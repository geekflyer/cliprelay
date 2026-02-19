package com.clipshare.pairing

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class PairingStore(context: Context) {
    companion object {
        private const val PREFS_NAME = "clipshare_pairing"

        private const val KEY_TOKEN_LEGACY = "token"
        private const val KEY_TOKEN_CIPHERTEXT = "token_ciphertext"
        private const val KEY_TOKEN_IV = "token_iv"
        private const val KEY_SERVICE_UUID = "service_uuid"
        private const val KEY_MAC_PUBLIC_KEY = "mac_public_key"

        private const val KEYSTORE_PROVIDER = "AndroidKeyStore"
        private const val KEY_ALIAS = "clipshare_pairing_aes"

        private val DEFAULT_ENCRYPTION_SEED = "clipboard-sync-dev-seed".toByteArray(Charsets.UTF_8)
    }

    private val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun save(payload: PairingPayload) {
        val editor = prefs.edit()

        val encrypted = encryptToken(payload.token)
        if (encrypted != null) {
            editor
                .putString(KEY_TOKEN_CIPHERTEXT, Base64.encodeToString(encrypted.first, Base64.NO_WRAP))
                .putString(KEY_TOKEN_IV, Base64.encodeToString(encrypted.second, Base64.NO_WRAP))
                .remove(KEY_TOKEN_LEGACY)
        } else {
            editor.putString(KEY_TOKEN_LEGACY, payload.token)
        }

        editor
            .putString(KEY_SERVICE_UUID, payload.serviceUUID)
            .putString(KEY_MAC_PUBLIC_KEY, payload.macPublicKey)
            .apply()
    }

    fun load(): PairingPayload? {
        val token = decryptToken() ?: prefs.getString(KEY_TOKEN_LEGACY, null)
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
        val token = load()?.token
        if (token.isNullOrBlank()) {
            return DEFAULT_ENCRYPTION_SEED
        }
        return token.toByteArray(Charsets.UTF_8)
    }

    fun pairingTokenForAdvertising(maxBytes: Int = 8): ByteArray? {
        val token = load()?.token ?: return null
        val tokenBytes = decodeHex(token) ?: return null
        if (tokenBytes.isEmpty()) {
            return null
        }
        return tokenBytes.copyOf(minOf(maxBytes, tokenBytes.size))
    }

    private fun encryptToken(token: String): Pair<ByteArray, ByteArray>? {
        val key = getOrCreateSecretKey() ?: return null
        return runCatching {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, key)
            val ciphertext = cipher.doFinal(token.toByteArray(Charsets.UTF_8))
            Pair(ciphertext, cipher.iv)
        }.getOrNull()
    }

    private fun decryptToken(): String? {
        val ciphertextB64 = prefs.getString(KEY_TOKEN_CIPHERTEXT, null)
        val ivB64 = prefs.getString(KEY_TOKEN_IV, null)
        if (ciphertextB64.isNullOrBlank() || ivB64.isNullOrBlank()) {
            return null
        }

        val ciphertext = decodeBase64(ciphertextB64) ?: return null
        val iv = decodeBase64(ivB64) ?: return null
        val key = getOrCreateSecretKey() ?: return null

        return runCatching {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, iv))
            val plaintext = cipher.doFinal(ciphertext)
            String(plaintext, Charsets.UTF_8)
        }.getOrNull()
    }

    private fun getOrCreateSecretKey(): SecretKey? {
        return runCatching {
            val keyStore = KeyStore.getInstance(KEYSTORE_PROVIDER)
            keyStore.load(null)

            val existing = keyStore.getKey(KEY_ALIAS, null) as? SecretKey
            if (existing != null) {
                return@runCatching existing
            }

            val keyGenerator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE_PROVIDER)
            val spec = KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .setUserAuthenticationRequired(false)
                .build()

            keyGenerator.init(spec)
            keyGenerator.generateKey()
        }.getOrNull()
    }

    private fun decodeBase64(value: String): ByteArray? {
        val normalized = value.replace(' ', '+')
        val flags = listOf(
            Base64.NO_WRAP,
            Base64.DEFAULT,
            Base64.URL_SAFE or Base64.NO_WRAP,
            Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING
        )

        flags.forEach { flag ->
            val decoded = runCatching { Base64.decode(normalized, flag) }.getOrNull()
            if (decoded != null) {
                return decoded
            }
        }

        return null
    }

    private fun decodeHex(value: String): ByteArray? {
        val normalized = value.trim()
        if (normalized.length % 2 != 0) {
            return null
        }

        return runCatching {
            ByteArray(normalized.length / 2) { index ->
                val offset = index * 2
                normalized.substring(offset, offset + 2).toInt(16).toByte()
            }
        }.getOrNull()
    }
}
