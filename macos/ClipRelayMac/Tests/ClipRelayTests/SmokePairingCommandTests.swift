import XCTest
@testable import ClipRelayCore

final class SmokePairingCommandTests: XCTestCase {
    func testImportAddsPairedDeviceToStore() {
        let store = InMemoryDataStore()
        let manager = PairingManager(store: store)
        let token = String(repeating: "ab", count: 32)

        let exitCode = SmokePairingCommand.run(
            arguments: ["ClipRelaySmokeCLI", "--smoke-import-pairing", "--token", token, "--name", "Pixel"],
            pairingManager: manager
        )

        XCTAssertEqual(exitCode, 0)
        XCTAssertEqual(manager.loadDevices().map(\.displayName), ["Pixel"])
        XCTAssertEqual(manager.loadDevices().map(\.sharedSecret), [token])
    }

    func testRemoveDeletesPairedDeviceFromStore() {
        let store = InMemoryDataStore()
        let manager = PairingManager(store: store)
        let token = String(repeating: "cd", count: 32)
        manager.addDevice(PairedDevice(sharedSecret: token, displayName: "Pixel", datePaired: Date()))

        let exitCode = SmokePairingCommand.run(
            arguments: ["ClipRelaySmokeCLI", "--smoke-remove-pairing", "--token", token],
            pairingManager: manager
        )

        XCTAssertEqual(exitCode, 0)
        XCTAssertTrue(manager.loadDevices().isEmpty)
    }

    func testRunRejectsInvalidToken() {
        let store = InMemoryDataStore()
        let manager = PairingManager(store: store)

        let exitCode = SmokePairingCommand.run(
            arguments: ["ClipRelaySmokeCLI", "--smoke-import-pairing", "--token", "bad-token"],
            pairingManager: manager
        )

        XCTAssertEqual(exitCode, 2)
        XCTAssertTrue(manager.loadDevices().isEmpty)
    }
}
