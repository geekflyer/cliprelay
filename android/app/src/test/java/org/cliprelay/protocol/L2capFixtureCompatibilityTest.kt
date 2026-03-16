package org.cliprelay.protocol

import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.File

class L2capFixtureCompatibilityTest {

    private val fixture: JSONObject by lazy { loadFixture() }

    @Test
    fun encodeMatchesFixtureHello() = assertEncodeMatchesFixture("HELLO")

    @Test
    fun encodeMatchesFixtureWelcome() = assertEncodeMatchesFixture("WELCOME")

    @Test
    fun encodeMatchesFixtureKeyExchange() = assertEncodeMatchesFixture("KEY_EXCHANGE")

    @Test
    fun encodeMatchesFixtureKeyConfirm() = assertEncodeMatchesFixture("KEY_CONFIRM")

    @Test
    fun encodeMatchesFixtureOffer() = assertEncodeMatchesFixture("OFFER")

    @Test
    fun encodeMatchesFixtureAccept() = assertEncodeMatchesFixture("ACCEPT")

    @Test
    fun encodeMatchesFixturePayload() = assertEncodeMatchesFixture("PAYLOAD")

    @Test
    fun encodeMatchesFixtureDone() = assertEncodeMatchesFixture("DONE")

    @Test
    fun decodeMatchesFixtureHello() = assertDecodeMatchesFixture("HELLO")

    @Test
    fun decodeMatchesFixtureWelcome() = assertDecodeMatchesFixture("WELCOME")

    @Test
    fun decodeMatchesFixtureKeyExchange() = assertDecodeMatchesFixture("KEY_EXCHANGE")

    @Test
    fun decodeMatchesFixtureKeyConfirm() = assertDecodeMatchesFixture("KEY_CONFIRM")

    @Test
    fun decodeMatchesFixtureOffer() = assertDecodeMatchesFixture("OFFER")

    @Test
    fun decodeMatchesFixtureAccept() = assertDecodeMatchesFixture("ACCEPT")

    @Test
    fun decodeMatchesFixturePayload() = assertDecodeMatchesFixture("PAYLOAD")

    @Test
    fun decodeMatchesFixtureDone() = assertDecodeMatchesFixture("DONE")

    @Test
    fun negativeUnknownTypeIsSkipped() {
        // Unknown types are now skipped gracefully. When there's no next message
        // after the skipped unknown type, decode throws ProtocolException for
        // the incomplete header of the next (missing) message.
        val negatives = fixture.getJSONArray("negative_cases")
        var entry: org.json.JSONObject? = null
        for (i in 0 until negatives.length()) {
            val obj = negatives.getJSONObject(i)
            if (obj.getString("name") == "unknown_type") {
                entry = obj
                break
            }
        }
        requireNotNull(entry) { "Negative case 'unknown_type' not found in fixture" }

        val encodedHex = entry.getString("encoded_hex")
        try {
            MessageCodec.decode(ByteArrayInputStream(hexToBytes(encodedHex)))
            fail("Expected ProtocolException after skipping unknown type")
        } catch (e: ProtocolException) {
            val msg = e.message?.lowercase() ?: ""
            assertTrue(
                "Expected 'incomplete header' after skipping unknown type, but was '${e.message}'",
                msg.contains("incomplete header")
            )
        }
    }

    @Test
    fun negativeTruncatedHeader() {
        assertNegativeCase("truncated_header")
    }

    @Test
    fun negativeZeroLength() {
        assertNegativeCase("zero_length")
    }

    @Test
    fun negativeOversized() {
        assertNegativeCase("oversized")
    }

    // --- Helpers ---

