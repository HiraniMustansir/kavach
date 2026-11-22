package app.kavach.agent.core

import java.security.SecureRandom

/** ULID (Crockford base32, 26 chars): sortable, idempotent event ids for the server upsert. */
object Ulid {
    private const val ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
    private val rnd = SecureRandom()

    fun next(ms: Long = System.currentTimeMillis()): String {
        val sb = StringBuilder(26)
        var t = ms
        val time = CharArray(10)
        for (i in 9 downTo 0) { time[i] = ALPHABET[(t and 31).toInt()]; t = t shr 5 }
        sb.append(time)
        val r = ByteArray(10).also { rnd.nextBytes(it) }
        // 80 random bits → 16 chars of 5 bits
        var acc = 0L; var bits = 0; var idx = 0
        repeat(16) {
            while (bits < 5) { acc = (acc shl 8) or (r[idx++].toLong() and 0xff); bits += 8 }
            bits -= 5
            sb.append(ALPHABET[((acc shr bits) and 31).toInt()])
        }
        return sb.toString()
    }
}
