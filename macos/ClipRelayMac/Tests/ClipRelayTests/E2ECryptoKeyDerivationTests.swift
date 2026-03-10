import CryptoKit
import XCTest
@testable import ClipRelay

final class E2ECryptoKeyDerivationTests: XCTestCase {
    /// Known test vector — must match Android E2ECryptoTest.kt
    private let testTokenHex = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"

    func testDeriveKeyReturnsNonNil() {
        XCTAssertNotNil(E2ECrypto.deriveKey(tokenHex: testTokenHex))
    }

    func testDeviceTagReturns8Bytes() {
        let tag = E2ECrypto.deviceTag(tokenHex: testTokenHex)
        XCTAssertNotNil(tag)
        XCTAssertEqual(tag?.count, 8)
    }

    func testDeriveKeyIs32Bytes() {
        let key = E2ECrypto.deriveKey(tokenHex: testTokenHex)
        XCTAssertNotNil(key)
        key?.withUnsafeBytes { bytes in
            XCTAssertEqual(bytes.count, 32)
        }
    }

    func testInvalidHexReturnsNil() {
        XCTAssertNil(E2ECrypto.deriveKey(tokenHex: "not-hex"))
        XCTAssertNil(E2ECrypto.deviceTag(tokenHex: "abc"))  // odd length
    }

    func testDeriveKeyFromSecretBytes() {
        // Use a known 32-byte secret
        let secretBytes = Data(repeating: 0x42, count: 32)
        let key = E2ECrypto.deriveKey(secretBytes: secretBytes)
        XCTAssertNotNil(key)

        let tag = E2ECrypto.deviceTag(secretBytes: secretBytes)
        XCTAssertNotNil(tag)
        XCTAssertEqual(tag!.count, 8)
    }

    func testDeriveKeyFromSecretBytesRejectsWrongSize() {
        XCTAssertNil(E2ECrypto.deriveKey(secretBytes: Data(repeating: 0, count: 16)))
        XCTAssertNil(E2ECrypto.deviceTag(secretBytes: Data(repeating: 0, count: 16)))
    }

    // MARK: - Cross-platform ECDH interop (must match Android E2ECryptoTest.kt)

    /// Golden fixture values from test-fixtures/protocol/l2cap/ecdh_fixture.json
    private let rawEcdhSecretHex = "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742"
    private let expectedRootSecretHex = "b4e4716bc736cde97aa0b585beddab79e190a2531e21bdd410914aeec7a2a4e1"
    private let expectedEncryptionKeyHex = "5b4fd11a1ad6d9e9efa059d2baebf904a9f4f9b7104f9e547f1a68127443ccba"
    private let expectedDeviceTagHex = "a33273934e2b9e80"
    private let expectedPairingTagHex = "300c9c9603b92a4b"
    private let macPublicKeyHex = "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a"

    func testECDHFixtureRootSecret() {
        // root_secret = HKDF-SHA256(ikm=raw_ecdh_secret, salt=empty, info="cliprelay-ecdh-v1", len=32)
        let rawSecret = E2ECrypto.hexToData(rawEcdhSecretHex)!
        let rootKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: rawSecret),
            info: Data("cliprelay-ecdh-v1".utf8),
            outputByteCount: 32
        )
        let rootBytes = rootKey.withUnsafeBytes { Data($0) }
        XCTAssertEqual(dataToHex(rootBytes), expectedRootSecretHex)
    }

    func testECDHFixtureEncryptionKey() {
        // encryption_key = deriveKey(root_secret)
        let rootBytes = E2ECrypto.hexToData(expectedRootSecretHex)!
        let encKey = E2ECrypto.deriveKey(secretBytes: rootBytes)
        XCTAssertNotNil(encKey)
        let encBytes = encKey!.withUnsafeBytes { Data($0) }
        XCTAssertEqual(dataToHex(encBytes), expectedEncryptionKeyHex)
    }

    func testECDHFixtureDeviceTag() {
        // device_tag = deviceTag(root_secret)
        let rootBytes = E2ECrypto.hexToData(expectedRootSecretHex)!
        let tag = E2ECrypto.deviceTag(secretBytes: rootBytes)
        XCTAssertNotNil(tag)
        XCTAssertEqual(dataToHex(tag!), expectedDeviceTagHex)
    }

    func testECDHFixturePairingTag() {
        // pairing_tag = SHA256(mac_public_key)[0:8]
        let macPubBytes = E2ECrypto.hexToData(macPublicKeyHex)!
        let hash = SHA256.hash(data: macPubBytes)
        let pairingTag = Data(Array(hash)[0..<8])
        XCTAssertEqual(dataToHex(pairingTag), expectedPairingTagHex)
    }

    func testECDHFixtureFullDerivationChain() {
        // Verify the full chain: raw_ecdh_secret -> root_secret -> encryption_key + device_tag
        let rawSecret = E2ECrypto.hexToData(rawEcdhSecretHex)!

        // Step 1: Derive root_secret from raw ECDH secret
        let rootKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: rawSecret),
            info: Data("cliprelay-ecdh-v1".utf8),
            outputByteCount: 32
        )
        let rootBytes = rootKey.withUnsafeBytes { Data($0) }

        // Step 2: Derive encryption_key from root_secret
        let encKey = E2ECrypto.deriveKey(secretBytes: rootBytes)!
        let encBytes = encKey.withUnsafeBytes { Data($0) }

        // Step 3: Derive device_tag from root_secret
        let tag = E2ECrypto.deviceTag(secretBytes: rootBytes)!

        // All values must match the fixture
        XCTAssertEqual(dataToHex(rootBytes), expectedRootSecretHex)
        XCTAssertEqual(dataToHex(encBytes), expectedEncryptionKeyHex)
        XCTAssertEqual(dataToHex(tag), expectedDeviceTagHex)
    }

    // MARK: - Helpers

    private func dataToHex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
