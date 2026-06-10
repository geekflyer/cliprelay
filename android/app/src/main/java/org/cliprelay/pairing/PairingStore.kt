package org.cliprelay.pairing

// Persists paired Macs (up to MAX_PAIRED_MACS) and the phone identity tag in EncryptedSharedPreferences.

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import org.cliprelay.crypto.E2ECrypto
import org.cliprelay.protocol.SettingsProvider
import org.json.JSONArray
import org.json.JSONObject

/** Device-tag hex for a shared secret: the stable non-secret identifier. */
internal fun deviceTagHex(secretHex: String): String =
    E2ECrypto.deviceTag(secretHex).joinToString("") { "%02x".format(it) }

/** One paired Mac. [id] is a stable non-secret identifier derived from the secret. */
data class PairedMac(
    val secretHex: String,
    val name: String?,
    val pairedAtMs: Long
) {
    val id: String by lazy { deviceTagHex(secretHex) }
}

class PairingStore internal constructor(private val encryptedPrefs: SharedPreferences?) : SettingsProvider {
    companion object {
        const val MAX_PAIRED_MACS = 5

        private const val TAG = "PairingStore"
        private const val PREFS_NAME = "cliprelay_pairing"
        // Legacy single-Mac key, migrated to KEY_PAIRED_MACS on first load.
        internal const val KEY_SHARED_SECRET = "shared_secret"
        internal const val KEY_PAIRED_MACS = "paired_macs"
        internal const val KEY_IDENTITY_TAG = "identity_tag"
        internal const val KEY_RICH_MEDIA_ENABLED = "rich_media_enabled"
        internal const val KEY_RICH_MEDIA_ENABLED_CHANGED_AT = "rich_media_enabled_changed_at"
    }

    init {
        migrateLegacySecretIfNeeded()
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

    // ── Paired Macs ───────────────────────────────────────────────────

    fun loadPairedMacs(): List<PairedMac> {
        val prefs = encryptedPrefs ?: return emptyList()
        val raw = runCatching { prefs.getString(KEY_PAIRED_MACS, null) }.getOrNull() ?: return emptyList()
        return runCatching {
            val array = JSONArray(raw)
            (0 until array.length()).mapNotNull { i ->
                val obj = array.optJSONObject(i) ?: return@mapNotNull null
                val secret = obj.optString("secret").takeIf { it.isNotEmpty() } ?: return@mapNotNull null
                PairedMac(
                    secretHex = secret,
                    name = obj.optString("name").takeIf { it.isNotEmpty() },
                    pairedAtMs = obj.optLong("pairedAt", 0L)
                )
            }
        }.getOrDefault(emptyList())
    }

    fun hasPairedMacs(): Boolean = loadPairedMacs().isNotEmpty()

    /**
     * Add (or re-add) a paired Mac. Sets the identity tag from this secret when
     * none exists yet (first pairing — old Macs scan for the secret-derived tag).
     * Returns false when storage is unavailable or the list is full.
     */
    fun addPairedMac(secretHex: String, name: String?, pairedAtMs: Long = System.currentTimeMillis()): Boolean {
        val prefs = encryptedPrefs
        if (prefs == null) {
            Log.e(TAG, "Cannot save pairing: encrypted storage unavailable")
            return false
        }
        val macs = loadPairedMacs().filterNot { it.secretHex == secretHex }
        if (macs.size >= MAX_PAIRED_MACS) {
            Log.w(TAG, "Cannot add pairing: limit of $MAX_PAIRED_MACS reached")
            return false
        }
        return runCatching {
            val editor = prefs.edit()
            if (identityTagHex() == null) {
                editor.putString(KEY_IDENTITY_TAG, deviceTagHex(secretHex))
            }
            editor.putString(KEY_PAIRED_MACS, encode(macs + PairedMac(secretHex, name, pairedAtMs)))
            editor.apply()
            true
        }.getOrDefault(false)
    }

    /** Update the display name of an existing pairing (from the handshake's remote name). */
    fun updateMacName(secretHex: String, name: String) {
        val prefs = encryptedPrefs ?: return
        val macs = loadPairedMacs()
        if (macs.none { it.secretHex == secretHex && it.name != name }) return
        val updated = macs.map { if (it.secretHex == secretHex) it.copy(name = name) else it }
        runCatching { prefs.edit().putString(KEY_PAIRED_MACS, encode(updated)).apply() }
    }

    /**
     * Remove one pairing. When the last Mac is removed the identity tag is
     * cleared too, so the next first pairing derives a fresh one.
     */
    fun removePairedMac(secretHex: String) {
        val prefs = encryptedPrefs ?: return
        val remaining = loadPairedMacs().filterNot { it.secretHex == secretHex }
        runCatching {
            val editor = prefs.edit()
            if (remaining.isEmpty()) {
                editor.remove(KEY_PAIRED_MACS)
                editor.remove(KEY_IDENTITY_TAG)
            } else {
                editor.putString(KEY_PAIRED_MACS, encode(remaining))
            }
            editor.apply()
        }
    }

    /** Stable 8-byte tag advertised over BLE; null when nothing is paired. */
    fun identityTag(): ByteArray? {
        val hex = identityTagHex() ?: return null
        return runCatching { E2ECrypto.hexToBytes(hex) }.getOrNull()
    }

    fun identityTagHex(): String? {
        val prefs = encryptedPrefs ?: return null
        return runCatching { prefs.getString(KEY_IDENTITY_TAG, null) }.getOrNull()
    }

    // ── Rich media settings (global, synced last-write-wins) ─────────

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
        val prefs = encryptedPrefs ?: return
        runCatching {
            prefs.edit()
                .remove(KEY_SHARED_SECRET)
                .remove(KEY_PAIRED_MACS)
                .remove(KEY_IDENTITY_TAG)
                .remove(KEY_RICH_MEDIA_ENABLED)
                .remove(KEY_RICH_MEDIA_ENABLED_CHANGED_AT)
                .apply()
        }
    }

    // ── Migration ─────────────────────────────────────────────────────

    private fun migrateLegacySecretIfNeeded() {
        val prefs = encryptedPrefs ?: return
        runCatching {
            val legacy = prefs.getString(KEY_SHARED_SECRET, null) ?: return
            if (prefs.getString(KEY_PAIRED_MACS, null) == null) {
                prefs.edit()
                    .putString(KEY_PAIRED_MACS, encode(listOf(PairedMac(legacy, null, 0L))))
                    .putString(KEY_IDENTITY_TAG, deviceTagHex(legacy))
                    .remove(KEY_SHARED_SECRET)
                    .apply()
            } else {
                prefs.edit().remove(KEY_SHARED_SECRET).apply()
            }
            Log.w(TAG, "Migrated legacy single-Mac pairing to paired_macs list")
        }
    }

    private fun encode(macs: List<PairedMac>): String {
        val array = JSONArray()
        macs.forEach { mac ->
            array.put(JSONObject().apply {
                put("secret", mac.secretHex)
                mac.name?.let { put("name", it) }
                put("pairedAt", mac.pairedAtMs)
            })
        }
        return array.toString()
    }
}
