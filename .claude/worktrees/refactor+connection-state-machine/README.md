<p align="center">
  <img src="docs/images/banner.png" alt="ClipRelay" width="480">
</p>

<p align="center">
  <strong>Clipboard sharing between Android and Mac</strong><br>
  Encrypted, Bluetooth-only, no cloud.
</p>

<p align="center">
  <a href="https://cliprelay.org/beta.html">Join Android Beta</a> &bull;
  <a href="https://cliprelay.org/#download">Download for Mac</a> &bull;
  <a href="https://cliprelay.org">Website</a>
</p>

---

Copy on one device, paste on the other. ClipRelay syncs your clipboard between Android and Mac over Bluetooth Low Energy — no cloud, no servers, no accounts.

- **End-to-end encrypted** — AES-256-GCM encryption. ECDH key exchange (X25519) during pairing.
- **Bluetooth only** — direct BLE transfer, no WiFi or internet needed
- **No cloud, no servers** — your clipboard data never leaves the connection between your devices
- **Text clipboard** — up to 100 KiB per transfer over BLE
- **Image sync** *(experimental)* — transfer images (PNG/JPEG, up to 10 MB) between devices over a temporary local WiFi connection, with BLE for signaling. Both devices must be on the same WiFi network.
- **Auto-copy on Android** *(experimental)* — automatically detects when you copy text on Android and syncs it to your Mac, no manual sharing needed. Uses Android's accessibility service.

## Screenshots

<p align="center">
  <img src="docs/images/android-connected.png" alt="ClipRelay Android app" height="400">
  &nbsp;&nbsp;&nbsp;&nbsp;
  <img src="docs/images/android-share.png" alt="Android Share menu with ClipRelay direct share" height="400">
</p>

<p align="center">
  <em>Android app &nbsp;&bull;&nbsp; Share menu with direct share to Mac</em>
</p>

<p align="center">
  <img src="docs/images/mac-menubar.png" alt="ClipRelay Mac menu bar" width="420">
</p>

<p align="center">
  <em>Mac menu bar</em>
</p>

## How it works

1. Install ClipRelay on both your Mac and Android device.
2. Open the Mac app (menu bar icon appears), click "Pair New Device" to show a QR code.
3. Open the Android app, tap "Pair with Mac", and scan the QR code.
4. Done — clipboard sharing is automatic:
   - **Mac to Android:** copy text on Mac, it syncs automatically.
   - **Android to Mac:** select text on Android, Share → ClipRelay.

### Image sync *(experimental)*

Image transfer uses a temporary TCP connection over your local WiFi (not Bluetooth) for speed. Both devices must be on the same WiFi network. Enable "Image Sync" in the paired device settings on both devices. When you copy an image on your Mac or share one from Android, it transfers encrypted over your local network — still AES-256-GCM encrypted, still no cloud.

### Auto-copy on Android *(experimental)*

By default, Android clipboard sharing requires manually using Share → ClipRelay. With auto-copy enabled, ClipRelay detects when you copy text on Android and automatically syncs it to your Mac — just like the Mac-to-Android direction. Enable it in the Android app settings. This feature requires granting the Accessibility Service permission.

## Building from source

### Prerequisites

**macOS app:**
- macOS with Xcode Command Line Tools (`xcode-select --install`)
- `swift` available in PATH

**Android app:**
- JDK 17 or newer
- Android SDK (via Android Studio or standalone)
- `ANDROID_HOME` set or Android Studio configured

### Build

```bash
# Build both platforms (debug)
./scripts/build-all.sh

# Build only one platform
./scripts/build-all.sh --mac-only
./scripts/build-all.sh --android-only

# Release build (requires signing configuration)
./scripts/build-all.sh --release
```

**Output artifacts:**

| Artifact | Path |
|----------|------|
| Mac app | `dist/ClipRelay.app` |
| Android debug APK | `dist/cliprelay-debug.apk` |
| Android release AAB | `dist/cliprelay-release.aab` |
| Android release APK | `dist/cliprelay-release.apk` |

### Install from build

**Mac:**

```bash
cp -R dist/ClipRelay.app /Applications/
open /Applications/ClipRelay.app
```

On first run, macOS may block an unsigned app. Right-click → Open in Finder, then approve in System Settings → Privacy & Security.

**Android:**

```bash
adb install -r dist/cliprelay-debug.apk
```

### Release signing (Android)

For release builds, configure signing via `android/keystore.properties`:

```properties
storeFile=../path-to-keystore.jks
storePassword=...
keyAlias=...
keyPassword=...
```

Or set environment variables: `CLIPRELAY_STORE_FILE`, `CLIPRELAY_STORE_PASSWORD`, `CLIPRELAY_KEY_ALIAS`, `CLIPRELAY_KEY_PASSWORD`.

## Development

### Running tests

```bash
# Unit tests (Android + Mac)
./scripts/test-all.sh
```

### Hardware smoke tests

For real-device BLE verification (requires a Mac host + Android phone connected via USB):

```bash
./scripts/hardware-smoke-test.sh
```

Options:

```bash
# Target a specific device
./scripts/hardware-smoke-test.sh --serial <adb-serial>

# Tune connection parameters
./scripts/hardware-smoke-test.sh --stability-seconds 8
./scripts/hardware-smoke-test.sh --timeout 90

# Stress test with repeated transfers
./scripts/hardware-smoke-test.sh --m2a-stress-count 25 --m2a-stress-timeout 12

# Keep the test pairing after the run (removed by default)
./scripts/hardware-smoke-test.sh --keep-pairing
```

When a smoke step fails, the script auto-dumps Android BLE logs, probe state, and recent macOS ClipRelay logs.

### Project structure

```
android/          Android app (Kotlin, Jetpack Compose)
ClipRelay/        macOS app (Swift)
website/          Static website (HTML/CSS/JS, hosted on Cloudflare Pages)
scripts/          Build, test, and publish scripts
docs/             Design documents and plans
```

## License

This source code is made available for reference and review purposes. See [LICENSE](LICENSE) for details.
