import XCTest
@testable import ClipRelay

/// Tests for PairedDevice rich media settings persistence and defaults.
final class PairedDeviceTests: XCTestCase {

    // MARK: - Default values

    func testRichMediaEnabledDefaultsToFalse() {
        let device = PairedDevice(sharedSecret: "aabb", displayName: "Test", datePaired: Date())
        XCTAssertFalse(device.richMediaEnabled)
    }

    func testRichMediaEnabledChangedAtDefaultsToZero() {
        let device = PairedDevice(sharedSecret: "aabb", displayName: "Test", datePaired: Date())
        XCTAssertEqual(device.richMediaEnabledChangedAt, 0)
    }

    // MARK: - Codable round-trip

    func testRichMediaSettingsRoundTrip() throws {
        var device = PairedDevice(sharedSecret: "aabb", displayName: "Test", datePaired: Date())
        device.richMediaEnabled = true
        device.richMediaEnabledChangedAt = 1700000000

        let data = try JSONEncoder().encode([device])
        let decoded = try JSONDecoder().decode([PairedDevice].self, from: data)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertTrue(decoded[0].richMediaEnabled)
        XCTAssertEqual(decoded[0].richMediaEnabledChangedAt, 1700000000)
    }

    func testDecodingLegacyDataWithoutRichMediaFields() throws {
        // Simulate JSON from before rich media fields were added
        let legacyJSON = """
        [{"sharedSecret":"aabb","displayName":"OldDevice","datePaired":0}]
        """
        let data = legacyJSON.data(using: .utf8)!
        let decoded = try JSONDecoder().decode([PairedDevice].self, from: data)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertFalse(decoded[0].richMediaEnabled)
        XCTAssertEqual(decoded[0].richMediaEnabledChangedAt, 0)
    }

    func testRichMediaDisabledRoundTrip() throws {
        let device = PairedDevice(sharedSecret: "ccdd", displayName: "Phone",
                                  datePaired: Date(), richMediaEnabled: false,
                                  richMediaEnabledChangedAt: 42)

        let data = try JSONEncoder().encode([device])
        let decoded = try JSONDecoder().decode([PairedDevice].self, from: data)

        XCTAssertFalse(decoded[0].richMediaEnabled)
        XCTAssertEqual(decoded[0].richMediaEnabledChangedAt, 42)
    }

    // MARK: - PairingManager integration (uses real Keychain)

    func testSetRichMediaEnabledUpdatesDevice() {
        let manager = PairingManager()
        let secret = "ff" + String(repeating: "00", count: 31)
        let device = PairedDevice(sharedSecret: secret, displayName: "RichMediaTest", datePaired: Date())

        // Clean up any leftover from previous test runs
        manager.removeDevice(secret: secret)

        manager.addDevice(device)

        let now = Int64(Date().timeIntervalSince1970)
        manager.setRichMediaEnabled(true, changedAt: now, forSecret: secret)

        let devices = manager.loadDevices()
        let found = devices.first { $0.sharedSecret == secret }
        XCTAssertNotNil(found)
        XCTAssertTrue(found!.richMediaEnabled)
        XCTAssertEqual(found!.richMediaEnabledChangedAt, now)

        // Clean up
        manager.removeDevice(secret: secret)
    }

    func testClearRichMediaBySettingFalse() {
        let manager = PairingManager()
        let secret = "ee" + String(repeating: "00", count: 31)
        let device = PairedDevice(sharedSecret: secret, displayName: "ClearTest", datePaired: Date())

        manager.removeDevice(secret: secret)
        manager.addDevice(device)

        let t1 = Int64(Date().timeIntervalSince1970)
        manager.setRichMediaEnabled(true, changedAt: t1, forSecret: secret)
        let t2 = t1 + 10
        manager.setRichMediaEnabled(false, changedAt: t2, forSecret: secret)

        let devices = manager.loadDevices()
        let found = devices.first { $0.sharedSecret == secret }
        XCTAssertNotNil(found)
        XCTAssertFalse(found!.richMediaEnabled)
        XCTAssertEqual(found!.richMediaEnabledChangedAt, t2)

        manager.removeDevice(secret: secret)
    }
}
