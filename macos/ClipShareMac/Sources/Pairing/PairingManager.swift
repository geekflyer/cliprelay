import CryptoKit
import Foundation
import Security

final class PairingManager {
    private enum Keys {
        static let token = "pairing_token"
        static let privateKey = "pairing_private_key"
    }

    private let keychain = KeychainStore(service: "clipboard-sync")
    private let defaultSeed = Data("clipboard-sync-dev-seed".utf8)

    func currentSeed() -> Data {
        if let token = pairingToken() {
            return Data(token.utf8)
        }
        return defaultSeed
    }

    func pairingToken() -> String? {
        guard
            let data = keychain.data(for: Keys.token),
            let token = String(data: data, encoding: .utf8),
            !token.isEmpty
        else {
            return nil
        }
        return token
    }

    func generatePairingURI(serviceUUID: String) -> URL? {
        let token = Self.randomHexToken(byteCount: 32)
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let publicKey = privateKey.publicKey.rawRepresentation.base64EncodedString()

        _ = keychain.setData(Data(token.utf8), for: Keys.token)
        _ = keychain.setData(privateKey.rawRepresentation, for: Keys.privateKey)

        return PairingURI.make(
            tokenHex: token,
            serviceUUID: serviceUUID,
            macPublicKeyBase64: publicKey
        )
    }

    static func tokenPrefixData(tokenHex: String, length: Int) -> Data? {
        let normalized = tokenHex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count.isMultiple(of: 2) else {
            return nil
        }

        let full = stride(from: 0, to: normalized.count, by: 2).compactMap { index -> UInt8? in
            let start = normalized.index(normalized.startIndex, offsetBy: index)
            let end = normalized.index(start, offsetBy: 2)
            return UInt8(normalized[start..<end], radix: 16)
        }

        guard full.count * 2 == normalized.count else {
            return nil
        }

        return Data(full.prefix(length))
    }

    private static func randomHexToken(byteCount: Int) -> String {
        var bytes = Data(count: byteCount)
        _ = bytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, byteCount, $0.baseAddress!)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
