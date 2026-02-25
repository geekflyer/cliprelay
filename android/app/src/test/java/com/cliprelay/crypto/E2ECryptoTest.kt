package com.cliprelay.crypto

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

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
}

private fun ByteArray.toHex(): String = joinToString(separator = "") { "%02x".format(it) }
