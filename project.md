# GreenPaste — Cross-Platform Clipboard Sync (Mac ↔ Android)

> **Note:** The project name "GreenPaste" is provisional. Keep it loosely coupled — use a generic internal name like `clipboard-sync` or `clipshare` for package names, directory structures, and variable names. The user-facing name can be swapped later without refactoring internals.

## Overview

GreenPaste is a clipboard synchronization tool between macOS and Android. It replicates the UX of Apple's Universal Clipboard but works across platforms. The design is intentionally asymmetric due to Android's clipboard access restrictions.

**Target devices:**
- MacBook Pro (M1 Max), macOS Tahoe 26.1+, Bluetooth 5.0
- Pixel 10 Pro XL, Android 16+, Bluetooth 5.4

---

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

**BLE only.** No cloud relay, no server, no internet dependency. This is a deliberate security decision — clipboard content never leaves the local BLE link between the two paired devices. No third-party infrastructure is involved at any point.

- Wi-Fi Direct is NOT available (macOS does not implement the Wi-Fi Direct standard; Apple uses proprietary AWDL which is not exposed to third parties and incompatible with Android)
- BLE 5.0 (the bottleneck, from the Mac side) with LE 2M PHY and DLE gives ~1-1.5 Mbps real-world throughput — plenty for text clipboard content
- Scope is text-only, so BLE throughput is never a bottleneck (even 100KB of text transfers in under a second)

---

## Clipboard Flow

### Mac → Android (fully automatic)

```
1. macOS app polls NSPasteboard.changeCount (every 500ms)
2. Change detected → content hashed (SHA-256)
3. BLE: Write hash + metadata to "Clipboard Available" characteristic
4. Android receives notification, compares hash to avoid duplicates
5. If new: pull content over BLE (chunked GATT reads)
6. Android calls ClipboardManager.setPrimaryClip()
7. System toast confirms "Copied to clipboard" (automatic on Android 13+)
```

**User experience:** Zero interaction required on either side. User copies on Mac, pastes on Android.

### Android → Mac (explicit share action)

```
1. User copies content on Android
2. User taps Share → selects "GreenPaste" / "Send to Mac"
3. App receives content via ACTION_SEND intent
4. Content sent to Mac over BLE (chunked writes to "Clipboard Push" characteristic)
5. macOS app receives content, writes to NSPasteboard
6. macOS shows brief notification: "Clipboard received from Android"
```

**Why explicit on Android:** Android 10+ prevents background apps from reading clipboard content. The share sheet is the cleanest sanctioned mechanism. No accessibility service hacks, no keyboard replacement.

---

## BLE Protocol Design

### GATT Service

```
Service UUID: (generate a custom 128-bit UUID)
  e.g., "C10B0001-1234-5678-9ABC-DEF012345678"

Characteristics:

1. Clipboard Available (Mac → Android signaling)
   UUID: C10B0002-...
   Properties: READ, NOTIFY
   Value: JSON { "hash": "<sha256>", "size": <bytes>, "type": "text/plain" }
   Description: Mac writes here when clipboard changes. Android subscribes for notifications.

2. Clipboard Data (Mac → Android transfer)
   UUID: C10B0003-...
   Properties: READ
   Value: Chunked clipboard content
   Description: Android reads this characteristic repeatedly to pull clipboard data.
   Chunking protocol:
     - First read returns header: { "total_chunks": N, "total_bytes": M, "encoding": "utf-8" | "base64" }
     - Subsequent reads return chunks with index prefix: [2-byte chunk index][payload]
     - MTU negotiated to 512 bytes, so ~509 bytes usable per chunk

3. Clipboard Push (Android → Mac transfer)
   UUID: C10B0004-...
   Properties: WRITE, WRITE_WITHOUT_RESPONSE
   Value: Chunked clipboard content from Android
   Description: Android writes clipboard data here. Mac subscribes.
   Same chunking protocol as above, but Android is the writer.

4. Device Info
   UUID: C10B0005-...
   Properties: READ
   Value: JSON { "name": "<device_name>", "platform": "macos" | "android", "version": "1.0" }
```

### BLE Connection Management

- **macOS acts as BLE Central**, Android acts as BLE Peripheral (GATT Server)
- Android advertises the ClipShare service UUID continuously via foreground service
- macOS scans for the service UUID, connects when found
- Reconnection: Exponential backoff on disconnect (1s, 2s, 4s, 8s, max 30s)
- Bonding: Pair once, reconnect automatically thereafter
- Connection interval: Request 15ms for responsive transfers, allow system to adjust

