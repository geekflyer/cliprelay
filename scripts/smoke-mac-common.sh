#!/usr/bin/env bash

SMOKE_MAC_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SMOKE_MAC_DIST_DIR="${DIST_DIR:-$(cd "$SMOKE_MAC_COMMON_DIR/.." && pwd)/dist}"

MAC_SMOKE_KEYCHAIN_SERVICE="${CLIPRELAY_PAIRING_KEYCHAIN_SERVICE:-cliprelay-smoke}"
MAC_SMOKE_KEYCHAIN_PATH="${CLIPRELAY_PAIRING_KEYCHAIN_PATH:-$SMOKE_MAC_DIST_DIR/ClipRelaySmoke.keychain-db}"
MAC_SMOKE_KEYCHAIN_PASSWORD="${CLIPRELAY_PAIRING_KEYCHAIN_PASSWORD:-cliprelay-smoke-password}"

prepare_mac_smoke_keychain() {
  mkdir -p "$(dirname "$MAC_SMOKE_KEYCHAIN_PATH")"
  security delete-keychain "$MAC_SMOKE_KEYCHAIN_PATH" >/dev/null 2>&1 || true
  rm -f "$MAC_SMOKE_KEYCHAIN_PATH"
  security create-keychain -p "$MAC_SMOKE_KEYCHAIN_PASSWORD" "$MAC_SMOKE_KEYCHAIN_PATH" >/dev/null
  security set-keychain-settings -lut 21600 "$MAC_SMOKE_KEYCHAIN_PATH" >/dev/null
  security unlock-keychain -p "$MAC_SMOKE_KEYCHAIN_PASSWORD" "$MAC_SMOKE_KEYCHAIN_PATH" >/dev/null
}

smoke_mac_env() {
  CLIPRELAY_PAIRING_KEYCHAIN_SERVICE="$MAC_SMOKE_KEYCHAIN_SERVICE" \
  CLIPRELAY_PAIRING_KEYCHAIN_PATH="$MAC_SMOKE_KEYCHAIN_PATH" \
  CLIPRELAY_PAIRING_KEYCHAIN_PASSWORD="$MAC_SMOKE_KEYCHAIN_PASSWORD" \
    "$@"
}

smoke_open_mac_app() {
  local app_path="$1"
  local stdout_path="${2:-/dev/null}"
  local stderr_path="${3:-/dev/null}"
  open -n -g \
    --stdout "$stdout_path" \
    --stderr "$stderr_path" \
    --env "CLIPRELAY_PAIRING_KEYCHAIN_SERVICE=$MAC_SMOKE_KEYCHAIN_SERVICE" \
    --env "CLIPRELAY_PAIRING_KEYCHAIN_PATH=$MAC_SMOKE_KEYCHAIN_PATH" \
    --env "CLIPRELAY_PAIRING_KEYCHAIN_PASSWORD=$MAC_SMOKE_KEYCHAIN_PASSWORD" \
    "$app_path"
}
