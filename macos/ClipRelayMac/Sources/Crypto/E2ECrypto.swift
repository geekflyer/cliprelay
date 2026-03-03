// AES-256-GCM encryption/decryption and HKDF key derivation for end-to-end clipboard security.

import CryptoKit
import Foundation

enum E2ECrypto {
    private static let aad = Data("cliprelay-v1".utf8)

    // MARK: - Key derivation (mirrors Android E2ECrypto.kt)

    static func deriveKey(tokenHex: String) -> SymmetricKey? {
        guard let tokenData = hexToData(tokenHex) else { return nil }
        let ikm = SymmetricKey(data: tokenData)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            info: Data("cliprelay-enc-v1".utf8),
            outputByteCount: 32
        )
    }

    static func deviceTag(tokenHex: String) -> Data? {
        guard let tokenData = hexToData(tokenHex) else { return nil }
        let ikm = SymmetricKey(data: tokenData)
        let tagKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            info: Data("cliprelay-tag-v1".utf8),
            outputByteCount: 8
        )
        return tagKey.withUnsafeBytes { Data($0) }
    }

    // MARK: - Encryption

    static func seal(_ plaintext: Data, key: SymmetricKey) throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: aad)
        guard let combined = sealed.combined else {
            throw NSError(domain: "E2ECrypto", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to produce combined sealed box",
            ])
        }
        // combined format: nonce (12) + ciphertext + tag (16)
        return combined
    }

    static func open(_ blob: Data, key: SymmetricKey) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: blob)
        return try AES.GCM.open(box, using: key, authenticating: aad)
    }

    // MARK: - Helpers

    private static func hexToData(_ hex: String) -> Data? {
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
