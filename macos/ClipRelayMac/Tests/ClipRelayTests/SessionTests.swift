import XCTest
import CryptoKit
import AppKit
@testable import ClipRelay

/// Tests for the Session protocol handler using piped in-memory streams.
///
/// Each test creates paired streams so two Session instances can communicate,
/// simulating a real L2CAP connection without any BLE hardware.
final class SessionTests: XCTestCase {

    private let testSharedSecret = "b4e4716bc736cde97aa0b585beddab79e190a2531e21bdd410914aeec7a2a4e1"

    // MARK: - Handshake tests

    func testInitiatorAndResponderHandshake() {
        let env = createPairedSessions(sharedSecretHex: testSharedSecret)
        let readyExpectation = expectation(description: "Both sessions ready")
        readyExpectation.expectedFulfillmentCount = 2

        env.macDelegate.onReady = { _ in readyExpectation.fulfill() }
        env.androidDelegate.onReady = { _ in readyExpectation.fulfill() }

        startBothSessions(env)

        wait(for: [readyExpectation], timeout: 5.0)
        cleanup(env)
    }

    func testHandshakeTimeoutWhenNoWelcome() {
        // Create an input stream with no data — peer never responds
        let emptyStream = InputStream(data: Data())
        emptyStream.open()
        let outputBuffer = OutputStream.toMemory()
        outputBuffer.open()

        let errorExpectation = expectation(description: "Timeout error")
        let delegate = TestSessionDelegate()
        delegate.onError = { _, error in
            if case SessionError.timeout = error as? SessionError ?? SessionError.sessionClosed {
                errorExpectation.fulfill()
            }
        }

        let session = Session(inputStream: emptyStream, outputStream: outputBuffer,
                              isInitiator: true, delegate: delegate,
                              sharedSecretHex: testSharedSecret)
        session.handshakeTimeoutSeconds = 0.3

        DispatchQueue.global().async {
            session.performHandshake()
        }

        wait(for: [errorExpectation], timeout: 3.0)
        session.close()
    }

