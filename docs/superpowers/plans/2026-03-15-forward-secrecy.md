# Forward Secrecy & Handshake Authentication — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add per-session ephemeral X25519 key exchange and HMAC authentication to the HELLO/WELCOME handshake, providing forward secrecy and mutual authentication.

**Architecture:** Embed ephemeral public keys and HMAC proofs in the existing HELLO/WELCOME JSON payloads (protocol v2). Session derives its own session key from the long-term shared secret + ephemeral ECDH result. Encryption/decryption moves inside Session, simplifying the service layer.

**Tech Stack:** CryptoKit (macOS), JCA X25519/HMAC (Android), AES-256-GCM, HKDF-SHA256

**Spec:** `docs/superpowers/specs/2026-03-15-forward-secrecy-design.md`

---

## Chunk 1: Cross-platform crypto fixtures and E2ECrypto additions

### Task 1: Create v2 crypto fixture

**Files:**
- Create: `test-fixtures/protocol/l2cap/v2_session_fixture.json`

The fixture uses the same RFC 7748 §6.1 key pairs from `ecdh_fixture.json` as the ephemeral keys, plus a known shared secret, to define expected values for auth_key, HMAC, raw ECDH result, and session key.

- [ ] **Step 1: Compute expected fixture values**

Use the existing ECDH fixture's key pairs. Pick a shared secret (use the existing `root_secret` from `ecdh_fixture.json` as our long-term shared secret for testing: `b4e4716bc736cde97aa0b585beddab79e190a2531e21bdd410914aeec7a2a4e1`).

