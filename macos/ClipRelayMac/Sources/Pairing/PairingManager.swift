// Persists paired device records in Keychain and derives per-device encryption keys.

import CryptoKit
import Foundation
import Security
import os

private let pairingLogger = Logger(subsystem: "org.cliprelay", category: "Pairing")

struct PairedDevice: Codable, Equatable {
    let token: String // 64-char hex
    let displayName: String
    let datePaired: Date
}

final class PairingManager {
    private static let keychainAccount = "paired_devices"
    private static let pendingDisplayNamePrefix = "Pending pairing"
    private let keychain = KeychainStore(service: "cliprelay")
    private var tagCache: [String: Data] = [:]

    func loadDevices() -> [PairedDevice] {
        guard let data = keychain.data(for: Self.keychainAccount) else { return [] }
        return (try? JSONDecoder().decode([PairedDevice].self, from: data)) ?? []
    }

    func addDevice(_ device: PairedDevice) {
        var devices = loadDevices()
        devices.removeAll { $0.token == device.token }
        devices.append(device)
        persist(devices)
    }

    func removeDevice(token: String) {
        var devices = loadDevices()
        devices.removeAll { $0.token == token }
        persist(devices)
    }

    func removePendingDevices() {
        var devices = loadDevices()
        devices.removeAll { $0.displayName.hasPrefix(Self.pendingDisplayNamePrefix) }
        persist(devices)
    }

    func isPendingDeviceToken(_ token: String) -> Bool {
        loadDevices().contains {
            $0.token == token && $0.displayName.hasPrefix(Self.pendingDisplayNamePrefix)
        }
    }

    func generateToken() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            pairingLogger.error("[Pairing] SecRandomCopyBytes failed with status \(status, privacy: .private)")
            return nil
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    func pairingURI(token: String) -> URL? {
        var components = URLComponents()
        components.scheme = "cliprelay"
        components.host = "pair"
        let macName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        components.queryItems = [
            URLQueryItem(name: "t", value: token),
            URLQueryItem(name: "n", value: macName)
        ]
        return components.url
    }

    func deviceTag(for token: String) -> Data? {
        if let cached = tagCache[token] { return cached }
        guard let result = E2ECrypto.deviceTag(tokenHex: token) else { return nil }
        tagCache[token] = result
        return result
    }

    func encryptionKey(for token: String) -> SymmetricKey? {
        return E2ECrypto.deriveKey(tokenHex: token)
    }

    func findDevice(byTag tag: Data) -> PairedDevice? {
        let devices = loadDevices()
        return devices.first { device in
            deviceTag(for: device.token) == tag
        }
    }

    private func persist(_ devices: [PairedDevice]) {
        tagCache.removeAll()
        guard let data = try? JSONEncoder().encode(devices) else { return }
        keychain.setData(data, for: Self.keychainAccount)
    }

}
