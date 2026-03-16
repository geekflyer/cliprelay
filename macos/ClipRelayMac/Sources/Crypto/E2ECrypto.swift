// AES-256-GCM encryption/decryption and HKDF key derivation for end-to-end clipboard security.

import CryptoKit
import Foundation

enum E2ECrypto {
    // Also used for KEY_CONFIRM during pairing — v1 devices cannot pair with v2 devices
    private static let aad = Data("cliprelay-v2".utf8)

    // MARK: - Key derivation (mirrors Android E2ECrypto.kt)

    static func deriveKey(tokenHex: String) -> SymmetricKey? {
        guard let tokenData = hexToData(tokenHex) else { return nil }
        return deriveKey(secretBytes: tokenData)
    }

    static func deviceTag(tokenHex: String) -> Data? {
        guard let tokenData = hexToData(tokenHex) else { return nil }
        return deviceTag(secretBytes: tokenData)
    }

    static func deriveKey(secretBytes: Data) -> SymmetricKey? {
        guard secretBytes.count == 32 else { return nil }
        let ikm = SymmetricKey(data: secretBytes)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            info: Data("cliprelay-enc-v1".utf8),
            outputByteCount: 32
        )
    }

    static func deviceTag(secretBytes: Data) -> Data? {
        guard secretBytes.count == 32 else { return nil }
        let ikm = SymmetricKey(data: secretBytes)
        let tagKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            info: Data("cliprelay-tag-v1".utf8),
            outputByteCount: 8
        )
        return tagKey.withUnsafeBytes { Data($0) }
    }

    // MARK: - ECDH

    static func ecdhSharedSecret(
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        remotePublicKeyBytes: Data
    ) throws -> Data {
        let remotePublic = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remotePublicKeyBytes)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: remotePublic)
        // Derive root secret using HKDF with domain separator
        let key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: Data("cliprelay-ecdh-v1".utf8),
            outputByteCount: 32
        )
        return key.withUnsafeBytes { Data($0) }
    }

    // MARK: - V2 session key derivation (mirrors Android E2ECrypto.kt)

    static func deriveAuthKey(secretBytes: Data) -> SymmetricKey? {
        guard secretBytes.count == 32 else { return nil }
        let ikm = SymmetricKey(data: secretBytes)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            info: Data("cliprelay-auth-v2".utf8),
            outputByteCount: 32
        )
    }

    static func deriveSessionKey(secretBytes: Data, ecdhResult: Data) -> SymmetricKey? {
        guard secretBytes.count == 32, ecdhResult.count == 32 else { return nil }
        var ikm = Data()
        ikm.append(secretBytes)
        ikm.append(ecdhResult)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            info: Data("cliprelay-session-v2".utf8),
            outputByteCount: 32
        )
    }

    static func hmacAuth(publicKeyBytes: Data, authKey: SymmetricKey) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(for: publicKeyBytes, using: authKey)
        return Data(mac)
    }

    static func verifyAuth(publicKeyBytes: Data, authKey: SymmetricKey, expected: Data) -> Bool {
        // Use CryptoKit's constant-time HMAC validation (NOT Data ==, which is not constant-time)
        return HMAC<SHA256>.isValidAuthenticationCode(expected, authenticating: publicKeyBytes, using: authKey)
    }

    static func rawX25519(
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        remotePublicKeyBytes: Data
    ) throws -> Data {
        let remotePublic = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remotePublicKeyBytes)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: remotePublic)
        // Return raw shared secret bytes without HKDF (unlike ecdhSharedSecret)
        // Note: withUnsafeBytes on SharedSecret is undocumented but stable. The rawX25519 fixture
        // test validates this against known RFC 7748 vectors to detect any future breakage.
        return shared.withUnsafeBytes { Data($0) }
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

    static func hexToData(_ hex: String) -> Data? {
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
