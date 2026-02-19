# GreenPaste — Cross-Platform Clipboard Sync (Mac <-> Android)

> Note: "GreenPaste" is a provisional product name. Keep internals generic (`clipboard-sync` / `clipshare`) so branding can be swapped later.

## Overview

GreenPaste is a clipboard synchronization tool between macOS and Android with an intentionally asymmetric UX:

- Mac -> Android is automatic.
- Android -> Mac is explicit via Android Share sheet.

Transport is BLE only. There is no cloud relay, server, or internet dependency.

## Architecture Summary

```
┌─────────────────────┐                             ┌──────────────────────┐
│   macOS Menu Bar    │         BLE (GATT)          │   Android Service    │
│       App           │◄───────────────────────────►│       + Share Target │
│                     │                              │                      │
│  - NSPasteboard     │                              │  - ClipboardManager  │
│  - CoreBluetooth    │                              │  - BLE GATT Server   │
│                     │                              │  - Foreground Svc    │
└─────────────────────┘                              └──────────────────────┘
```

### Transport

- BLE only.
- Scope is text-only clipboard sync (up to 100 KiB per transfer).
- Throughput requirements are modest for text, so reliability and simplicity take priority over maximizing bandwidth.

## Clipboard Flow

### Mac -> Android (fully automatic)

1. macOS app polls `NSPasteboard.changeCount` (default 500 ms, configurable constant).
2. On change, app reads text, computes hash, and prepares transfer metadata.
3. Mac writes metadata to the `Clipboard Available` characteristic.
4. Mac sends chunked payload frames on the `Clipboard Data` characteristic.
5. Android reassembles all chunks atomically, validates size/hash, then writes to `ClipboardManager`.

### Android -> Mac (explicit share action)

1. User taps Share on Android text content and selects GreenPaste.
2. Android service receives `ACTION_SEND` text.
3. Android sends metadata notification (`Clipboard Available`) and chunked data frames (`Clipboard Data`).
4. macOS reassembles atomically and writes to `NSPasteboard`.
5. macOS posts a brief "Clipboard received" notification.

Why explicit on Android: Android 10+ blocks background clipboard reads for privacy; Share sheet is the sanctioned path.

## BLE Protocol Design (MVP)

### GATT Service

```
Service UUID: c10b0001-1234-5678-9abc-def012345678

Characteristics:

1) Clipboard Available (bidirectional signaling)
   UUID: c10b0002-1234-5678-9abc-def012345678
   Properties: READ, WRITE, NOTIFY
   Value: UTF-8 JSON metadata
   Example: {"hash":"<sha256>","size":123,"type":"text/plain","tx_id":"<id>"}

2) Clipboard Data (bidirectional transfer)
   UUID: c10b0003-1234-5678-9abc-def012345678
   Properties: READ, WRITE, NOTIFY
   Value: Chunk header + chunk frames
```

Chunking format:

- Header frame (JSON): `{"tx_id":"...","total_chunks":N,"total_bytes":M,"encoding":"utf-8"}`
- Chunk frame: `[2-byte big-endian chunk_index][payload_bytes]`
- Payload limit: 100 KiB plain UTF-8 text.

Transfer reliability rule:

- Transfers are atomic.
- If disconnect or framing failure occurs before all chunks are received, discard the partial transfer.
- Retry only on the next full transfer after reconnect.

### BLE Connection Management

- macOS acts as BLE Central.
- Android acts as BLE Peripheral / GATT Server and advertises continuously while foreground service runs.
- Reconnect with exponential backoff on macOS (1 s, 2 s, 4 s, 8 s, max 30 s).
- Pair once via OS-native BLE Secure Connections; reconnect automatically afterward.

## Platform Implementation Details

### macOS (Swift)

App type: menu bar app (no dock icon, no main window).

Responsibilities:

- Monitor pasteboard changes (polling).
- Discover/connect to Android BLE GATT server.
- Send/receive metadata and chunked frames.
- Reassemble inbound transfers atomically.
- Write received text to clipboard.

Key APIs:

- `NSPasteboard.general.changeCount`
- `NSPasteboard.general.string(forType: .string)`
- `NSPasteboard.general.setString(_:forType:)`
- `CBCentralManager`, `CBPeripheral`
- `UNUserNotificationCenter`

Permissions:

- Bluetooth (`NSBluetoothAlwaysUsageDescription`)
- Notifications

### Android (Kotlin)

Responsibilities:

- Foreground service hosts BLE GATT server and advertising.
- Share target receives text from Android apps.
- Receive Mac transfers and write to clipboard.
- Publish Android->Mac transfers over BLE.

AndroidManifest highlights:

```xml
<uses-permission android:name="android.permission.BLUETOOTH_ADVERTISE" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
<uses-permission android:name="android.permission.BLUETOOTH_SCAN" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE" />
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />

<activity android:name=".ui.ShareReceiverActivity" android:exported="true">
    <intent-filter>
        <action android:name="android.intent.action.SEND" />
        <category android:name="android.intent.category.DEFAULT" />
        <data android:mimeType="text/*" />
    </intent-filter>
</activity>

<service android:name=".service.ClipShareService"
         android:foregroundServiceType="connectedDevice" />
```

## Security

### Pairing

- Use OS-native BLE Secure Connections pairing (numeric comparison / confirmation dialogs).
- Do not implement custom QR pairing or custom pairing token protocol for MVP.

### Encryption Model (MVP)

- Rely on BLE link-layer encryption after pairing/bonding.
- No extra app-layer encryption in MVP.
- Revisit app-layer E2E only if threat model expands (for example relay/cloud support or multi-hop transport).

### Storage

- Do not persist clipboard payloads to disk.
- Keep transfer state in memory only.

## Content Scope

- Text only (`text/plain`).
- Maximum payload: ~100 KiB UTF-8 text.
- Non-text or oversized payloads are ignored.

## Build & Tooling

### macOS

- Language: Swift
- Build: Xcode / `swift build`
- Dependencies: system frameworks only

### Android

- Language: Kotlin
- Min SDK / Target SDK: 35
- Build: Gradle (Kotlin DSL)
- Dependencies: AndroidX Core + AppCompat + Material

## Implementation Milestones

### Phase 1: Core Sync

1. Android foreground BLE GATT server + advertising.
2. macOS BLE central scan/connect/reconnect.
3. Native OS BLE pairing flow.
4. Mac clipboard polling -> Android clipboard write.
5. Android Share target -> Mac clipboard write.
6. Chunk framing/reassembly with atomic transfer discard on failure.

### Phase 2: Polish

1. Connection status UI on both platforms.
2. Robust reconnection behavior tuning.
3. Settings for auto-connect and polling interval.
4. User-visible reason for skipped payloads (optional, lightweight).

## Known Constraints & Tradeoffs

- Android -> Mac requires explicit Share action (platform privacy constraint).
- BLE range is local (~10 m typical).
- Text only.
- macOS clipboard uses polling (`changeCount`) by design.
- Default polling interval is 500 ms but should remain configurable.
- On transfer interruption/disconnect, partial payloads are discarded.
