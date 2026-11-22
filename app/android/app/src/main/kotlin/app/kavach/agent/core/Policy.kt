package app.kavach.agent.core

import org.json.JSONArray
import org.json.JSONObject

/** Parsed view of the policy document (design §4.3). Unknown/missing fields fall back to safe defaults. */
class Policy(val json: JSONObject) {
    val version = json.optInt("version", 0)
    val screenAi = json.optJSONObject("monitoring")?.optBoolean("screenAi", true) ?: true

    data class Cat(val enabled: Boolean, val sensitivity: String, val realtime: Boolean, val intervene: String)
    fun cat(code: String): Cat {
        val c = json.optJSONObject("categories")?.optJSONObject(code)
        return Cat(
            enabled = c?.optBoolean("enabled", true) ?: true,
            sensitivity = c?.optString("sensitivity", "balanced") ?: "balanced",
            realtime = c?.optBoolean("realtime", true) ?: true,
            intervene = c?.optString("intervene", "off") ?: "off",
        )
    }

    data class Keyword(val text: String, val fuzzy: Boolean, val action: String)
    val keywords: List<Keyword> = objs(json.optJSONObject("custom")?.optJSONArray("keywords")).map {
        Keyword(it.optString("text").lowercase().trim(), it.optString("match") == "fuzzy", it.optString("action", "alert"))
    }.filter { it.text.isNotEmpty() }

    val customApps: Map<String, String> = objs(json.optJSONObject("custom")?.optJSONArray("apps"))
        .associate { it.optString("pkg") to it.optString("action", "alert") }
    val customDomains: Map<String, String> = objs(json.optJSONObject("custom")?.optJSONArray("domains"))
        .associate { it.optString("domain").lowercase() to it.optString("action", "alert") }

    val allowApps = strs(json.optJSONObject("allow")?.optJSONArray("apps")).toSet()
    val allowDomains = strs(json.optJSONObject("allow")?.optJSONArray("domains")).map { it.lowercase() }.toSet()
    val excludedFromCapture = strs(json.optJSONArray("excludedFromCapture")).toSet()

    val blockedApps = strs(json.optJSONObject("blocked")?.optJSONArray("apps")).toSet() +
        customApps.filterValues { it == "block" }.keys
    val blockedAppCategories = strs(json.optJSONObject("blocked")?.optJSONArray("appCategories")).toSet()
    val blockedDomains = customDomains.filterValues { it == "block" }.keys

    private val limits = json.optJSONObject("limits")
    fun dailyTotalMin(weekend: Boolean): Int? =
        limits?.optJSONObject("dailyTotalMin")?.let { if (it.has(if (weekend) "weekend" else "weekday")) it.optInt(if (weekend) "weekend" else "weekday") else null }
    val perAppMin: Map<String, Int> = limits?.optJSONObject("perAppMin")?.let { o -> o.keys().asSequence().associateWith { o.optInt(it) } } ?: emptyMap()
    val perCategoryMin: Map<String, Int> = limits?.optJSONObject("perCategoryMin")?.let { o -> o.keys().asSequence().associateWith { o.optInt(it) } } ?: emptyMap()

    data class Schedule(val name: String, val days: Set<Int>, val start: Int, val end: Int, val mode: String)
    val schedules: List<Schedule> = objs(json.optJSONArray("schedules")).map {
        Schedule(it.optString("name"), ints(it.optJSONArray("days")).toSet(), hm(it.optString("start", "00:00")), hm(it.optString("end", "00:00")), it.optString("mode", "lock"))
    }

    val lateNightFrom = hm(json.optJSONObject("behaviour")?.optJSONObject("lateNight")?.optString("from", "23:00") ?: "23:00")
    val lateNightTo = hm(json.optJSONObject("behaviour")?.optJSONObject("lateNight")?.optString("to", "05:00") ?: "05:00")
    val lateNightMinMinutes = json.optJSONObject("behaviour")?.optJSONObject("lateNight")?.optInt("minMinutes", 15) ?: 15

    /** PBKDF2 parameters for the parent PIN; null until the parent sets one. */
    val pin: Triple<ByteArray, ByteArray, Int>? = json.optJSONObject("parentPin")?.let {
        Triple(android.util.Base64.decode(it.optString("salt"), 0), android.util.Base64.decode(it.optString("hash"), 0), it.optInt("iter", 120_000))
    }

    companion object {
        fun parse(s: String?): Policy = Policy(runCatching { JSONObject(s ?: "{}") }.getOrDefault(JSONObject()))
        fun hm(s: String): Int = s.split(":").let { (it.getOrNull(0)?.toIntOrNull() ?: 0) * 60 + (it.getOrNull(1)?.toIntOrNull() ?: 0) }
        /** [from, to) in minutes of day, wrapping midnight. */
        fun inWindow(min: Int, from: Int, to: Int) = if (from <= to) min in from until to else min >= from || min < to
        private fun objs(a: JSONArray?) = (0 until (a?.length() ?: 0)).mapNotNull { a!!.optJSONObject(it) }
        private fun strs(a: JSONArray?) = (0 until (a?.length() ?: 0)).mapNotNull { a!!.optString(it).takeIf { s -> s.isNotEmpty() } }
        private fun ints(a: JSONArray?) = (0 until (a?.length() ?: 0)).map { a!!.optInt(it) }
    }
}
