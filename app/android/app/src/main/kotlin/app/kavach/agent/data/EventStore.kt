package app.kavach.agent.data

import android.content.ContentValues
import android.content.Context
import android.util.Base64
import app.kavach.agent.core.Crypto
import net.zetetic.database.sqlcipher.SQLiteDatabase
import org.json.JSONObject
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec

/** A risk event as stored locally and uploaded (design §3.8). Never holds pixels or screen text. */
data class RiskEvent(
    val id: String, val tsWall: Long, val tsElapsed: Long, val category: String, val severity: String,
    val score: Double, val pkg: String, val appLabel: String?, val domain: String?, val durationS: Int?,
    val description: String, val customKeyword: String?,
) {
    fun toJson() = JSONObject().put("id", id).put("ts", tsWall).put("category", category).put("severity", severity)
        .put("score", score).put("pkg", pkg).put("appLabel", appLabel).put("domain", domain)
        .put("durationS", durationS).put("description", description).put("customKeyword", customKeyword)
}

/** SQLCipher-encrypted offline queue (ALR-6) + per-day counters for the digest. */
class EventStore private constructor(ctx: Context) {
    private val db: SQLiteDatabase

    init {
        System.loadLibrary("sqlcipher")
        val file = ctx.getDatabasePath("kavach.db").apply { parentFile?.mkdirs() }
        db = SQLiteDatabase.openOrCreateDatabase(file, passphrase(ctx), null, null, null)
        db.execSQL("""CREATE TABLE IF NOT EXISTS risk_event (
            id TEXT PRIMARY KEY, ts_wall INTEGER NOT NULL, ts_elapsed INTEGER NOT NULL, category TEXT NOT NULL,
            severity TEXT NOT NULL, score REAL NOT NULL, pkg TEXT NOT NULL, app_label TEXT, domain TEXT,
            duration_s INTEGER, description TEXT NOT NULL, custom_keyword TEXT, synced INTEGER DEFAULT 0)""")
        db.execSQL("CREATE INDEX IF NOT EXISTS ev_sync ON risk_event(synced, ts_wall)")
        db.execSQL("CREATE TABLE IF NOT EXISTS counter (day TEXT, k TEXT, n INTEGER, PRIMARY KEY(day, k))")
    }

    @Synchronized fun add(e: RiskEvent) {
        db.insertWithOnConflict("risk_event", null, ContentValues().apply {
            put("id", e.id); put("ts_wall", e.tsWall); put("ts_elapsed", e.tsElapsed); put("category", e.category)
            put("severity", e.severity); put("score", e.score); put("pkg", e.pkg); put("app_label", e.appLabel)
            put("domain", e.domain); put("duration_s", e.durationS); put("description", e.description)
            put("custom_keyword", e.customKeyword)
        }, android.database.sqlite.SQLiteDatabase.CONFLICT_IGNORE)
    }

    @Synchronized fun unsynced(limit: Int = 100): List<RiskEvent> = query("synced = 0 ORDER BY ts_wall LIMIT $limit", emptyArray())

    @Synchronized fun since(fromWall: Long): List<RiskEvent> = query("ts_wall >= ? ORDER BY ts_wall", arrayOf(fromWall.toString()))

    @Synchronized fun markSynced(ids: Collection<String>) {
        if (ids.isEmpty()) return
        db.execSQL("UPDATE risk_event SET synced = 1 WHERE id IN (${ids.joinToString(",") { "?" }})", ids.toTypedArray())
    }

    @Synchronized fun bump(day: String, key: String, by: Int = 1) {
        db.execSQL("INSERT INTO counter(day, k, n) VALUES(?, ?, ?) ON CONFLICT(day, k) DO UPDATE SET n = n + excluded.n", arrayOf<Any>(day, key, by))
    }

    @Synchronized fun counters(day: String): Map<String, Int> = db.rawQuery("SELECT k, n FROM counter WHERE day = ?", arrayOf(day)).use { c ->
        buildMap { while (c.moveToNext()) put(c.getString(0), c.getInt(1)) }
    }

    /** Retention: synced events 14 days, counters 30 days (design §3.8). */
    @Synchronized fun prune(now: Long = System.currentTimeMillis()) {
        db.execSQL("DELETE FROM risk_event WHERE synced = 1 AND ts_wall < ?", arrayOf(now - 14 * 86_400_000L))
        db.execSQL("DELETE FROM risk_event WHERE ts_wall < ?", arrayOf(now - 30 * 86_400_000L))
        db.execSQL("DELETE FROM counter WHERE day < date('now', '-30 day')")
    }

    @Synchronized fun wipe() { db.execSQL("DELETE FROM risk_event"); db.execSQL("DELETE FROM counter") }

    private fun query(where: String, args: Array<String>): List<RiskEvent> =
        db.rawQuery("SELECT id, ts_wall, ts_elapsed, category, severity, score, pkg, app_label, domain, duration_s, description, custom_keyword FROM risk_event WHERE $where", args).use { c ->
            buildList {
                while (c.moveToNext()) add(RiskEvent(c.getString(0), c.getLong(1), c.getLong(2), c.getString(3), c.getString(4),
                    c.getDouble(5), c.getString(6), c.getString(7), c.getString(8), if (c.isNull(9)) null else c.getInt(9),
                    c.getString(10), c.getString(11)))
            }
        }

    companion object {
        @Volatile private var inst: EventStore? = null
        fun get(ctx: Context) = inst ?: synchronized(this) { inst ?: EventStore(ctx).also { inst = it } }

        /** Random 32-byte passphrase, stored wrapped by a Keystore AES-GCM key. */
        private fun passphrase(ctx: Context): ByteArray {
            val p = ctx.getSharedPreferences("kavach_db_key", Context.MODE_PRIVATE)
            val key = Crypto.dbWrapKey()
            p.getString("wrapped", null)?.let { s ->
                val raw = Base64.decode(s, Base64.NO_WRAP)
                val c = Cipher.getInstance("AES/GCM/NoPadding")
                c.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, raw.copyOfRange(0, 12)))
                return c.doFinal(raw.copyOfRange(12, raw.size))
            }
            val pass = ByteArray(32).also { SecureRandom().nextBytes(it) }
            val c = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key) }
            p.edit().putString("wrapped", Base64.encodeToString(c.iv + c.doFinal(pass), Base64.NO_WRAP)).apply()
            return pass
        }
    }
}
