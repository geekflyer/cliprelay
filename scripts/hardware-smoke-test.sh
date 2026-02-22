#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
ANDROID_APP_ID="com.clipshare"
MAC_APP_PATH="$DIST_DIR/GreenPaste.app"
MAC_BIN="$MAC_APP_PATH/Contents/MacOS/GreenPaste"

ANDROID_SERIAL=""
TIMEOUT_SEC=90
KEEP_PAIRING=false
PAIR_TOKEN=""

usage() {
  cat <<'EOF'
Usage: ./scripts/hardware-smoke-test.sh [--serial <adb-serial>] [--timeout <seconds>] [--keep-pairing]

Runs a near-fully automated BLE smoke test on debug builds:
  1) Generates and imports a fresh pairing token on macOS and Android
  2) Verifies Android -> Mac transfer
  3) Verifies Mac -> Android transfer
  4) Attempts Bluetooth reconnect cycle and re-verifies both directions

Notes:
  - Requires an attached Android device with USB debugging enabled
  - Requires debug APK installed (for debug smoke receiver and probe state)
  - Cleans up the temporary pairing token on both devices at the end (unless --keep-pairing is set)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --serial)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --serial" >&2
        exit 1
      fi
      ANDROID_SERIAL="$2"
      shift 2
      ;;
    --timeout)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --timeout" >&2
        exit 1
      fi
      TIMEOUT_SEC="$2"
      shift 2
      ;;
    --keep-pairing)
      KEEP_PAIRING=true
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

ADB=(adb)
if [[ -n "$ANDROID_SERIAL" ]]; then
  ADB=(adb -s "$ANDROID_SERIAL")
fi

cleanup_smoke_pairing() {
  if [[ "$KEEP_PAIRING" == true ]]; then
    return
  fi
  if [[ -z "$PAIR_TOKEN" ]]; then
    return
  fi

  echo "- Cleaning up smoke pairing token"
  "$MAC_BIN" --smoke-remove-pairing --token "$PAIR_TOKEN" >/dev/null 2>&1 || true
  ${ADB[@]} shell am broadcast \
    -n com.clipshare/.debug.DebugSmokeReceiver \
    -a com.clipshare.debug.CLEAR_PAIRING \
    --receiver-foreground >/dev/null 2>&1 || true
}

trap cleanup_smoke_pairing EXIT

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Required command not found: $cmd" >&2
    exit 1
  fi
}

probe_json() {
  ${ADB[@]} shell run-as "$ANDROID_APP_ID" cat files/debug-smoke-state.json 2>/dev/null | tr -d '\r' || true
}

probe_get() {
  local key="$1"
  local default_value="${2:-}"
  local raw
  raw="$(probe_json)"
  if [[ -z "$raw" ]]; then
    printf '%s' "$default_value"
    return 1
  fi

  SMOKE_JSON="$raw" python3 - "$key" "$default_value" <<'PY'
import json
import os
import sys

key = sys.argv[1]
default_value = sys.argv[2]

try:
    payload = json.loads(os.environ.get("SMOKE_JSON", ""))
except Exception:
    print(default_value)
    sys.exit(1)

current = payload
for part in key.split('.'):
    if isinstance(current, dict) and part in current:
        current = current[part]
    else:
        print(default_value)
        sys.exit(1)

if isinstance(current, bool):
    print("true" if current else "false")
elif current is None:
    print("")
else:
    print(current)
PY
}

wait_for_probe_value() {
  local key="$1"
  local expected="$2"
  local timeout="$3"
  local start_ts
  start_ts="$(date +%s)"

  while true; do
    local value
    value="$(probe_get "$key" "")"
    if [[ "$value" == "$expected" ]]; then
      return 0
    fi

    local now_ts
    now_ts="$(date +%s)"
    if (( now_ts - start_ts >= timeout )); then
      echo "Timed out waiting for probe value: $key=$expected (last='$value')" >&2
      return 1
    fi
    sleep 1
  done
}

wait_for_probe_counter_gt() {
  local baseline="$1"
  local timeout="$2"
  local start_ts
  start_ts="$(date +%s)"

  while true; do
    local value
    value="$(probe_get "event_counter" "0")"
    if [[ "$value" =~ ^[0-9]+$ ]] && (( value > baseline )); then
      return 0
    fi

    local now_ts
    now_ts="$(date +%s)"
    if (( now_ts - start_ts >= timeout )); then
      echo "Timed out waiting for probe event counter to increase (baseline=$baseline, last=$value)" >&2
      return 1
    fi
    sleep 1
  done
}

