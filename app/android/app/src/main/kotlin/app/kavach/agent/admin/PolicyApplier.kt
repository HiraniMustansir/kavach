package app.kavach.agent.admin

import android.app.admin.DeviceAdminReceiver
import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.UserManager
import android.util.Log
import app.kavach.agent.Agent

/** Tier A device-owner policy set (design §3.7) and Tier B device-admin hooks. */
object PolicyApplier {
    private val RESTRICTIONS = listOf(
        UserManager.DISALLOW_SAFE_BOOT, UserManager.DISALLOW_FACTORY_RESET, UserManager.DISALLOW_ADD_USER,
        UserManager.DISALLOW_DEBUGGING_FEATURES, UserManager.DISALLOW_CONFIG_DATE_TIME,
        UserManager.DISALLOW_INSTALL_UNKNOWN_SOURCES_GLOBALLY,
    )

    fun admin(ctx: Context) = ComponentName(ctx, KavachAdminReceiver::class.java)
    private fun dpm(ctx: Context) = ctx.getSystemService(DevicePolicyManager::class.java)
    fun isDeviceOwner(ctx: Context) = dpm(ctx).isDeviceOwnerApp(ctx.packageName)
    fun isAdmin(ctx: Context) = dpm(ctx).isAdminActive(admin(ctx))

    fun applyTierA(ctx: Context) = runCatching {
        val d = dpm(ctx); val a = admin(ctx)
        d.setUninstallBlocked(a, ctx.packageName, true) // TMP-1
        RESTRICTIONS.forEach { d.addUserRestriction(a, it) } // TMP-2
        // TMP-3: our service plus whatever system a11y services are already on (TalkBack users keep TalkBack).
        val enabled = (android.provider.Settings.Secure.getString(ctx.contentResolver, android.provider.Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES) ?: "")
            .split(':').mapNotNull { ComponentName.unflattenFromString(it)?.packageName }
        d.setPermittedAccessibilityServices(a, (enabled + ctx.packageName).distinct())
        if (Build.VERSION.SDK_INT >= 33) {
            d.setPermissionGrantState(a, ctx.packageName, android.Manifest.permission.POST_NOTIFICATIONS, DevicePolicyManager.PERMISSION_GRANT_STATE_GRANTED)
        }
    }.onFailure { Log.w(Agent.TAG, "tier A policies", it) }

    /** Watchdog: put back any restriction that went missing. */
    fun ensure(ctx: Context) {
        val um = ctx.getSystemService(UserManager::class.java)
        if (RESTRICTIONS.any { !um.hasUserRestriction(it) } || !dpm(ctx).isUninstallBlocked(admin(ctx), ctx.packageName)) applyTierA(ctx)
    }

    /** CTL-3 Tier A: blocked apps are suspended (greyed out) instead of overlaid. */
    fun syncSuspended(ctx: Context, agent: Agent) = runCatching {
        val p = agent.store.policy
        val installed = ctx.packageManager.getInstalledApplications(0).map { it.packageName }.toSet()
        val want = installed.filter { pkg ->
            !agent.enforcer.isEssential(pkg) && (pkg in p.blockedApps || agent.catalog.appCategory(pkg) in p.blockedAppCategories) && pkg !in p.allowApps
        }
        val prev = agent.ctx.getSharedPreferences("kavach_suspended", Context.MODE_PRIVATE)
        val before = prev.getStringSet("pkgs", emptySet())!!
        val release = (before - want.toSet()).filter { it in installed }
        if (release.isNotEmpty()) dpm(ctx).setPackagesSuspended(admin(ctx), release.toTypedArray(), false)
        if (want.isNotEmpty()) dpm(ctx).setPackagesSuspended(admin(ctx), want.toTypedArray(), true)
        prev.edit().putStringSet("pkgs", want.toSet()).apply()
    }.onFailure { Log.w(Agent.TAG, "suspend", it) }

    /** TMP-4(b): blind without accessibility → suspend every launchable non-essential app until it's back. */
    fun suspendAllNonEssential(ctx: Context, agent: Agent, on: Boolean) = runCatching {
        val launchable = ctx.packageManager.queryIntentActivities(Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER), 0)
            .map { it.activityInfo.packageName }.distinct().filter { !agent.enforcer.isEssential(it) }
        dpm(ctx).setPackagesSuspended(admin(ctx), launchable.toTypedArray(), on)
        if (!on) syncSuspended(ctx, agent) // keep the policy-blocked ones suspended
    }.onFailure { Log.w(Agent.TAG, "suspend all", it) }

    fun lockNow(ctx: Context) { if (isAdmin(ctx)) runCatching { dpm(ctx).lockNow() } }

    /** PAIR-6: undo everything; in Tier A also give up device ownership so the phone is fully normal. */
    fun release(ctx: Context) {
        val d = dpm(ctx); val a = admin(ctx)
        if (isDeviceOwner(ctx)) runCatching {
            RESTRICTIONS.forEach { d.clearUserRestriction(a, it) }
            d.setUninstallBlocked(a, ctx.packageName, false)
            d.setPermittedAccessibilityServices(a, null)
            val launchable = ctx.packageManager.getInstalledApplications(0).map { it.packageName }
            d.setPackagesSuspended(a, launchable.toTypedArray(), false)
            @Suppress("DEPRECATION") d.clearDeviceOwnerApp(ctx.packageName)
        }.onFailure { Log.w(Agent.TAG, "release DO", it) }
        if (isAdmin(ctx)) runCatching { d.removeActiveAdmin(a) }
    }
}

class KavachAdminReceiver : DeviceAdminReceiver() {
    /** TMP-5: parent is told before deactivation completes. */
    override fun onDisableRequested(ctx: Context, intent: Intent): CharSequence {
        Agent.get(ctx).signal("admin_disable_requested")
        return ctx.getString(app.kavach.R.string.admin_disable_warning)
    }

    override fun onDisabled(ctx: Context, intent: Intent) {
        val agent = Agent.get(ctx)
        if (agent.store.paired) agent.setHealth("degraded", "Device admin was turned off")
    }

    /** Tier A QR provisioning finished: the pairing token arrives in the admin extras bundle (PAIR-2). */
    override fun onProfileProvisioningComplete(ctx: Context, intent: Intent) {
        val extras = if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(DevicePolicyManager.EXTRA_PROVISIONING_ADMIN_EXTRAS_BUNDLE, android.os.PersistableBundle::class.java)
        else @Suppress("DEPRECATION") intent.getParcelableExtra(DevicePolicyManager.EXTRA_PROVISIONING_ADMIN_EXTRAS_BUNDLE)
        extras?.getString("pairing_token")?.let { Agent.get(ctx).store.pendingPairingToken = it }
        PolicyApplier.applyTierA(ctx)
        ctx.startActivity(Intent(ctx, app.kavach.MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
}
