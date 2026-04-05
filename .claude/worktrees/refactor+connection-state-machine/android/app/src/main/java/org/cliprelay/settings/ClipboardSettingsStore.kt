package org.cliprelay.settings

// Persists user preferences for clipboard behavior (e.g. auto-clear after sync).

import android.content.Context

class ClipboardSettingsStore(context: Context) {
    companion object {
        private const val PREFS_NAME = "cliprelay_settings"
        private const val KEY_AUTO_CLEAR_SYNCED_CLIPBOARD = "auto_clear_synced_clipboard"
        const val KEY_AUTO_COPY_ENABLED = "auto_copy_enabled"
        const val KEY_AUTO_COPY_ONBOARDING_SHOWN = "auto_copy_onboarding_shown"

        const val AUTO_CLEAR_DELAY_MS = 60_000L
    }

    private val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun isAutoClearSyncedClipboardEnabled(): Boolean {
        return prefs.getBoolean(KEY_AUTO_CLEAR_SYNCED_CLIPBOARD, true)
    }

    fun setAutoClearSyncedClipboardEnabled(enabled: Boolean) {
        prefs.edit().putBoolean(KEY_AUTO_CLEAR_SYNCED_CLIPBOARD, enabled).apply()
    }

    fun isAutoCopyEnabled(): Boolean {
        return prefs.getBoolean(KEY_AUTO_COPY_ENABLED, false)
    }

    fun setAutoCopyEnabled(enabled: Boolean) {
        prefs.edit().putBoolean(KEY_AUTO_COPY_ENABLED, enabled).apply()
    }

    fun isAutoCopyOnboardingShown(): Boolean {
        return prefs.getBoolean(KEY_AUTO_COPY_ONBOARDING_SHOWN, false)
    }

    fun setAutoCopyOnboardingShown(shown: Boolean) {
        prefs.edit().putBoolean(KEY_AUTO_COPY_ONBOARDING_SHOWN, shown).apply()
    }
}