wait_for_mac_clipboard() {
  local expected="$1"
  local timeout="$2"
  local start_ts
  start_ts="$(date +%s)"

  while true; do
    local current
    current="$(pbpaste)"
    if [[ "$current" == "$expected" ]]; then
      return 0
    fi

    local now_ts
    now_ts="$(date +%s)"
    if (( now_ts - start_ts >= timeout )); then
      echo "Timed out waiting for macOS clipboard payload" >&2
      return 1
    fi
    sleep 1
  done
}

send_android_share_text() {
  local text="$1"
  ${ADB[@]} shell am start \
    -n com.clipshare/.ui.ShareReceiverActivity \
    -a android.intent.action.SEND \
    -t text/plain \
    --es android.intent.extra.TEXT "$text" >/dev/null
}

wait_for_mac_clipboard_with_retries() {
  local text="$1"
  local timeout="$2"
  local send_interval=3
  local start_ts
  start_ts="$(date +%s)"
  local last_send_ts=0

  while true; do
    local now_ts
    now_ts="$(date +%s)"

    if (( now_ts - last_send_ts >= send_interval )); then
      send_android_share_text "$text"
      last_send_ts="$now_ts"
    fi

    if [[ "$(pbpaste)" == "$text" ]]; then
      return 0
    fi

    if (( now_ts - start_ts >= timeout )); then
      echo "Timed out waiting for macOS clipboard payload" >&2
      return 1
    fi
    sleep 1
  done
}

wait_for_probe_after_mac_copy_with_retries() {
  local prefix="$1"
  local timeout="$2"
  local start_ts
  start_ts="$(date +%s)"
  local attempt=0

  while true; do
    attempt=$((attempt + 1))
    local payload="${prefix}-a${attempt}"
    printf '%s' "$payload" | pbcopy

    local inner_start
    inner_start="$(date +%s)"
    while true; do
      if [[ "$(probe_get "last_inbound_text" "")" == "$payload" ]]; then
        printf '%s' "$payload"
        return 0
      fi

      local now_ts
      now_ts="$(date +%s)"
      if (( now_ts - inner_start >= 5 )); then
        break
      fi
      sleep 1
    done

    local now_ts
    now_ts="$(date +%s)"
    if (( now_ts - start_ts >= timeout )); then
      echo "Timed out waiting for Android probe inbound clipboard" >&2
      return 1
    fi
  done
}

broadcast_debug_action() {
  local action="$1"
  shift
  local output
  output="$(
    ${ADB[@]} shell am broadcast \
      -n com.clipshare/.debug.DebugSmokeReceiver \
      -a "$action" \
      --receiver-foreground \
      "$@" 2>&1 | tr -d '\r'
  )"
  if [[ "$output" != *"result=1"* ]]; then
    echo "Debug broadcast failed for action: $action" >&2
    echo "$output" >&2
    return 1
  fi
}

start_android_app() {
  ${ADB[@]} shell am start -W -n com.clipshare/.ui.MainActivity >/dev/null 2>&1 || true
}

start_mac_app() {
  if pgrep -f "GreenPaste.app/Contents/MacOS/GreenPaste" >/dev/null 2>&1; then
    return
  fi

  open "$MAC_APP_PATH"

  local attempts=0
  until pgrep -f "GreenPaste.app/Contents/MacOS/GreenPaste" >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    if (( attempts >= 20 )); then
      echo "GreenPaste app did not stay running after launch." >&2
      echo "Check macOS logs: /usr/bin/log show --last 5m --style compact --predicate 'process == \"GreenPaste\"'" >&2
      exit 1
    fi
    sleep 1
  done
}

toggle_bluetooth() {
  if ${ADB[@]} shell cmd bluetooth_manager disable >/dev/null 2>&1; then
    if ! ${ADB[@]} shell cmd bluetooth_manager wait-for-state:STATE_OFF >/dev/null 2>&1; then
      return 1
    fi
    if ! ${ADB[@]} shell cmd bluetooth_manager enable >/dev/null 2>&1; then
      return 1
    fi
    if ! ${ADB[@]} shell cmd bluetooth_manager wait-for-state:STATE_ON >/dev/null 2>&1; then
      return 1
    fi
    return 0
  fi

  if ${ADB[@]} shell svc bluetooth disable >/dev/null 2>&1; then
    sleep 3
    ${ADB[@]} shell svc bluetooth enable >/dev/null 2>&1
    return 0
  fi

  return 1
}

echo "==> Automated hardware smoke preflight"

