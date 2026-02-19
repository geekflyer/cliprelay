import CryptoKit
import Foundation

enum E2ECrypto {
    static func makePrivateKey() -> Curve25519.KeyAgreement.PrivateKey {
        Curve25519.KeyAgreement.PrivateKey()
    }

    static func deriveSharedSecret(
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        peerPublicKeyRaw: Data
    ) throws -> SymmetricKey {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKeyRaw)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        return shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("clipboard-sync".utf8),
            sharedInfo: Data(),
            outputByteCount: 32
        )
    }

    static func seal(_ plaintext: Data, key: SymmetricKey) throws -> Data {
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: Data("clipboard-sync-v1".utf8))
        return nonce.withUnsafeBytes { nonceBytes in
            Data(nonceBytes) + sealed.ciphertext + sealed.tag
        }
    }

    static func open(_ blob: Data, key: SymmetricKey) throws -> Data {
        guard blob.count > 28 else { throw NSError(domain: "E2ECrypto", code: 1) }
        let nonceData = blob.prefix(12)
        let tag = blob.suffix(16)
        let ciphertext = blob.dropFirst(12).dropLast(16)
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        return try AES.GCM.open(box, using: key, authenticating: Data("clipboard-sync-v1".utf8))
    }
}
