# Mac App Store Publishing — Design

## Goal

Publish ClipRelay for macOS on the Mac App Store. The app is already built and distributed directly (Developer ID + notarization). This work adds App Store-specific signing, sandboxing, packaging, and store listing assets.

## Current State

- SwiftPM project, manual `.app` bundling via `scripts/build-all.sh`
- Bundle ID: `org.cliprelay.mac`
- Version: 0.1.0 (build 1)
- Menu bar app (`LSUIElement = true`)
- Uses CoreBluetooth (CBCentralManager) for BLE clipboard sync
- Has "Developer ID Application" cert (direct distribution) and "Mac Developer" cert (development)
- No App Store certificates, provisioning profiles, or App Store Connect app record yet

## Certificates & Provisioning

### New certificates needed (Apple Developer portal)

1. **3rd Party Mac Developer Application** — signs the `.app` for App Store
2. **3rd Party Mac Developer Installer** — signs the `.pkg` for upload

### Provisioning

- Register App ID `org.cliprelay.mac` in Apple Developer portal (Identifiers)
- Create a Mac App Store distribution provisioning profile
- Embed profile in `.app` bundle as `Contents/embedded.provisionprofile`

## Entitlements

Separate entitlements file for App Store builds (`ClipRelay-AppStore.entitlements`):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.app-sandbox</key>
  <true/>
  <key>com.apple.security.device.bluetooth</key>
  <true/>
</dict>
</plist>
```

Minimal sandbox — BLE only. No network, file access, or other capabilities needed.

## Build & Package Flow

Extend `scripts/build-all.sh` with an `--app-store` flag:

1. `swift build --configuration release` (existing step)
2. Construct `.app` bundle (existing step)
3. Embed provisioning profile into `Contents/embedded.provisionprofile`
4. Code sign with App Store entitlements:
   ```bash
   codesign --force --options runtime \
     --sign "3rd Party Mac Developer Application: Christian Theilemann (B66YFKPUA8)" \
     --entitlements ClipRelay-AppStore.entitlements \
     --timestamp \
     dist/ClipRelay.app
   ```
5. Package into signed `.pkg`:
   ```bash
   productbuild \
     --component dist/ClipRelay.app /Applications \
     --sign "3rd Party Mac Developer Installer: Christian Theilemann (B66YFKPUA8)" \
     dist/ClipRelay.pkg
   ```
6. Upload:
   ```bash
   xcrun altool --upload-app \
     --file dist/ClipRelay.pkg \
     --type macos \
     --apiKey <key> --apiIssuer <issuer>
   ```

## App Store Connect

- **App name**: ClipRelay
- **Bundle ID**: `org.cliprelay.mac`
- **Category**: Utilities
- **Pricing**: Free
- **Privacy policy**: https://cliprelay.pages.dev/privacy.html
- **Privacy nutrition label**: No data collected (same as Android Data Safety)

## Store Listing Assets

| Asset | Spec | Source |
|-------|------|--------|
| App icon | 1024x1024 PNG | Render from `design/logo-android-foreground.svg` on aqua bg |
| Screenshots | 1280x800 or 1440x900 | Capture from running app |
| Description | Up to 4000 chars | Adapt from Play Store listing |
| Keywords | Up to 100 chars | `clipboard, sync, bluetooth, paste, copy, BLE, Mac, Android` |
| What's New | Free text | "Initial release" |

## App Review Notes

- BLE usage: privacy string in Info.plist (`NSBluetoothAlwaysUsageDescription`)
- Sandboxed with minimal entitlements
- Menu bar app — no main window, no dock icon
- No network, no accounts, no data collection, no analytics
- Requires paired Android device to demonstrate full functionality (note for reviewer)

## Out of Scope

- Automated CI/CD publishing pipeline
- Paid features or in-app purchases
- Universal purchase with iOS (no iOS app)