require_cmd adb
require_cmd openssl
require_cmd pbcopy
require_cmd pbpaste
require_cmd python3

if [[ ! -d "$MAC_APP_PATH" ]]; then
  echo "Missing macOS app bundle: $MAC_APP_PATH" >&2
  echo "Build first: ./scripts/build-all.sh" >&2
  exit 1
fi

if [[ ! -x "$MAC_BIN" ]]; then
  echo "Missing macOS binary: $MAC_BIN" >&2
  exit 1
fi

if [[ ! -f "$DIST_DIR/greenpaste-debug.apk" ]]; then
  echo "Missing Android APK: $DIST_DIR/greenpaste-debug.apk" >&2
  echo "Build first: ./scripts/build-all.sh" >&2
  exit 1
fi

DEVICE_STATE="$(${ADB[@]} get-state 2>/dev/null || true)"
if [[ "$DEVICE_STATE" != "device" ]]; then
  echo "No online Android device detected via adb" >&2
  exit 1
fi

echo "- Installing latest debug APK"
${ADB[@]} install -r "$DIST_DIR/greenpaste-debug.apk" >/dev/null

for permission in \
  android.permission.BLUETOOTH_SCAN \
  android.permission.BLUETOOTH_CONNECT \
  android.permission.BLUETOOTH_ADVERTISE \
  android.permission.POST_NOTIFICATIONS
do
  ${ADB[@]} shell pm grant "$ANDROID_APP_ID" "$permission" >/dev/null 2>&1 || true
done

ANDROID_MODEL="$(${ADB[@]} shell getprop ro.product.model | tr -d '\r')"
MAC_NAME_RAW="$(scutil --get ComputerName 2>/dev/null || hostname)"
MAC_NAME="$(printf '%s' "$MAC_NAME_RAW" | tr -cs '[:alnum:]_-.' '_')"
PAIR_TOKEN="$(openssl rand -hex 32)"

echo "- Android device: ${ANDROID_MODEL}"
echo "- Importing fresh pairing token"

pkill -f "GreenPaste.app/Contents/MacOS/GreenPaste" >/dev/null 2>&1 || true
"$MAC_BIN" --smoke-import-pairing --token "$PAIR_TOKEN" --name "$ANDROID_MODEL" >/dev/null

${ADB[@]} shell am force-stop "$ANDROID_APP_ID" >/dev/null 2>&1 || true
start_android_app
sleep 2

broadcast_debug_action "com.clipshare.debug.IMPORT_PAIRING" --es token "$PAIR_TOKEN" --es device_name "$MAC_NAME"
broadcast_debug_action "com.clipshare.debug.RESET_PROBE"

start_mac_app

echo "- Waiting for BLE connection"
wait_for_probe_value "connected" "true" "$TIMEOUT_SEC"

android_to_mac_text="smoke-a2m-$(date +%s)-$RANDOM"
echo "- Running Android -> Mac transfer"
printf '%s' "pre-smoke-marker" | pbcopy
wait_for_mac_clipboard_with_retries "$android_to_mac_text" "$TIMEOUT_SEC"

echo "- Running Mac -> Android transfer"
mac_to_android_text="$(wait_for_probe_after_mac_copy_with_retries "smoke-m2a-$(date +%s)-$RANDOM" "$TIMEOUT_SEC")"

echo "- Running reconnect cycle"
counter_before_reconnect="$(probe_get "event_counter" "0")"
if ! toggle_bluetooth; then
  echo "Could not toggle Bluetooth via adb shell commands" >&2
  echo "Try manual toggle and rerun this script." >&2
  exit 1
fi

wait_for_probe_counter_gt "$counter_before_reconnect" 30
wait_for_probe_value "connected" "true" "$TIMEOUT_SEC"

android_to_mac_text_re="smoke-a2m-re-$(date +%s)-$RANDOM"
echo "- Re-verify Android -> Mac after reconnect"
wait_for_mac_clipboard_with_retries "$android_to_mac_text_re" "$TIMEOUT_SEC"

echo "- Re-verify Mac -> Android after reconnect"
mac_to_android_text_re="$(wait_for_probe_after_mac_copy_with_retries "smoke-m2a-re-$(date +%s)-$RANDOM" "$TIMEOUT_SEC")"

echo
echo "==> Automated BLE smoke: PASS"
echo "Pair token tail: ${PAIR_TOKEN:56:8}"
echo "Android -> Mac payload: $android_to_mac_text_re"
echo "Mac -> Android payload: $mac_to_android_text_re"
