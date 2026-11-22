package app.kavach.agent

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.PowerManager
import app.kavach.MainActivity
import app.kavach.R
import app.kavach.agent.admin.PolicyApplier
import app.kavach.agent.sync.SyncWorker
import java.time.LocalDate
import java.time.LocalTime

/**
 * Always-on foreground service (TMP-6) with the policy-required persistent notification (KID-1).
 * Runs the 60 s watchdog (TMP-4), the 5-min heartbeat while the screen is on (TMP-7),
 * late-night tracking (BEH-1), limit warnings (CTL-1) and the 21:00 digest trigger (DIG-1).
 */
class AgentService : Service() {
    private val thread = HandlerThread("kavach-agent").apply { start() }
    private val h = Handler(thread.looper)
    private lateinit var agent: Agent
    private var ticks = 0
    private var warned = HashSet<String>()
    private var suspendedForA11y = false

    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, i: Intent) {
            if (i.action == Intent.ACTION_SCREEN_ON || i.action == Intent.ACTION_USER_PRESENT) { lastScreenOn = System.currentTimeMillis(); h.post(tick) }
        }
    }

    override fun onCreate() {
        super.onCreate()
        agent = Agent.get(this)
        channels(this)
        val n = Notification.Builder(this, STATUS_CHANNEL)
            .setSmallIcon(R.drawable.ic_shield)
            .setContentTitle(getString(R.string.status_title))
            .setContentText(getString(R.string.status_body))
            .setOngoing(true)
            .setContentIntent(PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE))
            .build()
        if (Build.VERSION.SDK_INT >= 34) startForeground(1, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE) else startForeground(1, n)
        registerReceiver(screenReceiver, IntentFilter().apply { addAction(Intent.ACTION_SCREEN_ON); addAction(Intent.ACTION_USER_PRESENT) })
        lastScreenOn = System.currentTimeMillis()
        h.post(tick)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int) = START_STICKY

    override fun onDestroy() {
        runCatching { unregisterReceiver(screenReceiver) }
        thread.quitSafely()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private val tick = object : Runnable {
        override fun run() {
            h.removeCallbacks(this)
            if (!agent.store.paired) { stopSelf(); return }
            runCatching { watchdog() }
            val interactive = getSystemService(PowerManager::class.java).isInteractive
            if (interactive) {
                lastScreenOn = System.currentTimeMillis()
                runCatching { minuteChecks() }
            }
            // Heartbeat every 5 min while in use; the 15-min WorkManager job covers screen-off (no wake locks).
            if (interactive && ticks % 5 == 0) agent.io.execute { agent.sync() }
            ticks++
            h.postDelayed(this, 60_000)
        }
    }

    /** TMP-4/TMP-7: what's broken, self-heal where the API allows, report the rest. */
    private fun watchdog() {
        val problems = mutableListOf<String>()
        val a11y = agent.accessibilityOn()
        if (!a11y) problems += "Accessibility is off"
        if (!agent.usage.hasAccess()) problems += "Usage access is off"
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) problems += "Notifications are off"
        if (PolicyApplier.isDeviceOwner(this)) {
            PolicyApplier.ensure(this) // re-apply restrictions if anything drifted
            // TMP-4(b): without the accessibility service we're blind, so everything non-essential pauses.
            if (!a11y != suspendedForA11y) { PolicyApplier.suspendAllNonEssential(this, agent, !a11y); suspendedForA11y = !a11y }
        }
        if (agent.enforcer.paused()) agent.events.bump(LocalDate.now().toString(), "paused_min")
        if (problems.isEmpty()) agent.setHealth("protected", null)
        else { agent.setHealth("degraded", problems.joinToString("; ")); agent.events.bump(LocalDate.now().toString(), "degraded_min") }
    }

    private fun minuteChecks() {
        val p = agent.store.policy
        val today = LocalDate.now().toString()
        // BEH-1 late-night minutes (only counted while interactive)
        val now = LocalTime.now().let { it.hour * 60 + it.minute }
        if (app.kavach.agent.core.Policy.inWindow(now, p.lateNightFrom, p.lateNightTo)) {
            agent.events.bump(today, "late_night_min")
            agent.risk.onLateNightMinutes(agent.events.counters(today)["late_night_min"] ?: 0)
        }
        // CTL-1 warnings at 5 and 1 minute left, then the a11y service blocks.
        agent.enforcer.minutesLeft(p)?.let { left ->
            for (w in listOf(5L, 1L)) if (left == w && warned.add("$today-$w")) notifyChild(getString(R.string.limit_warning, w))
            if (left == 0L) app.kavach.agent.a11y.KavachAccessibilityService.instance?.recheck()
        }
        // Schedules can start while an app is open.
        app.kavach.agent.a11y.KavachAccessibilityService.instance?.recheck()
        if (now >= 21 * 60 && agent.store.lastDigestDay != today) agent.io.execute { runCatching { agent.maybeDigest() } }
    }

    private fun notifyChild(text: String) {
        getSystemService(NotificationManager::class.java).notify(2, Notification.Builder(this, STATUS_CHANNEL)
            .setSmallIcon(R.drawable.ic_shield).setContentTitle("Kavach").setContentText(text).setAutoCancel(true).build())
    }

    companion object {
        const val STATUS_CHANNEL = "kavach_status"
        @Volatile private var lastScreenOn = 0L
        fun screenOnRecently() = System.currentTimeMillis() - lastScreenOn < 10 * 60_000

        fun start(ctx: Context) {
            if (!app.kavach.agent.core.Store(ctx).paired) return
            runCatching { ctx.startForegroundService(Intent(ctx, AgentService::class.java)) }
            SyncWorker.schedule(ctx)
        }
        fun stop(ctx: Context) = ctx.stopService(Intent(ctx, AgentService::class.java))

        fun channels(ctx: Context) {
            val nm = ctx.getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(NotificationChannel(STATUS_CHANNEL, ctx.getString(R.string.channel_status), NotificationManager.IMPORTANCE_LOW))
        }
    }
}

