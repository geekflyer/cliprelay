import CoreBluetooth
import XCTest
@testable import ClipRelay

final class BluetoothAlertStateMachineTests: XCTestCase {
    func testPoweredOffSchedulesDebounceWhileAwake() {
        var stateMachine = BluetoothAlertStateMachine()

        let effect = stateMachine.handleBluetoothState(.poweredOff)

        XCTAssertEqual(effect, .schedulePoweredOffDebounce)
    }

    func testSleepCancelsPendingAlertAndWakeReschedulesIfStillPoweredOff() {
        var stateMachine = BluetoothAlertStateMachine()

        XCTAssertEqual(stateMachine.handleBluetoothState(.poweredOff), .schedulePoweredOffDebounce)
        XCTAssertEqual(stateMachine.handleWillSleep(), .cancelDebounce(clearWarning: true))
        XCTAssertEqual(stateMachine.handleDidWake(), .schedulePoweredOffDebounce)
    }

    func testWakeDoesNotRescheduleIfBluetoothRecoveredBeforeWakeHandlerRuns() {
        var stateMachine = BluetoothAlertStateMachine()

        XCTAssertEqual(stateMachine.handleBluetoothState(.poweredOff), .schedulePoweredOffDebounce)
        XCTAssertEqual(stateMachine.handleWillSleep(), .cancelDebounce(clearWarning: true))
        XCTAssertEqual(stateMachine.handleBluetoothState(.poweredOn), .cancelDebounce(clearWarning: true))
        XCTAssertEqual(stateMachine.handleDidWake(), .none)
    }

    func testUnauthorizedAlertIsSuppressedUntilBluetoothRecovers() {
        var stateMachine = BluetoothAlertStateMachine()

        XCTAssertEqual(stateMachine.handleBluetoothState(.unauthorized), .showUnauthorizedAlert)
        XCTAssertEqual(stateMachine.handleBluetoothState(.unauthorized), .none)
        XCTAssertEqual(stateMachine.handleBluetoothState(.poweredOn), .cancelDebounce(clearWarning: true))
        XCTAssertEqual(stateMachine.handleBluetoothState(.unauthorized), .showUnauthorizedAlert)
    }

    func testPoweredOffAlertIsSuppressedAfterBeingShownUntilBluetoothRecovers() {
        var stateMachine = BluetoothAlertStateMachine()

        XCTAssertEqual(stateMachine.handleBluetoothState(.poweredOff), .schedulePoweredOffDebounce)
        stateMachine.markPoweredOffAlertShown()
        XCTAssertEqual(stateMachine.handleBluetoothState(.poweredOff), .none)
        XCTAssertEqual(stateMachine.handleBluetoothState(.poweredOn), .cancelDebounce(clearWarning: true))
        XCTAssertEqual(stateMachine.handleBluetoothState(.poweredOff), .schedulePoweredOffDebounce)
    }
}
