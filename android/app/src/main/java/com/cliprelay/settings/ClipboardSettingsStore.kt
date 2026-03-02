package com.cliprelay.settings

import android.content.Context

class ClipboardSettingsStore(context: Context) {
    companion object {
        private const val PREFS_NAME = "cliprelay_settings"
        private const val KEY_AUTO_CLEAR_SYNCED_CLIPBOARD = "auto_clear_synced_clipboard"

        const val AUTO_CLEAR_DELAY_MS = 60_000L
    }

    private val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun isAutoClearSyncedClipboardEnabled(): Boolean {
        return prefs.getBoolean(KEY_AUTO_CLEAR_SYNCED_CLIPBOARD, false)
    }

    fun setAutoClearSyncedClipboardEnabled(enabled: Boolean) {
        prefs.edit().putBoolean(KEY_AUTO_CLEAR_SYNCED_CLIPBOARD, enabled).apply()
    }
}
