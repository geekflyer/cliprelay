#!/usr/bin/env bash
# Runs the full test suite (Swift package tests and Android unit tests).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANDROID_PROJECT_DIR="$ROOT_DIR/android"
MAC_PROJECT_DIR="$ROOT_DIR/macos/ClipRelayMac"

if [[ ! -x "$ANDROID_PROJECT_DIR/gradlew" ]]; then
  echo "Gradle wrapper missing at android/gradlew" >&2
  exit 1
fi

if ! command -v swift >/dev/null 2>&1; then
  echo "swift not found. Install Xcode command-line tools first." >&2
  exit 1
fi

echo "==> Running Android unit tests"
(
  cd "$ANDROID_PROJECT_DIR"
  ./gradlew testDebugUnitTest
)

echo "==> Running macOS unit tests"
swift test --package-path "$MAC_PROJECT_DIR"

echo "==> Verifying macOS smoke CLI app bundle"
"$ROOT_DIR/scripts/build-all.sh" --mac-only --smoke-cli
source "$ROOT_DIR/scripts/smoke-mac-common.sh"

expected_hash="$(git -C "$ROOT_DIR" rev-parse --short HEAD)"
/usr/libexec/PlistBuddy -c "Set :ClipRelayGitHash stale-smoke-hash" "$SMOKE_MAC_INFO_PLIST"
smoke_test_token="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
ensure_smoke_mac_app

rebuilt_hash="$(/usr/libexec/PlistBuddy -c 'Print :ClipRelayGitHash' "$SMOKE_MAC_INFO_PLIST" 2>/dev/null || true)"
if [[ "$rebuilt_hash" != "$expected_hash" ]]; then
  echo "Expected stale smoke app to be rebuilt with current git hash $expected_hash, got $rebuilt_hash" >&2
  exit 1
fi

set +e
run_smoke_mac_cli --smoke-import-pairing --token "$smoke_test_token" --name "Smoke Test Android" >/dev/null 2>&1
smoke_import_status=$?
run_smoke_mac_cli --smoke-remove-pairing --token "$smoke_test_token" >/dev/null 2>&1
smoke_remove_status=$?
set -e

if [[ "$smoke_import_status" -ne 0 ]]; then
  echo "Expected smoke CLI release binary to import a valid token with exit 0, got $smoke_import_status" >&2
  exit 1
fi

if [[ "$smoke_remove_status" -ne 0 ]]; then
  echo "Expected smoke CLI release binary to remove a valid token with exit 0, got $smoke_remove_status" >&2
  exit 1
fi

echo "==> Test suite complete"
