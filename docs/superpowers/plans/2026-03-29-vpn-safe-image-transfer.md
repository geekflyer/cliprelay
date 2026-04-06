# VPN-Safe TCP Image Transfer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make image transfer work when a VPN is active by binding TCP sockets to the LAN interface and replacing IP-based sender validation with a per-transfer nonce.

**Architecture:** Two changes: (1) bind outbound TCP sockets to the WiFi interface IP before `connect()` so the OS routes over LAN instead of VPN, (2) replace `allowedSenderIp` validation with a 16-byte random `tcpNonce` exchanged over encrypted BLE in the ACCEPT message and validated as a TCP preamble. Backward-compatible: old clients without `tcpNonce` fall back to IP validation.

**Tech Stack:** Swift (macOS), Kotlin (Android), BSD sockets, Java Socket API, BLE L2CAP signaling

**Spec:** `docs/superpowers/specs/2026-03-29-vpn-safe-image-transfer-design.md`

---

### Task 1: Add nonce support to macOS TcpImageReceiver

**Files:**
- Modify: `macos/ClipRelayMac/Sources/TCP/TcpImageReceiver.swift`
- Test: `macos/ClipRelayMac/Tests/ClipRelayTests/TcpImageReceiverTests.swift`

The receiver needs to accept an optional `tcpNonce`, validate it as the first 16 bytes of the TCP stream, and fall back to IP validation when no nonce is set.

- [ ] **Step 1: Write failing test — nonce validation accepts correct nonce**

Add to `TcpImageReceiverTests.swift`:

```swift
func testAcceptsConnectionWithCorrectNonce() throws {
    let nonce = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    let payload = Data((0..<1024).map { UInt8($0 % 256) })
    let receiver = TcpImageReceiver(
        expectedSize: payload.count,
        allowedSenderIp: nil,
        tcpNonce: nonce
    )

    let info = try receiver.start()
    defer { receiver.closeServer() }

    let expectation = self.expectation(description: "data received")
    var received: Data?
    var receiveError: Error?

    DispatchQueue.global().async {
        do {
            received = try receiver.receive()
        } catch {
            receiveError = error
        }
        expectation.fulfill()
    }

    Thread.sleep(forTimeInterval: 0.05)

    // Send nonce prefix followed by payload
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = info.port.bigEndian
    "127.0.0.1".withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }
    withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            _ = connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    var combined = nonce
    combined.append(payload)
    combined.withUnsafeBytes { ptr in
        _ = write(fd, ptr.baseAddress!, combined.count)
    }

    wait(for: [expectation], timeout: 5.0)

    XCTAssertNil(receiveError, "Unexpected error: \(receiveError!)")
    XCTAssertEqual(received, payload)
}
```

- [ ] **Step 2: Write failing test — nonce validation rejects wrong nonce**

Add to `TcpImageReceiverTests.swift`:

```swift
func testRejectsConnectionWithWrongNonce() throws {
    let nonce = Data(repeating: 0xAA, count: 16)
    let wrongNonce = Data(repeating: 0xBB, count: 16)
    let payload = Data(repeating: 0x42, count: 64)
    let receiver = TcpImageReceiver(
        expectedSize: payload.count,
        allowedSenderIp: nil,
        tcpNonce: nonce,
        noConnectionTimeoutMs: 2000,
        maxConnections: 1
    )

    let info = try receiver.start()
    defer { receiver.closeServer() }

    let expectation = self.expectation(description: "receive completes")
    var receiveError: Error?

    DispatchQueue.global().async {
        do {
            _ = try receiver.receive()
        } catch {
            receiveError = error
        }
        expectation.fulfill()
    }

    Thread.sleep(forTimeInterval: 0.05)

    // Send wrong nonce prefix
    var wrongData = wrongNonce
    wrongData.append(payload)
    try? TcpImageSender.send(host: "127.0.0.1", port: info.port, data: wrongData)

    wait(for: [expectation], timeout: 5.0)

    XCTAssertNotNil(receiveError)
    XCTAssertTrue(receiveError is TcpTransferError)
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --package-path macos/ClipRelayMac --filter TcpImageReceiverTests`
Expected: FAIL — `tcpNonce` parameter doesn't exist yet.

- [ ] **Step 4: Implement nonce support in TcpImageReceiver**

