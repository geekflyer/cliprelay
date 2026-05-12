package org.cliprelay.service

// NotificationListenerService that captures posted notifications and relays them to ClipRelayService.

import android.content.ComponentName
import android.content.Intent
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import org.cliprelay.settings.NotificationSettingsStore

class NotificationRelayService : NotificationListenerService() {
    companion object {
        private const val TAG = "NotificationRelayService"

        // Packages to ignore (system noise, self-referential, etc.)
        private val BLOCKED_PACKAGES = setOf(
            "android",
            "com.android.systemui",
            "org.cliprelay",
        )

        fun isListenerEnabled(context: android.content.Context): Boolean {
            val flat = android.provider.Settings.Secure.getString(
                context.contentResolver,
                "enabled_notification_listeners"
            ) ?: return false
            val cn = ComponentName(context, NotificationRelayService::class.java).flattenToString()
            return flat.split(":").any { it == cn }
        }
    }

    private lateinit var settingsStore: NotificationSettingsStore

    override fun onCreate() {
        super.onCreate()
        settingsStore = NotificationSettingsStore(this)
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        if (!settingsStore.isNotificationSyncEnabled()) return
        if (sbn.packageName in BLOCKED_PACKAGES) return
        if (sbn.isOngoing) return

        val extras = sbn.notification?.extras ?: return
        val title = extras.getCharSequence("android.title")?.toString() ?: return
        val text = extras.getCharSequence("android.text")?.toString() ?: ""

        val appName = try {
            packageManager.getApplicationLabel(
                packageManager.getApplicationInfo(sbn.packageName, 0)
            ).toString()
        } catch (_: Exception) {
            sbn.packageName
        }

        Log.d(TAG, "Relaying notification from $appName: $title")

        val intent = Intent(this, ClipRelayService::class.java).apply {
            action = ClipRelayService.ACTION_PUSH_NOTIFICATION
            putExtra(ClipRelayService.EXTRA_NOTIFICATION_APP, appName)
            putExtra(ClipRelayService.EXTRA_NOTIFICATION_TITLE, title)
            putExtra(ClipRelayService.EXTRA_NOTIFICATION_TEXT, text)
            putExtra(ClipRelayService.EXTRA_NOTIFICATION_TIME, sbn.postTime)
        }
        startService(intent)
    }
}