Write a small script or use the Android test runner to compute:
- `auth_key = HKDF(ikm=shared_secret, salt=zeros(32), info="cliprelay-auth-v2", length=32)`
- `auth_mac = HMAC-SHA256(key=auth_key, msg=mac_ephemeral_public_bytes)` (the Mac/initiator's pubkey)
- `auth_android = HMAC-SHA256(key=auth_key, msg=android_ephemeral_public_bytes)` (the Android/responder's pubkey)
- `raw_ecdh = raw X25519(mac_private, android_public)` — this is `4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742` (from the existing fixture)
- `session_key = HKDF(ikm=shared_secret || raw_ecdh, salt=zeros(32), info="cliprelay-session-v2", length=32)`

Run: `cd android && ./gradlew testDebugUnitTest --tests "org.cliprelay.crypto.E2ECryptoTest" -q` (after writing the computation helper in step 3 of Task 2)

- [ ] **Step 2: Write the fixture file**

```json
{
  "fixture_id": "v2-session-handshake",
  "description": "Golden fixture for v2 session handshake: ephemeral ECDH + HMAC auth + session key derivation",
  "notes": [
    "Uses RFC 7748 §6.1 key pairs as ephemeral keys (same as ecdh_fixture.json)",
    "shared_secret is the root_secret from ecdh_fixture.json (arbitrary choice for testing)",
    "auth_key = HKDF(ikm=shared_secret, salt=zeros, info='cliprelay-auth-v2', length=32)",
    "auth_mac = HMAC-SHA256(key=auth_key, msg=mac_ephemeral_public)",
    "auth_android = HMAC-SHA256(key=auth_key, msg=android_ephemeral_public)",
    "raw_ecdh = raw X25519 output (no HKDF wrapping, unlike ecdhSharedSecret())",
    "session_key = HKDF(ikm=shared_secret || raw_ecdh, salt=zeros, info='cliprelay-session-v2', length=32)"
  ],
  "shared_secret": "b4e4716bc736cde97aa0b585beddab79e190a2531e21bdd410914aeec7a2a4e1",
  "ephemeral_keys": {
    "mac": {
      "private_hex": "77076d0c9b7f0c04e35c1d5b79d5e76a8f3c2b0a1d4e6f8a9b0c1d2e3f4a5b6c",
      "public_hex": "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a"
    },
    "android": {
      "private_hex": "5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb",
      "public_hex": "de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f"
    }
  },
  "derivation": {
    "auth_key": "<computed in step 1>",
    "auth_mac": "<computed in step 1>",
    "auth_android": "<computed in step 1>",
    "raw_ecdh": "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742",
    "session_key": "<computed in step 1>"
  }
}
```

Fill in `<computed in step 1>` values after running the computation.

- [ ] **Step 3: Commit**

```bash
git add test-fixtures/protocol/l2cap/v2_session_fixture.json
git commit -m "test: add v2 session handshake golden fixture"
```

---

### Task 2: Add v2 crypto functions to Android E2ECrypto

**Files:**
- Modify: `android/app/src/main/java/org/cliprelay/crypto/E2ECrypto.kt`
- Modify: `android/app/src/test/java/org/cliprelay/crypto/E2ECryptoTest.kt`

- [ ] **Step 1: Write failing tests for new crypto functions**

Add these tests to `E2ECryptoTest.kt`:

```kotlin
@Test
fun deriveAuthKeyMatchesFixture() {
    val fixture = loadV2Fixture()
    val secretBytes = hexToBytes(fixture.sharedSecret)
    val authKey = E2ECrypto.deriveAuthKey(secretBytes)
    assertEquals(fixture.derivation.authKey, bytesToHex(authKey.encoded))
}

@Test
fun hmacAuthMatchesFixture() {
    val fixture = loadV2Fixture()
    val authKey = E2ECrypto.deriveAuthKey(hexToBytes(fixture.sharedSecret))
    val macPub = hexToBytes(fixture.ephemeralKeys.mac.publicHex)
    val hmac = E2ECrypto.hmacAuth(macPub, authKey)
    assertEquals(fixture.derivation.authMac, bytesToHex(hmac))
}

@Test
fun verifyAuthAcceptsCorrectHmac() {
    val fixture = loadV2Fixture()
    val authKey = E2ECrypto.deriveAuthKey(hexToBytes(fixture.sharedSecret))
    val macPub = hexToBytes(fixture.ephemeralKeys.mac.publicHex)
    val expected = hexToBytes(fixture.derivation.authMac)
    assertTrue(E2ECrypto.verifyAuth(macPub, authKey, expected))
}

@Test
fun verifyAuthRejectsWrongHmac() {
    val fixture = loadV2Fixture()
    val authKey = E2ECrypto.deriveAuthKey(hexToBytes(fixture.sharedSecret))
    val macPub = hexToBytes(fixture.ephemeralKeys.mac.publicHex)
    val wrong = ByteArray(32) { 0xFF.toByte() }
    assertFalse(E2ECrypto.verifyAuth(macPub, authKey, wrong))
}

@Test
fun rawX25519MatchesFixture() {
    // rawX25519 should return the raw ECDH output without HKDF wrapping
    val fixture = loadV2Fixture()
    val macPriv = hexToBytes(fixture.ephemeralKeys.mac.privateHex)
    val androidPub = hexToBytes(fixture.ephemeralKeys.android.publicHex)
    val kpg = java.security.KeyPairGenerator.getInstance("X25519")
    // We need to use the known private key — construct from raw bytes
    // For test purposes, use ecdhSharedSecret's internal path but without HKDF
    val result = E2ECrypto.rawX25519(macPriv, androidPub)
    assertEquals(fixture.derivation.rawEcdh, bytesToHex(result))
}

@Test
fun deriveSessionKeyMatchesFixture() {
    val fixture = loadV2Fixture()
    val secretBytes = hexToBytes(fixture.sharedSecret)
    val ecdhResult = hexToBytes(fixture.derivation.rawEcdh)
    val sessionKey = E2ECrypto.deriveSessionKey(secretBytes, ecdhResult)
    assertEquals(fixture.derivation.sessionKey, bytesToHex(sessionKey.encoded))
}
```

Also add a fixture loader for the v2 fixture (following the pattern of the existing `loadEcdhFixture()`).

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd android && ./gradlew testDebugUnitTest --tests "org.cliprelay.crypto.E2ECryptoTest" -q`
Expected: FAIL — functions don't exist yet

- [ ] **Step 3: Implement the new functions in E2ECrypto.kt**

Add to `E2ECrypto.kt`:

```kotlin
fun deriveAuthKey(secretBytes: ByteArray): SecretKey {
    val keyBytes = hkdf(secretBytes, "cliprelay-auth-v2", 32)
    return SecretKeySpec(keyBytes, "HmacSHA256")
}

fun deriveSessionKey(secretBytes: ByteArray, ecdhResult: ByteArray): SecretKey {
    val ikm = secretBytes + ecdhResult
    val keyBytes = hkdf(ikm, "cliprelay-session-v2", 32)
    return SecretKeySpec(keyBytes, "AES")
}

fun hmacAuth(publicKeyBytes: ByteArray, authKey: SecretKey): ByteArray {
    val mac = Mac.getInstance("HmacSHA256")
    mac.init(authKey)
    return mac.doFinal(publicKeyBytes)
}

fun verifyAuth(publicKeyBytes: ByteArray, authKey: SecretKey, expected: ByteArray): Boolean {
    val computed = hmacAuth(publicKeyBytes, authKey)
    return java.security.MessageDigest.isEqual(computed, expected)
}

fun rawX25519(ownPrivateKeyRaw: ByteArray, remotePublicKeyRaw: ByteArray): ByteArray {
    val remotePub = x25519PublicKeyFromRaw(remotePublicKeyRaw)
    // Construct private key from raw bytes
    // X25519 private key X.509 encoding: header + raw bytes
    val x509Header = byteArrayOf(
        0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x6e,
        0x04, 0x22, 0x04, 0x20
    )
    val encoded = x509Header + ownPrivateKeyRaw
    val privKey = KeyFactory.getInstance("X25519")
        .generatePrivate(java.security.spec.PKCS8EncodedKeySpec(encoded))
    val ka = JKeyAgreement.getInstance("X25519")
    ka.init(privKey)
    ka.doPhase(remotePub, true)
    return ka.generateSecret()  // raw, no HKDF
}
```

Note: The `rawX25519` that takes raw private key bytes is for testing with known keys. The Session will use the JCA `PrivateKey` object directly. Add an overload:

```kotlin
fun rawX25519(ownPrivateKey: PrivateKey, remotePublicKeyRaw: ByteArray): ByteArray {
    val remotePub = x25519PublicKeyFromRaw(remotePublicKeyRaw)
    val ka = JKeyAgreement.getInstance("X25519")
    ka.init(ownPrivateKey)
    ka.doPhase(remotePub, true)
    return ka.generateSecret()
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd android && ./gradlew testDebugUnitTest --tests "org.cliprelay.crypto.E2ECryptoTest" -q`
Expected: ALL PASS

- [ ] **Step 5: Use passing tests to compute fixture values**

The tests now compute the real values. Read them from test output or add a print statement to populate the fixture JSON with correct hex values.

- [ ] **Step 6: Update the fixture file with computed values and re-run tests**

Run: `cd android && ./gradlew testDebugUnitTest --tests "org.cliprelay.crypto.E2ECryptoTest" -q`
Expected: ALL PASS

- [ ] **Step 7: Commit**

```bash
git add android/app/src/main/java/org/cliprelay/crypto/E2ECrypto.kt \
        android/app/src/test/java/org/cliprelay/crypto/E2ECryptoTest.kt \
        test-fixtures/protocol/l2cap/v2_session_fixture.json
git commit -m "feat(android): add v2 session crypto — auth key, HMAC, raw X25519, session key"
```

---

### Task 3: Add v2 crypto functions to macOS E2ECrypto

**Files:**
- Modify: `macos/ClipRelayMac/Sources/Crypto/E2ECrypto.swift`
- Modify: `macos/ClipRelayMac/Tests/ClipRelayTests/E2ECryptoKeyDerivationTests.swift`

- [ ] **Step 1: Write failing tests matching the same fixture**

Add to `E2ECryptoKeyDerivationTests.swift`:

```swift
func testDeriveAuthKeyMatchesFixture() throws {
    let fixture = try V2SessionFixtureLoader.load()
    let secretBytes = hexToData(fixture.sharedSecret)
    let authKey = E2ECrypto.deriveAuthKey(secretBytes: secretBytes)
    XCTAssertNotNil(authKey)
    let authKeyHex = authKey!.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
    XCTAssertEqual(authKeyHex, fixture.derivation.authKey)
}

func testHmacAuthMatchesFixture() throws {
    let fixture = try V2SessionFixtureLoader.load()
    let secretBytes = hexToData(fixture.sharedSecret)
    let authKey = E2ECrypto.deriveAuthKey(secretBytes: secretBytes)!
    let macPub = hexToData(fixture.ephemeralKeys.mac.publicHex)
    let hmac = E2ECrypto.hmacAuth(publicKeyBytes: macPub, authKey: authKey)
    XCTAssertEqual(hmac.map { String(format: "%02x", $0) }.joined(), fixture.derivation.authMac)
}

func testVerifyAuthAcceptsCorrectHmac() throws {
    let fixture = try V2SessionFixtureLoader.load()
    let secretBytes = hexToData(fixture.sharedSecret)
    let authKey = E2ECrypto.deriveAuthKey(secretBytes: secretBytes)!
    let macPub = hexToData(fixture.ephemeralKeys.mac.publicHex)
    let expected = hexToData(fixture.derivation.authMac)
    XCTAssertTrue(E2ECrypto.verifyAuth(publicKeyBytes: macPub, authKey: authKey, expected: expected))
}

func testVerifyAuthRejectsWrongHmac() throws {
    let fixture = try V2SessionFixtureLoader.load()
    let secretBytes = hexToData(fixture.sharedSecret)
    let authKey = E2ECrypto.deriveAuthKey(secretBytes: secretBytes)!
    let macPub = hexToData(fixture.ephemeralKeys.mac.publicHex)
    let wrong = Data(repeating: 0xFF, count: 32)
    XCTAssertFalse(E2ECrypto.verifyAuth(publicKeyBytes: macPub, authKey: authKey, expected: wrong))
}

func testDeriveSessionKeyMatchesFixture() throws {
    let fixture = try V2SessionFixtureLoader.load()
    let secretBytes = hexToData(fixture.sharedSecret)
    let ecdhResult = hexToData(fixture.derivation.rawEcdh)
    let sessionKey = E2ECrypto.deriveSessionKey(secretBytes: secretBytes, ecdhResult: ecdhResult)
    XCTAssertNotNil(sessionKey)
    let sessionKeyHex = sessionKey!.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
    XCTAssertEqual(sessionKeyHex, fixture.derivation.sessionKey)
}
```

Add a `V2SessionFixtureLoader` (following the same pattern as the existing `L2capFixtureLoader`).

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd macos/ClipRelayMac && swift test --filter E2ECryptoKeyDerivationTests 2>&1 | tail -20`
Expected: FAIL — functions don't exist yet

- [ ] **Step 3: Implement the new functions in E2ECrypto.swift**

Add to `E2ECrypto.swift`:

```swift
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
    return shared.withUnsafeBytes { Data($0) }
}
```

Note: CryptoKit's `SharedSecret` can be accessed via `withUnsafeBytes` to get the raw bytes. This is different from `ecdhSharedSecret()` which runs the result through HKDF. This uses an undocumented but stable CryptoKit API surface — add a test that validates the raw output against the known RFC 7748 vector (`4a5d9d...1742`) to detect any future breakage.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd macos/ClipRelayMac && swift test --filter E2ECryptoKeyDerivationTests 2>&1 | tail -20`
Expected: ALL PASS

- [ ] **Step 5: Verify cross-platform fixture match**

Both Android and macOS tests should produce identical values for the same fixture inputs. If the macOS values differ from what was computed by Android in Task 2, investigate and fix until they match.

- [ ] **Step 6: Commit**

```bash
git add macos/ClipRelayMac/Sources/Crypto/E2ECrypto.swift \
        macos/ClipRelayMac/Tests/ClipRelayTests/E2ECryptoKeyDerivationTests.swift
git commit -m "feat(macos): add v2 session crypto — auth key, HMAC, raw X25519, session key"
```

---

### Task 4: Update AAD constant on both platforms

**Files:**
- Modify: `android/app/src/main/java/org/cliprelay/crypto/E2ECrypto.kt:21`
- Modify: `macos/ClipRelayMac/Sources/Crypto/E2ECrypto.swift:7`

- [ ] **Step 1: Update Android AAD**

In `E2ECrypto.kt`, change:
```kotlin
private val AAD = "cliprelay-v1".toByteArray(Charsets.UTF_8)
```
to:
```kotlin
private val AAD = "cliprelay-v2".toByteArray(Charsets.UTF_8)
```

- [ ] **Step 2: Update macOS AAD**

In `E2ECrypto.swift`, change:
```swift
private static let aad = Data("cliprelay-v1".utf8)
```
to:
```swift
private static let aad = Data("cliprelay-v2".utf8)
```

- [ ] **Step 3: Run existing crypto tests on both platforms**

Run: `cd android && ./gradlew testDebugUnitTest --tests "org.cliprelay.crypto.E2ECryptoTest" -q`
Run: `cd macos/ClipRelayMac && swift test --filter E2ECryptoTests 2>&1 | tail -20`
Expected: ALL PASS (existing seal/open roundtrip tests should still pass since they encrypt and decrypt with the same AAD)

- [ ] **Step 4: Commit**

```bash
git add android/app/src/main/java/org/cliprelay/crypto/E2ECrypto.kt \
        macos/ClipRelayMac/Sources/Crypto/E2ECrypto.swift
git commit -m "feat: bump AES-GCM AAD from cliprelay-v1 to cliprelay-v2"
```

---

## Chunk 2: Session v2 handshake (both platforms)

### Task 5: Update Android Session for v2 handshake

**Files:**
- Modify: `android/app/src/main/java/org/cliprelay/protocol/Session.kt`
- Modify: `android/app/src/test/java/org/cliprelay/protocol/SessionTest.kt`

- [ ] **Step 1: Write failing tests for v2 handshake**

Add to `SessionTest.kt`:

```kotlin
@Test
fun v2HandshakeSucceeds() {
    val sharedSecretHex = "b4e4716bc736cde97aa0b585beddab79e190a2531e21bdd410914aeec7a2a4e1"
    val env = createPairedSessions(sharedSecretHex)
    val ready = CountDownLatch(2)
    env.macCallback.onReady = { ready.countDown() }
    env.androidCallback.onReady = { ready.countDown() }
    startBoth(env)
    assertTrue(ready.await(5, TimeUnit.SECONDS))
    cleanup(env)
}

@Test
fun v2HandshakeRejectsVersion1() {
    // Send a v1 HELLO to a v2 session — should get versionMismatch
    val sharedSecretHex = "b4e4716bc736cde97aa0b585beddab79e190a2531e21bdd410914aeec7a2a4e1"
    val env = createManualStreams()
    val errorLatch = CountDownLatch(1)
    var caughtError: Exception? = null
    val callback = TestCallback()
    callback.onError = { e ->
        caughtError = e
        errorLatch.countDown()
    }
    val session = Session(env.sessionInput, env.sessionOutput, isInitiator = false, callback,
        sharedSecretHex = sharedSecretHex)
    Thread { session.performHandshake() }.apply { isDaemon = true; start() }

    // Send v1 HELLO
    val v1Hello = Message(MessageType.HELLO, """{"version":1}""".toByteArray())
    MessageCodec.write(env.writeToSession, v1Hello)

    assertTrue(errorLatch.await(5, TimeUnit.SECONDS))
    assertTrue(caughtError is ProtocolException)
    assertTrue(caughtError!!.message!!.contains("version", ignoreCase = true))
    session.close()
}

@Test
fun v2HandshakeRejectsBadAuth() {
    val sharedSecretHex = "b4e4716bc736cde97aa0b585beddab79e190a2531e21bdd410914aeec7a2a4e1"
    val env = createManualStreams()
    val errorLatch = CountDownLatch(1)
    var caughtError: Exception? = null
    val callback = TestCallback()
    callback.onError = { e ->
        caughtError = e
        errorLatch.countDown()
    }
    val session = Session(env.sessionInput, env.sessionOutput, isInitiator = false, callback,
        sharedSecretHex = sharedSecretHex)
    Thread { session.performHandshake() }.apply { isDaemon = true; start() }

    // Send v2 HELLO with wrong auth
    val fakeEk = "aa".repeat(32)
    val fakeAuth = "bb".repeat(32)
    val payload = """{"version":2,"ek":"$fakeEk","auth":"$fakeAuth"}""".toByteArray()
    MessageCodec.write(env.writeToSession, Message(MessageType.HELLO, payload))

    assertTrue(errorLatch.await(5, TimeUnit.SECONDS))
    assertTrue(caughtError!!.message!!.contains("Authentication failed"))
    session.close()
}

@Test
fun v2EndToEndClipboardTransfer() {
    val sharedSecretHex = "b4e4716bc736cde97aa0b585beddab79e190a2531e21bdd410914aeec7a2a4e1"
    val env = createPairedSessions(sharedSecretHex)
    val ready = CountDownLatch(2)
    val received = CountDownLatch(1)
    var receivedText: String? = null

    env.macCallback.onReady = { ready.countDown() }
    env.androidCallback.onReady = { ready.countDown() }
    env.androidCallback.onClipboardReceived = { plaintext, _ ->
        receivedText = String(plaintext)
        received.countDown()
    }

    startBoth(env)
    assertTrue(ready.await(5, TimeUnit.SECONDS))

    // Mac sends plaintext clipboard
    env.macSession.sendClipboard("Hello from Mac!".toByteArray())

    assertTrue(received.await(5, TimeUnit.SECONDS))
    assertEquals("Hello from Mac!", receivedText)
    cleanup(env)
}
```

Also add a test for missing/malformed `ek`:

```kotlin
@Test
fun v2HandshakeRejectsMissingEk() {
    val sharedSecretHex = "b4e4716bc736cde97aa0b585beddab79e190a2531e21bdd410914aeec7a2a4e1"
    val env = createManualStreams()
    val errorLatch = CountDownLatch(1)
    var caughtError: Exception? = null
    val callback = TestCallback()
    callback.onError = { e ->
        caughtError = e
        errorLatch.countDown()
    }
    val session = Session(env.sessionInput, env.sessionOutput, isInitiator = false, callback,
        sharedSecretHex = sharedSecretHex)
    Thread { session.performHandshake() }.apply { isDaemon = true; start() }

    // Send v2 HELLO without ek field
    val payload = """{"version":2,"auth":"${"aa".repeat(32)}"}""".toByteArray()
    MessageCodec.write(env.writeToSession, Message(MessageType.HELLO, payload))

    assertTrue(errorLatch.await(5, TimeUnit.SECONDS))
    assertTrue(caughtError!!.message!!.contains("ephemeral key", ignoreCase = true))
    session.close()
}
```

Update `createPairedSessions` to accept `sharedSecretHex` parameter and pass it to Session constructor. **Important:** All existing tests that use `createPairedSessions()` must also be updated to pass a shared secret, since the v2 handshake requires it. The `sharedSecretHex` parameter defaults to `null`, but when `null`, the session should skip ephemeral key exchange and fall back to... actually no — this is a clean break. All existing paired-session tests must pass a valid shared secret. Update them all to use the test secret `"b4e4716bc736cde97aa0b585beddab79e190a2531e21bdd410914aeec7a2a4e1"`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd android && ./gradlew testDebugUnitTest --tests "org.cliprelay.protocol.SessionTest" -q`
Expected: FAIL — Session constructor doesn't accept sharedSecretHex yet

- [ ] **Step 3: Implement v2 handshake in Android Session**

Modify `Session.kt`:

1. Add `sharedSecretHex: String? = null` parameter to constructor
2. Derive `authKey` from shared secret in init block (if provided)
3. Store `sessionKey` as a `var` — set after handshake completes
4. Update `initiatorHandshake()`: generate ephemeral key, embed `ek`+`auth` in HELLO, validate WELCOME's `ek`+`auth`, compute session key
5. Update `responderHandshake()`: validate HELLO's `ek`+`auth`, generate ephemeral key, embed in WELCOME, compute session key
6. Update `helloPayload()`: include `ek`, `auth`, version 2
7. Update `validateVersion()`: extract and validate `ek` and `auth`, report version mismatch distinctly
8. Update `doSendClipboard()`: encrypt plaintext internally, hash plaintext before encryption
9. Update `handleInboundOffer()`: decrypt payload internally, deliver plaintext via callback
10. Update `SessionCallback.onClipboardReceived`: change parameter from encrypted blob to plaintext

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd android && ./gradlew testDebugUnitTest --tests "org.cliprelay.protocol.SessionTest" -q`
Expected: ALL PASS

- [ ] **Step 5: Commit**

```bash
git add android/app/src/main/java/org/cliprelay/protocol/Session.kt \
        android/app/src/test/java/org/cliprelay/protocol/SessionTest.kt
git commit -m "feat(android): implement v2 handshake with ephemeral ECDH and HMAC auth"
```

---

### Task 6: Update macOS Session for v2 handshake

**Files:**
- Modify: `macos/ClipRelayMac/Sources/Protocol/Session.swift`
- Modify: `macos/ClipRelayMac/Tests/ClipRelayTests/SessionTests.swift`

- [ ] **Step 1: Write failing tests for v2 handshake**

Add to `SessionTests.swift` (mirror the Android tests from Task 5):

```swift
func testV2HandshakeSucceeds() {
    let sharedSecretHex = "b4e4716bc736cde97aa0b585beddab79e190a2531e21bdd410914aeec7a2a4e1"
    let env = createPairedSessions(sharedSecretHex: sharedSecretHex)
    let readyExpectation = expectation(description: "Both ready")
    readyExpectation.expectedFulfillmentCount = 2
    env.macDelegate.onReady = { _ in readyExpectation.fulfill() }
    env.androidDelegate.onReady = { _ in readyExpectation.fulfill() }
    startBothSessions(env)
    wait(for: [readyExpectation], timeout: 5.0)
    cleanup(env)
}

func testV2HandshakeRejectsVersion1() {
    let sharedSecretHex = "b4e4716bc736cde97aa0b585beddab79e190a2531e21bdd410914aeec7a2a4e1"
    let env = createManualStreams()
    let errorExpectation = expectation(description: "Version mismatch")
    let delegate = TestSessionDelegate()
    delegate.onError = { _, error in
        if case SessionError.versionMismatch = error as? SessionError ?? SessionError.sessionClosed {
            errorExpectation.fulfill()
        }
    }
    let session = Session(inputStream: env.sessionInput, outputStream: env.sessionOutput,
                          isInitiator: true, delegate: delegate,
                          sharedSecretHex: sharedSecretHex)
    session.handshakeTimeoutSeconds = 3.0
    DispatchQueue.global().async { session.performHandshake() }
    // Read the HELLO, send back a v1 WELCOME
    _ = try? MessageCodec.decode(from: env.readFromSession)
    let v1Welcome = Message(type: .welcome, payload: Data(#"{"version":1}"#.utf8))
    writeMessage(v1Welcome, to: env.writeToSession)
    wait(for: [errorExpectation], timeout: 5.0)
    session.close()
    cleanupManual(env)
}

func testV2EndToEndClipboardTransfer() {
    let sharedSecretHex = "b4e4716bc736cde97aa0b585beddab79e190a2531e21bdd410914aeec7a2a4e1"
    let env = createPairedSessions(sharedSecretHex: sharedSecretHex)
    let readyExpectation = expectation(description: "Both ready")
    readyExpectation.expectedFulfillmentCount = 2
    let receivedExpectation = expectation(description: "Received clipboard")
    var receivedData: Data?

    env.macDelegate.onReady = { _ in readyExpectation.fulfill() }
    env.androidDelegate.onReady = { _ in readyExpectation.fulfill() }
    env.androidDelegate.onReceived = { _, blob, _ in
        receivedData = blob
        receivedExpectation.fulfill()
    }

    startBothSessions(env)
    wait(for: [readyExpectation], timeout: 5.0)

    // Mac sends plaintext
    env.macSession.sendClipboard(Data("Hello from Mac!".utf8))
    wait(for: [receivedExpectation], timeout: 5.0)
    XCTAssertEqual(String(data: receivedData!, encoding: .utf8), "Hello from Mac!")
    cleanup(env)
}
```

Update `createPairedSessions` to accept `sharedSecretHex` parameter. **Important:** Same as Android — all existing paired-session tests must be updated to pass the test shared secret since v2 requires it. Also add a test for missing `ek` (mirror the Android test from Task 5).

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd macos/ClipRelayMac && swift test --filter SessionTests 2>&1 | tail -20`
Expected: FAIL

- [ ] **Step 3: Implement v2 handshake in macOS Session**

Mirror the Android changes from Task 5 step 3, using CryptoKit APIs:

1. Add `sharedSecretHex: String? = nil` parameter to `init`
2. Derive `authKey` from shared secret
3. Store `sessionKey` — set after handshake
4. Update `initiatorHandshake()` / `responderHandshake()` with ephemeral key exchange
5. Update `helloPayload()` and `validateVersion()` for v2
6. Encrypt/decrypt internally in `doSendClipboard()` / `handleInboundOffer()`
7. Hash plaintext in `doSendClipboard()` (before encryption)
8. Update `SessionDelegate.session(_:didReceiveClipboard:hash:)` to deliver plaintext

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd macos/ClipRelayMac && swift test --filter SessionTests 2>&1 | tail -20`
Expected: ALL PASS

- [ ] **Step 5: Commit**

```bash
git add macos/ClipRelayMac/Sources/Protocol/Session.swift \
        macos/ClipRelayMac/Tests/ClipRelayTests/SessionTests.swift
git commit -m "feat(macos): implement v2 handshake with ephemeral ECDH and HMAC auth"
```

---

### Task 7: Update L2CAP fixture for v2 HELLO/WELCOME

**Files:**
- Modify: `test-fixtures/protocol/l2cap/l2cap_fixture.json`
- Modify: `macos/ClipRelayMac/Tests/ClipRelayTests/L2capFixtureCompatibilityTests.swift`
- Modify: `android/app/src/test/java/org/cliprelay/protocol/L2capFixtureCompatibilityTest.kt`

- [ ] **Step 1: Update HELLO and WELCOME entries in l2cap_fixture.json**

Change the payload to include `version:2` with dummy `ek` and `auth` fields (the fixture tests only verify codec encoding/decoding, not crypto correctness):

```json
{
    "name": "HELLO",
    "type_byte": "01",
    "payload_utf8": "{\"version\":2,\"ek\":\"8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a\",\"auth\":\"0000000000000000000000000000000000000000000000000000000000000000\"}",
    "payload_hex": "<compute from payload_utf8>",
    "encoded_hex": "<compute: 4-byte length header + 0x01 + payload>"
}
```

Compute the hex values by encoding the JSON payload UTF-8 bytes.

- [ ] **Step 2: Run fixture compatibility tests on both platforms**

Run: `cd android && ./gradlew testDebugUnitTest --tests "org.cliprelay.protocol.L2capFixtureCompatibilityTest" -q`
Run: `cd macos/ClipRelayMac && swift test --filter L2capFixtureCompatibilityTests 2>&1 | tail -20`
Expected: ALL PASS

- [ ] **Step 3: Commit**

```bash
git add test-fixtures/protocol/l2cap/l2cap_fixture.json
git commit -m "test: update L2CAP fixture HELLO/WELCOME for v2 payload format"
```

---

## Chunk 3: Service layer integration and version mismatch UX

### Task 8: Update Android ClipRelayService

**Files:**
- Modify: `android/app/src/main/java/org/cliprelay/service/ClipRelayService.kt`
- Modify: `android/app/src/main/java/org/cliprelay/ui/MainViewModel.kt`
- Modify: `android/app/src/main/java/org/cliprelay/ui/ClipRelayScreen.kt`

- [ ] **Step 1: Update Session construction to pass shared secret**

In `onClientConnected()`, pass `sharedSecretHex` to Session. Note: during pairing (`pairingInProgress == true`), pass `null` since no shared secret exists yet — the pairing handshake (KEY_EXCHANGE/KEY_CONFIRM) establishes it, and the subsequent HELLO/WELCOME v2 handshake will use it:

```kotlin
val secret = if (pairingInProgress) null else pairingStore.loadSharedSecret()
val session = Session(
    socket.inputStream, socket.outputStream,
    isInitiator = false,
    this,
    mode = mode,
    sharedSecretHex = secret
)
```

- [ ] **Step 2: Replace `encryptionKey` with `isPaired` check**

Replace **all** uses of `encryptionKey` with `isPaired` check. The `encryptionKey` field is referenced in multiple places beyond just `ensureBleComponentsState`:

- Add: `private val isPaired: Boolean get() = pairingStore.loadSharedSecret() != null`
- `ensureBleComponentsState()`: change `encryptionKey == null && !pairingInProgress` to `!isPaired && !pairingInProgress`
- `onCreate()`: change `encryptionKey != null` to `isPaired`
- `loadPairingState()`: remove `encryptionKey` assignment, keep device tag logic using the raw secret bytes
- `startBle()` log line (line ~248): change `encryptionKey` reference to `isPaired` in the log message
- `startBle()` device tag derivation (line ~277): change `encryptionKey?.let {` guard to `if (isPaired)` and load secret directly from pairing store
- `onStartCommand()` / `ACTION_RELOAD_PAIRING` handler (line ~171): change `encryptionKey == null` to `!isPaired`
- `onPairingComplete()`: remove `encryptionKey = E2ECrypto.deriveKey(sharedSecret)`
- `pushPlainTextToMac()`: remove `encryptionKey` null check (session handles crypto internally)
- `onClipboardReceived()`: remove `encryptionKey` null check and `E2ECrypto.open()` call

Remove the `encryptionKey` field entirely. Search for all occurrences to ensure none are missed — the compiler will catch any remaining references.

- [ ] **Step 3: Simplify clipboard path — remove external encryption**

In `pushPlainTextToMac()`:
- Remove `E2ECrypto.seal()` call
- Pass plaintext bytes directly to `session.sendClipboard(plaintext)`
- Remove the `encryptionKey` null check (session handles this internally)

In `onClipboardReceived()`:
- The callback now receives plaintext directly — remove `E2ECrypto.open()` call
- Remove `encryptionKey` null check

In `onPairingComplete()`:
- Remove `encryptionKey = E2ECrypto.deriveKey(sharedSecret)` — no longer needed

- [ ] **Step 4: Add version mismatch handling**

Add to companion object:
```kotlin
const val ACTION_VERSION_MISMATCH = "org.cliprelay.action.VERSION_MISMATCH"
```

In `onSessionError()`, detect version mismatch:
```kotlin
override fun onSessionError(error: Exception) {
    if (error is ProtocolException && error.message?.contains("version", ignoreCase = true) == true) {
        val intent = Intent(ACTION_VERSION_MISMATCH)
        intent.setPackage(packageName)
        sendBroadcast(intent)
    }
    // ... existing error handling
}
```

- [ ] **Step 5: Add version mismatch UI in MainViewModel/Screen**

Register for `ACTION_VERSION_MISMATCH` broadcast in `MainViewModel`. Show an AlertDialog in `ClipRelayScreen` with message: "Your Mac app needs to be updated to continue syncing. Download the latest version at cliprelay.org."

- [ ] **Step 6: Build and verify**

Run: `scripts/build-all.sh` (or `cd android && ./gradlew assembleDebug`)
Expected: Build succeeds

Run: `cd android && ./gradlew testDebugUnitTest -q`
Expected: ALL PASS

- [ ] **Step 7: Commit**

```bash
git add android/app/src/main/java/org/cliprelay/service/ClipRelayService.kt \
        android/app/src/main/java/org/cliprelay/ui/MainViewModel.kt \
        android/app/src/main/java/org/cliprelay/ui/ClipRelayScreen.kt
git commit -m "feat(android): integrate v2 session — remove external encryption, add version mismatch UX"
```

---

### Task 9: Update macOS AppDelegate

**Files:**
- Modify: `macos/ClipRelayMac/Sources/App/AppDelegate.swift`

- [ ] **Step 1: Update Session construction to pass shared secret**

In `connectionManager(_:didEstablishChannel:outputStream:for:)`:
```swift
let session = Session(inputStream: inputStream, outputStream: outputStream,
                      isInitiator: true, delegate: self,
                      sharedSecretHex: token)
```

In `connectionManager(_:didEstablishPairingChannel:outputStream:)`:
```swift
let session = Session(inputStream: inputStream, outputStream: outputStream,
                      isInitiator: true, delegate: self,
                      mode: .pairing(privateKey: privateKey),
                      sharedSecretHex: nil)  // no shared secret yet during pairing
```

- [ ] **Step 2: Simplify clipboard path**

In `onClipboardChange()`:
- Remove `pairingManager.encryptionKey(for:)` call
- Remove `E2ECrypto.seal()` call
- Send plaintext data directly: `session.sendClipboard(Data(text.utf8))`
- `pendingClipboardPayload` now stores plaintext `Data(text.utf8)` instead of encrypted blob

In `session(_:didReceiveClipboard:hash:)`:
- Remove `pairingManager.encryptionKey(for:)` call
- Remove `E2ECrypto.open()` call
- The `encryptedBlob` parameter is now plaintext — rename to `plaintext` and use directly

- [ ] **Step 3: Add version mismatch notification**

In `session(_:didFailWithError:)`:
```swift
if case SessionError.versionMismatch = error {
    DispatchQueue.main.async { [weak self] in
        self?.showBluetoothAlert(
            message: "App Update Required",
            info: "Your Android app needs to be updated to continue syncing. Update via Google Play."
        )
    }
    return  // don't reconnect for version mismatch
}
```

- [ ] **Step 4: Build and run tests**

Run: `cd macos/ClipRelayMac && swift build 2>&1 | tail -5`
Expected: Build succeeds

Run: `cd macos/ClipRelayMac && swift test 2>&1 | tail -20`
Expected: ALL PASS

- [ ] **Step 5: Commit**

```bash
git add macos/ClipRelayMac/Sources/App/AppDelegate.swift
git commit -m "feat(macos): integrate v2 session — remove external encryption, add version mismatch UX"
```

---

### Task 10: Full build and test verification

**Files:** None (verification only)

- [ ] **Step 1: Run full build**

Run: `scripts/build-all.sh`
Expected: Both platforms build successfully

- [ ] **Step 2: Run full test suite**

Run: `scripts/test-all.sh`
Expected: ALL PASS on both platforms

- [ ] **Step 3: Run hardware smoke tests (if device connected)**

Run: `adb get-state 2>/dev/null` — if "device", run `scripts/hardware-smoke-test.sh`

- [ ] **Step 4: Restart both apps for manual verification**

Per AGENTS.md:
- Mac: `pkill -f ClipRelay; open dist/ClipRelay.app`
- Android: `adb install -r dist/cliprelay-debug.apk && adb shell am force-stop org.cliprelay && adb shell am start -n org.cliprelay/.ui.MainActivity`

- [ ] **Step 5: Commit any remaining fixes**

If any issues were found and fixed during verification, commit them.
