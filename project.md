# ClipRelay — Cross-Platform Clipboard Sync (Mac ↔ Android)

> Note: ClipRelay is the product name. Internals use `cliprelay` for consistency.

## Overview

ClipRelay is a clipboard synchronization tool between macOS and Android with an intentionally asymmetric UX:

- Mac → Android is automatic.
- Android → Mac is explicit via Android Share sheet.

Transport is BLE only. There is no cloud relay, server, or internet dependency.

## Architecture Summary

```
┌──────────────────────────┐                             ┌───────────────────────────┐
│   macOS Menu Bar App     │         BLE (GATT)          │   Android Service         │
│   (BLE Central)          │◄───────────────────────────►│   (BLE Peripheral/Server) │
│                          │                              │   + Share Target          │
│  - NSPasteboard polling  │                              │  - ClipboardManager       │
│  - CoreBluetooth Central │                              │  - BLE GATT Server        │
│  - E2E encryption        │                              │  - Foreground Service     │
│  - QR code pairing       │                              │  - QR code scanner        │
│  - Status bar menu       │                              │  - Share receiver toast   │
└──────────────────────────┘                              └───────────────────────────┘
```

### Transport

- BLE only.
- Text-only clipboard sync (up to 100 KiB per transfer).
- Chunk size: 509 bytes per BLE frame.
- Throughput requirements are modest for text; reliability and simplicity take priority over bandwidth.

## Clipboard Flow

### Mac → Android (fully automatic)

1. macOS app polls `NSPasteboard.changeCount` (default 500 ms, configurable via `CLIPRELAY_POLL_INTERVAL_MS` env var, minimum 100 ms).
2. On change, reads text, computes SHA-256 hash, deduplicates against last sent hash.
3. Encrypts plaintext with AES-256-GCM using the shared key derived from the pairing token.
4. Writes metadata JSON to the `Clipboard Available` characteristic.
5. Sends chunked encrypted payload on the `Clipboard Data` characteristic (header frame + 509-byte chunk frames with 10 ms inter-frame delay).
6. Android reassembles all chunks atomically, verifies hash against metadata, decrypts, deduplicates, then writes to `ClipboardManager`.

### Android → Mac (explicit share action)

1. User taps Share on Android text content and selects ClipRelay.
2. `ShareReceiverActivity` receives `ACTION_SEND`, forwards text to `ClipRelayService`.
3. A toast shows "Sent to \<device_name\>" (e.g. "Sent to christian's Laptop").
4. Service encrypts, chunks, and sends metadata + data frames via BLE notifications.
5. macOS reassembles, decrypts, writes to `NSPasteboard`, and posts a user notification ("Clipboard received from Android" with text preview).
6. Because Mac → Android sync is automatic to all currently connected paired Android devices, this can fan out to additional Android devices that are connected to the same Mac.

Why explicit on Android: Android 10+ blocks background clipboard reads for privacy; Share sheet is the sanctioned path.

## BLE Protocol Design

### GATT Service

```
Service UUID: c10b0001-1234-5678-9abc-def012345678

Characteristics:

1) Clipboard Available (bidirectional signaling)
   UUID: c10b0002-1234-5678-9abc-def012345678
   Properties: READ, WRITE, WRITE_NO_RESPONSE, NOTIFY
   Value: UTF-8 JSON metadata
   Example: {"hash":"<sha256>","size":123,"type":"text/plain","tx_id":"<uuid>"}

2) Clipboard Data (bidirectional transfer)
   UUID: c10b0003-1234-5678-9abc-def012345678
   Properties: READ, WRITE, WRITE_NO_RESPONSE, NOTIFY
   Value: Chunk header + chunk frames
```

Chunking format:

- Header frame (JSON): `{"tx_id":"...","total_chunks":N,"total_bytes":M,"encoding":"utf-8"}`
- Chunk frame: `[2-byte big-endian chunk_index][payload_bytes]` (max 509 bytes payload per chunk)
- Payload limit: 100 KiB plain UTF-8 text (102,400 bytes).

Transfer reliability:

- Transfers are atomic.
- If disconnect or framing failure occurs before all chunks are received, discard the partial transfer.
- Retry only on the next full transfer after reconnect.

### BLE Connection Management

- macOS acts as BLE Central.
- Android acts as BLE Peripheral / GATT Server and advertises continuously while foreground service runs.
- Android advertisement includes service UUID in primary ad, and device name + manufacturer data (8-byte device tag) in scan response.
- macOS identifies paired Android devices by matching the 8-byte device tag (first 8 bytes of SHA-256 of pairing token) in manufacturer data.
- Reconnect with exponential backoff on macOS (1 s → 2 s → 4 s → 8 s → max 30 s), resets on Bluetooth toggle.
- BLE stack recovery: both platforms detect Bluetooth toggle and restart GATT/advertising when Bluetooth re-enables.

## Security

### Pairing

- QR-code-based pairing: Mac generates a 256-bit random token, encodes it as a QR code URI.
- URI format: `cliprelay://pair?t=<64-char-hex-token>&n=<mac-computer-name>`
- Android scans QR code, validates and stores the token.
- Both sides derive an identical AES-256 key from the shared token.
- Device identification: first 8 bytes of SHA-256(token) used as a device tag in BLE manufacturer data for mutual recognition.

### Encryption

- App-layer E2E encryption on every transfer using AES-256-GCM.
- Key derivation: `SHA-256(token_bytes)` → 256-bit AES key.
- Nonce: 12 bytes generated per encryption (prepended to ciphertext).
- Authenticated associated data (AAD): `"cliprelay-v1"`.
- Ciphertext format: `[12-byte nonce][ciphertext + 16-byte GCM tag]`.

