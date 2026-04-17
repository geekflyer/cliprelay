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

echo "==> Verifying macOS smoke CLI binary"
source "$ROOT_DIR/scripts/smoke-mac-common.sh"

if [[ ! -x "$ROOT_DIR/dist/ClipRelaySmokeCLI" ]]; then
  echo "Expected macOS smoke CLI at dist/ClipRelaySmokeCLI. Run scripts/build-all.sh first." >&2
  exit 1
fi

prepare_mac_smoke_keychain
smoke_test_token="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

set +e
smoke_mac_env "$ROOT_DIR/dist/ClipRelaySmokeCLI" --smoke-import-pairing --token "$smoke_test_token" --name "Smoke Test Android" >/dev/null 2>&1
smoke_import_status=$?
smoke_mac_env "$ROOT_DIR/dist/ClipRelaySmokeCLI" --smoke-remove-pairing --token "$smoke_test_token" >/dev/null 2>&1
smoke_remove_status=$?
set -e

if [[ "$smoke_import_status" -ne 0 ]]; then
  echo "Expected standalone smoke CLI to import a valid token with exit 0, got $smoke_import_status" >&2
  exit 1
fi

if [[ "$smoke_remove_status" -ne 0 ]]; then
  echo "Expected standalone smoke CLI to remove a valid token with exit 0, got $smoke_remove_status" >&2
  exit 1
fi

echo "==> Test suite complete"
