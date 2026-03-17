// Manages a single L2CAP protocol session: handshake, clipboard offer/accept, and payload transfer.

import Foundation
import CommonCrypto
import CryptoKit
import os

// MARK: - Settings Provider

/// Abstraction so Session can read/write rich-media settings without depending on PairingManager.
protocol SettingsProvider: AnyObject {
    func isRichMediaEnabled() -> Bool
    func getRichMediaEnabledChangedAt() -> Int64
    func setRichMediaEnabled(_ enabled: Bool, changedAt: Int64)
}

// MARK: - Session Delegate

protocol SessionDelegate: AnyObject {
    func sessionDidBecomeReady(_ session: Session)
    func session(_ session: Session, didReceivePlaintext plaintext: Data, hash: String)
    func session(_ session: Session, didCompleteTransfer hash: String)
    func session(_ session: Session, didFailWithError error: Error)
    func session(_ session: Session, alreadyHasHash hash: String) -> Bool
    func session(_ session: Session, didCompletePairingWithSecret sharedSecret: Data, remoteName: String?)
    func session(_ session: Session, didChangeRichMediaSetting enabled: Bool)
    func session(_ session: Session, didReceiveImage data: Data, contentType: String, hash: String)
    func session(_ session: Session, imageWasRejected reason: String)
}

extension SessionDelegate {
    func session(_ session: Session, didChangeRichMediaSetting enabled: Bool) {}
    func session(_ session: Session, didReceiveImage data: Data, contentType: String, hash: String) {}
    func session(_ session: Session, imageWasRejected reason: String) {}
    func session(_ session: Session, imageSendFailed reason: String) {}
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
    private let logger = Logger(subsystem: "org.cliprelay", category: "Session")
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

    /// Settings provider for reading/writing rich-media settings.
    weak var settingsProvider: SettingsProvider?

    /// Queue of outbound clipboard transfers (plaintext).
    private var outboundQueue: [Data] = []
    /// Queue of outbound image transfers: (imageData, contentType).
    private var imageQueue: [(Data, String)] = []
    private var configUpdateQueue: [Message] = []
    private let queueLock = NSLock()

    /// Active TCP image receiver, if any (for cancellation on new inbound offer).
    private var activeReceiver: TcpImageReceiver?

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
                // Drain any queued CONFIG_UPDATE messages first
                if let configMsg = dequeueConfigUpdate() {
                    try writeMessage(configMsg)
                    continue
                }

