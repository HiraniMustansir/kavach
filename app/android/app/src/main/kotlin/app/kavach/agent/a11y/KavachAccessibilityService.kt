package app.kavach.agent.a11y

import android.accessibilityservice.AccessibilityService
import android.app.KeyguardManager
import android.graphics.Bitmap
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.PowerManager
import android.view.Display
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import androidx.annotation.RequiresApi
import app.kavach.agent.Agent
import app.kavach.agent.enforce.Block
import app.kavach.agent.ml.Catalog
import app.kavach.agent.ml.DHash
import java.time.LocalDate
import java.util.concurrent.Executor

/**
 * Primary sensor (SENSE-1..5, SENSE-9) and the on-screen enforcer (CTL-3/5/6, TMP-5).
 * Text and frames stay in memory only and are dropped right after classification.
 */
class KavachAccessibilityService : AccessibilityService() {
    private lateinit var agent: Agent
    private lateinit var overlays: Overlays
    private val main = Handler(Looper.getMainLooper())
    private val work = HandlerThread("kavach-sense", android.os.Process.THREAD_PRIORITY_BACKGROUND).apply { start() }
    private val bg = Handler(work.looper)
    private val bgExec = Executor { bg.post(it) }

    private var pkg = ""
    private var label = ""
    private var domain: String? = null
    private var lastTextHash = 0
    private var textPending = false
    private val recentFrames = ArrayDeque<Long>()
    private var settingsUnlockedUntil = 0L

    override fun onServiceConnected() {
        agent = Agent.get(this)
        overlays = Overlays(this, agent)
        instance = this
        bg.postDelayed(sampler, 3_000)
        agent.setHealth("protected", null)
    }

    override fun onDestroy() {
        instance = null
        overlays.hideAll()
        work.quitSafely()
        super.onDestroy()
    }

    override fun onInterrupt() = Unit

    override fun onAccessibilityEvent(e: AccessibilityEvent) {
        if (!::agent.isInitialized || !agent.store.paired) return
        val p = e.packageName?.toString() ?: return
        when (e.eventType) {
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED -> {
                if (p == packageName || isOverlayOrIme(e)) return
                if (p != pkg) onAppChanged(p)
                guardSettings(p)
                scheduleText()
            }
            AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED, AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED -> {
                if (p != pkg) return
                guardSettings(p)
                scheduleText()
            }
        }
    }

    private fun isOverlayOrIme(e: AccessibilityEvent) = e.className?.toString()?.contains("InputMethod") == true

    private fun onAppChanged(p: String) {
        pkg = p
        label = agent.usage.label(p)
        currentLabel = label
        domain = null
        lastTextHash = 0
        recheck()
        bg.removeCallbacks(sampler)
        bg.postDelayed(sampler, 400) // SENSE-4(a): sample on app switch
    }

    /** CTL-3/CTL-1/CTL-2/CTL-6: decide and show the right overlay for the foreground app. */
    fun recheck() = bg.post {
        if (!::agent.isInitialized) return@post
        val p = pkg; val l = label
        if (p.isEmpty()) return@post
        // UsageStats + package lookups are slow on cheap phones: decide here, touch views on main.
        val b = agent.enforcer.check(p)
        if (b is Block.AppBlocked || b is Block.DailyLimit || b is Block.AppLimit) agent.risk.onBlockedAttempt(p, l)
        main.post {
            if (p != pkg) return@post // app changed meanwhile; that switch rechecks itself
            when (b) {
                null -> overlays.hideBlock(keepNotice = agent.usage.isLauncherOrSystemUi(p)) // notice stays on home only
                is Block.Locked -> overlays.showBlock(Overlays.Kind.LOCKED, null)
                is Block.Schedule -> overlays.showBlock(Overlays.Kind.SCHEDULE, b.name)
                else -> {
                    overlays.showBlock(if (b is Block.AppBlocked) Overlays.Kind.BLOCKED else Overlays.Kind.LIMIT, l)
                    performGlobalAction(GLOBAL_ACTION_HOME)
                }
            }
        }
    }

    // ---------- text (SENSE-2/3/9), debounced 750 ms ----------

