package org.cliprelay.otp

// Experimental: watches incoming notifications (SMS apps, mail, messengers) for
// one-time passcodes and relays them to the paired Mac over the normal
// clipboard push path. No SMS permission needed — Play-policy safe.

import android.app.Notification
import android.content.Context
import android.content.Intent
import android.os.SystemClock
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import org.cliprelay.service.ClipRelayService
import org.cliprelay.settings.ClipboardSettingsStore

class OtpNotificationListener : NotificationListenerService() {

    companion object {
        private const val TAG = "OtpListener"

        // Apps update/re-post OTP notifications (group summaries, "silent" re-posts);
        // ignore the same code within this window.
        private const val DEDUPE_WINDOW_MS = 30_000L

        fun isAccessGranted(context: Context): Boolean =
            NotificationManagerCompat.getEnabledListenerPackages(context)
                .contains(context.packageName)
    }

    private var lastOtp: String? = null
    private var lastOtpAtMs = 0L

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        if (sbn.packageName == packageName) return
        if (sbn.isOngoing) return
        if (sbn.notification.flags and Notification.FLAG_GROUP_SUMMARY != 0) return
        if (!ClipboardSettingsStore(this).isOtpRelayEnabled()) return

        val extras = sbn.notification.extras
        val text = listOfNotNull(
            extras.getCharSequence(Notification.EXTRA_TITLE),
            extras.getCharSequence(Notification.EXTRA_TEXT),
            extras.getCharSequence(Notification.EXTRA_BIG_TEXT),
            extras.getCharSequenceArray(Notification.EXTRA_TEXT_LINES)?.joinToString(" ")
        ).joinToString(" ")
        if (text.isBlank()) return

        val otp = OtpExtractor.extract(text) ?: return

        val now = SystemClock.elapsedRealtime()
        if (otp == lastOtp && now - lastOtpAtMs < DEDUPE_WINDOW_MS) return
        lastOtp = otp
        lastOtpAtMs = now

        // Never log the code itself.
        Log.i(TAG, "OTP detected in notification from ${sbn.packageName}, relaying to Mac")
        val intent = Intent(this, ClipRelayService::class.java).apply {
            action = ClipRelayService.ACTION_PUSH_TEXT
            putExtra(ClipRelayService.EXTRA_TEXT, otp)
        }
        runCatching { ContextCompat.startForegroundService(this, intent) }
            .onFailure { Log.w(TAG, "Could not start service to relay OTP", it) }
    }
}
