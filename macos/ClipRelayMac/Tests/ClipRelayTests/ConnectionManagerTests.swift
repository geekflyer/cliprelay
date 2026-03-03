import XCTest
@testable import ClipRelay

final class ConnectionManagerTests: XCTestCase {

    // MARK: - Reconnect Backoff Tests

    func testBackoffSequence() {
        // Create a ConnectionManager without initializing CBCentralManager
        // to avoid Bluetooth permission prompts during tests.
        let manager = ConnectionManager(skipCentralManager: true)

        // Expected sequence: 1, 2, 4, 8, 16, 30, 30, 30
        let expected: [TimeInterval] = [1.0, 2.0, 4.0, 8.0, 16.0, 30.0, 30.0, 30.0]
        for (i, expectedDelay) in expected.enumerated() {
            let delay = manager.nextReconnectDelay()
            XCTAssertEqual(delay, expectedDelay, accuracy: 0.001,
                           "Backoff step \(i): expected \(expectedDelay), got \(delay)")
        }
    }

    func testBackoffResetsToOneSecond() {
        let manager = ConnectionManager(skipCentralManager: true)

        // Advance backoff a few times
        _ = manager.nextReconnectDelay()  // 1
        _ = manager.nextReconnectDelay()  // 2
        _ = manager.nextReconnectDelay()  // 4

        // Reset
        manager.resetReconnectDelay()

        // Should start back at 1
        let delay = manager.nextReconnectDelay()
        XCTAssertEqual(delay, 1.0, accuracy: 0.001)
    }

    func testBackoffCapAtMaxDelay() {
        let manager = ConnectionManager(skipCentralManager: true)

        // Run many iterations to ensure we never exceed the cap
        for _ in 0..<20 {
            let delay = manager.nextReconnectDelay()
            XCTAssertLessThanOrEqual(delay, ConnectionManager.maxReconnectDelay)
        }
    }

    // MARK: - Device Tag Extraction Tests

    func testExtractTagFromValidManufacturerData() {
        // 2-byte company ID (0xFF, 0xFF) + 8-byte tag
        let companyID: [UInt8] = [0xFF, 0xFF]
        let tag: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]
        let mfgData = Data(companyID + tag)

        let extracted = ConnectionManager.extractDeviceTag(from: mfgData)
        XCTAssertNotNil(extracted)
        XCTAssertEqual(extracted, Data(tag))
    }

    func testExtractTagFromDataWithExtraTrailingBytes() {
        // 2-byte company ID + 8-byte tag + extra bytes (should still work)
        let companyID: [UInt8] = [0xFF, 0xFF]
        let tag: [UInt8] = [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x11, 0x22]
        let extra: [UInt8] = [0x99, 0x88]
        let mfgData = Data(companyID + tag + extra)

        let extracted = ConnectionManager.extractDeviceTag(from: mfgData)
        XCTAssertNotNil(extracted)
        XCTAssertEqual(extracted, Data(tag))
    }

    func testExtractTagReturnsNilForShortData() {
        // Only 9 bytes (need at least 10: 2 company + 8 tag)
        let shortData = Data([0xFF, 0xFF, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07])
        XCTAssertNil(ConnectionManager.extractDeviceTag(from: shortData))
    }

    func testExtractTagReturnsNilForEmptyData() {
        XCTAssertNil(ConnectionManager.extractDeviceTag(from: Data()))
    }

    func testExtractTagReturnsNilForTwoBytesOnly() {
        // Just company ID, no tag
        let twoBytes = Data([0xFF, 0xFF])
        XCTAssertNil(ConnectionManager.extractDeviceTag(from: twoBytes))
    }

    func testExtractTagExactlyTenBytes() {
        // Exactly the minimum: 2 + 8 = 10
        let mfgData = Data([0x00, 0x00, 0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80])
        let extracted = ConnectionManager.extractDeviceTag(from: mfgData)
        XCTAssertNotNil(extracted)
        XCTAssertEqual(extracted, Data([0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80]))
    }

    // MARK: - State Enum Tests

    func testStateIdleEquality() {
        XCTAssertEqual(ConnectionManager.State.idle, ConnectionManager.State.idle)
    }

    func testStateScanningEquality() {
        XCTAssertEqual(ConnectionManager.State.scanning, ConnectionManager.State.scanning)
    }

    func testDifferentStatesAreNotEqual() {
        XCTAssertNotEqual(ConnectionManager.State.idle, ConnectionManager.State.scanning)
    }

    func testInitialStateIsIdle() {
        let manager = ConnectionManager(skipCentralManager: true)
        XCTAssertEqual(manager.state, .idle)
    }

    // MARK: - UUID Constants Tests

    func testServiceUUIDIsCorrect() {
        XCTAssertEqual(ConnectionManager.serviceUUID.uuidString, "C10B0001-1234-5678-9ABC-DEF012345678")
    }

    func testPSMCharUUIDIsCorrect() {
        XCTAssertEqual(ConnectionManager.psmCharUUID.uuidString, "C10B0010-1234-5678-9ABC-DEF012345678")
    }

    func testMaxReconnectDelay() {
        XCTAssertEqual(ConnectionManager.maxReconnectDelay, 30.0)
    }
}
