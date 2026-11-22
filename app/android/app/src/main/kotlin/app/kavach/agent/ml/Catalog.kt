package app.kavach.agent.ml

import android.content.Context
import org.json.JSONObject

/**
 * Domain categories (CLS-3), app-package categories (BEH-2/3), surface risk (SENSE-4) and browser
 * selectors (SENSE-3), all from assets/kavach/catalog.json.
 * shortcut: plain sets, not the bloom filter in CLS-3; switch when the domain list passes ~100k entries.
 */
class Catalog(json: String) {
    private val j = JSONObject(json)
    private val domains: Map<String, String> = buildMap {
        val d = j.getJSONObject("domains")
        for (cat in d.keys()) { val a = d.getJSONArray(cat); for (i in 0 until a.length()) put(a.getString(i), cat) }
    }
    private val apps: Map<String, String> = buildMap {
        val d = j.getJSONObject("apps")
        for (cat in d.keys()) { val a = d.getJSONArray(cat); for (i in 0 until a.length()) put(a.getString(i), cat) }
    }
    private val domainKeywords = j.getJSONObject("domainKeywords").let { o -> o.keys().asSequence().associateWith { Regex(o.getString(it)) } }
    val highRisk: Set<String> = j.getJSONArray("highRiskSurfaces").let { a -> (0 until a.length()).map { a.getString(it) }.toSet() }
    val lowRisk: Set<String> = j.getJSONArray("lowRiskSurfaces").let { a -> (0 until a.length()).map { a.getString(it) }.toSet() }
    val urlBarIds: Map<String, String> = j.getJSONObject("urlBarIds").let { o -> o.keys().asSequence().associateWith { o.getString(it) } }
    val searchIds: Set<String> = j.getJSONArray("searchFieldIds").let { a -> (0 until a.length()).map { a.getString(it) }.toSet() }
    val browsers get() = urlBarIds.keys
    val essentialApps: Set<String> = j.getJSONArray("essentialApps").let { a -> (0 until a.length()).map { a.getString(it) }.toSet() }

    /** Category for an eTLD+1-ish host: exact list, then parent domains, then keyword heuristics. */
    fun domainCategory(host: String): String? {
        var h = host.lowercase().removePrefix("www.").removePrefix("m.")
        while (true) {
            domains[h]?.let { return it }
            val dot = h.indexOf('.')
            if (dot < 0 || h.indexOf('.', dot + 1) < 0) break
            h = h.substring(dot + 1)
        }
        return domainKeywords.entries.firstOrNull { it.value.containsMatchIn(host) }?.key
    }

    fun appCategory(pkg: String): String? = apps[pkg]

    companion object {
        fun load(ctx: Context) = Catalog(TextRisk.bundled(ctx, "catalog.json"))

        /** Pulls a host out of address-bar text ("https://m.example.com/x", "example.com/…"). */
        fun hostOf(urlText: String): String? {
            val t = urlText.trim().lowercase()
            if (t.contains(' ') || !t.contains('.')) return null
            val noScheme = t.substringAfter("://")
            val host = noScheme.substringBefore('/').substringBefore('?').substringBefore(':')
            return host.takeIf { Regex("^[a-z0-9.-]+\\.[a-z]{2,}$").matches(it) }
        }

        /** eTLD+1 approximation for upload (CLS-9: domain only, never full URL). Handles co.in / com.au style. */
        fun registrable(host: String): String {
            val parts = host.split('.')
            if (parts.size <= 2) return host
            val sld = parts[parts.size - 2]
            val n = if (sld in setOf("co", "com", "net", "org", "gov", "ac", "edu") && parts.last().length == 2) 3 else 2
            return parts.takeLast(n).joinToString(".")
        }
    }
}
