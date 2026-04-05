# Rich Media Transfer Design

## Overview

Add image transfer between macOS and Android over TCP on the local network, using BLE for signaling. This extends ClipRelay's existing text clipboard sync with rich media support, starting with images.

**Architecture**: Receiver-as-server, sender pushes (consistent with AirDrop, Quick Share, LocalSend).

**Scope**: Images only (PNG, JPEG). macOS converts TIFF to PNG before sending (Android has no native TIFF support). Designed to be extensible to other file types in the future.

**Feature flag**: `richMediaEnabled` — per-pairing, defaults to `false`, behind an "experimental" label.

## Transfer Flow

```
Sender (has image)                          Receiver
    |                                           |
    |--- OFFER (hash, size, type, senderIp) BLE ->|
    |                                           | check: unlocked? flag enabled?
    |                                           | start TCP server on port 0
    |<-- ACCEPT (tcpHost, tcpPort) BLE ---------|
    |                                           |
    |==== TCP connect to receiver's port ======>|
    |     (receiver validates sender IP)        |
    |==== push AES-256-GCM encrypted blob ====>|
    |                                           | decrypt, verify SHA-256 hash
    |                                           | set clipboard
    |<-- DONE over BLE -------------------------|
    |                                           | close TCP server
```

Text transfers remain unchanged — entirely over BLE as today.

### Rejection Flow

If the receiver cannot or will not accept the image:

```
Sender                                      Receiver
    |--- OFFER (image) BLE ---------------->|
    |                                       | reason: locked, flag off, etc.
    |<-- REJECT (reason) BLE ---------------|
```

### Error Flow

If something goes wrong during transfer:

```
Sender                                      Receiver
    |--- OFFER BLE ----------------------->|
    |<-- ACCEPT (tcpHost, tcpPort) BLE ----|
    |==== TCP connect =====================>|
    |     (connection fails or times out)   |
    |--- ERROR BLE ----------------------->|  (so receiver tears down TCP server)
    |                                       |
    --- OR ---
    |                                       |
    |==== push blob ======================>|
    |                                       | hash mismatch
    |<-- ERROR BLE ------------------------|
```

## Directionality

Both directions supported in v1:

- **Mac → Android**: Mac detects image on pasteboard (polling), auto-sends OFFER. Android must be unlocked and awake to accept (`PowerManager.isInteractive()`, `KeyguardManager.isDeviceLocked()`).
- **Android → Mac**: User explicitly shares image via Android share sheet. Mac always accepts (no lock/sleep check — Mac is typically always-on at a desk, and the image just lands on the pasteboard silently).

## Feature Flag & Config Sync

### Storage

- Per-pairing setting: `richMediaEnabled` (boolean) + `richMediaEnabledChangedAt` (Unix timestamp)
- Stored alongside existing pairing data on both platforms
- Defaults to `false`

### Initial Sync (Session Establishment)

Both sides include settings in HELLO/WELCOME. The settings object is added alongside the existing fields (`ek`, `auth`, `name`):

```json
{
  "ek": "...",
  "auth": "...",
  "name": "My Device",
  "settings": {
    "richMediaEnabled": true,
    "richMediaEnabledChangedAt": 1773698112
  }
}
```

Protocol version remains 2 — `settings` is optional and ignored by older clients that parse only known fields.

Last-write-wins: both sides compare `richMediaEnabledChangedAt` timestamps, the newer value wins, both persist the result.

### Mid-Session Update

Toggling the flag sends a CONFIG_UPDATE message over BLE:

```json
{
  "richMediaEnabled": false,
  "richMediaEnabledChangedAt": 1773699000
}
```

The other side persists immediately. If a transfer is in-flight, it completes — the flag change takes effect on the next transfer. Specifically, the receiver checks `richMediaEnabled` once at OFFER time; a CONFIG_UPDATE arriving between OFFER and DONE does not affect the in-flight transfer.

### UI

Toggle in settings on both platforms, next to existing auto-copy toggle. Label: "Image sync (experimental)".

## Protocol Changes

### New Message Types

| Code | Type | Purpose |
|------|------|---------|
| 0x14 | CONFIG_UPDATE | Settings sync mid-session |
| 0x15 | REJECT | Intentional refusal with reason code |
| 0x16 | ERROR | Something broke, with error code |

### Modified Messages

**HELLO / WELCOME** — add optional `settings` object:

```json
{
  "settings": {
    "richMediaEnabled": true,
    "richMediaEnabledChangedAt": 1773698112
  }
}
```

**OFFER** — for rich media, the existing `type` field carries the MIME type (currently `text/plain` for text). New optional fields:

```json
{
  "hash": "sha256hex...",
  "size": 2048576,
  "type": "image/png",
  "senderIp": "192.168.1.10"
}
```

