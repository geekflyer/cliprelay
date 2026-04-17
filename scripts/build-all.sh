#!/usr/bin/env bash
# Builds both macOS and Android apps into the dist/ directory.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAC_VERSION=${MAC_VERSION:-$(cat "$ROOT_DIR/macos/VERSION" 2>/dev/null || echo "0.0.0")}
MAC_BUILD_NUMBER=${MAC_BUILD_NUMBER:-$(git -C "$ROOT_DIR" rev-list --count HEAD)}
GIT_HASH=$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
DIST_DIR="$ROOT_DIR/dist"
MAC_PROJECT_DIR="$ROOT_DIR/macos/ClipRelayMac"
ANDROID_PROJECT_DIR="$ROOT_DIR/android"

# EdDSA public key for Sparkle update signature verification.
# This is the verification (public) key — safe to commit. Override via SPARKLE_PUBLIC_KEY env var if needed.
SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-MvvTVBZwmJX4xjRViW6SBISRMDdzdVkVdO5KVB/7z8I=}"
SPARKLE_PLIST_KEYS="<key>SUPublicEDKey</key>
    <string>${SPARKLE_PUBLIC_KEY}</string>"

BUILD_MAC=true
BUILD_ANDROID=true
ANDROID_RELEASE=false
MAC_SMOKE_CLI=false
MAC_DEVELOPER_ID_SIGN=false

usage() {
  cat <<'EOF'
Usage: ./scripts/build-all.sh [options]

Builds the macOS app bundle and Android app artifacts.

Options:
  --mac-only       Build only macOS app
  --android-only   Build only Android artifacts
  --release        Build Android release AAB/APK instead of debug APK
  --smoke-cli      Build macOS app with smoke-test-only CLI entry points
  --developer-id-sign
                   Sign macOS app with the configured Developer ID identity
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
    --smoke-cli)
      MAC_SMOKE_CLI=true
      shift
      ;;
    --developer-id-sign)
      MAC_DEVELOPER_ID_SIGN=true
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

if [[ "$BUILD_MAC" == false && "$MAC_SMOKE_CLI" == true ]]; then
  echo "--smoke-cli requires a macOS build target" >&2
  exit 1
fi

mkdir -p "$DIST_DIR"