    private fun assertEncodeMatchesFixture(messageName: String) {
        val entry = findMessage(messageName)
        val typeByte = entry.getString("type_byte").toInt(16).toByte()
        val payloadHex = entry.getString("payload_hex")
        val expectedHex = entry.getString("encoded_hex")

        val type = MessageType.fromByte(typeByte)
        val payload = hexToBytes(payloadHex)
        val message = Message(type, payload)
        val encoded = MessageCodec.encode(message)

        assertEquals(
            "Encoded hex mismatch for $messageName",
            expectedHex,
            bytesToHex(encoded)
        )
    }

    private fun assertDecodeMatchesFixture(messageName: String) {
        val entry = findMessage(messageName)
        val encodedHex = entry.getString("encoded_hex")
        val expectedTypeByte = entry.getString("type_byte").toInt(16).toByte()
        val expectedPayloadHex = entry.getString("payload_hex")

        val decoded = MessageCodec.decode(ByteArrayInputStream(hexToBytes(encodedHex)))

        assertEquals(
            "Type mismatch for $messageName",
            expectedTypeByte,
            decoded.type.byte
        )
        assertArrayEquals(
            "Payload mismatch for $messageName",
            hexToBytes(expectedPayloadHex),
            decoded.payload
        )
    }

    private fun assertNegativeCase(caseName: String) {
        val negatives = fixture.getJSONArray("negative_cases")
        var entry: JSONObject? = null
        for (i in 0 until negatives.length()) {
            val obj = negatives.getJSONObject(i)
            if (obj.getString("name") == caseName) {
                entry = obj
                break
            }
        }
        requireNotNull(entry) { "Negative case '$caseName' not found in fixture" }

        val encodedHex = entry.getString("encoded_hex")
        val expectedError = entry.getString("expected_error")
        val expectedSubstring = ERROR_SUBSTRINGS[expectedError]
            ?: error("Unrecognized expected_error '$expectedError' in fixture")
        try {
            MessageCodec.decode(ByteArrayInputStream(hexToBytes(encodedHex)))
            fail("Expected ProtocolException for negative case '$caseName'")
        } catch (e: ProtocolException) {
            val msg = e.message?.lowercase() ?: ""
            assertTrue(
                "Expected exception message to contain '$expectedSubstring' but was '${e.message}'",
                msg.contains(expectedSubstring)
            )
        }
    }

    private fun findMessage(name: String): JSONObject {
        val messages = fixture.getJSONArray("messages")
        for (i in 0 until messages.length()) {
            val obj = messages.getJSONObject(i)
            if (obj.getString("name") == name) return obj
        }
        error("Message '$name' not found in fixture")
    }

    private fun loadFixture(): JSONObject {
        val path = "test-fixtures/protocol/l2cap/l2cap_fixture.json"
        val file = findUpwards(path)
            ?: error("Could not locate fixture file: $path from ${System.getProperty("user.dir")}")
        return JSONObject(file.readText())
    }

    private fun findUpwards(relativePath: String): File? {
        var current = File(System.getProperty("user.dir") ?: ".").absoluteFile
        while (true) {
            val candidate = File(current, relativePath)
            if (candidate.exists()) return candidate
            val parent = current.parentFile ?: return null
            if (parent == current) return null
            current = parent
        }
    }

    private fun hexToBytes(hex: String): ByteArray {
        if (hex.isEmpty()) return byteArrayOf()
        require(hex.length % 2 == 0) { "Invalid hex length" }
        return ByteArray(hex.length / 2) { i ->
            val high = Character.digit(hex[2 * i], 16)
            val low = Character.digit(hex[2 * i + 1], 16)
            ((high shl 4) + low).toByte()
        }
    }

    private fun bytesToHex(bytes: ByteArray): String =
        bytes.joinToString("") { "%02x".format(it) }

    companion object {
        /** Maps fixture expected_error values to substrings found in ProtocolException messages. */
        private val ERROR_SUBSTRINGS = mapOf(
            "incomplete_header" to "incomplete header",
            "empty_message" to "empty message",
            "message_too_large" to "message too large",
            "incomplete_body" to "incomplete body"
        )
    }
}
