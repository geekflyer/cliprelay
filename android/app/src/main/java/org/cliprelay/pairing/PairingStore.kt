package org.cliprelay.pairing

// Persists the pairing token in EncryptedSharedPreferences.

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

class PairingStore(context: Context) {
    companion object {
        private const val TAG = "PairingStore"
        private const val PREFS_NAME = "cliprelay_pairing"
        private const val KEY_TOKEN = "pairing_token"
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

    fun saveToken(token: String): Boolean {
        val prefs = encryptedPrefs
        if (prefs == null) {
            Log.e(TAG, "Cannot save pairing token: encrypted storage unavailable")
            return false
        }
        return runCatching {
            prefs.edit().putString(KEY_TOKEN, token).apply()
            true
        }.getOrDefault(false)
    }

    fun loadToken(): String? {
        return readToken(encryptedPrefs)
    }

    fun clear() {
        clearToken(encryptedPrefs)
    }

    private fun readToken(prefs: SharedPreferences?): String? {
        if (prefs == null) return null
        return runCatching { prefs.getString(KEY_TOKEN, null) }.getOrNull()
    }

    private fun clearToken(prefs: SharedPreferences?) {
        if (prefs == null) return
        runCatching {
            prefs.edit().remove(KEY_TOKEN).apply()
        }
    }
}
