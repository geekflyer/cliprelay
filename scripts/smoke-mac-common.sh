# Shared helpers for smoke-test-specific macOS app handling.

if [[ -z "${ROOT_DIR:-}" ]]; then
  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
PRIMARY_MAC_APP_PATH="${PRIMARY_MAC_APP_PATH:-$DIST_DIR/ClipRelay.app}"
SMOKE_MAC_APP_PATH="${SMOKE_MAC_APP_PATH:-$DIST_DIR/ClipRelay-smoke.app}"
PRIMARY_MAC_INFO_PLIST="${PRIMARY_MAC_INFO_PLIST:-$PRIMARY_MAC_APP_PATH/Contents/Info.plist}"
SMOKE_MAC_INFO_PLIST="${SMOKE_MAC_INFO_PLIST:-$SMOKE_MAC_APP_PATH/Contents/Info.plist}"
PRIMARY_MAC_BINARY_PATH="${PRIMARY_MAC_BINARY_PATH:-$PRIMARY_MAC_APP_PATH/Contents/MacOS/ClipRelay}"
SMOKE_MAC_BINARY_PATH="${SMOKE_MAC_BINARY_PATH:-$SMOKE_MAC_APP_PATH/Contents/MacOS/ClipRelay}"

current_repo_git_hash() {
  git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || true
}

app_git_hash() {
  local info_plist="$1"
  [[ -f "$info_plist" ]] || return 1
  /usr/libexec/PlistBuddy -c 'Print :ClipRelayGitHash' "$info_plist" 2>/dev/null || true
}

app_build_fingerprint() {
  local info_plist="$1"
  [[ -f "$info_plist" ]] || return 1
  /usr/libexec/PlistBuddy -c 'Print :ClipRelayBuildFingerprint' "$info_plist" 2>/dev/null || true
}

current_build_fingerprint() {
  local source_paths=(
    "$ROOT_DIR/macos/ClipRelayMac/Package.swift"
    "$ROOT_DIR/macos/ClipRelayMac/Sources"
    "$ROOT_DIR/macos/ClipRelayMac/Resources"
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

app_matches_current_repo() {
  local info_plist="$1"
  local expected_hash
  local bundled_hash
  local expected_fingerprint
  local bundled_fingerprint

  expected_hash="$(current_repo_git_hash)"
  bundled_hash="$(app_git_hash "$info_plist")"
  expected_fingerprint="$(current_build_fingerprint)"
  bundled_fingerprint="$(app_build_fingerprint "$info_plist")"

  [[ -n "$expected_hash" ]] || return 1
  [[ "$bundled_hash" == "$expected_hash" ]] || return 1
  [[ "$bundled_fingerprint" == "$expected_fingerprint" ]]
}

smoke_mac_app_has_cli() {
  [[ -f "$SMOKE_MAC_INFO_PLIST" ]] || return 1
  /usr/libexec/PlistBuddy -c 'Print :ClipRelaySmokeCLI' "$SMOKE_MAC_INFO_PLIST" 2>/dev/null | grep -qi '^true$'
}

ensure_smoke_mac_app() {
  if smoke_mac_app_has_cli && app_matches_current_repo "$SMOKE_MAC_INFO_PLIST"; then
    return
  fi

  echo "- Building smoke-capable macOS app"
  "$ROOT_DIR/scripts/build-all.sh" --mac-only --smoke-cli
}

ensure_primary_mac_app() {
  if [[ -d "$PRIMARY_MAC_APP_PATH" ]] && app_matches_current_repo "$PRIMARY_MAC_INFO_PLIST"; then
    return
  fi

  echo "- Building primary macOS app"
  "$ROOT_DIR/scripts/build-all.sh" --mac-only
}

run_smoke_mac_cli() {
  ensure_smoke_mac_app

  if [[ ! -x "$SMOKE_MAC_BINARY_PATH" ]]; then
    echo "Smoke CLI binary not found: $SMOKE_MAC_BINARY_PATH" >&2
    return 1
  fi

  "$SMOKE_MAC_BINARY_PATH" "$@"
}

start_primary_mac_app() {
  ensure_primary_mac_app

  if [[ ! -d "$PRIMARY_MAC_APP_PATH" ]]; then
    echo "Primary macOS app not found: $PRIMARY_MAC_APP_PATH" >&2
    return 1
  fi

  open "$PRIMARY_MAC_APP_PATH"
  wait_for_primary_mac_app_running
}

wait_for_primary_mac_app_running() {
  local attempts="${1:-20}"
  local i
  for ((i = 1; i <= attempts; i++)); do
    if pgrep -f 'ClipRelay.app/Contents/MacOS/ClipRelay' >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  echo "Primary ClipRelay app did not stay running after smoke launch." >&2
  return 1
}
