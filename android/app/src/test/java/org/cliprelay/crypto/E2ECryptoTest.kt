package org.cliprelay.crypto

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Test
import java.security.MessageDigest

class E2ECryptoTest {
    @Test
    fun sealAndOpen_roundTrip() {
        val token = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
        val key = E2ECrypto.deriveKey(token)
        val plaintext = "hello from android test".toByteArray(Charsets.UTF_8)

        val blob = E2ECrypto.seal(plaintext, key)
        val reopened = E2ECrypto.open(blob, key)

        assertArrayEquals(plaintext, reopened)
    }

    @Test
    fun deriveKeyAndDeviceTag_matchKnownVector() {
        val token = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
        val key = E2ECrypto.deriveKey(token)
        val tag = E2ECrypto.deviceTag(token)

        assertEquals(
            "1eca4ce80d0a18eb5ae4991b3a9ea9f87958e424e91b72a8773ba8df8617d2fa",
            key.encoded.toHex()
        )
        assertEquals("9a93227ce19a8a39", tag.toHex())
    }

    @Test(expected = Exception::class)
    fun open_rejectsTamperedBlob() {
        val token = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
        val key = E2ECrypto.deriveKey(token)
        val blob = E2ECrypto.seal("payload".toByteArray(Charsets.UTF_8), key)
        blob[blob.lastIndex] = (blob.last().toInt() xor 0x01).toByte()

        E2ECrypto.open(blob, key)
    }

    @Test(expected = IllegalArgumentException::class)
    fun open_rejectsShortBlob() {
        val token = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
        val key = E2ECrypto.deriveKey(token)
        val tooShort = ByteArray(16)

        E2ECrypto.open(tooShort, key)
    }

    @Test
    fun seal_usesRandomNonce() {
        val token = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
        val key = E2ECrypto.deriveKey(token)
        val plaintext = "same payload".toByteArray(Charsets.UTF_8)

        val first = E2ECrypto.seal(plaintext, key)
        val second = E2ECrypto.seal(plaintext, key)

        assertNotEquals(first.toHex(), second.toHex())
    }

    @Test
    fun ecdhSharedSecretSymmetry() {
        val keyPair1 = E2ECrypto.generateX25519KeyPair()
        val keyPair2 = E2ECrypto.generateX25519KeyPair()

        val pub1Raw = E2ECrypto.x25519PublicKeyToRaw(keyPair1.public)
        val pub2Raw = E2ECrypto.x25519PublicKeyToRaw(keyPair2.public)

        val secret1 = E2ECrypto.ecdhSharedSecret(keyPair1.private, pub2Raw)
        val secret2 = E2ECrypto.ecdhSharedSecret(keyPair2.private, pub1Raw)

        assertArrayEquals(secret1, secret2)
        assertEquals(32, secret1.size)
    }

    @Test
    fun deriveKeyFromSecretBytes() {
        val secretBytes = ByteArray(32) { 0x42 }
        val key = E2ECrypto.deriveKey(secretBytes)
        assertNotNull(key)

        val tag = E2ECrypto.deviceTag(secretBytes)
        assertEquals(8, tag.size)
    }

    @Test
    fun deriveKeyFromSecretBytesMatchesHexVersion() {
        val hex = "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742"
        val bytes = E2ECrypto.hexToBytes(hex)

        val keyFromHex = E2ECrypto.deriveKey(hex)
        val keyFromBytes = E2ECrypto.deriveKey(bytes)

        // Both should produce the same key - verify by encrypting and cross-decrypting
        val plaintext = "test".toByteArray()
        val encrypted = E2ECrypto.seal(plaintext, keyFromHex)
        val decrypted = E2ECrypto.open(encrypted, keyFromBytes)
        assertArrayEquals(plaintext, decrypted)
    }

    @Test
    fun x25519PublicKeyRoundTrip() {
        val keyPair = E2ECrypto.generateX25519KeyPair()
        val raw = E2ECrypto.x25519PublicKeyToRaw(keyPair.public)
        assertEquals(32, raw.size)

        val reconstructed = E2ECrypto.x25519PublicKeyFromRaw(raw)
        val rawAgain = E2ECrypto.x25519PublicKeyToRaw(reconstructed)
        assertArrayEquals(raw, rawAgain)
    }

    // --- Cross-platform ECDH interop (must match macOS E2ECryptoKeyDerivationTests.swift) ---

    // Golden fixture values from test-fixtures/protocol/l2cap/ecdh_fixture.json
    private val rawEcdhSecretHex = "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742"
    private val expectedRootSecretHex = "b4e4716bc736cde97aa0b585beddab79e190a2531e21bdd410914aeec7a2a4e1"
    private val expectedEncryptionKeyHex = "5b4fd11a1ad6d9e9efa059d2baebf904a9f4f9b7104f9e547f1a68127443ccba"
    private val expectedDeviceTagHex = "a33273934e2b9e80"
    private val expectedPairingTagHex = "300c9c9603b92a4b"
    private val macPublicKeyHex = "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a"

    @Test
    fun ecdhFixtureRootSecret() {
        // root_secret = HKDF-SHA256(ikm=raw_ecdh_secret, salt=zeros(32), info="cliprelay-ecdh-v1", len=32)
        val rawSecret = E2ECrypto.hexToBytes(rawEcdhSecretHex)
        val rootSecret = E2ECrypto.hkdf(rawSecret, "cliprelay-ecdh-v1", 32)
        assertEquals(expectedRootSecretHex, rootSecret.toHex())
    }

    @Test
    fun ecdhFixtureEncryptionKey() {
        // encryption_key = deriveKey(root_secret)
        val rootBytes = E2ECrypto.hexToBytes(expectedRootSecretHex)
        val encKey = E2ECrypto.deriveKey(rootBytes)
        assertEquals(expectedEncryptionKeyHex, encKey.encoded.toHex())
    }

    @Test
    fun ecdhFixtureDeviceTag() {
        // device_tag = deviceTag(root_secret)
        val rootBytes = E2ECrypto.hexToBytes(expectedRootSecretHex)
        val tag = E2ECrypto.deviceTag(rootBytes)
        assertEquals(expectedDeviceTagHex, tag.toHex())
    }

    @Test
    fun ecdhFixturePairingTag() {
        // pairing_tag = SHA256(mac_public_key)[0:8]
        val macPubBytes = E2ECrypto.hexToBytes(macPublicKeyHex)
        val hash = MessageDigest.getInstance("SHA-256").digest(macPubBytes)
        val pairingTag = hash.copyOfRange(0, 8)
        assertEquals(expectedPairingTagHex, pairingTag.toHex())
    }

    @Test
    fun ecdhFixtureFullDerivationChain() {
        // Verify the full chain: raw_ecdh_secret -> root_secret -> encryption_key + device_tag
        val rawSecret = E2ECrypto.hexToBytes(rawEcdhSecretHex)

        // Step 1: Derive root_secret from raw ECDH secret
        val rootSecret = E2ECrypto.hkdf(rawSecret, "cliprelay-ecdh-v1", 32)

        // Step 2: Derive encryption_key from root_secret
        val encKey = E2ECrypto.deriveKey(rootSecret)

        // Step 3: Derive device_tag from root_secret
        val tag = E2ECrypto.deviceTag(rootSecret)

        // All values must match the fixture
        assertEquals(expectedRootSecretHex, rootSecret.toHex())
        assertEquals(expectedEncryptionKeyHex, encKey.encoded.toHex())
        assertEquals(expectedDeviceTagHex, tag.toHex())
    }
}

private fun ByteArray.toHex(): String = joinToString(separator = "") { "%02x".format(it) }
