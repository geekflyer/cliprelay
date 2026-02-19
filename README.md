# GreenPaste (clipboard-sync)

Cross-platform clipboard sync between macOS and Android over BLE only.

This repository contains:

- `macos/ClipShareMac`: macOS menu-bar application skeleton in Swift.
- `android/`: Android app skeleton in Kotlin with a foreground BLE service and share target flow.

The implementation is intentionally text-only and designed around Android clipboard restrictions:

- Mac -> Android is automatic (poll macOS clipboard and send updates over BLE).
- Android -> Mac uses explicit user share action (`ACTION_SEND`).

## Protocol at a glance

- Service UUID: `c10b0001-1234-5678-9abc-def012345678`
- `Clipboard Available`: `c10b0002-1234-5678-9abc-def012345678`
- `Clipboard Data`: `c10b0003-1234-5678-9abc-def012345678`
- `Clipboard Push`: `c10b0004-1234-5678-9abc-def012345678`
- `Device Info`: `c10b0005-1234-5678-9abc-def012345678`

## Security model

- One-time pairing QR payload includes token + service UUID + macOS X25519 public key.
- Session keys derived from X25519 shared secret.
- Clipboard payload encrypted with AES-GCM before BLE transfer.
- No cloud relay and no persistent clipboard storage.

## Build notes

### macOS

Open `macos/ClipShareMac` as a Swift package in Xcode and run on macOS.

### Android

Open `android/` in Android Studio (AGP 8.x, Kotlin 2.x) and run on Android 16+.