    private fun scheduleText() {
        if (textPending) return
        textPending = true
        main.postDelayed({ textPending = false; readText() }, 750)
    }

    private fun readText() {
        val p = pkg
        if (p.isEmpty() || p in agent.store.policy.excludedFromCapture) return
        val root = rootInActiveWindow ?: return
        val snap = TextExtractor.extract(root, agent.catalog.urlBarIds[p], agent.catalog.searchIds)
        snap.url?.let { Catalog.hostOf(it) }?.let { host ->
            if (host != domain) {
                domain = host
                bg.post { agent.risk.onDomain(p, label, host) }
                if (Catalog.registrable(host) in agent.store.policy.blockedDomains) main.post {
                    agent.risk.onBlockedAttempt(p, label)
                    overlays.showBlock(Overlays.Kind.BLOCKED, host); performGlobalAction(GLOBAL_ACTION_BACK)
                }
            }
        }
        val h = snap.text.hashCode() * 31 + snap.typed.hashCode()
        if (h == lastTextHash) return // de-dup identical snapshots
        lastTextHash = h
        val d = domain; val l = label
        bg.post {
            if (snap.typed.isNotBlank()) agent.risk.onText(p, l, snap.typed, typed = true, domain = d)
            if (snap.text.isNotBlank()) agent.risk.onText(p, l, snap.text, typed = false, domain = d)
        }
    }

    // ---------- Tier B settings guard (TMP-5); also protects a11y toggle in Tier A ----------

    private val settingsPkgs = setOf("com.android.settings", "com.miui.securitycenter", "com.coloros.safecenter",
        "com.oplus.safecenter", "com.vivo.permissionmanager", "com.google.android.packageinstaller", "com.android.packageinstaller",
        "com.samsung.accessibility", "com.google.android.marvin.talkback")
    private val dangerWords = listOf("accessibility", "device admin", "admin app", "uninstall", "force stop", "deactivate",
        "clear storage", "clear data", "usage access", "disable", "अनइंस्टॉल", "बंद करें", "सुलभता")

    private fun guardSettings(p: String) {
        if (p !in settingsPkgs || System.currentTimeMillis() < settingsUnlockedUntil || agent.enforcer.paused()) return
        // No PIN yet = setup still in progress; gating now would block Usage access / Device admin screens.
        if (agent.store.policy.pin == null) return
        val root = rootInActiveWindow ?: return
        val appName = applicationInfo.loadLabel(packageManager).toString()
        val text = TextExtractor.extract(root, null, emptySet()).text.lowercase()
        if (text.contains(appName.lowercase()) && dangerWords.any { text.contains(it) }) {
            main.post {
                overlays.showPinGate(onOk = { settingsUnlockedUntil = System.currentTimeMillis() + 10 * 60_000 }) {
                    performGlobalAction(GLOBAL_ACTION_HOME)
                }
            }
        }
    }

    // ---------- visual sampling (SENSE-4/5, CLS-12) ----------

    private val sampler = object : Runnable {
        override fun run() {
            val next = runCatching { sampleOnce() }.getOrDefault(15_000L)
            bg.postDelayed(this, next)
        }
    }

    /** Returns ms until next sample, following the design §3.2 state machine. */
    private fun sampleOnce(): Long {
        val pm = getSystemService(PowerManager::class.java)
        val kg = getSystemService(KeyguardManager::class.java)
        val p = pkg
        val pol = agent.store.policy
        if (!pm.isInteractive || kg.isKeyguardLocked) return 5_000 // IDLE: never while off/locked
        if (p.isEmpty() || p in pol.excludedFromCapture || !pol.screenAi || agent.enforcer.paused()) return 15_000
        val vision = agent.vision ?: return 30_000 // no model shipped yet → nothing to look at, so no capture
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return 60_000 // SENSE-7 MediaProjection fallback not built
        if (Build.VERSION.SDK_INT >= 29 && pm.currentThermalStatus >= PowerManager.THERMAL_STATUS_SEVERE) return 30_000

        val base = when {
            System.currentTimeMillis() - agent.risk.lastRiskAt < 30_000 -> 1_000L // BURST
            p in agent.catalog.lowRisk -> 15_000L
            p in agent.catalog.highRisk || !fromPlayStore(p) -> 3_000L
            else -> 15_000L
        }
        val battery = getSystemService(BatteryManager::class.java).getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
        capture(vision, p)
        return if (battery in 0..14) base * 3 else base // DEGRADED
    }

