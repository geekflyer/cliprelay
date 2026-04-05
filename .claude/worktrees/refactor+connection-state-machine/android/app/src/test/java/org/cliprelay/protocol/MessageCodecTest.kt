package org.cliprelay.protocol

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Test
import java.io.ByteArrayInputStream

class MessageCodecTest {

    @Test
    fun roundTripHello() {
        val msg = Message(MessageType.HELLO, """{"version":1}""".toByteArray())
        assertRoundTrip(msg)
    }

    @Test
    fun roundTripWelcome() {
        val msg = Message(MessageType.WELCOME, """{"version":1}""".toByteArray())
        assertRoundTrip(msg)
    }

    @Test
    fun roundTripOffer() {
        val payload = """{"hash":"abc123","size":100,"type":"text/plain"}""".toByteArray()
        val msg = Message(MessageType.OFFER, payload)
        assertRoundTrip(msg)
    }

    @Test
    fun roundTripAcceptEmptyPayload() {
        val msg = Message(MessageType.ACCEPT, byteArrayOf())
        assertRoundTrip(msg)
    }

    @Test
    fun roundTripPayloadBinaryData() {
        val binary = ByteArray(256) { it.toByte() }
        val msg = Message(MessageType.PAYLOAD, binary)
        assertRoundTrip(msg)
    }

    @Test
    fun roundTripDone() {
        val payload = """{"hash":"abc123","ok":true}""".toByteArray()
        val msg = Message(MessageType.DONE, payload)
        assertRoundTrip(msg)
    }

    @Test
    fun roundTripConfigUpdate() {
        val payload = """{"maxSize":1048576}""".toByteArray()
        val msg = Message(MessageType.CONFIG_UPDATE, payload)
        assertRoundTrip(msg)
    }

    @Test
    fun roundTripReject() {
        val payload = """{"reason":"too_large"}""".toByteArray()
        val msg = Message(MessageType.REJECT, payload)
        assertRoundTrip(msg)
    }

    @Test
    fun roundTripError() {
        val payload = """{"code":500,"message":"internal error"}""".toByteArray()
        val msg = Message(MessageType.ERROR, payload)
        assertRoundTrip(msg)
    }

    @Test
    fun decodeUnknownTypeSkipsToNextMessage() {
        // Unknown type 0xFF with 4-byte payload "test", followed by a valid DONE message
        val unknownMsg = hexToBytes("00000005ff74657374")
        val donePayload = """{"ok":true}""".toByteArray()
        val doneMsg = MessageCodec.encode(Message(MessageType.DONE, donePayload))
        val combined = unknownMsg + doneMsg
        val decoded = MessageCodec.decode(ByteArrayInputStream(combined))
        assertEquals(MessageType.DONE, decoded.type)
        assertArrayEquals(donePayload, decoded.payload)
    }

    @Test(expected = ProtocolException::class)
    fun decodeTruncatedHeaderThrows() {
        val encoded = hexToBytes("0000")
        MessageCodec.decode(ByteArrayInputStream(encoded))
    }

    @Test(expected = ProtocolException::class)
    fun decodeZeroLengthThrows() {
        val encoded = hexToBytes("00000000")
        MessageCodec.decode(ByteArrayInputStream(encoded))
    }

    @Test(expected = ProtocolException::class)
    fun decodeOversizedThrows() {
        val encoded = hexToBytes("00030d4101")
        MessageCodec.decode(ByteArrayInputStream(encoded))
    }

    @Test
    fun decodeIncompleteBodyThrows() {
        // Header says 10 bytes but only 3 bytes of body follow
        val encoded = hexToBytes("0000000a01aabb")
        try {
            MessageCodec.decode(ByteArrayInputStream(encoded))
            fail("Expected ProtocolException")
        } catch (e: ProtocolException) {
            // expected
        }
    }

    @Test
    fun encodeProducesCorrectFormat() {
        val msg = Message(MessageType.HELLO, """{"version":1}""".toByteArray())
        val encoded = MessageCodec.encode(msg)

        // First 4 bytes: length = 14 (1 type + 13 payload) = 0x0000000e
        assertEquals(0x00, encoded[0].toInt() and 0xFF)
        assertEquals(0x00, encoded[1].toInt() and 0xFF)
        assertEquals(0x00, encoded[2].toInt() and 0xFF)
        assertEquals(0x0e, encoded[3].toInt() and 0xFF)
        // 5th byte: type = 0x01
        assertEquals(0x01, encoded[4].toInt() and 0xFF)
    }

    private fun assertRoundTrip(original: Message) {
        val encoded = MessageCodec.encode(original)
        val decoded = MessageCodec.decode(ByteArrayInputStream(encoded))
        assertEquals(original.type, decoded.type)
        assertArrayEquals(original.payload, decoded.payload)
    }

    private fun hexToBytes(hex: String): ByteArray {
        require(hex.length % 2 == 0) { "Invalid hex length" }
        return ByteArray(hex.length / 2) { i ->
            val high = Character.digit(hex[2 * i], 16)
            val low = Character.digit(hex[2 * i + 1], 16)
            ((high shl 4) + low).toByte()
        }
    }
}
