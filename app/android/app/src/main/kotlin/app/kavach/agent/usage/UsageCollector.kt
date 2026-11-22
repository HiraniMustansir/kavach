package app.kavach.agent.usage

import android.app.AppOpsManager
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.pm.ApplicationInfo
import android.os.Process
import java.time.LocalDate
import java.time.ZoneId

/** Screen-time from UsageStats (CTL-1, DIG-2). Foreground time is rebuilt from resume/pause events. */
class UsageCollector(private val ctx: Context) {
    private val usm = ctx.getSystemService(UsageStatsManager::class.java)
    private val pm = ctx.packageManager

    data class Day(
        val fgMs: Map<String, Long>, val pickups: Int, val firstUse: Long?, val lastUse: Long?,
        /** foreground ms per minute-of-day bucket, for late-night totals */
        val lateNightMs: Long,
    ) {
        val totalMs get() = fgMs.values.sum()
    }

    private var cache: Pair<Long, Day>? = null

    fun hasAccess(): Boolean {
        val ops = ctx.getSystemService(AppOpsManager::class.java)
        @Suppress("DEPRECATION")
        val mode = if (android.os.Build.VERSION.SDK_INT >= 29) ops.unsafeCheckOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), ctx.packageName)
        else ops.checkOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), ctx.packageName)
        return mode == AppOpsManager.MODE_ALLOWED
    }

    /** Today so far, cached 30 s (limits are checked on every app switch). */
    fun today(lateFrom: Int = 23 * 60, lateTo: Int = 5 * 60): Day {
        val now = System.currentTimeMillis()
        cache?.let { if (now - it.first < 30_000) return it.second }
        val start = LocalDate.now().atStartOfDay(ZoneId.systemDefault()).toInstant().toEpochMilli()
        return day(start, now, lateFrom, lateTo).also { cache = now to it }
    }

    fun day(start: Long, end: Long, lateFrom: Int, lateTo: Int): Day {
        val fg = HashMap<String, Long>()
        var pickups = 0; var first: Long? = null; var last: Long? = null; var late = 0L
        val open = HashMap<String, Long>()
        val ev = UsageEvents.Event()
        val events = runCatching { usm.queryEvents(start, end) }.getOrNull() ?: return Day(emptyMap(), 0, null, null, 0)
        val own = ctx.packageName
        fun close(pkg: String, at: Long) {
            val s = open.remove(pkg) ?: return
            if (pkg == own || isLauncherOrSystemUi(pkg)) return
            fg[pkg] = (fg[pkg] ?: 0) + (at - s)
            late += lateOverlap(s, at, lateFrom, lateTo)
            if (first == null) first = s
            last = at
        }
        while (events.hasNextEvent()) {
            events.getNextEvent(ev)
            when (ev.eventType) {
                UsageEvents.Event.ACTIVITY_RESUMED -> { open.keys.toList().forEach { close(it, ev.timeStamp) }; open[ev.packageName] = ev.timeStamp }
                UsageEvents.Event.ACTIVITY_PAUSED, UsageEvents.Event.ACTIVITY_STOPPED -> close(ev.packageName, ev.timeStamp)
                UsageEvents.Event.SCREEN_NON_INTERACTIVE -> open.keys.toList().forEach { close(it, ev.timeStamp) }
                UsageEvents.Event.KEYGUARD_HIDDEN -> pickups++
            }
        }
        open.keys.toList().forEach { close(it, end) }
        return Day(fg, pickups, first, last, late)
    }

    private fun lateOverlap(s: Long, e: Long, from: Int, to: Int): Long {
        var t = s; var acc = 0L
        val zone = ZoneId.systemDefault()
        while (t < e) { // minute steps; sessions are short so this is cheap
            val m = java.time.Instant.ofEpochMilli(t).atZone(zone).let { it.hour * 60 + it.minute }
            val step = minOf(60_000L, e - t)
            if (app.kavach.agent.core.Policy.inWindow(m, from, to)) acc += step
            t += step
        }
        return acc
    }

    private val launchers by lazy {
        pm.queryIntentActivities(android.content.Intent(android.content.Intent.ACTION_MAIN).addCategory(android.content.Intent.CATEGORY_HOME), 0)
            .map { it.activityInfo.packageName }.toSet() + "com.android.systemui"
    }
    fun isLauncherOrSystemUi(pkg: String) = pkg in launchers

    fun label(pkg: String): String = runCatching { pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString() }.getOrDefault(pkg)

    /** Digest/limit category from the app's own manifest category (CTL-1 per-category, DIG-2). */
    fun category(pkg: String, browsers: Set<String>): String {
        if (pkg in browsers) return "browsing"
        val c = runCatching { pm.getApplicationInfo(pkg, 0).category }.getOrDefault(ApplicationInfo.CATEGORY_UNDEFINED)
        return when (c) {
            ApplicationInfo.CATEGORY_GAME -> "games"
            ApplicationInfo.CATEGORY_VIDEO, ApplicationInfo.CATEGORY_AUDIO -> "video"
            ApplicationInfo.CATEGORY_SOCIAL -> "social"
            ApplicationInfo.CATEGORY_PRODUCTIVITY -> "education"
            ApplicationInfo.CATEGORY_NEWS, ApplicationInfo.CATEGORY_IMAGE -> "other"
            else -> if (pkg.contains("whatsapp") || pkg.contains("messag") || pkg.contains("telegram")) "communication" else "other"
        }
    }
}
