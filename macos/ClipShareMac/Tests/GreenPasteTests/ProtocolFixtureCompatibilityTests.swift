import CryptoKit
import XCTest
@testable import GreenPaste

final class ProtocolFixtureCompatibilityTests: XCTestCase {
    func testFixtureDecryptsWithDerivedKey() throws {
        let fixture = try ProtocolFixtureLoader.loadV1()
        let key = SymmetricKey(data: Data(SHA256.hash(data: hexToData(fixture.tokenHex))))

        let decrypted = try E2ECrypto.open(fixture.encryptedBlob, key: key)

        XCTAssertEqual(1280, decrypted.count)
        XCTAssertEqual(fixture.plaintextSHA256Hex, SHA256.hash(data: decrypted).hexString)
        XCTAssertEqual(fixture.encryptedSHA256Hex, SHA256.hash(data: fixture.encryptedBlob).hexString)
    }

    func testFixtureFramesReassembleToEncryptedBlob() throws {
        let fixture = try ProtocolFixtureLoader.loadV1()
        let assembler = ChunkAssembler()
        let header = ChunkHeader(
            tx_id: fixture.txID,
            total_chunks: fixture.totalChunks,
            total_bytes: fixture.encryptedBlob.count,
            encoding: "utf-8"
        )

        assembler.reset(with: header)
        fixture.chunkFrames.forEach { assembler.appendChunkFrame($0) }

        XCTAssertTrue(assembler.isComplete())
        XCTAssertEqual(fixture.encryptedBlob, assembler.assembleData())
    }
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

private extension SHA256Digest {
    var hexString: String {
        self.map { String(format: "%02x", $0) }.joined()
    }
}
