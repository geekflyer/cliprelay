# Mac App Store Publishing — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Package and publish ClipRelay for macOS on the Mac App Store, including sandbox entitlements, App Store signing, store listing assets, and upload tooling.

**Architecture:** Keep the existing SwiftPM + manual `.app` bundling workflow. Add an `--app-store` flag to `scripts/build-all.sh` that applies sandbox entitlements, signs with the App Store certificate, embeds the provisioning profile, and packages into a signed `.pkg`. Store listing metadata goes in `appstore/` (parallel to `googleplay/`). Upload via `xcrun altool`.

**Tech Stack:** Swift/SwiftPM (build), codesign + productbuild (packaging), xcrun altool (upload), Python/Pillow + rsvg-convert (asset generation)

---

### Task 1: Create App Store entitlements file

**Files:**
- Create: `macos/ClipRelayMac/Resources/ClipRelay-AppStore.entitlements`
- Read: `macos/ClipRelayMac/Resources/ClipRelay.entitlements` (existing Developer ID entitlements)

The existing entitlements file (`ClipRelay.entitlements`) is for Developer ID / direct distribution. App Store requires a separate file with App Sandbox enabled.

**Step 1: Create the App Store entitlements file**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.device.bluetooth</key>
	<true/>
</dict>
</plist>
```

Save to `macos/ClipRelayMac/Resources/ClipRelay-AppStore.entitlements`.

**Step 2: Commit**

```bash
git add macos/ClipRelayMac/Resources/ClipRelay-AppStore.entitlements
git commit -m "feat(macos): add App Store sandbox entitlements"
```

---

### Task 2: Manual — Create certificates and provisioning profile

This task requires the user to perform manual steps in the Apple Developer portal. Document the exact steps and verify the results.

**Step 1: Document the manual steps**

The user must do the following in https://developer.apple.com/account/resources:

**A. Register App ID** (if not already done):
1. Go to Identifiers > "+" > App IDs > macOS
2. Description: "ClipRelay Mac"
3. Bundle ID (Explicit): `org.cliprelay.mac`
4. Capabilities: check nothing extra (Bluetooth is automatic)
5. Register

**B. Create "3rd Party Mac Developer Application" certificate** (if not present):
1. Go to Certificates > "+"
2. Select "Mac App Distribution" (this is the modern name for "3rd Party Mac Developer Application")
3. Upload a CSR generated from Keychain Access (Keychain Access > Certificate Assistant > Request a Certificate From a Certificate Authority > save to disk)
4. Download and double-click to install

**C. Create "3rd Party Mac Developer Installer" certificate** (if not present):
1. Go to Certificates > "+"
2. Select "Mac Installer Distribution"
3. Use the same CSR or generate a new one
4. Download and double-click to install

**D. Create provisioning profile:**
1. Go to Profiles > "+"
2. Select "Mac App Store Connect" under Distribution
3. Select App ID: `org.cliprelay.mac`
4. Select the "Mac App Distribution" certificate
5. Name: "ClipRelay Mac App Store"
6. Download the `.provisionprofile` file
7. Save to `macos/ClipRelayMac/Resources/embedded.provisionprofile`

**Step 2: Verify certificates are installed**

```bash
security find-identity -v -p codesigning | grep -i "3rd Party Mac Developer\|Mac App Distribution\|Apple Distribution"
```

Expected: At least one line with "3rd Party Mac Developer Application" or "Apple Distribution".

```bash
security find-identity -v | grep -i "installer\|Mac Installer Distribution"
```

Expected: At least one line with "3rd Party Mac Developer Installer" or "Mac Installer Distribution".

**Step 3: Verify provisioning profile**

```bash
security cms -D -i macos/ClipRelayMac/Resources/embedded.provisionprofile 2>/dev/null | grep -A1 "application-identifier"
```

Expected: Should contain `org.cliprelay.mac`.

**Step 4: Gitignore the provisioning profile (contains team-specific data)**

Add to `.gitignore`:

```
*.provisionprofile
```

**Step 5: Commit**

```bash
git add .gitignore
git commit -m "chore: gitignore provisioning profiles"
```

---

### Task 3: Add `--app-store` flag to build script

**Files:**
- Modify: `scripts/build-all.sh`

This task extends the existing build script to support App Store builds. The `--app-store` flag will:
1. Build the `.app` bundle as before
2. Embed the provisioning profile
3. Sign with the App Store certificate and sandbox entitlements
4. Package into a signed `.pkg`

**Step 1: Add the `--app-store` flag parsing**

In `scripts/build-all.sh`, add a new variable after line 12 (`ANDROID_RELEASE=false`):

```bash
MAC_APP_STORE=false
```

Add a new case in the `while` loop (after the `--release` case):

```bash
    --app-store)
      MAC_APP_STORE=true
      shift
      ;;
