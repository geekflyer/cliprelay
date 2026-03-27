import XCTest
@testable import ClipRelay

final class ConnectionControllerTests: XCTestCase {

    private func makeController() -> ConnectionController {
        let pm = PairingManager()
        return ConnectionController(pairingManager: pm, skipCentralManager: true)
    }

    // MARK: - Backoff Tests

    func testBackoffSequence() {
        let controller = makeController()
        let expected: [TimeInterval] = [1.0, 2.0, 4.0, 8.0, 16.0, 30.0, 30.0, 30.0]
        for (i, expectedDelay) in expected.enumerated() {
            let delay = controller.nextReconnectDelay()
            XCTAssertEqual(delay, expectedDelay, accuracy: 0.001,
                           "Backoff step \(i): expected \(expectedDelay), got \(delay)")
        }
    }

    func testBackoffResetsToOneSecond() {
        let controller = makeController()
        _ = controller.nextReconnectDelay()
        _ = controller.nextReconnectDelay()
        _ = controller.nextReconnectDelay()
        controller.resetReconnectDelay()
        XCTAssertEqual(controller.nextReconnectDelay(), 1.0, accuracy: 0.001)
    }

    func testBackoffCapAtMaxDelay() {
        let controller = makeController()
        for _ in 0..<20 {
            let delay = controller.nextReconnectDelay()
            XCTAssertLessThanOrEqual(delay, ConnectionController.maxReconnectDelay)
        }
    }

    // MARK: - Device Tag Extraction Tests

    func testExtractTagFromValidManufacturerData() {
        let data = Data([0xFF, 0xFF, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
        let tag = ConnectionController.extractDeviceTag(from: data)
        XCTAssertNotNil(tag)
        XCTAssertEqual(tag, Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]))
    }

    func testExtractTagFromDataWithPSMTrailing() {
        let data = Data([0xFF, 0xFF, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x11, 0x22, 0x00, 0x83])
        let tag = ConnectionController.extractDeviceTag(from: data)
        XCTAssertNotNil(tag)
        XCTAssertEqual(tag, Data([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x11, 0x22]))
    }

    func testExtractTagReturnsNilForShortData() {
        let data = Data([0xFF, 0xFF, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07])
        XCTAssertNil(ConnectionController.extractDeviceTag(from: data))
    }

    func testExtractTagReturnsNilForEmptyData() {
        XCTAssertNil(ConnectionController.extractDeviceTag(from: Data()))
    }

    func testExtractTagReturnsNilForTwoBytesOnly() {
        let data = Data([0xFF, 0xFF])
        XCTAssertNil(ConnectionController.extractDeviceTag(from: data))
    }

    func testExtractTagExactlyTenBytes() {
        let data = Data([0x00, 0x00, 0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80])
        let tag = ConnectionController.extractDeviceTag(from: data)
        XCTAssertNotNil(tag)
        XCTAssertEqual(tag, Data([0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80]))
    }

    // MARK: - PSM Extraction Tests

    func testExtractPSMFromValidData() {
        let data = Data([0xFF, 0xFF, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x00, 0x83])
        XCTAssertEqual(ConnectionController.extractPSM(from: data), 131)
    }

    func testExtractPSMFromLargerValue() {
        let data = Data([0xFF, 0xFF, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x01, 0x01])
        XCTAssertEqual(ConnectionController.extractPSM(from: data), 257)
    }

    func testExtractPSMReturnsNilForShortData() {
        let data = Data([0xFF, 0xFF, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x00])
        XCTAssertNil(ConnectionController.extractPSM(from: data))
    }

    func testExtractPSMReturnsNilForZeroPSM() {
        let data = Data([0xFF, 0xFF, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x00, 0x00])
        XCTAssertNil(ConnectionController.extractPSM(from: data))
    }

    func testExtractPSMReturnsNilForTagOnlyData() {
        let data = Data([0xFF, 0xFF, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
        XCTAssertNil(ConnectionController.extractPSM(from: data))
    }

    // MARK: - State Tests

    func testInitialStateIsIdle() {
        let controller = makeController()
        XCTAssertEqual(controller.state.description, "idle")
    }

    func testInitialGenerationIsZero() {
        let controller = makeController()
        XCTAssertEqual(controller.generation, 0)
    }

    func testStateDescriptions() {
        XCTAssertEqual(ConnectionState.idle.description, "idle")
        XCTAssertEqual(ConnectionState.scanning.description, "scanning")
    }

    func testStateGenerationNilForIdleAndScanning() {
        XCTAssertNil(ConnectionState.idle.generation)
        XCTAssertNil(ConnectionState.scanning.generation)
    }

    // MARK: - Constants Tests

    func testServiceUUID() {
        XCTAssertEqual(ConnectionController.serviceUUID.uuidString, "C10B0001-1234-5678-9ABC-DEF012345678")
    }

    func testMaxReconnectDelay() {
        XCTAssertEqual(ConnectionController.maxReconnectDelay, 30.0)
    }

    func testHealthCheckInterval() {
        XCTAssertEqual(ConnectionController.healthCheckInterval, 60.0)
    }

    func testConnectingTimeout() {
        XCTAssertEqual(ConnectionController.connectingTimeout, 15.0)
    }

    // MARK: - Image Sync Tests

    func testImageSyncDisabledWhenNotConnected() {
        let controller = makeController()
        XCTAssertFalse(controller.isImageSyncEnabled)
    }

    // MARK: - Send Tests

    func testSendClipboardDoesNotCrashWhenDisconnected() {
        let controller = makeController()
        controller.sendClipboard("hello")
        controller.sendClipboard("hello") // double send should not crash
    }
}
