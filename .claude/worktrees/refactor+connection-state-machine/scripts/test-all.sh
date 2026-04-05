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

echo "==> Test suite complete"
