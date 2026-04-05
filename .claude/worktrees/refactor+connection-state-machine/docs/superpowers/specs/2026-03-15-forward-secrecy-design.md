# Forward Secrecy & Handshake Authentication — Design Spec

**Date:** 2026-03-15
**Addresses:** Security review findings M-11 (no forward secrecy) and H-1 (unauthenticated handshake)

---

## Summary

Add per-session ephemeral X25519 key exchange and HMAC authentication to the HELLO/WELCOME handshake. This provides forward secrecy (captured traffic is undecryptable after session ends) and mutual authentication (rogue devices rejected at handshake). Protocol version bumps from 1 to 2. No new message types, no extra round trips.

---

## Protocol Change

### Current handshake (v1)

```
Mac:     HELLO   {"version":1, "name":"Christian's Mac"}
Android: WELCOME {"version":1, "name":"Pixel 9 Pro"}
→ encryption key = HKDF(shared_secret, "cliprelay-enc-v1")  [static, never changes]
```

### New handshake (v2)

```
Mac:     HELLO   {"version":2, "name":"Christian's Mac", "ek":"<ephemeral pubkey hex>", "auth":"<HMAC hex>"}
Android: WELCOME {"version":2, "name":"Pixel 9 Pro",     "ek":"<ephemeral pubkey hex>", "auth":"<HMAC hex>"}
→ session key = HKDF(shared_secret || ecdh_result, "cliprelay-session-v2")  [fresh per session]
```

Fields:
- `ek`: 64-char hex string — raw 32-byte X25519 ephemeral public key
- `auth`: 64-char hex string — `HMAC-SHA256(key=auth_key, msg=ephemeral_public_key_bytes)`

### Key derivation

```
auth_key     = HKDF(ikm=shared_secret, salt=zeros, info="cliprelay-auth-v2",    length=32)
ecdh_result  = raw_X25519(own_ephemeral_private, remote_ephemeral_public)
session_key  = HKDF(ikm=shared_secret || ecdh_result, salt=zeros, info="cliprelay-session-v2", length=32)
```

Notes:
- All HKDF derivations use an all-zeros salt, consistent with the existing `hkdf()` implementations on both platforms.
- `ecdh_result` is the **raw** X25519 output (32 bytes). Do NOT use the existing `ecdhSharedSecret()` helper, which wraps the result in an additional HKDF with info `"cliprelay-ecdh-v1"`. The raw output is fed directly into the session key HKDF, which provides the necessary key stretching.
- The session key derivation includes the shared secret so that even if ephemeral keys are compromised (e.g., weak RNG), the session key still can't be derived without the long-term secret.

AAD for AES-GCM changes from `"cliprelay-v1"` to `"cliprelay-v2"` to ensure v1 ciphertext can't be accepted by a v2 session.

### Ephemeral key lifecycle

1. Generated fresh at start of `initiatorHandshake()` / `responderHandshake()`
2. Public key embedded in HELLO/WELCOME payload
3. After both sides exchange keys, ECDH is computed and session key derived
4. Ephemeral private key reference is dropped immediately after session key derivation
5. Session key lives in the `Session` object and is discarded when the session closes

---

## Handshake Flow (detailed)

### Mac (initiator)

1. Generate ephemeral X25519 key pair
2. Compute `auth = HMAC-SHA256(key=auth_key, msg=ephemeral_public_bytes)`
3. Send HELLO with `version`, `name`, `ek`, `auth`
4. Receive WELCOME — validate:
   - `version == 2` (else version mismatch error)
   - `ek` present and 64 hex chars
   - `auth` verifies against remote's `ek` using `auth_key` (constant-time comparison)
5. Compute `ecdh_result = raw_X25519(own_ephemeral_private, remote_ek)`
6. Derive `session_key`
7. Drop ephemeral private key

### Android (responder)

1. Receive HELLO — validate:
   - `version == 2` (else version mismatch error)
   - `ek` present and 64 hex chars
   - `auth` verifies against remote's `ek` using `auth_key` (constant-time comparison)
2. Generate ephemeral X25519 key pair
3. Compute `auth = HMAC-SHA256(key=auth_key, msg=ephemeral_public_bytes)`
4. Send WELCOME with `version`, `name`, `ek`, `auth`
5. Compute `ecdh_result = raw_X25519(own_ephemeral_private, remote_ek)`
6. Derive `session_key`
7. Drop ephemeral private key

---

## Session Key Ownership

The session key is owned by the `Session` object. The service layer (AppDelegate / ClipRelayService) no longer passes an encryption key to the session for clipboard operations. Instead:

- The service layer provides the **shared secret** (hex string) to the Session at construction time
- The Session derives `auth_key` from the shared secret during construction
- The Session derives the `session_key` during the handshake
- The Session encrypts/decrypts clipboard payloads internally using the session key
- The `sendClipboard()` method accepts **plaintext** instead of pre-encrypted data
- The `onClipboardReceived` callback delivers **plaintext** instead of encrypted blobs

This simplifies the service layer (no more encrypt-then-send / receive-then-decrypt) and ensures the session key never leaks outside the Session object.

### Hash computation

The `hash` field in OFFER/DONE messages is computed over **plaintext** (before encryption). This ensures that identical clipboard content deduplicates correctly regardless of session key (AES-GCM produces different ciphertext each time due to random nonces, so hashing ciphertext would break dedup).

---

## Version Mismatch UX

When a device receives a handshake message with a version it doesn't support, it reports a distinct error so the UI can show a helpful message.

### Android

