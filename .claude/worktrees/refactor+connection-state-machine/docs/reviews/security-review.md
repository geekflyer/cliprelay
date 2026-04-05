# ClipRelay Security Review

**Date:** 2026-03-15 (updated from 2026-03-03)
**Scope:** Full codebase — crypto/protocol, macOS app, Android app, website, scripts

---

## Executive Summary

ClipRelay implements a BLE-based clipboard relay between macOS and Android using AES-256-GCM encryption with HKDF-derived keys, shared via a QR code pairing flow. The cryptographic primitives are well-chosen and correctly implemented. The protocol v2 handshake provides per-session forward secrecy and mutual HMAC authentication. No immediately exploitable remote vulnerabilities were found — all attacks require BLE proximity or local access.

### Changes since last review (2026-03-03)

- **Removed (fixed):** H-3 (debug file logger to `/tmp`) — `debugLog()` replaced with `os.Logger` exclusively.
- **Removed (fixed):** H-1 (unauthenticated handshake) — protocol v2 adds HMAC-SHA256 mutual authentication in HELLO/WELCOME. Rogue devices are rejected at handshake.
- **Removed (fixed):** M-11 (no forward secrecy) — protocol v2 adds per-session ephemeral X25519 key exchange. Session keys are derived from both the long-term shared secret and an ephemeral ECDH result. Ephemeral private keys are discarded immediately after derivation.
- **Downgraded:** Old H-1 (replay protection) to L-10. Impact limited to stale clipboard text; largely subsumed by forward secrecy (captured frames from prior sessions are undecryptable).
- **Removed (fixed):** L-7 `PsmGattServer.kt` reference — file no longer exists. Updated to reference only `ClipRelayService.kt`.
- Renumbered: H-4→H-1 (insecure L2CAP, accepted risk).

---

## Findings

### MEDIUM

#### M-0: Insecure L2CAP channel (no BLE-level encryption) — ACCEPTED RISK

**Files:** `android/.../ble/L2capServer.kt:30`

Uses `adapter.listenUsingInsecureL2capChannel()`. This is an intentional design choice (app-layer AES-256-GCM provides encryption), but the BLE link layer is unencrypted. Traffic metadata (message sizes, timing) is visible to nearby observers, and active MITM can selectively drop or delay messages.

**Resolution:** Accepted risk. Using the secure L2CAP variant would require BLE bonding, which adds UX friction and compatibility issues across Android versions. App-layer AES-256-GCM provides strong confidentiality and integrity guarantees.

#### M-1: HKDF used without salt on both platforms — ACCEPTED

**Files:** `macos/.../Crypto/E2ECrypto.swift:21-28`, `android/.../crypto/E2ECrypto.kt:93-116`

Both HKDF implementations use no salt (macOS omits it; Android uses all-zeros). Per RFC 5869 this is acceptable when IKM has high entropy (256 bits here), but best practice is to use an application-specific salt.

**Resolution:** Accepted risk. With 256-bit IKM, RFC 5869 confirms salt is optional when input key material has sufficient entropy. Adding a salt would break existing pairings for zero practical security gain.

#### M-2: ~~Notification preview leaks clipboard content~~ — FIXED

**Files:** `android/.../service/ClipboardWriter.kt:26-28`

~~The notification body contains `String(text.prefix(80))` — the first 80 characters of received clipboard text. Visible on the lock screen by default.~~

**Resolution:** Text clipboard writes are marked with `ClipDescription.EXTRA_IS_SENSITIVE`, which tells Android to redact the content preview in the system clipboard overlay. Image clipboard writes are left unredacted.

#### M-3: SecItemUpdate path doesn't set kSecAttrAccessible

**Files:** `macos/.../Security/KeychainStore.swift:28-46`

Only the `SecItemAdd` code path sets `kSecAttrAccessible`. The `SecItemUpdate` path preserves whatever accessibility level the item was originally created with.

**Fix:** Include `kSecAttrAccessible` in the update attributes dictionary.

#### M-4: CLIPRELAY_POLL_INTERVAL_MS env var active in release

**Files:** `macos/.../Clipboard/ClipboardMonitor.swift:7-16`

The environment variable is read unconditionally with no `#if DEBUG` guard. An attacker with local access could set this env var to manipulate clipboard polling frequency.

**Fix:** Guard behind `#if DEBUG`.

#### M-5: No payload size validation before ACCEPT

**Files:** `macos/.../Protocol/Session.swift:290-329`, `android/.../protocol/Session.kt:283-324`

When an OFFER is received, the `size` field is never inspected before sending ACCEPT. The receiver blindly accepts any OFFER regardless of claimed payload size. The 200KB codec-level max provides some protection, but the application-level 100KB limit is not enforced at the protocol layer.

**Fix:** Validate `size` against `MAX_CLIPBOARD_BYTES` before sending ACCEPT.

#### M-6: DebugSmokeReceiver exported without permission guard

**Files:** `android/app/src/debug/AndroidManifest.xml:4-12`

The receiver is `android:exported="true"` with no `android:permission` attribute. Since it's in `src/debug/`, it only ships in debug APKs, limiting risk to developer devices. Any app on a debug device can send `IMPORT_PAIRING` / `CLEAR_PAIRING` intents to inject or wipe pairing secrets.

**Fix:** Add `android:permission="org.cliprelay.permission.DEBUG_SMOKE"` with `protectionLevel="signature"`.

#### M-7: BootCompletedReceiver missing sender permission check

**Files:** `android/app/src/main/AndroidManifest.xml:65-72`

The receiver is `exported="true"` (required for BOOT_COMPLETED) but any app can send a crafted `BOOT_COMPLETED` intent to start the foreground service.

**Fix:** Add `android:permission="android.permission.RECEIVE_BOOT_COMPLETED"`.

