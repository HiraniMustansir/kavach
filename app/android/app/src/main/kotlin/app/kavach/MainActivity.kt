package app.kavach

import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import app.kavach.agent.Agent
import app.kavach.agent.AgentService
import app.kavach.agent.a11y.KavachAccessibilityService
import app.kavach.agent.a11y.KavachNotificationListener
import app.kavach.agent.admin.PolicyApplier
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

/** Flutter shell + the `app.kavach/agent` channel to the native child agent (design §2). */
class MainActivity : FlutterFragmentActivity() {
    private val agent by lazy { Agent.get(this) }

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        MethodChannel(engine.dartExecutor.binaryMessenger, "app.kavach/agent").setMethodCallHandler { call, result ->
            fun bg(block: () -> Any?) = agent.io.execute {
                val r = runCatching(block)
                runOnUiThread { r.fold({ result.success(it) }, { result.error("agent", it.message, null) }) }
            }
            when (call.method) {
                "status" -> result.success(status())
                "pair" -> bg { agent.pair(call.argument<String>("token")!!, call.argument<String>("fcmToken")).toString() }
                "openAccessibility" -> open(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS), result)
                "openUsageAccess" -> open(Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS), result)
                "openNotificationListener" -> open(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS), result)
                "openAppDetails" -> open(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")), result)
                "requestBatteryExemption" -> @Suppress("BatteryLife") open(
                    Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:$packageName")), result)
                "activateAdmin" -> open(Intent(DevicePolicyManager.ACTION_ADD_DEVICE_ADMIN)
                    .putExtra(DevicePolicyManager.EXTRA_DEVICE_ADMIN, PolicyApplier.admin(this))
                    .putExtra(DevicePolicyManager.EXTRA_ADD_EXPLANATION, getString(R.string.admin_explanation)), result)
                "openAutostart" -> openAutostart(result)
                "requestNotifications" -> {
                    if (Build.VERSION.SDK_INT >= 33) requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 7)
                    result.success(true)
                }
                "startAgent" -> { AgentService.start(this); result.success(true) }
                "selfTest" -> selfTest(result)
                "today" -> bg { today() }
                "sos" -> bg { agent.risk.sos(); agent.sync(); true }
                "reportMisuse" -> bg { agent.api.post("report", JSONObject().put("message", call.argument<String>("message"))); true }
                "requestTime" -> bg {
                    agent.api.post("request", JSONObject().put("kind", "more_time").put("minutes", call.argument<Int>("minutes") ?: 15)
                        .put("reason", call.argument<String>("reason"))).toString()
                }
                "verifyPin" -> bg { agent.verifyPin(call.argument<String>("pin") ?: "").let { mapOf("result" to it.first.name, "left" to it.second) } }
                // Parent-area actions: Flutter only calls these after verifyPin returned OK.
                "pause" -> { agent.store.pausedUntil = System.currentTimeMillis() + (call.argument<Int>("minutes") ?: 30) * 60_000L; result.success(true) }
                "resume" -> { agent.store.pausedUntil = 0; result.success(true) }
                "unpair" -> bg { agent.release("unpaired on device with parent PIN"); true }
                "diagnostics" -> bg { agent.sync(); status() }
                else -> result.notImplemented()
            }
        }
    }

    private fun open(i: Intent, result: MethodChannel.Result) {
        runCatching { startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
            .fold({ result.success(true) }, { result.success(false) })
    }

    private fun status(): Map<String, Any?> {
        val s = agent.store
        val dpm = getSystemService(DevicePolicyManager::class.java)
        val nl = Settings.Secure.getString(contentResolver, "enabled_notification_listeners") ?: ""
        val others = dpm.activeAdmins.orEmpty().map { it.packageName }.filter { it != packageName }
        return mapOf(
            "paired" to s.paired, "nickname" to s.nickname, "ageBand" to s.ageBand, "tier" to s.tier,
            "pendingToken" to s.pendingPairingToken,
            "deviceOwner" to PolicyApplier.isDeviceOwner(this), "admin" to PolicyApplier.isAdmin(this),
            "accessibility" to agent.accessibilityOn(), "usageAccess" to agent.usage.hasAccess(),
            "notifications" to (Build.VERSION.SDK_INT < 33 || checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) == android.content.pm.PackageManager.PERMISSION_GRANTED),
            "batteryExempt" to getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(packageName),
            "notificationListener" to nl.contains(ComponentName(this, KavachNotificationListener::class.java).flattenToString()),
            "otherAdmins" to others, // PAIR-5: Family Link / another DPC
            "health" to (s.health ?: "protected"), "healthReason" to s.healthReason,
            "pausedUntil" to s.pausedUntil, "locked" to s.lockedByParent, "hasPin" to (s.policy.pin != null),
            "sdk" to Build.VERSION.SDK_INT, "oem" to Build.MANUFACTURER.lowercase(), "visionModel" to (agent.vision != null),
        )
    }

    private fun today(): Map<String, Any?> {
        val p = agent.store.policy
        val day = agent.usage.today(p.lateNightFrom, p.lateNightTo)
        val sched = agent.enforcer.activeSchedule(p)
        val upcoming = p.schedules.minByOrNull { s ->
            val now = java.time.LocalTime.now().let { it.hour * 60 + it.minute }
            (s.start - now + 1440) % 1440
        }
        return mapOf(
            "usedMin" to day.totalMs / 60_000, "minutesLeft" to agent.enforcer.minutesLeft(p),
            "apps" to p.perAppMin.keys.map { mapOf("label" to agent.usage.label(it), "left" to agent.enforcer.appMinutesLeft(it, p)) },
            "schedule" to sched?.let { mapOf("name" to it.name, "until" to "%02d:%02d".format(it.end / 60, it.end % 60)) },
            "nextSchedule" to upcoming?.let { mapOf("name" to it.name, "start" to "%02d:%02d".format(it.start / 60, it.start % 60)) },
            "locked" to agent.store.lockedByParent,
        )
    }

    /** PAIR-4: each check plus a real test alert to the parent. */
    private fun selfTest(result: MethodChannel.Result) {
        val svc = KavachAccessibilityService.instance
        val finish = { shot: Boolean? ->
            agent.io.execute {
                val sent = runCatching { agent.api.post("signal", JSONObject().put("kind", "test")); true }.getOrDefault(false)
                runCatching { agent.sync() }
                val st = status()
                runOnUiThread {
                    result.success(st + mapOf("screenshot" to shot, "modelLoaded" to (agent.vision != null), "testAlertSent" to sent))
                }
            }
        }
        if (svc == null) finish(null) else svc.testScreenshot { finish(it) }
    }

    /** PAIR-3: OEM autostart / battery screens (MIUI, ColorOS, FuntouchOS, One UI). */
    private fun openAutostart(result: MethodChannel.Result) {
        val candidates = listOf(
            ComponentName("com.miui.securitycenter", "com.miui.permcenter.autostart.AutoStartManagementActivity"),
            ComponentName("com.coloros.safecenter", "com.coloros.safecenter.permission.startup.StartupAppListActivity"),
            ComponentName("com.oplus.safecenter", "com.oplus.safecenter.permission.startup.StartupAppListActivity"),
            ComponentName("com.vivo.permissionmanager", "com.vivo.permissionmanager.activity.BgStartUpManagerActivity"),
            ComponentName("com.iqoo.secure", "com.iqoo.secure.ui.phoneoptimize.AddWhiteListActivity"),
            ComponentName("com.samsung.android.lool", "com.samsung.android.sm.battery.ui.BatteryActivity"),
        )
        for (c in candidates) {
            if (runCatching { startActivity(Intent().setComponent(c).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }.isSuccess) {
                result.success(true); return
            }
        }
        open(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")), result)
    }
}