### Why Android is the Peripheral

- Android has excellent `BluetoothGattServer` APIs in Kotlin
- Android foreground services can maintain BLE advertising reliably
- macOS CoreBluetooth is strongest as a Central (scanning/connecting)
- This matches the typical BLE pattern for mobile ↔ desktop

---

## Platform Implementation Details

### macOS (Swift)

**App type:** Menu bar app (no dock icon, no main window)

**Components:**

```
ClipShareMac/
├── App/
│   ├── AppDelegate.swift          # Menu bar setup, lifecycle
│   └── StatusBarController.swift  # Menu bar icon + dropdown menu
├── Clipboard/
│   ├── ClipboardMonitor.swift     # NSPasteboard polling (500ms timer)
│   └── ClipboardWriter.swift      # Write incoming content to NSPasteboard
├── BLE/
│   ├── BLECentralManager.swift    # CoreBluetooth CBCentralManager
│   ├── BLEPeripheralDelegate.swift # Handle GATT interactions
│   └── ChunkAssembler.swift       # Reassemble chunked BLE data
├── Crypto/
│   └── E2ECrypto.swift            # X25519 + AES-256-GCM
├── Models/
│   └── ClipboardContent.swift     # Content type, hash, payload
└── Info.plist                     # NSBluetoothAlwaysUsageDescription
```

**Key APIs:**
- `NSPasteboard.general.changeCount` — poll for clipboard changes
- `NSPasteboard.general.string(forType: .string)` — read text
- `NSPasteboard.general.setString(_:forType:)` — write text
- `CBCentralManager` — BLE scanning and connection
- `CBPeripheral` — interact with Android's GATT server
- `NSUserNotification` or `UNUserNotificationCenter` — notify on receive

**Permissions required:**
- Bluetooth (Info.plist: `NSBluetoothAlwaysUsageDescription`)
- Notifications

**Distribution:** Direct .app bundle or Homebrew cask. No App Store required for personal use.

### Android (Kotlin)

**Components:**

```
app/src/main/java/com/clipshare/
├── ui/
│   ├── MainActivity.kt            # Settings, pairing UI, connection status
│   ├── QrScannerActivity.kt      # CameraX + ML Kit barcode scanner for pairing
│   └── ShareReceiverActivity.kt   # Handles ACTION_SEND intents
├── service/
│   ├── ClipShareService.kt         # Foreground service (keeps BLE alive)
│   └── ClipboardWriter.kt        # Write to ClipboardManager
├── ble/
│   ├── GattServerManager.kt      # BluetoothGattServer setup
│   ├── GattServerCallback.kt     # Handle read/write requests
│   ├── Advertiser.kt             # BLE advertising
│   └── ChunkTransfer.kt          # Chunking/reassembly logic
├── crypto/
│   └── E2ECrypto.kt              # Matching crypto implementation
└── models/
    └── ClipboardContent.kt
```

**AndroidManifest.xml entries:**

```xml
<!-- Permissions -->
<uses-permission android:name="android.permission.BLUETOOTH_ADVERTISE" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
<uses-permission android:name="android.permission.BLUETOOTH_SCAN" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE" />
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
<uses-permission android:name="android.permission.CAMERA" /> <!-- QR code scanning for pairing -->

<!-- Share target -->
<activity android:name=".ui.ShareReceiverActivity"
          android:exported="true">
    <intent-filter>
        <action android:name="android.intent.action.SEND" />
        <category android:name="android.intent.category.DEFAULT" />
        <data android:mimeType="text/*" />
    </intent-filter>
</activity>

<!-- Foreground service -->
<service android:name=".service.ClipShareService"
         android:foregroundServiceType="connectedDevice" />
```

**Key APIs:**
- `BluetoothGattServer` — host GATT service
- `BluetoothLeAdvertiser` — advertise service UUID
- `ClipboardManager.setPrimaryClip()` — write to clipboard (works from foreground service)
**Clipboard writing behavior by Android version:**
- Android 12 and below: `setPrimaryClip()` works silently from foreground service
- Android 13+: `setPrimaryClip()` works but system shows automatic "Copied to clipboard" toast. This is fine — it's good UX feedback.

---

## Security

### Pairing (QR Code)

One-time setup to establish trust between devices.

**Flow:**
1. User opens GreenPaste on macOS, clicks "Pair New Device"
2. macOS generates a QR code displayed in a window containing:
   - A one-time pairing token (random 32 bytes, hex-encoded)
   - macOS device's X25519 public key
   - BLE service UUID (so Android knows what to scan for)
   - Encoded as JSON, then as a `clipshare://pair?data=<base64>` URI in the QR code
