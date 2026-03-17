import XCTest
@testable import ClipRelay

final class MessageCodecTests: XCTestCase {

    // MARK: - Round-trip tests

    func testRoundTripHello() throws {
        let msg = Message(type: .hello, payload: Data(#"{"version":1}"#.utf8))
        try assertRoundTrip(msg)
    }

    func testRoundTripWelcome() throws {
        let msg = Message(type: .welcome, payload: Data(#"{"version":1}"#.utf8))
        try assertRoundTrip(msg)
    }

    func testRoundTripOffer() throws {
        let payload = Data(#"{"hash":"abc123","size":100,"type":"text/plain"}"#.utf8)
        let msg = Message(type: .offer, payload: payload)
        try assertRoundTrip(msg)
    }

    func testRoundTripAcceptEmptyPayload() throws {
        let msg = Message(type: .accept, payload: Data())
        try assertRoundTrip(msg)
    }

    func testRoundTripPayloadBinaryData() throws {
        let binary = Data((0..<256).map { UInt8($0 & 0xFF) })
        let msg = Message(type: .payload, payload: binary)
        try assertRoundTrip(msg)
    }

    func testRoundTripDone() throws {
        let payload = Data(#"{"hash":"abc123","ok":true}"#.utf8)
        let msg = Message(type: .done, payload: payload)
        try assertRoundTrip(msg)
    }

    func testKeyExchangeRoundTrip() {
        let pubkeyJSON = #"{"pubkey":"de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f"}"#
        let message = Message(type: .keyExchange, payload: Data(pubkeyJSON.utf8))
        let encoded = MessageCodec.encode(message)
        var offset = 0
        let decoded = try! MessageCodec.decode(from: encoded, offset: &offset)
        XCTAssertEqual(decoded.type, .keyExchange)
        XCTAssertEqual(String(data: decoded.payload, encoding: .utf8), pubkeyJSON)
    }

    func testKeyConfirmRoundTrip() {
        let payload = Data("encrypted-confirm-data".utf8)
        let message = Message(type: .keyConfirm, payload: payload)
        let encoded = MessageCodec.encode(message)
        var offset = 0
        let decoded = try! MessageCodec.decode(from: encoded, offset: &offset)
        XCTAssertEqual(decoded.type, .keyConfirm)
        XCTAssertEqual(decoded.payload, payload)
    }

    func testRoundTripConfigUpdate() throws {
        let payload = Data(#"{"imageSupport":true}"#.utf8)
        let msg = Message(type: .configUpdate, payload: payload)
        try assertRoundTrip(msg)
    }

    func testRoundTripReject() throws {
        let payload = Data(#"{"reason":"unsupported"}"#.utf8)
        let msg = Message(type: .reject, payload: payload)
        try assertRoundTrip(msg)
    }

    func testRoundTripError() throws {
        let payload = Data(#"{"code":500,"message":"internal error"}"#.utf8)
        let msg = Message(type: .error, payload: payload)
        try assertRoundTrip(msg)
    }

    func testConfigUpdateTypeByte() {
        let msg = Message(type: .configUpdate, payload: Data())
        let encoded = MessageCodec.encode(msg)
        XCTAssertEqual(encoded[4], 0x14)
    }

    func testRejectTypeByte() {
        let msg = Message(type: .reject, payload: Data())
        let encoded = MessageCodec.encode(msg)
        XCTAssertEqual(encoded[4], 0x15)
    }

    func testErrorTypeByte() {
        let msg = Message(type: .error, payload: Data())
        let encoded = MessageCodec.encode(msg)
        XCTAssertEqual(encoded[4], 0x16)
    }

    // MARK: - Error cases

    func testDecodeUnknownTypeSkipsToNextMessage() throws {
        // Unknown type 0xFF with 4 bytes payload, followed by a valid DONE message
        let unknownMsg = hexToData("00000005ff74657374") // type=0xFF, payload="test"
        let donePayload = Data(#"{"ok":true}"#.utf8)
        let doneMsg = MessageCodec.encode(Message(type: .done, payload: donePayload))

        var combined = Data()
        combined.append(unknownMsg)
        combined.append(doneMsg)

        var offset = 0
        let decoded = try MessageCodec.decode(from: combined, offset: &offset)
        XCTAssertEqual(decoded.type, .done)
        XCTAssertEqual(decoded.payload, donePayload)
        XCTAssertEqual(offset, combined.count)
    }

    func testDecodeUnknownTypeFromInputStream() throws {
        // Unknown type 0xFF with 4 bytes payload, followed by a valid DONE message
        let unknownMsg = hexToData("00000005ff74657374")
        let donePayload = Data(#"{"ok":true}"#.utf8)
        let doneMsg = MessageCodec.encode(Message(type: .done, payload: donePayload))

        var combined = Data()
        combined.append(unknownMsg)
        combined.append(doneMsg)

        let stream = InputStream(data: combined)
        stream.open()
        defer { stream.close() }

        let decoded = try MessageCodec.decode(from: stream)
        XCTAssertEqual(decoded.type, .done)
        XCTAssertEqual(decoded.payload, donePayload)
    }

    func testDecodeUnknownTypeOnlyThrowsIncompleteHeader() {
        // Only an unknown message with no valid message after — should throw incompleteHeader
        let encoded = hexToData("00000005ff74657374")
        var offset = 0
        XCTAssertThrowsError(try MessageCodec.decode(from: encoded, offset: &offset)) { error in
            guard case ProtocolError.incompleteHeader = error else {
                XCTFail("Expected incompleteHeader (no more data after skipping unknown), got \(error)")
                return
            }
        }
    }

    func testDecodeTruncatedHeaderThrows() {
        let encoded = hexToData("0000")
        var offset = 0
        XCTAssertThrowsError(try MessageCodec.decode(from: encoded, offset: &offset)) { error in
            guard case ProtocolError.incompleteHeader = error else {
                XCTFail("Expected incompleteHeader, got \(error)")
                return
            }
        }
    }

    func testDecodeZeroLengthThrows() {
        let encoded = hexToData("00000000")
        var offset = 0
        XCTAssertThrowsError(try MessageCodec.decode(from: encoded, offset: &offset)) { error in
            guard case ProtocolError.emptyMessage = error else {
                XCTFail("Expected emptyMessage, got \(error)")
                return
            }
        }
    }

    func testDecodeOversizedThrows() {
        let encoded = hexToData("00030d4101")
        var offset = 0
        XCTAssertThrowsError(try MessageCodec.decode(from: encoded, offset: &offset)) { error in
            guard case ProtocolError.messageTooLarge = error else {
                XCTFail("Expected messageTooLarge, got \(error)")
                return
            }
        }
    }

    func testDecodeIncompleteBodyThrows() {
        // Header says 10 bytes but only 3 bytes of body follow
        let encoded = hexToData("0000000a01aabb")
        var offset = 0
        XCTAssertThrowsError(try MessageCodec.decode(from: encoded, offset: &offset)) { error in
            guard case ProtocolError.incompleteBody = error else {
                XCTFail("Expected incompleteBody, got \(error)")
                return
            }
        }
    }

    // MARK: - Format verification

    func testEncodeProducesCorrectFormat() {
        let msg = Message(type: .hello, payload: Data(#"{"version":1}"#.utf8))
        let encoded = MessageCodec.encode(msg)

        // First 4 bytes: length = 14 (1 type + 13 payload) = 0x0000000e
        XCTAssertEqual(encoded[0], 0x00)
        XCTAssertEqual(encoded[1], 0x00)
        XCTAssertEqual(encoded[2], 0x00)
        XCTAssertEqual(encoded[3], 0x0e)
        // 5th byte: type = 0x01
        XCTAssertEqual(encoded[4], 0x01)
    }

    // MARK: - InputStream decode tests

    func testInputStreamRoundTrip() throws {
        let msg = Message(type: .hello, payload: Data(#"{"version":1}"#.utf8))
        let encoded = MessageCodec.encode(msg)
        let stream = InputStream(data: encoded)
        stream.open()
        defer { stream.close() }
        let decoded = try MessageCodec.decode(from: stream)
        XCTAssertEqual(decoded.type, msg.type)
        XCTAssertEqual(decoded.payload, msg.payload)
    }

    // MARK: - Helpers

    private func assertRoundTrip(_ original: Message) throws {
        let encoded = MessageCodec.encode(original)
        var offset = 0
        let decoded = try MessageCodec.decode(from: encoded, offset: &offset)
        XCTAssertEqual(decoded.type, original.type)
        XCTAssertEqual(decoded.payload, original.payload)
        XCTAssertEqual(offset, encoded.count)
    }

    private func hexToData(_ hex: String) -> Data {
        precondition(hex.count.isMultiple(of: 2), "Invalid hex length")
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            let byte = UInt8(hex[index..<next], radix: 16)!
            data.append(byte)
            index = next
        }
        return data
    }
}