                // Check for queued image transfers
                if let imageItem = dequeueImage() {
                    try doSendImage(imageItem.0, contentType: imageItem.1)
                    continue
                }

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
            if let json = try? JSONSerialization.jsonObject(with: msg.payload) as? [String: Any],
               let type = json["type"] as? String, type.hasPrefix("image/") {
                try handleInboundImageOffer(msg)
            } else {
                try handleInboundOffer(msg)
            }
        case .configUpdate:
            handleConfigUpdate(msg)
        case .reject:
            break // handled in later task
        case .error:
            break // handled in later task
        default:
            logger.warning("Ignoring unexpected message type: \(String(describing: msg.type))")
        }
    }

    // MARK: - CONFIG_UPDATE

    /// Handle an inbound CONFIG_UPDATE message. Applies last-write-wins to the rich-media setting.
    private func handleConfigUpdate(_ msg: Message) {
        guard let sp = settingsProvider,
              let json = try? JSONSerialization.jsonObject(with: msg.payload) as? [String: Any] else { return }
        let remoteEnabled = json["richMediaEnabled"] as? Bool ?? false
        let remoteChangedAt = (json["richMediaEnabledChangedAt"] as? NSNumber)?.int64Value ?? 0
        let localChangedAt = sp.getRichMediaEnabledChangedAt()
        if remoteChangedAt > localChangedAt {
            sp.setRichMediaEnabled(remoteEnabled, changedAt: remoteChangedAt)
            delegate?.session(self, didChangeRichMediaSetting: remoteEnabled)
        }
    }

    /// Send a CONFIG_UPDATE message with the current rich-media settings.
    /// Can be called from any thread; the message is enqueued for the listen loop.
    func sendConfigUpdate() {
        guard !closed, let sp = settingsProvider else { return }
        let payload: [String: Any] = [
            "richMediaEnabled": sp.isRichMediaEnabled(),
            "richMediaEnabledChangedAt": sp.getRichMediaEnabledChangedAt()
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        let msg = Message(type: .configUpdate, payload: data)
        queueLock.lock()
        configUpdateQueue.append(msg)
        queueLock.unlock()
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

    /// Queue an image for sending. Thread-safe.
    /// The actual transfer happens in the listen loop via TCP.
    func sendImage(_ imageData: Data, contentType: String) {
        guard !closed else { return }
        queueLock.lock()
        imageQueue.append((imageData, contentType))
        queueLock.unlock()
    }

    private func dequeueImage() -> (Data, String)? {
        queueLock.lock()
        defer { queueLock.unlock() }
        if imageQueue.isEmpty { return nil }
        return imageQueue.removeFirst()
    }

    private func dequeueConfigUpdate() -> Message? {
        queueLock.lock()
        defer { queueLock.unlock() }
        if configUpdateQueue.isEmpty { return nil }
        return configUpdateQueue.removeFirst()
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

    // MARK: - Outbound Image Transfer

    private func doSendImage(_ imageData: Data, contentType: String) throws {
        guard let key = sessionKey else {
            throw SessionError.protocolError("No session key available")
        }
        let hash = Session.sha256Hex(imageData)
        guard let senderIp = LocalNetworkAddress.getLocalIPv4Address() else {
            throw SessionError.protocolError("No local IP address available")
        }

        // Send OFFER over BLE
        let offerJSON: [String: Any] = [
            "hash": hash,
            "size": imageData.count,
            "type": contentType,
            "senderIp": senderIp
        ]
        let offerData = try JSONSerialization.data(withJSONObject: offerJSON)
        let offer = Message(type: .offer, payload: offerData)
        try writeMessage(offer)

        // Read response: ACCEPT, REJECT, or ERROR
        let response = try readWithTimeout(transferTimeoutSeconds)
        switch response.type {
        case .accept:
            guard let acceptJson = try? JSONSerialization.jsonObject(with: response.payload) as? [String: Any],
                  let tcpHost = acceptJson["tcpHost"] as? String,
                  let tcpPort = acceptJson["tcpPort"] as? Int else {
                throw SessionError.protocolError("Invalid ACCEPT payload for image")
            }

            // Encrypt image
            let encrypted = try E2ECrypto.seal(imageData, key: key)

            // Push via TCP with retry (2 attempts, 500ms pause)
            var lastError: Error?
            for attempt in 1...2 {
                do {
                    try TcpImageSender.send(host: tcpHost, port: UInt16(tcpPort), data: encrypted)
                    lastError = nil
                    break
                } catch {
                    lastError = error
                    if attempt < 2 { Thread.sleep(forTimeInterval: 0.5) }
                }
            }

            if let err = lastError {
                // Send ERROR over BLE
                let errorJSON: [String: Any] = ["code": "connection_failed"]
                let errorData = try JSONSerialization.data(withJSONObject: errorJSON)
                try writeMessage(Message(type: .error, payload: errorData))
                delegate?.session(self, imageSendFailed: "TCP connection failed: \(err.localizedDescription)")
                return
            }

            // Wait for DONE or ERROR
            let done = try readWithTimeout(transferTimeoutSeconds)
            switch done.type {
            case .done:
                delegate?.session(self, didCompleteTransfer: hash)
            case .error:
                let errorJson = (try? JSONSerialization.jsonObject(with: done.payload) as? [String: Any]) ?? [:]
                let code = errorJson["code"] as? String ?? "unknown"
                logger.warning("Receiver reported error after image transfer: \(code)")
                delegate?.session(self, imageSendFailed: "Receiver error: \(code)")
            default:
                logger.warning("Expected DONE or ERROR after image send, got \(String(describing: done.type))")
                delegate?.session(self, imageSendFailed: "Unexpected response: \(String(describing: done.type))")
            }

        case .reject:
            let rejectJson = (try? JSONSerialization.jsonObject(with: response.payload) as? [String: Any]) ?? [:]
            let reason = rejectJson["reason"] as? String ?? "unknown"
            logger.info("Image rejected: \(reason)")
            delegate?.session(self, imageWasRejected: reason)

        case .error:
            let errorJson = (try? JSONSerialization.jsonObject(with: response.payload) as? [String: Any]) ?? [:]
            let code = errorJson["code"] as? String ?? "unknown"
            logger.warning("Image error from receiver: \(code)")

        default:
            throw SessionError.unexpectedMessage("Expected ACCEPT, REJECT, or ERROR, got \(response.type)")
        }
    }

    // MARK: - Inbound Image Transfer

    private func handleInboundImageOffer(_ msg: Message) throws {
        guard let json = try JSONSerialization.jsonObject(with: msg.payload) as? [String: Any],
              let contentType = json["type"] as? String,
              let size = json["size"] as? Int,
              let hash = json["hash"] as? String,
              let senderIp = json["senderIp"] as? String else {
            throw SessionError.protocolError("Invalid image OFFER payload")
        }

        // Check richMediaEnabled
        guard let sp = settingsProvider, sp.isRichMediaEnabled() else {
            let rejectJSON: [String: Any] = ["reason": "feature_disabled"]
            let rejectData = try JSONSerialization.data(withJSONObject: rejectJSON)
            try writeMessage(Message(type: .reject, payload: rejectData))
            return
        }

        // Check size <= 10MB
        let maxSize = 10 * 1024 * 1024
        if size > maxSize {
            let rejectJSON: [String: Any] = ["reason": "size_exceeded"]
            let rejectData = try JSONSerialization.data(withJSONObject: rejectJSON)
            try writeMessage(Message(type: .reject, payload: rejectData))
            return
        }

        // Cancel any in-flight transfer
        activeReceiver?.cancel()

        // GCM overhead is 28 bytes (12 nonce + 16 tag)
        let expectedSize = size + 28
        let receiver = TcpImageReceiver(
            expectedSize: expectedSize,
            allowedSenderIp: senderIp
        )
        activeReceiver = receiver

        defer {
            receiver.closeServer()
            activeReceiver = nil
        }

        do {
            let serverInfo = try receiver.start()

            // Send ACCEPT with TCP server info
            let acceptJSON: [String: Any] = [
                "tcpHost": serverInfo.host,
                "tcpPort": Int(serverInfo.port)
            ]
            let acceptData = try JSONSerialization.data(withJSONObject: acceptJSON)
            try writeMessage(Message(type: .accept, payload: acceptData))

            // Await TCP data
            let encrypted = try receiver.receive()

            // Decrypt
            guard let key = sessionKey else {
                throw SessionError.protocolError("No session key available")
            }
            let plaintext = try E2ECrypto.open(encrypted, key: key)

            // Verify SHA-256 hash
            let actualHash = Session.sha256Hex(plaintext)
            if actualHash != hash {
                let errorJSON: [String: Any] = ["code": "hash_mismatch"]
                let errorData = try JSONSerialization.data(withJSONObject: errorJSON)
                try writeMessage(Message(type: .error, payload: errorData))
                return
            }

            // Send DONE
            let doneJSON: [String: Any] = ["hash": hash, "ok": true]
            let doneData = try JSONSerialization.data(withJSONObject: doneJSON)
            try writeMessage(Message(type: .done, payload: doneData))

            // Notify delegate
            delegate?.session(self, didReceiveImage: plaintext, contentType: contentType, hash: hash)
        } catch let error as TcpTransferError {
            let errorJSON: [String: Any] = ["code": "transfer_failed"]
            let errorData = (try? JSONSerialization.data(withJSONObject: errorJSON)) ?? Data()
            try? writeMessage(Message(type: .error, payload: errorData))
            logger.error("TCP transfer error: \(error.localizedDescription)")
        } catch {
            let errorJSON: [String: Any] = ["code": "transfer_failed", "message": "\(error.localizedDescription)"]
            let errorData = (try? JSONSerialization.data(withJSONObject: errorJSON)) ?? Data()
            try? writeMessage(Message(type: .error, payload: errorData))
            logger.error("Image receive failed: \(error.localizedDescription)")
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

        // Include settings if available
        if let sp = settingsProvider {
            let settings: [String: Any] = [
                "richMediaEnabled": sp.isRichMediaEnabled(),
                "richMediaEnabledChangedAt": sp.getRichMediaEnabledChangedAt()
            ]
            obj["settings"] = settings
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

        // Resolve settings with last-write-wins
        resolveSettings(json)

        return remoteEkBytes
    }

    /// Resolve remote settings using last-write-wins. If the remote has a newer
    /// `richMediaEnabledChangedAt`, persist the remote value locally.
    private func resolveSettings(_ json: [String: Any]) {
        guard let sp = settingsProvider,
              let remoteSettings = json["settings"] as? [String: Any] else { return }
        let remoteEnabled = remoteSettings["richMediaEnabled"] as? Bool ?? false
        let remoteChangedAt = (remoteSettings["richMediaEnabledChangedAt"] as? NSNumber)?.int64Value ?? 0
        let localChangedAt = sp.getRichMediaEnabledChangedAt()
        if remoteChangedAt > localChangedAt {
            sp.setRichMediaEnabled(remoteEnabled, changedAt: remoteChangedAt)
            delegate?.session(self, didChangeRichMediaSetting: remoteEnabled)
        }
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
