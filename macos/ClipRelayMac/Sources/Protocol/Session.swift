// Manages a single L2CAP protocol session: handshake, clipboard offer/accept, and payload transfer.

import Foundation
import CommonCrypto
import CryptoKit

// MARK: - Session Delegate

protocol SessionDelegate: AnyObject {
    func sessionDidBecomeReady(_ session: Session)
    func session(_ session: Session, didReceivePlaintext plaintext: Data, hash: String)
    func session(_ session: Session, didCompleteTransfer hash: String)
    func session(_ session: Session, didFailWithError error: Error)
    func session(_ session: Session, alreadyHasHash hash: String) -> Bool
    func session(_ session: Session, didCompletePairingWithSecret sharedSecret: Data, remoteName: String?)
}

// MARK: - Session Errors

enum SessionError: Error, Equatable {
    case timeout(String)
    case unexpectedMessage(String)
    case versionMismatch(Int)
    case hashMismatch(expected: String, actual: String)
    case sessionClosed
    case protocolError(String)
}

// MARK: - Session Mode

enum SessionMode {
    case normal
    case pairing(privateKey: Curve25519.KeyAgreement.PrivateKey)
}

// MARK: - Session

/// Manages the L2CAP protocol conversation over a pair of streams.
///
/// Handles:
///   - Handshake (HELLO / WELCOME)
///   - Outbound clipboard transfer (OFFER → ACCEPT → PAYLOAD → DONE)
///   - Inbound clipboard transfer (OFFER → ACCEPT → PAYLOAD → DONE, with dedup)
///   - Continuous message listening
///
/// Session is single-use: once closed or errored, it cannot be reused.
/// Threading: call `listenForMessages()` on a background thread. Use `sendClipboard()`
/// from any thread — it queues the transfer for the listen loop.
final class Session {
    private let inputStream: InputStream
    private let outputStream: OutputStream
    private let isInitiator: Bool
    let mode: SessionMode
    weak var delegate: SessionDelegate?

    var handshakeTimeoutSeconds: TimeInterval = 5.0
    var transferTimeoutSeconds: TimeInterval = 30.0

    /// Local device name sent during handshake. Set before calling performHandshake().
    var localName: String?

    /// Remote device name received during handshake. Available after sessionDidBecomeReady.
    private(set) var remoteName: String?