```

Update the `usage()` function to include:

```
  --app-store      Build macOS App Store .pkg (signed + sandboxed)
```

**Step 2: Add the App Store signing and packaging logic**

After the existing `echo "macOS app bundle created: $app_dir"` line (line 128), add:

```bash
  if [[ "$MAC_APP_STORE" == true ]]; then
    echo "==> Packaging for Mac App Store"

    local entitlements="$MAC_PROJECT_DIR/Resources/ClipRelay-AppStore.entitlements"
    local profile="$MAC_PROJECT_DIR/Resources/embedded.provisionprofile"

    if [[ ! -f "$entitlements" ]]; then
      echo "App Store entitlements not found: $entitlements" >&2
      exit 1
    fi
    if [[ ! -f "$profile" ]]; then
      echo "Provisioning profile not found: $profile" >&2
      echo "Download from Apple Developer portal and save to: $profile" >&2
      exit 1
    fi

    # Embed provisioning profile
    cp "$profile" "$app_dir/Contents/embedded.provisionprofile"

    # Detect signing identity
    local app_sign_id
    app_sign_id=$(security find-identity -v -p codesigning | grep -o '"3rd Party Mac Developer Application:[^"]*"' | head -1 | tr -d '"')
    if [[ -z "$app_sign_id" ]]; then
      app_sign_id=$(security find-identity -v -p codesigning | grep -o '"Apple Distribution:[^"]*"' | head -1 | tr -d '"')
    fi
    if [[ -z "$app_sign_id" ]]; then
      echo "No App Store signing identity found. Install a 'Mac App Distribution' certificate." >&2
      exit 1
    fi

    local installer_sign_id
    installer_sign_id=$(security find-identity -v | grep -o '"3rd Party Mac Developer Installer:[^"]*"' | head -1 | tr -d '"')
    if [[ -z "$installer_sign_id" ]]; then
      installer_sign_id=$(security find-identity -v | grep -o '"Mac Installer Distribution:[^"]*"' | head -1 | tr -d '"')
    fi
    if [[ -z "$installer_sign_id" ]]; then
      echo "No installer signing identity found. Install a 'Mac Installer Distribution' certificate." >&2
      exit 1
    fi

    echo "  Signing with: $app_sign_id"
    codesign --force --options runtime \
      --sign "$app_sign_id" \
      --entitlements "$entitlements" \
      --timestamp \
      "$app_dir"

    echo "  Packaging with: $installer_sign_id"
    productbuild \
      --component "$app_dir" /Applications \
      --sign "$installer_sign_id" \
      "$DIST_DIR/ClipRelay.pkg"

    echo "Mac App Store package created: $DIST_DIR/ClipRelay.pkg"
  fi
