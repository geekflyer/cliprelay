// Persists paired device records in Keychain and derives per-device encryption keys.

import CryptoKit
import Foundation
import Security
import os

private let pairingLogger = Logger(subsystem: "org.cliprelay", category: "Pairing")

struct PairedDevice: Codable, Equatable {
    let sharedSecret: String // 64-char hex (ECDH-derived root secret)
    let displayName: String
    let datePaired: Date
    var richMediaEnabled: Bool
    var richMediaEnabledChangedAt: Int64 // Unix seconds

    init(sharedSecret: String, displayName: String, datePaired: Date,
         richMediaEnabled: Bool = false, richMediaEnabledChangedAt: Int64 = 0) {
        self.sharedSecret = sharedSecret
        self.displayName = displayName
        self.datePaired = datePaired
        self.richMediaEnabled = richMediaEnabled
        self.richMediaEnabledChangedAt = richMediaEnabledChangedAt
    }

    // Custom decoding to handle existing data without the new fields
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sharedSecret = try container.decode(String.self, forKey: .sharedSecret)
        displayName = try container.decode(String.self, forKey: .displayName)
        datePaired = try container.decode(Date.self, forKey: .datePaired)
        richMediaEnabled = try container.decodeIfPresent(Bool.self, forKey: .richMediaEnabled) ?? false
        richMediaEnabledChangedAt = try container.decodeIfPresent(Int64.self, forKey: .richMediaEnabledChangedAt) ?? 0
    }
}

final class PairingManager {
    private static let keychainAccount = "paired_devices"
    private static let pendingDisplayNamePrefix = "Pending pairing"
    private let keychain = KeychainStore(service: "cliprelay")
    private var tagCache: [String: Data] = [:]

    /// Ephemeral ECDH key pair for in-progress pairing. Lives only during pairing window.
    private(set) var ephemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey?

    func generateKeyPair() -> Curve25519.KeyAgreement.PrivateKey {
        let key = Curve25519.KeyAgreement.PrivateKey()
        ephemeralPrivateKey = key
        return key
    }

    func clearEphemeralKey() {
        ephemeralPrivateKey = nil
    }

    func loadDevices() -> [PairedDevice] {
        guard let data = keychain.data(for: Self.keychainAccount) else { return [] }
        return (try? JSONDecoder().decode([PairedDevice].self, from: data)) ?? []
    }

    func addDevice(_ device: PairedDevice) {
        var devices = loadDevices()
        devices.removeAll { $0.sharedSecret == device.sharedSecret }
        devices.append(device)
        persist(devices)
    }

    func removeDevice(secret: String) {
        var devices = loadDevices()
        devices.removeAll { $0.sharedSecret == secret }
        persist(devices)
    }

    func setRichMediaEnabled(_ enabled: Bool, changedAt: Int64, forSecret secret: String) {
        var devices = loadDevices()
        guard let index = devices.firstIndex(where: { $0.sharedSecret == secret }) else { return }
        devices[index].richMediaEnabled = enabled
        devices[index].richMediaEnabledChangedAt = changedAt
        persist(devices)
    }

    func removePendingDevices() {
        var devices = loadDevices()
        devices.removeAll { $0.displayName.hasPrefix(Self.pendingDisplayNamePrefix) }
        persist(devices)
    }

    func pairingURI(publicKey: Curve25519.KeyAgreement.PublicKey) -> URL? {
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

    static func pairingTag(from publicKey: Data) -> Data {
        let hash = SHA256.hash(data: publicKey)
        return Data(hash.prefix(8))
    }

    func deviceTag(for secret: String) -> Data? {
        if let cached = tagCache[secret] { return cached }
        guard let secretBytes = E2ECrypto.hexToData(secret) else { return nil }
        guard let result = E2ECrypto.deviceTag(secretBytes: secretBytes) else { return nil }
        tagCache[secret] = result
        return result
    }

    func encryptionKey(for secret: String) -> SymmetricKey? {
        guard let secretBytes = E2ECrypto.hexToData(secret) else { return nil }
        return E2ECrypto.deriveKey(secretBytes: secretBytes)
    }


    private func persist(_ devices: [PairedDevice]) {
        tagCache.removeAll()
        guard let data = try? JSONEncoder().encode(devices) else { return }
        keychain.setData(data, for: Self.keychainAccount)
    }

}
