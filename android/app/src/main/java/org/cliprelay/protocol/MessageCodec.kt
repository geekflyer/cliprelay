package org.cliprelay.protocol

// Binary wire format: length-prefixed message types and encoding/decoding for the L2CAP protocol.

import java.io.InputStream
import java.io.OutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

enum class MessageType(val byte: Byte) {
    HELLO(0x01),
    WELCOME(0x02),
    KEY_EXCHANGE(0x03),
    KEY_CONFIRM(0x04),
    OFFER(0x10),
    ACCEPT(0x11),
    PAYLOAD(0x12),
    DONE(0x13);

    companion object {
        fun fromByte(b: Byte): MessageType =
            entries.firstOrNull { it.byte == b }
                ?: throw ProtocolException("Unknown message type: 0x${b.toUByte().toString(16).padStart(2, '0')}")
    }
}

data class Message(val type: MessageType, val payload: ByteArray) {
    override fun equals(other: Any?): Boolean =
        other is Message && type == other.type && payload.contentEquals(other.payload)

    override fun hashCode(): Int =
        31 * type.hashCode() + payload.contentHashCode()
}

open class ProtocolException(message: String) : Exception(message)
class VersionMismatchException(val version: Int) : ProtocolException("Unsupported protocol version: $version")

object MessageCodec {
    const val MAX_MESSAGE_SIZE = 200_000
    private const val HEADER_SIZE = 4

    fun encode(message: Message): ByteArray {
        val messageLength = 1 + message.payload.size // type byte + payload
        val buffer = ByteBuffer.allocate(HEADER_SIZE + messageLength)
        buffer.order(ByteOrder.BIG_ENDIAN)
        buffer.putInt(messageLength)
        buffer.put(message.type.byte)
        buffer.put(message.payload)
        return buffer.array()
    }

    fun decode(input: InputStream): Message {
        val headerBytes = readExactly(input, HEADER_SIZE, "Incomplete header")

        val messageLength = ByteBuffer.wrap(headerBytes).order(ByteOrder.BIG_ENDIAN).int

        if (messageLength <= 0) {
            throw ProtocolException("Empty message: length is $messageLength")
        }

        if (messageLength > MAX_MESSAGE_SIZE) {
            throw ProtocolException("Message too large: $messageLength bytes exceeds maximum of $MAX_MESSAGE_SIZE")
        }

        val body = readExactly(input, messageLength, "Incomplete body")

        val typeByte = body[0]
        val type = MessageType.fromByte(typeByte)
        val payload = body.copyOfRange(1, body.size)

        return Message(type, payload)
    }

    fun write(output: OutputStream, message: Message) {
        output.write(encode(message))
        output.flush()
    }

    private fun readExactly(input: InputStream, count: Int, onFail: String): ByteArray {
        val buffer = ByteArray(count)
        var offset = 0
        while (offset < count) {
            val read = input.read(buffer, offset, count - offset)
            if (read == -1) {
                throw ProtocolException("$onFail: expected $count bytes, got $offset")
            }
            offset += read
        }
        return buffer
    }
}
