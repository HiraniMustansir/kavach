package app.kavach.agent.risk

import android.os.SystemClock
import app.kavach.agent.core.Policy
import app.kavach.agent.core.Store
import app.kavach.agent.core.Ulid
import app.kavach.agent.data.EventStore
import app.kavach.agent.data.RiskEvent
import app.kavach.agent.ml.Catalog
import app.kavach.agent.ml.GroomingWindow
import app.kavach.agent.ml.TextRisk
import java.time.LocalDate

/**
 * Turns signals into RiskEvents (design §3.2 Fusion → Smoother → RuleEngine → EventQueue).
 * Only labels, scores, app, domain and a generated content-free description are kept (CLS-9).
 */
/** Called from the a11y thread, the notification listener and receivers: every entry point is @Synchronized. */
class RiskEngine(
    private val store: Store, private val events: EventStore, private val text: TextRisk, private val catalog: Catalog,
    private val onEvent: (RiskEvent, Policy.Cat?) -> Unit,
) {
    private val smoother = TemporalSmoother()
    private val grooming = GroomingWindow()
    private val lastEmit = HashMap<String, Long>()
    private val incognitoUntil = HashMap<String, Long>()
    private val blockedHits = ArrayDeque<Long>()
    @Volatile var lastRiskAt = 0L; private set

    private val urlPriors = mapOf(
        "adult" to ("SEX" to 3.5), "gambling" to ("GAMB" to 3.0), "gore" to ("GORE" to 3.0),
        "drugs" to ("DRUG" to 2.0), "dating" to ("STRNG" to 1.5),
    )

    private val band get() = store.ageBand ?: "child"
    private fun today() = LocalDate.now().toString()

    private fun appPrior(pkg: String): Double = when {
        pkg in catalog.lowRisk -> -1.5
        catalog.appCategory(pkg) in setOf("vault", "second_space") -> 0.5
        else -> 0.0
    }

    /** Visible page text (weight 0.8) or something the child typed/searched (weight 1.0, SENSE-9). */
    @Synchronized fun onText(pkg: String, label: String, raw: String, typed: Boolean, domain: String?) {
        val p = store.policy
        if (skip(pkg, domain, p)) return
        val lower = TextRisk.normalize(raw)

        // Parent custom keywords (CUSTOM): the only case where the matched words leave the device.
        for (k in p.keywords) {
            val hit = if (k.fuzzy) lower.replace(" ", "").contains(k.text.replace(" ", "")) else Regex("\\b${Regex.escape(k.text)}\\b").containsMatchIn(lower)
            if (hit) emit("CUSTOM", if (k.action == "digest") "low" else "high", 1.0, pkg, label, domain,
                "Your keyword appeared in $label", k.text)
        }
        if (catalog.browsers.contains(pkg) && (lower.contains("incognito") || lower.contains("private tab") || lower.contains("इनकॉग्निटो"))) {
            if ((incognitoUntil[pkg] ?: 0) < System.currentTimeMillis()) events.bump(today(), "incognito")
            incognitoUntil[pkg] = System.currentTimeMillis() + 10 * 60_000
        }
        if (!p.screenAi) return

        val r = text.score(lower, if (typed) 1.0 else 0.8)
        val groom = grooming.observe(pkg, r.lexIds)
        val scores = r.scores.toMutableMap()
        if (groom > 0) scores["CSE"] = maxOf(scores["CSE"] ?: 0.0, groom)
        val url = domain?.let { catalog.domainCategory(it) }?.let { urlPriors[it] }
        for ((cat, s) in scores) {
            val c = p.cat(cat)
            if (!c.enabled) continue
            val fused = Fusion.fuse(Fusion.Signals(txt = s, urlPrior = if (url?.first == cat) url.second else 0.0, appPrior = appPrior(pkg)),
                c.sensitivity, familyOffset(cat))
            val sev = Fusion.severity(cat, fused, band) ?: continue
            emit(cat, sev, fused, pkg, label, domain, describe(cat, label, typed, domain), null)
        }
    }

    /** Domain change in a browser (CLS-3). */
    @Synchronized fun onDomain(pkg: String, label: String, host: String) {
        val p = store.policy
        val reg = Catalog.registrable(host)
        if (p.customDomains[reg] == "alert") emit("CUSTOM", "high", 1.0, pkg, label, reg, "A site you flagged was opened in $label", reg)
        if (skip(pkg, reg, p) || !p.screenAi) return
        val cat = catalog.domainCategory(host) ?: return
        if (cat == "proxy") { emit("BEH", "high", 0.9, pkg, label, reg, "A proxy/unblocker site was opened in $label", null); return }
        val (risk, prior) = urlPriors[cat] ?: return
        val c = p.cat(risk)
        if (!c.enabled) return
        val fused = Fusion.fuse(Fusion.Signals(urlPrior = prior, appPrior = appPrior(pkg)), c.sensitivity, familyOffset(risk))
        val sev = Fusion.severity(risk, fused, band) ?: return
        emit(risk, sev, fused, pkg, label, reg, "${catName(risk)} site opened in $label (site category: $cat)", null)
        if (risk == "SEX" && (incognitoUntil[pkg] ?: 0) > System.currentTimeMillis()) {
            emit("BEH", "high", 0.9, pkg, label, reg, "Explicit site opened in private browsing in $label", null)
        }
    }

    /** One sampled frame's vision scores (M1). Goes through k-of-n smoothing (CLS-5). */
    @Synchronized fun onVision(pkg: String, label: String, scores: Map<String, Double>, domain: String?) {
        val p = store.policy
        if (skip(pkg, domain, p) || !p.screenAi) return
        val url = domain?.let { catalog.domainCategory(it) }?.let { urlPriors[it] }
        for ((cat, s) in scores) {
            if (cat == "SAFE" || cat == "GAMB-UI") continue
            val c = p.cat(cat)
            if (!c.enabled) continue
            val fused = Fusion.fuse(Fusion.Signals(img = s, urlPrior = if (url?.first == cat) url.second else 0.0, appPrior = appPrior(pkg)),
                c.sensitivity, familyOffset(cat))
            val sev = Fusion.severity(cat, fused, band)
            if (fused >= 0.5) lastRiskAt = System.currentTimeMillis()
            val positive = sev == "high" || sev == "critical"
            if (sev == null) { smoother.admit(cat, pkg, fused, false); continue }
            if (positive && !smoother.admit(cat, pkg, fused, true)) continue
            emit(cat, sev, fused, pkg, label, domain, "${catName(cat)} imagery detected in $label" + (domain?.let { " ($it)" } ?: ""), null)
        }
    }

    /** BEH-6: ≥5 blocked attempts in 10 minutes. */
    @Synchronized fun onBlockedAttempt(pkg: String, label: String) {
        val now = System.currentTimeMillis()
        events.bump(today(), "blocked_attempts")
        blockedHits.addLast(now)
        while (blockedHits.isNotEmpty() && now - blockedHits.first() > 10 * 60_000) blockedHits.removeFirst()
        if (blockedHits.size >= 5) {
            blockedHits.clear()
            emit("BEH", "high", 0.9, pkg, label, null, "Repeated attempts to open a blocked app ($label)", null)
        }
    }

    /** BEH-2/3: new app installed. Risky categories alert; everything is listed in the digest. */
    @Synchronized fun onInstalled(pkg: String, label: String) {
        events.bump(today(), "newapp:${label.take(40)}|${catalog.appCategory(pkg) ?: ""}")
        when (catalog.appCategory(pkg)) {
            "vault" -> emit("BEH", "high", 0.9, pkg, label, null, "A hidden-vault app was installed: $label", null)
            "vpn" -> emit("BEH", "high", 0.9, pkg, label, null, "A VPN/proxy app was installed: $label", null)
            "second_space" -> emit("BEH", "high", 0.9, pkg, label, null, "A dual-space/clone app was installed: $label", null)
            "dating" -> emit("STRNG", "high", 0.9, pkg, label, null, "A dating/chat-with-strangers app was installed: $label", null)
            "gambling" -> emit("GAMB", "high", 0.9, pkg, label, null, "A real-money gaming app was installed: $label", null)
        }
    }

    /** BEH-1: once per day when late-night minutes cross the threshold. Medium → pushes for Child band only. */
    @Synchronized fun onLateNightMinutes(minutes: Int) {
        val p = store.policy
        if (minutes >= p.lateNightMinMinutes && (events.counters(today())["late_alerted"] ?: 0) == 0) {
            events.bump(today(), "late_alerted")
            emit("BEH", "medium", 0.8, "android", "Phone", null, "Phone used for $minutes minutes late at night", null)
        }
    }

    @Synchronized fun sos() = emit("SOS", "critical", 1.0, "app.kavach", "Kavach", null, "Child pressed “I need help”", null, dedupe = false)

    private fun skip(pkg: String, domain: String?, p: Policy): Boolean =
        store.pausedUntil > System.currentTimeMillis() || pkg in p.allowApps || pkg in p.excludedFromCapture ||
            (domain != null && (Catalog.registrable(domain) in p.allowDomains || domain in p.allowDomains))

    private fun familyOffset(cat: String) = store.tuning.optDouble(cat, 0.0)

    private fun emit(cat: String, sev: String, score: Double, pkg: String, label: String, domain: String?, desc: String, kw: String?, dedupe: Boolean = true) {
        val now = System.currentTimeMillis()
        val key = "$cat|$pkg|$sev"
        // Same category+app+severity within 60 s is one ongoing event, not many.
        if (dedupe && now - (lastEmit[key] ?: 0) < 60_000) return
        lastEmit[key] = now
        if (sev != "low") lastRiskAt = now
        val e = RiskEvent(Ulid.next(now), now, SystemClock.elapsedRealtime(), cat, sev, score.coerceIn(0.0, 1.0), pkg, label,
            domain?.let { Catalog.registrable(it) }, null, desc.take(200), kw)
        events.add(e)
        onEvent(e, store.policy.cat(cat))
    }

    private fun describe(cat: String, label: String, typed: Boolean, domain: String?) =
        "${catName(cat)}${if (typed) " search or message typed" else " text appeared"} in $label" + (domain?.let { " ($it)" } ?: "")

    companion object {
        fun catName(cat: String) = mapOf(
            "SEX" to "Explicit", "CSE" to "Grooming/sextortion-like", "GORE" to "Graphic violent", "SELF" to "Self-harm related",
            "WEAP" to "Weapons-related", "DRUG" to "Drugs-related", "GAMB" to "Gambling-related", "HATE" to "Hateful",
            "BULLY" to "Bullying", "STRNG" to "Stranger-contact", "SCAM" to "Scam-like", "HORROR" to "Disturbing horror",
        )[cat] ?: cat
    }
}