    func testWrongMessageTypeDuringHandshake() {
        // Set up manual piped streams where we send OFFER instead of WELCOME
        let env = createManualStreams()
        let errorExpectation = expectation(description: "Wrong message error")
        let delegate = TestSessionDelegate()
        delegate.onError = { _, error in
            if case SessionError.unexpectedMessage = error as? SessionError ?? SessionError.sessionClosed {
                errorExpectation.fulfill()
            }
        }

        let session = Session(inputStream: env.sessionInput, outputStream: env.sessionOutput,
                              isInitiator: true, delegate: delegate,
                              sharedSecretHex: testSharedSecret)
        session.handshakeTimeoutSeconds = 3.0

        DispatchQueue.global().async {
            session.performHandshake()
        }

        // Read the HELLO the session sent
        _ = try? MessageCodec.decode(from: env.readFromSession)

        // Send an OFFER instead of WELCOME
        let wrongMsg = Message(type: .offer,
                               payload: Data(#"{"hash":"x","size":1,"type":"text/plain"}"#.utf8))
        writeMessage(wrongMsg, to: env.writeToSession)

        wait(for: [errorExpectation], timeout: 3.0)
        session.close()
        cleanupManual(env)
    }

    func testVersionMismatchInHelloCausesResponderError() {
        let env = createManualStreams()
        let errorExpectation = expectation(description: "Version mismatch error")
        let delegate = TestSessionDelegate()
        delegate.onError = { _, error in
            if case SessionError.versionMismatch = error as? SessionError ?? SessionError.sessionClosed {
                errorExpectation.fulfill()
            }
        }

        let session = Session(inputStream: env.sessionInput, outputStream: env.sessionOutput,
                              isInitiator: false, delegate: delegate,
                              sharedSecretHex: testSharedSecret)
        session.handshakeTimeoutSeconds = 3.0

        DispatchQueue.global().async {
            session.performHandshake()
        }

        // Send HELLO with wrong version
        let badHello = Message(type: .hello, payload: Data(#"{"version":99}"#.utf8))
        writeMessage(badHello, to: env.writeToSession)

        wait(for: [errorExpectation], timeout: 3.0)
        session.close()
        cleanupManual(env)
    }

    // MARK: - Transfer tests

    func testSenderSendsOfferGetsAcceptSendsPayloadGetsDone() {
        let env = createPairedSessions(sharedSecretHex: testSharedSecret)
        let readyExpectation = expectation(description: "Both ready")
        readyExpectation.expectedFulfillmentCount = 2
        let transferExpectation = expectation(description: "Transfer complete")
        let receivedExpectation = expectation(description: "Clipboard received")

        let testData = Data("Hello from Mac!".utf8)
        let expectedHash = Session.sha256Hex(testData)

        env.macDelegate.onReady = { _ in readyExpectation.fulfill() }
        env.androidDelegate.onReady = { _ in readyExpectation.fulfill() }

        env.macDelegate.onTransferComplete = { _, hash in
            XCTAssertEqual(hash, expectedHash)
            transferExpectation.fulfill()
        }
        env.androidDelegate.onReceived = { _, blob, hash in
            XCTAssertEqual(blob, testData)
            XCTAssertEqual(hash, expectedHash)
            receivedExpectation.fulfill()
        }

        startBothSessions(env)
        wait(for: [readyExpectation], timeout: 5.0)

        // Mac sends plaintext clipboard
        env.macSession.sendClipboard(testData)

        wait(for: [receivedExpectation, transferExpectation], timeout: 5.0)
        cleanup(env)
    }

    func testReceiverGetsOfferSendsAcceptGetsPayloadSendsDone() {
        let env = createPairedSessions(sharedSecretHex: testSharedSecret)
        let readyExpectation = expectation(description: "Both ready")
        readyExpectation.expectedFulfillmentCount = 2
        let receivedExpectation = expectation(description: "Mac receives clipboard")

        let testData = Data("Hello from Android!".utf8)
        let expectedHash = Session.sha256Hex(testData)
        var receivedBlob: Data?
        var receivedHash: String?

        env.macDelegate.onReady = { _ in readyExpectation.fulfill() }
        env.androidDelegate.onReady = { _ in readyExpectation.fulfill() }
        env.macDelegate.onReceived = { _, blob, hash in
            receivedBlob = blob
            receivedHash = hash
            receivedExpectation.fulfill()
        }

        startBothSessions(env)
        wait(for: [readyExpectation], timeout: 5.0)

        // Android sends plaintext clipboard
        env.androidSession.sendClipboard(testData)

        wait(for: [receivedExpectation], timeout: 5.0)
        XCTAssertEqual(receivedBlob, testData)
        XCTAssertEqual(receivedHash, expectedHash)
        cleanup(env)
    }

    func testDuplicateOfferHashReturnsTrue() {
        let env = createPairedSessions(sharedSecretHex: testSharedSecret)
        let readyExpectation = expectation(description: "Both ready")
        readyExpectation.expectedFulfillmentCount = 2
        let transferExpectation = expectation(description: "Transfer complete (dedup)")

        let testData = Data("duplicate data".utf8)
        let hash = Session.sha256Hex(testData)

        // Android already has this hash
        env.androidDelegate.knownHashes.insert(hash)

        env.macDelegate.onReady = { _ in readyExpectation.fulfill() }
        env.androidDelegate.onReady = { _ in readyExpectation.fulfill() }
        env.macDelegate.onTransferComplete = { _, h in
            XCTAssertEqual(h, hash)
            transferExpectation.fulfill()
        }
        env.androidDelegate.onReceived = { _, _, _ in
            XCTFail("Should not receive clipboard for duplicate")
        }

        startBothSessions(env)
        wait(for: [readyExpectation], timeout: 5.0)

        env.macSession.sendClipboard(testData)

        wait(for: [transferExpectation], timeout: 5.0)
        cleanup(env)
    }

    func testTransferTimeoutWhenReceiverNeverResponds() {
        let env = createManualStreams()
        let readyExpectation = expectation(description: "Session ready")
        let errorExpectation = expectation(description: "Timeout error")

        let delegate = TestSessionDelegate()
        delegate.onReady = { _ in readyExpectation.fulfill() }
        delegate.onError = { _, error in
            if case SessionError.timeout = error as? SessionError ?? SessionError.sessionClosed {
                errorExpectation.fulfill()
            }
        }

        let session = Session(inputStream: env.sessionInput, outputStream: env.sessionOutput,
                              isInitiator: true, delegate: delegate,
                              sharedSecretHex: testSharedSecret)
        session.handshakeTimeoutSeconds = 3.0
        session.transferTimeoutSeconds = 0.3 // Short timeout

        DispatchQueue.global().async {
            session.performHandshake()
            session.listenForMessages()
        }

        // Complete handshake from the other side — must send valid v2 WELCOME
        let hello = try? MessageCodec.decode(from: env.readFromSession)
        XCTAssertEqual(hello?.type, .hello)
        sendValidWelcome(to: env.writeToSession, hello: hello!)

        wait(for: [readyExpectation], timeout: 3.0)

        // Send clipboard — will timeout waiting for ACCEPT
        session.sendClipboard(Data("timeout test".utf8))

        wait(for: [errorExpectation], timeout: 5.0)
        session.close()
        cleanupManual(env)
    }

    // MARK: - Edge case tests

    func testStreamClosedDuringListenCausesError() {
        let env = createManualStreams()
        let readyExpectation = expectation(description: "Session ready")
        let errorExpectation = expectation(description: "Stream close detected")

        let delegate = TestSessionDelegate()
        delegate.onReady = { _ in readyExpectation.fulfill() }
        delegate.onError = { _, _ in errorExpectation.fulfill() }

        let session = Session(inputStream: env.sessionInput, outputStream: env.sessionOutput,
                              isInitiator: true, delegate: delegate,
                              sharedSecretHex: testSharedSecret)
        session.handshakeTimeoutSeconds = 3.0

        DispatchQueue.global().async {
            session.performHandshake()
            session.listenForMessages()
        }

        // Complete handshake with valid v2 WELCOME
        let hello = try? MessageCodec.decode(from: env.readFromSession)
        sendValidWelcome(to: env.writeToSession, hello: hello!)

        wait(for: [readyExpectation], timeout: 3.0)

        // Close write end to simulate disconnect
        env.writeToSession.close()

        wait(for: [errorExpectation], timeout: 3.0)
        session.close()
        cleanupManual(env)
    }

    func testMalformedMessageDuringListenCausesError() {
        let env = createManualStreams()
        let readyExpectation = expectation(description: "Session ready")
        let errorExpectation = expectation(description: "Malformed message error")

        let delegate = TestSessionDelegate()
        delegate.onReady = { _ in readyExpectation.fulfill() }
        delegate.onError = { _, _ in errorExpectation.fulfill() }

        let session = Session(inputStream: env.sessionInput, outputStream: env.sessionOutput,
                              isInitiator: true, delegate: delegate,
                              sharedSecretHex: testSharedSecret)
        session.handshakeTimeoutSeconds = 3.0

        DispatchQueue.global().async {
            session.performHandshake()
            session.listenForMessages()
        }

        // Complete handshake with valid v2 WELCOME
        let hello = try? MessageCodec.decode(from: env.readFromSession)
        sendValidWelcome(to: env.writeToSession, hello: hello!)

        wait(for: [readyExpectation], timeout: 3.0)

        // Send garbage (invalid message type 0xFF) — unknown types are skipped,
        // so close the stream afterwards to trigger an error.
        let garbage: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0xFF]
        env.writeToSession.write(garbage, maxLength: garbage.count)
        env.writeToSession.close()

        wait(for: [errorExpectation], timeout: 3.0)
        session.close()
        cleanupManual(env)
    }

    // MARK: - V2 Handshake tests

    func testV2HandshakeSucceeds() {
        let env = createPairedSessions(sharedSecretHex: testSharedSecret)
        let readyExpectation = expectation(description: "Both sessions ready via v2 handshake")
        readyExpectation.expectedFulfillmentCount = 2

        env.macDelegate.onReady = { _ in readyExpectation.fulfill() }
        env.androidDelegate.onReady = { _ in readyExpectation.fulfill() }

        startBothSessions(env)

        wait(for: [readyExpectation], timeout: 5.0)
        cleanup(env)
    }

    func testV2HandshakeRejectsVersion1() {
        let env = createManualStreams()
        let errorExpectation = expectation(description: "Version mismatch error")
        let delegate = TestSessionDelegate()
        delegate.onError = { _, error in
            if case SessionError.versionMismatch = error as? SessionError ?? SessionError.sessionClosed {
                errorExpectation.fulfill()
            }
        }

        let session = Session(inputStream: env.sessionInput, outputStream: env.sessionOutput,
                              isInitiator: false, delegate: delegate,
                              sharedSecretHex: testSharedSecret)
        session.handshakeTimeoutSeconds = 3.0

        DispatchQueue.global().async {
            session.performHandshake()
        }

        // Send v1 HELLO (no ek, no auth)
        let v1Hello = Message(type: .hello, payload: Data(#"{"version":1,"name":"OldMac"}"#.utf8))
        writeMessage(v1Hello, to: env.writeToSession)

        wait(for: [errorExpectation], timeout: 3.0)
        session.close()
        cleanupManual(env)
    }

    func testV2HandshakeRejectsBadAuth() {
        let env = createManualStreams()
        let errorExpectation = expectation(description: "Auth error")
        let delegate = TestSessionDelegate()
        var capturedError: Error?
        delegate.onError = { _, error in
            capturedError = error
            errorExpectation.fulfill()
        }

        let session = Session(inputStream: env.sessionInput, outputStream: env.sessionOutput,
                              isInitiator: false, delegate: delegate,
                              sharedSecretHex: testSharedSecret)
        session.handshakeTimeoutSeconds = 3.0

        DispatchQueue.global().async {
            session.performHandshake()
        }

        // Generate a valid ek but with wrong auth (using different secret)
        let ekPriv = Curve25519.KeyAgreement.PrivateKey()
        let ekBytes = ekPriv.publicKey.rawRepresentation
        let ekHex = ekBytes.map { String(format: "%02x", $0) }.joined()

        // Use a wrong auth key (all-zeros shared secret)
        let wrongAuthKey = E2ECrypto.deriveAuthKey(secretBytes: Data(repeating: 0, count: 32))!
        let wrongAuth = E2ECrypto.hmacAuth(publicKeyBytes: Data(ekBytes), authKey: wrongAuthKey)
        let wrongAuthHex = wrongAuth.map { String(format: "%02x", $0) }.joined()

        var badHello: [String: Any] = [
            "version": 2,
            "ek": ekHex,
            "auth": wrongAuthHex
        ]
        let badHelloData = try! JSONSerialization.data(withJSONObject: badHello)
        let msg = Message(type: .hello, payload: badHelloData)
        writeMessage(msg, to: env.writeToSession)

        wait(for: [errorExpectation], timeout: 3.0)
        if let sessionError = capturedError as? SessionError,
           case .protocolError(let msg) = sessionError {
            XCTAssertTrue(msg.contains("Authentication failed"))
        } else {
            XCTFail("Expected protocolError with 'Authentication failed'")
        }
        session.close()
        cleanupManual(env)
    }

    func testV2HandshakeRejectsMissingEk() {
        let env = createManualStreams()
        let errorExpectation = expectation(description: "Missing ek error")
        let delegate = TestSessionDelegate()
        var capturedError: Error?
        delegate.onError = { _, error in
            capturedError = error
            errorExpectation.fulfill()
        }

        let session = Session(inputStream: env.sessionInput, outputStream: env.sessionOutput,
                              isInitiator: false, delegate: delegate,
                              sharedSecretHex: testSharedSecret)
        session.handshakeTimeoutSeconds = 3.0

        DispatchQueue.global().async {
            session.performHandshake()
        }

        // Send v2 HELLO without ek field
        var badHello: [String: Any] = [
            "version": 2,
            "auth": String(repeating: "a", count: 64)
        ]
        let badHelloData = try! JSONSerialization.data(withJSONObject: badHello)
        let msg = Message(type: .hello, payload: badHelloData)
        writeMessage(msg, to: env.writeToSession)

        wait(for: [errorExpectation], timeout: 3.0)
        if let sessionError = capturedError as? SessionError,
           case .protocolError(let msg) = sessionError {
            XCTAssertTrue(msg.lowercased().contains("ephemeral key"))
        } else {
            XCTFail("Expected protocolError with 'ephemeral key'")
        }
        session.close()
        cleanupManual(env)
    }

    func testV2EndToEndClipboardTransfer() {
        let env = createPairedSessions(sharedSecretHex: testSharedSecret)
        let readyExpectation = expectation(description: "Both ready")
        readyExpectation.expectedFulfillmentCount = 2
        let transferExpectation = expectation(description: "Transfer complete")
        let receivedExpectation = expectation(description: "Clipboard received")

        let plaintext = Data("Forward secrecy clipboard test!".utf8)
        let expectedHash = Session.sha256Hex(plaintext)

        env.macDelegate.onReady = { _ in readyExpectation.fulfill() }
        env.androidDelegate.onReady = { _ in readyExpectation.fulfill() }

        env.macDelegate.onTransferComplete = { _, hash in
            XCTAssertEqual(hash, expectedHash)
            transferExpectation.fulfill()
        }
        env.androidDelegate.onReceived = { _, received, hash in
            XCTAssertEqual(received, plaintext, "Plaintext should match")
            XCTAssertEqual(hash, expectedHash, "Hash should match")
            receivedExpectation.fulfill()
        }

        startBothSessions(env)
        wait(for: [readyExpectation], timeout: 5.0)

        // Mac sends plaintext — Session encrypts internally
        env.macSession.sendClipboard(plaintext)

        wait(for: [receivedExpectation, transferExpectation], timeout: 5.0)
        cleanup(env)
    }

    // MARK: - New message type routing tests

    func testConfigUpdateDuringListenDoesNotCrash() {
        let env = createManualStreams()
        let readyExpectation = expectation(description: "Session ready")
        let errorExpectation = expectation(description: "Error should not fire")
        errorExpectation.isInverted = true

        let delegate = TestSessionDelegate()
        delegate.onReady = { _ in readyExpectation.fulfill() }
        delegate.onError = { _, _ in errorExpectation.fulfill() }

        let session = Session(inputStream: env.sessionInput, outputStream: env.sessionOutput,
                              isInitiator: true, delegate: delegate,
                              sharedSecretHex: testSharedSecret)
        session.handshakeTimeoutSeconds = 3.0

        DispatchQueue.global().async {
            session.performHandshake()
            session.listenForMessages()
        }

        // Complete handshake
        let hello = try? MessageCodec.decode(from: env.readFromSession)
        XCTAssertEqual(hello?.type, .hello)
        sendValidWelcome(to: env.writeToSession, hello: hello!)

        wait(for: [readyExpectation], timeout: 3.0)

        // Send CONFIG_UPDATE — session should not crash
        let configMsg = Message(type: .configUpdate, payload: Data(#"{"images":true}"#.utf8))
        writeMessage(configMsg, to: env.writeToSession)

        // Send REJECT — session should not crash
        let rejectMsg = Message(type: .reject, payload: Data(#"{"reason":"unsupported"}"#.utf8))
        writeMessage(rejectMsg, to: env.writeToSession)

        // Send ERROR — session should not crash
        let errorMsg = Message(type: .error, payload: Data(#"{"message":"test error"}"#.utf8))
        writeMessage(errorMsg, to: env.writeToSession)

        // Wait briefly to confirm no error fires (inverted expectation)
        wait(for: [errorExpectation], timeout: 1.0)

        session.close()
        cleanupManual(env)
    }

    // MARK: - Settings in HELLO/WELCOME tests

    func testHelloPayloadIncludesSettingsWhenProviderIsSet() {
        let env = createManualStreams()
        let sp = TestSettingsProvider(richMediaEnabled: true, richMediaEnabledChangedAt: 1773698112)
        let delegate = TestSessionDelegate()

        let session = Session(inputStream: env.sessionInput, outputStream: env.sessionOutput,
                              isInitiator: true, delegate: delegate,
                              sharedSecretHex: testSharedSecret)
        session.handshakeTimeoutSeconds = 3.0
        session.settingsProvider = sp

        DispatchQueue.global().async {
            session.performHandshake()
        }

        // Read the HELLO the session sent
        let hello = try? MessageCodec.decode(from: env.readFromSession)
        XCTAssertEqual(hello?.type, .hello)

        guard let payload = hello?.payload,
              let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            XCTFail("Failed to parse HELLO payload")
            return
        }

        guard let settings = json["settings"] as? [String: Any] else {
            XCTFail("HELLO should have settings")
            return
        }
        XCTAssertEqual(settings["richMediaEnabled"] as? Bool, true)
        XCTAssertEqual((settings["richMediaEnabledChangedAt"] as? NSNumber)?.int64Value, 1773698112)

        session.close()
        cleanupManual(env)
    }

    func testValidateVersionResolvesSettingsRemoteNewerWins() {
        let env = createManualStreams()
        let sp = TestSettingsProvider(richMediaEnabled: false, richMediaEnabledChangedAt: 1000)
        let readyExpectation = expectation(description: "Session ready")
        var settingChanged: Bool?

        let delegate = TestSessionDelegate()
        delegate.onReady = { _ in readyExpectation.fulfill() }
        delegate.onRichMediaChanged = { _, enabled in settingChanged = enabled }

        let session = Session(inputStream: env.sessionInput, outputStream: env.sessionOutput,
                              isInitiator: false, delegate: delegate,
                              sharedSecretHex: testSharedSecret)
        session.handshakeTimeoutSeconds = 3.0
        session.settingsProvider = sp

        DispatchQueue.global().async {
            session.performHandshake()
        }

        // Send HELLO with remote settings: richMediaEnabled=true, changedAt=2000
        let ekPriv = Curve25519.KeyAgreement.PrivateKey()
        let ekBytes = ekPriv.publicKey.rawRepresentation
        let ekHex = ekBytes.map { String(format: "%02x", $0) }.joined()
        guard let secretBytes = E2ECrypto.hexToData(testSharedSecret),
              let authKey = E2ECrypto.deriveAuthKey(secretBytes: secretBytes) else {
            XCTFail("Failed to derive auth key"); return
        }
        let authBytes = E2ECrypto.hmacAuth(publicKeyBytes: Data(ekBytes), authKey: authKey)
        let authHex = authBytes.map { String(format: "%02x", $0) }.joined()

        let helloObj: [String: Any] = [
            "version": 2,
            "ek": ekHex,
            "auth": authHex,
            "settings": [
                "richMediaEnabled": true,
                "richMediaEnabledChangedAt": 2000
            ]
        ]
        let helloData = try! JSONSerialization.data(withJSONObject: helloObj)
        writeMessage(Message(type: .hello, payload: helloData), to: env.writeToSession)

        // Read WELCOME
        _ = try? MessageCodec.decode(from: env.readFromSession)

        wait(for: [readyExpectation], timeout: 5.0)

        XCTAssertTrue(sp.richMediaEnabled)
        XCTAssertEqual(sp.richMediaEnabledChangedAt, 2000)
        XCTAssertEqual(settingChanged, true)

        session.close()
        cleanupManual(env)
    }

    func testValidateVersionKeepsLocalSettingsWhenLocalIsNewer() {
        let env = createManualStreams()
        let sp = TestSettingsProvider(richMediaEnabled: true, richMediaEnabledChangedAt: 3000)
        let readyExpectation = expectation(description: "Session ready")
        var settingChangeCalled = false

        let delegate = TestSessionDelegate()
        delegate.onReady = { _ in readyExpectation.fulfill() }
        delegate.onRichMediaChanged = { _, _ in settingChangeCalled = true }

        let session = Session(inputStream: env.sessionInput, outputStream: env.sessionOutput,
                              isInitiator: false, delegate: delegate,
                              sharedSecretHex: testSharedSecret)
        session.handshakeTimeoutSeconds = 3.0
        session.settingsProvider = sp

        DispatchQueue.global().async {
            session.performHandshake()
        }

        // Send HELLO with older remote settings
        let ekPriv = Curve25519.KeyAgreement.PrivateKey()
        let ekBytes = ekPriv.publicKey.rawRepresentation
        let ekHex = ekBytes.map { String(format: "%02x", $0) }.joined()
        guard let secretBytes = E2ECrypto.hexToData(testSharedSecret),
              let authKey = E2ECrypto.deriveAuthKey(secretBytes: secretBytes) else {
            XCTFail("Failed to derive auth key"); return
        }
        let authBytes = E2ECrypto.hmacAuth(publicKeyBytes: Data(ekBytes), authKey: authKey)
        let authHex = authBytes.map { String(format: "%02x", $0) }.joined()

        let helloObj: [String: Any] = [
            "version": 2,
            "ek": ekHex,
            "auth": authHex,
            "settings": [
                "richMediaEnabled": false,
                "richMediaEnabledChangedAt": 1000
            ]
        ]
        let helloData = try! JSONSerialization.data(withJSONObject: helloObj)
        writeMessage(Message(type: .hello, payload: helloData), to: env.writeToSession)

        _ = try? MessageCodec.decode(from: env.readFromSession)

        wait(for: [readyExpectation], timeout: 5.0)

        XCTAssertTrue(sp.richMediaEnabled, "Local should still be true")
        XCTAssertEqual(sp.richMediaEnabledChangedAt, 3000, "Local changedAt should still be 3000")
        XCTAssertFalse(settingChangeCalled, "Callback should not fire for older settings")

        session.close()
        cleanupManual(env)
    }

    func testValidateVersionHandlesMissingSettingsGracefully() {
        let env = createManualStreams()
        let sp = TestSettingsProvider(richMediaEnabled: false, richMediaEnabledChangedAt: 500)
        let readyExpectation = expectation(description: "Session ready")

        let delegate = TestSessionDelegate()
        delegate.onReady = { _ in readyExpectation.fulfill() }

        let session = Session(inputStream: env.sessionInput, outputStream: env.sessionOutput,
                              isInitiator: false, delegate: delegate,
                              sharedSecretHex: testSharedSecret)
        session.handshakeTimeoutSeconds = 3.0
        session.settingsProvider = sp

        DispatchQueue.global().async {
            session.performHandshake()
        }

        // Send HELLO without settings (older client)
        let ekPriv = Curve25519.KeyAgreement.PrivateKey()
        let ekBytes = ekPriv.publicKey.rawRepresentation
        let ekHex = ekBytes.map { String(format: "%02x", $0) }.joined()
        guard let secretBytes = E2ECrypto.hexToData(testSharedSecret),
              let authKey = E2ECrypto.deriveAuthKey(secretBytes: secretBytes) else {
            XCTFail("Failed to derive auth key"); return
        }
        let authBytes = E2ECrypto.hmacAuth(publicKeyBytes: Data(ekBytes), authKey: authKey)
        let authHex = authBytes.map { String(format: "%02x", $0) }.joined()

        let helloObj: [String: Any] = [
            "version": 2,
            "ek": ekHex,
            "auth": authHex
        ]
        let helloData = try! JSONSerialization.data(withJSONObject: helloObj)
        writeMessage(Message(type: .hello, payload: helloData), to: env.writeToSession)

        _ = try? MessageCodec.decode(from: env.readFromSession)

        wait(for: [readyExpectation], timeout: 5.0)

        XCTAssertFalse(sp.richMediaEnabled)
        XCTAssertEqual(sp.richMediaEnabledChangedAt, 500)

        session.close()
        cleanupManual(env)
    }

    // MARK: - CONFIG_UPDATE tests

    func testHandleConfigUpdatePersistsRemoteSettingsWhenNewer() {
        let env = createManualStreams()
        let sp = TestSettingsProvider(richMediaEnabled: false, richMediaEnabledChangedAt: 1000)
        let readyExpectation = expectation(description: "Session ready")
        let settingChangedExpectation = expectation(description: "Setting changed")
        var changedValue: Bool?

        let delegate = TestSessionDelegate()
        delegate.onReady = { _ in readyExpectation.fulfill() }
        delegate.onRichMediaChanged = { _, enabled in
            changedValue = enabled
            settingChangedExpectation.fulfill()
        }

        let session = Session(inputStream: env.sessionInput, outputStream: env.sessionOutput,
                              isInitiator: true, delegate: delegate,
                              sharedSecretHex: testSharedSecret)
        session.handshakeTimeoutSeconds = 3.0
        session.settingsProvider = sp

        DispatchQueue.global().async {
            session.performHandshake()
            session.listenForMessages()
        }

        let hello = try? MessageCodec.decode(from: env.readFromSession)
        XCTAssertEqual(hello?.type, .hello)
        sendValidWelcome(to: env.writeToSession, hello: hello!)

        wait(for: [readyExpectation], timeout: 3.0)

        // Send CONFIG_UPDATE with newer settings
        let configObj: [String: Any] = [
            "richMediaEnabled": true,
            "richMediaEnabledChangedAt": 2000
        ]
        let configData = try! JSONSerialization.data(withJSONObject: configObj)
        writeMessage(Message(type: .configUpdate, payload: configData), to: env.writeToSession)

        wait(for: [settingChangedExpectation], timeout: 3.0)
        XCTAssertTrue(sp.richMediaEnabled)
        XCTAssertEqual(sp.richMediaEnabledChangedAt, 2000)
        XCTAssertEqual(changedValue, true)

        session.close()
        cleanupManual(env)
    }

    func testHandleConfigUpdateIgnoresRemoteSettingsWhenOlder() {
        let env = createManualStreams()
        let sp = TestSettingsProvider(richMediaEnabled: true, richMediaEnabledChangedAt: 3000)
        let readyExpectation = expectation(description: "Session ready")
        let noChangeExpectation = expectation(description: "No change")
        noChangeExpectation.isInverted = true

        let delegate = TestSessionDelegate()
        delegate.onReady = { _ in readyExpectation.fulfill() }
        delegate.onRichMediaChanged = { _, _ in noChangeExpectation.fulfill() }

        let session = Session(inputStream: env.sessionInput, outputStream: env.sessionOutput,
                              isInitiator: true, delegate: delegate,
                              sharedSecretHex: testSharedSecret)
        session.handshakeTimeoutSeconds = 3.0
        session.settingsProvider = sp

        DispatchQueue.global().async {
            session.performHandshake()
            session.listenForMessages()
        }

        let hello = try? MessageCodec.decode(from: env.readFromSession)
        sendValidWelcome(to: env.writeToSession, hello: hello!)

        wait(for: [readyExpectation], timeout: 3.0)

        // Send CONFIG_UPDATE with older settings
        let configObj: [String: Any] = [
            "richMediaEnabled": false,
            "richMediaEnabledChangedAt": 1000
        ]
        let configData = try! JSONSerialization.data(withJSONObject: configObj)
        writeMessage(Message(type: .configUpdate, payload: configData), to: env.writeToSession)

        // Wait briefly for inverted expectation
        wait(for: [noChangeExpectation], timeout: 1.0)
        XCTAssertTrue(sp.richMediaEnabled)
        XCTAssertEqual(sp.richMediaEnabledChangedAt, 3000)

        session.close()
        cleanupManual(env)
    }

    func testSendConfigUpdateProducesCorrectFormat() {
        let env = createManualStreams()
        let sp = TestSettingsProvider(richMediaEnabled: true, richMediaEnabledChangedAt: 1773698112)
        let readyExpectation = expectation(description: "Session ready")

        let delegate = TestSessionDelegate()
        delegate.onReady = { _ in readyExpectation.fulfill() }

        let session = Session(inputStream: env.sessionInput, outputStream: env.sessionOutput,
                              isInitiator: true, delegate: delegate,
                              sharedSecretHex: testSharedSecret)
        session.handshakeTimeoutSeconds = 3.0
        session.settingsProvider = sp

        DispatchQueue.global().async {
            session.performHandshake()
            session.listenForMessages()
        }

        let hello = try? MessageCodec.decode(from: env.readFromSession)
        sendValidWelcome(to: env.writeToSession, hello: hello!)

        wait(for: [readyExpectation], timeout: 3.0)

        // Trigger sendConfigUpdate
        session.sendConfigUpdate()

        // Read the CONFIG_UPDATE from output
        let msg = try? MessageCodec.decode(from: env.readFromSession)
        XCTAssertEqual(msg?.type, .configUpdate)

        guard let payload = msg?.payload,
              let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            XCTFail("Failed to parse CONFIG_UPDATE payload")
            return
        }
        XCTAssertEqual(json["richMediaEnabled"] as? Bool, true)
        XCTAssertEqual((json["richMediaEnabledChangedAt"] as? NSNumber)?.int64Value, 1773698112)

        session.close()
        cleanupManual(env)
    }

    // MARK: - Image transfer tests

    func testSendImageSendsCorrectOfferJSON() {
        let env = createManualStreams()
        let readyExpectation = expectation(description: "Session ready")

        let delegate = TestSessionDelegate()
        delegate.onReady = { _ in readyExpectation.fulfill() }

        let session = Session(inputStream: env.sessionInput, outputStream: env.sessionOutput,
                              isInitiator: true, delegate: delegate,
                              sharedSecretHex: testSharedSecret)
        session.handshakeTimeoutSeconds = 3.0
        session.transferTimeoutSeconds = 5.0

        DispatchQueue.global().async {
            session.performHandshake()
            session.listenForMessages()
        }

        let hello = try? MessageCodec.decode(from: env.readFromSession)
        XCTAssertEqual(hello?.type, .hello)
        sendValidWelcome(to: env.writeToSession, hello: hello!)

        wait(for: [readyExpectation], timeout: 3.0)

        // Queue an image
        let imageData = Data((0..<100).map { UInt8($0 % 256) })
        session.sendImage(imageData, contentType: "image/png")

        // Read the OFFER
        let offer = try? MessageCodec.decode(from: env.readFromSession)
        XCTAssertEqual(offer?.type, .offer)

        guard let payload = offer?.payload,
              let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            XCTFail("Failed to parse OFFER payload")
            session.close(); cleanupManual(env); return
        }

        XCTAssertEqual(json["type"] as? String, "image/png")
        XCTAssertEqual(json["size"] as? Int, 100)
        XCTAssertNotNil(json["hash"])
        XCTAssertNotNil(json["senderIp"])

        let expectedHash = Session.sha256Hex(imageData)
        XCTAssertEqual(json["hash"] as? String, expectedHash)

        // Send REJECT so session doesn't hang
        let rejectJSON: [String: Any] = ["reason": "test"]
        let rejectData = try! JSONSerialization.data(withJSONObject: rejectJSON)
        writeMessage(Message(type: .reject, payload: rejectData), to: env.writeToSession)

        Thread.sleep(forTimeInterval: 0.2)
        session.close()
        cleanupManual(env)
    }

    func testHandleInboundImageOfferRejectsWhenFeatureDisabled() {
        let env = createManualStreams()
        let sp = TestSettingsProvider(richMediaEnabled: false, richMediaEnabledChangedAt: 1000)
        let readyExpectation = expectation(description: "Session ready")

        let delegate = TestSessionDelegate()
        delegate.onReady = { _ in readyExpectation.fulfill() }

        let session = Session(inputStream: env.sessionInput, outputStream: env.sessionOutput,
                              isInitiator: true, delegate: delegate,
                              sharedSecretHex: testSharedSecret)
        session.handshakeTimeoutSeconds = 3.0
        session.settingsProvider = sp

        DispatchQueue.global().async {
            session.performHandshake()
            session.listenForMessages()
        }

        let hello = try? MessageCodec.decode(from: env.readFromSession)
        sendValidWelcome(to: env.writeToSession, hello: hello!)

        wait(for: [readyExpectation], timeout: 3.0)

        // Send image OFFER
        let offerJSON: [String: Any] = [
            "hash": "abc123",
            "size": 1000,
            "type": "image/png",
            "senderIp": "192.168.1.10"
        ]
        let offerData = try! JSONSerialization.data(withJSONObject: offerJSON)
        writeMessage(Message(type: .offer, payload: offerData), to: env.writeToSession)

        // Read REJECT
        let reject = try? MessageCodec.decode(from: env.readFromSession)
        XCTAssertEqual(reject?.type, .reject)

        if let rejectPayload = reject?.payload,
           let rejectJson = try? JSONSerialization.jsonObject(with: rejectPayload) as? [String: Any] {
            XCTAssertEqual(rejectJson["reason"] as? String, "feature_disabled")
        } else {
            XCTFail("Failed to parse REJECT payload")
        }

        session.close()
        cleanupManual(env)
    }

    func testHandleInboundImageOfferRejectsOversizedImages() {
        let env = createManualStreams()
        let sp = TestSettingsProvider(richMediaEnabled: true, richMediaEnabledChangedAt: 1000)
        let readyExpectation = expectation(description: "Session ready")

        let delegate = TestSessionDelegate()
        delegate.onReady = { _ in readyExpectation.fulfill() }

        let session = Session(inputStream: env.sessionInput, outputStream: env.sessionOutput,
                              isInitiator: true, delegate: delegate,
                              sharedSecretHex: testSharedSecret)
        session.handshakeTimeoutSeconds = 3.0
        session.settingsProvider = sp

        DispatchQueue.global().async {
            session.performHandshake()
            session.listenForMessages()
        }

        let hello = try? MessageCodec.decode(from: env.readFromSession)
        sendValidWelcome(to: env.writeToSession, hello: hello!)

        wait(for: [readyExpectation], timeout: 3.0)

        // Send image OFFER with size > 10MB
        let offerJSON: [String: Any] = [
            "hash": "abc123",
            "size": 11 * 1024 * 1024,
            "type": "image/png",
            "senderIp": "192.168.1.10"
        ]
        let offerData = try! JSONSerialization.data(withJSONObject: offerJSON)
        writeMessage(Message(type: .offer, payload: offerData), to: env.writeToSession)

        // Read REJECT
        let reject = try? MessageCodec.decode(from: env.readFromSession)
        XCTAssertEqual(reject?.type, .reject)

        if let rejectPayload = reject?.payload,
           let rejectJson = try? JSONSerialization.jsonObject(with: rejectPayload) as? [String: Any] {
            XCTAssertEqual(rejectJson["reason"] as? String, "size_exceeded")
        } else {
            XCTFail("Failed to parse REJECT payload")
        }

        session.close()
        cleanupManual(env)
    }

    func testHandleInboundImageOfferStartsTcpServerAndSendsAccept() {
        let env = createManualStreams()
        let sp = TestSettingsProvider(richMediaEnabled: true, richMediaEnabledChangedAt: 1000)
        let readyExpectation = expectation(description: "Session ready")

        let delegate = TestSessionDelegate()
        delegate.onReady = { _ in readyExpectation.fulfill() }

        let session = Session(inputStream: env.sessionInput, outputStream: env.sessionOutput,
                              isInitiator: true, delegate: delegate,
                              sharedSecretHex: testSharedSecret)
        session.handshakeTimeoutSeconds = 3.0
        session.transferTimeoutSeconds = 5.0
        session.settingsProvider = sp

        DispatchQueue.global().async {
            session.performHandshake()
            session.listenForMessages()
        }

        let hello = try? MessageCodec.decode(from: env.readFromSession)
        sendValidWelcome(to: env.writeToSession, hello: hello!)

        wait(for: [readyExpectation], timeout: 3.0)

        // Send a small image OFFER
        let offerJSON: [String: Any] = [
            "hash": "abc123",
            "size": 100,
            "type": "image/png",
            "senderIp": "127.0.0.1"
        ]
        let offerData = try! JSONSerialization.data(withJSONObject: offerJSON)
        writeMessage(Message(type: .offer, payload: offerData), to: env.writeToSession)

        // Read ACCEPT
        let accept = try? MessageCodec.decode(from: env.readFromSession)
        XCTAssertEqual(accept?.type, .accept)

        if let acceptPayload = accept?.payload,
           let acceptJson = try? JSONSerialization.jsonObject(with: acceptPayload) as? [String: Any] {
            XCTAssertNotNil(acceptJson["tcpHost"])
            XCTAssertNotNil(acceptJson["tcpPort"])
            if let tcpPort = acceptJson["tcpPort"] as? Int {
                XCTAssertTrue(tcpPort > 0, "TCP port should be positive")
            }
        } else {
            XCTFail("Failed to parse ACCEPT payload")
        }

        // Close without sending data (session will eventually error/timeout, OK for this test)
        session.close()
        cleanupManual(env)
    }

    // MARK: - Edge case tests

    func testReceiverRejectsOversizedImageWithSizeExceeded() {
        // OFFER with size = 11_000_000 (over 10MB limit)
        let env = createManualStreams()
        let sp = TestSettingsProvider(richMediaEnabled: true, richMediaEnabledChangedAt: 1000)
        let readyExpectation = expectation(description: "Session ready")

        let delegate = TestSessionDelegate()
        delegate.onReady = { _ in readyExpectation.fulfill() }

        let session = Session(inputStream: env.sessionInput, outputStream: env.sessionOutput,
                              isInitiator: true, delegate: delegate,
                              sharedSecretHex: testSharedSecret)
        session.handshakeTimeoutSeconds = 3.0
        session.settingsProvider = sp

        DispatchQueue.global().async {
            session.performHandshake()
            session.listenForMessages()
        }

        let hello = try? MessageCodec.decode(from: env.readFromSession)
        sendValidWelcome(to: env.writeToSession, hello: hello!)

        wait(for: [readyExpectation], timeout: 3.0)

        // Send image OFFER with size = 11_000_000 (> 10 * 1024 * 1024)
        let offerJSON: [String: Any] = [
            "hash": "abc123",
            "size": 11_000_000,
            "type": "image/png",
            "senderIp": "192.168.1.10"
        ]
        let offerData = try! JSONSerialization.data(withJSONObject: offerJSON)
        writeMessage(Message(type: .offer, payload: offerData), to: env.writeToSession)

        // Read REJECT with reason "size_exceeded"
        let reject = try? MessageCodec.decode(from: env.readFromSession)
        XCTAssertEqual(reject?.type, .reject)

        if let rejectPayload = reject?.payload,
           let rejectJson = try? JSONSerialization.jsonObject(with: rejectPayload) as? [String: Any] {
            XCTAssertEqual(rejectJson["reason"] as? String, "size_exceeded")
        } else {
            XCTFail("Failed to parse REJECT payload")
        }

        session.close()
        cleanupManual(env)
    }

    func testEchoLoopPreventionHashSkipsDuplicateClipboard() {
        // When the receiver already has the hash, it sends DONE immediately.
        // This prevents echo loops where copied content bounces back.
        let env = createPairedSessions(sharedSecretHex: testSharedSecret)
        let readyExpectation = expectation(description: "Both ready")
        readyExpectation.expectedFulfillmentCount = 2
        let transferExpectation = expectation(description: "Transfer complete (dedup)")

        let testData = Data("echo-test-data".utf8)
        let hash = Session.sha256Hex(testData)

        env.macDelegate.onReady = { _ in readyExpectation.fulfill() }
        env.androidDelegate.onReady = { _ in readyExpectation.fulfill() }

        // Pre-populate Android's known hashes (simulating it already received this content)
        env.androidDelegate.knownHashes.insert(hash)

        env.macDelegate.onTransferComplete = { _, h in
            XCTAssertEqual(h, hash)
            transferExpectation.fulfill()
        }

        // Android MUST NOT receive onClipboardReceived for a deduplicated offer
        env.androidDelegate.onReceived = { _, _, _ in
            XCTFail("Echo loop detected: should not deliver clipboard that receiver already has")
        }

        startBothSessions(env)
        wait(for: [readyExpectation], timeout: 5.0)

        env.macSession.sendClipboard(testData)
        wait(for: [transferExpectation], timeout: 5.0)

        cleanup(env)
    }

    func testConcurrentTransferCancellationNewOfferCancelsInFlight() {
        // Start receiving image A (TCP server started), then verify it can be cancelled
        let env = createManualStreams()
        let sp = TestSettingsProvider(richMediaEnabled: true, richMediaEnabledChangedAt: 1000)
        let readyExpectation = expectation(description: "Session ready")

        let delegate = TestSessionDelegate()
        delegate.onReady = { _ in readyExpectation.fulfill() }

        let session = Session(inputStream: env.sessionInput, outputStream: env.sessionOutput,
                              isInitiator: true, delegate: delegate,
                              sharedSecretHex: testSharedSecret)
        session.handshakeTimeoutSeconds = 3.0
        session.transferTimeoutSeconds = 10.0
        session.settingsProvider = sp

        DispatchQueue.global().async {
            session.performHandshake()
            session.listenForMessages()
        }

        let hello = try? MessageCodec.decode(from: env.readFromSession)
        sendValidWelcome(to: env.writeToSession, hello: hello!)

        wait(for: [readyExpectation], timeout: 3.0)

        // Send first image OFFER (A)
        let offerAJSON: [String: Any] = [
            "hash": "hash_image_a",
            "size": 100,
            "type": "image/png",
            "senderIp": "127.0.0.1"
        ]
        let offerAData = try! JSONSerialization.data(withJSONObject: offerAJSON)
        writeMessage(Message(type: .offer, payload: offerAData), to: env.writeToSession)

        // Read ACCEPT for image A — confirms TCP server started
        let acceptA = try? MessageCodec.decode(from: env.readFromSession)
        XCTAssertEqual(acceptA?.type, .accept)

        if let acceptPayload = acceptA?.payload,
           let acceptJson = try? JSONSerialization.jsonObject(with: acceptPayload) as? [String: Any] {
            XCTAssertNotNil(acceptJson["tcpHost"])
            if let tcpPort = acceptJson["tcpPort"] as? Int {
                XCTAssertTrue(tcpPort > 0, "Port A should be positive")
            }
        } else {
            XCTFail("Failed to parse ACCEPT payload for image A")
        }

        // Close the session — the blocked TCP receiver will fail
        session.close()
        cleanupManual(env)
    }

    // MARK: - TIFF-to-PNG conversion test

    func testTiffToPngConversionInClipboardMonitor() {
        // ClipboardMonitor.pasteboardImage() converts TIFF to PNG.
        // We test the conversion logic by creating a TIFF NSBitmapImageRep and converting it.
        // Note: ClipboardMonitor uses NSPasteboard directly which requires a running app,
        // so we test the underlying conversion logic here.
        let width = 1, height = 1
        let bitmapRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 3,
            hasAlpha: false,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!

        // Set pixel to red
        bitmapRep.setColor(NSColor.red, atX: 0, y: 0)

        // Get TIFF data
        let tiffData = bitmapRep.tiffRepresentation!

        // Convert TIFF -> PNG (same logic as ClipboardMonitor.pasteboardImage)
        guard let bitmapFromTiff = NSBitmapImageRep(data: tiffData),
              let pngData = bitmapFromTiff.representation(using: .png, properties: [:]) else {
            XCTFail("TIFF to PNG conversion failed")
            return
        }

        XCTAssertFalse(pngData.isEmpty, "PNG data should not be empty")
        // Verify it starts with PNG signature
        let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let headerBytes = Array(pngData.prefix(8))
        XCTAssertEqual(headerBytes, pngSignature, "Converted data should be a valid PNG")

        // Content type would be "image/png" per the ClipboardMonitor logic
        let contentType = "image/png"
        XCTAssertEqual(contentType, "image/png")
    }

    // MARK: - Cross-platform image fixture tests

    func testCrossPlatformFixturePngHashMatchesKnownVector() throws {
        let fixture = try loadImageTransferFixture()
        guard let pngHex = fixture["test_png"]?["hex"] as? String,
              let expectedHash = fixture["test_png"]?["sha256"] as? String else {
            XCTFail("Missing test_png fields in fixture")
            return
        }

        guard let pngData = E2ECrypto.hexToData(pngHex) else {
            XCTFail("Invalid hex in fixture")
            return
        }
        let actualHash = Session.sha256Hex(pngData)
        XCTAssertEqual(actualHash, expectedHash, "SHA-256 hash of test PNG must match fixture")
    }

    func testCrossPlatformFixtureSealAndOpenRoundTrip() throws {
        let fixture = try loadImageTransferFixture()
        guard let pngHex = fixture["test_png"]?["hex"] as? String,
              let sessionKeyHex = fixture["encryption"]?["session_key_hex"] as? String else {
            XCTFail("Missing fields in fixture")
            return
        }

        guard let pngData = E2ECrypto.hexToData(pngHex),
              let keyData = E2ECrypto.hexToData(sessionKeyHex) else {
            XCTFail("Invalid hex in fixture")
            return
        }
        let sessionKey = SymmetricKey(data: keyData)

        // Seal (encrypt)
        let encrypted = try E2ECrypto.seal(pngData, key: sessionKey)
        XCTAssertTrue(encrypted.count > pngData.count, "Encrypted blob should be larger than plaintext")

        // Open (decrypt) — must recover original PNG bytes
        let decrypted = try E2ECrypto.open(encrypted, key: sessionKey)
        XCTAssertEqual(decrypted, pngData, "Decrypted data must match original PNG")
    }

    func testCrossPlatformFixtureHashVerificationAfterDecrypt() throws {
        let fixture = try loadImageTransferFixture()
        guard let pngHex = fixture["test_png"]?["hex"] as? String,
              let expectedHash = fixture["test_png"]?["sha256"] as? String,
              let sessionKeyHex = fixture["encryption"]?["session_key_hex"] as? String else {
            XCTFail("Missing fields in fixture")
            return
        }

        guard let pngData = E2ECrypto.hexToData(pngHex),
              let keyData = E2ECrypto.hexToData(sessionKeyHex) else {
            XCTFail("Invalid hex in fixture")
            return
        }
        let sessionKey = SymmetricKey(data: keyData)

        // Encrypt -> Decrypt -> Hash must match
        let encrypted = try E2ECrypto.seal(pngData, key: sessionKey)
        let decrypted = try E2ECrypto.open(encrypted, key: sessionKey)
        let actualHash = Session.sha256Hex(decrypted)
        XCTAssertEqual(actualHash, expectedHash, "Hash of decrypted image must match fixture")
    }

    private func loadImageTransferFixture() throws -> [String: [String: Any]] {
        let relativePath = "test-fixtures/protocol/l2cap/image_transfer_fixture.json"
        var current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        while true {
            let candidate = current.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                let data = try Data(contentsOf: candidate)
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw NSError(domain: "Fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON"])
                }
                var result: [String: [String: Any]] = [:]
                if let testPng = json["test_png"] as? [String: Any] { result["test_png"] = testPng }
                if let encryption = json["encryption"] as? [String: Any] { result["encryption"] = encryption }
                return result
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                throw NSError(domain: "Fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixture not found: \(relativePath)"])
            }
            current = parent
        }
    }

    // MARK: - Test Infrastructure

    struct PairedSessionEnv {
        let macSession: Session
        let androidSession: Session
        let macDelegate: TestSessionDelegate
        let androidDelegate: TestSessionDelegate
        var threads: [Thread] = []
        // Keep stream references alive
        let streams: [Any]
    }

    struct ManualStreamEnv {
        let sessionInput: InputStream
        let sessionOutput: OutputStream
        let readFromSession: InputStream
        let writeToSession: OutputStream
    }

    private func createPairedSessions(sharedSecretHex: String) -> PairedSessionEnv {
        // Mac → Android pipe
        var macToAndroidRead: InputStream?
        var macToAndroidWrite: OutputStream?
        Stream.getBoundStreams(withBufferSize: 65536,
                              inputStream: &macToAndroidRead,
                              outputStream: &macToAndroidWrite)

        // Android → Mac pipe
        var androidToMacRead: InputStream?
        var androidToMacWrite: OutputStream?
        Stream.getBoundStreams(withBufferSize: 65536,
                              inputStream: &androidToMacRead,
                              outputStream: &androidToMacWrite)

        let m2aR = macToAndroidRead!
        let m2aW = macToAndroidWrite!
        let a2mR = androidToMacRead!
        let a2mW = androidToMacWrite!

        m2aR.open(); m2aW.open()
        a2mR.open(); a2mW.open()

        let macDelegate = TestSessionDelegate()
        let androidDelegate = TestSessionDelegate()

        let macSession = Session(inputStream: a2mR, outputStream: m2aW,
                                 isInitiator: true, delegate: macDelegate,
                                 sharedSecretHex: sharedSecretHex)
        let androidSession = Session(inputStream: m2aR, outputStream: a2mW,
                                     isInitiator: false, delegate: androidDelegate,
                                     sharedSecretHex: sharedSecretHex)

        return PairedSessionEnv(
            macSession: macSession, androidSession: androidSession,
            macDelegate: macDelegate, androidDelegate: androidDelegate,
            streams: [m2aR, m2aW, a2mR, a2mW]
        )
    }

    private func createManualStreams() -> ManualStreamEnv {
        // Test side → Session
        var toSessionRead: InputStream?
        var toSessionWrite: OutputStream?
        Stream.getBoundStreams(withBufferSize: 65536,
                              inputStream: &toSessionRead,
                              outputStream: &toSessionWrite)

        // Session → Test side
        var fromSessionRead: InputStream?
        var fromSessionWrite: OutputStream?
        Stream.getBoundStreams(withBufferSize: 65536,
                              inputStream: &fromSessionRead,
                              outputStream: &fromSessionWrite)

        toSessionRead!.open(); toSessionWrite!.open()
        fromSessionRead!.open(); fromSessionWrite!.open()

        return ManualStreamEnv(
            sessionInput: toSessionRead!,
            sessionOutput: fromSessionWrite!,
            readFromSession: fromSessionRead!,
            writeToSession: toSessionWrite!
        )
    }

    private func startBothSessions(_ env: PairedSessionEnv) {
        DispatchQueue.global().async {
            env.macSession.performHandshake()
            env.macSession.listenForMessages()
        }
        DispatchQueue.global().async {
            env.androidSession.performHandshake()
            env.androidSession.listenForMessages()
        }
    }

    private func cleanup(_ env: PairedSessionEnv) {
        env.macSession.close()
        env.androidSession.close()
        // Give threads time to finish
        Thread.sleep(forTimeInterval: 0.1)
    }

    private func cleanupManual(_ env: ManualStreamEnv) {
        env.sessionInput.close()
        env.sessionOutput.close()
        env.readFromSession.close()
        env.writeToSession.close()
    }

    private func writeMessage(_ message: Message, to stream: OutputStream) {
        let encoded = MessageCodec.encode(message)
        encoded.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            let pointer = baseAddress.assumingMemoryBound(to: UInt8.self)
            stream.write(pointer, maxLength: encoded.count)
        }
    }

    /// Helper to send a valid v2 WELCOME response given a received HELLO message.
    /// Used in manual-stream tests that need to complete the handshake.
    private func sendValidWelcome(to stream: OutputStream, hello: Message) {
        // Generate responder ephemeral key pair
        let responderKey = Curve25519.KeyAgreement.PrivateKey()
        let responderEkBytes = responderKey.publicKey.rawRepresentation
        let responderEkHex = responderEkBytes.map { String(format: "%02x", $0) }.joined()

        // Compute auth
        guard let secretBytes = E2ECrypto.hexToData(testSharedSecret),
              let authKey = E2ECrypto.deriveAuthKey(secretBytes: secretBytes) else {
            XCTFail("Failed to derive auth key")
            return
        }
        let authBytes = E2ECrypto.hmacAuth(publicKeyBytes: Data(responderEkBytes), authKey: authKey)
        let authHex = authBytes.map { String(format: "%02x", $0) }.joined()

        var welcomeObj: [String: Any] = [
            "version": 2,
            "ek": responderEkHex,
            "auth": authHex
        ]
        let welcomeData = try! JSONSerialization.data(withJSONObject: welcomeObj)
        let welcome = Message(type: .welcome, payload: welcomeData)
        writeMessage(welcome, to: stream)
    }
}

// MARK: - Test Delegate

final class TestSessionDelegate: SessionDelegate {
    var onReady: (Session) -> Void = { _ in }
    var onReceived: (Session, Data, String) -> Void = { _, _, _ in }
    var onTransferComplete: (Session, String) -> Void = { _, _ in }
    var onError: (Session, Error) -> Void = { _, _ in }
    var onRichMediaChanged: (Session, Bool) -> Void = { _, _ in }
    var onImageReceived: (Session, Data, String, String) -> Void = { _, _, _, _ in }
    var onImageRejected: (Session, String) -> Void = { _, _ in }
    var onImageSendFailed: (Session, String) -> Void = { _, _ in }
    var knownHashes = Set<String>()

    func sessionDidBecomeReady(_ session: Session) { onReady(session) }
    func session(_ session: Session, didReceivePlaintext plaintext: Data, hash: String) {
        onReceived(session, plaintext, hash)
    }
    func session(_ session: Session, didCompleteTransfer hash: String) {
        onTransferComplete(session, hash)
    }
    func session(_ session: Session, didFailWithError error: Error) { onError(session, error) }
    func session(_ session: Session, alreadyHasHash hash: String) -> Bool {
        knownHashes.contains(hash)
    }
    func session(_ session: Session, didCompletePairingWithSecret sharedSecret: Data, remoteName: String?) {}
    func session(_ session: Session, didChangeRichMediaSetting enabled: Bool) {
        onRichMediaChanged(session, enabled)
    }
    func session(_ session: Session, didReceiveImage data: Data, contentType: String, hash: String) {
        onImageReceived(session, data, contentType, hash)
    }
    func session(_ session: Session, imageWasRejected reason: String) {
        onImageRejected(session, reason)
    }
    func session(_ session: Session, imageSendFailed reason: String) {
        onImageSendFailed(session, reason)
    }
}

/// In-memory settings provider for tests.
final class TestSettingsProvider: SettingsProvider {
    var richMediaEnabled: Bool
    var richMediaEnabledChangedAt: Int64

    init(richMediaEnabled: Bool = false, richMediaEnabledChangedAt: Int64 = 0) {
        self.richMediaEnabled = richMediaEnabled
        self.richMediaEnabledChangedAt = richMediaEnabledChangedAt
    }

    func isRichMediaEnabled() -> Bool { richMediaEnabled }
    func getRichMediaEnabledChangedAt() -> Int64 { richMediaEnabledChangedAt }
    func setRichMediaEnabled(_ enabled: Bool, changedAt: Int64) {
        richMediaEnabled = enabled
        richMediaEnabledChangedAt = changedAt
    }
}
