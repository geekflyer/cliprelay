import CryptoKit
import XCTest
@testable import ClipRelay

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

    func testECDHSharedSecret() {
        let macKey = Curve25519.KeyAgreement.PrivateKey()
        let androidKey = Curve25519.KeyAgreement.PrivateKey()
        let secret1 = try! E2ECrypto.ecdhSharedSecret(
            privateKey: macKey,
            remotePublicKeyBytes: androidKey.publicKey.rawRepresentation
        )
        let secret2 = try! E2ECrypto.ecdhSharedSecret(
            privateKey: androidKey,
            remotePublicKeyBytes: macKey.publicKey.rawRepresentation
        )
        XCTAssertEqual(secret1, secret2)
        XCTAssertEqual(secret1.count, 32)
    }

    func testECDHSharedSecretInvalidKey() {
        let key = Curve25519.KeyAgreement.PrivateKey()
        XCTAssertThrowsError(try E2ECrypto.ecdhSharedSecret(
            privateKey: key,
            remotePublicKeyBytes: Data(repeating: 0xFF, count: 10) // wrong size
        ))
    }
}
