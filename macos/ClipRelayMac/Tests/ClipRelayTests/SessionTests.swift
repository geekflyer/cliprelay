import XCTest
@testable import ClipRelay

/// Tests for the Session protocol handler using piped in-memory streams.
///
/// Each test creates paired streams so two Session instances can communicate,
/// simulating a real L2CAP connection without any BLE hardware.
final class SessionTests: XCTestCase {

    // MARK: - Handshake tests

    func testInitiatorAndResponderHandshake() {
        let env = createPairedSessions()
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
                              isInitiator: true, delegate: delegate)
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
                              isInitiator: true, delegate: delegate)
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
                              isInitiator: false, delegate: delegate)
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
        let env = createPairedSessions()
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

        // Mac sends clipboard
        env.macSession.sendClipboard(testData)

        wait(for: [receivedExpectation, transferExpectation], timeout: 5.0)
        cleanup(env)
    }

    func testReceiverGetsOfferSendsAcceptGetsPayloadSendsDone() {
        let env = createPairedSessions()
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

        // Android sends clipboard
        env.androidSession.sendClipboard(testData)

        wait(for: [receivedExpectation], timeout: 5.0)
        XCTAssertEqual(receivedBlob, testData)
        XCTAssertEqual(receivedHash, expectedHash)
        cleanup(env)
    }

    func testDuplicateOfferHashReturnsTrue() {
        let env = createPairedSessions()
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
                              isInitiator: true, delegate: delegate)
        session.handshakeTimeoutSeconds = 3.0
        session.transferTimeoutSeconds = 0.3 // Short timeout

        DispatchQueue.global().async {
            session.performHandshake()
            session.listenForMessages()
        }

        // Complete handshake from the other side
        let hello = try? MessageCodec.decode(from: env.readFromSession)
        XCTAssertEqual(hello?.type, .hello)
        let welcome = Message(type: .welcome, payload: Data(#"{"version":1}"#.utf8))
        writeMessage(welcome, to: env.writeToSession)

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
                              isInitiator: true, delegate: delegate)
        session.handshakeTimeoutSeconds = 3.0

        DispatchQueue.global().async {
            session.performHandshake()
            session.listenForMessages()
        }

        // Complete handshake
        _ = try? MessageCodec.decode(from: env.readFromSession)
        writeMessage(Message(type: .welcome, payload: Data(#"{"version":1}"#.utf8)),
                     to: env.writeToSession)

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
                              isInitiator: true, delegate: delegate)
        session.handshakeTimeoutSeconds = 3.0

        DispatchQueue.global().async {
            session.performHandshake()
            session.listenForMessages()
        }

        // Complete handshake
        _ = try? MessageCodec.decode(from: env.readFromSession)
        writeMessage(Message(type: .welcome, payload: Data(#"{"version":1}"#.utf8)),
                     to: env.writeToSession)

        wait(for: [readyExpectation], timeout: 3.0)

        // Send garbage (invalid message type 0xFF)
        let garbage: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0xFF]
        env.writeToSession.write(garbage, maxLength: garbage.count)

        wait(for: [errorExpectation], timeout: 3.0)
        session.close()
        cleanupManual(env)
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

    private func createPairedSessions() -> PairedSessionEnv {
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
                                 isInitiator: true, delegate: macDelegate)
        let androidSession = Session(inputStream: m2aR, outputStream: a2mW,
                                     isInitiator: false, delegate: androidDelegate)

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
}

// MARK: - Test Delegate

final class TestSessionDelegate: SessionDelegate {
    var onReady: (Session) -> Void = { _ in }
    var onReceived: (Session, Data, String) -> Void = { _, _, _ in }
    var onTransferComplete: (Session, String) -> Void = { _, _ in }
    var onError: (Session, Error) -> Void = { _, _ in }
    var knownHashes = Set<String>()

    func sessionDidBecomeReady(_ session: Session) { onReady(session) }
    func session(_ session: Session, didReceiveClipboard encryptedBlob: Data, hash: String) {
        onReceived(session, encryptedBlob, hash)
    }
    func session(_ session: Session, didCompleteTransfer hash: String) {
        onTransferComplete(session, hash)
    }
    func session(_ session: Session, didFailWithError error: Error) { onError(session, error) }
    func session(_ session: Session, alreadyHasHash hash: String) -> Bool {
        knownHashes.contains(hash)
    }
    func session(_ session: Session, didCompletePairingWithSecret sharedSecret: Data, remoteName: String?) {}
}
