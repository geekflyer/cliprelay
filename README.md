# GreenPaste (clipboard-sync)

Cross-platform clipboard sync between macOS and Android over BLE only.

## What this repo builds

- macOS menu bar app bundle: `dist/GreenPaste.app`
- Android debug APK: `dist/greenpaste-debug.apk`

Both are produced by one script: `scripts/build-all.sh`.

## Prerequisites

### macOS build

- macOS with Xcode Command Line Tools
- `swift` available in PATH

Install CLI tools if needed:

```bash
xcode-select --install
```

### Android build

- JDK 17 or newer
- Android SDK installed (via Android Studio)
- `ANDROID_HOME` set (or Android Studio configured)
- USB debugging enabled on your Android phone (for install via ADB)

Check Java:

```bash
java -version
```

## Build both targets

From repo root:

```bash
./scripts/build-all.sh
```

Optional:

```bash
./scripts/build-all.sh --mac-only
./scripts/build-all.sh --android-only
```

## Install and run

### 1) Install the mac app

After build, copy app bundle:

```bash
cp -R dist/GreenPaste.app /Applications/
```

Launch:

```bash
open /Applications/GreenPaste.app
```

On first run, macOS may block unsigned app launch. If so:

- Right click app in Finder -> Open
- Approve in System Settings -> Privacy & Security

### 2) Install the Android APK

Connect device with USB debugging enabled, then:

```bash
adb install -r dist/greenpaste-debug.apk
```

If ADB is not found, add Android platform-tools to PATH.

### 3) Pair devices (native BLE pairing)

1. Open Bluetooth settings on macOS and Android.
2. Pair the two devices using the OS dialogs (numeric confirmation).
3. Launch GreenPaste on Android and tap `Start Clipboard Service`.
4. Launch GreenPaste on macOS (menu bar icon appears).

## Daily usage

- Mac -> Android: copy text on Mac, it syncs automatically.
- Android -> Mac: select text on Android, Share -> GreenPaste.

## Artifact paths

- mac app: `dist/GreenPaste.app`
- android apk: `dist/greenpaste-debug.apk`

## Notes

- Transport is BLE only (no cloud relay).
- Content scope is text only.
- Max payload is 100 KiB.
- MVP security relies on BLE Secure Connections (no additional app-layer crypto).