```

**Step 3: Verify the build works (dry run without `--app-store` flag)**

```bash
scripts/build-all.sh --mac-only
```

Expected: Builds the `.app` bundle as before (no signing step).

**Step 4: Commit**

```bash
git add scripts/build-all.sh
git commit -m "feat(macos): add --app-store flag to build script"
```

---

### Task 4: Scaffold App Store metadata directory

**Files:**
- Create: `appstore/metadata/en-US/description.txt`
- Create: `appstore/metadata/en-US/keywords.txt`
- Create: `appstore/metadata/en-US/name.txt`
- Create: `appstore/metadata/en-US/subtitle.txt`
- Create: `appstore/metadata/en-US/whats_new.txt`
- Create: `appstore/metadata/en-US/privacy_url.txt`
- Create: `appstore/metadata/en-US/support_url.txt`
- Create directories for screenshots

**Step 1: Create directory structure**

```bash
mkdir -p appstore/metadata/en-US
mkdir -p appstore/screenshots
```

**Step 2: Write `name.txt`**

```
ClipRelay
```

Save to `appstore/metadata/en-US/name.txt`. (Max 30 chars)

**Step 3: Write `subtitle.txt`**

```
Clipboard Sync over Bluetooth
```

Save to `appstore/metadata/en-US/subtitle.txt`. (Max 30 chars)

**Step 4: Write `keywords.txt`**

```
clipboard,sync,bluetooth,paste,copy,BLE,Android
```

Save to `appstore/metadata/en-US/keywords.txt`. (Max 100 chars, comma-separated)

**Step 5: Write `description.txt`**

Adapt from Play Store listing (Mac-centric perspective):

```
ClipRelay syncs your clipboard between your Mac and Android phone instantly over Bluetooth Low Energy. Copy on one device, paste on the other.

No cloud. No servers. No internet required. Your clipboard data never leaves your devices.

HOW IT WORKS
- Pair your Android phone with your Mac by scanning a QR code
- ClipRelay runs in your menu bar on Mac and in the background on Android
- Copy text on either device and it appears on the other within seconds

PRIVACY FIRST
- Direct Bluetooth connection — no data goes through any server
- End-to-end encrypted with AES-256-GCM
- No accounts, no sign-up, no tracking

FEATURES
- Instant clipboard sync over Bluetooth Low Energy
- Dead simple setup — scan a QR code and you're done
- Runs quietly in your menu bar
- Works offline — no internet connection needed
```

Save to `appstore/metadata/en-US/description.txt`.

**Step 6: Write `whats_new.txt`**

```
Initial release.
```

Save to `appstore/metadata/en-US/whats_new.txt`.

**Step 7: Write `privacy_url.txt`**

```
https://cliprelay.pages.dev/privacy.html
```

Save to `appstore/metadata/en-US/privacy_url.txt`.

**Step 8: Write `support_url.txt`**

```
https://cliprelay.pages.dev
```

Save to `appstore/metadata/en-US/support_url.txt`.

**Step 9: Commit**

```bash
git add appstore/
git commit -m "feat(macos): scaffold App Store listing metadata"
```

---

### Task 5: Generate 1024x1024 App Store icon

**Files:**
- Read: `design/logo-android-foreground.svg`
- Create: `appstore/AppIcon.png`

The Mac App Store requires a 1024x1024 PNG icon. Use the same approach as the Play Store icon: aqua background (#00FFD5) with the ClipRelay logo mark.

**Step 1: Render the foreground SVG at 1024px**

```bash
rsvg-convert -w 1024 -h 1024 design/logo-android-foreground.svg -o /tmp/cliprelay-fg-1024.png
```

**Step 2: Composite onto aqua background**

```python
from PIL import Image

bg = Image.new('RGBA', (1024, 1024), (0, 255, 213, 255))
fg = Image.open('/tmp/cliprelay-fg-1024.png').convert('RGBA')
result = Image.alpha_composite(bg, fg)
result = result.convert('RGB')
result.save('appstore/AppIcon.png')
```

**Step 3: Verify dimensions**

```bash
python3 -c "from PIL import Image; img = Image.open('appstore/AppIcon.png'); print(img.size)"
```

Expected: `(1024, 1024)`

**Step 4: Visually inspect the icon**

Read the generated PNG to verify it looks correct.

**Step 5: Commit**

```bash
git add appstore/AppIcon.png
git commit -m "feat(macos): add 1024x1024 App Store icon"
```

---

### Task 6: Capture Mac screenshots

**Files:**
- Create: `appstore/screenshots/1-menubar.png`
- Create: `appstore/screenshots/2-paired.png`

Mac App Store requires at least one screenshot at 1280x800, 1440x900, 2560x1600, or 2880x1800 pixels.

**Step 1: Determine screen resolution**

```bash
system_profiler SPDisplaysDataType | grep Resolution
```

**Step 2: Build and launch the app**

```bash
scripts/build-all.sh --mac-only
open dist/ClipRelay.app
```

**Step 3: Capture the menu bar dropdown (paired state)**

Get the app running in a paired state with the Android device, then capture the screen:

```bash
screencapture -x /tmp/cliprelay-mac-full.png
```

The `-x` flag suppresses the shutter sound.

**Step 4: Crop/resize to App Store requirements if needed**

If the screenshot is Retina (e.g., 2880x1800), it satisfies the largest size requirement. If it needs cropping, use Python/Pillow:

```python
from PIL import Image
img = Image.open('/tmp/cliprelay-mac-full.png')
# Crop or resize as needed
img.save('appstore/screenshots/1-menubar.png')
```

**Step 5: Capture additional states**

Repeat for the unpaired state showing the QR pairing prompt.

**Step 6: Verify screenshot dimensions**

```python
from PIL import Image
import os
for f in sorted(os.listdir('appstore/screenshots')):
    img = Image.open(f'appstore/screenshots/{f}')
    w, h = img.size
    print(f'{f}: {w}x{h}')