- Session reports a `VersionMismatchException` (or distinct error type) when it receives HELLO with `version != 2`
- ClipRelayService catches this in `onSessionError` and broadcasts `ACTION_VERSION_MISMATCH`
- UI shows a dialog: "Your Mac app needs to be updated to continue syncing. Download the latest version at cliprelay.org."

### macOS

- Session reports `SessionError.versionMismatch` (already exists) when it receives WELCOME with `version != 2`
- AppDelegate shows a notification or alert: "Your Android app needs to be updated to continue syncing. Update via Google Play."

---

## Error Handling

All new error conditions result in session close + automatic reconnect (same behavior as existing handshake errors):

| Condition | Error |
|-----------|-------|
| Remote sends `version: 1` | `versionMismatch` — reported distinctly to UI for update prompt |
| `ek` missing or not 64 hex chars | `protocolError("Invalid ephemeral key")` |
| `auth` HMAC verification fails | `protocolError("Authentication failed")` |
| ECDH computation fails | `protocolError("Key agreement failed")` |

---

## Pairing Handshake

The pairing flow (KEY_EXCHANGE / KEY_CONFIRM) is unchanged. Pairing still establishes the long-term shared secret via its own ECDH exchange. After pairing completes, the normal v2 HELLO/WELCOME handshake follows, which establishes the session key. This is already the existing behavior (pairing is followed by a normal handshake on the same connection).

---

## Files Changed

### E2ECrypto (both platforms)

- Add `deriveAuthKey(secretBytes:) -> key` — `HKDF(secret, "cliprelay-auth-v2", 32)`
- Add `deriveSessionKey(secretBytes:, ecdhResult:) -> key` — `HKDF(secret || ecdhResult, "cliprelay-session-v2", 32)`
- Add `hmacAuth(publicKeyBytes:, authKey:) -> Data` — `HMAC-SHA256(key=authKey, msg=publicKeyBytes)`
- Add `verifyAuth(publicKeyBytes:, authKey:, expected:) -> Bool` — constant-time comparison (use `MessageDigest.isEqual()` on Android, CryptoKit's built-in comparison on macOS)
- Add `rawX25519(ownPrivate:, remotePublic:) -> Data` — raw X25519 output without the extra HKDF that `ecdhSharedSecret()` applies
- Update AAD constant from `"cliprelay-v1"` to `"cliprelay-v2"`

### Session (both platforms)

- Add `sharedSecret: Data` parameter to constructor
- Remove external encryption/decryption — Session encrypts/decrypts internally
- `sendClipboard()` accepts plaintext `Data`/`ByteArray` instead of encrypted blob
- Callback/delegate delivers plaintext instead of encrypted blob
- `initiatorHandshake()` / `responderHandshake()` — generate ephemeral keys, embed in payload, verify remote auth, derive session key
- `helloPayload()` → include `ek` and `auth` fields, version bumped to 2
- `validateVersion()` → also validate `ek` and `auth`, report version mismatch distinctly
- Version constant bumped from 1 to 2

### AppDelegate (macOS)

- Pass shared secret to Session instead of encrypting/decrypting externally
- `onClipboardChange()` sends plaintext to session
- `session(_:didReceiveClipboard:hash:)` receives plaintext
- `pendingClipboardPayload` switches from storing ciphertext to storing plaintext. On reconnect, the plaintext is re-encrypted with the new session's key — this is the correct behavior (new session = new ephemeral keys = new session key). Note: this is an in-memory variable only (not persisted to disk). The plaintext is already in process memory via `ClipboardMonitor` and `NSPasteboard`, so this does not change the attack surface.
- Remove `pairingManager.encryptionKey(for:)` calls from clipboard path
- Handle `versionMismatch` distinctly in `session(_:didFailWithError:)` — show update prompt

### ClipRelayService (Android)

- Pass shared secret to Session instead of encrypting/decrypting externally
- `pushPlainTextToMac()` sends plaintext to session
- `onClipboardReceived()` receives plaintext
- Replace `encryptionKey` field with an `isPaired: Boolean` check (e.g., `pairingStore.loadSharedSecret() != null`) — the field currently doubles as a "is paired" sentinel for BLE lifecycle decisions in `ensureBleComponentsState()` and `onCreate()`. Remove all `E2ECrypto.seal`/`E2ECrypto.open` calls from clipboard path
- Handle version mismatch in `onSessionError()` — broadcast `ACTION_VERSION_MISMATCH`
- UI layer shows update dialog on version mismatch

### MessageCodec (both platforms)

- No changes — message format is unchanged, just payload content differs

### Test fixtures

- Update HELLO/WELCOME entries in `l2cap_fixture.json` for v2 payload format
- Add new crypto fixture: given fixed shared secret + fixed ephemeral key pairs → expected `auth_key`, `auth` HMAC, `ecdh_result`, and `session_key` (cross-platform compatibility)

### Session tests (both platforms)

- Update paired-session tests to provide shared secret
- Add test: v2 handshake succeeds and produces valid session key
- Add test: wrong HMAC → protocolError
- Add test: missing `ek` → protocolError
- Add test: version 1 HELLO → versionMismatch error
- Add test: two paired sessions derive identical session keys (verified by successful end-to-end clipboard transfer with session-internal encryption/decryption)

---

## What Does NOT Change

- Pairing flow (KEY_EXCHANGE / KEY_CONFIRM)
- Long-term shared secret storage (Keychain / EncryptedSharedPreferences)
- Device tag derivation and BLE advertisement format
- MessageCodec wire format (length-prefixed binary)
- Message types enum
- Clipboard monitoring and writing
- BLE connection management (ConnectionManager / Advertiser / L2capServer)
