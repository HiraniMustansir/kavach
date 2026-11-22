package app.kavach.agent.admin

import android.app.Activity
import android.app.admin.DevicePolicyManager
import android.content.Intent
import android.os.Build
import android.os.Bundle
import app.kavach.agent.Agent

/** Android 10+ QR provisioning asks the DPC which mode it wants: always fully managed (Tier A). */
class ProvisioningModeActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Admin extras are also delivered here; keep the pairing token as early as possible.
        val extras = if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(DevicePolicyManager.EXTRA_PROVISIONING_ADMIN_EXTRAS_BUNDLE, android.os.PersistableBundle::class.java)
        else @Suppress("DEPRECATION") intent.getParcelableExtra(DevicePolicyManager.EXTRA_PROVISIONING_ADMIN_EXTRAS_BUNDLE)
        extras?.getString("pairing_token")?.let { Agent.get(this).store.pendingPairingToken = it }
        setResult(RESULT_OK, Intent().putExtra(DevicePolicyManager.EXTRA_PROVISIONING_MODE, DevicePolicyManager.PROVISIONING_MODE_FULLY_MANAGED_DEVICE))
        finish()
    }
}

/** Runs at the end of setup-wizard provisioning: apply the Tier A policy set, then let setup continue. */
class PolicyComplianceActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val extras = if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(DevicePolicyManager.EXTRA_PROVISIONING_ADMIN_EXTRAS_BUNDLE, android.os.PersistableBundle::class.java)
        else @Suppress("DEPRECATION") intent.getParcelableExtra(DevicePolicyManager.EXTRA_PROVISIONING_ADMIN_EXTRAS_BUNDLE)
        extras?.getString("pairing_token")?.let { Agent.get(this).store.pendingPairingToken = it }
        PolicyApplier.applyTierA(this)
        setResult(RESULT_OK)
        finish()
    }
}
