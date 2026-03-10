package org.cliprelay.pairing

// Persists the shared secret in EncryptedSharedPreferences.

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

class PairingStore(context: Context) {
    companion object {
        private const val TAG = "PairingStore"
        private const val PREFS_NAME = "cliprelay_pairing"
        private const val KEY_SHARED_SECRET = "shared_secret"
    }

    private val encryptedPrefs: SharedPreferences? = try {
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

    fun clear() {
        clearSecret(encryptedPrefs)
    }

    private fun readSecret(prefs: SharedPreferences?): String? {
        if (prefs == null) return null
        return runCatching { prefs.getString(KEY_SHARED_SECRET, null) }.getOrNull()
    }

    private fun clearSecret(prefs: SharedPreferences?) {
        if (prefs == null) return
        runCatching {
            prefs.edit().remove(KEY_SHARED_SECRET).apply()
        }
    }
}