    private fun fromPlayStore(p: String) = runCatching {
        val src = if (Build.VERSION.SDK_INT >= 30) packageManager.getInstallSourceInfo(p).installingPackageName
        else @Suppress("DEPRECATION") packageManager.getInstallerPackageName(p)
        src == "com.android.vending" || (packageManager.getApplicationInfo(p, 0).flags and android.content.pm.ApplicationInfo.FLAG_SYSTEM) != 0
    }.getOrDefault(true)

    @RequiresApi(Build.VERSION_CODES.R)
    private fun capture(vision: app.kavach.agent.ml.VisionGate, p: String) {
        takeScreenshot(Display.DEFAULT_DISPLAY, bgExec, object : TakeScreenshotCallback {
            override fun onSuccess(s: ScreenshotResult) {
                var hw: Bitmap? = null; var small: Bitmap? = null
                try {
                    hw = Bitmap.wrapHardwareBuffer(s.hardwareBuffer, s.colorSpace) ?: return
                    val sw = hw.copy(Bitmap.Config.ARGB_8888, false)
                    small = Bitmap.createScaledBitmap(sw, 224, 224 * sw.height / maxOf(1, sw.width), true)
                    sw.recycle()
                    val h = DHash.of(small)
                    if (recentFrames.any { DHash.distance(it, h) <= 4 }) return // near-duplicate of last 5
                    recentFrames.addLast(h); while (recentFrames.size > 5) recentFrames.removeFirst()
                    agent.risk.onVision(p, label, vision.run(small), domain)
                } finally {
                    small?.recycle(); hw?.recycle(); s.hardwareBuffer.close()
                }
            }
            override fun onFailure(code: Int) {
                if (code == ERROR_TAKE_SCREENSHOT_SECURE_WINDOW) {
                    agent.events.bump(LocalDate.now().toString(), "limited_visibility_min")
                }
            }
        })
    }

    /** PAIR-4 self-test: can this OEM build give us a screenshot? */
    fun testScreenshot(cb: (Boolean) -> Unit) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return cb(false)
        takeScreenshot(Display.DEFAULT_DISPLAY, bgExec, object : TakeScreenshotCallback {
            override fun onSuccess(s: ScreenshotResult) { s.hardwareBuffer.close(); main.post { cb(true) } }
            override fun onFailure(code: Int) { main.post { cb(false) } }
        })
    }

    fun showIntervention(category: String) = main.post { overlays.showIntervention(category) { performGlobalAction(GLOBAL_ACTION_BACK) } }

    fun showPinGate(onOk: () -> Unit) = main.post { overlays.showPinGate(onOk) {} }

    companion object {
        @Volatile var instance: KavachAccessibilityService? = null; private set
        @Volatile var currentLabel: String? = null
    }
}

/** Breadth-first node walk (design §3.3): ≤400 nodes / 4000 chars, never password fields. */
object TextExtractor {
    data class Snapshot(val text: String, val typed: String, val url: String?)

    fun extract(root: AccessibilityNodeInfo, urlBarId: String?, searchIds: Set<String>): Snapshot {
        val text = StringBuilder(); val typed = StringBuilder()
        var url: String? = null
        val q = ArrayDeque<AccessibilityNodeInfo>().apply { add(root) }
        var n = 0
        while (q.isNotEmpty() && n < 400 && text.length < 4000) {
            val node = q.removeFirst(); n++
            if (!node.isPassword) {
                val id = node.viewIdResourceName
                val t = node.text?.toString()
                if (t != null) {
                    when {
                        urlBarId != null && id == urlBarId -> url = t
                        node.isEditable || (id != null && id in searchIds) -> typed.append(t).append(' ')
                        else -> text.append(t).append(' ')
                    }
                }
                node.contentDescription?.let { if (it.length in 3..200) text.append(it).append(' ') }
            }
            for (i in 0 until node.childCount) node.getChild(i)?.let { q.add(it) }
        }
        return Snapshot(text.toString().take(4000), typed.toString().take(500), url)
    }
}
