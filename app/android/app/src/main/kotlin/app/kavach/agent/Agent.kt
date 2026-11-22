package app.kavach.agent

import android.content.ComponentName
import android.content.Context
import android.os.BatteryManager
import android.provider.Settings
import android.util.Log
import app.kavach.agent.a11y.KavachAccessibilityService
import app.kavach.agent.admin.PolicyApplier
import app.kavach.agent.core.Policy
import app.kavach.agent.core.Store
import app.kavach.agent.data.EventStore
import app.kavach.agent.data.RiskEvent
import app.kavach.agent.enforce.Enforcer
import app.kavach.agent.ml.Catalog
import app.kavach.agent.ml.TextRisk
import app.kavach.agent.ml.VisionGate
import app.kavach.agent.risk.RiskEngine
import app.kavach.agent.sync.ApiException
import app.kavach.agent.sync.SyncClient
import app.kavach.agent.sync.SyncWorker
import app.kavach.agent.usage.UsageCollector
import org.json.JSONArray
import org.json.JSONObject
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZoneId
import java.util.concurrent.Executors

/** Process-wide agent: owns the engines and the sync/command logic shared by services, workers and the Flutter bridge. */
class Agent private constructor(val ctx: Context) {
    val store = Store(ctx)
    val events = EventStore.get(ctx)
    val catalog = Catalog.load(ctx)
    val usage = UsageCollector(ctx)
    val enforcer = Enforcer(store, catalog, usage, ctx.packageName)
    val api = SyncClient(store)
    @Volatile var vision: VisionGate? = VisionGate.load(ctx); private set
    val io = Executors.newSingleThreadExecutor()
    val risk = RiskEngine(store, events, TextRisk.load(ctx), catalog) { e, cat -> onRiskEvent(e, cat) }

    /** High/critical go out right away (ALR-1); the rest ride the next sync. CTL-5 intervention on screen. */
    private fun onRiskEvent(e: RiskEvent, cat: Policy.Cat?) {
        if (e.severity == "high" || e.severity == "critical") SyncWorker.now(ctx)
        val intervene = cat?.intervene == "blur" && e.category in setOf("SEX", "GORE") && e.severity in setOf("high", "critical")
        if (intervene) KavachAccessibilityService.instance?.showIntervention(e.category)
    }

    // ---------- pairing ----------

    fun pair(token: String, fcmToken: String?): JSONObject {
        val pub = app.kavach.agent.core.Crypto.newDeviceKey()
        val info = JSONObject().put("model", android.os.Build.MODEL).put("oem", android.os.Build.MANUFACTURER)
            .put("osVersion", android.os.Build.VERSION.RELEASE).put("appVersion", appVersion()).put("fcmToken", fcmToken)
        val r = api.pairComplete(token.trim().uppercase(), pub, info)
        store.deviceId = r.getString("deviceId")
        store.childId = r.getString("childId")
        store.nickname = r.optString("nickname")
        store.ageBand = r.optString("ageBand", "child")
        store.tier = r.optString("tier", "C")
        store.fcmToken = fcmToken
        store.pendingPairingToken = null
        applyPolicy(r.getJSONObject("policy"))
        if (store.tier == "A" && PolicyApplier.isDeviceOwner(ctx)) PolicyApplier.applyTierA(ctx)
        SyncWorker.schedule(ctx)
        AgentService.start(ctx)
        return r
    }

    fun applyPolicy(p: JSONObject) {
        val body = p.optJSONObject("body") ?: JSONObject()
        if (!body.has("version")) body.put("version", p.optInt("version"))
        store.policyJson = body.toString()
        if (PolicyApplier.isDeviceOwner(ctx)) PolicyApplier.syncSuspended(ctx, this)
    }

    // ---------- sync ----------

    /** Upload queued events, heartbeat, run pending commands, pull policy. Safe to call often. */
    @Synchronized fun sync() {
        if (!store.paired) return
        try {
            // ALR-6: queued offline events go first with their original timestamps.
            while (true) {
                val batch = events.unsynced(100)
                if (batch.isEmpty()) break
                val r = api.post("events", JSONObject().put("events", JSONArray(batch.map { it.toJson() })))
                val ids = r.optJSONArray("accepted")?.let { a -> (0 until a.length()).map { a.getString(it) } } ?: emptyList()
                events.markSynced(ids)
                if (ids.size < batch.size) break
            }
            heartbeat()
            maybeDigest()
            events.prune()
            store.orphanSince = 0
        } catch (e: ApiException) {
            // Orphan handling: the server no longer knows this device (remote unpair or account deleted).
            // Release only after it has said so consistently for an hour, so a transient error can't do it.
            if (e.status == 401 && e.message == "unknown device") {
                val now = System.currentTimeMillis()
                if (store.orphanSince == 0L) store.orphanSince = now
                else if (now - store.orphanSince > 60 * 60_000) release("server no longer recognises this device")
            }
            Log.w(TAG, "sync failed: ${e.status} ${e.message}")
        } catch (e: Exception) {
            Log.w(TAG, "sync failed", e)
        }
    }

