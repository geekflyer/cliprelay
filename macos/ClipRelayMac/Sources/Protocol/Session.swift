// Manages a single L2CAP protocol session: handshake, clipboard offer/accept, and payload transfer.

import Foundation
import CommonCrypto
import CryptoKit

// MARK: - Session Delegate

protocol SessionDelegate: AnyObject {
    func sessionDidBecomeReady(_ session: Session)
    func session(_ session: Session, didReceiveClipboard encryptedBlob: Data, hash: String)
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

    /// Queue of outbound clipboard transfers (encrypted blobs).
    private var outboundQueue: [Data] = []
    private let queueLock = NSLock()

    init(inputStream: InputStream, outputStream: OutputStream,
         isInitiator: Bool, delegate: SessionDelegate,
         mode: SessionMode = .normal) {
        self.inputStream = inputStream
        self.outputStream = outputStream
        self.isInitiator = isInitiator
        self.mode = mode
        self.delegate = delegate
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
        // Send HELLO
        let hello = Message(type: .hello, payload: helloPayload())
        try writeMessage(hello)

        // Wait for WELCOME
        let welcome = try readWithTimeout(handshakeTimeoutSeconds)
        guard welcome.type == .welcome else {
            throw SessionError.unexpectedMessage("Expected WELCOME, got \(welcome.type)")
        }
        try validateVersion(welcome.payload)
    }

    private func responderHandshake() throws {
        // Wait for HELLO
        let hello = try readWithTimeout(handshakeTimeoutSeconds)
        guard hello.type == .hello else {
            throw SessionError.unexpectedMessage("Expected HELLO, got \(hello.type)")
        }
        try validateVersion(hello.payload)

        // Send WELCOME
        let welcome = Message(type: .welcome, payload: helloPayload())
        try writeMessage(welcome)
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

    /// Queue a clipboard blob for sending. Thread-safe.
    func sendClipboard(_ encryptedBlob: Data) {
        guard !closed else { return }
        queueLock.lock()
        outboundQueue.append(encryptedBlob)
        queueLock.unlock()
    }

    private func dequeueOutbound() -> Data? {
        queueLock.lock()
        defer { queueLock.unlock() }
        if outboundQueue.isEmpty { return nil }
        return outboundQueue.removeFirst()
    }

    private func doSendClipboard(_ encryptedBlob: Data) throws {
        let hash = Session.sha256Hex(encryptedBlob)
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

        // Verify hash
        let actualHash = Session.sha256Hex(payload.payload)
        guard actualHash == hash else {
            throw SessionError.hashMismatch(expected: hash, actual: actualHash)
        }

        // Notify delegate
        delegate?.session(self, didReceiveClipboard: payload.payload, hash: hash)

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
        var obj: [String: Any] = ["version": 1]
        if let name = localName {
            obj["name"] = name
        }
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data(#"{"version":1}"#.utf8)
    }

    private func validateVersion(_ payload: Data) throws {
        guard let json = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let version = json["version"] as? Int else {
            throw SessionError.protocolError("Invalid version payload")
        }
        guard version == 1 else {
            throw SessionError.versionMismatch(version)
        }
        remoteName = json["name"] as? String
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
