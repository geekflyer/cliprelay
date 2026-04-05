package org.cliprelay.crypto

// AES-256-GCM encryption/decryption and HKDF key derivation for end-to-end clipboard security.

import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.PrivateKey
import java.security.PublicKey
import java.security.spec.X509EncodedKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyAgreement as JKeyAgreement
import javax.crypto.Mac
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

object E2ECrypto {
    private const val GCM_NONCE_LENGTH = 12
    private const val GCM_TAG_BITS = 128
    // Also used for KEY_CONFIRM during pairing — v1 devices cannot pair with v2 devices
    private val AAD = "cliprelay-v2".toByteArray(Charsets.UTF_8)

    fun deriveKey(secretBytes: ByteArray): SecretKey {
        val keyBytes = hkdf(secretBytes, "cliprelay-enc-v1", 32)
        return SecretKeySpec(keyBytes, "AES")
    }

    fun deriveKey(tokenHex: String): SecretKey {
        return deriveKey(hexToBytes(tokenHex))
    }

    fun deviceTag(secretBytes: ByteArray): ByteArray {
        return hkdf(secretBytes, "cliprelay-tag-v1", 8)
    }

    fun deviceTag(tokenHex: String): ByteArray {
        return deviceTag(hexToBytes(tokenHex))
    }

    fun generateX25519KeyPair(): KeyPair {
        val kpg = KeyPairGenerator.getInstance("X25519")
        return kpg.generateKeyPair()
    }

    /** Convert raw 32-byte X25519 public key to JCA PublicKey. */
    fun x25519PublicKeyFromRaw(rawBytes: ByteArray): PublicKey {
        require(rawBytes.size == 32) { "X25519 public key must be 32 bytes" }
        // X.509 SubjectPublicKeyInfo header for X25519
        val x509Header = byteArrayOf(
            0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x6e, 0x03, 0x21, 0x00
        )
        val encoded = x509Header + rawBytes
        return KeyFactory.getInstance("X25519").generatePublic(X509EncodedKeySpec(encoded))
    }

    /** Extract raw 32-byte public key from JCA PublicKey. */
    fun x25519PublicKeyToRaw(publicKey: PublicKey): ByteArray {
        val encoded = publicKey.encoded
        return encoded.copyOfRange(encoded.size - 32, encoded.size)
    }

    /** Compute ECDH shared secret and derive root secret via HKDF. */
    fun ecdhSharedSecret(privateKey: PrivateKey, remotePublicKeyRaw: ByteArray): ByteArray {
        val remotePub = x25519PublicKeyFromRaw(remotePublicKeyRaw)
        val ka = JKeyAgreement.getInstance("X25519")
        ka.init(privateKey)
        ka.doPhase(remotePub, true)
        val rawSecret = ka.generateSecret()
        // Derive root secret using HKDF with domain separator (matches macOS)
        return hkdf(rawSecret, "cliprelay-ecdh-v1", 32)
    }

    fun deriveAuthKey(secretBytes: ByteArray): SecretKey {
        val keyBytes = hkdf(secretBytes, "cliprelay-auth-v2", 32)
        return SecretKeySpec(keyBytes, "HmacSHA256")
    }

    fun deriveSessionKey(secretBytes: ByteArray, ecdhResult: ByteArray): SecretKey {
        val ikm = secretBytes + ecdhResult
        val keyBytes = hkdf(ikm, "cliprelay-session-v2", 32)
        return SecretKeySpec(keyBytes, "AES")
    }

    fun hmacAuth(publicKeyBytes: ByteArray, authKey: SecretKey): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(authKey)
        return mac.doFinal(publicKeyBytes)
    }

    fun verifyAuth(publicKeyBytes: ByteArray, authKey: SecretKey, expected: ByteArray): Boolean {
        val computed = hmacAuth(publicKeyBytes, authKey)
        return java.security.MessageDigest.isEqual(computed, expected)
    }

    /** Compute raw X25519 shared secret (no HKDF wrapping). Production overload using JCA PrivateKey. */
    fun rawX25519(ownPrivateKey: PrivateKey, remotePublicKeyRaw: ByteArray): ByteArray {
        val remotePub = x25519PublicKeyFromRaw(remotePublicKeyRaw)
        val ka = JKeyAgreement.getInstance("X25519")
        ka.init(ownPrivateKey)
        ka.doPhase(remotePub, true)
        return ka.generateSecret()
    }

    /** Compute raw X25519 shared secret from raw private key bytes. Test-only overload. */
    fun rawX25519(ownPrivateKeyRaw: ByteArray, remotePublicKeyRaw: ByteArray): ByteArray {
        val remotePub = x25519PublicKeyFromRaw(remotePublicKeyRaw)
        // PKCS#8 header for X25519 private key
        val pkcs8Header = byteArrayOf(
            0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x6e,
            0x04, 0x22, 0x04, 0x20
        )
        val encoded = pkcs8Header + ownPrivateKeyRaw
        val privKey = KeyFactory.getInstance("X25519")
            .generatePrivate(java.security.spec.PKCS8EncodedKeySpec(encoded))
        val ka = JKeyAgreement.getInstance("X25519")
        ka.init(privKey)
        ka.doPhase(remotePub, true)
        return ka.generateSecret()
    }

    fun seal(plaintext: ByteArray, key: SecretKey): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key)
        cipher.updateAAD(AAD)
        val ciphertext = cipher.doFinal(plaintext)
        // cipher.iv is the 12-byte nonce generated by the provider
        // ciphertext includes the 16-byte auth tag appended by GCM
        return cipher.iv + ciphertext
    }

    fun open(blob: ByteArray, key: SecretKey): ByteArray {
        require(blob.size > GCM_NONCE_LENGTH + GCM_TAG_BITS / 8) { "Blob too short" }
        val nonce = blob.copyOfRange(0, GCM_NONCE_LENGTH)
        val ciphertextWithTag = blob.copyOfRange(GCM_NONCE_LENGTH, blob.size)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(GCM_TAG_BITS, nonce))
        cipher.updateAAD(AAD)
        return cipher.doFinal(ciphertextWithTag)
    }

    internal fun hkdf(ikm: ByteArray, info: String, length: Int): ByteArray {
        val infoBytes = info.toByteArray(Charsets.UTF_8)
        val mac = Mac.getInstance("HmacSHA256")
        // Extract: PRK = HMAC-SHA256(salt=zeros, IKM)
        mac.init(SecretKeySpec(ByteArray(32), "HmacSHA256"))
        val prk = mac.doFinal(ikm)
        // Expand
        mac.init(SecretKeySpec(prk, "HmacSHA256"))
        val okm = ByteArray(length)
        var t = ByteArray(0)
        var offset = 0
        var counter: Byte = 1
        while (offset < length) {
            mac.update(t)
            mac.update(infoBytes)
            mac.update(counter)
            t = mac.doFinal()
            val copyLen = minOf(t.size, length - offset)
            System.arraycopy(t, 0, okm, offset, copyLen)
            offset += copyLen
            counter++
        }
        return okm
    }

    internal fun hexToBytes(hex: String): ByteArray {
        val len = hex.length
        val data = ByteArray(len / 2)
        for (i in 0 until len step 2) {
            data[i / 2] = ((Character.digit(hex[i], 16) shl 4) + Character.digit(hex[i + 1], 16)).toByte()
        }
        return data
    }
}
