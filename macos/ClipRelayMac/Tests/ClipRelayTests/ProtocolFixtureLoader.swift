import Foundation

struct ProtocolFixture: Decodable {
    let txID: String
    let tokenHex: String
    let plaintextBase64: String
    let plaintextSHA256Hex: String
    let encryptedBlobHex: String
    let encryptedSHA256Hex: String
    let totalChunks: Int
    let chunkFramesHex: [String]

    enum CodingKeys: String, CodingKey {
        case txID = "tx_id"
        case tokenHex = "token_hex"
        case plaintextBase64 = "plaintext_base64"
        case plaintextSHA256Hex = "plaintext_sha256_hex"
        case encryptedBlobHex = "encrypted_blob_hex"
        case encryptedSHA256Hex = "encrypted_sha256_hex"
        case totalChunks = "total_chunks"
        case chunkFramesHex = "chunk_frames_hex"
    }

    var plaintext: Data {
        Data(base64Encoded: plaintextBase64) ?? Data()
    }

    var encryptedBlob: Data {
        Data(hex: encryptedBlobHex)
    }

    var chunkFrames: [Data] {
        chunkFramesHex.map(Data.init(hex:))
    }
}

enum ProtocolFixtureLoader {
    static func loadV1() throws -> ProtocolFixture {
        let relativePath = "test-fixtures/protocol/v1/interop_fixture_v1.json"
        guard let fileURL = findFileUpwards(relativePath: relativePath) else {
            throw NSError(domain: "ProtocolFixtureLoader", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Fixture not found: \(relativePath)"
            ])
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(ProtocolFixture.self, from: data)
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

private extension Data {
    init(hex: String) {
        precondition(hex.count.isMultiple(of: 2), "Invalid hex length")
        self.init(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            let byte = UInt8(hex[index..<next], radix: 16)!
            self.append(byte)
            index = next
        }
    }
}
