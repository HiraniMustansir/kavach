package app.kavach.agent.core

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONObject

/**
 * Agent state. App-private SharedPreferences: nothing secret lives here except what the device key
 * signs (the key itself is in Keystore). shortcut: not encrypted at rest; a rooted phone can read it,
 * which TMP-10 root detection reports. Move to EncryptedFile if counsel/pentest asks.
 */
class Store(ctx: Context) {
    private val p: SharedPreferences = ctx.applicationContext.getSharedPreferences("kavach_agent", Context.MODE_PRIVATE)

    var deviceId: String? by str("device_id")
    var childId: String? by str("child_id")
    var nickname: String? by str("nickname")
    var ageBand: String? by str("age_band")
    var tier: String? by str("tier")
    var pendingPairingToken: String? by str("pending_token")
    var fcmToken: String? by str("fcm_token")
    var policyJson: String? by str("policy")
    var tuningJson: String? by str("tuning")
    var health: String? by str("health")
    var healthReason: String? by str("health_reason")

    var pausedUntil: Long by long("paused_until")
    var lockedByParent: Boolean by bool("locked")
    var extraMinutesDay: String? by str("extra_day")
    var extraMinutes: Long by long("extra_minutes")
    var pinFailures: Long by long("pin_failures")
    var pinLockoutUntil: Long by long("pin_lockout_until")
    var orphanSince: Long by long("orphan_since")
    var lastDigestDay: String? by str("last_digest_day")
    var serverSkewMs: Long by long("server_skew")

    val paired get() = deviceId != null
    val policy: Policy get() = Policy.parse(policyJson)
    val tuning: JSONObject get() = runCatching { JSONObject(tuningJson ?: "{}") }.getOrDefault(JSONObject())

    fun extraMinutesToday(today: String) = if (extraMinutesDay == today) extraMinutes else 0L
    fun addExtraMinutes(today: String, m: Long) {
        extraMinutes = extraMinutesToday(today) + m
        extraMinutesDay = today
    }

    fun clearPairing() = p.edit().clear().apply()

    private fun str(k: String) = object : kotlin.properties.ReadWriteProperty<Any?, String?> {
        override fun getValue(thisRef: Any?, property: kotlin.reflect.KProperty<*>) = p.getString(k, null)
        override fun setValue(thisRef: Any?, property: kotlin.reflect.KProperty<*>, value: String?) = p.edit().putString(k, value).apply()
    }
    private fun long(k: String) = object : kotlin.properties.ReadWriteProperty<Any?, Long> {
        override fun getValue(thisRef: Any?, property: kotlin.reflect.KProperty<*>) = p.getLong(k, 0L)
        override fun setValue(thisRef: Any?, property: kotlin.reflect.KProperty<*>, value: Long) = p.edit().putLong(k, value).apply()
    }
    private fun bool(k: String) = object : kotlin.properties.ReadWriteProperty<Any?, Boolean> {
        override fun getValue(thisRef: Any?, property: kotlin.reflect.KProperty<*>) = p.getBoolean(k, false)
        override fun setValue(thisRef: Any?, property: kotlin.reflect.KProperty<*>, value: Boolean) = p.edit().putBoolean(k, value).apply()
    }
}
