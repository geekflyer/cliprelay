import CryptoKit
import XCTest
@testable import GreenPaste

final class E2ECryptoTests: XCTestCase {
    func testSealOpenRoundTrip() throws {
        let key = SymmetricKey(data: Data(SHA256.hash(data: Data("seed".utf8))))
        let plaintext = Data("hello from swift tests".utf8)

        let blob = try E2ECrypto.seal(plaintext, key: key)
        let reopened = try E2ECrypto.open(blob, key: key)

        XCTAssertEqual(plaintext, reopened)
    }

    func testOpenRejectsTamperedBlob() throws {
        let key = SymmetricKey(data: Data(SHA256.hash(data: Data("seed".utf8))))
        let plaintext = Data("payload".utf8)

        var blob = try E2ECrypto.seal(plaintext, key: key)
        blob[blob.index(before: blob.endIndex)] ^= 0x01

        XCTAssertThrowsError(try E2ECrypto.open(blob, key: key))
    }
}