Modify `TcpImageReceiver.swift`. Add `tcpNonce` parameter (default `nil`). In the `receive()` method, after accepting a connection: if `tcpNonce` is set, read the first 16 bytes and constant-time compare. If mismatch, close and try next connection. If `tcpNonce` is nil, use existing IP validation as fallback.

Replace the `init` and the IP validation + read section in `receive()`:

Change the `init`:
```swift
init(
    expectedSize: Int,
    allowedSenderIp: String?,
    tcpNonce: Data? = nil,
    noConnectionTimeoutMs: Int = 30_000,
    transferTimeoutMs: Int = 120_000,
    maxConnections: Int = 2
) {
    self.expectedSize = expectedSize
    self.allowedSenderIp = allowedSenderIp
    self.tcpNonce = tcpNonce
    self.noConnectionTimeoutMs = noConnectionTimeoutMs
    self.transferTimeoutMs = transferTimeoutMs
    self.maxConnections = maxConnections
}
```

Add the stored property alongside the existing ones:
```swift
private let tcpNonce: Data?
```

Replace the section in `receive()` from `// Validate sender IP` through to `let data = try readExactly(...)` — the entire inner body after `accept()` succeeds — with:

```swift
            // Validate connection
            if let nonce = tcpNonce {
                // Nonce-based validation: read first 16 bytes and constant-time compare
                setReceiveTimeout(fd: clientFd, ms: transferTimeoutMs)
                do {
                    let receivedNonce = try readExactly(fd: clientFd, size: 16)
                    // Constant-time comparison to prevent timing attacks
                    var mismatch: UInt8 = 0
                    for i in 0..<16 {
                        mismatch |= receivedNonce[i] ^ nonce[i]
                    }
                    if mismatch != 0 {
                        close(clientFd)
                        continue
                    }
                } catch {
                    close(clientFd)
                    continue
                }
            } else {
                // TODO(2026-05-01): Remove IP validation fallback — all clients should support tcpNonce by now
                if let allowed = allowedSenderIp {
                    var remoteHostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    withUnsafePointer(to: &clientAddr) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                            _ = getnameinfo(sa, clientAddrLen, &remoteHostname,
                                            socklen_t(remoteHostname.count), nil, 0, NI_NUMERICHOST)
                        }
                    }
                    let remoteIp = String(cString: remoteHostname)
                    if remoteIp != allowed {
                        close(clientFd)
                        continue
                    }
                }
            }

            // Set transfer timeout
            setReceiveTimeout(fd: clientFd, ms: transferTimeoutMs)

            do {
                let data = try readExactly(fd: clientFd, size: expectedSize)
                close(clientFd)
                return data
            } catch {
                close(clientFd)
                throw error
            }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --package-path macos/ClipRelayMac --filter TcpImageReceiverTests`
Expected: All 5 tests PASS (3 existing + 2 new).

- [ ] **Step 6: Commit**

```bash
git add macos/ClipRelayMac/Sources/TCP/TcpImageReceiver.swift macos/ClipRelayMac/Tests/ClipRelayTests/TcpImageReceiverTests.swift
git commit -m "feat(mac): add tcpNonce validation to TcpImageReceiver

Receiver validates a 16-byte nonce as TCP preamble when set.
Falls back to IP validation when tcpNonce is nil (old clients).
Uses constant-time comparison to prevent timing attacks."
```

---

### Task 2: Add source binding to macOS TcpImageSender

**Files:**
- Modify: `macos/ClipRelayMac/Sources/TCP/TcpImageSender.swift`
- Test: `macos/ClipRelayMac/Tests/ClipRelayTests/TcpImageSenderTests.swift`

The sender needs to: (1) accept an optional `nonce` to prepend to the TCP stream, and (2) bind to a local IP before connecting to bypass VPN routing.

- [ ] **Step 1: Write failing test — sender prepends nonce to data**

Add to `TcpImageSenderTests.swift`:

