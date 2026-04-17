// Persists paired device records in Keychain and derives per-device encryption keys.

import CryptoKit
import Foundation
import os

private let pairingLogger = Logger(subsystem: "org.cliprelay", category: "Pairing")

package struct PairedDevice: Codable, Equatable {
    package let sharedSecret: String // 64-char hex (ECDH-derived root secret)
    package let displayName: String
    package let datePaired: Date
    package var richMediaEnabled: Bool
    package var richMediaEnabledChangedAt: Int64 // Unix seconds

    package init(sharedSecret: String, displayName: String, datePaired: Date,
                 richMediaEnabled: Bool = false, richMediaEnabledChangedAt: Int64 = 0) {
        self.sharedSecret = sharedSecret
        self.displayName = displayName
        self.datePaired = datePaired
        self.richMediaEnabled = richMediaEnabled
        self.richMediaEnabledChangedAt = richMediaEnabledChangedAt
    }

    // Custom decoding to handle existing data without the new fields
    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sharedSecret = try container.decode(String.self, forKey: .sharedSecret)
        displayName = try container.decode(String.self, forKey: .displayName)
        datePaired = try container.decode(Date.self, forKey: .datePaired)
        richMediaEnabled = try container.decodeIfPresent(Bool.self, forKey: .richMediaEnabled) ?? false
        richMediaEnabledChangedAt = try container.decodeIfPresent(Int64.self, forKey: .richMediaEnabledChangedAt) ?? 0
    }
}

package final class PairingManager {
    private static let keychainAccount = "paired_devices"
    private static let keychainService = ProcessInfo.processInfo.environment["CLIPRELAY_PAIRING_KEYCHAIN_SERVICE"] ?? "cliprelay"
    private static let keychainPath = ProcessInfo.processInfo.environment["CLIPRELAY_PAIRING_KEYCHAIN_PATH"]
    private static let keychainPassword = ProcessInfo.processInfo.environment["CLIPRELAY_PAIRING_KEYCHAIN_PASSWORD"]
    private static let pendingDisplayNamePrefix = "Pending pairing"
    private let store: any SecureDataStore
    private var tagCache: [String: Data] = [:]

    /// Ephemeral ECDH key pair for in-progress pairing. Lives only during pairing window.
    package private(set) var ephemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey?

    package init(store: (any SecureDataStore)? = nil) {
        self.store = store ?? KeychainStore(
            service: Self.keychainService,
            keychainPath: Self.keychainPath,
            keychainPassword: Self.keychainPassword
        )
    }

    package func generateKeyPair() -> Curve25519.KeyAgreement.PrivateKey {
        let key = Curve25519.KeyAgreement.PrivateKey()
        ephemeralPrivateKey = key
        return key
    }

    package func clearEphemeralKey() {
        ephemeralPrivateKey = nil
    }

    package func loadDevices() -> [PairedDevice] {
        guard let data = store.data(for: Self.keychainAccount) else { return [] }
        return (try? JSONDecoder().decode([PairedDevice].self, from: data)) ?? []
    }

    @discardableResult
    package func addDevice(_ device: PairedDevice) -> Bool {
        var devices = loadDevices()
        devices.removeAll { $0.sharedSecret == device.sharedSecret }
        devices.append(device)
        return persist(devices)
    }

    @discardableResult
    package func removeDevice(secret: String) -> Bool {
        var devices = loadDevices()
        devices.removeAll { $0.sharedSecret == secret }
        return persist(devices)
    }

    @discardableResult
    package func setRichMediaEnabled(_ enabled: Bool, changedAt: Int64, forSecret secret: String) -> Bool {
        var devices = loadDevices()
        guard let index = devices.firstIndex(where: { $0.sharedSecret == secret }) else { return false }
        devices[index].richMediaEnabled = enabled
        devices[index].richMediaEnabledChangedAt = changedAt
        return persist(devices)
    }

    @discardableResult
    package func removePendingDevices() -> Bool {
        var devices = loadDevices()
        devices.removeAll { $0.displayName.hasPrefix(Self.pendingDisplayNamePrefix) }
        return persist(devices)
    }

    package func pairingURI(publicKey: Curve25519.KeyAgreement.PublicKey) -> URL? {
        let pubHex = publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
        var components = URLComponents()
        components.scheme = "cliprelay"
        components.host = "pair"
        let macName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        components.queryItems = [
            URLQueryItem(name: "k", value: pubHex),
            URLQueryItem(name: "n", value: macName)
        ]
        return components.url
    }

    package static func pairingTag(from publicKey: Data) -> Data {
        let hash = SHA256.hash(data: publicKey)
        return Data(hash.prefix(8))
    }

    package func deviceTag(for secret: String) -> Data? {
        if let cached = tagCache[secret] { return cached }
        guard let secretBytes = E2ECrypto.hexToData(secret) else { return nil }
        guard let result = E2ECrypto.deviceTag(secretBytes: secretBytes) else { return nil }
        tagCache[secret] = result
        return result
    }

    package func encryptionKey(for secret: String) -> SymmetricKey? {
        guard let secretBytes = E2ECrypto.hexToData(secret) else { return nil }
        return E2ECrypto.deriveKey(secretBytes: secretBytes)
    }


    @discardableResult
    private func persist(_ devices: [PairedDevice]) -> Bool {
        tagCache.removeAll()
        if devices.isEmpty {
            return store.removeData(for: Self.keychainAccount)
        }
        guard let data = try? JSONEncoder().encode(devices) else { return false }
        return store.setData(data, for: Self.keychainAccount)
    }

}