### Storage

- Pairing tokens stored securely:
  - macOS: Keychain (`KeychainStore`)
  - Android: `EncryptedSharedPreferences` (AES-256-GCM), with fallback to standard SharedPreferences
- Clipboard payloads are never persisted to disk; transfer state is in-memory only.

## Platform Implementation Details

### macOS (Swift)

App type: menu bar app (no dock icon, no main window; `LSUIElement = true`).

Source files (`macos/ClipRelayMac/Sources/`):

| File | Role |
|------|------|
| `App/AppDelegate.swift` | Entry point; orchestrates BLE, clipboard, pairing, notifications, status bar |
| `App/StatusBarController.swift` | Menu bar UI: connection status, device list, pair/forget actions |
| `App/ReceiveNotificationManager.swift` | Posts user notifications on clipboard receive |
| `BLE/BLECentralManager.swift` | BLE scanning, connecting, reconnect, data transfer |
| `BLE/ChunkAssembler.swift` | Reassembles chunked BLE frames into complete payloads |
| `Clipboard/ClipboardMonitor.swift` | Polls NSPasteboard every 500 ms, triggers sends on change |
| `Clipboard/ClipboardWriter.swift` | Writes received text to system pasteboard |
| `Crypto/E2ECrypto.swift` | AES-256-GCM encrypt/decrypt |
| `Pairing/PairingManager.swift` | Token generation, key derivation, device tag, keychain persistence |
| `Pairing/PairingWindowController.swift` | QR code display window for pairing |
| `Security/KeychainStore.swift` | Keychain read/write helper |

Key APIs: `CBCentralManager`, `CBPeripheral`, `NSPasteboard`, `UNUserNotificationCenter`, `CIQRCodeGenerator`

Menu bar UI:
- Status icon: green-tinted when connected, gray when disconnected.
- Menu: paired device list (with connection dots), "Pair New Device..." (⌘N), "Quit" (⌘Q).
- Each device has a "Forget Device" submenu option.

### Android (Kotlin)

Source files (`android/app/src/main/java/com/cliprelay/`):

| File | Role |
|------|------|
| `ui/MainActivity.kt` | Main UI; shows pairing status ("Connected to \<name\>"), pair/unpair buttons |
| `ui/QrScannerActivity.kt` | ML Kit barcode scanner for QR pairing |
| `ui/ShareReceiverActivity.kt` | Share target; sends text to service, shows "Sent to \<name\>" toast |
| `service/ClipRelayService.kt` | Foreground service; manages BLE server, encryption, data transfer |
| `service/ClipboardWriter.kt` | Writes received text to system ClipboardManager |
| `service/BootCompletedReceiver.kt` | Auto-starts service on device boot |
| `ble/GattServerManager.kt` | GATT server setup and characteristic management |
| `ble/GattServerCallback.kt` | Handles BLE read/write/notify requests |
| `ble/Advertiser.kt` | BLE advertising with service UUID + device tag |
| `ble/ChunkTransfer.kt` | Chunk framing utilities (header + chunk creation) |
| `ble/ChunkReassembler.kt` | Reassembles inbound chunk frames into complete payloads |
| `crypto/E2ECrypto.kt` | AES-256-GCM encrypt/decrypt, key derivation, device tag |
| `pairing/PairingStore.kt` | EncryptedSharedPreferences for token storage |
| `pairing/PairingUriParser.kt` | Parses `cliprelay://pair?t=...&n=...` URIs |

Permissions: `BLUETOOTH_ADVERTISE`, `BLUETOOTH_CONNECT`, `BLUETOOTH_SCAN`, `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_CONNECTED_DEVICE`, `POST_NOTIFICATIONS`, `RECEIVE_BOOT_COMPLETED`

Service communication: `ClipRelayService` broadcasts `ACTION_CONNECTION_STATE` with connection status and device name; `MainActivity` listens via `BroadcastReceiver`.

## Build & Tooling

### Build Script

`scripts/build-all.sh` builds both platforms and outputs to `dist/`:

```bash
./scripts/build-all.sh              # Build both
./scripts/build-all.sh --mac-only   # macOS only
./scripts/build-all.sh --android-only  # Android only
```

Outputs:
- `dist/ClipRelay.app` — macOS app bundle
- `dist/cliprelay-debug.apk` — Android debug APK

Hardware smoke helpers:

```bash
./scripts/hardware-smoke-test.sh   # Automated BLE smoke test (includes pairing import)
```

### macOS

- Language: Swift
- Build: Swift Package Manager (`swift build -c release`)
- Package path: `macos/ClipRelayMac/`
- Dependencies: system frameworks only (CoreBluetooth, CryptoKit, Foundation, AppKit, UserNotifications)

### Android

- Language: Kotlin
- Min SDK: 29 / Target SDK: 35
- Build: Gradle (Kotlin DSL)
- Dependencies: AndroidX Core + AppCompat + Material, ML Kit Barcode Scanning

## Known Constraints & Tradeoffs

- Android → Mac requires explicit Share action (platform privacy constraint).
- Android system clipboard UI differs by OS version; newer Android versions may show clipboard overlays while Android 10 may show none. ClipRelay does not post per-transfer clipboard notifications.
- Multi-device fan-out is currently expected: Android → Mac updates can propagate to other connected Android devices via the Mac clipboard loop.
- BLE range is local (~10 m typical).
- Text only (100 KiB max).
- macOS clipboard uses polling (`changeCount`) by design.
- Default polling interval is 500 ms (configurable via env var, minimum 100 ms).
- On transfer interruption/disconnect, partial payloads are discarded.
- BLE device name is unreliable for display; device name is captured from QR code at pairing time.
