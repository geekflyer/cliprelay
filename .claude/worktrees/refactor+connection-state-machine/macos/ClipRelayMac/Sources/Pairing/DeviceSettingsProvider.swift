// Wraps PairingManager to conform to SettingsProvider for a specific paired device.

import Foundation

/// Adapter that exposes per-device rich-media settings through the SettingsProvider protocol.
/// Holds a weak reference to PairingManager and the device's shared secret.
final class DeviceSettingsProvider: SettingsProvider {
    private weak var pairingManager: PairingManager?
    private let secret: String

    init(pairingManager: PairingManager, secret: String) {
        self.pairingManager = pairingManager
        self.secret = secret
    }

    func isRichMediaEnabled() -> Bool {
        guard let device = pairingManager?.loadDevices().first(where: { $0.sharedSecret == secret }) else {
            return false
        }
        return device.richMediaEnabled
    }

    func getRichMediaEnabledChangedAt() -> Int64 {
        guard let device = pairingManager?.loadDevices().first(where: { $0.sharedSecret == secret }) else {
            return 0
        }
        return device.richMediaEnabledChangedAt
    }

    func setRichMediaEnabled(_ enabled: Bool, changedAt: Int64) {
        pairingManager?.setRichMediaEnabled(enabled, changedAt: changedAt, forSecret: secret)
    }
}