```swift
func testSenderPrependsNonceToData() throws {
    let nonce = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    let payload = Data((0..<512).map { UInt8($0 % 256) })

    // Start a simple TCP server
    let serverFd = socket(AF_INET, SOCK_STREAM, 0)
    XCTAssertGreaterThanOrEqual(serverFd, 0)
    defer { close(serverFd) }

    var yes: Int32 = 1
    setsockopt(serverFd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr.s_addr = INADDR_ANY.bigEndian

    withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            _ = Darwin.bind(serverFd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    _ = listen(serverFd, 1)

    var boundAddr = sockaddr_in()
    var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
    withUnsafeMutablePointer(to: &boundAddr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            _ = getsockname(serverFd, sa, &addrLen)
        }
    }
    let port = UInt16(bigEndian: boundAddr.sin_port)

    let expectation = self.expectation(description: "data received by server")
    var receivedData = Data()

    DispatchQueue.global().async {
        let clientFd = accept(serverFd, nil, nil)
        guard clientFd >= 0 else { return }
        defer { close(clientFd) }

        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(clientFd, &buffer, buffer.count)
            if n <= 0 { break }
            receivedData.append(contentsOf: buffer[0..<n])
        }
        expectation.fulfill()
    }

    try TcpImageSender.send(host: "127.0.0.1", port: port, data: payload, nonce: nonce)

    wait(for: [expectation], timeout: 5.0)

    // First 16 bytes should be the nonce, rest should be the payload
    XCTAssertEqual(receivedData.count, nonce.count + payload.count)
    XCTAssertEqual(receivedData.prefix(16), nonce)
    XCTAssertEqual(receivedData.dropFirst(16), payload)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path macos/ClipRelayMac --filter TcpImageSenderTests`
Expected: FAIL — `nonce` parameter doesn't exist.

- [ ] **Step 3: Implement nonce prefix and source binding in TcpImageSender**

Replace the entire `TcpImageSender.swift`:

```swift
import Foundation

enum TcpImageSender {
    /// Connects to a TCP server and sends the given data, optionally prefixed with a nonce.
    /// When `sourceIp` is provided, binds the socket to that local address before connecting
    /// (forces routing over the LAN interface even when a VPN is active).
    static func send(
        host: String,
        port: UInt16,
        data: Data,
        nonce: Data? = nil,
        sourceIp: String? = nil,
        connectTimeoutMs: Int = 3000
    ) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw TcpTransferError.sendFailed("socket() failed: \(errno)")
        }

        defer { close(fd) }

        // Bind to LAN interface to bypass VPN routing
        if let srcIp = sourceIp {
            var srcAddr = sockaddr_in()
            srcAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            srcAddr.sin_family = sa_family_t(AF_INET)
            srcAddr.sin_port = 0 // OS-assigned source port
            if srcIp.withCString({ inet_pton(AF_INET, $0, &srcAddr.sin_addr) }) == 1 {
                _ = withUnsafePointer(to: &srcAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                // If bind fails, proceed without binding (graceful degradation)
            }
        }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian

        guard host.withCString({ inet_pton(AF_INET, $0, &addr.sin_addr) }) == 1 else {
            throw TcpTransferError.sendFailed("Invalid host address: \(host)")
        }

        // Set send timeout
        var tv = timeval()
        tv.tv_sec = connectTimeoutMs / 1000
        tv.tv_usec = Int32((connectTimeoutMs % 1000) * 1000)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else {
            throw TcpTransferError.sendFailed("connect() failed: \(errno)")
        }

        // Write nonce prefix if provided
        if let nonce = nonce {
            try nonce.withUnsafeBytes { rawPtr in
                guard let baseAddress = rawPtr.baseAddress else { return }
                var offset = 0
                while offset < nonce.count {
                    let n = write(fd, baseAddress.advanced(by: offset), nonce.count - offset)
                    if n < 0 {
                        throw TcpTransferError.sendFailed("write() nonce failed: \(errno)")
                    }
                    offset += n
                }
            }
        }

        // Write payload
        try data.withUnsafeBytes { rawPtr in
            guard let baseAddress = rawPtr.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let n = write(fd, baseAddress.advanced(by: offset), data.count - offset)
                if n < 0 {
                    throw TcpTransferError.sendFailed("write() failed: \(errno)")
                }
                offset += n
            }
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path macos/ClipRelayMac --filter TcpImageSenderTests`
Expected: All 3 tests PASS (2 existing + 1 new).

- [ ] **Step 5: Commit**

```bash
git add macos/ClipRelayMac/Sources/TCP/TcpImageSender.swift macos/ClipRelayMac/Tests/ClipRelayTests/TcpImageSenderTests.swift
git commit -m "feat(mac): add nonce prefix and source binding to TcpImageSender

Sender prepends optional nonce bytes before payload on TCP stream.
Binds socket to local LAN IP when sourceIp is set, forcing traffic
over WiFi even when a VPN is active."
```

---

