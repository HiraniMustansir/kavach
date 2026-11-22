package app.kavach.agent.sync

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import app.kavach.agent.Agent
import app.kavach.agent.AgentService
import java.util.concurrent.TimeUnit

/** Periodic (15 min) sync + resurrect of the foreground service (TMP-6), and expedited "send now". */
class SyncWorker(ctx: Context, params: WorkerParameters) : Worker(ctx, params) {
    override fun doWork(): Result {
        val agent = Agent.get(applicationContext)
        if (!agent.store.paired) return Result.success()
        AgentService.start(applicationContext)
        agent.sync()
        return Result.success()
    }

    companion object {
        private val online = Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()

        fun schedule(ctx: Context) {
            WorkManager.getInstance(ctx).enqueueUniquePeriodicWork("kavach-sync", ExistingPeriodicWorkPolicy.KEEP,
                PeriodicWorkRequestBuilder<SyncWorker>(15, TimeUnit.MINUTES).setConstraints(online).build())
        }

        fun now(ctx: Context) {
            WorkManager.getInstance(ctx).enqueueUniqueWork("kavach-sync-now", ExistingWorkPolicy.REPLACE,
                OneTimeWorkRequestBuilder<SyncWorker>().setConstraints(online)
                    .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
                    .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS).build())
        }

        fun cancel(ctx: Context) = WorkManager.getInstance(ctx).cancelAllWork()
    }
}

/** Boot / app update → restart the agent (TMP-6). */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) = AgentService.start(ctx)
}

/** BEH-2/3: new installs are categorised; risky ones alert. */
class PackageReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        if (intent.getBooleanExtra(Intent.EXTRA_REPLACING, false)) return
        val pkg = intent.data?.schemeSpecificPart ?: return
        val agent = Agent.get(ctx)
        if (!agent.store.paired) return
        val pending = goAsync()
        agent.io.execute {
            try {
                agent.risk.onInstalled(pkg, agent.usage.label(pkg))
                if (app.kavach.agent.admin.PolicyApplier.isDeviceOwner(ctx)) app.kavach.agent.admin.PolicyApplier.syncSuspended(ctx, agent)
            } finally { pending.finish() }
        }
    }
}
