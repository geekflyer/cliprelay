import CryptoKit
import Foundation
import Security

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
            print("[Pairing] SecRandomCopyBytes failed with status \(status)")
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
        guard let tokenData = hexToData(token) else { return nil }
        let ikm = SymmetricKey(data: tokenData)
        let tagKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            info: Data("cliprelay-tag-v1".utf8),
            outputByteCount: 8
        )
        let result = tagKey.withUnsafeBytes { Data($0) }
        tagCache[token] = result
        return result
    }

    func encryptionKey(for token: String) -> SymmetricKey? {
        guard let tokenData = hexToData(token) else { return nil }
        let ikm = SymmetricKey(data: tokenData)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            info: Data("cliprelay-enc-v1".utf8),
            outputByteCount: 32
        )
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

    private func hexToData(_ hex: String) -> Data? {
        let chars = Array(hex)
        guard chars.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: chars.count / 2)
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let byte = UInt8(String(chars[i...i + 1]), radix: 16) else { return nil }
            data.append(byte)
        }
        return data
    }
}
