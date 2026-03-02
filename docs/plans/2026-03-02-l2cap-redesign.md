# ClipRelay L2CAP Redesign

**Date:** 2026-03-02
**Status:** Draft
**Branch:** `l2cap`

## Goal

Redesign ClipRelay's BLE communication stack from the ground up, optimizing for connection reliability, failure tolerance, and simplicity. Replace GATT-based chunked transfers with L2CAP CoC (Connection-Oriented Channels), which provides a reliable ordered byte stream over BLE.

## Constraints

- Bluetooth Low Energy only (single radio, low power)
- Text payloads up to 100 KB
- macOS 14+ / Android 10+ (API 29+) minimum
- Asymmetric sync: Mac pushes clipboard automatically, Android sends explicitly via Share sheet

## Architecture

### Role Assignment

| Platform | BLE Role | Responsibility |
|----------|----------|----------------|
| Android  | Peripheral (GATT Server + L2CAP Listener) | Advertises, hosts PSM characteristic, accepts L2CAP connections |
| Mac      | Central (Scanner + L2CAP Initiator) | Scans, connects, reads PSM, opens L2CAP channel, owns connection lifecycle |

**Connection ownership rule:** Mac is the sole owner of the connection. It decides when to connect, reconnect, and give up. Android never initiates -- it advertises and accepts. This eliminates connection races.

**One peer, one channel:** At most one L2CAP channel per paired token at any time. If a new connection attempt arrives while a channel exists, the old channel is torn down first.

### Discovery Flow

```
Android                          Mac
  |                               |
  |  BLE Advertisement            |
  |  (Service UUID + device tag)  |
  | ----------------------------> |
  |                               | Match tag against paired tokens
  |                               |
  |        GATT Connect           |
  | <---------------------------- |
  |                               |
  |   Read PSM characteristic     |
  | <---------------------------- |
  |   Return PSM value            |
  | ----------------------------> |
  |                               |
  |   Open L2CAP Channel (PSM)    |
  | <---------------------------- |
  |                               |
  |   === Byte stream open ===    |
  |   (bidirectional, reliable)   |
```

### Why L2CAP Over GATT

L2CAP CoC gives us a TCP-like byte stream over BLE. The OS handles segmentation, flow control, and ordering. This eliminates:

- Manual chunking and reassembly
- MTU negotiation
- Notification subscription management
- Write-without-response flow control
- Ambiguous "did the write succeed?" states

Connection state becomes binary: open or closed. No half-open GATT subscription states.

### L2CAP Considerations

Based on research into the state of L2CAP CoC across devices (2025):

- **Use insecure L2CAP channels.** Secure (BLE-level encrypted) L2CAP is unreliable cross-platform. Use `listenUsingInsecureL2capChannel()` on Android and app-layer AES-256-GCM encryption.
- **PSM via GATT characteristic.** The PSM is dynamically allocated by the OS. Expose it as a read-only GATT characteristic so the central can discover it before opening the L2CAP channel.
- **Android DLE bug.** Android does not apply Data Length Extension to L2CAP CoC, limiting throughput to ~10-30 KB/s. For 100 KB payloads this means 3-10 seconds. Tolerable.
- **2-second post-connect delay on some Android devices.** Some devices need a brief delay after BLE connection before L2CAP operations work reliably.
- **Ditto (ditto.live) ships this in production** across iOS, Android, macOS -- proving the approach works at scale.

## Wire Protocol

Since L2CAP provides a reliable ordered byte stream, the protocol is minimal.

### Message Format

```
[4 bytes] message_length (uint32 BE, covers type + payload)
[1 byte]  message_type
[... ]    payload
```

5-byte header + payload. No CRC (L2CAP guarantees integrity). No per-message version field (negotiated once at session start).

### Message Types

```
Control:
  0x01  HELLO     Mac sends after L2CAP channel opens
  0x02  WELCOME   Android replies, session established

Transfer:
  0x10  OFFER     "I have clipboard content for you"
  0x11  ACCEPT    "Send it"
  0x12  PAYLOAD   The encrypted clipboard data
  0x13  DONE      "Got it, hash matches"
```

Six message types total. That is the entire protocol.

### Session Establishment (2 messages)

```
Mac                              Android
 |                                 |
 |  HELLO {version: 1}            |
 | -----------------------------> |
 |                                | Validate version
 |  WELCOME {version: 1}         |
 | <----------------------------- |
 |                                |
 |  === Session ready ===         |
```

HELLO/WELCOME confirms both sides agree on protocol version and proves the L2CAP channel works end-to-end. If WELCOME doesn't arrive within 5 seconds, tear down and reconnect.

### Clipboard Transfer (4 messages)

```
Sender                           Receiver
 |                                 |
 |  OFFER {hash, size, type}      |
 | -----------------------------> |
 |                                | Check: duplicate hash?
 |  ACCEPT {}                     |
 | <----------------------------- |
 |                                |
 |  PAYLOAD {encrypted_data}      |
 | -----------------------------> |
 |                                | Decrypt, verify hash
 |  DONE {hash, ok: true}        |
 | <----------------------------- |
```

- No chunking in the protocol. A 100 KB payload is a single PAYLOAD message. L2CAP segments internally.
- Deduplication at OFFER: if receiver already has this hash, it sends DONE immediately (skip PAYLOAD).
- Both sides can send OFFER at any time (bidirectional).
- One transfer at a time per direction (stop-and-wait). Next OFFER supersedes prior state.

