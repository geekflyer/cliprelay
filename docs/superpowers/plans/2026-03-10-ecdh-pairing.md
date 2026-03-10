# ECDH Pairing Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace static token-in-QR pairing with X25519 ECDH key exchange so photographing the QR code cannot compromise the encryption key.

**Architecture:** The QR code carries the Mac's ephemeral X25519 public key instead of a shared secret. After the Android scans, both devices perform ECDH over BLE to derive the encryption key. The shared secret replaces the token as root input to the existing HKDF derivation — all downstream encryption is unchanged.

**Tech Stack:** Swift/CryptoKit (macOS), Kotlin/javax.crypto (Android), X25519 ECDH, HKDF-SHA256, AES-256-GCM

**Spec:** `docs/superpowers/specs/2026-03-10-ecdh-pairing-design.md`

---

## File Structure

### New files
- `test-fixtures/protocol/l2cap/ecdh_fixture.json` — Cross-platform ECDH test vectors

### Modified files

**macOS:**
- `macos/ClipRelayMac/Sources/Protocol/MessageCodec.swift` — Add KEY_EXCHANGE (0x03), KEY_CONFIRM (0x04) message types
- `macos/ClipRelayMac/Sources/Crypto/E2ECrypto.swift` — Add ECDH shared secret computation, generalize deriveKey/deviceTag to accept raw bytes
- `macos/ClipRelayMac/Sources/Pairing/PairingManager.swift` — Generate X25519 key pair, build `k=` QR URI, hold ephemeral private key, store shared secret
- `macos/ClipRelayMac/Sources/Protocol/Session.swift` — Add pairing handshake mode (KEY_EXCHANGE/KEY_CONFIRM)
- `macos/ClipRelayMac/Sources/BLE/ConnectionManager.swift` — Support pairing tag matching during pairing mode
- `macos/ClipRelayMac/Sources/App/AppDelegate.swift` — Wire pairing mode through ConnectionManager and Session
- `macos/ClipRelayMac/Sources/App/PeerSummary.swift` — Rename `token` to `secret` (field stores shared secret now)
- `macos/ClipRelayMac/Tests/ClipRelayTests/MessageCodecTests.swift` — Tests for new message types
- `macos/ClipRelayMac/Tests/ClipRelayTests/E2ECryptoTests.swift` — ECDH tests
- `macos/ClipRelayMac/Tests/ClipRelayTests/E2ECryptoKeyDerivationTests.swift` — Test derivation from ECDH shared secret
- `macos/ClipRelayMac/Tests/ClipRelayTests/L2capFixtureCompatibilityTests.swift` — Add ECDH fixture tests

**Android:**
- `android/app/build.gradle.kts` — minSdk 30 → 31
- `android/app/src/main/java/org/cliprelay/protocol/MessageCodec.kt` — Add KEY_EXCHANGE (0x03), KEY_CONFIRM (0x04)
- `android/app/src/main/java/org/cliprelay/crypto/E2ECrypto.kt` — Add ECDH computation, generalize deriveKey/deviceTag
- `android/app/src/main/java/org/cliprelay/pairing/PairingUriParser.kt` — Parse `k=` instead of `t=`
- `android/app/src/main/java/org/cliprelay/pairing/PairingStore.kt` — Store shared secret instead of token
- `android/app/src/main/java/org/cliprelay/protocol/Session.kt` — Add pairing handshake mode
- `android/app/src/main/java/org/cliprelay/service/ClipRelayService.kt` — Pairing mode: advertise with pairing tag, handle key exchange
- `android/app/src/main/java/org/cliprelay/ui/QrScannerActivity.kt` — Generate key pair, show progress, wait for handshake
- `android/app/src/test/java/org/cliprelay/crypto/E2ECryptoTest.kt` — ECDH tests
- `android/app/src/test/java/org/cliprelay/pairing/PairingUriParserTest.kt` — Update for `k=` format
- `android/app/src/test/java/org/cliprelay/protocol/L2capFixtureCompatibilityTest.kt` — Add ECDH fixture tests

---

## Chunk 1: Protocol Layer (MessageCodec + Test Fixtures)

### Task 1: Add ECDH test fixture

**Files:**
- Create: `test-fixtures/protocol/l2cap/ecdh_fixture.json`

- [ ] **Step 1: Create the ECDH cross-platform test fixture**

Create `test-fixtures/protocol/l2cap/ecdh_fixture.json` with known X25519 key pairs and expected derivation outputs. Use RFC 7748 test vectors for the ECDH computation, then apply the existing HKDF derivation:

```json
{
  "fixture_id": "ecdh-pairing-v1",
  "description": "Cross-platform ECDH pairing test vectors for ClipRelay",
  "key_pairs": [
    {
      "name": "mac_ephemeral",
      "private_key_hex": "77076d0c9b7f0c04e35c1d5b79d5e76a8f3c2b0a1d4e6f8a9b0c1d2e3f4a5b6c",
      "public_key_hex": "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a"
    },
    {
      "name": "android_ephemeral",
      "private_key_hex": "5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb",
      "public_key_hex": "de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f"
    }
  ],
  "ecdh_shared_secret_hex": "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742",
  "derived": {
    "encryption_key_hex_prefix": "",
    "device_tag_hex": "",
    "pairing_tag_hex": ""
  },
  "key_exchange_message": {
    "type_byte": "03",
    "payload_utf8_template": "{\"pubkey\":\"<public_key_hex>\"}",
    "example_encoded_hex": ""
  },
  "key_confirm_message": {
    "type_byte": "04",
    "plaintext": "cliprelay-paired"
  },
  "wire_format_messages": [
    {
      "name": "KEY_EXCHANGE",
      "type_byte": "03",
      "payload_utf8": "{\"pubkey\":\"de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f\"}",
      "payload_hex": "7b227075626b6579223a2264653965646237643762376463316234643335623631633265636534333533373366383334336338356237383637346461646663376531343666383832623466227d"
    }
  ]
}
```

