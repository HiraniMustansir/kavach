package app.kavach.agent.ml

import android.content.Context
import org.json.JSONObject
import java.text.Normalizer

/**
 * Text risk (CLS-2): normalise → lexicon/regex → per-category noisy-OR score.
 * The M4 multilingual model slots in behind [score] once trained; lexicons ship in assets/lexicon.json
 * and are replaced by signed bundles (CLS-8).
 */
class TextRisk(lexiconJson: String) {
    data class Rule(val id: String, val re: Regex, val w: Double)
    data class Result(val scores: Map<String, Double>, val lexIds: List<String>)

    private val rules: Map<String, List<Rule>>
    val version: String

    init {
        val j = JSONObject(lexiconJson)
        version = j.optString("version", "0")
        val cats = j.getJSONObject("categories")
        rules = cats.keys().asSequence().associateWith { cat ->
            val arr = cats.getJSONObject(cat).getJSONArray("patterns")
            (0 until arr.length()).map { i ->
                val p = arr.getJSONObject(i)
                Rule(p.getString("id"), Regex(p.getString("re"), RegexOption.IGNORE_CASE), p.getDouble("w"))
            }
        }
    }

    /** [weight] < 1 for passive page text, 1.0 for things the child typed or searched (SENSE-9). */
    fun score(raw: String, weight: Double = 1.0): Result {
        val text = normalize(raw)
        val ids = mutableListOf<String>()
        val scores = rules.mapValues { (_, rs) ->
            var miss = 1.0
            for (r in rs) if (r.re.containsMatchIn(text)) { miss *= 1 - r.w * weight; ids += r.id }
            1 - miss
        }.filterValues { it > 0 }
        return Result(scores, ids)
    }

    companion object {
        fun load(ctx: Context) = TextRisk(ctx.assets.open("kavach/lexicon.json").bufferedReader().use { it.readText() })

        private val leet = mapOf('0' to 'o', '1' to 'i', '3' to 'e', '4' to 'a', '5' to 's', '7' to 't', '@' to 'a', '$' to 's')
        private val emoji = mapOf("🍆" to " eggplant ", "🍑" to " peach ", "🔞" to " adult ", "🔪" to " knife ", "🔫" to " gun ",
            "💊" to " pill ", "💉" to " syringe ", "🎰" to " casino ", "💀" to " skull ", "🩸" to " blood ")
        private val zeroWidth = Regex("[\\u200B-\\u200D\\uFEFF]")
        private val repeats = Regex("([a-z])\\1{2,}")
        private val spaces = Regex("\\s+")

        /** Lowercase, NFKC, strip zero-width, emoji → words, leetspeak inside latin words, squeeze "sooooo" → "soo". */
        fun normalize(s: String): String {
            var t = Normalizer.normalize(s, Normalizer.Form.NFKC).lowercase().replace(zeroWidth, "")
            for ((k, v) in emoji) t = t.replace(k, v)
            val sb = StringBuilder(t.length)
            for (i in t.indices) {
                val c = t[i]
                val l = leet[c]
                // only de-leet when sandwiched by letters ("s3x", "p0rn"), so "2024" stays a number
                sb.append(if (l != null && i > 0 && t[i - 1].isLetter() && (i + 1 < t.length && t[i + 1].isLetter() || i + 1 == t.length)) l else c)
            }
            return sb.toString().replace(repeats, "$1$1").replace(spaces, " ").trim()
        }
    }
}

/**
 * Conversation-level grooming escalation (M5 stand-in): distinct CSE/STRNG signal groups seen in the
 * same app within 15 minutes. Contact + secrecy + image request together is the classic pattern.
 */
class GroomingWindow {
    private val hits = HashMap<String, ArrayDeque<Pair<Long, String>>>()

    fun observe(pkg: String, lexIds: List<String>, now: Long = System.currentTimeMillis()): Double {
        val q = hits.getOrPut(pkg) { ArrayDeque() }
        lexIds.filter { it.startsWith("cse_") || it.startsWith("strng_") }.forEach { q.addLast(now to it.substringBeforeLast('_')) }
        while (q.isNotEmpty() && now - q.first().first > 15 * 60_000) q.removeFirst()
        val groups = q.map { it.second }.toSet().size
        return when { groups >= 3 -> 0.92; groups == 2 -> 0.7; else -> 0.0 }
    }
}
