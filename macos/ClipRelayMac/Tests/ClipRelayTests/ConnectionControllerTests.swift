import XCTest
@testable import ClipRelay

final class ConnectionControllerTests: XCTestCase {

    private func makeController() -> ConnectionController {
        let pm = PairingManager(keychain: InMemorySecretStore())
        return ConnectionController(pairingManager: pm, skipCentralManager: true)
    }

    // MARK: - Backoff Tests

    func testBackoffSequence() {
        var backoff = ReconnectBackoff()
        let expected: [TimeInterval] = [1.0, 2.0, 4.0, 8.0, 16.0, 30.0, 30.0, 30.0]
        for (i, expectedDelay) in expected.enumerated() {
            let delay = backoff.next()
            XCTAssertEqual(delay, expectedDelay, accuracy: 0.001,
                           "Backoff step \(i): expected \(expectedDelay), got \(delay)")
        }
    }

    func testBackoffResetsToOneSecond() {
        var backoff = ReconnectBackoff()
        _ = backoff.next()
        _ = backoff.next()
        _ = backoff.next()
        backoff.reset()
        XCTAssertEqual(backoff.next(), 1.0, accuracy: 0.001)
    }

    func testBackoffCapAtMaxDelay() {
        var backoff = ReconnectBackoff()
        for _ in 0..<20 {
            let delay = backoff.next()
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

    // MARK: - ClipRelay Manufacturer Data Filter Tests

    func testIsClipRelayManufacturerDataAcceptsValidPayload() {
        let data = Data([0xFF, 0xFF, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x00, 0x83])
        XCTAssertTrue(ConnectionController.isClipRelayManufacturerData(data))
    }

    func testIsClipRelayManufacturerDataRejectsOtherCompanyID() {
        // Apple company ID (0x004C, little-endian 0x4C 0x00) with a full-length
        // payload must not be mistaken for a ClipRelay tag+PSM under broad scan.
        let data = Data([0x4C, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x00, 0x83])
        XCTAssertFalse(ConnectionController.isClipRelayManufacturerData(data))
    }

    func testIsClipRelayManufacturerDataRejectsShortData() {
        let data = Data([0xFF, 0xFF, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x00])
        XCTAssertFalse(ConnectionController.isClipRelayManufacturerData(data))
    }

    func testIsClipRelayManufacturerDataRejectsEmptyData() {
        XCTAssertFalse(ConnectionController.isClipRelayManufacturerData(Data()))
    }

    // MARK: - State Tests

    func testInitialStateIsDisconnected() {
        let controller = makeController()
        XCTAssertFalse(controller.isConnected)
        XCTAssertTrue(controller.connectedTokens.isEmpty)
        XCTAssertNil(controller.connectedToken)
    }

    func testInitialGenerationIsZero() {
        let controller = makeController()
        XCTAssertEqual(controller.generation, 0)
    }

    func testDeviceStateDescriptions() {
        XCTAssertEqual(DeviceState.idle.description, "idle")
        XCTAssertEqual(DeviceState.l2capOpening.description, "l2capOpening")
        XCTAssertEqual(DeviceState.bleConnecting(131).description, "bleConnecting(psm=131)")
    }

    func testDeviceStateReadiness() {
        XCTAssertTrue(DeviceState.idle.isIdle)
        XCTAssertFalse(DeviceState.idle.isReady)
        XCTAssertFalse(DeviceState.l2capOpening.isIdle)
        XCTAssertNil(DeviceState.idle.session)
    }

    func testNewDeviceConnectionStartsIdle() {
        let device = DeviceConnection(token: "aabb")
        XCTAssertTrue(device.state.isIdle)
        XCTAssertNil(device.peripheral)
        XCTAssertEqual(device.nextAttemptAt, .distantPast)
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