#### M-8: registerReceiver missing RECEIVER_NOT_EXPORTED

**Files:** `android/.../service/ClipRelayService.kt:138`

Uses legacy `registerReceiver()` without `RECEIVER_NOT_EXPORTED` flag. On Android 14+ targeting API 34+, this will crash with a `SecurityException`.

**Fix:** Use `ContextCompat.registerReceiver()` with `RECEIVER_NOT_EXPORTED`.

#### M-9: No Content Security Policy on website

**Files:** `website/index.html`, `website/privacy.html`

No `<meta http-equiv="Content-Security-Policy">` tag. The site is static with no XSS vectors today, but CSP provides defense-in-depth.

**Fix:** Add a CSP meta tag restricting `default-src 'none'` with allowlists for styles, fonts, scripts, and images.

#### M-10: Google Fonts loaded without SRI / not self-hosted

**Files:** `website/index.html:23`

External CSS from `fonts.googleapis.com` without `integrity` attribute. SRI is impractical for Google Fonts (response varies by user agent). Also a privacy concern — every visitor's IP is sent to Google, inconsistent with the privacy-first branding.

**Fix:** Self-host the Inter and Outfit WOFF2 files.

---

### LOW

| # | Finding | Location |
|---|---------|----------|
| L-1 | Static BLE device tag (8-byte HKDF derivative) enables location tracking across sessions | `Advertiser.kt`, `ConnectionManager.swift` |
| L-2 | Android HKDF counter is a signed `Byte` — overflow potential if deriving >8160 bytes | `E2ECrypto.kt:104` |
| L-3 | Non-constant-time hash comparison (not practically exploitable over BLE) | `Session.swift`, `Session.kt` |
| L-4 | Keychain `kSecAttrAccessibleAfterFirstUnlock` could use `WhenUnlockedThisDeviceOnly` | `KeychainStore.swift:42` |
| L-5 | `PeerSummary.secret` carries raw shared secret through UI layer | `PeerSummary.swift:8` |
| L-6 | BLE manufacturer data uses reserved company ID `0xFFFF` | `Advertiser.kt:94` |
| L-7 | `Log.w` statements expose PSM and connection state in release logcat | `ClipRelayService.kt` |
| L-8 | ProGuard rules file is empty — no log stripping configured | `android/app/proguard-rules.pro` |
| L-9 | `security-crypto` uses alpha version `1.1.0-alpha06` | `android/app/build.gradle.kts:173` |
| L-10 | No explicit replay protection at protocol layer — attacker in BLE range could replay captured ciphertext within the same session. Impact limited to stale clipboard text reappearing. Mitigated by AES-GCM random nonces, single-hash dedup, and forward secrecy (captured frames from prior sessions are undecryptable with different session keys). Comparable apps (KDE Connect, etc.) do not implement bespoke replay protection either. | `Session.swift`, `Session.kt` |

---

## What's Done Well

- **AES-256-GCM** with HKDF domain separation (`cliprelay-enc-v1`, `cliprelay-tag-v1`, `cliprelay-auth-v2`, `cliprelay-session-v2`) and AAD (`cliprelay-v2`)
- **Per-session forward secrecy** — ephemeral X25519 key exchange on every HELLO/WELCOME handshake; session keys derived from long-term secret + ephemeral ECDH; ephemeral private keys discarded immediately after derivation
- **HMAC-SHA256 mutual authentication** — both sides prove possession of the shared secret during handshake; rogue devices rejected before any clipboard data flows
- **Constant-time HMAC verification** — `MessageDigest.isEqual()` (Android), `HMAC.isValidAuthenticationCode()` (macOS)
- **X25519 ECDH** pairing with ephemeral keys cleared after use
- **KEY_CONFIRM verification** — encrypted known plaintext proves both sides derived the same key, preventing silent MITM during pairing
- **Cross-platform test vectors** for crypto interoperability (golden fixtures for v1 ECDH and v2 session key derivation)
- **Version mismatch UX** — both platforms detect protocol version incompatibility and prompt users to update
- **`android:allowBackup="false"`**, package-scoped broadcasts, unexported services
- **`os.Logger`** used exclusively on macOS (no file-based debug logging)
- **No XSS vectors** in website JS — zero `innerHTML`/`eval`/`document.write` usage
- **All shell scripts** use `set -euo pipefail` with properly quoted variables
- **No hardcoded secrets** anywhere in the codebase
- **Sensitive files** (keystores, service accounts, signing configs) properly `.gitignored`
- **Message size limits** (200KB codec cap, 100KB clipboard cap on send side)
- **Protocol timeouts** on all handshake (5s) and transfer (30s) operations
- **EncryptedSharedPreferences** as primary storage for Android pairing token
- **`neverForLocation`** flag on `BLUETOOTH_SCAN` permission
- **SHA-256 integrity check** on received payloads
- **ProGuard/R8** enabled for Android release builds

---

## Recommended Priority Order

### Quick wins

1. **M-4** — Guard poll interval env var behind `#if DEBUG`
2. **M-8** — Fix `registerReceiver` to use `RECEIVER_NOT_EXPORTED`

### Moderate effort

4. **M-3** — Include `kSecAttrAccessible` in Keychain update path
5. **M-5** — Validate OFFER size before ACCEPT
6. **M-9** — Add CSP meta tags to website
7. **M-10** — Self-host Google Fonts

### Done

- ~~**H-1** — Mutual authentication~~ — Fixed in protocol v2 (HMAC-SHA256 in HELLO/WELCOME)
- ~~**M-11** — Forward secrecy~~ — Fixed in protocol v2 (per-session ephemeral X25519 ECDH)
- ~~**M-2** — Clipboard preview leak~~ — Fixed with `EXTRA_IS_SENSITIVE` on text clipboard writes
