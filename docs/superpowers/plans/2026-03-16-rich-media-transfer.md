# Rich Media Transfer Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add image transfer between macOS and Android over TCP on LAN, with BLE for signaling, behind an experimental feature flag.

**Architecture:** Receiver-as-server, sender pushes. BLE handles all signaling (OFFER/ACCEPT/REJECT/ERROR/DONE). TCP is ephemeral — server spins up per transfer, tears down after. Images encrypted with existing AES-256-GCM session key as single blob.

**Tech Stack:** Kotlin (Android), Swift (macOS), BSD sockets / Java ServerSocket for TCP, existing E2ECrypto for encryption.

**Spec:** `docs/superpowers/specs/2026-03-16-rich-media-transfer-design.md`

### Concurrency Model

Both platforms use a single-threaded listen loop that reads BLE messages sequentially. The existing text send flow (`doSendClipboard`) runs on this same loop: it writes OFFER, then reads ACCEPT, writes PAYLOAD, reads DONE — all synchronous on the same thread and stream. Image transfer follows the same pattern: `doSendImage` writes OFFER, reads ACCEPT/REJECT/ERROR, then does the TCP push on a separate thread, then reads DONE. Since the listen loop is single-threaded, there is no interleaving risk for BLE messages.

The outbound queue is used for *requests* from the UI/service thread (e.g. "send this image"). The listen loop dequeues requests and calls `doSendImage`/`handleInboundImageOffer`, which write protocol messages (OFFER, ACCEPT, DONE, ERROR, REJECT) **directly** to the output stream via `MessageCodec.write(output, msg)` — the same pattern as existing `doSendClipboard`. This is safe because they run on the listen loop thread, which is the only thread that reads/writes the BLE stream.

In the code snippets below, `sendMessage(msg)` means `MessageCodec.write(output, msg)` — a direct, synchronous write on the listen loop thread. It does NOT go through the outbound queue.

### Timestamp Convention

Both platforms use **Unix seconds** (not milliseconds) for `richMediaEnabledChangedAt`. Use `System.currentTimeMillis() / 1000` on Android and `Int(Date().timeIntervalSince1970)` on macOS.

---

## Chunk 1: Protocol Foundation (Both Platforms)

### Task 1: Add new message types to MessageCodec (Android)

**Files:**
- Modify: `android/app/src/main/java/org/cliprelay/protocol/MessageCodec.kt`
- Test: `android/app/src/test/java/org/cliprelay/protocol/MessageCodecTest.kt`

- [ ] **Step 1: Write test for new message types**

Add to `MessageCodecTest.kt`:

```kotlin
@Test
fun `encode and decode CONFIG_UPDATE message`() {
    val payload = """{"richMediaEnabled":true,"richMediaEnabledChangedAt":1773698112}""".toByteArray()
    val msg = Message(MessageType.CONFIG_UPDATE, payload)
    val encoded = MessageCodec.encode(msg)
    val decoded = MessageCodec.decode(ByteArrayInputStream(encoded))
    assertEquals(MessageType.CONFIG_UPDATE, decoded.type)
    assertArrayEquals(payload, decoded.payload)
}

@Test
fun `encode and decode REJECT message`() {
    val payload = """{"reason":"device_locked"}""".toByteArray()
    val msg = Message(MessageType.REJECT, payload)
    val encoded = MessageCodec.encode(msg)
    val decoded = MessageCodec.decode(ByteArrayInputStream(encoded))
    assertEquals(MessageType.REJECT, decoded.type)
    assertArrayEquals(payload, decoded.payload)
}

@Test
fun `encode and decode ERROR message`() {
    val payload = """{"code":"transfer_failed","message":"timeout"}""".toByteArray()
    val msg = Message(MessageType.ERROR, payload)
    val encoded = MessageCodec.encode(msg)
    val decoded = MessageCodec.decode(ByteArrayInputStream(encoded))
    assertEquals(MessageType.ERROR, decoded.type)
    assertArrayEquals(payload, decoded.payload)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd android && ./gradlew testDebugUnitTest --tests "org.cliprelay.protocol.MessageCodecTest" 2>&1 | tail -20`
Expected: FAIL — `CONFIG_UPDATE`, `REJECT`, `ERROR` not defined in `MessageType` enum.

- [ ] **Step 3: Add new message types to enum**

In `MessageCodec.kt`, extend the `MessageType` enum (after `DONE(0x13)`):

