import XCTest
@testable import ClipRelay

final class L2capFixtureCompatibilityTests: XCTestCase {

    // MARK: - Encode tests

    func testEncodeMatchesFixtureHello() throws {
        try assertEncodeMatchesFixture(name: "HELLO")
    }

    func testEncodeMatchesFixtureWelcome() throws {
        try assertEncodeMatchesFixture(name: "WELCOME")
    }

    func testEncodeMatchesFixtureKeyExchange() throws {
        try assertEncodeMatchesFixture(name: "KEY_EXCHANGE")
    }

    func testEncodeMatchesFixtureKeyConfirm() throws {
        try assertEncodeMatchesFixture(name: "KEY_CONFIRM")
    }

    func testEncodeMatchesFixtureOffer() throws {
        try assertEncodeMatchesFixture(name: "OFFER")
    }

    func testEncodeMatchesFixtureAccept() throws {
        try assertEncodeMatchesFixture(name: "ACCEPT")
    }

    func testEncodeMatchesFixturePayload() throws {
        try assertEncodeMatchesFixture(name: "PAYLOAD")
    }

    func testEncodeMatchesFixtureDone() throws {
        try assertEncodeMatchesFixture(name: "DONE")
    }

    // MARK: - Decode tests

    func testDecodeMatchesFixtureHello() throws {
        try assertDecodeMatchesFixture(name: "HELLO")
    }

    func testDecodeMatchesFixtureWelcome() throws {
        try assertDecodeMatchesFixture(name: "WELCOME")
    }

    func testDecodeMatchesFixtureKeyExchange() throws {
        try assertDecodeMatchesFixture(name: "KEY_EXCHANGE")
    }

    func testDecodeMatchesFixtureKeyConfirm() throws {
        try assertDecodeMatchesFixture(name: "KEY_CONFIRM")
    }

    func testDecodeMatchesFixtureOffer() throws {
        try assertDecodeMatchesFixture(name: "OFFER")
    }

    func testDecodeMatchesFixtureAccept() throws {
        try assertDecodeMatchesFixture(name: "ACCEPT")
    }

    func testDecodeMatchesFixturePayload() throws {
        try assertDecodeMatchesFixture(name: "PAYLOAD")
    }

    func testDecodeMatchesFixtureDone() throws {
        try assertDecodeMatchesFixture(name: "DONE")
    }

    // MARK: - Negative tests

    func testNegativeUnknownType() throws {
        // Unknown types are now skipped gracefully. When only an unknown-type
        // message is present with no valid message after, decode exhausts the
        // buffer and throws incompleteHeader.
        let fixture = try L2capFixtureLoader.load()
        guard let entry = fixture.negativeCases.first(where: { $0.name == "unknown_type" }) else {
            XCTFail("Negative case 'unknown_type' not found in fixture")
            return
        }
        let encodedData = hexToData(entry.encodedHex)
        var offset = 0
        XCTAssertThrowsError(
            try MessageCodec.decode(from: encodedData, offset: &offset),
            "Expected error after skipping unknown type"
        ) { error in
            guard let protocolError = error as? ProtocolError else {
                XCTFail("Expected ProtocolError, got \(error)")
                return
            }
            // After skipping the unknown message, there's no more data → incompleteHeader
            XCTAssertEqual(protocolError, .incompleteHeader,
                "Expected .incompleteHeader after skipping unknown type, got \(protocolError)")
        }
    }

    func testNegativeTruncatedHeader() throws {
        try assertNegativeCase(name: "truncated_header")
    }

    func testNegativeZeroLength() throws {
        try assertNegativeCase(name: "zero_length")
    }

    func testNegativeOversized() throws {
        try assertNegativeCase(name: "oversized")
    }

    // MARK: - Helpers

    private func assertEncodeMatchesFixture(name: String) throws {
        let fixture = try L2capFixtureLoader.load()
        guard let entry = fixture.messages.first(where: { $0.name == name }) else {
            XCTFail("Message '\(name)' not found in fixture")
            return
        }

        let type = MessageType(rawValue: entry.typeByte)!
        let payload = hexToData(entry.payloadHex)
        let message = Message(type: type, payload: payload)
        let encoded = MessageCodec.encode(message)

        XCTAssertEqual(
            dataToHex(encoded),
            entry.encodedHex,
            "Encoded hex mismatch for \(name)"
        )
    }