### Payload Formats

```
HELLO payload (plaintext JSON):
  {"version": 1}

WELCOME payload (plaintext JSON):
  {"version": 1}

OFFER payload (plaintext JSON):
  {"hash": "<sha256-hex>", "size": 12345, "type": "text/plain"}

ACCEPT payload: empty

PAYLOAD payload (binary):
  [12-byte nonce][ciphertext + 16-byte GCM tag]

DONE payload (plaintext JSON):
  {"hash": "<sha256-hex>", "ok": true}
```

## Pairing

QR-based pre-shared token, same as today but simplified:

1. Mac generates 256-bit random token
2. Encodes URI: `cliprelay://pair?t=<64-char-hex-token>`
3. Displays QR code
4. Android scans, extracts token, stores in EncryptedSharedPreferences
5. Both sides derive:
   - **Encryption key:** `HKDF-SHA256(token, info="cliprelay-enc", len=32)`
   - **Device tag:** `SHA-256(token)[0..8]` (for advertisement matching)

No protocol version in the URI. If the protocol ever changes incompatibly, bump the URI scheme (e.g., `cliprelay2://pair`), forcing re-pairing naturally.

Device tag is stable (derived from static token). BLE address rotation does not affect discovery because the Mac identifies devices by the tag in manufacturer data, not by BLE address or CoreBluetooth peripheral UUID.

## Connection Lifecycle

### Mac States

```
Idle --> Scanning --> Connecting --> ReadingPSM --> OpeningL2CAP --> Connected
 ^                                                                     |
 |________________________ on disconnect, backoff _____________________|
```

Six states, linear progression, one backward edge. Android has no connection state machine -- it advertises and accepts.

### Reconnect Policy

- Exponential backoff: 1s, 2s, 4s, 8s, 16s, 30s (cap)
- Reset to 1s on: Bluetooth power cycle, user action, successful connection
- No retry limit -- keep trying forever with capped backoff

### Sleep / Out-of-Range Behavior

**Mac goes out of range or Android sleeps:**
1. L2CAP channel drops. Both sides get immediate disconnect callback.
2. Mac enters reconnect loop with backoff. Android keeps advertising.
3. When back in range, Mac discovers advertisement, reconnects. Fresh session.

**Mac sleeps (lid close):**
1. macOS tears down BLE on sleep.
2. On wake, `centralManagerDidUpdateState(.poweredOn)` fires. Mac resets backoff, scans immediately.

**Android killed by OS:**
1. Advertisement stops. Mac scans, finds nothing, retries with backoff.
2. When Android restarts (boot receiver or user opens app), it advertises again.

### Transfer-in-Flight Recovery

No partial resume. If a transfer is interrupted:
- Sender retains the pending payload in memory
- On reconnect, if payload is still current (clipboard hasn't changed), re-send from scratch
- Receiver deduplicates by content hash, so duplicate delivery is harmless

## Error Handling

One rule: **close and reconnect.**

Any of these trigger immediate channel teardown:
- Malformed message (bad length, unknown type)
- Decryption failure
- Timeout (5s for WELCOME, 30s for transfer completion)
- Unexpected message sequence
- Stream read/write error

No error recovery within a session. L2CAP channel setup is cheap (~1-2 seconds), so restarting is always simpler than trying to recover in-place. This eliminates half-open and confused-state bugs.

## App Architecture

### Android (Peripheral)

| Component | Responsibility |
|-----------|---------------|
| `ClipRelayService` | Foreground service. Starts/stops advertiser and GATT server. |
| `Advertiser` | BLE advertisement with service UUID + device tag. |
| `GattServer` | Single read-only characteristic: PSM value. Nothing else. |
| `L2CAPServer` | Listens for incoming L2CAP connections. Accepts one at a time. |
| `Session` | Reads/writes messages on the L2CAP stream. Owns the protocol logic. |
| `Crypto` | AES-256-GCM encrypt/decrypt. |

### macOS (Central)

| Component | Responsibility |
|-----------|---------------|
| `AppDelegate` | Lifecycle, menu bar, clipboard monitor. |
| `ConnectionManager` | Scan, connect, read PSM, open L2CAP, reconnect loop. Only component that talks to CoreBluetooth. |
| `Session` | Reads/writes messages on the L2CAP stream. Owns the protocol logic. |
| `ClipboardMonitor` | Polls NSPasteboard, triggers outbound transfers. |
| `Crypto` | AES-256-GCM encrypt/decrypt. |

### Shared Protocol Logic

`Session` is platform-agnostic. It takes a bidirectional byte stream and runs the protocol (read/write length-prefixed messages, enforce timeouts, validate message sequences). It doesn't know about BLE, GATT, scanning, or advertising. This means the protocol logic can be unit-tested with in-memory streams and zero BLE involvement.

## Out of Scope

- No heartbeat/keepalive (L2CAP supervision timeout detects dead links)
- No session resumption (every reconnect is fresh)
- No partial transfer resume (payloads are small enough to retry fully)
- No multi-device support (one paired device at a time)
- No file/image transfer (text only, max 100 KB)
- No per-message version negotiation (checked once in HELLO/WELCOME)
- No transfer IDs (one transfer at a time, stop-and-wait)
- No compression (100 KB is tiny)
- No GATT fallback (pure L2CAP; can be added later if needed)
