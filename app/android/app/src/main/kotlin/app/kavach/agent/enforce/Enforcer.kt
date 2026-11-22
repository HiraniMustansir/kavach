package app.kavach.agent.enforce

import app.kavach.agent.core.Policy
import app.kavach.agent.core.Store
import app.kavach.agent.ml.Catalog
import app.kavach.agent.usage.UsageCollector
import java.time.LocalDate
import java.time.LocalDateTime

/** Why an app may not be used right now. Pure decision logic; overlays/suspension live in the service. */
sealed class Block(val reason: String) {
    object Locked : Block("locked")
    class Schedule(val name: String, val until: Int) : Block("schedule")
    object AppBlocked : Block("app_blocked")
    object DailyLimit : Block("daily_limit")
    class AppLimit(val minutes: Int) : Block("app_limit")
}

class Enforcer(private val store: Store, @Volatile var catalog: Catalog, private val usage: UsageCollector, private val ownPkg: String) {

    fun paused(now: Long = System.currentTimeMillis()) = store.pausedUntil > now

    /** Schedule active now (CTL-2), days 0=Sunday per design §4.3. Windows may wrap midnight. */
    fun activeSchedule(p: Policy, at: LocalDateTime = LocalDateTime.now()): Policy.Schedule? {
        val min = at.hour * 60 + at.minute
        val dow = at.dayOfWeek.value % 7
        val yesterday = (dow + 6) % 7
        return p.schedules.firstOrNull { s ->
            if (!Policy.inWindow(min, s.start, s.end)) return@firstOrNull false
            // a 21:30–06:30 window that started yesterday counts for yesterday's day list
            if (s.start > s.end && min < s.end) yesterday in s.days else dow in s.days
        }
    }

    fun isEssential(pkg: String) = pkg == ownPkg || pkg in catalog.essentialApps || usage.isLauncherOrSystemUi(pkg)

    fun check(pkg: String, p: Policy = store.policy, now: LocalDateTime = LocalDateTime.now()): Block? {
        if (isEssential(pkg) || paused()) return null
        if (store.lockedByParent) return Block.Locked
        activeSchedule(p, now)?.let { s ->
            if (s.mode == "lock") return Block.Schedule(s.name, s.end)
            if (s.mode == "allowListOnly" && pkg !in p.allowApps) return Block.Schedule(s.name, s.end)
        }
        if (pkg in p.allowApps) return null
        if (pkg in p.blockedApps) return Block.AppBlocked
        val appCat = catalog.appCategory(pkg)
        if (appCat != null && appCat in p.blockedAppCategories) return Block.AppBlocked

        val day = usage.today(p.lateNightFrom, p.lateNightTo)
        val extra = store.extraMinutesToday(LocalDate.now().toString()) * 60_000
        val weekend = now.dayOfWeek.value >= 6
        p.dailyTotalMin(weekend)?.let { if (day.totalMs >= it * 60_000L + extra) return Block.DailyLimit }
        p.perAppMin[pkg]?.let { if ((day.fgMs[pkg] ?: 0) >= it * 60_000L + extra) return Block.AppLimit(it) }
        val cat = usage.category(pkg, catalog.browsers)
        p.perCategoryMin[cat]?.let { lim ->
            val used = day.fgMs.filterKeys { usage.category(it, catalog.browsers) == cat }.values.sum()
            if (used >= lim * 60_000L + extra) return Block.AppLimit(lim)
        }
        return null
    }

    /** Minutes left today overall (for child home + 5/1-minute warnings). null = no limit. */
    fun minutesLeft(p: Policy = store.policy): Long? {
        val lim = p.dailyTotalMin(LocalDateTime.now().dayOfWeek.value >= 6) ?: return null
        val used = usage.today(p.lateNightFrom, p.lateNightTo).totalMs / 60_000
        return (lim + store.extraMinutesToday(LocalDate.now().toString()) - used).coerceAtLeast(0)
    }

    fun appMinutesLeft(pkg: String, p: Policy = store.policy): Long? {
        val lim = p.perAppMin[pkg] ?: return null
        val used = (usage.today(p.lateNightFrom, p.lateNightTo).fgMs[pkg] ?: 0) / 60_000
        return (lim + store.extraMinutesToday(LocalDate.now().toString()) - used).coerceAtLeast(0)
    }
}
