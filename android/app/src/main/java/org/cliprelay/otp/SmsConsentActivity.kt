package org.cliprelay.otp

// Transparent activity that shows the system SMS-consent dialog. On approval it
// receives the full SMS, extracts only the OTP, and relays that code to the Mac
// over the existing clipboard-push path — the full message never leaves the phone.

import android.app.Activity
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import com.google.android.gms.auth.api.phone.SmsRetriever
import org.cliprelay.service.ClipRelayService

class SmsConsentActivity : ComponentActivity() {
    companion object {
        private const val TAG = "SmsOtp"
        const val EXTRA_CONSENT_INTENT = "consent_intent"
    }

    private val consentLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result ->
        if (result.resultCode == Activity.RESULT_OK) {
            relayOtp(result.data?.getStringExtra(SmsRetriever.EXTRA_SMS_MESSAGE))
        }
        // Reopen the window for the next code, then close.
        SmsOtpController.armIfEnabled(this)
        finish()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val consentIntent: Intent? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(EXTRA_CONSENT_INTENT, Intent::class.java)
        } else {
            @Suppress("DEPRECATION") intent.getParcelableExtra(EXTRA_CONSENT_INTENT)
        }
        if (consentIntent == null) {
            finish()
            return
        }
        runCatching { consentLauncher.launch(consentIntent) }
            .onFailure {
                Log.w(TAG, "Could not show SMS consent dialog", it)
                finish()
            }
    }

    private fun relayOtp(message: String?) {
        if (message.isNullOrBlank()) return
        val otp = OtpExtractor.extract(message) ?: return
        Log.i(TAG, "OTP extracted from consented SMS, relaying to Mac")
        val push = Intent(this, ClipRelayService::class.java).apply {
            action = ClipRelayService.ACTION_PUSH_TEXT
            putExtra(ClipRelayService.EXTRA_TEXT, otp)
        }
        runCatching { startService(push) }
            .onFailure { Log.w(TAG, "Could not relay OTP to service", it) }
    }
}
