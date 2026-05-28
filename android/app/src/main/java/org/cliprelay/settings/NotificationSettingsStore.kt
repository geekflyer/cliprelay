package org.cliprelay.settings

import android.content.Context

class NotificationSettingsStore(context: Context) {
    private val prefs = context.getSharedPreferences("cliprelay_notification_settings", Context.MODE_PRIVATE)

    fun isNotificationSyncEnabled(): Boolean = prefs.getBoolean(KEY_NOTIFICATION_SYNC_ENABLED, false)

    fun setNotificationSyncEnabled(enabled: Boolean) {
        prefs.edit().putBoolean(KEY_NOTIFICATION_SYNC_ENABLED, enabled).apply()
    }

    companion object {
        private const val KEY_NOTIFICATION_SYNC_ENABLED = "notification_sync_enabled"
    }
}