- `type` value starting with `image/` distinguishes image OFFER from text OFFER (text uses `text/plain`)
- `size` is plaintext size in bytes (used for 10MB limit check). Note: existing text OFFERs send encrypted size in `size`; for image OFFERs this is plaintext size since the receiver needs it to compute expected TCP bytes (`size + 28` GCM overhead). This inconsistency is acceptable since the two flows are clearly distinguished by `type`.
- `hash` is SHA-256 hex of plaintext image data
- `senderIp` is the sender's LAN IPv4 address, used by the receiver for TCP IP validation. BLE does not expose peer IP, so it must be sent explicitly.

**ACCEPT** — add optional fields for rich media:

```json
{
  "tcpHost": "192.168.1.5",
  "tcpPort": 54321
}
```

- Presence of `tcpHost`/`tcpPort` signals receiver's TCP server is ready

**REJECT** — new message:

```json
{
  "reason": "device_locked"
}
```

Reason codes: `device_locked`, `feature_disabled`, `size_exceeded`, `storage_full` (future).

**ERROR** — new message:

```json
{
  "code": "transfer_failed",
  "message": "optional human-readable detail"
}
```

Error codes: `transfer_failed`, `hash_mismatch`, `timeout`, `connection_failed`, `server_start_failed`.

**DONE** — unchanged format (`{"hash": "...", "ok": true}`). For image transfers, DONE is sent over the same BLE L2CAP channel as all other signaling messages. The TCP connection is used exclusively for the encrypted image blob; all protocol messages go over BLE.

**Unchanged**: KEY_EXCHANGE, KEY_CONFIRM, PAYLOAD.

### Backward Compatibility

**Important**: The current `MessageCodec` on both platforms throws an exception on unknown message types. This must be updated to log a warning and skip unknown types before shipping new message types. Without this fix, sending CONFIG_UPDATE/REJECT/ERROR to an older client will crash its session.

Additionally, the session-level message handlers (`handleInbound` on both platforms) throw on unexpected message types. These must also be updated to log and ignore unknown types, not just the codec.

After both fixes: older clients will silently ignore new message types. Rich media requires both sides to have `richMediaEnabled` negotiated in HELLO/WELCOME, so an old client (no flag support) simply means rich media stays off.

## Encryption

- **Algorithm**: AES-256-GCM with existing session key (same as text)
- **Approach**: Single-blob encryption (entire image encrypted as one unit)
- **Wire format**: `[12-byte nonce][ciphertext][16-byte auth tag]` — same layout as existing `E2ECrypto.seal()` output
- **GCM overhead**: 12 + 16 = 28 bytes
- **Encrypted size**: `plaintext_size + 28` (deterministic, both sides compute from OFFER `size`)
- **Limitation**: Single-blob requires holding the full image in memory. Acceptable for 10MB max. Streaming encryption must be added when video/large file support is introduced.

## TCP Server Lifecycle

### Startup

Receiver starts TCP server after receiving an image OFFER:
- Bind to port 0 (OS-assigned random port)
- Report assigned port + LAN IP in ACCEPT message

### IP Validation

When a TCP connection arrives, check source IP against the `senderIp` from the OFFER message. Reject mismatched IPs immediately. This is a fast-reject optimization — the real security is AES-256-GCM encryption (attacker without session key cannot forge a valid blob).

### Timeouts

- **No connection timeout**: 30 seconds. If no TCP client connects within 30s of server start, shut down and send ERROR over BLE.
- **Transfer timeout**: 120 seconds from first byte received. Covers large images on slow networks.

### Cleanup

TCP server is torn down on whichever comes first:
1. Transfer completes successfully (happy path)
2. No connection timeout (30s)
3. Transfer timeout (120s)
4. BLE session disconnects
5. ERROR received from sender
6. New OFFER received (implicit cancellation of current transfer — see Concurrent Transfer Handling)

The server never lingers.

## TCP Data Framing

The receiver knows the exact encrypted blob size: `OFFER.size + 28` (GCM overhead). It reads exactly that many bytes from the TCP socket. This allows distinguishing a complete transfer from a dropped connection.

No length prefix or other framing is needed — it's a dedicated connection for a single transfer.

## Network Reachability

**Approach**: Fail-fast. No proactive network checks. Just try the TCP connection.

1. Sender sends OFFER over BLE
2. Receiver starts TCP server, sends ACCEPT with host/port
3. Sender attempts TCP connection (3s connect timeout)
4. If connection fails, sender retries once (fresh connection, same host/port)
5. If retry fails:
   - **Auto-sync** (Mac clipboard copy): silently drop
   - **Explicit share** (Android share sheet): show error: *"Could not transfer image. Make sure both devices are on the same Wi-Fi network."*
6. Sender sends ERROR over BLE so receiver tears down TCP server immediately

## Echo Loop Prevention