```

All must be at least 1280x800 and no larger than 9999x9999.

**Step 7: Commit**

```bash
git add appstore/screenshots/
git commit -m "feat(macos): add App Store screenshots"
```

---

### Task 7: Manual — Create App Store Connect record and upload

This task requires the user to perform steps in App Store Connect and on the command line.

**Step 1: Create the app record in App Store Connect**

1. Go to https://appstoreconnect.apple.com > My Apps > "+" > New App
2. Platform: macOS
3. Name: ClipRelay
4. Primary Language: English (U.S.)
5. Bundle ID: `org.cliprelay.mac` (must match the registered App ID)
6. SKU: `org.cliprelay.mac`
7. Access: Full Access

**Step 2: Build the App Store `.pkg`**

```bash
scripts/build-all.sh --mac-only --app-store
```

Expected output ends with: `Mac App Store package created: dist/ClipRelay.pkg`

**Step 3: Validate the package**

```bash
xcrun altool --validate-app --file dist/ClipRelay.pkg --type macos --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>
```

Replace `<KEY_ID>` and `<ISSUER_ID>` with your App Store Connect API key credentials. If you don't have an API key yet:

1. Go to https://appstoreconnect.apple.com > Users and Access > Integrations > App Store Connect API
2. Generate a new key with "Admin" or "Developer" role
3. Download the `.p8` file and save to `~/.private_keys/AuthKey_<KEY_ID>.p8`

**Step 4: Upload the package**

```bash
xcrun altool --upload-app --file dist/ClipRelay.pkg --type macos --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>
```

**Step 5: Fill in App Store listing**

In App Store Connect > My Apps > ClipRelay > macOS > Prepare for Submission:

1. **Screenshots**: Upload from `appstore/screenshots/`
2. **Description**: Copy from `appstore/metadata/en-US/description.txt`
3. **Keywords**: Copy from `appstore/metadata/en-US/keywords.txt`
4. **Subtitle**: Copy from `appstore/metadata/en-US/subtitle.txt`
5. **Support URL**: `https://cliprelay.pages.dev`
6. **Privacy Policy URL**: `https://cliprelay.pages.dev/privacy.html`
7. **Category**: Utilities
8. **App icon**: Upload from `appstore/AppIcon.png`
9. **What's New**: "Initial release."
10. **Review Notes**: "ClipRelay is a menu bar app that syncs clipboard text between Mac and Android over Bluetooth Low Energy. To test, you need a paired Android device running the ClipRelay Android app. The app appears as a menu bar icon (no dock icon or main window). Click the menu bar icon to see connection status and synced clipboard contents."

**Step 6: Submit for review**

Click "Submit for Review" in App Store Connect.

---

### Task 8: Document App Privacy (App Store Connect)

This is filled in via App Store Connect UI (not uploaded programmatically).

**Step 1: Navigate to App Privacy**

In App Store Connect > My Apps > ClipRelay > App Privacy

**Step 2: Answer the questionnaire**

**Do you or your third-party partners collect data from this app?**
> No

That's it. Since no data is collected, no further detail is needed.

**Step 3: Save**

Click Save. The privacy label will show "No Data Collected".
