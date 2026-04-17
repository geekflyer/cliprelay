import Foundation
import Security
import XCTest
@testable import ClipRelayCore

final class KeychainStoreTests: XCTestCase {
    func testExplicitKeychainRoundTripsData() throws {
        let keychainPath = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("keychain-db")
        let password = "cliprelay-tests"

        var keychain: SecKeychain?
        let passwordBytes = Array(password.utf8)
        let createStatus = passwordBytes.withUnsafeBytes { bytes in
            SecKeychainCreate(
                keychainPath.path,
                UInt32(passwordBytes.count),
                bytes.baseAddress,
                false,
                nil,
                &keychain
            )
        }
        XCTAssertEqual(createStatus, errSecSuccess)
        defer {
            if let keychain {
                SecKeychainDelete(keychain)
            }
        }

        let store = KeychainStore(
            service: "cliprelay-tests-\(UUID().uuidString)",
            keychainPath: keychainPath.path,
            keychainPassword: password
        )
        let payload = Data("round-trip".utf8)

        XCTAssertTrue(store.setData(payload, for: "paired_devices"))
        XCTAssertEqual(store.data(for: "paired_devices"), payload)
    }
}
