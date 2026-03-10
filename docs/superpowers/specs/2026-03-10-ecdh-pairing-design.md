# ECDH Pairing Design

## Problem

The current pairing flow embeds a long-lived shared secret (token) directly in the QR code. Anyone who photographs the QR code can derive the encryption key and device tag, allowing them to impersonate a paired device and decrypt all clipboard traffic silently.

## Solution

Replace the static token with an ECDH key exchange. The QR code carries only the Mac's ephemeral public key. The actual encryption key is negotiated over BLE using X25519, so photographing the QR code is useless without also possessing the Android's private key.

## Protocol Overview

1. Mac generates an ephemeral X25519 key pair and displays the public key in a QR code
2. Android scans the QR, generates its own X25519 key pair
3. Android advertises over BLE with a temporary pairing tag derived from the Mac's public key
4. Mac detects the advertisement, connects, and opens an L2CAP channel
5. Android sends its public key over L2CAP
6. Both sides independently compute the ECDH shared secret
7. Mac sends an encrypted confirmation proving both sides derived the same key
8. Both sides store the shared secret and derive encryption key + device tag via HKDF
9. Session transitions to the normal HELLO/WELCOME handshake

Pairing now requires BLE proximity (both devices in range), which is reasonable since they are in the same room.

## QR Code Format

**Current:**
```
cliprelay://pair?t=<64-char hex token>&n=<device name>
```

**New:**
```
cliprelay://pair?k=<64-char hex X25519 public key>&n=<device name>
```

The `k` parameter replaces `t`. Same size (32 bytes = 64 hex chars), same QR density. The parameter name change allows both sides to detect and reject old-format URIs.

## Key Exchange Protocol

### New Message Types

```
0x03: KEY_EXCHANGE  — carries an ECDH public key
0x04: KEY_CONFIRM   — encrypted proof that key agreement succeeded
```

### Pairing Handshake (over L2CAP)

After BLE connection and L2CAP channel are established:

1. Android sends `KEY_EXCHANGE`: `{"pubkey": "<android_pubkey_hex>"}`
2. Mac computes `shared_secret = X25519(mac_private, android_public)`
3. Mac derives `encryption_key` and `device_tag` via HKDF (same parameters as today)
4. Mac sends `KEY_CONFIRM`: `E2ECrypto.seal("cliprelay-paired", encryption_key)`
5. Android computes `shared_secret = X25519(android_private, mac_public_from_qr)`
6. Android derives `encryption_key` and `device_tag` via HKDF
7. Android decrypts `KEY_CONFIRM` — if it decrypts to `"cliprelay-paired"`, pairing is confirmed
8. Both store the shared secret
9. Session continues with normal HELLO/WELCOME, ready for clipboard sync

### BLE Discovery During Pairing

Both sides compute a temporary pairing tag from the Mac's public key:

```
pairing_tag = SHA256(mac_public_key)[0:8]
```

Android advertises with this tag in manufacturer data. Mac scans for it. After pairing completes, Android switches to advertising with the permanent device tag (derived from the ECDH shared secret via HKDF).

### Post-Pairing Reconnections

Unchanged. Same HELLO/WELCOME handshake, same device tag matching, same encrypted clipboard exchange. ECDH only happens once during pairing.

## Crypto Primitives

- **ECDH curve:** X25519 (Curve25519)
- **Platform APIs:**
  - macOS: `CryptoKit.Curve25519.KeyAgreement` (macOS 10.15+)
  - Android: `KeyPairGenerator("X25519")` + `KeyAgreement("X25519")` (API 31+)
- **minSdk:** bumped from 30 to 31
- **Public key encoding:** 32 bytes raw (64 hex chars in QR)
- **HKDF:** unchanged — SHA-256, info strings `"cliprelay-enc-v1"` / `"cliprelay-tag-v1"`
- **AES-256-GCM:** unchanged
- **KEY_CONFIRM encryption:** uses existing `E2ECrypto.seal()` / `E2ECrypto.open()`

## Key Derivation

The ECDH shared secret replaces the token as the root secret. Everything downstream is identical:

- **Old:** `token` -> HKDF -> `encryption_key`, `device_tag`
- **New:** `ecdh_shared_secret` -> HKDF -> `encryption_key`, `device_tag`

## Storage

Same mechanisms, different value:

- **macOS Keychain:** `sharedSecret` (64 hex chars) per paired device, replacing `token`
- **Android EncryptedSharedPreferences:** `shared_secret` (64 hex chars), replacing `pairing_token`
- **Mac's ephemeral ECDH private key:** in-memory only during pairing window, never persisted

No migration needed. Old tokens fail tag matching silently. Users re-pair after update.

## Timeouts and Cancellation

- **Pairing handshake timeout:** 60 seconds on both sides
- **Mac pairing cancellation:** closing the QR window discards the ephemeral private key; any incoming KEY_EXCHANGE fails gracefully; Android times out
- **Android timeout:** if handshake doesn't complete in 60 seconds, stop advertising pairing tag and show error

## BLE Advertisement During Pairing

Android can only run one BLE advertisement at a time. During pairing, it temporarily replaces its normal advertisement (device tag) with the pairing tag. Existing L2CAP connections remain active. After pairing completes, Android switches to advertising the new device tag.

## Session Mode

Both `Session.swift` and `Session.kt` accept a mode parameter:

- **Normal mode:** Mac sends HELLO first, Android responds with WELCOME (unchanged)
- **Pairing mode:** Android sends KEY_EXCHANGE first, Mac responds with KEY_CONFIRM, then transitions to normal HELLO/WELCOME

## Security Properties

- **QR photograph resistance:** the QR contains only the Mac's public key, not the shared secret. An attacker cannot derive the encryption key without the Android's private key.
- **Race attack detection:** if an attacker scans the QR and pairs before the legitimate Android, the Android's pairing fails visibly. Re-pairing generates a new key pair, invalidating the attacker's session.
- **No silent compromise:** unlike the current design, there is no scenario where an attacker gains persistent access without the user noticing a pairing failure.
- **Same post-pairing security:** AES-256-GCM with HKDF key derivation, same as today.

## Backward Compatibility

None. Old `t=`-style QR codes are rejected. Old pairings fail tag matching. Users re-pair after update. This is acceptable for a pre-release product.

## Android Pairing UX Change

Pairing is no longer instant after QR scan. The Android app shows a "Pairing..." progress state while waiting for the BLE handshake to complete (a few seconds). Success is shown after KEY_CONFIRM is verified.

## Testing

- Cross-platform ECDH test vectors: known X25519 key pairs verified to produce the same shared secret and derived keys on both platforms
- Existing HKDF test vectors remain valid (derivation unchanged)
- Integration test: full pairing flow over BLE

## Changes Per Platform

### macOS

| File | Change |
|------|--------|
| `PairingManager.swift` | Generate X25519 key pair instead of random token. QR URI uses `k=`. Hold ephemeral private key in memory. Compute pairing tag from public key. |
| `ConnectionManager.swift` | Pairing mode: match on pairing tag. Normal mode: device tag matching (unchanged). |
| `Session.swift` | Handle KEY_EXCHANGE / KEY_CONFIRM in pairing mode. Compute ECDH shared secret. |
| `E2ECrypto.swift` | Add ECDH computation via `Curve25519.KeyAgreement`. HKDF unchanged. |
| `MessageCodec` | Add message types 0x03 (KEY_EXCHANGE) and 0x04 (KEY_CONFIRM). |
| `AppDelegate.swift` | Wire pairing mode: tell ConnectionManager to scan for pairing tag, handle KEY_CONFIRM success. |

### Android

| File | Change |
|------|--------|
| `PairingUriParser.kt` | Parse `k=` instead of `t=`. Same 64-hex validation. |
| `PairingStore.kt` | Store `shared_secret` instead of `pairing_token`. |
| `QrScannerActivity.kt` | Generate X25519 key pair after scan. Show "Pairing..." progress. Wait for handshake. |
| `ClipRelayService.kt` | Pairing mode: advertise with pairing tag, handle key exchange, switch to device tag. |
| `Session.kt` | Handle KEY_EXCHANGE / KEY_CONFIRM. Compute ECDH shared secret. |
| `E2ECrypto.kt` | Add ECDH computation via `KeyAgreement("X25519")`. HKDF unchanged. |
| `MessageCodec` | Add message types 0x03 and 0x04. |
| `build.gradle.kts` | `minSdk = 30` -> `31`. |

### Unchanged

UI layout code, BLE advertising structure, reconnection flow, clipboard sync protocol, AES-256-GCM encryption, HKDF parameters, device tag display in UI.