Both platforms track `lastReceivedHash`. When an image is received and written to clipboard:
1. Set `lastReceivedHash = hash`
2. When local clipboard changes, compute hash of the raw image bytes and compare against `lastReceivedHash`
3. If match, skip sending (it's our own write echoing back)

This prevents: Mac sends image → Android writes to clipboard → Android clipboard listener fires → would send back to Mac → infinite loop.

**Hash computation**: Hash the raw image bytes as they would be sent over TCP (i.e. the PNG/JPEG data, not a re-encoded representation). On macOS, read the pasteboard's PNG or JPEG representation directly. On Android, read the raw bytes from the content URI. This avoids hash mismatches from OS re-encoding.

**Trade-off**: If the user independently copies the exact same image on both devices simultaneously, the dedup would suppress the send. This is an acceptable false negative for a rare edge case.

## Concurrent Transfer Handling

Only one image transfer can be in-flight at a time per session. If a new image OFFER arrives while a transfer is active, the current transfer is cancelled — the receiver tears down the active TCP server, discards any partial data, and processes the new OFFER. The latest clipboard state is what matters; if the user copies image A then immediately copies image B, they want image B on the other device.

On the sender side: if a new clipboard image is detected while a previous transfer is in-flight, the sender sends a new OFFER immediately. The receiver treats the new OFFER as an implicit cancellation of the previous transfer.

## Local IP Address Selection

Both platforms need `getLocalIpAddress()` to report in OFFER (`senderIp`) and ACCEPT (`tcpHost`):
- **Android**: Iterate `NetworkInterface`, select the Wi-Fi interface IP (not cellular, not VPN, not loopback). Filter for non-loopback IPv4 addresses on `wlan*` interfaces.
- **macOS**: Iterate network interfaces, select `en0`/`en1` (Wi-Fi). Filter for non-loopback IPv4.
- **IPv4 only** for v1. IPv6 LAN support can be added later.
- **Freshness**: Both sender and receiver should read their LAN IP at message time (OFFER/ACCEPT), not cache from session start. IP can change if the device switches Wi-Fi networks mid-session.

## Platform Integration

### Android

**Sender (share sheet)**:
- `ShareReceiverActivity` handles `ACTION_SEND` for `image/*` MIME types
- Validate size ≤ 10MB; show error if exceeded
- If no active BLE session or rich media disabled → show error: *"Image sync is not available. Make sure ClipRelay is connected and image sync is enabled."*
- Copy image to cache (avoid Binder transaction limits), pass to service
- Service initiates OFFER flow

**Receiver (from Mac)**:
- On image OFFER → check `isInteractive()` and `!isDeviceLocked()`
- If locked/sleeping → send REJECT with `device_locked`
- Otherwise → start TCP server, send ACCEPT, receive blob, decrypt, verify hash
- Write image to temp file in app cache, then set clipboard with `content://` URI via FileProvider (Android clipboard requires a content URI for images, not raw bytes)

### macOS

**Sender (clipboard)**:
- ClipboardMonitor detects PNG, JPEG, or TIFF on pasteboard (TIFF is converted to PNG before sending)
- If rich media disabled or no active session → skip
- Deduplicate against `lastReceivedHash`
- Initiate OFFER → connect to receiver's TCP server → push encrypted blob

**Receiver (from Android)**:
- On image OFFER → start TCP server, send ACCEPT
- Validate sender IP on incoming connection
- Receive blob → decrypt → verify hash → set pasteboard (NSImage data)
- Tear down TCP server

### Entitlements & Permissions

- **macOS**: `com.apple.security.network.server` and `.client` (already present)
- **Android**: `INTERNET` permission (already present), `image/*` in share intent filter

## Error Handling Summary

| Scenario | Behavior |
|----------|----------|
| TCP connection fails (both attempts) | Auto-sync: silent drop. Share sheet: show error |
| Hash mismatch after decrypt | Receiver discards, sends ERROR over BLE |
| Image > 10MB via share sheet | Show error on Android before transfer |
| Image > 10MB via clipboard | Silently skip |
| BLE disconnects mid-transfer | TCP server hits timeout, cleans up |
| TCP server fails to start | Send ERROR instead of ACCEPT |
| Receiver locked (Mac → Android) | Send REJECT with `device_locked` |
| Rich media disabled | Sender skips OFFER entirely (checked locally) |
| No BLE session (share sheet) | Show error in ShareReceiverActivity |
| New OFFER during active transfer | Cancel current transfer, process new OFFER |

## Size Limits

- **Maximum image size**: 10 MB (plaintext)
- **Intentional design constraint**: Single-blob encryption requires holding full image in memory. This must be revisited with streaming encryption when video or large file support is added.

## Future Extensibility

The design supports future expansion:
- **Other file types**: Add new `type` values (e.g. `application/pdf`, `video/mp4`). Transport layer is content-agnostic.
- **Explicit send for large files**: Future file types that require explicit user action (not auto-sync) can use the same OFFER/ACCEPT/TCP flow, gated by content type and size thresholds.
- **Streaming encryption**: Replace single-blob AES-256-GCM with chunked encryption for files > 10MB. Requires a framing protocol on TCP (chunk length + encrypted chunk + auth tag per chunk).
- **Progress indication**: Out of scope for v1. Could be added by having the receiver send periodic progress messages over BLE, or by the sender tracking bytes written to TCP.
- **IPv6**: Replace IPv4-only `getLocalIpAddress()` with dual-stack support.