    private let lock = NSLock()
    private var _closed = false
    private var closed: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _closed }
        set { lock.lock(); _closed = newValue; lock.unlock() }
    }

    /// Queue of outbound clipboard transfers (plaintext).
    private var outboundQueue: [Data] = []
    private let queueLock = NSLock()

    /// Shared secret hex string for deriving auth and session keys.
    private var sharedSecretHex: String?

    /// Auth key derived from the shared secret, used for HMAC authentication during handshake.
    private var authKey: SymmetricKey?

    /// Session key derived during v2 handshake. Used for encrypting/decrypting clipboard payloads.
    private var sessionKey: SymmetricKey?

    /// Ephemeral key pair, generated at handshake start and dropped after session key derivation.
    private var ephemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey?

    init(inputStream: InputStream, outputStream: OutputStream,
         isInitiator: Bool, delegate: SessionDelegate,
         mode: SessionMode = .normal,
         sharedSecretHex: String? = nil) {
        self.inputStream = inputStream
        self.outputStream = outputStream
        self.isInitiator = isInitiator
        self.mode = mode
        self.delegate = delegate
        self.sharedSecretHex = sharedSecretHex

        // Derive auth key from shared secret if available
        if let hex = sharedSecretHex, let secretBytes = E2ECrypto.hexToData(hex) {
            self.authKey = E2ECrypto.deriveAuthKey(secretBytes: secretBytes)
        } else {
            self.authKey = nil
        }
    }

    // MARK: - Handshake

    /// Perform the handshake. Blocks until complete or timeout.
    /// Must be called before `listenForMessages()`.
    func performHandshake() {
        do {
            switch mode {
            case .normal:
                if isInitiator {
                    try initiatorHandshake()
                } else {
                    try responderHandshake()
                }
            case .pairing(let privateKey):
                if isInitiator {
                    try pairingInitiatorHandshake(privateKey: privateKey)
                } else {
                    try pairingResponderHandshake(privateKey: privateKey)
                }
            }
            delegate?.sessionDidBecomeReady(self)
        } catch {
            lock.lock()
            guard !_closed else { lock.unlock(); return }
            _closed = true
            lock.unlock()
            inputStream.close()
            outputStream.close()
            delegate?.session(self, didFailWithError: error)
        }
    }

    private func initiatorHandshake() throws {
        // Generate ephemeral key pair for v2 handshake
        ephemeralPrivateKey = Curve25519.KeyAgreement.PrivateKey()

        // Send HELLO
        let hello = Message(type: .hello, payload: helloPayload())
        try writeMessage(hello)

        // Wait for WELCOME
        let welcome = try readWithTimeout(handshakeTimeoutSeconds)
        guard welcome.type == .welcome else {
            throw SessionError.unexpectedMessage("Expected WELCOME, got \(welcome.type)")
        }
        let remoteEkBytes = try validateVersion(welcome.payload)

        // Derive session key from ECDH
        try deriveSessionKeyAndCleanup(remoteEkBytes: remoteEkBytes)
    }

    private func responderHandshake() throws {
        // Wait for HELLO
        let hello = try readWithTimeout(handshakeTimeoutSeconds)
        guard hello.type == .hello else {
            throw SessionError.unexpectedMessage("Expected HELLO, got \(hello.type)")
        }
        let remoteEkBytes = try validateVersion(hello.payload)

        // Generate ephemeral key pair for v2 handshake
        ephemeralPrivateKey = Curve25519.KeyAgreement.PrivateKey()

        // Send WELCOME
        let welcome = Message(type: .welcome, payload: helloPayload())
        try writeMessage(welcome)

        // Derive session key from ECDH
        try deriveSessionKeyAndCleanup(remoteEkBytes: remoteEkBytes)
    }

    /// Compute ECDH shared secret and derive session key, then drop ephemeral private key.
    private func deriveSessionKeyAndCleanup(remoteEkBytes: Data) throws {
        guard let ephPriv = ephemeralPrivateKey else {
            throw SessionError.protocolError("No ephemeral private key")
        }
        let ecdhResult = try E2ECrypto.rawX25519(privateKey: ephPriv, remotePublicKeyBytes: remoteEkBytes)
        guard let secretHex = sharedSecretHex, let secretBytes = E2ECrypto.hexToData(secretHex) else {
            throw SessionError.protocolError("No shared secret for session key derivation")
        }
        sessionKey = E2ECrypto.deriveSessionKey(secretBytes: secretBytes, ecdhResult: ecdhResult)
        // Drop ephemeral private key
        ephemeralPrivateKey = nil
    }

    // MARK: - Pairing Handshake

    private func pairingInitiatorHandshake(privateKey: Curve25519.KeyAgreement.PrivateKey) throws {
        // Wait for KEY_EXCHANGE from Android (60s timeout for pairing)
        let keyExchange = try readWithTimeout(60.0)
        guard keyExchange.type == .keyExchange else {
            throw SessionError.unexpectedMessage("Expected KEY_EXCHANGE, got \(keyExchange.type)")
        }

        // Parse Android's public key and optional name
        guard let json = try JSONSerialization.jsonObject(with: keyExchange.payload) as? [String: Any],
              let pubkeyHex = json["pubkey"] as? String else {
            throw SessionError.protocolError("Invalid KEY_EXCHANGE payload")
        }
        guard let remoteKeyBytes = E2ECrypto.hexToData(pubkeyHex) else {
            throw SessionError.protocolError("Invalid public key hex")
        }

        // Compute ECDH shared secret
        let sharedSecret = try E2ECrypto.ecdhSharedSecret(
            privateKey: privateKey,
            remotePublicKeyBytes: remoteKeyBytes
        )

        // Derive encryption key for confirmation
        guard let encKey = E2ECrypto.deriveKey(secretBytes: sharedSecret) else {
            throw SessionError.protocolError("Key derivation failed")
        }

        // Send KEY_CONFIRM: encrypt "cliprelay-paired" with derived key
        let confirmPlaintext = Data("cliprelay-paired".utf8)
        let confirmEncrypted = try E2ECrypto.seal(confirmPlaintext, key: encKey)
        let confirm = Message(type: .keyConfirm, payload: confirmEncrypted)
        try writeMessage(confirm)

        // Extract remote name from KEY_EXCHANGE if present
        let exchangeRemoteName = json["name"] as? String

        // Notify delegate of completed pairing
        delegate?.session(self, didCompletePairingWithSecret: sharedSecret, remoteName: exchangeRemoteName)

        // Update shared secret and auth key for the subsequent v2 handshake
        let secretHex = sharedSecret.map { String(format: "%02x", $0) }.joined()
        self.sharedSecretHex = secretHex
        self.authKey = E2ECrypto.deriveAuthKey(secretBytes: sharedSecret)

        // Continue with normal HELLO/WELCOME handshake
        try initiatorHandshake()
    }

    private func pairingResponderHandshake(privateKey: Curve25519.KeyAgreement.PrivateKey) throws {
        // Not used in current architecture (Mac is always initiator)
        throw SessionError.protocolError("Mac cannot be pairing responder")
    }

    // MARK: - Message Loop

    /// Blocking read loop. Call on a dedicated background thread after handshake.
    /// Returns when the session is closed (either normally or on error).
    func listenForMessages() {
        do {
            while !closed {
                // Check for queued outbound transfers
                if let outbound = dequeueOutbound() {
                    try doSendClipboard(outbound)
                    continue
                }

                // Check if data is available (non-blocking)
                if inputStream.hasBytesAvailable {
                    let msg = try MessageCodec.decode(from: inputStream)
                    try handleInbound(msg)
                } else {
                    // Brief sleep to avoid busy-waiting
                    Thread.sleep(forTimeInterval: 0.01)
                }
            }
        } catch {
            lock.lock()
            guard !_closed else { lock.unlock(); return }
            _closed = true
            lock.unlock()
            inputStream.close()
            outputStream.close()
            delegate?.session(self, didFailWithError: error)
        }
    }

    private func handleInbound(_ msg: Message) throws {
        switch msg.type {
        case .offer:
            try handleInboundOffer(msg)
        default:
            throw SessionError.unexpectedMessage("Unexpected message type: \(msg.type)")
        }
    }

    // MARK: - Outbound Transfer

    /// Queue plaintext clipboard data for sending. Thread-safe.
    /// The actual transfer happens in the listen loop.
    /// Session encrypts the data internally using the session key.
    func sendClipboard(_ plaintext: Data) {
        guard !closed else { return }
        queueLock.lock()
        outboundQueue.append(plaintext)
        queueLock.unlock()
    }

    private func dequeueOutbound() -> Data? {
        queueLock.lock()
        defer { queueLock.unlock() }
        if outboundQueue.isEmpty { return nil }
        return outboundQueue.removeFirst()
    }

    private func doSendClipboard(_ plaintext: Data) throws {
        // Hash is computed over plaintext (for dedup across sessions)
        guard let key = sessionKey else {
            throw SessionError.protocolError("No session key available")
        }
        let hash = Session.sha256Hex(plaintext)
        let encryptedBlob = try E2ECrypto.seal(plaintext, key: key)
        let offerJSON: [String: Any] = [
            "hash": hash,
            "size": encryptedBlob.count,
            "type": "text/plain"
        ]
        let offerData = try JSONSerialization.data(withJSONObject: offerJSON)
        let offer = Message(type: .offer, payload: offerData)
        try writeMessage(offer)

        // Wait for ACCEPT or DONE
        let response = try readWithTimeout(transferTimeoutSeconds)
        switch response.type {
        case .accept:
            // Send PAYLOAD
            let payload = Message(type: .payload, payload: encryptedBlob)
            try writeMessage(payload)

            // Wait for DONE
            let done = try readWithTimeout(transferTimeoutSeconds)
            guard done.type == .done else {
                throw SessionError.unexpectedMessage("Expected DONE, got \(done.type)")
            }
            delegate?.session(self, didCompleteTransfer: hash)

        case .done:
            // Receiver already had this hash — dedup
            delegate?.session(self, didCompleteTransfer: hash)

        default:
            throw SessionError.unexpectedMessage("Expected ACCEPT or DONE, got \(response.type)")
        }
    }

    // MARK: - Inbound Transfer

    private func handleInboundOffer(_ msg: Message) throws {
        guard let json = try JSONSerialization.jsonObject(with: msg.payload) as? [String: Any],
              let hash = json["hash"] as? String else {
            throw SessionError.protocolError("Invalid OFFER payload")
        }

        if delegate?.session(self, alreadyHasHash: hash) == true {
            // Dedup — send DONE immediately
            let doneJSON: [String: Any] = ["hash": hash, "ok": true]
            let doneData = try JSONSerialization.data(withJSONObject: doneJSON)
            let done = Message(type: .done, payload: doneData)
            try writeMessage(done)
            return
        }

        // Send ACCEPT
        let accept = Message(type: .accept, payload: Data())
        try writeMessage(accept)

        // Wait for PAYLOAD
        let payload = try readWithTimeout(transferTimeoutSeconds)
        guard payload.type == .payload else {
            throw SessionError.unexpectedMessage("Expected PAYLOAD, got \(payload.type)")
        }

        // Decrypt payload
        guard let key = sessionKey else {
            throw SessionError.protocolError("No session key available")
        }
        let plaintext = try E2ECrypto.open(payload.payload, key: key)

        // Verify hash against plaintext
        let actualHash = Session.sha256Hex(plaintext)
        guard actualHash == hash else {
            throw SessionError.hashMismatch(expected: hash, actual: actualHash)
        }

        // Notify delegate with plaintext
        delegate?.session(self, didReceivePlaintext: plaintext, hash: hash)

        // Send DONE
        let doneJSON: [String: Any] = ["hash": hash, "ok": true]
        let doneData = try JSONSerialization.data(withJSONObject: doneJSON)
        let done = Message(type: .done, payload: doneData)
        try writeMessage(done)
    }

    // MARK: - Lifecycle

    /// Close the session. Can be called from any thread.
    func close() {
        lock.lock()
        guard !_closed else { lock.unlock(); return }
        _closed = true
        lock.unlock()
        // Clear ephemeral key material
        ephemeralPrivateKey = nil
        sessionKey = nil
        inputStream.close()
        outputStream.close()
    }

    // MARK: - Helpers

    private func readWithTimeout(_ timeout: TimeInterval) throws -> Message {
        let deadline = Date().addingTimeInterval(timeout)
        while !closed {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                throw SessionError.timeout("Timeout waiting for message (\(timeout)s)")
            }
            if inputStream.hasBytesAvailable {
                return try MessageCodec.decode(from: inputStream)
            }
            Thread.sleep(forTimeInterval: min(0.01, remaining))
        }
        throw SessionError.sessionClosed
    }

    private func writeMessage(_ message: Message) throws {
        let encoded = MessageCodec.encode(message)
        try encoded.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            let pointer = baseAddress.assumingMemoryBound(to: UInt8.self)
            var totalWritten = 0
            while totalWritten < encoded.count {
                let written = outputStream.write(
                    pointer.advanced(by: totalWritten),
                    maxLength: encoded.count - totalWritten
                )
                if written <= 0 {
                    throw SessionError.protocolError("Write failed")
                }
                totalWritten += written
            }
        }
    }

    private func helloPayload() -> Data {
        var obj: [String: Any] = ["version": 2]
        if let name = localName {
            obj["name"] = name
        }

        // Include ephemeral key and auth for v2 handshake (when authKey is available)
        if let authKey = authKey, let ephPriv = ephemeralPrivateKey {
            let ekBytes = ephPriv.publicKey.rawRepresentation
            let ekHex = ekBytes.map { String(format: "%02x", $0) }.joined()
            obj["ek"] = ekHex
            let authBytes = E2ECrypto.hmacAuth(publicKeyBytes: Data(ekBytes), authKey: authKey)
            let authHex = authBytes.map { String(format: "%02x", $0) }.joined()
            obj["auth"] = authHex
        }

        return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data(#"{"version":2}"#.utf8)
    }

    /// Validate handshake payload: version must be 2, ek must be valid, auth must verify.
    /// Returns the remote ephemeral public key bytes.
    @discardableResult
    private func validateVersion(_ payload: Data) throws -> Data {
        guard let json = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let version = json["version"] as? Int else {
            throw SessionError.protocolError("Invalid version payload")
        }
        guard version == 2 else {
            throw SessionError.versionMismatch(version)
        }
        remoteName = json["name"] as? String

        // Validate ephemeral key
        guard let ekHex = json["ek"] as? String,
              ekHex.count == 64,
              ekHex.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil else {
            throw SessionError.protocolError("Invalid ephemeral key")
        }
        guard let remoteEkBytes = E2ECrypto.hexToData(ekHex) else {
            throw SessionError.protocolError("Invalid ephemeral key hex")
        }

        // Validate auth HMAC
        guard let authHex = json["auth"] as? String, !authHex.isEmpty else {
            throw SessionError.protocolError("Authentication failed")
        }
        guard let authBytes = E2ECrypto.hexToData(authHex) else {
            throw SessionError.protocolError("Authentication failed")
        }
        guard let authKey = authKey else {
            throw SessionError.protocolError("No auth key for validation")
        }
        guard E2ECrypto.verifyAuth(publicKeyBytes: remoteEkBytes, authKey: authKey, expected: authBytes) else {
            throw SessionError.protocolError("Authentication failed")
        }

        return remoteEkBytes
    }

    /// Compute SHA-256 hex digest of data.
    static func sha256Hex(_ data: Data) -> String {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { rawBuffer in
            _ = CC_SHA256(rawBuffer.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
