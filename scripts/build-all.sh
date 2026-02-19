#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
MAC_PROJECT_DIR="$ROOT_DIR/macos/ClipShareMac"
ANDROID_PROJECT_DIR="$ROOT_DIR/android"

BUILD_MAC=true
BUILD_ANDROID=true

usage() {
  cat <<'EOF'
Usage: ./scripts/build-all.sh [options]

Builds the macOS app bundle and Android APK.

Options:
  --mac-only       Build only macOS app
  --android-only   Build only Android APK
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

  local binary_path="$MAC_PROJECT_DIR/.build/release/GreenPaste"
  if [[ ! -x "$binary_path" ]]; then
    if [[ -x "$MAC_PROJECT_DIR/.build/arm64-apple-macosx/release/GreenPaste" ]]; then
      binary_path="$MAC_PROJECT_DIR/.build/arm64-apple-macosx/release/GreenPaste"
    elif [[ -x "$MAC_PROJECT_DIR/.build/x86_64-apple-macosx/release/GreenPaste" ]]; then
      binary_path="$MAC_PROJECT_DIR/.build/x86_64-apple-macosx/release/GreenPaste"
    else
      echo "Could not locate built macOS binary." >&2
      exit 1
    fi
  fi

  local app_dir="$DIST_DIR/GreenPaste.app"
  rm -rf "$DIST_DIR/ClipShareMac.app"
  rm -rf "$app_dir"
  mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"

  cp "$binary_path" "$app_dir/Contents/MacOS/GreenPaste"

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

  cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>GreenPaste</string>
  <key>CFBundleDisplayName</key>
  <string>GreenPaste</string>
  <key>CFBundleIdentifier</key>
  <string>com.greenpaste.mac</string>
  <key>CFBundleExecutable</key>
  <string>GreenPaste</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
PLIST

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

  echo "==> Building Android APK"
  (
    cd "$ANDROID_PROJECT_DIR"
    ./gradlew assembleDebug
  )

  local apk_path="$ANDROID_PROJECT_DIR/app/build/outputs/apk/debug/app-debug.apk"
  if [[ ! -f "$apk_path" ]]; then
    echo "APK not found at $apk_path" >&2
    exit 1
  fi

  cp "$apk_path" "$DIST_DIR/greenpaste-debug.apk"
  echo "Android APK copied to: $DIST_DIR/greenpaste-debug.apk"
}

if [[ "$BUILD_MAC" == true ]]; then
  build_mac
fi

if [[ "$BUILD_ANDROID" == true ]]; then
  build_android
fi

echo "==> Build complete"
