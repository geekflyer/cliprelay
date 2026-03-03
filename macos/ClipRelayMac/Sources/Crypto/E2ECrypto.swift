// AES-256-GCM encryption/decryption and HKDF key derivation for end-to-end clipboard security.

import CryptoKit
import Foundation

enum E2ECrypto {
    private static let aad = Data("cliprelay-v1".utf8)

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
}