    private val ackQueue = mutableListOf<Long>()

    private fun heartbeat() {
        val bm = ctx.getSystemService(BatteryManager::class.java)
        val body = JSONObject()
            .put("health", if (enforcer.paused()) "paused" else store.health ?: "protected")
            .put("reason", store.healthReason)
            .put("battery", bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY))
            .put("screenOnRecent", AgentService.screenOnRecently())
            .put("policyVersion", store.policy.version)
            .put("modelVersion", if (vision != null) "vision" else "rules")
            .put("currentApp", if (store.ageBand == "child") KavachAccessibilityService.currentLabel else null)
            .put("fcmToken", store.fcmToken)
            .put("ackCommands", JSONArray(synchronized(ackQueue) { ackQueue.toList() }))
            .put("today", todaySummary())
        val r = api.post("heartbeat", body)
        synchronized(ackQueue) { ackQueue.clear() }
        r.optLong("serverTime").takeIf { it > 0 }?.let { store.serverSkewMs = it - System.currentTimeMillis() }
        store.tuningJson = (r.optJSONObject("tuning") ?: JSONObject()).toString()
        val cmds = r.optJSONArray("commands") ?: JSONArray()
        for (i in 0 until cmds.length()) {
            val c = cmds.getJSONObject(i)
            runCommand(c.getString("kind"), c.optJSONObject("args") ?: JSONObject())
            synchronized(ackQueue) { ackQueue += c.getLong("id") }
        }
        if (r.optInt("policyVersion") > store.policy.version) applyPolicy(api.get("policy"))
        if (cmds.length() > 0 && store.paired) api.post("heartbeat", body.put("ackCommands", JSONArray(synchronized(ackQueue) { ackQueue.toList() })))
            .also { synchronized(ackQueue) { ackQueue.clear() } }
    }

    private fun todaySummary(): JSONObject {
        val p = store.policy
        val d = usage.today(p.lateNightFrom, p.lateNightTo)
        return JSONObject().put("usedMin", d.totalMs / 60_000).put("minutesLeft", enforcer.minutesLeft(p))
            .put("topApps", JSONArray(d.fgMs.entries.sortedByDescending { it.value }.take(3).map {
                JSONObject().put("label", usage.label(it.key)).put("pkg", it.key).put("min", it.value / 60_000)
            }))
    }

    fun runCommand(kind: String, args: JSONObject) {
        when (kind) {
            "lock" -> { store.lockedByParent = true; PolicyApplier.lockNow(ctx); KavachAccessibilityService.instance?.recheck() }
            "unlock" -> { store.lockedByParent = false; KavachAccessibilityService.instance?.recheck() }
            "pause" -> store.pausedUntil = System.currentTimeMillis() + args.optLong("minutes", 30) * 60_000
            "resume" -> store.pausedUntil = 0
            "add_time" -> { store.addExtraMinutes(LocalDate.now().toString(), args.optLong("minutes", 15)); KavachAccessibilityService.instance?.recheck() }
            "unpair" -> release(args.optString("reason", "parent unpaired"))
            "sync_policy" -> Unit // handled by the policy-version check
        }
    }

    /** Health from the watchdog (TMP-4/7). A change triggers an immediate heartbeat. */
    fun setHealth(state: String, reason: String?) {
        if (store.health == state && store.healthReason == reason) return
        store.health = state; store.healthReason = reason
        SyncWorker.now(ctx)
    }

    fun signal(kind: String, extra: JSONObject = JSONObject()) {
        io.execute { runCatching { api.post("signal", extra.put("kind", kind)) }.onFailure { Log.w(TAG, "signal $kind failed", it) } }
    }

    /** PAIR-6 / VPC-5: drop Device Owner and all data so the phone is a normal phone again. */
    fun release(reason: String) {
        Log.i(TAG, "releasing: $reason")
        if (store.paired) runCatching { api.post("signal", JSONObject().put("kind", "unpaired").put("detail", reason)) }
        PolicyApplier.release(ctx)
        events.wipe()
        store.clearPairing()
        SyncWorker.cancel(ctx)
        AgentService.stop(ctx)
    }

    // ---------- digest (DIG-1/2, design §4.4) ----------

    fun maybeDigest(now: LocalDateTime = LocalDateTime.now()) {
        val today = now.toLocalDate().toString()
        if (now.hour < 21 || store.lastDigestDay == today) return
        api.post("digest", JSONObject().put("stats", buildDigest(now.toLocalDate())))
        store.lastDigestDay = today
    }

    fun buildDigest(day: LocalDate): JSONObject {
        val p = store.policy
        val zone = ZoneId.systemDefault()
        val start = day.atStartOfDay(zone).toInstant().toEpochMilli()
        val end = minOf(System.currentTimeMillis(), day.plusDays(1).atStartOfDay(zone).toInstant().toEpochMilli())
        val d = usage.day(start, end, p.lateNightFrom, p.lateNightTo)
        val prev = (1..7).map { i ->
            val s = day.minusDays(i.toLong()).atStartOfDay(zone).toInstant().toEpochMilli()
            usage.day(s, s + 86_400_000, p.lateNightFrom, p.lateNightTo).totalMs
        }.filter { it > 0 }
        val screenMin = (d.totalMs / 60_000).toInt()
        val cats = HashMap<String, Long>()
        d.fgMs.forEach { (pkg, ms) -> cats.merge(usage.category(pkg, catalog.browsers), ms, Long::plus) }
        val fmt = { t: Long? -> t?.let { java.time.Instant.ofEpochMilli(it).atZone(zone).toLocalTime().toString().take(5) } }
        val evs = events.since(start).filter { it.tsWall < end && it.category != "SOS" }
        val risks = evs.groupBy { it.category to it.severity }.map { (k, list) ->
            JSONObject().put("cat", k.first).put("sev", k.second).put("count", list.size)
                .put("times", JSONArray(list.take(5).map { fmt(it.tsWall) }))
        }
        val counters = events.counters(day.toString())
        val newApps = counters.keys.filter { it.startsWith("newapp:") }.map {
            val (label, cat) = it.removePrefix("newapp:").split("|").let { s -> s[0] to s.getOrElse(1) { "" } }
            JSONObject().put("label", label).put("category", cat.ifEmpty { null })
        }
        return JSONObject()
            .put("day", day.toString()).put("screenMin", screenMin)
            .put("vsAvg7", if (prev.isEmpty()) null else ((d.totalMs - prev.average()) * 100 / prev.average()).toInt())
            .put("pickups", d.pickups).put("firstUse", fmt(d.firstUse)).put("lastUse", fmt(d.lastUse))
            .put("lateNightMin", (d.lateNightMs / 60_000).toInt())
            .put("topApps", JSONArray(d.fgMs.entries.sortedByDescending { it.value }.take(5).map {
                JSONObject().put("label", usage.label(it.key)).put("pkg", it.key).put("min", (it.value / 60_000).toInt()).put("category", usage.category(it.key, catalog.browsers))
            }))
            .put("categories", JSONObject(cats.mapValues { (it.value / 60_000).toInt() }))
            .put("risks", JSONArray(risks))
            .put("newApps", JSONArray(newApps))
            .put("blockedAttempts", counters["blocked_attempts"] ?: 0)
            .put("incognitoSessions", counters["incognito"] ?: 0)
            .put("health", JSONObject().put("degradedMin", counters["degraded_min"] ?: 0))
            .put("limitedVisibilityMin", counters["limited_visibility_min"] ?: 0)
            .put("pausedMin", counters["paused_min"] ?: 0)
    }

    // ---------- status for the child UI + self-test (PAIR-4, KID-2) ----------

    fun accessibilityOn(): Boolean {
        val want = ComponentName(ctx, KavachAccessibilityService::class.java).flattenToString()
        val on = Settings.Secure.getString(ctx.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES) ?: ""
        return on.split(':').any { it.equals(want, true) }
    }

    fun reloadModels() { vision = VisionGate.load(ctx) }

    enum class PinResult { OK, WRONG, LOCKED_OUT, NO_PIN }

    /** ACC-8: 5 wrong tries → 15-minute lockout + parent alert. Shared by the overlay gate and the Flutter parent area. */
    fun verifyPin(pin: String): Pair<PinResult, Int> {
        val p = store.policy.pin ?: return PinResult.NO_PIN to 0
        if (store.pinLockoutUntil > System.currentTimeMillis()) return PinResult.LOCKED_OUT to 0
        if (app.kavach.agent.core.Crypto.pinMatches(pin, p.first, p.second, p.third)) { store.pinFailures = 0; return PinResult.OK to 5 }
        val f = store.pinFailures + 1
        if (f >= 5) {
            store.pinFailures = 0
            store.pinLockoutUntil = System.currentTimeMillis() + 15 * 60_000
            signal("pin_lockout")
            return PinResult.LOCKED_OUT to 0
        }
        store.pinFailures = f
        return PinResult.WRONG to (5 - f).toInt()
    }

    private fun appVersion() = runCatching { ctx.packageManager.getPackageInfo(ctx.packageName, 0).versionName }.getOrNull() ?: "0"

    companion object {
        const val TAG = "KavachAgent"
        @Volatile private var inst: Agent? = null
        fun get(ctx: Context) = inst ?: synchronized(this) { inst ?: Agent(ctx.applicationContext).also { inst = it } }
    }
}
