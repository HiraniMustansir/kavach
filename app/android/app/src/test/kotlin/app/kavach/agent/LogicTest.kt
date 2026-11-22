package app.kavach.agent

import app.kavach.agent.core.BundleManager
import app.kavach.agent.core.Policy
import app.kavach.agent.core.Ulid
import app.kavach.agent.ml.Catalog
import app.kavach.agent.ml.GroomingWindow
import app.kavach.agent.ml.TextRisk
import app.kavach.agent.risk.Fusion
import app.kavach.agent.risk.TemporalSmoother
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class LogicTest {
    private val assets = File("src/main/assets/kavach")
    private val text = TextRisk(File(assets, "lexicon.json").readText())
    private val catalog = Catalog(File(assets, "catalog.json").readText())

    @Test fun normalizeHandlesLeetEmojiAndRepeats() {
        assertEquals("porn", TextRisk.normalize("P0RN"))
        assertEquals("sex 2024", TextRisk.normalize("s3x 2024")) // numbers stay numbers
        assertTrue(TextRisk.normalize("🔪").contains("knife"))
        assertEquals("soo", TextRisk.normalize("sooooo"))
    }

    @Test fun lexiconFindsEnglishHinglishAndHindi() {
        assertTrue(text.score("how to kill myself painless").scores.getValue("SELF") > 0.8)
        assertTrue(text.score("main marna chahta hoon").scores.containsKey("SELF"))
        assertTrue(text.score("मैं आत्महत्या").scores.containsKey("SELF"))
        assertTrue(text.score("kisi ko mat batana, apni photo bhejo").scores.getValue("CSE") > 0.7)
        assertTrue(text.score("watch free diamond generator").scores.containsKey("SCAM"))
    }

    @Test fun hardNegativesStayQuiet() {
        // cricket, cooking, biology class, gaming talk (PRD §10.2 hard negatives)
        for (s in listOf("India won by 6 wickets, what a shot", "chicken curry recipe: cut the meat into pieces",
                "Class 8 biology: human reproductive system chapter", "BGMI headshot clutch in final circle")) {
            val r = text.score(s)
            assertTrue("$s → ${r.scores}", r.scores.values.all { it < 0.5 })
        }
    }

    @Test fun groomingEscalatesAcrossMessages() {
        val g = GroomingWindow()
        val t0 = 1_000_000L
        assertEquals(0.0, g.observe("org.telegram.messenger", text.score("how old are you").lexIds, t0), 0.0)
        assertEquals(0.7, g.observe("org.telegram.messenger", text.score("don't tell your parents").lexIds, t0 + 60_000), 0.0)
        assertTrue(g.observe("org.telegram.messenger", text.score("send me a pic of you").lexIds, t0 + 120_000) > 0.9)
    }

    @Test fun adultDomainAloneIsHighForBothBands() {
        val s = Fusion.fuse(Fusion.Signals(urlPrior = 3.5), "balanced", 0.0)
        assertEquals("high", Fusion.severity("SEX", s, "child"))
        assertEquals("high", Fusion.severity("SEX", s, "teen"))
    }

    @Test fun sensitivityAndFeedbackShiftScores() {
        val base = Fusion.fuse(Fusion.Signals(txt = 0.6), "balanced", 0.0)
        assertTrue(Fusion.fuse(Fusion.Signals(txt = 0.6), "strict", 0.0) > base)
        assertTrue(Fusion.fuse(Fusion.Signals(txt = 0.6), "relaxed", 0.0) < base)
        assertTrue(Fusion.fuse(Fusion.Signals(txt = 0.6), "balanced", 1.0) < base) // parent said "not a problem"
        assertEquals(0.0, Fusion.fuse(Fusion.Signals(), "balanced", 0.0), 0.0)
    }

    @Test fun severityCapsAndBands() {
        assertEquals("medium", Fusion.severity("SCAM", 0.99, "child"))
        assertNull(Fusion.severity("HORROR", 0.99, "teen"))
        assertEquals("critical", Fusion.severity("SELF", 0.9, "teen"))
    }

    @Test fun smootherNeedsTwoHitsOrOneVeryStrong() {
        val s = TemporalSmoother()
        assertFalse(s.admit("SEX", "chrome", 0.9, true, 0))
        assertTrue(s.admit("SEX", "chrome", 0.9, true, 5_000))
        assertFalse(s.admit("GORE", "yt", 0.9, true, 0))
        assertFalse(s.admit("GORE", "yt", 0.9, true, 30_000)) // outside 20 s window
        assertTrue(s.admit("GORE", "x", 0.98, true, 0))
    }

    @Test fun windowsWrapMidnight() {
        assertTrue(Policy.inWindow(23 * 60, 21 * 60 + 30, 6 * 60 + 30))
        assertTrue(Policy.inWindow(60, 21 * 60 + 30, 6 * 60 + 30))
        assertFalse(Policy.inWindow(12 * 60, 21 * 60 + 30, 6 * 60 + 30))
        assertEquals(510, Policy.hm("08:30"))
    }

    @Test fun domainsAndHosts() {
        assertEquals("m.example.co.in", Catalog.hostOf("https://m.example.co.in/path?q=1"))
        assertNull(Catalog.hostOf("how to tie a tie"))
        assertEquals("example.co.in", Catalog.registrable("m.example.co.in"))
        assertEquals("adult", catalog.domainCategory("www.pornhub.com"))
        assertEquals("adult", catalog.domainCategory("de.xhamster.com"))
        assertEquals("gambling", catalog.domainCategory("ind.1xbet.com"))
        assertNull(catalog.domainCategory("khanacademy.org"))
        assertEquals("vault", catalog.appCategory("com.domobile.applockwatcher"))
    }

    @Test fun ulidMatchesServerFormat() {
        val ids = (1..200).map { Ulid.next(1_700_000_000_000L + it) }
        assertTrue(ids.all { Regex("^[0-9A-HJKMNP-TV-Z]{26}$").matches(it) })
        assertEquals(ids, ids.sorted()) // time-ordered
    }

    @Test fun bundleSignatureFromToolVerifiesWithPinnedKey() {
        // Produced by tools/bundle.ts signManifest() with ~/.kavach-keys/bundle-signing.pem.
        val m = """{"version":"test-1","files":[{"name":"lexicon.json","sha256":"ab","size":1}]}"""
        val sig = "MEQCIBX0Tir/xnkGJBgEDn0jt7xwB7HZGhFnYxPlo+Sd64GrAiAZ0Z3RlTXLeuhHy64nhMQ2Za3jB5gqvAz9oufg87P5yA=="
        assertTrue(BundleManager.verify(m, sig))
        assertFalse(BundleManager.verify(m.replace("test-1", "test-2"), sig)) // tampered manifest
        assertFalse(BundleManager.verify(m, "AAAA"))
    }
}