3. User opens GreenPaste on Android, taps "Scan to Pair"
4. Android scans QR code using CameraX / ML Kit barcode scanner
5. Android extracts the pairing token and Mac's public key
6. Android generates its own X25519 keypair
7. Android starts BLE advertising with the pairing token embedded in the advertisement data
8. macOS scans for BLE peripherals advertising the expected pairing token — this confirms the correct device
9. BLE connection established. Android sends its X25519 public key over the encrypted BLE link
10. Both devices derive a shared secret (X25519 ECDH) and store it:
    - macOS: Keychain
    - Android: Android Keystore (hardware-backed on Pixel)
11. Pairing complete. Devices now recognize each other by BLE identity and shared secret.

**Why QR code instead of numeric code:**
- More data can be exchanged in one step (public key + token + service UUID)
- No manual typing, less error-prone
- The public key exchange happens out-of-band (camera), which prevents MITM on the BLE channel

**Re-pairing:** User can unpair from either device's settings and repeat the flow.

### Encryption

- All clipboard content encrypted with AES-256-GCM before transmission
- Unique nonce per message
- Key rotation: derive per-session keys from the shared secret + session nonce
- BLE characteristic values are always encrypted (BLE link-layer encryption is supplementary, not relied upon)

### Storage

- macOS: Keychain for shared secret and device identity
- Android: Android Keystore (hardware-backed on Pixel)
- No clipboard content is persisted to disk — in-memory only, transient

---

## Content Scope

**Text only.** Plain text clipboard content via BLE. No images, files, or rich text.

Max payload: ~100KB of text (transfers in under a second over BLE between target devices). If clipboard content exceeds this, silently skip (don't attempt to send).

---

## Build & Tooling

### macOS
- **Language:** Swift
- **Min deployment target:** macOS Tahoe 26.1
- **Build system:** Xcode / swift build
- **Dependencies:** None beyond system frameworks (CoreBluetooth, CryptoKit, AppKit)

### Android
- **Language:** Kotlin
- **Min SDK:** 35 (Android 16) — target device specific
- **Target SDK:** 35
- **Build system:** Gradle with Kotlin DSL
- **Dependencies:** AndroidX Core, Material3 for UI, CameraX + ML Kit Barcode for QR scanning. No third-party BLE libraries needed.

---

## Implementation Milestones

### Phase 1: Core BLE text sync
1. Android GATT server with advertising + foreground service
2. macOS BLE central that discovers and connects to Android
3. QR code pairing flow (macOS displays QR, Android scans with CameraX/ML Kit)
4. X25519 key exchange and shared secret storage (Keychain / Android Keystore)
5. E2E encryption (AES-256-GCM) over BLE
6. macOS clipboard monitor → BLE write → Android clipboard write (Mac→Android flow)
7. Android share sheet target → BLE write → macOS clipboard write (Android→Mac flow)

### Phase 2: Polish
7. Connection status UI on both platforms
8. Reconnection reliability (exponential backoff, auto-reconnect on BLE drop)
9. Notification actions on Android ("Paste from Mac: {preview}")
10. Settings: auto-connect on launch, content size limit

---

## Known Constraints & Tradeoffs

- **Android → Mac requires explicit user action (share sheet).** This is a deliberate design choice, not a limitation we can work around. Android 10+ prevents background clipboard reading for privacy. The share sheet is the only sanctioned path without resorting to Accessibility Services or building a custom keyboard.
- **BLE range.** ~10m typical. Devices must be in BLE range for any sync to work. No remote fallback — this is intentional for security (clipboard data never touches any network or server).
- **Text only.** Images and rich content are out of scope. If clipboard contains non-text content, it is silently ignored.
- **No Wi-Fi Direct.** macOS does not implement Wi-Fi Direct (Wi-Fi Alliance standard). Apple uses proprietary AWDL, which is not exposed to third parties and is incompatible with Android.
- **macOS clipboard polling.** `NSPasteboard` has no change notification API — polling `changeCount` is the standard approach (used by all Mac clipboard managers). 500ms interval is a good balance of responsiveness vs. CPU.
- **BLE connection stability.** BLE connections can drop, especially when devices go in/out of range. Robust reconnection logic is essential. The Android foreground service ensures the GATT server stays alive.
- **Sideloading only for Android.** No Play Store distribution planned. Install via ADB.