### Task 3: Wire nonce into macOS Session (OFFER/ACCEPT flow)

**Files:**
- Modify: `macos/ClipRelayMac/Sources/Protocol/Session.swift`
- Test: `macos/ClipRelayMac/Tests/ClipRelayTests/SessionTests.swift`

Connect the nonce and source binding to the session-level image transfer flow.

- [ ] **Step 1: Write failing test — ACCEPT includes tcpNonce**

Add to `SessionTests.swift`:

```swift
func testHandleInboundImageOfferIncludesTcpNonceInAccept() {
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
        // tcpNonce must be present and be 32 hex chars (16 bytes)
        let nonceHex = acceptJson["tcpNonce"] as? String
        XCTAssertNotNil(nonceHex, "ACCEPT should include tcpNonce")
        XCTAssertEqual(nonceHex?.count, 32, "tcpNonce should be 32 hex chars (16 bytes)")
    } else {
        XCTFail("Failed to parse ACCEPT payload")
    }

    session.close()
    cleanupManual(env)
}
```

- [ ] **Step 2: Write failing test — OFFER still includes senderIp**

Add to `SessionTests.swift` (update existing `testSendImageSendsCorrectOfferJSON` assertion is already there — just verify the test still passes after changes). No new test needed; the existing test at line 916 already asserts `senderIp` is present.

- [ ] **Step 3: Run tests to verify new test fails**

Run: `swift test --package-path macos/ClipRelayMac --filter SessionTests/testHandleInboundImageOfferIncludesTcpNonceInAccept`
Expected: FAIL — `tcpNonce` not in ACCEPT payload.

- [ ] **Step 4: Implement nonce in Session — receiver side (handleInboundImageOffer)**

In `Session.swift`, modify `handleInboundImageOffer`:

a) Make `senderIp` optional in OFFER parsing (for backward compat). Change the guard:

```swift
guard let json = try JSONSerialization.jsonObject(with: msg.payload) as? [String: Any],
      let contentType = json["type"] as? String,
      let size = json["size"] as? Int,
      let hash = json["hash"] as? String else {
    throw SessionError.protocolError("Invalid image OFFER payload")
}
let senderIp = json["senderIp"] as? String
```

b) Generate a 16-byte nonce and pass to `TcpImageReceiver`:

```swift
// Generate per-transfer nonce for TCP authentication
var nonceBytes = [UInt8](repeating: 0, count: 16)
_ = SecRandomCopyBytes(kSecRandomDefault, 16, &nonceBytes)
let tcpNonce = Data(nonceBytes)

let receiver = TcpImageReceiver(
    expectedSize: expectedSize,
    allowedSenderIp: senderIp,
    tcpNonce: tcpNonce
)
```

c) Include `tcpNonce` hex in the ACCEPT message:

```swift
let nonceHex = tcpNonce.map { String(format: "%02x", $0) }.joined()
let acceptJSON: [String: Any] = [
    "tcpHost": serverInfo.host,
    "tcpPort": Int(serverInfo.port),
    "tcpNonce": nonceHex
]
```

- [ ] **Step 5: Implement nonce in Session — sender side (doSendImage)**

In `Session.swift`, modify `doSendImage`:

a) Parse optional `tcpNonce` from ACCEPT:

```swift
case .accept:
    guard let acceptJson = try? JSONSerialization.jsonObject(with: response.payload) as? [String: Any],
          let tcpHost = acceptJson["tcpHost"] as? String,
          let tcpPort = acceptJson["tcpPort"] as? Int else {
        throw SessionError.protocolError("Invalid ACCEPT payload for image")
    }

    // Parse optional tcpNonce (new receivers include this)
    // TODO(2026-05-01): Remove IP validation fallback — all clients should support tcpNonce by now
    var tcpNonce: Data?
    if let nonceHex = acceptJson["tcpNonce"] as? String {
        tcpNonce = hexToData(nonceHex)
    }
```

b) Pass nonce and source IP to TcpImageSender:

```swift
try TcpImageSender.send(
    host: tcpHost,
    port: UInt16(tcpPort),
    data: encrypted,
    nonce: tcpNonce,
    sourceIp: LocalNetworkAddress.getLocalIPv4Address()
)
```

c) Add a `hexToData` helper at the bottom of the Session class (or reuse `E2ECrypto.hexToData` if accessible):

```swift
private func hexToData(_ hex: String) -> Data? {
    return E2ECrypto.hexToData(hex)
}
```