Note: The `derived` fields and `example_encoded_hex` will be filled in during Task 2 after we can compute them. The key pairs above are from RFC 7748 Section 6.1 test vectors.

- [ ] **Step 2: Commit**

```bash
git add test-fixtures/protocol/l2cap/ecdh_fixture.json
git commit -m "test: add ECDH pairing cross-platform test fixture"
```

### Task 2: Add KEY_EXCHANGE and KEY_CONFIRM message types (macOS)

**Files:**
- Modify: `macos/ClipRelayMac/Sources/Protocol/MessageCodec.swift:5-12`
- Modify: `macos/ClipRelayMac/Tests/ClipRelayTests/MessageCodecTests.swift`

- [ ] **Step 1: Write failing test for KEY_EXCHANGE round-trip**

In `MessageCodecTests.swift`, add:

```swift
func testKeyExchangeRoundTrip() {
    let pubkeyJSON = #"{"pubkey":"de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f"}"#
    let message = Message(type: .keyExchange, payload: Data(pubkeyJSON.utf8))
    let encoded = MessageCodec.encode(message)
    var offset = 0
    let decoded = try! MessageCodec.decode(from: encoded, offset: &offset)
    XCTAssertEqual(decoded.type, .keyExchange)
    XCTAssertEqual(String(data: decoded.payload, encoding: .utf8), pubkeyJSON)
}

func testKeyConfirmRoundTrip() {
    let payload = Data("encrypted-confirm-data".utf8)
    let message = Message(type: .keyConfirm, payload: payload)
    let encoded = MessageCodec.encode(message)
    var offset = 0
    let decoded = try! MessageCodec.decode(from: encoded, offset: &offset)
    XCTAssertEqual(decoded.type, .keyConfirm)
    XCTAssertEqual(decoded.payload, payload)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd macos && swift test --filter MessageCodecTests 2>&1 | tail -5`
Expected: Compilation error — `keyExchange` and `keyConfirm` not defined on `MessageType`

- [ ] **Step 3: Add message types to MessageCodec.swift**

In `MessageCodec.swift`, add to the `MessageType` enum after `welcome = 0x02`:

```swift
case keyExchange = 0x03
case keyConfirm = 0x04
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd macos && swift test --filter MessageCodecTests 2>&1 | tail -5`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add macos/ClipRelayMac/Sources/Protocol/MessageCodec.swift macos/ClipRelayMac/Tests/ClipRelayTests/MessageCodecTests.swift
git commit -m "feat(mac): add KEY_EXCHANGE and KEY_CONFIRM message types"
```

### Task 3: Add KEY_EXCHANGE and KEY_CONFIRM message types (Android)

**Files:**
- Modify: `android/app/src/main/java/org/cliprelay/protocol/MessageCodec.kt:10-16`
- Modify: `android/app/build.gradle.kts:65`

- [ ] **Step 1: Bump minSdk to 31**

In `android/app/build.gradle.kts`, change:
```kotlin
minSdk = 30
```
to:
```kotlin
minSdk = 31
```

- [ ] **Step 2: Add message types to MessageCodec.kt**

In `MessageCodec.kt`, add to the `MessageType` enum after `WELCOME(0x02)`:

```kotlin
KEY_EXCHANGE(0x03),
KEY_CONFIRM(0x04),
```

- [ ] **Step 3: Run Android tests to verify existing tests still pass**

Run: `cd android && ./gradlew test 2>&1 | tail -10`
Expected: All tests PASS

- [ ] **Step 4: Commit**

```bash
git add android/app/build.gradle.kts android/app/src/main/java/org/cliprelay/protocol/MessageCodec.kt
git commit -m "feat(android): add KEY_EXCHANGE/KEY_CONFIRM message types, bump minSdk to 31"
```

### Task 4: Update L2CAP fixture and fixture tests for new message types

**Files:**
- Modify: `test-fixtures/protocol/l2cap/l2cap_fixture.json`
- Modify: `macos/ClipRelayMac/Tests/ClipRelayTests/L2capFixtureCompatibilityTests.swift`
- Modify: `android/app/src/test/java/org/cliprelay/protocol/L2capFixtureCompatibilityTest.kt`

- [ ] **Step 1: Add KEY_EXCHANGE and KEY_CONFIRM entries to the L2CAP fixture**

Add to the `messages` array in `l2cap_fixture.json`:

```json
{
  "name": "KEY_EXCHANGE",
  "type_byte": "03",
  "payload_utf8": "{\"pubkey\":\"de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f\"}",
  "payload_hex": "7b227075626b6579223a2264653965646237643762376463316234643335623631633265636534333533373366383334336338356237383637346461646663376531343666383832623466227d",
  "encoded_hex": ""
},
{
  "name": "KEY_CONFIRM",
  "type_byte": "04",
  "payload_hex": "aaaabbbbccccdddd",
  "encoded_hex": ""
}
```

The `encoded_hex` values need to be computed: `[4-byte big-endian length of (1 + payload)][type_byte][payload]`. Compute these during implementation and fill in.

- [ ] **Step 2: Run fixture compatibility tests on both platforms**

Run:
```bash
cd macos && swift test --filter L2capFixture 2>&1 | tail -5
cd android && ./gradlew test --tests '*L2capFixture*' 2>&1 | tail -5
```

Expected: Both PASS (new entries are additive; existing tests shouldn't break if the fixture test code iterates all messages)

- [ ] **Step 3: Commit**

```bash
git add test-fixtures/ macos/ClipRelayMac/Tests/ android/app/src/test/
git commit -m "test: add KEY_EXCHANGE/KEY_CONFIRM to L2CAP fixture"
```

---

## Chunk 2: Crypto Layer (ECDH + Key Derivation)

### Task 5: Add ECDH computation to E2ECrypto (macOS)

**Files:**
- Modify: `macos/ClipRelayMac/Sources/Crypto/E2ECrypto.swift`
- Modify: `macos/ClipRelayMac/Tests/ClipRelayTests/E2ECryptoTests.swift`

- [ ] **Step 1: Write failing test for ECDH shared secret computation**

In `E2ECryptoTests.swift`, add:

```swift
import CryptoKit

