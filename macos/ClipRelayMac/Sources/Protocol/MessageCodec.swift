// Binary wire format: length-prefixed message types and encoding/decoding for the L2CAP protocol.

import Foundation

enum MessageType: UInt8 {
    case hello = 0x01
    case welcome = 0x02
    case keyExchange = 0x03
    case keyConfirm = 0x04
    case offer = 0x10
    case accept = 0x11
    case payload = 0x12
    case done = 0x13
}

struct Message {
    let type: MessageType
    let payload: Data
}

enum ProtocolError: Error, Equatable {
    case incompleteHeader
    case emptyMessage
    case messageTooLarge(Int)
    case incompleteBody
    case unknownType(UInt8)
}

enum MessageCodec {
    static let maxMessageSize = 200_000
    private static let headerSize = 4

    static func encode(_ message: Message) -> Data {
        let messageLength = UInt32(1 + message.payload.count) // type byte + payload
        var data = Data(capacity: headerSize + Int(messageLength))

        // Write length as uint32 big-endian
        var lengthBE = messageLength.bigEndian
        data.append(Data(bytes: &lengthBE, count: 4))

        // Write type byte
        data.append(message.type.rawValue)

        // Write payload
        data.append(message.payload)

        return data
    }

    /// Decode a message from a Data buffer at a given offset.
    /// Advances `offset` past the consumed bytes on success.
    static func decode(from data: Data, offset: inout Int) throws -> Message {
        guard data.count - offset >= headerSize else {
            throw ProtocolError.incompleteHeader
        }

        let messageLength = Int(
            UInt32(data[offset]) << 24 |
            UInt32(data[offset + 1]) << 16 |
            UInt32(data[offset + 2]) << 8 |
            UInt32(data[offset + 3])
        )

        offset += headerSize

        if messageLength <= 0 {
            throw ProtocolError.emptyMessage
        }

        if messageLength > maxMessageSize {
            throw ProtocolError.messageTooLarge(messageLength)
        }

        guard data.count - offset >= messageLength else {
            throw ProtocolError.incompleteBody
        }

        let typeByte = data[offset]
        guard let type = MessageType(rawValue: typeByte) else {
            throw ProtocolError.unknownType(typeByte)
        }

        let payloadStart = offset + 1
        let payloadEnd = offset + messageLength
        let payload = data[payloadStart..<payloadEnd]

        offset = payloadEnd

        return Message(type: type, payload: Data(payload))
    }

    /// Decode a message from an InputStream (blocking read).
    static func decode(from inputStream: InputStream) throws -> Message {
        let headerBytes = try readExactly(from: inputStream, count: headerSize, onFail: .incompleteHeader)

        let messageLength = Int(
            UInt32(headerBytes[0]) << 24 |
            UInt32(headerBytes[1]) << 16 |
            UInt32(headerBytes[2]) << 8 |
            UInt32(headerBytes[3])
        )

        if messageLength <= 0 {
            throw ProtocolError.emptyMessage
        }

        if messageLength > maxMessageSize {
            throw ProtocolError.messageTooLarge(messageLength)
        }

        let body = try readExactly(from: inputStream, count: messageLength, onFail: .incompleteBody)

        let typeByte = body[0]
        guard let type = MessageType(rawValue: typeByte) else {
            throw ProtocolError.unknownType(typeByte)
        }

        let payload = messageLength > 1 ? Data(body[1...]) : Data()

        return Message(type: type, payload: payload)
    }

    private static func readExactly(from stream: InputStream, count: Int, onFail: ProtocolError) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        var totalRead = 0

        while totalRead < count {
            let read = stream.read(&buffer + totalRead, maxLength: count - totalRead)
            if read <= 0 {
                throw onFail
            }
            totalRead += read
        }

        return buffer
    }
}