- [ ] **Step 6: Run all macOS tests**

Run: `swift test --package-path macos/ClipRelayMac`
Expected: ALL PASS.

- [ ] **Step 7: Commit**

```bash
git add macos/ClipRelayMac/Sources/Protocol/Session.swift macos/ClipRelayMac/Tests/ClipRelayTests/SessionTests.swift
git commit -m "feat(mac): wire tcpNonce into Session OFFER/ACCEPT flow

Receiver generates 16-byte random nonce, includes it as hex in ACCEPT.
Sender parses tcpNonce from ACCEPT and sends as TCP preamble.
Sender binds to LAN IP to bypass VPN routing.
senderIp kept in OFFER for backward compatibility with old receivers."
```

---

### Task 4: Add nonce support to Android TcpImageReceiver

**Files:**
- Modify: `android/app/src/main/java/org/cliprelay/tcp/TcpImageReceiver.kt`
- Test: `android/app/src/test/java/org/cliprelay/tcp/TcpImageReceiverTest.kt`

Mirror the macOS receiver changes.

- [ ] **Step 1: Write failing test — nonce validation accepts correct nonce**

Add to `TcpImageReceiverTest.kt`:

```kotlin
@Test
fun acceptsConnectionWithCorrectNonce() {
    val nonce = ByteArray(16).also { java.security.SecureRandom().nextBytes(it) }
    val payload = ByteArray(1024) { it.toByte() }
    val receiver = TcpImageReceiver(
        expectedSize = payload.size,
        allowedSenderIp = null,
        tcpNonce = nonce,
    )

    val info = receiver.start()
    try {
        val thread = Thread {
            Thread.sleep(50)
            val socket = Socket()
            socket.connect(InetSocketAddress("127.0.0.1", info.port), 1000)
            socket.getOutputStream().write(nonce)
            socket.getOutputStream().write(payload)
            socket.getOutputStream().flush()
            socket.close()
        }
        thread.start()

        val received = receiver.receive()
        assertArrayEquals(payload, received)
        thread.join(2000)
    } finally {
        receiver.close()
    }
}
```

- [ ] **Step 2: Write failing test — nonce validation rejects wrong nonce**

Add to `TcpImageReceiverTest.kt`:

```kotlin
@Test
fun rejectsConnectionWithWrongNonce() {
    val nonce = ByteArray(16) { 0xAA.toByte() }
    val wrongNonce = ByteArray(16) { 0xBB.toByte() }
    val payload = ByteArray(64) { 0x42 }
    val receiver = TcpImageReceiver(
        expectedSize = payload.size,
        allowedSenderIp = null,
        tcpNonce = nonce,
        maxConnections = 1,
        noConnectionTimeoutMs = 2000,
    )

    val info = receiver.start()
    try {
        val thread = Thread {
            Thread.sleep(50)
            try {
                val socket = Socket()
                socket.connect(InetSocketAddress("127.0.0.1", info.port), 1000)
                socket.getOutputStream().write(wrongNonce)
                socket.getOutputStream().write(payload)
                socket.getOutputStream().flush()
                socket.close()
            } catch (_: Exception) {}
        }
        thread.start()

        try {
            receiver.receive()
            fail("Expected TcpTransferException")
        } catch (e: TcpTransferException) {
            // expected
        }
        thread.join(2000)
    } finally {
        receiver.close()
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd android && ./gradlew testDebugUnitTest --tests "org.cliprelay.tcp.TcpImageReceiverTest"`
Expected: FAIL — `tcpNonce` parameter doesn't exist.

- [ ] **Step 4: Implement nonce support in TcpImageReceiver.kt**

Add `tcpNonce` parameter to the constructor:

```kotlin
class TcpImageReceiver(
    private val expectedSize: Int,
    private val allowedSenderIp: String?,
    private val tcpNonce: ByteArray? = null,
    private val noConnectionTimeoutMs: Int = 30_000,
    private val transferTimeoutMs: Int = 120_000,
    private val maxConnections: Int = 2,
)
```

In `receive()`, replace the IP validation block (after `client = server.accept()`, inside the `try` block) with:

