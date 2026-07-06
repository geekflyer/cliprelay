package org.cliprelay.otp

// Arms the SMS User Consent listener. Each call opens one ~5-minute window that
// ends on the first matching SMS (or times out); we re-arm on both to keep
// listening while the feature is on.

import android.content.Context
import android.util.Log
import com.google.android.gms.auth.api.phone.SmsRetriever
import org.cliprelay.settings.ClipboardSettingsStore

object SmsOtpController {
    private const val TAG = "SmsOtp"

    /** Open a single SMS User Consent window. null sender = accept any number. */
    fun arm(context: Context) {
        runCatching {
            SmsRetriever.getClient(context.applicationContext).startSmsUserConsent(null)
        }.onSuccess {
            Log.i(TAG, "SMS user-consent listener armed")
        }.onFailure {
            // No Google Play services, or GMS declined — feature silently unavailable.
            Log.w(TAG, "Failed to arm SMS user-consent listener", it)
        }
    }

    fun armIfEnabled(context: Context) {
        if (ClipboardSettingsStore(context).isOtpRelayEnabled()) arm(context)
    }
}