func testECDHSharedSecret() {
    // Generate two X25519 key pairs
    let macKey = Curve25519.KeyAgreement.PrivateKey()
    let androidKey = Curve25519.KeyAgreement.PrivateKey()

    // Both sides compute the same shared secret
    let secret1 = try! E2ECrypto.ecdhSharedSecret(
        privateKey: macKey,
        remotePublicKeyBytes: androidKey.publicKey.rawRepresentation
    )
    let secret2 = try! E2ECrypto.ecdhSharedSecret(
        privateKey: androidKey,
        remotePublicKeyBytes: macKey.publicKey.rawRepresentation
    )
    XCTAssertEqual(secret1, secret2)
    XCTAssertEqual(secret1.count, 32)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd macos && swift test --filter testECDHSharedSecret 2>&1 | tail -5`
Expected: FAIL — `ecdhSharedSecret` not defined

- [ ] **Step 3: Implement ecdhSharedSecret in E2ECrypto.swift**

Add to `E2ECrypto`:

```swift
// MARK: - ECDH Key Agreement

static func ecdhSharedSecret(
    privateKey: Curve25519.KeyAgreement.PrivateKey,
    remotePublicKeyBytes: Data
) throws -> Data {
    let remotePublic = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remotePublicKeyBytes)
    let shared = try privateKey.sharedSecretFromKeyAgreement(with: remotePublic)
    // Extract raw bytes from SharedSecret via HKDF with empty info to get the raw value
    // Actually, we use the shared secret directly as IKM for our existing HKDF
    return shared.withUnsafeBytes { Data($0) }
}
```

Wait — `SharedSecret` in CryptoKit doesn't expose raw bytes directly. Instead, use `hkdfDerivedSymmetricKey` or convert. The correct approach:

```swift
static func ecdhSharedSecret(
    privateKey: Curve25519.KeyAgreement.PrivateKey,
    remotePublicKeyBytes: Data
) throws -> Data {
    let remotePublic = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remotePublicKeyBytes)
    let shared = try privateKey.sharedSecretFromKeyAgreement(with: remotePublic)
    // Use HKDF to extract a 32-byte key from the shared secret
    // This becomes the root secret (replaces the old token)
    let key = shared.hkdfDerivedSymmetricKey(
        using: SHA256.self,
        salt: Data(),
        sharedInfo: Data("cliprelay-ecdh-v1".utf8),
        outputByteCount: 32
    )
    return key.withUnsafeBytes { Data($0) }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd macos && swift test --filter testECDHSharedSecret 2>&1 | tail -5`
Expected: PASS

- [ ] **Step 5: Add deriveKey/deviceTag overloads that accept raw bytes**

Add to `E2ECrypto`:

```swift
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
```

- [ ] **Step 6: Write test for derivation from ECDH shared secret**

In `E2ECryptoKeyDerivationTests.swift`, add:

```swift
func testDeriveKeyFromSecretBytes() {
    let secretHex = "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742"
    let secretBytes = Data(hexString: secretHex)! // use existing hex helper or inline
    let key = E2ECrypto.deriveKey(secretBytes: secretBytes)
    XCTAssertNotNil(key)

    let tag = E2ECrypto.deviceTag(secretBytes: secretBytes)
    XCTAssertNotNil(tag)
    XCTAssertEqual(tag!.count, 8)
}
```

- [ ] **Step 7: Run all E2ECrypto tests**

Run: `cd macos && swift test --filter E2ECrypto 2>&1 | tail -10`
Expected: All PASS

- [ ] **Step 8: Commit**

```bash
git add macos/ClipRelayMac/Sources/Crypto/E2ECrypto.swift macos/ClipRelayMac/Tests/ClipRelayTests/
git commit -m "feat(mac): add ECDH shared secret computation and byte-based key derivation"
```

### Task 6: Add ECDH computation to E2ECrypto (Android)

**Files:**
- Modify: `android/app/src/main/java/org/cliprelay/crypto/E2ECrypto.kt`
- Modify: `android/app/src/test/java/org/cliprelay/crypto/E2ECryptoTest.kt`

- [ ] **Step 1: Write failing test for ECDH shared secret**

In `E2ECryptoTest.kt`, add:

```kotlin
@Test
fun ecdhSharedSecretMatchesBothSides() {
    val macKeyPair = E2ECrypto.generateX25519KeyPair()
    val androidKeyPair = E2ECrypto.generateX25519KeyPair()

    val secret1 = E2ECrypto.ecdhSharedSecret(macKeyPair.private, androidKeyPair.public.encoded)
    val secret2 = E2ECrypto.ecdhSharedSecret(androidKeyPair.private, macKeyPair.public.encoded)

    assertArrayEquals(secret1, secret2)
    assertEquals(32, secret1.size)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd android && ./gradlew test --tests '*E2ECryptoTest.ecdhSharedSecret*' 2>&1 | tail -5`
Expected: FAIL — methods not defined

- [ ] **Step 3: Implement ECDH in E2ECrypto.kt**

Add to `E2ECrypto`:

```kotlin
import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.PrivateKey
import java.security.spec.X509EncodedKeySpec
import javax.crypto.KeyAgreement as JKeyAgreement

fun generateX25519KeyPair(): KeyPair {
    val kpg = KeyPairGenerator.getInstance("X25519")
    return kpg.generateKeyPair()
}

fun ecdhSharedSecret(privateKey: PrivateKey, remotePublicKeyBytes: ByteArray): ByteArray {
    val keyFactory = KeyFactory.getInstance("X25519")
    val remotePub = keyFactory.generatePublic(X509EncodedKeySpec(remotePublicKeyBytes))
    val ka = JKeyAgreement.getInstance("X25519")
    ka.init(privateKey)
    ka.doPhase(remotePub, true)
    val rawSecret = ka.generateSecret()
    // Apply HKDF to extract root secret (matches macOS)
    return hkdf(rawSecret, "cliprelay-ecdh-v1", 32)
}
```

Note: Android's `PublicKey.getEncoded()` returns X.509-encoded bytes, not raw 32-byte keys. When receiving a raw 32-byte public key from the wire protocol, we need to wrap it in X.509 format. Add a helper:

```kotlin
fun x25519PublicKeyFromRaw(rawBytes: ByteArray): java.security.PublicKey {
    // X.509 SubjectPublicKeyInfo wrapper for X25519 raw key
    val x509Header = byteArrayOf(
        0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x6e, 0x03, 0x21, 0x00
    )
    val encoded = x509Header + rawBytes
    val keyFactory = KeyFactory.getInstance("X25519")
    return keyFactory.generatePublic(X509EncodedKeySpec(encoded))
}

fun ecdhSharedSecret(privateKey: PrivateKey, remotePublicKeyRaw: ByteArray): ByteArray {
    val remotePub = x25519PublicKeyFromRaw(remotePublicKeyRaw)
    val ka = JKeyAgreement.getInstance("X25519")
    ka.init(privateKey)
    ka.doPhase(remotePub, true)
    val rawSecret = ka.generateSecret()
    return hkdf(rawSecret, "cliprelay-ecdh-v1", 32)
}

fun x25519PublicKeyToRaw(publicKey: java.security.PublicKey): ByteArray {
    // Strip X.509 header (12 bytes) to get raw 32-byte key
    val encoded = publicKey.encoded
    return encoded.copyOfRange(encoded.size - 32, encoded.size)
}
```

- [ ] **Step 4: Add deriveKey/deviceTag overloads for raw bytes**

```kotlin
fun deriveKey(secretBytes: ByteArray): SecretKey {
    val keyBytes = hkdf(secretBytes, "cliprelay-enc-v1", 32)
    return SecretKeySpec(keyBytes, "AES")
}

fun deviceTag(secretBytes: ByteArray): ByteArray {
    return hkdf(secretBytes, "cliprelay-tag-v1", 8)
}
```

- [ ] **Step 5: Run tests**

Run: `cd android && ./gradlew test --tests '*E2ECryptoTest*' 2>&1 | tail -10`
Expected: All PASS

- [ ] **Step 6: Commit**

```bash
git add android/app/src/main/java/org/cliprelay/crypto/E2ECrypto.kt android/app/src/test/java/org/cliprelay/crypto/E2ECryptoTest.kt
git commit -m "feat(android): add ECDH shared secret computation and byte-based key derivation"
```

### Task 7: Cross-platform ECDH interop test

**Files:**
- Modify: `test-fixtures/protocol/l2cap/ecdh_fixture.json`
- Modify: `macos/ClipRelayMac/Tests/ClipRelayTests/E2ECryptoKeyDerivationTests.swift`
- Modify: `android/app/src/test/java/org/cliprelay/crypto/E2ECryptoTest.kt`

- [ ] **Step 1: Compute actual derived values using one platform and update the fixture**

Run the ECDH shared secret through the derivation on one platform to get the actual `encryption_key`, `device_tag`, and `pairing_tag` hex values. Update `ecdh_fixture.json` with these known-good values.

- [ ] **Step 2: Write fixture-based test on macOS**

```swift
func testECDHFixtureDerivation() {
    // Load ecdh_fixture.json, parse shared_secret_hex
    // Verify deriveKey(secretBytes:) and deviceTag(secretBytes:) match fixture values
}
```

- [ ] **Step 3: Write fixture-based test on Android**

```kotlin
@Test
fun ecdhFixtureDerivation() {
    // Load ecdh_fixture.json, parse shared_secret_hex
    // Verify deriveKey(secretBytes) and deviceTag(secretBytes) match fixture values
}
```

- [ ] **Step 4: Run both**

```bash
cd macos && swift test --filter ECDHFixture 2>&1 | tail -5
cd android && ./gradlew test --tests '*ecdhFixture*' 2>&1 | tail -5
```

Expected: Both PASS with identical derived values

- [ ] **Step 5: Commit**

```bash
git add test-fixtures/ macos/ClipRelayMac/Tests/ android/app/src/test/
git commit -m "test: cross-platform ECDH interop fixture verification"
```

---

## Chunk 3: Pairing Layer (QR, URI parsing, Storage)

### Task 8: Update PairingManager for ECDH (macOS)

**Files:**
- Modify: `macos/ClipRelayMac/Sources/Pairing/PairingManager.swift`

- [ ] **Step 1: Replace PairedDevice.token with sharedSecret**

Change the `PairedDevice` struct:

```swift
struct PairedDevice: Codable, Equatable {
    let sharedSecret: String // 64-char hex (ECDH-derived)
    let displayName: String
    let datePaired: Date
}
```

- [ ] **Step 2: Add ECDH key pair generation and QR URI builder**

Replace `generateToken()` and `pairingURI(token:)` with:

```swift
/// Ephemeral ECDH key pair for in-progress pairing. Discarded after pairing completes or is cancelled.
private(set) var ephemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey?

func generateKeyPair() -> Curve25519.KeyAgreement.PrivateKey {
    let key = Curve25519.KeyAgreement.PrivateKey()
    ephemeralPrivateKey = key
    return key
}

func clearEphemeralKey() {
    ephemeralPrivateKey = nil
}

func pairingURI(publicKey: Curve25519.KeyAgreement.PublicKey) -> URL? {
    let pubHex = publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
    var components = URLComponents()
    components.scheme = "cliprelay"
    components.host = "pair"
    let macName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    components.queryItems = [
        URLQueryItem(name: "k", value: pubHex),
        URLQueryItem(name: "n", value: macName)
    ]
    return components.url
}

/// Compute pairing tag from public key for BLE discovery during pairing.
static func pairingTag(from publicKey: Data) -> Data {
    let hash = SHA256.hash(data: publicKey)
    return Data(hash.prefix(8))
}
```

- [ ] **Step 3: Update deriveKey/deviceTag to use sharedSecret**

Update methods to call the new byte-based overloads:

```swift
func deviceTag(for secret: String) -> Data? {
    if let cached = tagCache[secret] { return cached }
    guard let secretBytes = hexToData(secret) else { return nil }
    guard let result = E2ECrypto.deviceTag(secretBytes: secretBytes) else { return nil }
    tagCache[secret] = result
    return result
}

func encryptionKey(for secret: String) -> SymmetricKey? {
    guard let secretBytes = hexToData(secret) else { return nil }
    return E2ECrypto.deriveKey(secretBytes: secretBytes)
}

private func hexToData(_ hex: String) -> Data? {
    let chars = Array(hex)
    guard chars.count.isMultiple(of: 2) else { return nil }
    var data = Data(capacity: chars.count / 2)
    for i in stride(from: 0, to: chars.count, by: 2) {
        guard let byte = UInt8(String(chars[i...i + 1]), radix: 16) else { return nil }
        data.append(byte)
    }
    return data
}
```

- [ ] **Step 4: Update addDevice/removeDevice to use sharedSecret field**

Replace all references to `device.token` with `device.sharedSecret` in `addDevice`, `removeDevice`, `removePendingDevices`.

- [ ] **Step 5: Build to verify compilation**

Run: `cd macos && swift build 2>&1 | tail -10`
Expected: Compilation errors in files that still reference `.token` (AppDelegate, ConnectionManager, etc.) — this is expected; those files will be updated in later tasks.

- [ ] **Step 6: Commit**

```bash
git add macos/ClipRelayMac/Sources/Pairing/PairingManager.swift
git commit -m "feat(mac): update PairingManager for ECDH key pairs and shared secret storage"
```

### Task 9: Update PairingUriParser for `k=` format (Android)

**Files:**
- Modify: `android/app/src/main/java/org/cliprelay/pairing/PairingUriParser.kt`
- Modify: `android/app/src/test/java/org/cliprelay/pairing/PairingUriParserTest.kt`

- [ ] **Step 1: Update tests for `k=` format**

Update all tests in `PairingUriParserTest.kt` to use `k=` instead of `t=`. Rename `PairingInfo.token` to `PairingInfo.publicKeyHex`. Add a test that rejects old `t=` format:

```kotlin
@Test
fun rejectsOldTokenFormat() {
    val uri = "cliprelay://pair?t=${"ab".repeat(32)}"
    assertNull(PairingUriParser.parse(uri))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd android && ./gradlew test --tests '*PairingUriParserTest*' 2>&1 | tail -10`
Expected: FAIL

- [ ] **Step 3: Update PairingUriParser**

Change `PairingInfo`:
```kotlin
data class PairingInfo(val publicKeyHex: String, val deviceName: String?)
```

Change `parse()` to look for `k=` instead of `t=`:
```kotlin
val publicKeyHex = params["k"] ?: return null
if (publicKeyHex.length != 64) return null
if (!publicKeyHex.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }) return null
val deviceName = params["n"]?.takeIf { it.isNotBlank() }
return PairingInfo(publicKeyHex.lowercase(), deviceName)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd android && ./gradlew test --tests '*PairingUriParserTest*' 2>&1 | tail -10`
Expected: All PASS

- [ ] **Step 5: Commit**

```bash
git add android/app/src/main/java/org/cliprelay/pairing/ android/app/src/test/java/org/cliprelay/pairing/
git commit -m "feat(android): update PairingUriParser for k= (public key) format"
```

### Task 10: Update PairingStore for shared secret (Android)

**Files:**
- Modify: `android/app/src/main/java/org/cliprelay/pairing/PairingStore.kt`

- [ ] **Step 1: Rename token methods to sharedSecret**

Rename `KEY_TOKEN` to `KEY_SHARED_SECRET`, `saveToken` to `saveSharedSecret`, `loadToken` to `loadSharedSecret`:

```kotlin
companion object {
    private const val TAG = "PairingStore"
    private const val PREFS_NAME = "cliprelay_pairing"
    private const val KEY_SHARED_SECRET = "shared_secret"
}

fun saveSharedSecret(secret: String): Boolean { ... }
fun loadSharedSecret(): String? { ... }
```

Keep the same EncryptedSharedPreferences mechanism.

- [ ] **Step 2: Build to verify**

Run: `cd android && ./gradlew compileDebugKotlin 2>&1 | tail -10`
Expected: Compilation errors in callers (ClipRelayService, QrScannerActivity) — expected, those are updated later.

- [ ] **Step 3: Commit**

```bash
git add android/app/src/main/java/org/cliprelay/pairing/PairingStore.kt
git commit -m "feat(android): rename PairingStore from token to shared secret"
```

---

## Chunk 4: Session Pairing Handshake

### Task 11: Add pairing handshake to Session (macOS)

**Files:**
- Modify: `macos/ClipRelayMac/Sources/Protocol/Session.swift`

- [ ] **Step 1: Add pairing mode support**

Add a pairing mode enum and callback to Session:

```swift
enum SessionMode {
    case normal
    case pairing(privateKey: Curve25519.KeyAgreement.PrivateKey)
}

// Add to Session init:
// let mode: SessionMode

// Add delegate method:
// func session(_ session: Session, didCompletePairingWithSecret sharedSecret: Data, remoteName: String?)
```

Extend `SessionDelegate`:
```swift
func session(_ session: Session, didCompletePairingWithSecret sharedSecret: Data, remoteName: String?)
```

- [ ] **Step 2: Implement pairing handshake in performHandshake**

When `mode == .pairing(let privateKey)`:

```swift
private func pairingInitiatorHandshake(privateKey: Curve25519.KeyAgreement.PrivateKey) throws {
    // Wait for KEY_EXCHANGE from Android
    let keyExchange = try readWithTimeout(60.0) // 60s pairing timeout
    guard keyExchange.type == .keyExchange else {
        throw SessionError.unexpectedMessage("Expected KEY_EXCHANGE, got \(keyExchange.type)")
    }

    // Parse Android's public key
    guard let json = try JSONSerialization.jsonObject(with: keyExchange.payload) as? [String: Any],
          let pubkeyHex = json["pubkey"] as? String else {
        throw SessionError.protocolError("Invalid KEY_EXCHANGE payload")
    }

    // Compute ECDH shared secret
    guard let remoteKeyBytes = hexToData(pubkeyHex) else {
        throw SessionError.protocolError("Invalid public key hex")
    }
    let sharedSecret = try E2ECrypto.ecdhSharedSecret(privateKey: privateKey, remotePublicKeyBytes: remoteKeyBytes)

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
    remoteName = json["name"] as? String

    // Notify delegate of completed pairing
    delegate?.session(self, didCompletePairingWithSecret: sharedSecret, remoteName: remoteName)

    // Continue with normal HELLO/WELCOME
    try initiatorHandshake()
}
```

- [ ] **Step 3: Add hexToData helper to Session (or make E2ECrypto's version accessible)**

- [ ] **Step 4: Build to verify**

Run: `cd macos && swift build 2>&1 | tail -10`

- [ ] **Step 5: Commit**

```bash
git add macos/ClipRelayMac/Sources/Protocol/Session.swift
git commit -m "feat(mac): add ECDH pairing handshake to Session"
```

### Task 12: Add pairing handshake to Session (Android)

**Files:**
- Modify: `android/app/src/main/java/org/cliprelay/protocol/Session.kt`

- [ ] **Step 1: Add pairing mode**

Add a sealed class for session mode:

```kotlin
sealed class SessionMode {
    object Normal : SessionMode()
    data class Pairing(
        val ownPrivateKey: java.security.PrivateKey,
        val remotePublicKeyRaw: ByteArray
    ) : SessionMode()
}
```

Add to `SessionCallback`:
```kotlin
fun onPairingComplete(sharedSecret: ByteArray, remoteName: String?)
```

Add `mode` parameter to Session constructor with default `SessionMode.Normal`.

- [ ] **Step 2: Implement pairing responder handshake**

When `mode` is `SessionMode.Pairing`:

```kotlin
private fun pairingResponderHandshake(mode: SessionMode.Pairing) {
    // Send KEY_EXCHANGE with our public key
    val ownPubRaw = E2ECrypto.x25519PublicKeyToRaw(/* need to get public key from private */)
    val json = JSONObject().apply {
        put("pubkey", ownPubRaw.joinToString("") { "%02x".format(it) })
        localName?.let { put("name", it) }
    }
    val keyExchange = Message(MessageType.KEY_EXCHANGE, json.toString().toByteArray())
    MessageCodec.write(output, keyExchange)

    // Compute shared secret
    val sharedSecret = E2ECrypto.ecdhSharedSecret(mode.ownPrivateKey, mode.remotePublicKeyRaw)

    // Wait for KEY_CONFIRM
    val confirm = readWithTimeout(60_000) // 60s pairing timeout
    if (confirm.type != MessageType.KEY_CONFIRM) {
        throw ProtocolException("Expected KEY_CONFIRM, got ${confirm.type}")
    }

    // Decrypt and verify
    val encKey = E2ECrypto.deriveKey(sharedSecret)
    val plaintext = E2ECrypto.open(confirm.payload, encKey)
    val confirmText = String(plaintext)
    if (confirmText != "cliprelay-paired") {
        throw ProtocolException("KEY_CONFIRM verification failed")
    }

    // Notify callback
    callback.onPairingComplete(sharedSecret, remoteName = null)

    // Continue with normal HELLO/WELCOME
    responderHandshake()
}
```

- [ ] **Step 3: Build to verify**

Run: `cd android && ./gradlew compileDebugKotlin 2>&1 | tail -10`

- [ ] **Step 4: Commit**

```bash
git add android/app/src/main/java/org/cliprelay/protocol/Session.kt
git commit -m "feat(android): add ECDH pairing handshake to Session"
```

---

## Chunk 5: BLE and App Integration

### Task 13: Update ConnectionManager for pairing tag (macOS)

**Files:**
- Modify: `macos/ClipRelayMac/Sources/BLE/ConnectionManager.swift`

- [ ] **Step 1: Add pairing tag scanning mode**

Add a property for pairing mode:

```swift
/// When set, scan for this pairing tag instead of paired device tags.
var pairingTag: Data? {
    didSet {
        if pairingTag != nil {
            // Restart scanning in pairing mode
            if case .scanning = state { centralManager?.stopScan() }
            state = .idle
            startScanning()
        }
    }
}
```

- [ ] **Step 2: Update didDiscover to check pairing tag**

In `centralManager(_:didDiscover:advertisementData:rssi:)`, add pairing tag matching before the existing paired device matching:

```swift
// Check pairing mode first
if let expectedPairingTag = pairingTag {
    if tag == expectedPairingTag {
        matchedToken = nil // no token yet — will be set after ECDH
        // ... connect logic
    }
    return // in pairing mode, only match pairing tag
}
// Existing paired device matching...
```

- [ ] **Step 3: Update delegate to support pairing connections (no token yet)**

The `didEstablishChannel` delegate call currently requires a token. For pairing, there's no token yet. Either:
- Make the token parameter optional
- Add a separate `didEstablishPairingChannel` method

Use a separate method for clarity:

```swift
func connectionManager(_ manager: ConnectionManager, didEstablishPairingChannel inputStream: InputStream,
                       outputStream: OutputStream)
```

- [ ] **Step 4: Commit**

```bash
git add macos/ClipRelayMac/Sources/BLE/ConnectionManager.swift
git commit -m "feat(mac): add pairing tag scanning to ConnectionManager"
```

### Task 14: Wire pairing flow in AppDelegate (macOS)

**Files:**
- Modify: `macos/ClipRelayMac/Sources/App/AppDelegate.swift`
- Modify: `macos/ClipRelayMac/Sources/App/PeerSummary.swift`

- [ ] **Step 1: Update PeerSummary**

Rename `token` to `secret`:

```swift
struct PeerSummary {
    let id: UUID
    let description: String
    var secret: String?
    var deviceTagHex: String?
}
```

- [ ] **Step 2: Update startPairing() for ECDH**

```swift
private func startPairing() {
    pairingManager.removePendingDevices()

    let privateKey = pairingManager.generateKeyPair()
    let publicKey = privateKey.publicKey

    // Add a pending device placeholder
    let device = PairedDevice(
        sharedSecret: "", // empty until ECDH completes
        displayName: "Pending pairing\u{2026}",
        datePaired: Date()
    )
    // Don't persist pending device yet — wait for ECDH completion

    awaitingNewPairingConnection = true

    guard let uri = pairingManager.pairingURI(publicKey: publicKey) else { return }
    pairingWindowController.showPairingQR(uri: uri)

    // Tell ConnectionManager to scan for pairing tag
    let pairingTag = PairingManager.pairingTag(from: publicKey.rawRepresentation)
    connectionManager.pairingTag = pairingTag

    refreshTrustedPeersMenu()
}
```

- [ ] **Step 3: Handle pairing channel establishment**

Implement the new delegate method:

```swift
func connectionManager(_ manager: ConnectionManager, didEstablishPairingChannel inputStream: InputStream,
                       outputStream: OutputStream) {
    guard let privateKey = pairingManager.ephemeralPrivateKey else {
        appLogger.error("[App] Pairing channel established but no ephemeral key")
        return
    }

    // Create session in pairing mode
    let session = Session(inputStream: inputStream, outputStream: outputStream,
                          isInitiator: true, delegate: self,
                          mode: .pairing(privateKey: privateKey))
    session.localName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    activeSession = session

    // Run on background thread (same pattern as normal connections)
    let thread = Thread {
        session.performHandshake()
        session.listenForMessages()
    }
    thread.name = "L2CAP-Pairing"
    thread.start()
    sessionThread = thread
}
```

- [ ] **Step 4: Handle pairing completion callback**

```swift
func session(_ session: Session, didCompletePairingWithSecret sharedSecret: Data, remoteName: String?) {
    let secretHex = sharedSecret.map { String(format: "%02x", $0) }.joined()

    // Store the paired device
    let device = PairedDevice(
        sharedSecret: secretHex,
        displayName: remoteName ?? "Android",
        datePaired: Date()
    )
    pairingManager.addDevice(device)
    pairingManager.clearEphemeralKey()

    // Clear pairing mode on ConnectionManager
    connectionManager.pairingTag = nil
    connectedToken = secretHex // reuse this field (rename later if desired)

    DispatchQueue.main.async { [weak self] in
        self?.completePairing(token: secretHex, deviceName: remoteName)
    }
}
```

- [ ] **Step 5: Update all `.token` references to `.sharedSecret`**

Search through AppDelegate for all references to `device.token`, `peer.token`, `connectedToken` and update to use `sharedSecret` / `secret` as appropriate. The `connectedToken` field can be renamed to `connectedSecret` for consistency.

- [ ] **Step 6: Update handlePairingWindowClosed to clear ephemeral key**

```swift
private func handlePairingWindowClosed() {
    guard awaitingNewPairingConnection else { return }
    pairingManager.clearEphemeralKey()
    connectionManager.pairingTag = nil
    cancelPendingPairingFlow(removePendingDevice: true)
}
```

- [ ] **Step 7: Build to verify**

Run: `cd macos && swift build 2>&1 | tail -10`
Expected: BUILD SUCCEEDED (or known errors in StatusBarController referencing `peer.token`)

- [ ] **Step 8: Update StatusBarController references**

Update `renderTrustedDevicesSection` in `StatusBarController.swift` — change `peer.token` to `peer.secret`.

- [ ] **Step 9: Build and run all macOS tests**

Run: `cd macos && swift test 2>&1 | tail -15`
Expected: All PASS

- [ ] **Step 10: Commit**

```bash
git add macos/ClipRelayMac/Sources/
git commit -m "feat(mac): wire ECDH pairing flow through AppDelegate and ConnectionManager"
```

### Task 15: Update Android service and QR scanner for ECDH pairing

**Files:**
- Modify: `android/app/src/main/java/org/cliprelay/service/ClipRelayService.kt`
- Modify: `android/app/src/main/java/org/cliprelay/ui/QrScannerActivity.kt`

- [ ] **Step 1: Update QrScannerActivity for ECDH**

Replace `handleScannedValue` to generate a key pair and signal the service:

```kotlin
private fun handleScannedValue(rawValue: String) {
    val info = PairingUriParser.parse(rawValue)
    if (info == null) {
        Toast.makeText(this, "Invalid pairing QR code", Toast.LENGTH_LONG).show()
        finish()
        return
    }

    // Store the Mac's public key hex and device name in SharedPreferences
    // The service will handle key generation and pairing
    val prefs = getSharedPreferences(ClipRelayService.PREFS_NAME, MODE_PRIVATE)
    prefs.edit()
        .putString("pending_pairing_pubkey", info.publicKeyHex)
        .putString(ClipRelayService.KEY_CONNECTED_DEVICE, info.deviceName ?: "")
        .apply()

    // Signal the service to start pairing mode
    val intent = android.content.Intent(ClipRelayService.ACTION_START_PAIRING)
    intent.setPackage(packageName)
    sendBroadcast(intent)

    Toast.makeText(this, "Pairing...", Toast.LENGTH_SHORT).show()
    setResult(RESULT_OK)
    finish()
}
```

- [ ] **Step 2: Add pairing mode to ClipRelayService**

Add a broadcast receiver for `ACTION_START_PAIRING` and implement the pairing flow:

1. Read Mac's public key from SharedPreferences
2. Generate X25519 key pair
3. Compute pairing tag from Mac's public key
4. Switch advertiser to use pairing tag
5. When L2CAP connection arrives, create Session in pairing mode
6. On pairing completion callback, store shared secret, switch to device tag advertising

- [ ] **Step 3: Update ClipRelayService token references to shared secret**

Replace all `pairingStore.loadToken()` / `pairingStore.saveToken()` with `loadSharedSecret()` / `saveSharedSecret()`.

- [ ] **Step 4: Update ClipRelayService encryption key derivation**

Change from `E2ECrypto.deriveKey(tokenHex)` to `E2ECrypto.deriveKey(hexToBytes(secretHex))` pattern.

- [ ] **Step 5: Build and run tests**

Run: `cd android && ./gradlew test 2>&1 | tail -15`
Expected: All PASS

- [ ] **Step 6: Commit**

```bash
git add android/app/src/main/java/org/cliprelay/
git commit -m "feat(android): wire ECDH pairing through QrScanner and ClipRelayService"
```

### Task 16: Update MainViewModel for pairing state (Android)

**Files:**
- Modify: `android/app/src/main/java/org/cliprelay/ui/MainViewModel.kt`
- Modify: `android/app/src/main/java/org/cliprelay/ui/MainActivity.kt`

- [ ] **Step 1: Update initState and onPaired to use shared secret**

The `MainViewModel` currently receives `deviceTag` for display. This stays the same — the device tag is still derived via HKDF, just from the ECDH shared secret instead of the token. No logic changes needed in the ViewModel, but verify `MainActivity` passes the correct values.

- [ ] **Step 2: Update MainActivity to use loadSharedSecret**

Any reference to `pairingStore.loadToken()` should become `pairingStore.loadSharedSecret()`.

- [ ] **Step 3: Build and verify**

Run: `cd android && ./gradlew assembleDebug 2>&1 | tail -10`
Expected: BUILD SUCCESSFUL

- [ ] **Step 4: Commit**

```bash
git add android/app/src/main/java/org/cliprelay/ui/
git commit -m "feat(android): update UI layer for shared secret pairing"
```

---

## Chunk 6: Build Verification and Integration Testing

### Task 17: Full build and test verification

**Files:** None (verification only)

- [ ] **Step 1: Run full macOS build and test**

Run: `cd macos && swift build && swift test 2>&1 | tail -20`
Expected: BUILD SUCCEEDED, all tests PASS

- [ ] **Step 2: Run full Android build and test**

Run: `cd android && ./gradlew assembleDebug test 2>&1 | tail -20`
Expected: BUILD SUCCESSFUL, all tests PASS

- [ ] **Step 3: Run scripts/build-all.sh**

Run: `scripts/build-all.sh 2>&1 | tail -20`
Expected: All builds pass

- [ ] **Step 4: Run scripts/test-all.sh**

Run: `scripts/test-all.sh 2>&1 | tail -20`
Expected: All tests pass

- [ ] **Step 5: If an Android device is connected, run hardware smoke tests**

Run: `adb get-state 2>/dev/null && scripts/hardware-smoke-test.sh`

### Task 18: Manual integration test (if devices available)

- [ ] **Step 1: Install Mac app**

```bash
pkill -f ClipRelay; open dist/ClipRelay.app
```

- [ ] **Step 2: Install Android app**

```bash
adb install -r dist/cliprelay-debug.apk
adb shell am force-stop org.cliprelay
adb shell am start -n org.cliprelay/.ui.MainActivity
```

- [ ] **Step 3: Test pairing flow**

1. Click "Pair New Device" on Mac
2. Scan QR from Android
3. Verify Android shows "Pairing..." then "Paired successfully!"
4. Verify Mac QR window closes
5. Verify both show the same pairing ID
6. Copy text on Mac → verify it appears on Android
7. Copy text on Android → verify it appears on Mac

- [ ] **Step 4: Test re-pairing**

1. Unpair on Android
2. Pair again
3. Verify clipboard sync works with new pairing
