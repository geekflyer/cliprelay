#!/usr/bin/env bash
# Builds both macOS and Android apps into the dist/ directory.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAC_VERSION=$(cat "$ROOT_DIR/macos/VERSION" 2>/dev/null || echo "0.0.0")
MAC_BUILD_NUMBER=$(git -C "$ROOT_DIR" rev-list --count HEAD)
GIT_HASH=$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
DIST_DIR="$ROOT_DIR/dist"
MAC_PROJECT_DIR="$ROOT_DIR/macos/ClipRelayMac"
ANDROID_PROJECT_DIR="$ROOT_DIR/android"

SPARKLE_PLIST_KEYS=""
if [[ -n "${SPARKLE_PUBLIC_KEY:-}" ]]; then
    SPARKLE_PLIST_KEYS="<key>SUPublicEDKey</key>
    <string>${SPARKLE_PUBLIC_KEY}</string>"
fi

BUILD_MAC=true
BUILD_ANDROID=true
ANDROID_RELEASE=false

usage() {
  cat <<'EOF'
Usage: ./scripts/build-all.sh [options]

Builds the macOS app bundle and Android app artifacts.

Options:
  --mac-only       Build only macOS app
  --android-only   Build only Android artifacts
  --release        Build Android release AAB/APK instead of debug APK
  -h, --help       Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mac-only)
      BUILD_ANDROID=false
      shift
      ;;
    --android-only)
      BUILD_MAC=false
      shift
      ;;
    --release)
      ANDROID_RELEASE=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ "$BUILD_MAC" == false && "$BUILD_ANDROID" == false ]]; then
  echo "Nothing to build. Pick at least one target." >&2
  exit 1
fi

mkdir -p "$DIST_DIR"

build_mac() {
  if ! command -v swift >/dev/null 2>&1; then
    echo "swift not found. Install Xcode command-line tools first." >&2
    exit 1
  fi

  echo "==> Building macOS app"
  swift build --configuration release --package-path "$MAC_PROJECT_DIR"

  local binary_path="$MAC_PROJECT_DIR/.build/release/ClipRelay"
  if [[ ! -x "$binary_path" ]]; then
    if [[ -x "$MAC_PROJECT_DIR/.build/arm64-apple-macosx/release/ClipRelay" ]]; then
      binary_path="$MAC_PROJECT_DIR/.build/arm64-apple-macosx/release/ClipRelay"
    elif [[ -x "$MAC_PROJECT_DIR/.build/x86_64-apple-macosx/release/ClipRelay" ]]; then
      binary_path="$MAC_PROJECT_DIR/.build/x86_64-apple-macosx/release/ClipRelay"
    else
      echo "Could not locate built macOS binary." >&2
      exit 1
    fi
  fi

  local app_dir="$DIST_DIR/ClipRelay.app"
  rm -rf "$app_dir"
  mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"

  cp "$binary_path" "$app_dir/Contents/MacOS/ClipRelay"

  # Copy Sparkle.framework into Frameworks/
  local sparkle_fw
  sparkle_fw=$(dirname "$binary_path")/Sparkle.framework
  if [[ -d "$sparkle_fw" ]]; then
    mkdir -p "$app_dir/Contents/Frameworks"
    cp -a "$sparkle_fw" "$app_dir/Contents/Frameworks/Sparkle.framework"
    install_name_tool -add_rpath @executable_path/../Frameworks "$app_dir/Contents/MacOS/ClipRelay"
    echo "Copying Sparkle.framework"
  else
    echo "Error: Sparkle.framework not found at $sparkle_fw" >&2
    exit 1
  fi

  # Copy app icon and menu bar icon into Resources
  local resources_src="$MAC_PROJECT_DIR/Resources"
  if [[ -f "$resources_src/AppIcon.icns" ]]; then
    cp "$resources_src/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"
  fi
  for img in StatusBarIcon.png StatusBarIcon@2x.png; do
    if [[ -f "$resources_src/$img" ]]; then
      cp "$resources_src/$img" "$app_dir/Contents/Resources/$img"
    fi
  done

  cat > "$app_dir/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>ClipRelay</string>
  <key>CFBundleDisplayName</key>
  <string>ClipRelay</string>
  <key>CFBundleIdentifier</key>
  <string>org.cliprelay.mac</string>
  <key>CFBundleExecutable</key>
  <string>ClipRelay</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleShortVersionString</key>
  <string>${MAC_VERSION} (${GIT_HASH})</string>
  <key>CFBundleVersion</key>
  <string>${MAC_BUILD_NUMBER}</string>
  <key>ClipRelayGitHash</key>
  <string>${GIT_HASH}</string>
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>ClipRelay uses Bluetooth Low Energy to discover and sync clipboard text with your paired Android devices.</string>
  <key>LSUIElement</key>
  <true/>
  <key>SUFeedURL</key>
  <string>https://raw.githubusercontent.com/geekflyer/cliprelay/main/sparkle/appcast.xml</string>
  ${SPARKLE_PLIST_KEYS}
</dict>
</plist>
PLIST

  # ── Sign with entitlements + hardened runtime ──
  local entitlements_path="$ROOT_DIR/macos/ClipRelayMac/Resources/ClipRelay.entitlements"
  local dev_id="Developer ID Application: Christian Theilemann (B66YFKPUA8)"
  if security find-identity -v -p codesigning 2>/dev/null | grep -q "$dev_id"; then
    echo "Signing with Developer ID + hardened runtime..."
    codesign --force --deep --sign "$dev_id" \
        --entitlements "$entitlements_path" \
        --options runtime \
        --timestamp \
        "$app_dir"
  else
    echo "Developer ID not found, signing ad-hoc with hardened runtime..."
    codesign --force --sign - \
        --entitlements "$entitlements_path" \
        --options runtime \
        "$app_dir"
  fi
  echo "Code signing complete."

  echo "macOS app bundle created: $app_dir"
}

