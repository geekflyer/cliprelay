package org.cliprelay.pairing

// Persists the shared secret in EncryptedSharedPreferences.

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import org.cliprelay.protocol.SettingsProvider

class PairingStore internal constructor(private val encryptedPrefs: SharedPreferences?) : SettingsProvider {
    companion object {
        private const val TAG = "PairingStore"
        private const val PREFS_NAME = "cliprelay_pairing"
        internal const val KEY_SHARED_SECRET = "shared_secret"
        internal const val KEY_RICH_MEDIA_ENABLED = "rich_media_enabled"
        internal const val KEY_RICH_MEDIA_ENABLED_CHANGED_AT = "rich_media_enabled_changed_at"
    }

    constructor(context: Context) : this(
        try {
            val masterKey = MasterKey.Builder(context)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build()
            EncryptedSharedPreferences.create(
                context,
                PREFS_NAME,
                masterKey,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
            )
        } catch (e: Exception) {
            Log.e(TAG, "EncryptedSharedPreferences unavailable; pairing will not be possible on this device", e)
            null
        }
    )

    fun saveSharedSecret(secret: String): Boolean {
        val prefs = encryptedPrefs
        if (prefs == null) {
            Log.e(TAG, "Cannot save shared secret: encrypted storage unavailable")
            return false
        }
        return runCatching {
            prefs.edit().putString(KEY_SHARED_SECRET, secret).apply()
            true
        }.getOrDefault(false)
    }

    fun loadSharedSecret(): String? {
        return readSecret(encryptedPrefs)
    }

    override fun isRichMediaEnabled(): Boolean {
        val prefs = encryptedPrefs ?: return false
        return runCatching { prefs.getBoolean(KEY_RICH_MEDIA_ENABLED, false) }.getOrDefault(false)
    }

    override fun getRichMediaEnabledChangedAt(): Long {
        val prefs = encryptedPrefs ?: return 0L
        return runCatching { prefs.getLong(KEY_RICH_MEDIA_ENABLED_CHANGED_AT, 0L) }.getOrDefault(0L)
    }

    override fun setRichMediaEnabled(enabled: Boolean, changedAt: Long) {
        val prefs = encryptedPrefs ?: return
        runCatching {
            prefs.edit()
                .putBoolean(KEY_RICH_MEDIA_ENABLED, enabled)
                .putLong(KEY_RICH_MEDIA_ENABLED_CHANGED_AT, changedAt)
                .apply()
        }
    }

    fun clear() {
        clearAll(encryptedPrefs)
    }

    private fun readSecret(prefs: SharedPreferences?): String? {
        if (prefs == null) return null
        return runCatching { prefs.getString(KEY_SHARED_SECRET, null) }.getOrNull()
    }

    private fun clearAll(prefs: SharedPreferences?) {
        if (prefs == null) return
        runCatching {
            prefs.edit()
                .remove(KEY_SHARED_SECRET)
                .remove(KEY_RICH_MEDIA_ENABLED)
                .remove(KEY_RICH_MEDIA_ENABLED_CHANGED_AT)
                .apply()
        }
    }
}
