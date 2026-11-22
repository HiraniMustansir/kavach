package app.kavach.agent.a11y

import android.app.Notification
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import app.kavach.agent.Agent

/**
 * SENSE-8 (optional, consent-gated via policy.monitoring.notifText): message previews are classified
 * for grooming/sextortion/bullying signals and discarded immediately; nothing is stored.
 */
class KavachNotificationListener : NotificationListenerService() {
    override fun onNotificationPosted(sbn: StatusBarNotification) {
        val agent = Agent.get(this)
        if (!agent.store.paired || sbn.packageName == packageName) return
        val notifOn = agent.store.policy.json.optJSONObject("monitoring")?.optBoolean("notifText", false) ?: false
        if (!notifOn || sbn.packageName !in agent.catalog.highRisk) return
        val ex = sbn.notification.extras
        val text = listOfNotNull(ex.getCharSequence(Notification.EXTRA_TITLE), ex.getCharSequence(Notification.EXTRA_TEXT),
            ex.getCharSequence(Notification.EXTRA_BIG_TEXT)).joinToString(" ")
        if (text.isBlank()) return
        val label = agent.usage.label(sbn.packageName)
        agent.io.execute { agent.risk.onText(sbn.packageName, label, text, typed = false, domain = null) }
    }
}