```kotlin
try {
    if (tcpNonce != null) {
        // Nonce-based validation: read first 16 bytes and constant-time compare
        client.soTimeout = transferTimeoutMs
        val receivedNonce = try {
            readExactly(client.getInputStream(), 16)
        } catch (e: Exception) {
            client.close()
            continue
        }
        // Constant-time comparison
        var mismatch: Int = 0
        for (i in 0 until 16) {
            mismatch = mismatch or (receivedNonce[i].toInt() xor tcpNonce[i].toInt())
        }
        if (mismatch != 0) {
            client.close()
            continue
        }
    } else {
        // TODO(2026-05-01): Remove IP validation fallback — all clients should support tcpNonce by now
        val remoteIp = (client.remoteSocketAddress as? InetSocketAddress)
            ?.address?.hostAddress

        if (allowedSenderIp != null && remoteIp != allowedSenderIp) {
            client.close()
            continue
        }
    }

    client.soTimeout = transferTimeoutMs
    val data = readExactly(client.getInputStream(), expectedSize)
    return data
} finally {
    try { client.close() } catch (_: Exception) {}
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd android && ./gradlew testDebugUnitTest --tests "org.cliprelay.tcp.TcpImageReceiverTest"`
Expected: All 5 tests PASS.

- [ ] **Step 6: Commit**

```bash
git add android/app/src/main/java/org/cliprelay/tcp/TcpImageReceiver.kt android/app/src/test/java/org/cliprelay/tcp/TcpImageReceiverTest.kt
git commit -m "feat(android): add tcpNonce validation to TcpImageReceiver

Mirrors macOS implementation. Validates 16-byte nonce as TCP preamble.
Falls back to IP validation when tcpNonce is null (old clients).
Uses constant-time comparison to prevent timing attacks."
```

---

### Task 5: Add source binding and nonce to Android TcpImageSender

**Files:**
- Modify: `android/app/src/main/java/org/cliprelay/tcp/TcpImageSender.kt`
- Test: `android/app/src/test/java/org/cliprelay/tcp/TcpImageSenderTest.kt`

- [ ] **Step 1: Write failing test — sender prepends nonce to data**

Add to `TcpImageSenderTest.kt`:

```kotlin
@Test
fun senderPrependsNonceToData() {
    val nonce = ByteArray(16).also { java.security.SecureRandom().nextBytes(it) }
    val payload = ByteArray(512) { (it % 256).toByte() }
    val server = ServerSocket(0)

    try {
        val received = ByteArray(nonce.size + payload.size)
        val serverThread = Thread {
            val client = server.accept()
            val input = client.getInputStream()
            var offset = 0
            while (offset < received.size) {
                val n = input.read(received, offset, received.size - offset)
                if (n == -1) break
                offset += n
            }
            client.close()
        }
        serverThread.start()

        TcpImageSender.send("127.0.0.1", server.localPort, payload, nonce = nonce)

        serverThread.join(5000)
        assertArrayEquals(nonce, received.sliceArray(0 until 16))
        assertArrayEquals(payload, received.sliceArray(16 until received.size))
    } finally {
        server.close()
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd android && ./gradlew testDebugUnitTest --tests "org.cliprelay.tcp.TcpImageSenderTest"`
Expected: FAIL — `nonce` parameter doesn't exist.

- [ ] **Step 3: Implement nonce prefix and source binding in TcpImageSender.kt**

Replace the entire `TcpImageSender.kt`:

```kotlin
package org.cliprelay.tcp

import java.net.InetSocketAddress
import java.net.Socket

object TcpImageSender {
    /**
     * Connects to a TCP server and sends the given data, optionally prefixed with a nonce.
     * When [sourceIp] is provided, binds the socket to that local address before connecting
     * (forces routing over the LAN interface even when a VPN is active).
     */
    fun send(
        host: String,
        port: Int,
        data: ByteArray,
        nonce: ByteArray? = null,
        sourceIp: String? = null,
        connectTimeoutMs: Int = 3000,
    ) {
        val socket = Socket()
        try {
            // Bind to LAN interface to bypass VPN routing
            if (sourceIp != null) {
                try {
                    socket.bind(InetSocketAddress(sourceIp, 0))
                } catch (_: Exception) {
                    // If bind fails, proceed without binding (graceful degradation)
                }
            }
            socket.connect(InetSocketAddress(host, port), connectTimeoutMs)
            val out = socket.getOutputStream()
            if (nonce != null) {
                out.write(nonce)
            }
            out.write(data)
            out.flush()
        } catch (e: Exception) {
            throw TcpTransferException("Failed to send: ${e.message}", e)
        } finally {
            try { socket.close() } catch (_: Exception) {}
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd android && ./gradlew testDebugUnitTest --tests "org.cliprelay.tcp.TcpImageSenderTest"`
Expected: All 3 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add android/app/src/main/java/org/cliprelay/tcp/TcpImageSender.kt android/app/src/test/java/org/cliprelay/tcp/TcpImageSenderTest.kt
git commit -m "feat(android): add nonce prefix and source binding to TcpImageSender

