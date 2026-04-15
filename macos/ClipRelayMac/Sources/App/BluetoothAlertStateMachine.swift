import CoreBluetooth

enum BluetoothAlertEffect: Equatable {
    case none
    case cancelDebounce(clearWarning: Bool)
    case schedulePoweredOffDebounce
    case showUnauthorizedAlert
}

struct BluetoothAlertStateMachine {
    private(set) var currentState: CBManagerState = .unknown
    private(set) var hasShownAlert = false
    private(set) var isSystemSleeping = false

    mutating func handleBluetoothState(_ state: CBManagerState) -> BluetoothAlertEffect {
        currentState = state

        switch state {
        case .poweredOn:
            hasShownAlert = false
            return .cancelDebounce(clearWarning: true)
        case .unauthorized:
            guard !hasShownAlert else { return .none }
            hasShownAlert = true
            return .showUnauthorizedAlert
        case .poweredOff:
            guard !isSystemSleeping, !hasShownAlert else { return .none }
            return .schedulePoweredOffDebounce
        default:
            return .none
        }
    }

    mutating func handleWillSleep() -> BluetoothAlertEffect {
        isSystemSleeping = true
        return .cancelDebounce(clearWarning: true)
    }

    mutating func handleDidWake() -> BluetoothAlertEffect {
        isSystemSleeping = false
        guard currentState == .poweredOff, !hasShownAlert else { return .none }
        return .schedulePoweredOffDebounce
    }

    mutating func markPoweredOffAlertShown() {
        hasShownAlert = true
    }
}