mac_build_fingerprint() {
  local source_paths=(
    "$MAC_PROJECT_DIR/Package.swift"
    "$MAC_PROJECT_DIR/Sources"
    "$MAC_PROJECT_DIR/Resources"
    "$ROOT_DIR/scripts/build-all.sh"
    "$ROOT_DIR/scripts/smoke-mac-common.sh"
    "$ROOT_DIR/scripts/auto-pair.sh"
    "$ROOT_DIR/scripts/hardware-smoke-test-auto.sh"
    "$ROOT_DIR/scripts/test-all.sh"
  )

  local existing_paths=()
  local path
  for path in "${source_paths[@]}"; do
    [[ -e "$path" ]] && existing_paths+=("$path")
  done

  if [[ ${#existing_paths[@]} -eq 0 ]]; then
    echo "unknown"
    return
  fi

  find "${existing_paths[@]}" -type f -print0 \
    | sort -z \
    | xargs -0 shasum -a 256 \
    | shasum -a 256 \
    | awk '{print $1}'
}

build_mac() {
  if ! command -v swift >/dev/null 2>&1; then
    echo "swift not found. Install Xcode command-line tools first." >&2
    exit 1
  fi

  local build_label="==> Building macOS app"
  local scratch_path="$MAC_PROJECT_DIR/.build"
  local build_args=(
    --configuration release
    --package-path "$MAC_PROJECT_DIR"
  )

  if [[ "$MAC_SMOKE_CLI" == true ]]; then
    build_label+=" (smoke CLI enabled)"
    scratch_path="$MAC_PROJECT_DIR/.build-smoke"
    build_args+=(
      --scratch-path "$scratch_path"
      -Xswiftc -DSMOKE_TEST_CLI
    )
  fi

  echo "$build_label"
  swift build "${build_args[@]}"

  local binary_path="$scratch_path/release/ClipRelay"
  if [[ ! -x "$binary_path" ]]; then
    if [[ -x "$scratch_path/arm64-apple-macosx/release/ClipRelay" ]]; then
      binary_path="$scratch_path/arm64-apple-macosx/release/ClipRelay"
    elif [[ -x "$scratch_path/x86_64-apple-macosx/release/ClipRelay" ]]; then
      binary_path="$scratch_path/x86_64-apple-macosx/release/ClipRelay"
    else
      echo "Could not locate built macOS binary." >&2
      exit 1
    fi
  fi

  local app_name="ClipRelay.app"
  if [[ "$MAC_SMOKE_CLI" == true ]]; then
    app_name="ClipRelay-smoke.app"
  fi

  local app_dir="$DIST_DIR/$app_name"
  if [[ "$MAC_SMOKE_CLI" == false ]]; then
    # Normal builds invalidate the smoke-only bundle so smoke scripts never
    # silently reuse an older smoke artifact after a fresh default build.
    rm -rf "$DIST_DIR/ClipRelay-smoke.app"
  fi
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

  local extra_plist_keys=""
  local bundle_identifier="org.cliprelay.mac"
  local sparkle_keys="$SPARKLE_PLIST_KEYS"
  local build_fingerprint
  build_fingerprint="$(mac_build_fingerprint)"
  local sparkle_feed_block="  <key>SUFeedURL</key>
  <string>https://updates.cliprelay.org/appcast.xml</string>
  <key>SUScheduledCheckInterval</key>
  <integer>7200</integer>"
  if [[ "$MAC_SMOKE_CLI" == true ]]; then
    bundle_identifier="org.cliprelay.mac.smoke"
    sparkle_keys=""
    sparkle_feed_block=""
    extra_plist_keys="  <key>ClipRelaySmokeCLI</key>
  <true/>"
  fi

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
  <string>${bundle_identifier}</string>
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
  <key>ClipRelayBuildFingerprint</key>
  <string>${build_fingerprint}</string>
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>ClipRelay uses Bluetooth Low Energy to discover and sync clipboard text with your paired Android devices.</string>
  <key>LSUIElement</key>
  <true/>
  ${sparkle_feed_block}
  ${sparkle_keys}
  ${extra_plist_keys}
</dict>
</plist>
PLIST

  sign_path() {
    local identity="$1"
    local target_path="$2"
    local entitlements_arg="${3:-}"
    local hardened_runtime="$4"
    local timestamp_flag="${5:-false}"
    local cmd=(codesign --force --sign "$identity")

    if [[ -n "$entitlements_arg" ]]; then
      cmd+=(--entitlements "$entitlements_arg")
    fi
    if [[ "$hardened_runtime" == true ]]; then
      cmd+=(--options runtime)
    fi
    if [[ "$timestamp_flag" == true ]]; then
      cmd+=(--timestamp)
    fi

    cmd+=("$target_path")
    "${cmd[@]}"
  }

  sign_sparkle_framework() {
    local identity="$1"
    local framework_path="$2"
    local hardened_runtime="$3"
    local timestamp_flag="$4"
    local nested_bundle
    local nested_binary

    while IFS= read -r nested_bundle; do
      [[ -n "$nested_bundle" ]] || continue
      sign_path "$identity" "$nested_bundle" "" "$hardened_runtime" "$timestamp_flag"
    done < <(
      find "$framework_path" -mindepth 1 -type d \
        \( -name "*.app" -o -name "*.xpc" -o -name "*.framework" \) \
        | awk '{ print length($0) "\t" $0 }' \
        | sort -rn \
        | cut -f2-
    )

    while IFS= read -r nested_binary; do
      [[ -n "$nested_binary" ]] || continue
      sign_path "$identity" "$nested_binary" "" "$hardened_runtime" "$timestamp_flag"
    done < <(
      find "$framework_path" -type f -perm -111 \
        ! -path "*/_CodeSignature/*" \
        ! -path "*/Resources/*"
    )

    sign_path "$identity" "$framework_path" "" "$hardened_runtime" "$timestamp_flag"
  }

  # ── Sign bundle ──
  local entitlements_path="$ROOT_DIR/macos/ClipRelayMac/Resources/ClipRelay.entitlements"
  local dev_id="Developer ID Application: Christian Theilemann (B66YFKPUA8)"
  local framework_path="$app_dir/Contents/Frameworks/Sparkle.framework"
  local binary_target="$app_dir/Contents/MacOS/ClipRelay"
  if [[ "$MAC_DEVELOPER_ID_SIGN" == true ]]; then
    if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$dev_id"; then
      echo "Requested --developer-id-sign but Developer ID identity was not found: $dev_id" >&2
      exit 1
    fi
    echo "Signing with Developer ID + hardened runtime..."
    if [[ -d "$framework_path" ]]; then
      sign_sparkle_framework "$dev_id" "$framework_path" true true
    fi
    sign_path "$dev_id" "$binary_target" "$entitlements_path" true true
    sign_path "$dev_id" "$app_dir" "$entitlements_path" true true
  else
    # Keep normal local builds off the Developer ID certificate path so build
    # and test loops do not touch the login keychain or prompt for certificate
    # access. Release publishing is handled separately by publish-mac.sh.
    echo "Signing ad-hoc for local use..."
    if [[ -d "$framework_path" ]]; then
      sign_sparkle_framework "-" "$framework_path" false false
    fi
    sign_path "-" "$binary_target" "$entitlements_path" false false
    sign_path "-" "$app_dir" "$entitlements_path" false false
  fi
  codesign --verify --deep --strict "$app_dir"
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

  if [[ "$ANDROID_RELEASE" == true ]]; then
    echo "==> Building Android release AAB/APK"
    (
      cd "$ANDROID_PROJECT_DIR"
      ./gradlew clean bundleRelease assembleRelease
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
      ./gradlew assembleDebug
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
