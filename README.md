# ClipRelay (clipboard-sync)

Cross-platform clipboard sync between macOS and Android over BLE only.

## What this repo builds

- macOS menu bar app bundle: `dist/ClipRelay.app`
- Android debug APK: `dist/cliprelay-debug.apk`

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

## Run automated tests

From repo root:

```bash
./scripts/test-all.sh
```

## Run device smoke tests

For real-device BLE verification (macOS host + Android phone, debug builds):

```bash
./scripts/hardware-smoke-test.sh
```

Optional device selection:

```bash
./scripts/hardware-smoke-test.sh --serial <adb-serial>
```

Connection robustness options:

```bash
./scripts/hardware-smoke-test.sh --stability-seconds 8
./scripts/hardware-smoke-test.sh --timeout 90
./scripts/hardware-smoke-test.sh --m2a-stress-count 25 --m2a-stress-timeout 12
```

Use `--m2a-stress-count` to run repeated Mac -> Android clipboard transfers in one session.
This catches intermittent regressions where a single transfer might pass but repeated writes fail.

When a smoke step fails, the script now auto-dumps Android BLE logs, Android probe state,
and recent macOS ClipRelay logs to speed up root-cause analysis.

By default the script removes the temporary smoke-test pairing from both devices at the end.
Use `--keep-pairing` if you want to retain that pairing.

## Install and run

### 1) Install the mac app

After build, copy app bundle:

```bash
cp -R dist/ClipRelay.app /Applications/
```

Launch:

```bash
open /Applications/ClipRelay.app
```

On first run, macOS may block unsigned app launch. If so:

- Right click app in Finder -> Open
- Approve in System Settings -> Privacy & Security

### 2) Install the Android APK

Connect device with USB debugging enabled, then:

```bash
adb install -r dist/cliprelay-debug.apk
```

If ADB is not found, add Android platform-tools to PATH.

### 3) Pair devices

1. Launch ClipRelay on macOS (menu bar icon appears).
2. Click the menu bar icon and select "Pair New Device" to display a QR code.
3. Launch ClipRelay on Android and tap "Pair with Mac".
4. Scan the QR code with the Android app to complete pairing.

## Daily usage

- Mac -> Android: copy text on Mac, it syncs automatically.
- Android -> Mac: select text on Android, Share -> ClipRelay.

## Artifact paths

- mac app: `dist/ClipRelay.app`
- android apk: `dist/cliprelay-debug.apk`

## Notes

- Transport is BLE only (no cloud relay).
- Content scope is text only.
- Max payload is 100 KiB.
- All clipboard data is encrypted with AES-256-GCM using keys derived from the shared pairing token via HKDF.
