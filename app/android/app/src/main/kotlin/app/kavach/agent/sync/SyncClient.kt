package app.kavach.agent.sync

import app.kavach.BuildConfig
import app.kavach.agent.core.Crypto
import app.kavach.agent.core.Store
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

class ApiException(val status: Int, message: String) : Exception(message)

/** Signed calls to the `device` Edge Function (design §4.2). Blocking: call from a worker thread. */
class SyncClient(private val store: Store) {
    private val base = "${BuildConfig.SUPABASE_URL}/functions/v1/device"

    fun pairComplete(token: String, pubkey: String, info: JSONObject): JSONObject =
        call("POST", "pair-complete", info.put("token", token).put("pubkey", pubkey), signed = false)

    fun post(route: String, body: JSONObject): JSONObject = call("POST", route, body, signed = true)
    fun get(route: String): JSONObject = call("GET", route, null, signed = true)

    private fun call(method: String, route: String, body: JSONObject?, signed: Boolean): JSONObject {
        val payload = body?.toString() ?: ""
        val conn = URL("$base/$route").openConnection() as HttpURLConnection
        try {
            conn.requestMethod = method
            conn.connectTimeout = 15_000; conn.readTimeout = 20_000
            conn.setRequestProperty("content-type", "application/json")
            conn.setRequestProperty("apikey", BuildConfig.SUPABASE_KEY)
            if (signed) {
                val id = store.deviceId ?: throw ApiException(0, "not paired")
                val ts = (System.currentTimeMillis() + store.serverSkewMs).toString() // TMP-9
                val nonce = Crypto.nonce()
                conn.setRequestProperty("x-device-id", id)
                conn.setRequestProperty("x-ts", ts)
                conn.setRequestProperty("x-nonce", nonce)
                conn.setRequestProperty("x-sig", Crypto.sign("$method|$route|$ts|$nonce|${Crypto.sha256Hex(payload)}"))
            }
            if (method == "POST") {
                conn.doOutput = true
                conn.outputStream.use { it.write(payload.toByteArray()) }
            }
            val code = conn.responseCode
            val text = (if (code < 400) conn.inputStream else conn.errorStream)?.bufferedReader()?.use { it.readText() } ?: ""
            val json = runCatching { JSONObject(text) }.getOrDefault(JSONObject())
            if (code >= 400) throw ApiException(code, json.optString("error", "http $code"))
            return json
        } finally {
            conn.disconnect()
        }
    }
}
