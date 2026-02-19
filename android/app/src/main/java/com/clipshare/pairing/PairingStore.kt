package com.clipshare.pairing

import android.content.Context

class PairingStore(context: Context) {
    companion object {
        private const val PREFS_NAME = "clipshare_pairing"
        private const val KEY_TOKEN = "token"
        private const val KEY_SERVICE_UUID = "service_uuid"
        private const val KEY_MAC_PUBLIC_KEY = "mac_public_key"
        private val DEFAULT_ENCRYPTION_SEED = "clipboard-sync-dev-seed".toByteArray(Charsets.UTF_8)
    }

    private val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun save(payload: PairingPayload) {
        prefs.edit()
            .putString(KEY_TOKEN, payload.token)
            .putString(KEY_SERVICE_UUID, payload.serviceUUID)
            .putString(KEY_MAC_PUBLIC_KEY, payload.macPublicKey)
            .apply()
    }

    fun load(): PairingPayload? {
        val token = prefs.getString(KEY_TOKEN, null)
        val serviceUuid = prefs.getString(KEY_SERVICE_UUID, null)
        val macPublicKey = prefs.getString(KEY_MAC_PUBLIC_KEY, null)

        if (token.isNullOrBlank() || serviceUuid.isNullOrBlank() || macPublicKey.isNullOrBlank()) {
            return null
        }

        return PairingPayload(
            token = token,
            serviceUUID = serviceUuid,
            macPublicKey = macPublicKey
        )
    }

    fun encryptionSeed(): ByteArray {
        return DEFAULT_ENCRYPTION_SEED
    }
}