    private func assertDecodeMatchesFixture(name: String) throws {
        let fixture = try L2capFixtureLoader.load()
        guard let entry = fixture.messages.first(where: { $0.name == name }) else {
            XCTFail("Message '\(name)' not found in fixture")
            return
        }

        let encodedData = hexToData(entry.encodedHex)
        var offset = 0
        let decoded = try MessageCodec.decode(from: encodedData, offset: &offset)

        XCTAssertEqual(decoded.type.rawValue, entry.typeByte, "Type mismatch for \(name)")
        XCTAssertEqual(decoded.payload, hexToData(entry.payloadHex), "Payload mismatch for \(name)")
    }

    private func assertNegativeCase(name: String) throws {
        let fixture = try L2capFixtureLoader.load()
        guard let entry = fixture.negativeCases.first(where: { $0.name == name }) else {
            XCTFail("Negative case '\(name)' not found in fixture")
            return
        }

        let encodedData = hexToData(entry.encodedHex)
        var offset = 0
        XCTAssertThrowsError(
            try MessageCodec.decode(from: encodedData, offset: &offset),
            "Expected error for negative case '\(name)'"
        ) { error in
            guard let protocolError = error as? ProtocolError else {
                XCTFail("Expected ProtocolError, got \(error)")
                return
            }
            let expectedError = entry.expectedError
            switch expectedError {
            case "unknown_type":
                guard case .unknownType = protocolError else {
                    XCTFail("Expected .unknownType, got \(protocolError)")
                    return
                }
            case "incomplete_header":
                XCTAssertEqual(protocolError, .incompleteHeader,
                    "Expected .incompleteHeader, got \(protocolError)")
            case "empty_message":
                XCTAssertEqual(protocolError, .emptyMessage,
                    "Expected .emptyMessage, got \(protocolError)")
            case "message_too_large":
                guard case .messageTooLarge = protocolError else {
                    XCTFail("Expected .messageTooLarge, got \(protocolError)")
                    return
                }
            default:
                XCTFail("Unrecognized expected_error '\(expectedError)' in fixture")
            }
        }
    }

    private func hexToData(_ hex: String) -> Data {
        if hex.isEmpty { return Data() }
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

    private func dataToHex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Fixture Loader

private struct L2capFixture: Decodable {
    let messages: [FixtureMessage]
    let negativeCases: [NegativeCase]

    enum CodingKeys: String, CodingKey {
        case messages
        case negativeCases = "negative_cases"
    }
}

private struct FixtureMessage: Decodable {
    let name: String
    let typeByte: UInt8
    let payloadHex: String
    let encodedHex: String

    enum CodingKeys: String, CodingKey {
        case name
        case typeByte = "type_byte"
        case payloadHex = "payload_hex"
        case encodedHex = "encoded_hex"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        let typeByteStr = try container.decode(String.self, forKey: .typeByte)
        typeByte = UInt8(typeByteStr, radix: 16)!
        payloadHex = try container.decode(String.self, forKey: .payloadHex)
        encodedHex = try container.decode(String.self, forKey: .encodedHex)
    }
}

private struct NegativeCase: Decodable {
    let name: String
    let encodedHex: String
    let expectedError: String

    enum CodingKeys: String, CodingKey {
        case name
        case encodedHex = "encoded_hex"
        case expectedError = "expected_error"
    }
}

private enum L2capFixtureLoader {
    static func load() throws -> L2capFixture {
        let relativePath = "test-fixtures/protocol/l2cap/l2cap_fixture.json"
        guard let fileURL = findFileUpwards(relativePath: relativePath) else {
            throw NSError(domain: "L2capFixtureLoader", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Fixture not found: \(relativePath)"
            ])
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(L2capFixture.self, from: data)
    }

    private static func findFileUpwards(relativePath: String) -> URL? {
        var current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        while true {
            let candidate = current.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                return nil
            }
            current = parent
        }
    }
}