build_android() {
  if [[ ! -x "$ANDROID_PROJECT_DIR/gradlew" ]]; then
    echo "Gradle wrapper missing at android/gradlew" >&2
    exit 1
  fi

  if ! command -v java >/dev/null 2>&1; then
    echo "java not found. Install JDK 17+ first." >&2
    exit 1
  fi

  ANDROID_VERSION_CODE=$(git tag -l 'android/v*' | wc -l | tr -d ' ')
  local gradle_version_arg=""
  if [[ "$ANDROID_VERSION_CODE" -gt 0 ]]; then
    gradle_version_arg="-PcliVersionCode=$ANDROID_VERSION_CODE"
  fi

  if [[ "$ANDROID_RELEASE" == true ]]; then
    echo "==> Building Android release AAB/APK"
    (
      cd "$ANDROID_PROJECT_DIR"
      ./gradlew clean bundleRelease assembleRelease $gradle_version_arg
    )

    local aab_path="$ANDROID_PROJECT_DIR/app/build/outputs/bundle/release/app-release.aab"
    local release_apk_path="$ANDROID_PROJECT_DIR/app/build/outputs/apk/release/app-release.apk"

    if [[ ! -f "$aab_path" ]]; then
      echo "AAB not found at $aab_path" >&2
      exit 1
    fi

    if [[ ! -f "$release_apk_path" ]]; then
      echo "Release APK not found at $release_apk_path" >&2
      exit 1
    fi

    cp "$aab_path" "$DIST_DIR/cliprelay-release.aab"
    cp "$release_apk_path" "$DIST_DIR/cliprelay-release.apk"
    echo "Android release AAB copied to: $DIST_DIR/cliprelay-release.aab"
    echo "Android release APK copied to: $DIST_DIR/cliprelay-release.apk"
  else
    echo "==> Building Android debug APK"
    (
      cd "$ANDROID_PROJECT_DIR"
      ./gradlew assembleDebug $gradle_version_arg
    )

    local apk_path="$ANDROID_PROJECT_DIR/app/build/outputs/apk/debug/app-debug.apk"
    if [[ ! -f "$apk_path" ]]; then
      echo "APK not found at $apk_path" >&2
      exit 1
    fi

    cp "$apk_path" "$DIST_DIR/cliprelay-debug.apk"
    echo "Android APK copied to: $DIST_DIR/cliprelay-debug.apk"
  fi
}

if [[ "$BUILD_MAC" == true ]]; then
  build_mac
fi

if [[ "$BUILD_ANDROID" == true ]]; then
  build_android
fi

echo "==> Build complete"
