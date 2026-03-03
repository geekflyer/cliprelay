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
}
