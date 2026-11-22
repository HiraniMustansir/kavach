package app.kavach.agent.risk

import kotlin.math.exp
import kotlin.math.ln

/**
 * Fusion (CLS-4/6) per design §3.5:
 * score = σ(w_img·logit(img) + w_txt·logit(txt) + w_url·url_prior + w_app·app_prior + b_age + b_sens + b_family)
 */
object Fusion {
    data class Signals(
        val img: Double? = null, val txt: Double? = null, val urlPrior: Double = 0.0, val appPrior: Double = 0.0,
    )

    data class Thresholds(val med: Double, val high: Double, val crit: Double?, val childOff: Double, val teenOff: Double)

    val THRESHOLDS = mapOf(
        "SEX" to Thresholds(0.55, 0.80, 0.95, -0.05, 0.05),
        "GORE" to Thresholds(0.60, 0.82, null, -0.05, 0.08),
        "SELF" to Thresholds(0.45, 0.70, 0.85, 0.0, 0.0),
        "CSE" to Thresholds(0.50, 0.75, 0.88, 0.0, 0.0),
        "STRNG" to Thresholds(0.50, 0.75, null, 0.0, 0.0),
    )
    private val DEFAULT = Thresholds(0.65, 0.85, null, -0.05, 0.10)
    // HORROR only matters for the Child band (taxonomy table), BULLY/SCAM cap at medium.
    private val MAX_SEVERITY = mapOf("SCAM" to "medium", "HORROR" to "low", "BULLY" to "medium")

    private const val W_IMG = 1.0; private const val W_TXT = 0.9; private const val W_URL = 1.0; private const val W_APP = 1.0

    fun logit(p: Double): Double { val q = p.coerceIn(1e-4, 1 - 1e-4); return ln(q / (1 - q)) }
    fun sigmoid(x: Double) = 1 / (1 + exp(-x))

    /** Sensitivity slider (CLS-6): Strict lowers the bar, Relaxed raises it. */
    private fun sensOffset(s: String) = when (s) { "strict" -> -0.5; "relaxed" -> 0.6; else -> 0.0 }

    fun fuse(s: Signals, sensitivity: String, familyOffset: Double): Double {
        var x = s.urlPrior * W_URL + s.appPrior * W_APP - sensOffset(sensitivity) - familyOffset.coerceIn(-1.0, 1.0)
        var any = s.urlPrior != 0.0
        s.img?.let { x += W_IMG * logit(it); any = true }
        s.txt?.let { x += W_TXT * logit(it); any = true }
        if (!any) return 0.0
        // With only priors (no img/txt), start from a low base so a domain alone can still cross the bar.
        if (s.img == null && s.txt == null) x += logit(0.2)
        return sigmoid(x)
    }

    /** Severity from the fused score using age-band-adjusted thresholds; null = below medium (digest count only). */
    fun severity(cat: String, score: Double, band: String): String? {
        val t = THRESHOLDS[cat] ?: DEFAULT
        val off = if (band == "teen") t.teenOff else t.childOff
        val sev = when {
            t.crit != null && score >= t.crit + off -> "critical"
            score >= t.high + off -> "high"
            score >= t.med + off -> "medium"
            score >= 0.35 -> "low"
            else -> null
        }
        if (cat == "HORROR" && band == "teen") return null
        val cap = MAX_SEVERITY[cat] ?: return sev
        val order = listOf("low", "medium", "high", "critical")
        return sev?.let { if (order.indexOf(it) > order.indexOf(cap)) cap else it }
    }
}

/** k-of-n smoothing (CLS-5): high/critical from frames needs 2 positives in 20 s, or one frame ≥ 0.97. */
class TemporalSmoother(private val windowMs: Long = 20_000, private val k: Int = 2, private val n: Int = 4) {
    private val ring = HashMap<String, ArrayDeque<Pair<Long, Boolean>>>()

    fun admit(cat: String, pkg: String, score: Double, positive: Boolean, now: Long = System.currentTimeMillis()): Boolean {
        val q = ring.getOrPut("$cat|$pkg") { ArrayDeque() }
        q.addLast(now to positive)
        while (q.size > n) q.removeFirst()
        if (!positive) return false
        if (score >= 0.97) return true
        return q.count { it.second && now - it.first <= windowMs } >= k
    }
}
