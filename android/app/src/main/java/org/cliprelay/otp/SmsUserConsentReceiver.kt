package org.cliprelay.otp

// Receives the SMS User Consent broadcast from Google Play services. On a match,
// launches SmsConsentActivity to show the one-tap consent dialog; on timeout,
// re-arms so the feature keeps listening.

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import com.google.android.gms.auth.api.phone.SmsRetriever
import com.google.android.gms.common.api.CommonStatusCodes
import com.google.android.gms.common.api.Status
import org.cliprelay.service.ClipRelayService
import org.cliprelay.settings.ClipboardSettingsStore

class SmsUserConsentReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "SmsOtp"
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != SmsRetriever.SMS_RETRIEVED_ACTION) return
        if (!ClipboardSettingsStore(context).isOtpRelayEnabled()) return

        val extras = intent.extras ?: return
        val status: Status? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            extras.getParcelable(SmsRetriever.EXTRA_STATUS, Status::class.java)
        } else {
            @Suppress("DEPRECATION") extras.getParcelable(SmsRetriever.EXTRA_STATUS)
        }

        when (status?.statusCode) {
            CommonStatusCodes.SUCCESS -> {
                // Connection may have dropped during the window — don't prompt if
                // there's no Mac to receive the code.
                if (!ClipRelayService.anyMacConnected) return
                val consentIntent: Intent? =
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        extras.getParcelable(SmsRetriever.EXTRA_CONSENT_INTENT, Intent::class.java)
                    } else {
                        @Suppress("DEPRECATION")
                        extras.getParcelable(SmsRetriever.EXTRA_CONSENT_INTENT)
                    }
                if (consentIntent == null) return
                val launch = Intent(context, SmsConsentActivity::class.java).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    putExtra(SmsConsentActivity.EXTRA_CONSENT_INTENT, consentIntent)
                }
                runCatching { context.startActivity(launch) }
                    .onFailure { Log.w(TAG, "Could not launch consent activity", it) }
            }
            CommonStatusCodes.TIMEOUT -> {
                // Window expired with no matching SMS — reopen it if still eligible.
                SmsOtpController.armIfEligible(context)
            }
        }
    }
}