```kotlin
CONFIG_UPDATE(0x14),
REJECT(0x15),
ERROR(0x16);
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd android && ./gradlew testDebugUnitTest --tests "org.cliprelay.protocol.MessageCodecTest" 2>&1 | tail -20`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add android/app/src/main/java/org/cliprelay/protocol/MessageCodec.kt android/app/src/test/java/org/cliprelay/protocol/MessageCodecTest.kt
git commit -m "feat(protocol): add CONFIG_UPDATE, REJECT, ERROR message types (Android)"
```

---

### Task 2: Handle unknown message types gracefully in MessageCodec (Android)

**Files:**
- Modify: `android/app/src/main/java/org/cliprelay/protocol/MessageCodec.kt`
- Test: `android/app/src/test/java/org/cliprelay/protocol/MessageCodecTest.kt`

- [ ] **Step 1: Write test for unknown message type**

Add to `MessageCodecTest.kt`:

```kotlin
@Test
fun `decode skips unknown message type and reads next message`() {
    // Encode a message with unknown type byte 0xFF, followed by a valid DONE message
    val unknownPayload = "unknown".toByteArray()
    val unknownLength = 1 + unknownPayload.size // type byte + payload
    val donePayload = """{"hash":"abc","ok":true}""".toByteArray()
    val doneMsg = MessageCodec.encode(Message(MessageType.DONE, donePayload))

    val buf = ByteArrayOutputStream()
    // Write unknown message: [4-byte BE length][0xFF type][payload]
    buf.write(ByteBuffer.allocate(4).putInt(unknownLength).array())
    buf.write(0xFF)
    buf.write(unknownPayload)
    // Write valid DONE message
    buf.write(doneMsg)

    val stream = ByteArrayInputStream(buf.toByteArray())
    val decoded = MessageCodec.decode(stream)
    // Should skip the unknown message and return the DONE message
    assertEquals(MessageType.DONE, decoded.type)
    assertArrayEquals(donePayload, decoded.payload)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd android && ./gradlew testDebugUnitTest --tests "org.cliprelay.protocol.MessageCodecTest.decode skips unknown message type and reads next message" 2>&1 | tail -20`
Expected: FAIL — currently throws `ProtocolException("Unknown message type")`

- [ ] **Step 3: Update decode to skip unknown types**

In `MessageCodec.kt`, in the `decode()` method, replace the line that throws on unknown type with a loop that skips unknown types and reads the next message:

```kotlin
fun decode(input: InputStream): Message {
    while (true) {
        val lengthBytes = readExactly(input, 4)
        val length = ByteBuffer.wrap(lengthBytes).int
        if (length < 1 || length > MAX_MESSAGE_SIZE) {
            throw ProtocolException("Invalid message length: $length")
        }
        val body = readExactly(input, length)
        val typeByte = body[0].toInt() and 0xFF
        val type = MessageType.entries.firstOrNull { it.value == typeByte }
        if (type == null) {
            android.util.Log.w("MessageCodec", "Skipping unknown message type: 0x${typeByte.toString(16)}")
            continue
        }
        val payload = body.copyOfRange(1, body.size)
        return Message(type, payload)
    }
}
```

- [ ] **Step 4: Run all MessageCodec tests**

Run: `cd android && ./gradlew testDebugUnitTest --tests "org.cliprelay.protocol.MessageCodecTest" 2>&1 | tail -20`
Expected: ALL PASS

- [ ] **Step 5: Commit**

```bash
git add android/app/src/main/java/org/cliprelay/protocol/MessageCodec.kt android/app/src/test/java/org/cliprelay/protocol/MessageCodecTest.kt
git commit -m "fix(protocol): skip unknown message types instead of throwing (Android)"
```

---

### Task 3: Add new message types to MessageCodec (macOS)

**Files:**
- Modify: `macos/ClipRelayMac/Sources/Protocol/MessageCodec.swift`
- Test: `macos/ClipRelayMac/Tests/MessageCodecTests.swift`

- [ ] **Step 1: Write test for new message types**

Add to `MessageCodecTests.swift`:

```swift
func testEncodeDecodeConfigUpdate() throws {
    let payload = Data("""{"richMediaEnabled":true,"richMediaEnabledChangedAt":1773698112}""".utf8)
    let msg = Message(type: .configUpdate, payload: payload)
    let encoded = MessageCodec.encode(msg)
    let decoded = try MessageCodec.decode(from: encoded)
    XCTAssertEqual(decoded.type, .configUpdate)
    XCTAssertEqual(decoded.payload, payload)
}

func testEncodeDecodeReject() throws {
    let payload = Data("""{"reason":"device_locked"}""".utf8)
    let msg = Message(type: .reject, payload: payload)
    let encoded = MessageCodec.encode(msg)
    let decoded = try MessageCodec.decode(from: encoded)
    XCTAssertEqual(decoded.type, .reject)
    XCTAssertEqual(decoded.payload, payload)
}

func testEncodeDecodeError() throws {
    let payload = Data("""{"code":"transfer_failed"}""".utf8)
    let msg = Message(type: .error, payload: payload)
    let encoded = MessageCodec.encode(msg)
    let decoded = try MessageCodec.decode(from: encoded)
    XCTAssertEqual(decoded.type, .error)
    XCTAssertEqual(decoded.payload, payload)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd macos && xcodebuild test -scheme ClipRelayMac -only-testing:"ClipRelayMacTests/MessageCodecTests/testEncodeDecodeConfigUpdate" 2>&1 | tail -20`
Expected: FAIL — `configUpdate`, `reject`, `error` not defined.

- [ ] **Step 3: Add new cases to MessageType enum**

In `MessageCodec.swift`, extend the `MessageType` enum (after `done = 0x13`):

```swift
case configUpdate = 0x14
case reject = 0x15
case error = 0x16
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd macos && xcodebuild test -scheme ClipRelayMac -only-testing:"ClipRelayMacTests/MessageCodecTests" 2>&1 | tail -20`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add macos/ClipRelayMac/Sources/Protocol/MessageCodec.swift macos/ClipRelayMac/Tests/MessageCodecTests.swift
git commit -m "feat(protocol): add CONFIG_UPDATE, REJECT, ERROR message types (macOS)"
```

---

### Task 4: Handle unknown message types gracefully in MessageCodec (macOS)

**Files:**
- Modify: `macos/ClipRelayMac/Sources/Protocol/MessageCodec.swift`
- Test: `macos/ClipRelayMac/Tests/MessageCodecTests.swift`

- [ ] **Step 1: Write test for unknown message type**

Add to `MessageCodecTests.swift`:

```swift
func testDecodeSkipsUnknownMessageType() throws {
    // Encode an unknown message (type 0xFF) followed by a valid DONE
    var buf = Data()
    let unknownPayload = Data("unknown".utf8)
    let unknownLength = UInt32(1 + unknownPayload.count).bigEndian
    withUnsafeBytes(of: unknownLength) { buf.append(contentsOf: $0) }
    buf.append(0xFF) // unknown type
    buf.append(unknownPayload)

    let donePayload = Data("""{"hash":"abc","ok":true}""".utf8)
    let doneEncoded = MessageCodec.encode(Message(type: .done, payload: donePayload))
    buf.append(doneEncoded)

    let decoded = try MessageCodec.decode(from: buf)
    XCTAssertEqual(decoded.type, .done)
    XCTAssertEqual(decoded.payload, donePayload)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd macos && xcodebuild test -scheme ClipRelayMac -only-testing:"ClipRelayMacTests/MessageCodecTests/testDecodeSkipsUnknownMessageType" 2>&1 | tail -20`
Expected: FAIL — throws `ProtocolError.unknownType`

- [ ] **Step 3: Update decode to skip unknown types**

In `MessageCodec.swift`, update the `decode(from data: Data, offset: inout Int)` method to skip unknown types. Replace the `guard let type = MessageType(rawValue: typeByte)` block:

```swift
static func decode(from data: Data, offset: inout Int) throws -> Message {
    while true {
        guard offset + 4 <= data.count else { throw ProtocolError.truncated }
        let length = Int(data[offset..<offset+4].withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
        offset += 4
        guard length >= 1, length <= maxMessageSize else { throw ProtocolError.invalidLength }
        guard offset + length <= data.count else { throw ProtocolError.truncated }
        let typeByte = data[offset]
        let payload = data[offset + 1 ..< offset + length]
        offset += length
        guard let type = MessageType(rawValue: typeByte) else {
            os_log("Skipping unknown message type: 0x%02x", log: .default, type: .info, typeByte)
            continue
        }
        return Message(type: type, payload: Data(payload))
    }
}
```

Also update the `decode(from inputStream: InputStream)` method similarly — wrap in `while true`, skip unknown types with `continue`.

- [ ] **Step 4: Run all MessageCodec tests**

Run: `cd macos && xcodebuild test -scheme ClipRelayMac -only-testing:"ClipRelayMacTests/MessageCodecTests" 2>&1 | tail -20`
Expected: ALL PASS

- [ ] **Step 5: Run existing L2CAP fixture compatibility tests to ensure no regressions**

Run: `cd macos && xcodebuild test -scheme ClipRelayMac -only-testing:"ClipRelayMacTests/L2capFixtureCompatibilityTests" 2>&1 | tail -20`
Expected: ALL PASS

- [ ] **Step 6: Commit**

```bash
git add macos/ClipRelayMac/Sources/Protocol/MessageCodec.swift macos/ClipRelayMac/Tests/MessageCodecTests.swift
git commit -m "fix(protocol): skip unknown message types instead of throwing (macOS)"
```

---

### Task 5: Update Session to route new message types (Android)

**Files:**
- Modify: `android/app/src/main/java/org/cliprelay/protocol/Session.kt`
- Test: `android/app/src/test/java/org/cliprelay/protocol/SessionTest.kt`

- [ ] **Step 1: Write test that unknown message types in session don't crash**

Add to `SessionTest.kt`:

```kotlin
@Test
fun `session ignores CONFIG_UPDATE when no handler registered`() {
    // Set up a session with a mock stream that sends HELLO, then CONFIG_UPDATE, then OFFER
    // Verify the session completes handshake and processes OFFER without crashing on CONFIG_UPDATE
    // (Exact test setup depends on existing SessionTest patterns — follow existing mock patterns)
}
```

Note: Adapt to existing test patterns in `SessionTest.kt`. The key assertion is that `handleInbound()` does not throw when receiving CONFIG_UPDATE, REJECT, or ERROR.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd android && ./gradlew testDebugUnitTest --tests "org.cliprelay.protocol.SessionTest" 2>&1 | tail -20`
Expected: FAIL — `handleInbound()` throws on unexpected message type.

- [ ] **Step 3: Update handleInbound to route or ignore new types**

In `Session.kt`, update `handleInbound()` to handle new message types. For now, log and ignore — actual handlers will be added in later tasks:

```kotlin
private fun handleInbound(msg: Message) {
    when (msg.type) {
        MessageType.OFFER -> handleInboundOffer(msg)
        MessageType.CONFIG_UPDATE -> { /* handled in later task */ }
        MessageType.REJECT -> { /* handled in later task */ }
        MessageType.ERROR -> { /* handled in later task */ }
        else -> Log.w(TAG, "Ignoring unexpected message type: ${msg.type}")
    }
}
```

- [ ] **Step 4: Run all Session tests**

Run: `cd android && ./gradlew testDebugUnitTest --tests "org.cliprelay.protocol.SessionTest" 2>&1 | tail -20`
Expected: ALL PASS

- [ ] **Step 5: Commit**

```bash
git add android/app/src/main/java/org/cliprelay/protocol/Session.kt android/app/src/test/java/org/cliprelay/protocol/SessionTest.kt
git commit -m "feat(protocol): route new message types in Session (Android)"
```

---

### Task 6: Update Session to route new message types (macOS)

**Files:**
- Modify: `macos/ClipRelayMac/Sources/Protocol/Session.swift`
- Test: `macos/ClipRelayMac/Tests/SessionTests.swift`

- [ ] **Step 1: Write test that new message types don't crash the session**

Add to `SessionTests.swift`, following existing test patterns.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd macos && xcodebuild test -scheme ClipRelayMac -only-testing:"ClipRelayMacTests/SessionTests" 2>&1 | tail -20`
Expected: FAIL

- [ ] **Step 3: Update handleInbound to route or ignore new types**

In `Session.swift`, update `handleInbound()`:

```swift
private func handleInbound(_ msg: Message) throws {
    switch msg.type {
    case .offer:
        try handleInboundOffer(msg)
    case .configUpdate:
        break // handled in later task
    case .reject:
        break // handled in later task
    case .error:
        break // handled in later task
    default:
        logger.warning("Ignoring unexpected message type: \(String(describing: msg.type))")
    }
}
```

- [ ] **Step 4: Run all Session tests**

Run: `cd macos && xcodebuild test -scheme ClipRelayMac -only-testing:"ClipRelayMacTests/SessionTests" 2>&1 | tail -20`
Expected: ALL PASS

- [ ] **Step 5: Commit**

```bash
git add macos/ClipRelayMac/Sources/Protocol/Session.swift macos/ClipRelayMac/Tests/SessionTests.swift
git commit -m "feat(protocol): route new message types in Session (macOS)"
```

---

## Chunk 2: Feature Flag & Config Sync

### Task 7: Add rich media settings to PairingStore (Android)

**Files:**
- Modify: `android/app/src/main/java/org/cliprelay/pairing/PairingStore.kt`
- Test: `android/app/src/test/java/org/cliprelay/pairing/PairingStoreTest.kt` (create)

- [ ] **Step 1: Write tests for rich media settings persistence**

Create `PairingStoreTest.kt`:

```kotlin
@RunWith(RobolectricTestRunner::class)
class PairingStoreTest {
    private lateinit var store: PairingStore

    @Before
    fun setup() {
        store = PairingStore(ApplicationProvider.getApplicationContext())
    }

    @Test
    fun `richMediaEnabled defaults to false`() {
        assertFalse(store.isRichMediaEnabled())
    }

    @Test
    fun `save and load richMediaEnabled`() {
        val timestamp = System.currentTimeMillis()
        store.setRichMediaEnabled(true, timestamp)
        assertTrue(store.isRichMediaEnabled())
        assertEquals(timestamp, store.getRichMediaEnabledChangedAt())
    }

    @Test
    fun `clear resets richMediaEnabled`() {
        store.setRichMediaEnabled(true, System.currentTimeMillis())
        store.clear()
        assertFalse(store.isRichMediaEnabled())
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd android && ./gradlew testDebugUnitTest --tests "org.cliprelay.pairing.PairingStoreTest" 2>&1 | tail -20`
Expected: FAIL — methods don't exist.

- [ ] **Step 3: Add rich media settings methods to PairingStore**

In `PairingStore.kt`, add:

```kotlin
companion object {
    private const val KEY_RICH_MEDIA_ENABLED = "rich_media_enabled"
    private const val KEY_RICH_MEDIA_ENABLED_CHANGED_AT = "rich_media_enabled_changed_at"
}

fun isRichMediaEnabled(): Boolean =
    prefs.getBoolean(KEY_RICH_MEDIA_ENABLED, false)

fun getRichMediaEnabledChangedAt(): Long =
    prefs.getLong(KEY_RICH_MEDIA_ENABLED_CHANGED_AT, 0L)

fun setRichMediaEnabled(enabled: Boolean, changedAt: Long) {
    prefs.edit()
        .putBoolean(KEY_RICH_MEDIA_ENABLED, enabled)
        .putLong(KEY_RICH_MEDIA_ENABLED_CHANGED_AT, changedAt)
        .apply()
}
```

Also update `clear()` to remove these keys.

- [ ] **Step 4: Run tests**

Run: `cd android && ./gradlew testDebugUnitTest --tests "org.cliprelay.pairing.PairingStoreTest" 2>&1 | tail -20`
Expected: ALL PASS

- [ ] **Step 5: Commit**

```bash
git add android/app/src/main/java/org/cliprelay/pairing/PairingStore.kt android/app/src/test/java/org/cliprelay/pairing/PairingStoreTest.kt
git commit -m "feat(settings): add richMediaEnabled to PairingStore (Android)"
```

---

### Task 8: Add rich media settings to PairingManager (macOS)

**Files:**
- Modify: `macos/ClipRelayMac/Sources/Pairing/PairingManager.swift` (or `KeychainStore.swift` — whichever holds per-device settings)
- Test: existing or new test file

- [ ] **Step 1: Write tests for settings persistence**

Follow macOS test patterns. Test that `PairedDevice` (or equivalent) can store and retrieve `richMediaEnabled` and `richMediaEnabledChangedAt`.

- [ ] **Step 2: Run tests to verify they fail**

- [ ] **Step 3: Add rich media fields to the paired device model**

Add `richMediaEnabled: Bool` (default `false`) and `richMediaEnabledChangedAt: Int64` (default `0`) to the paired device storage. Persist via Keychain or UserDefaults alongside existing pairing data.

- [ ] **Step 4: Run tests**

Expected: ALL PASS

- [ ] **Step 5: Commit**

```bash
git add macos/ClipRelayMac/Sources/ macos/ClipRelayMac/Tests/
git commit -m "feat(settings): add richMediaEnabled to pairing storage (macOS)"
```

---

### Task 9: Include settings in HELLO/WELCOME handshake (Android)

**Files:**
- Modify: `android/app/src/main/java/org/cliprelay/protocol/Session.kt`
- Test: `android/app/src/test/java/org/cliprelay/protocol/SessionTest.kt`

- [ ] **Step 1: Write test that HELLO payload includes settings**

```kotlin
@Test
fun `helloPayload includes settings when richMediaEnabled`() {
    // Create a Session with PairingStore that has richMediaEnabled=true
    // Call helloPayload() and parse the JSON
    // Assert settings.richMediaEnabled == true
    // Assert settings.richMediaEnabledChangedAt is present
}
```

- [ ] **Step 2: Run test to verify it fails**

- [ ] **Step 3: Extend helloPayload() to include settings**

In `Session.kt`, update `helloPayload()` to include the `settings` object:

```kotlin
private fun helloPayload(ephemeralPublicKey: ByteArray): ByteArray {
    val json = JSONObject()
    json.put("version", 2)
    json.put("ek", ephemeralPublicKey.toHex())
    json.put("auth", E2ECrypto.hmacAuth(authKey, ephemeralPublicKey).toHex())
    json.put("name", Build.MODEL)
    // Add settings
    val settings = JSONObject()
    settings.put("richMediaEnabled", pairingStore.isRichMediaEnabled())
    settings.put("richMediaEnabledChangedAt", pairingStore.getRichMediaEnabledChangedAt())
    json.put("settings", settings)
    return json.toString().toByteArray()
}
```

- [ ] **Step 4: Write test that validateVersion parses remote settings and resolves last-write-wins**

```kotlin
@Test
fun `validateVersion resolves richMediaEnabled with last-write-wins`() {
    // Local: richMediaEnabled=false, changedAt=1000
    // Remote HELLO has: richMediaEnabled=true, changedAt=2000
    // After validateVersion, local store should have richMediaEnabled=true, changedAt=2000
}

@Test
fun `validateVersion keeps local settings when local is newer`() {
    // Local: richMediaEnabled=true, changedAt=2000
    // Remote HELLO has: richMediaEnabled=false, changedAt=1000
    // After validateVersion, local store should keep richMediaEnabled=true, changedAt=2000
}
```

- [ ] **Step 5: Run tests to verify they fail**

- [ ] **Step 6: Update validateVersion to parse and resolve settings**

In `Session.kt`, in `validateVersion()`, after validating auth, parse the optional `settings` object:

```kotlin
val remoteSettings = json.optJSONObject("settings")
if (remoteSettings != null) {
    val remoteEnabled = remoteSettings.optBoolean("richMediaEnabled", false)
    val remoteChangedAt = remoteSettings.optLong("richMediaEnabledChangedAt", 0)
    val localChangedAt = pairingStore.getRichMediaEnabledChangedAt()
    if (remoteChangedAt > localChangedAt) {
        pairingStore.setRichMediaEnabled(remoteEnabled, remoteChangedAt)
    }
}
```

- [ ] **Step 7: Run all Session tests**

Expected: ALL PASS

- [ ] **Step 8: Commit**

```bash
git add android/app/src/main/java/org/cliprelay/protocol/Session.kt android/app/src/test/java/org/cliprelay/protocol/SessionTest.kt
git commit -m "feat(protocol): include richMedia settings in HELLO/WELCOME handshake (Android)"
```

---

### Task 10: Include settings in HELLO/WELCOME handshake (macOS)

**Files:**
- Modify: `macos/ClipRelayMac/Sources/Protocol/Session.swift`
- Test: `macos/ClipRelayMac/Tests/SessionTests.swift`

Mirror Task 9 for macOS:

- [ ] **Step 1: Write test that HELLO payload includes settings**
- [ ] **Step 2: Run test to verify it fails**
- [ ] **Step 3: Extend helloPayload() to include settings**
- [ ] **Step 4: Write test for last-write-wins resolution in validateVersion**
- [ ] **Step 5: Run test to verify it fails**
- [ ] **Step 6: Update validateVersion to parse and resolve settings**
- [ ] **Step 7: Run all Session tests**

Expected: ALL PASS

- [ ] **Step 8: Commit**

```bash
git add macos/ClipRelayMac/Sources/Protocol/Session.swift macos/ClipRelayMac/Tests/SessionTests.swift
git commit -m "feat(protocol): include richMedia settings in HELLO/WELCOME handshake (macOS)"
```

---

### Task 11: Implement CONFIG_UPDATE send and receive (Android)

**Files:**
- Modify: `android/app/src/main/java/org/cliprelay/protocol/Session.kt`
- Modify: `android/app/src/main/java/org/cliprelay/service/ClipRelayService.kt`
- Test: `android/app/src/test/java/org/cliprelay/protocol/SessionTest.kt`

- [ ] **Step 1: Write test for CONFIG_UPDATE handling**

```kotlin
@Test
fun `handleConfigUpdate persists remote settings when newer`() {
    // Send a CONFIG_UPDATE message with richMediaEnabled=true, changedAt=newer
    // Verify PairingStore is updated
}

@Test
fun `handleConfigUpdate ignores remote settings when older`() {
    // Send a CONFIG_UPDATE message with changedAt=older than local
    // Verify PairingStore is NOT updated
}
```

- [ ] **Step 2: Run tests to verify they fail**

- [ ] **Step 3: Implement handleConfigUpdate in Session**

```kotlin
private fun handleConfigUpdate(msg: Message) {
    val json = JSONObject(String(msg.payload))
    val remoteEnabled = json.optBoolean("richMediaEnabled", false)
    val remoteChangedAt = json.optLong("richMediaEnabledChangedAt", 0)
    val localChangedAt = pairingStore.getRichMediaEnabledChangedAt()
    if (remoteChangedAt > localChangedAt) {
        pairingStore.setRichMediaEnabled(remoteEnabled, remoteChangedAt)
        callback.onRichMediaSettingChanged(remoteEnabled)
    }
}
```

Update `handleInbound()` to call `handleConfigUpdate()` for `CONFIG_UPDATE`.

- [ ] **Step 4: Add sendConfigUpdate method to Session**

```kotlin
fun sendConfigUpdate() {
    val json = JSONObject()
    json.put("richMediaEnabled", pairingStore.isRichMediaEnabled())
    json.put("richMediaEnabledChangedAt", pairingStore.getRichMediaEnabledChangedAt())
    val msg = Message(MessageType.CONFIG_UPDATE, json.toString().toByteArray())
    outboundQueue.put(msg)
}
```

- [ ] **Step 5: Run all Session tests**

Expected: ALL PASS

- [ ] **Step 6: Commit**

```bash
git add android/app/src/main/java/org/cliprelay/protocol/Session.kt android/app/src/test/java/org/cliprelay/protocol/SessionTest.kt
git commit -m "feat(protocol): implement CONFIG_UPDATE send/receive (Android)"
```

---

### Task 12: Implement CONFIG_UPDATE send and receive (macOS)

Mirror Task 11 for macOS.

**Files:**
- Modify: `macos/ClipRelayMac/Sources/Protocol/Session.swift`
- Modify: `macos/ClipRelayMac/Sources/App/AppDelegate.swift`
- Test: `macos/ClipRelayMac/Tests/SessionTests.swift`

- [ ] **Step 1-6: Same structure as Task 11, adapted for Swift**
- [ ] **Step 7: Commit**

```bash
git add macos/ClipRelayMac/Sources/ macos/ClipRelayMac/Tests/
git commit -m "feat(protocol): implement CONFIG_UPDATE send/receive (macOS)"
```

---

### Task 13: Add settings UI toggle (Android)

**Files:**
- Modify: `android/app/src/main/java/org/cliprelay/ui/SettingsScreen.kt`
- Modify: `android/app/src/main/java/org/cliprelay/service/ClipRelayService.kt`

- [ ] **Step 1: Add "Image sync (experimental)" toggle to SettingsScreen**

Follow the existing pattern of the auto-copy toggle. Add a new row below it:

```kotlin
SettingRow(
    title = "Image sync (experimental)",
    subtitle = "Sync images between devices over Wi-Fi",
    checked = richMediaEnabled,
    onCheckedChange = { enabled ->
        val changedAt = System.currentTimeMillis()
        pairingStore.setRichMediaEnabled(enabled, changedAt)
        // Notify service to send CONFIG_UPDATE
        context.startService(
            Intent(context, ClipRelayService::class.java)
                .setAction(ClipRelayService.ACTION_SEND_CONFIG_UPDATE)
        )
    }
)
```

- [ ] **Step 2: Add ACTION_SEND_CONFIG_UPDATE to ClipRelayService**

In `ClipRelayService.kt`, handle the new action in `onStartCommand()`:

```kotlin
ACTION_SEND_CONFIG_UPDATE -> {
    activeSession?.sendConfigUpdate()
}
```

- [ ] **Step 3: Manually test the toggle**

Build and install: `cd android && ./gradlew installDebug`
Open settings, verify toggle appears and persists.

- [ ] **Step 4: Commit**

```bash
git add android/app/src/main/java/org/cliprelay/ui/SettingsScreen.kt android/app/src/main/java/org/cliprelay/service/ClipRelayService.kt
git commit -m "feat(ui): add Image sync toggle in Android settings"
```

---

### Task 14: Add settings UI toggle (macOS)

**Files:**
- Modify: the macOS settings/preferences view (find the SwiftUI or AppKit settings view)
- Modify: `macos/ClipRelayMac/Sources/App/AppDelegate.swift`

- [ ] **Step 1: Add "Image sync (experimental)" toggle to macOS settings**

Follow the existing auto-copy toggle pattern. When toggled, persist via PairingManager and call `activeSession?.sendConfigUpdate()`.

- [ ] **Step 2: Manually test**

Build and run, verify toggle appears in settings.

- [ ] **Step 3: Commit**

```bash
git add macos/ClipRelayMac/Sources/
git commit -m "feat(ui): add Image sync toggle in macOS settings"
```

---

## Chunk 3: TCP Transport Layer

### Task 15: Implement NetworkUtil and TCP server (Android)

**Note:** NetworkUtil is implemented first since TcpImageReceiver depends on it.

#### Task 15a: NetworkUtil for LAN IP (Android)

**Files:**
- Create: `android/app/src/main/java/org/cliprelay/tcp/NetworkUtil.kt`
- Test: `android/app/src/test/java/org/cliprelay/tcp/NetworkUtilTest.kt`

- [ ] **Step 1: Write test**

```kotlin
class NetworkUtilTest {
    @Test
    fun `getLocalIpAddress returns non-loopback IPv4 or null`() {
        val ip = NetworkUtil.getLocalIpAddress()
        if (ip != null) {
            assertFalse(ip.startsWith("127."))
            assertTrue(ip.matches(Regex("""\d+\.\d+\.\d+\.\d+""")))
        }
    }
}
```

- [ ] **Step 2: Implement NetworkUtil**

```kotlin
package org.cliprelay.tcp

import java.net.Inet4Address
import java.net.NetworkInterface

object NetworkUtil {
    fun getLocalIpAddress(): String? {
        return NetworkInterface.getNetworkInterfaces()?.asSequence()
            ?.filter { it.isUp && !it.isLoopback }
            ?.filter { it.name.startsWith("wlan") || it.name.startsWith("eth") }
            ?.flatMap { it.inetAddresses.asSequence() }
            ?.filterIsInstance<Inet4Address>()
            ?.firstOrNull()
            ?.hostAddress
    }
}
```

- [ ] **Step 3: Run tests and commit**

```bash
git add android/app/src/main/java/org/cliprelay/tcp/NetworkUtil.kt android/app/src/test/java/org/cliprelay/tcp/NetworkUtilTest.kt
git commit -m "feat(tcp): implement NetworkUtil for LAN IP detection (Android)"
```

#### Task 15b: TCP server (Android)

**Files:**
- Create: `android/app/src/main/java/org/cliprelay/tcp/TcpImageReceiver.kt`
- Test: `android/app/src/test/java/org/cliprelay/tcp/TcpImageReceiverTest.kt`

- [ ] **Step 1: Write test for TCP server accepting connection and receiving data**

```kotlin
class TcpImageReceiverTest {
    @Test
    fun `server accepts connection and receives exact bytes`() {
        val testData = ByteArray(1024) { it.toByte() }
        val receiver = TcpImageReceiver(
            expectedSize = testData.size,
            allowedSenderIp = "127.0.0.1",
            noConnectionTimeoutMs = 5000,
            transferTimeoutMs = 10000
        )
        val serverInfo = receiver.start() // returns (host, port)

        // Connect as client and send data
        thread {
            Socket("127.0.0.1", serverInfo.port).use { socket ->
                socket.getOutputStream().write(testData)
                socket.getOutputStream().flush()
            }
        }

        val received = receiver.awaitResult()
        assertArrayEquals(testData, received)
    }

    @Test
    fun `server rejects connection from wrong IP`() {
        // This is hard to test locally since all connections come from 127.0.0.1
        // Test with allowedSenderIp set to a non-loopback IP
        val receiver = TcpImageReceiver(
            expectedSize = 100,
            allowedSenderIp = "10.0.0.99",
            noConnectionTimeoutMs = 2000,
            transferTimeoutMs = 5000
        )
        val serverInfo = receiver.start()

        thread {
            Socket("127.0.0.1", serverInfo.port).use { socket ->
                socket.getOutputStream().write(ByteArray(100))
            }
        }

        assertThrows(TcpTransferException::class.java) {
            receiver.awaitResult()
        }
    }

    @Test
    fun `server times out when no connection`() {
        val receiver = TcpImageReceiver(
            expectedSize = 100,
            allowedSenderIp = "127.0.0.1",
            noConnectionTimeoutMs = 500,
            transferTimeoutMs = 5000
        )
        receiver.start()

        assertThrows(TcpTransferException::class.java) {
            receiver.awaitResult()
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd android && ./gradlew testDebugUnitTest --tests "org.cliprelay.tcp.TcpImageReceiverTest" 2>&1 | tail -20`
Expected: FAIL — class doesn't exist.

- [ ] **Step 3: Implement TcpImageReceiver**

Create `TcpImageReceiver.kt`:

```kotlin
package org.cliprelay.tcp

import java.io.IOException
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket

class TcpTransferException(message: String, cause: Throwable? = null) : IOException(message, cause)

data class ServerInfo(val host: String, val port: Int)

class TcpImageReceiver(
    private val expectedSize: Int,
    private val allowedSenderIp: String,
    private val noConnectionTimeoutMs: Int = 30_000,
    private val transferTimeoutMs: Int = 120_000
) {
    private var serverSocket: ServerSocket? = null
    @Volatile private var cancelled = false

    fun start(): ServerInfo {
        val server = ServerSocket()
        server.reuseAddress = true
        server.bind(InetSocketAddress("0.0.0.0", 0))
        server.soTimeout = noConnectionTimeoutMs
        serverSocket = server
        val host = NetworkUtil.getLocalIpAddress()
            ?: throw TcpTransferException("No Wi-Fi IP address available")
        return ServerInfo(host, server.localPort)
    }

    fun awaitResult(): ByteArray {
        val server = serverSocket ?: throw TcpTransferException("Server not started")
        try {
            // Accept up to maxAttempts connections (supports sender retry)
            val maxAttempts = 2
            for (attempt in 1..maxAttempts) {
                val client: Socket = try {
                    server.accept()
                } catch (e: java.net.SocketTimeoutException) {
                    throw TcpTransferException("No connection within timeout", e)
                }

                client.use { socket ->
                    // Validate sender IP
                    val remoteIp = socket.inetAddress.hostAddress
                    if (remoteIp != allowedSenderIp) {
                        Log.w(TAG, "Rejected connection from $remoteIp, expected $allowedSenderIp")
                        if (attempt < maxAttempts) continue
                        throw TcpTransferException("Rejected connection from wrong IP")
                    }

                    socket.soTimeout = transferTimeoutMs
                    val input = socket.getInputStream()
                    val buffer = ByteArray(expectedSize)
                    var offset = 0
                    while (offset < expectedSize) {
                        if (cancelled) throw TcpTransferException("Transfer cancelled")
                        val read = input.read(buffer, offset, expectedSize - offset)
                        if (read == -1) {
                            // Connection dropped — allow retry
                            if (attempt < maxAttempts) break
                            throw TcpTransferException("Connection closed after $offset/$expectedSize bytes")
                        }
                        offset += read
                    }
                    if (offset == expectedSize) return buffer
                    // Incomplete read, retry if attempts remain
                }
            }
            throw TcpTransferException("Transfer failed after $maxAttempts attempts")
        } finally {
            close()
        }
    }

    fun cancel() {
        cancelled = true
        close()
    }

    fun close() {
        try { serverSocket?.close() } catch (_: IOException) {}
        serverSocket = null
    }
}
```

- [ ] **Step 4: Run tests**

Run: `cd android && ./gradlew testDebugUnitTest --tests "org.cliprelay.tcp.TcpImageReceiverTest" 2>&1 | tail -20`
Expected: ALL PASS

- [ ] **Step 5: Commit**

```bash
git add android/app/src/main/java/org/cliprelay/tcp/TcpImageReceiver.kt android/app/src/test/java/org/cliprelay/tcp/TcpImageReceiverTest.kt
git commit -m "feat(tcp): implement TcpImageReceiver with IP validation and timeouts (Android)"
```

---

### Task 16: Implement TCP client (Android)

**Files:**
- Create: `android/app/src/main/java/org/cliprelay/tcp/TcpImageSender.kt`
- Test: `android/app/src/test/java/org/cliprelay/tcp/TcpImageSenderTest.kt`

- [ ] **Step 1: Write test for TCP client sending data**

```kotlin
class TcpImageSenderTest {
    @Test
    fun `sender connects and pushes data`() {
        // Start a local server
        val received = ByteArray(1024)
        val server = ServerSocket(0)
        val serverThread = thread {
            server.accept().use { client ->
                var offset = 0
                val input = client.getInputStream()
                while (offset < received.size) {
                    val n = input.read(received, offset, received.size - offset)
                    if (n == -1) break
                    offset += n
                }
            }
        }

        val testData = ByteArray(1024) { it.toByte() }
        TcpImageSender.send(
            host = "127.0.0.1",
            port = server.localPort,
            data = testData,
            connectTimeoutMs = 3000
        )

        serverThread.join(5000)
        server.close()
        assertArrayEquals(testData, received)
    }

    @Test
    fun `sender throws on connection refused`() {
        assertThrows(TcpTransferException::class.java) {
            TcpImageSender.send(
                host = "127.0.0.1",
                port = 1, // unlikely to be open
                data = ByteArray(100),
                connectTimeoutMs = 1000
            )
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

- [ ] **Step 3: Implement TcpImageSender**

Create `TcpImageSender.kt`:

```kotlin
package org.cliprelay.tcp

import java.net.InetSocketAddress
import java.net.Socket

object TcpImageSender {
    fun send(host: String, port: Int, data: ByteArray, connectTimeoutMs: Int = 3000) {
        val socket = Socket()
        try {
            socket.connect(InetSocketAddress(host, port), connectTimeoutMs)
            socket.getOutputStream().write(data)
            socket.getOutputStream().flush()
        } catch (e: Exception) {
            throw TcpTransferException("Failed to send: ${e.message}", e)
        } finally {
            try { socket.close() } catch (_: Exception) {}
        }
    }
}
```

- [ ] **Step 4: Run tests**

Expected: ALL PASS

- [ ] **Step 5: Commit**

```bash
git add android/app/src/main/java/org/cliprelay/tcp/TcpImageSender.kt android/app/src/test/java/org/cliprelay/tcp/TcpImageSenderTest.kt
git commit -m "feat(tcp): implement TcpImageSender (Android)"
```

---

### Task 17: (Merged into Task 15a)

---

### Task 18: Implement TCP server (macOS)

**Files:**
- Create: `macos/ClipRelayMac/Sources/TCP/TcpImageReceiver.swift`
- Test: `macos/ClipRelayMac/Tests/TcpImageReceiverTests.swift`

- [ ] **Step 1: Write tests**

Mirror the Android tests: test data reception, IP rejection, timeout.

- [ ] **Step 2: Implement TcpImageReceiver using BSD sockets**

Use POSIX socket APIs (`socket`, `bind`, `listen`, `accept`, `read`). Set `SO_REUSEADDR`, `SO_RCVTIMEO` for timeouts. Validate source IP against `allowedSenderIp`.

- [ ] **Step 3: Run tests**
- [ ] **Step 4: Commit**

```bash
git add macos/ClipRelayMac/Sources/TCP/ macos/ClipRelayMac/Tests/TcpImageReceiverTests.swift
git commit -m "feat(tcp): implement TcpImageReceiver with BSD sockets (macOS)"
```

---

### Task 19: Implement TCP client (macOS)

**Files:**
- Create: `macos/ClipRelayMac/Sources/TCP/TcpImageSender.swift`
- Test: `macos/ClipRelayMac/Tests/TcpImageSenderTests.swift`

- [ ] **Step 1: Write tests**

Mirror Android: test data push, connection refused.

- [ ] **Step 2: Implement TcpImageSender using BSD sockets**

Use `socket`, `connect`, `write`. Set `SO_SNDTIMEO` for timeout.

- [ ] **Step 3: Run tests**
- [ ] **Step 4: Commit**

```bash
git add macos/ClipRelayMac/Sources/TCP/ macos/ClipRelayMac/Tests/TcpImageSenderTests.swift
git commit -m "feat(tcp): implement TcpImageSender with BSD sockets (macOS)"
```

---

### Task 20: Implement LocalNetworkAddress (macOS)

**Files:**
- Create: `macos/ClipRelayMac/Sources/TCP/LocalNetworkAddress.swift`
- Test: `macos/ClipRelayMac/Tests/LocalNetworkAddressTests.swift`

- [ ] **Step 1: Write test**
- [ ] **Step 2: Implement — iterate network interfaces, filter en0/en1, return IPv4**
- [ ] **Step 3: Run tests**
- [ ] **Step 4: Commit**

```bash
git add macos/ClipRelayMac/Sources/TCP/ macos/ClipRelayMac/Tests/LocalNetworkAddressTests.swift
git commit -m "feat(tcp): implement LocalNetworkAddress for Wi-Fi IP (macOS)"
```

---

## Chunk 4: Image Transfer Integration

### Task 21: Implement image OFFER/ACCEPT/TCP flow in Session (Android)

**Files:**
- Modify: `android/app/src/main/java/org/cliprelay/protocol/Session.kt`
- Test: `android/app/src/test/java/org/cliprelay/protocol/SessionTest.kt`

This is the core integration. Session must handle:

**Sending an image (Android → Mac):**

- [ ] **Step 1: Write test for sendImage OFFER flow**

```kotlin
@Test
fun `sendImage sends OFFER with type, hash, size, senderIp then connects to receiver TCP`() {
    // Mock outbound stream, verify OFFER JSON contains image fields
    // Mock inbound ACCEPT with tcpHost/tcpPort
    // Verify TCP client is called with correct host/port/encrypted data
    // Verify DONE is received
}
```

- [ ] **Step 2: Run test to verify it fails**

- [ ] **Step 3: Implement sendImage in Session**

Add a `sendImage(imageData: ByteArray, contentType: String)` method:

```kotlin
fun sendImage(imageData: ByteArray, contentType: String) {
    outboundImageQueue.put(Pair(imageData, contentType))
}

private fun doSendImage(imageData: ByteArray, contentType: String) {
    val hash = sha256Hex(imageData)
    val senderIp = NetworkUtil.getLocalIpAddress()
        ?: throw IOException("No Wi-Fi IP")

    // Send OFFER
    val offerJson = JSONObject().apply {
        put("hash", hash)
        put("size", imageData.size)
        put("type", contentType)
        put("senderIp", senderIp)
    }
    sendMessage(Message(MessageType.OFFER, offerJson.toString().toByteArray()))

    // Wait for ACCEPT or REJECT or ERROR
    val response = MessageCodec.decode(input)
    when (response.type) {
        MessageType.ACCEPT -> {
            val acceptJson = JSONObject(String(response.payload))
            val tcpHost = acceptJson.getString("tcpHost")
            val tcpPort = acceptJson.getInt("tcpPort")

            // Encrypt
            val encrypted = E2ECrypto.seal(sessionKey, imageData)

            // Push via TCP (with 1 retry)
            // Note: receiver's TCP server accepts up to 2 connections (initial + retry)
            var lastError: TcpTransferException? = null
            for (attempt in 1..2) {
                try {
                    TcpImageSender.send(tcpHost, tcpPort, encrypted)
                    lastError = null
                    break
                } catch (e: TcpTransferException) {
                    lastError = e
                    if (attempt == 1) Thread.sleep(500) // brief pause before retry
                }
            }
            if (lastError != null) {
                sendMessage(Message(MessageType.ERROR,
                    """{"code":"connection_failed"}""".toByteArray()))
                throw lastError
            }

            // Wait for DONE
            val done = MessageCodec.decode(input)
            if (done.type != MessageType.DONE) {
                throw ProtocolException("Expected DONE, got ${done.type}")
            }
        }
        MessageType.REJECT -> {
            val reason = JSONObject(String(response.payload)).optString("reason", "unknown")
            Log.i(TAG, "Image OFFER rejected: $reason")
            callback.onImageRejected(reason)
        }
        MessageType.ERROR -> {
            val code = JSONObject(String(response.payload)).optString("code", "unknown")
            throw ProtocolException("Image OFFER got error: $code")
        }
        else -> throw ProtocolException("Expected ACCEPT/REJECT/ERROR, got ${response.type}")
    }
}
```

- [ ] **Step 4: Run tests**

Expected: ALL PASS

- [ ] **Step 5: Commit**

```bash
git add android/app/src/main/java/org/cliprelay/protocol/Session.kt android/app/src/test/java/org/cliprelay/protocol/SessionTest.kt
git commit -m "feat(protocol): implement image send flow in Session (Android)"
```

**Receiving an image (Mac → Android):**

- [ ] **Step 6: Write test for image OFFER reception**

```kotlin
@Test
fun `handleInboundImageOffer starts TCP server and sends ACCEPT`() {
    // Send an OFFER with type=image/png, hash, size, senderIp
    // Verify ACCEPT is sent back with tcpHost and tcpPort
    // Connect to the TCP server and push encrypted data
    // Verify DONE is sent
    // Verify callback.onImageReceived is called with decrypted data
}
```

- [ ] **Step 7: Run test to verify it fails**

- [ ] **Step 8: Implement handleInboundImageOffer**

```kotlin
private fun handleInboundImageOffer(msg: Message) {
    val json = JSONObject(String(msg.payload))
    val contentType = json.getString("type")
    val size = json.getInt("size")
    val hash = json.getString("hash")
    val senderIp = json.getString("senderIp")

    // Check feature flag
    if (!pairingStore.isRichMediaEnabled()) {
        sendMessage(Message(MessageType.REJECT,
            """{"reason":"feature_disabled"}""".toByteArray()))
        return
    }

    // Check size limit (10MB)
    if (size > 10 * 1024 * 1024) {
        sendMessage(Message(MessageType.REJECT,
            """{"reason":"size_exceeded"}""".toByteArray()))
        return
    }

    // Check device state (callback checks isInteractive/isDeviceLocked)
    if (!callback.isDeviceAwake()) {
        sendMessage(Message(MessageType.REJECT,
            """{"reason":"device_locked"}""".toByteArray()))
        return
    }

    // Cancel any in-flight transfer
    activeReceiver?.cancel()

    // Start TCP server
    val encryptedSize = size + 28 // GCM overhead
    val receiver = TcpImageReceiver(
        expectedSize = encryptedSize,
        allowedSenderIp = senderIp
    )
    activeReceiver = receiver

    try {
        val serverInfo = receiver.start()
        // Send ACCEPT
        val acceptJson = JSONObject().apply {
            put("tcpHost", serverInfo.host)
            put("tcpPort", serverInfo.port)
        }
        sendMessage(Message(MessageType.ACCEPT, acceptJson.toString().toByteArray()))

        // Await data
        val encrypted = receiver.awaitResult()

        // Decrypt and verify
        val plaintext = E2ECrypto.open(sessionKey, encrypted)
        val actualHash = sha256Hex(plaintext)
        if (actualHash != hash) {
            sendMessage(Message(MessageType.ERROR,
                """{"code":"hash_mismatch"}""".toByteArray()))
            return
        }

        // Success
        sendMessage(Message(MessageType.DONE,
            JSONObject().apply {
                put("hash", hash)
                put("ok", true)
            }.toString().toByteArray()))

        callback.onImageReceived(plaintext, contentType, hash)
    } catch (e: TcpTransferException) {
        sendMessage(Message(MessageType.ERROR,
            """{"code":"transfer_failed","message":"${e.message}"}""".toByteArray()))
    } finally {
        receiver.close()
        activeReceiver = null
    }
}
```

Update `handleInbound()` to distinguish text vs image OFFER:

```kotlin
MessageType.OFFER -> {
    val json = JSONObject(String(msg.payload))
    val type = json.optString("type", "text/plain")
    if (type.startsWith("image/")) {
        handleInboundImageOffer(msg)
    } else {
        handleInboundOffer(msg)
    }
}
```

- [ ] **Step 9: Run all Session tests**

Expected: ALL PASS

- [ ] **Step 10: Commit**

```bash
git add android/app/src/main/java/org/cliprelay/protocol/Session.kt android/app/src/test/java/org/cliprelay/protocol/SessionTest.kt
git commit -m "feat(protocol): implement image receive flow in Session (Android)"
```

---

### Task 22: Implement image OFFER/ACCEPT/TCP flow in Session (macOS)

**Files:**
- Modify: `macos/ClipRelayMac/Sources/Protocol/Session.swift`
- Test: `macos/ClipRelayMac/Tests/SessionTests.swift`

Mirror Task 21 for macOS. Same structure:

- [ ] **Step 1-5: Implement sendImage flow**
- [ ] **Step 6-10: Implement handleInboundImageOffer flow**

Key differences from Android:
- macOS does NOT check device lock state (always accepts)
- Uses BSD socket-based TcpImageReceiver/TcpImageSender
- Uses `LocalNetworkAddress.getIPv4()` instead of `NetworkUtil.getLocalIpAddress()`

- [ ] **Step 11: Commit**

```bash
git add macos/ClipRelayMac/Sources/ macos/ClipRelayMac/Tests/
git commit -m "feat(protocol): implement image send/receive flow in Session (macOS)"
```

---

## Chunk 5: Clipboard & Share Sheet Integration

### Task 23: Extend ClipboardMonitor to detect images (macOS)

**Files:**
- Modify: `macos/ClipRelayMac/Sources/Clipboard/ClipboardMonitor.swift`
- Test: `macos/ClipRelayMac/Tests/ClipboardMonitorTests.swift` (create if needed)

- [ ] **Step 1: Write test for image detection**

```swift
func testDetectsImageOnPasteboard() {
    // Write a PNG to pasteboard
    // Trigger poll()
    // Verify onImageChange callback fires with PNG data
}
```

- [ ] **Step 2: Run test to verify it fails**

- [ ] **Step 3: Extend poll() to detect images**

In `ClipboardMonitor.swift`, extend `poll()`:

```swift
private func poll() {
    let pasteboard = NSPasteboard.general
    let currentChangeCount = pasteboard.changeCount
    guard currentChangeCount != lastChangeCount else { return }
    lastChangeCount = currentChangeCount

    // Check for image first (PNG, JPEG, TIFF → convert to PNG)
    if let (imageData, contentType) = pasteboardImage(pasteboard) {
        let hash = SHA256.hash(data: imageData).hexString
        if hash != lastHash {
            lastHash = hash
            onImageChange?(imageData, contentType, hash)
        }
        return
    }

    // Fall back to text
    if let text = pasteboard.string(forType: .string) {
        let hash = SHA256.hash(data: Data(text.utf8)).hexString
        if hash != lastHash {
            lastHash = hash
            onChange?(text, hash)
        }
    }
}

/// Returns (imageData, contentType) or nil. TIFF is converted to PNG per spec.
private func pasteboardImage(_ pasteboard: NSPasteboard) -> (Data, String)? {
    let maxSize = 10_485_760 // 10 MB
    // Try PNG first
    if let png = pasteboard.data(forType: .png), png.count <= maxSize {
        return (png, "image/png")
    }
    // Try JPEG
    if let jpeg = pasteboard.data(forType: NSPasteboard.PasteboardType("public.jpeg")),
       jpeg.count <= maxSize {
        return (jpeg, "image/jpeg")
    }
    // Try TIFF → convert to PNG (Android has no native TIFF support)
    if let tiff = pasteboard.data(forType: .tiff),
       let image = NSImage(data: tiff),
       let png = image.pngData(),
       png.count <= maxSize {
        return (png, "image/png")
    }
    return nil
}
```

Add `onImageChange` callback property alongside existing `onChange`.

- [ ] **Step 4: Run tests**

Expected: ALL PASS

- [ ] **Step 5: Commit**

```bash
git add macos/ClipRelayMac/Sources/Clipboard/ClipboardMonitor.swift macos/ClipRelayMac/Tests/
git commit -m "feat(clipboard): detect images on pasteboard (macOS)"
```

---

### Task 24: Extend ClipboardWriter to write images (macOS)

**Files:**
- Modify: `macos/ClipRelayMac/Sources/Clipboard/ClipboardWriter.swift`

- [ ] **Step 1: Add writeImage method**

```swift
static func writeImage(_ data: Data) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setData(data, forType: .png)
}
```

- [ ] **Step 2: Commit**

```bash
git add macos/ClipRelayMac/Sources/Clipboard/ClipboardWriter.swift
git commit -m "feat(clipboard): add image write support (macOS)"
```

---

### Task 25: Wire image transfer into AppDelegate (macOS)

**Files:**
- Modify: `macos/ClipRelayMac/Sources/App/AppDelegate.swift`

- [ ] **Step 1: Handle image clipboard changes**

In `applicationDidFinishLaunching`, set up the `onImageChange` callback on the clipboard monitor:

```swift
clipboardMonitor.onImageChange = { [weak self] imageData, contentType, hash in
    guard let self = self else { return }
    guard self.lastReceivedImageHash != hash else { return } // echo loop prevention
    guard pairingStore.isRichMediaEnabled() else { return }
    self.activeSession?.sendImage(imageData, contentType: contentType)
}
```

- [ ] **Step 2: Handle received images in SessionDelegate**

Add handling in `session(_:didReceiveImage:contentType:hash:)`:

```swift
func session(_ session: Session, didReceiveImage data: Data, contentType: String, hash: String) {
    lastReceivedImageHash = hash
    DispatchQueue.main.async {
        ClipboardWriter.writeImage(data)
    }
}
```

- [ ] **Step 3: Add `lastReceivedImageHash` property**

```swift
private var lastReceivedImageHash: String?
```

- [ ] **Step 4: Build and manually test**

Run: `cd macos && xcodebuild -scheme ClipRelayMac build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add macos/ClipRelayMac/Sources/App/AppDelegate.swift
git commit -m "feat: wire image transfer into macOS app lifecycle"
```

---

### Task 26: Extend ClipboardWriter for images (Android)

**Files:**
- Modify: `android/app/src/main/java/org/cliprelay/service/ClipboardWriter.kt`

- [ ] **Step 1: Add writeImage method**

```kotlin
fun writeImage(context: Context, imageData: ByteArray, contentType: String) {
    // Write to temp file
    val extension = when {
        contentType.contains("png") -> "png"
        contentType.contains("jpeg") || contentType.contains("jpg") -> "jpg"
        else -> "png"
    }
    val file = File(context.cacheDir, "cliprelay_received.$extension")
    file.writeBytes(imageData)

    // Get content URI via FileProvider
    val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)

    // Set clipboard
    val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    val clip = ClipData.newUri(context.contentResolver, "ClipRelay Image", uri)
    clipboard.setPrimaryClip(clip)
}
```

- [ ] **Step 2: Ensure FileProvider is configured in AndroidManifest.xml**

Check that a `<provider>` entry exists for `FileProvider`. If not, add one with `file_paths.xml` pointing to `cacheDir`.

- [ ] **Step 3: Commit**

```bash
git add android/app/src/main/java/org/cliprelay/service/ClipboardWriter.kt android/app/src/main/AndroidManifest.xml android/app/src/main/res/xml/
git commit -m "feat(clipboard): add image write via FileProvider (Android)"
```

---

### Task 27: Wire image transfer into ClipRelayService (Android)

**Files:**
- Modify: `android/app/src/main/java/org/cliprelay/service/ClipRelayService.kt`

- [ ] **Step 1: Add image received callback**

Implement `onImageReceived` in ClipRelayService's SessionCallback:

```kotlin
override fun onImageReceived(data: ByteArray, contentType: String, hash: String) {
    lastReceivedImageHash = hash
    ClipboardWriter.writeImage(this, data, contentType)
}
```

- [ ] **Step 2: Add `isDeviceAwake` callback**

```kotlin
override fun isDeviceAwake(): Boolean {
    val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
    val km = getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
    return pm.isInteractive && !km.isDeviceLocked
}
```

- [ ] **Step 3: Add echo loop prevention for images**

```kotlin
private var lastReceivedImageHash: String? = null
```

Check this hash in `handleClipboardChanged()` if/when we add auto-send from Android clipboard.

- [ ] **Step 4: Build and test**

Run: `cd android && ./gradlew assembleDebug 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add android/app/src/main/java/org/cliprelay/service/ClipRelayService.kt
git commit -m "feat: wire image transfer into Android service"
```

---

### Task 28: Extend ShareReceiverActivity for images (Android)

**Files:**
- Modify: `android/app/src/main/java/org/cliprelay/ui/ShareReceiverActivity.kt`
- Modify: `android/app/src/main/AndroidManifest.xml`

- [ ] **Step 1: Add image/* intent filter to AndroidManifest.xml**

In the `ShareReceiverActivity` `<intent-filter>`, add:

```xml
<data android:mimeType="image/*" />
```

- [ ] **Step 2: Handle image intent in ShareReceiverActivity**

Extend `onCreate()` to handle `image/*`:

```kotlin
override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)

    when {
        intent?.type?.startsWith("text/") == true -> handleTextShare()
        intent?.type?.startsWith("image/") == true -> handleImageShare()
        else -> {
            Toast.makeText(this, "Unsupported content type", Toast.LENGTH_SHORT).show()
            finish()
        }
    }
}

private fun handleImageShare() {
    val imageUri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
    } else {
        @Suppress("DEPRECATION") intent.getParcelableExtra(Intent.EXTRA_STREAM)
    }
    if (imageUri == null) {
        Toast.makeText(this, "No image found", Toast.LENGTH_SHORT).show()
        finish()
        return
    }

    // Check size (use OpenableColumns.SIZE for accurate size, not InputStream.available())
    val size = contentResolver.query(imageUri, arrayOf(android.provider.OpenableColumns.SIZE), null, null, null)?.use { cursor ->
        if (cursor.moveToFirst()) cursor.getLong(0) else 0L
    } ?: 0L
    if (size > 10 * 1024 * 1024) {
        Toast.makeText(this, "Image too large (max 10 MB)", Toast.LENGTH_LONG).show()
        finish()
        return
    }

    // Copy to cache
    val cacheFile = File(cacheDir, "cliprelay_share_${System.currentTimeMillis()}.tmp")
    contentResolver.openInputStream(imageUri)?.use { input ->
        cacheFile.outputStream().use { output -> input.copyTo(output) }
    }

    // Send to service
    val serviceIntent = Intent(this, ClipRelayService::class.java).apply {
        action = ClipRelayService.ACTION_PUSH_IMAGE
        putExtra("imagePath", cacheFile.absolutePath)
        putExtra("mimeType", intent.type ?: "image/png")
    }
    startService(serviceIntent)

    Toast.makeText(this, "Sending image...", Toast.LENGTH_SHORT).show()
    finish()
}
```

- [ ] **Step 3: Handle ACTION_PUSH_IMAGE in ClipRelayService**

In `ClipRelayService.onStartCommand()`, add:

```kotlin
ACTION_PUSH_IMAGE -> {
    val path = intent.getStringExtra("imagePath") ?: return START_NOT_STICKY
    val mimeType = intent.getStringExtra("mimeType") ?: "image/png"
    val file = File(path)
    if (!file.exists()) return START_NOT_STICKY

    val session = activeSession
    if (session == null || !pairingStore.isRichMediaEnabled()) {
        // Show error via broadcast or toast
        handler.post {
            Toast.makeText(this, "Image sync is not available. Make sure ClipRelay is connected and image sync is enabled.", Toast.LENGTH_LONG).show()
        }
        return START_NOT_STICKY
    }

    executor.execute {
        try {
            val imageData = file.readBytes()
            session.sendImage(imageData, mimeType)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to send image", e)
            handler.post {
                Toast.makeText(this, "Could not transfer image. Make sure both devices are on the same Wi-Fi network.", Toast.LENGTH_LONG).show()
            }
        } finally {
            file.delete()
        }
    }
}
```

- [ ] **Step 4: Build and test**

Run: `cd android && ./gradlew assembleDebug 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add android/app/src/main/java/org/cliprelay/ui/ShareReceiverActivity.kt android/app/src/main/java/org/cliprelay/service/ClipRelayService.kt android/app/src/main/AndroidManifest.xml
git commit -m "feat: add image sharing via Android share sheet"
```

---

## Chunk 6: Cross-Platform Testing & Polish

### Task 29: Add automated tests for edge cases

**Files:**
- Test: `android/app/src/test/java/org/cliprelay/protocol/SessionTest.kt`
- Test: `macos/ClipRelayMac/Tests/SessionTests.swift`

- [ ] **Step 1: Test receiver rejects oversized images**

```kotlin
@Test
fun `handleInboundImageOffer rejects image over 10MB`() {
    // Send OFFER with size = 11_000_000
    // Verify REJECT with reason "size_exceeded" is sent back
}
```

- [ ] **Step 2: Test echo loop prevention**

```kotlin
@Test
fun `image with same hash as last received is not sent`() {
    // Simulate receiving an image with hash "abc123"
    // Set lastReceivedImageHash = "abc123"
    // Attempt to send clipboard with same hash
    // Verify no OFFER is sent (hasHash returns true)
}
```

- [ ] **Step 3: Test concurrent transfer cancellation**

```kotlin
@Test
fun `new image OFFER cancels in-flight transfer`() {
    // Start receiving image A (start TCP server)
    // Before TCP completes, send new OFFER for image B
    // Verify first TCP server is cancelled
    // Verify new TCP server starts for image B
}
```

- [ ] **Step 4: Test TIFF-to-PNG conversion on macOS**

```swift
func testTiffConvertedToPngBeforeSending() {
    // Write TIFF data to pasteboard
    // Trigger poll()
    // Verify callback receives PNG data with contentType "image/png"
}
```

- [ ] **Step 5: Run all tests on both platforms**

Run: `cd android && ./gradlew testDebugUnitTest 2>&1 | tail -20`
Run: `cd macos && xcodebuild test -scheme ClipRelayMac 2>&1 | tail -20`
Expected: ALL PASS

- [ ] **Step 6: Commit**

```bash
git add android/app/src/test/ macos/ClipRelayMac/Tests/
git commit -m "test: add edge case tests for echo loop, size limits, cancellation"
```

---

### Task 30: Add cross-platform session test fixtures for image transfer

**Files:**
- Modify: `android/app/src/test/java/org/cliprelay/protocol/SessionTest.kt`
- Modify: `macos/ClipRelayMac/Tests/SessionTests.swift`

- [ ] **Step 1: Create test fixture data**

Create shared test vectors: a small test PNG (e.g. 1x1 pixel), its SHA-256 hash, its encrypted form with a known session key. Ensure both platforms produce identical results.

- [ ] **Step 2: Write Android test**

```kotlin
@Test
fun `image OFFER round-trip with known test vector`() {
    // Use the shared test PNG and session key
    // Verify OFFER JSON matches expected format
    // Verify encryption produces expected ciphertext
    // Verify decryption and hash verification work
}
```

- [ ] **Step 3: Write macOS test**

```swift
func testImageOfferRoundTripWithKnownTestVector() {
    // Same test vector as Android
    // Verify cross-platform compatibility
}
```

- [ ] **Step 4: Run both test suites**

Run: `cd android && ./gradlew testDebugUnitTest 2>&1 | tail -20`
Run: `cd macos && xcodebuild test -scheme ClipRelayMac 2>&1 | tail -20`
Expected: ALL PASS

- [ ] **Step 5: Commit**

```bash
git add android/app/src/test/ macos/ClipRelayMac/Tests/
git commit -m "test: add cross-platform image transfer test fixtures"
```

---

### Task 31: Run full build and test suite

**Files:** None (verification only)

- [ ] **Step 1: Run full build**

Run: `scripts/build-all.sh`
Expected: Both platforms build successfully.

- [ ] **Step 2: Run full test suite**

Run: `scripts/test-all.sh`
Expected: ALL PASS

- [ ] **Step 3: If device connected, run hardware smoke tests**

Run: `adb get-state 2>/dev/null` — if "device", run `scripts/hardware-smoke-test.sh`

- [ ] **Step 4: Final commit if any fixes were needed**

---

### Task 32: End-to-end manual testing

- [ ] **Step 1: Test Mac → Android image transfer**
  - Copy an image on Mac
  - Verify it appears on Android clipboard (device must be unlocked)

- [ ] **Step 2: Test Android → Mac image transfer**
  - Share an image from Android gallery via ClipRelay share sheet
  - Verify it appears on Mac pasteboard

- [ ] **Step 3: Test rejection when device locked**
  - Lock Android device
  - Copy image on Mac
  - Verify no crash, silent drop

- [ ] **Step 4: Test "not on same network" error**
  - Disable Wi-Fi on one device
  - Try image share from Android
  - Verify error message appears

- [ ] **Step 5: Test feature flag toggle**
  - Disable "Image sync" on one device
  - Verify images are not transferred
  - Re-enable and verify transfers resume

- [ ] **Step 6: Test echo loop prevention**
  - Send image Mac → Android
  - Verify it does NOT bounce back to Mac

- [ ] **Step 7: Test concurrent transfer cancellation**
  - Copy image A on Mac
  - Immediately copy image B
  - Verify only image B arrives on Android

- [ ] **Step 8: Take screenshots of Android UI**

Run: `adb exec-out screencap -p > /tmp/cliprelay-screenshot.png`
Verify settings toggle and share sheet look correct.
