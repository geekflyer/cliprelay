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

    // MARK: - V2 session fixture tests

    private func loadV2Fixture() throws -> V2SessionFixture {
        try V2SessionFixtureLoader.load()
    }

    func testDeriveAuthKeyMatchesV2Fixture() throws {
        let fixture = try loadV2Fixture()
        let secretBytes = E2ECrypto.hexToData(fixture.sharedSecret)!
        let authKey = E2ECrypto.deriveAuthKey(secretBytes: secretBytes)
        XCTAssertNotNil(authKey)
        let authKeyBytes = authKey!.withUnsafeBytes { Data($0) }
        XCTAssertEqual(dataToHex(authKeyBytes), fixture.derivation.authKey,
            "auth_key must match v2 session fixture")
    }

    func testHmacAuthMatchesV2Fixture() throws {
        let fixture = try loadV2Fixture()
        let secretBytes = E2ECrypto.hexToData(fixture.sharedSecret)!
        let authKey = E2ECrypto.deriveAuthKey(secretBytes: secretBytes)!

        // Verify mac HMAC (over mac ephemeral public key)
        let macPubBytes = E2ECrypto.hexToData(fixture.keyPairs.macEphemeral.publicHex)!
        let macHmac = E2ECrypto.hmacAuth(publicKeyBytes: macPubBytes, authKey: authKey)
        XCTAssertEqual(dataToHex(macHmac), fixture.derivation.authMac,
            "auth_mac must match v2 session fixture")

        // Verify android HMAC (over android ephemeral public key)
        let androidPubBytes = E2ECrypto.hexToData(fixture.keyPairs.androidEphemeral.publicHex)!
        let androidHmac = E2ECrypto.hmacAuth(publicKeyBytes: androidPubBytes, authKey: authKey)
        XCTAssertEqual(dataToHex(androidHmac), fixture.derivation.authAndroid,
            "auth_android must match v2 session fixture")
    }

    func testVerifyAuthAcceptsCorrectHmac() throws {
        let fixture = try loadV2Fixture()
        let secretBytes = E2ECrypto.hexToData(fixture.sharedSecret)!
        let authKey = E2ECrypto.deriveAuthKey(secretBytes: secretBytes)!

        let macPubBytes = E2ECrypto.hexToData(fixture.keyPairs.macEphemeral.publicHex)!
        let expectedHmac = E2ECrypto.hexToData(fixture.derivation.authMac)!
        XCTAssertTrue(E2ECrypto.verifyAuth(publicKeyBytes: macPubBytes, authKey: authKey, expected: expectedHmac))
    }

    func testVerifyAuthRejectsWrongHmac() throws {
        let fixture = try loadV2Fixture()
        let secretBytes = E2ECrypto.hexToData(fixture.sharedSecret)!
        let authKey = E2ECrypto.deriveAuthKey(secretBytes: secretBytes)!

        let macPubBytes = E2ECrypto.hexToData(fixture.keyPairs.macEphemeral.publicHex)!
        var wrongHmac = E2ECrypto.hexToData(fixture.derivation.authMac)!
        wrongHmac[0] ^= 0xFF  // Flip bits in first byte
        XCTAssertFalse(E2ECrypto.verifyAuth(publicKeyBytes: macPubBytes, authKey: authKey, expected: wrongHmac))
    }

    func testRawX25519MatchesV2Fixture() throws {
        let fixture = try loadV2Fixture()
        let macPrivateBytes = E2ECrypto.hexToData(fixture.keyPairs.macEphemeral.privateHex)!
        let androidPubBytes = E2ECrypto.hexToData(fixture.keyPairs.androidEphemeral.publicHex)!

        let macPrivateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: macPrivateBytes)
        let rawEcdh = try E2ECrypto.rawX25519(privateKey: macPrivateKey, remotePublicKeyBytes: androidPubBytes)
        XCTAssertEqual(dataToHex(rawEcdh), fixture.derivation.rawEcdh,
            "raw_ecdh must match RFC 7748 §6.1 expected output")
    }

    func testDeriveSessionKeyMatchesV2Fixture() throws {
        let fixture = try loadV2Fixture()
        let secretBytes = E2ECrypto.hexToData(fixture.sharedSecret)!
        let rawEcdh = E2ECrypto.hexToData(fixture.derivation.rawEcdh)!

        let sessionKey = E2ECrypto.deriveSessionKey(secretBytes: secretBytes, ecdhResult: rawEcdh)
        XCTAssertNotNil(sessionKey)
        let sessionKeyBytes = sessionKey!.withUnsafeBytes { Data($0) }
        XCTAssertEqual(dataToHex(sessionKeyBytes), fixture.derivation.sessionKey,
            "session_key must match v2 session fixture")
    }

    // MARK: - Helpers

    private func dataToHex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - V2 Session Fixture Loader

private struct V2SessionFixture: Decodable {
    let sharedSecret: String
    let keyPairs: KeyPairs
    let derivation: Derivation

    enum CodingKeys: String, CodingKey {
        case sharedSecret = "shared_secret"
        case keyPairs = "key_pairs"
        case derivation
    }

    struct KeyPairs: Decodable {
        let macEphemeral: KeyPair
        let androidEphemeral: KeyPair

        enum CodingKeys: String, CodingKey {
            case macEphemeral = "mac_ephemeral"
            case androidEphemeral = "android_ephemeral"
        }
    }

    struct KeyPair: Decodable {
        let privateHex: String
        let publicHex: String

        enum CodingKeys: String, CodingKey {
            case privateHex = "private_hex"
            case publicHex = "public_hex"
        }
    }

    struct Derivation: Decodable {
        let rawEcdh: String
        let authKey: String
        let authMac: String
        let authAndroid: String
        let sessionKey: String

        enum CodingKeys: String, CodingKey {
            case rawEcdh = "raw_ecdh"
            case authKey = "auth_key"
            case authMac = "auth_mac"
            case authAndroid = "auth_android"
            case sessionKey = "session_key"
        }
    }
}

private enum V2SessionFixtureLoader {
    static func load() throws -> V2SessionFixture {
        let relativePath = "test-fixtures/protocol/l2cap/v2_session_fixture.json"
        guard let fileURL = findFileUpwards(relativePath: relativePath) else {
            throw NSError(domain: "V2SessionFixtureLoader", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Fixture not found: \(relativePath)"
            ])
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(V2SessionFixture.self, from: data)
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
