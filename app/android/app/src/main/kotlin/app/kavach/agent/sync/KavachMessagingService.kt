package app.kavach.agent.sync

import app.kavach.agent.Agent
import com.google.firebase.messaging.RemoteMessage
import io.flutter.plugins.firebase.messaging.FlutterFirebaseMessagingService

/**
 * Replaces the plugin's FCM service (manifest tools:node="remove") so data pushes wake the native agent
 * even when Flutter isn't running; everything is still forwarded to Flutter for parent-mode handling.
 */
class KavachMessagingService : FlutterFirebaseMessagingService() {
    override fun onMessageReceived(remoteMessage: RemoteMessage) {
        val agent = Agent.get(applicationContext)
        if (agent.store.paired) {
            when (remoteMessage.data["kind"]) {
                "command", "sync_policy" -> SyncWorker.now(applicationContext)
                "account_deleted" -> SyncWorker.now(applicationContext) // sync sees "unknown device" and starts the orphan clock
            }
            return // child phones never show parent notifications
        }
        super.onMessageReceived(remoteMessage)
    }

    override fun onNewToken(token: String) {
        val agent = Agent.get(applicationContext)
        agent.store.fcmToken = token
        if (agent.store.paired) SyncWorker.now(applicationContext)
        super.onNewToken(token)
    }
}
