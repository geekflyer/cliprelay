package com.clipshare.crypto

import java.security.MessageDigest
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

object E2ECrypto {
    fun deriveAesKey(sharedSecret: ByteArray): SecretKey {
        val digest = MessageDigest.getInstance("SHA-256").digest(sharedSecret)
        return SecretKeySpec(digest, "AES")
    }

    fun encrypt(plaintext: ByteArray, key: SecretKey, nonce: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        val spec = GCMParameterSpec(128, nonce)
        cipher.init(Cipher.ENCRYPT_MODE, key, spec)
        cipher.updateAAD("clipboard-sync-v1".toByteArray())
        return cipher.doFinal(plaintext)
    }

    fun decrypt(ciphertext: ByteArray, key: SecretKey, nonce: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        val spec = GCMParameterSpec(128, nonce)
        cipher.init(Cipher.DECRYPT_MODE, key, spec)
        cipher.updateAAD("clipboard-sync-v1".toByteArray())
        return cipher.doFinal(ciphertext)
    }

    fun computeSharedSecret(privateKey: java.security.PrivateKey, publicKey: java.security.PublicKey): ByteArray {
        val keyAgreement = KeyAgreement.getInstance("XDH")
        keyAgreement.init(privateKey)
        keyAgreement.doPhase(publicKey, true)
        return keyAgreement.generateSecret()
    }
}
