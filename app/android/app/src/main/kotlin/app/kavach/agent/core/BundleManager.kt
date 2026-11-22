package app.kavach.agent.core

import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.KeyFactory
import java.security.MessageDigest
import java.security.Signature
import java.security.spec.X509EncodedKeySpec

/**
 * CLS-8: signed rule/model bundles. Files land in models/staging, every byte is checked against the
 * signed manifest, then staging becomes models/current (previous kept as models/prev for rollback).
 */
object BundleManager {
    /** Public half of ~/.kavach-keys/bundle-signing.pem (ECDSA P-256). Rotating it needs an app update. */
    const val PUBLIC_KEY = "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEjzFsxneFEtaQlxPSHMkWr/mkQkcXkHhVbVZjstldK7Cc0JbalukewU9fpkq0LxDmNw5bZFs2nIwhkavHGEEszg=="
    val ALLOWED = setOf("lexicon.json", "catalog.json", "vision_gate.tflite", "vision_gate.json")

    fun verify(manifestText: String, signatureB64: String, publicKeyB64: String = PUBLIC_KEY): Boolean = runCatching {
        val key = KeyFactory.getInstance("EC").generatePublic(X509EncodedKeySpec(java.util.Base64.getDecoder().decode(publicKeyB64)))
        Signature.getInstance("SHA256withECDSA").run {
            initVerify(key); update(manifestText.toByteArray()); verify(java.util.Base64.getDecoder().decode(signatureB64))
        }
    }.getOrDefault(false)

    private fun sha256(f: File) = MessageDigest.getInstance("SHA-256").let { md ->
        f.inputStream().use { s -> val buf = ByteArray(64 * 1024); while (true) { val n = s.read(buf); if (n < 0) break; md.update(buf, 0, n) } }
        md.digest().joinToString("") { "%02x".format(it) }
    }

    /**
     * Installs [bundle] (heartbeat `bundle` field) into [modelsDir]. Returns true when files changed.
     * Throws on any download/verification failure, leaving models/current untouched.
     */
    fun install(modelsDir: File, bundle: JSONObject): Boolean {
        val manifestText = bundle.getString("manifest")
        require(verify(manifestText, bundle.getString("signature"))) { "bundle signature invalid" }
        val manifest = JSONObject(manifestText)
        require(manifest.getString("version") == bundle.getString("version")) { "version mismatch" }
        val expected = manifest.getJSONArray("files").let { a -> (0 until a.length()).associate { a.getJSONObject(it).let { f -> f.getString("name") to f.getString("sha256") } } }
        require(expected.keys.all { it in ALLOWED }) { "unexpected file in bundle" }
        val urls = bundle.getJSONArray("files").let { a -> (0 until a.length()).associate { a.getJSONObject(it).let { f -> f.getString("name") to f.getString("url") } } }

        val staging = File(modelsDir, "staging").apply { deleteRecursively(); mkdirs() }
        for ((name, hash) in expected) {
            val out = File(staging, name)
            val conn = URL(urls[name] ?: error("no url for $name")).openConnection() as HttpURLConnection
            try {
                conn.connectTimeout = 15_000; conn.readTimeout = 60_000
                require(conn.responseCode == 200) { "download $name: ${conn.responseCode}" }
                conn.inputStream.use { i -> out.outputStream().use { i.copyTo(it) } }
            } finally { conn.disconnect() }
            require(sha256(out) == hash) { "hash mismatch for $name" }
        }
        File(staging, "VERSION").writeText(manifest.getString("version"))
        swap(modelsDir, staging)
        return true
    }

    /** Admin revoked the bundle / rolled this device out: go back to the rules built into the APK. */
    fun clear(modelsDir: File) {
        File(modelsDir, "current").takeIf { it.exists() }?.let { cur ->
            File(modelsDir, "prev").deleteRecursively(); cur.renameTo(File(modelsDir, "prev"))
        }
    }

    /** Undo the last swap when the new files fail to load. */
    fun rollback(modelsDir: File) {
        val cur = File(modelsDir, "current"); val prev = File(modelsDir, "prev")
        cur.deleteRecursively()
        if (prev.exists()) prev.renameTo(cur)
    }

    fun currentVersion(modelsDir: File): String? = File(modelsDir, "current/VERSION").takeIf { it.exists() }?.readText()?.trim()

    private fun swap(modelsDir: File, staging: File) {
        val cur = File(modelsDir, "current"); val prev = File(modelsDir, "prev")
        prev.deleteRecursively()
        if (cur.exists()) check(cur.renameTo(prev)) { "could not move current aside" }
        check(staging.renameTo(cur)) { "could not activate bundle" }
    }
}