Mirrors macOS implementation. Prepends optional nonce before payload.
Binds socket to local LAN IP when sourceIp is set."
```

---

### Task 6: Wire nonce into Android Session (OFFER/ACCEPT flow)

**Files:**
- Modify: `android/app/src/main/java/org/cliprelay/protocol/Session.kt`

No new unit tests — the Session tests that exist are integration-level and the underlying TCP components are already tested.

- [ ] **Step 1: Modify handleInboundImageOffer — generate nonce, include in ACCEPT**

In `Session.kt`, modify `handleInboundImageOffer`:

a) Make `senderIp` optional:

```kotlin
val senderIp = json.optString("senderIp", null)
```

b) Generate nonce and pass to receiver:

```kotlin
// Generate per-transfer nonce for TCP authentication
val tcpNonce = ByteArray(16).also { java.security.SecureRandom().nextBytes(it) }

val receiver = TcpImageReceiver(
    expectedSize = expectedSize,
    allowedSenderIp = senderIp,
    tcpNonce = tcpNonce,
)
```

c) Include nonce hex in ACCEPT:

```kotlin
val acceptJson = JSONObject().apply {
    put("tcpHost", serverInfo.host)
    put("tcpPort", serverInfo.port)
    put("tcpNonce", tcpNonce.joinToString("") { "%02x".format(it) })
}
```

- [ ] **Step 2: Modify doSendImage — parse nonce from ACCEPT, pass to sender**

In `Session.kt`, modify `doSendImage`:

a) Parse optional `tcpNonce` from ACCEPT response:

```kotlin
MessageType.ACCEPT -> {
    val acceptJson = JSONObject(String(response.payload))
    val tcpHost = acceptJson.getString("tcpHost")
    val tcpPort = acceptJson.getInt("tcpPort")

    // Parse optional tcpNonce (new receivers include this)
    // TODO(2026-05-01): Remove IP validation fallback — all clients should support tcpNonce by now
    val tcpNonce = acceptJson.optString("tcpNonce", null)?.let { hex ->
        ByteArray(hex.length / 2) { i ->
            hex.substring(i * 2, i * 2 + 2).toInt(16).toByte()
        }
    }
```

b) Pass nonce and source IP to sender:

```kotlin
TcpImageSender.send(
    tcpHost,
    tcpPort,
    encrypted,
    nonce = tcpNonce,
    sourceIp = NetworkUtil.getLocalIpAddress(),
)
```

- [ ] **Step 3: Run all Android tests**

Run: `cd android && ./gradlew testDebugUnitTest`
Expected: ALL PASS.

- [ ] **Step 4: Commit**

```bash
git add android/app/src/main/java/org/cliprelay/protocol/Session.kt
git commit -m "feat(android): wire tcpNonce into Session OFFER/ACCEPT flow

Mirrors macOS implementation. Receiver generates nonce, includes in ACCEPT.
Sender parses tcpNonce and sends as TCP preamble with LAN source binding.
senderIp kept in OFFER for backward compatibility with old receivers."
```

---

### Task 7: Full build + test + manual VPN verification

**Files:** None (verification only)

- [ ] **Step 1: Run full test suite**

Run: `scripts/test-all.sh`
Expected: ALL PASS.

- [ ] **Step 2: Run full build**

Run: `scripts/build-all.sh`
Expected: Build succeeds for both platforms.

- [ ] **Step 3: Update existing tests that assert senderIp is required**

Check `SessionTests.swift` line 916 — `XCTAssertNotNil(json["senderIp"])` should still pass since we still send `senderIp` in OFFER. The existing `testHandleInboundImageOfferStartsTcpServerAndSendsAccept` test at line 1029 should also still pass.

If any tests fail due to the changes, fix them.

- [ ] **Step 4: Manual VPN test**

With NordVPN active:
1. Copy an image on Mac
2. Verify it transfers to Android
3. Copy an image on Android
4. Verify it transfers to Mac

- [ ] **Step 5: Commit any test fixups if needed**
