#!/usr/bin/env bash
# End-to-end BLE hardware smoke test: pairs devices, syncs clipboard, and verifies round-trip.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
ANDROID_APP_ID="org.cliprelay"
MAC_APP_PATH="$DIST_DIR/ClipRelay.app"
MAC_BIN="$MAC_APP_PATH/Contents/MacOS/ClipRelay"

ANDROID_SERIAL=""
WIRELESS_DEBUG=false
WIRELESS_ENDPOINT=""
ADB_PAIR_ENDPOINT=""
ADB_PAIR_CODE=""
TIMEOUT_SEC=90
BLE_CONNECT_TIMEOUT_MAX_SEC=10
KEEP_PAIRING=false
PAIR_TOKEN=""
CONNECTION_STABILITY_SECONDS=8
M2A_STRESS_COUNT=0
M2A_STRESS_TIMEOUT_SEC=12

usage() {
  cat <<'EOF'
Usage: ./scripts/hardware-smoke-test-auto.sh [options]

Options:
  --serial <adb-serial>         Use a specific adb serial
  --wireless                    Require a wireless adb target (ip:port)
  --connect <ip:port>           Run `adb connect` before starting
  --pair <ip:port> --pair-code <code>
                                Run `adb pair` before connecting
  --timeout <seconds>           Per-step timeout (default: 90)
  --stability-seconds <seconds> Connected-state hold check before transfers (default: 8)
  --m2a-stress-count <count>    Run extra Mac->Android stress iterations (default: 0)
  --m2a-stress-timeout <sec>    Timeout per stress iteration (default: 12)
  --keep-pairing                Keep temporary smoke pairing token

Runs a near-fully automated BLE smoke test on debug builds:
  1) Generates and imports a fresh pairing token on macOS and Android
  2) Verifies Android -> Mac transfer
  3) Verifies Mac -> Android transfer
  4) Attempts Bluetooth reconnect cycle and re-verifies both directions

Notes:
  - Requires an attached Android device via USB debugging or wireless debugging
  - Requires debug APK installed (for debug smoke receiver and probe state)
  - BLE connection waits are capped at 10 seconds
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
    --wireless)
      WIRELESS_DEBUG=true
      shift
      ;;
    --connect)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --connect" >&2
        exit 1
      fi
      WIRELESS_ENDPOINT="$2"
      WIRELESS_DEBUG=true
      shift 2
      ;;
    --pair)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --pair" >&2
        exit 1
      fi
      ADB_PAIR_ENDPOINT="$2"
      WIRELESS_DEBUG=true
      shift 2
      ;;
    --pair-code)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --pair-code" >&2
        exit 1
      fi
      ADB_PAIR_CODE="$2"
      WIRELESS_DEBUG=true
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
    --stability-seconds)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --stability-seconds" >&2
        exit 1
      fi
      CONNECTION_STABILITY_SECONDS="$2"
      shift 2
      ;;
    --m2a-stress-count)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --m2a-stress-count" >&2
        exit 1
      fi
      M2A_STRESS_COUNT="$2"
      shift 2
      ;;
    --m2a-stress-timeout)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --m2a-stress-timeout" >&2
        exit 1
      fi
      M2A_STRESS_TIMEOUT_SEC="$2"
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

require_non_negative_int() {
  local value="$1"
  local flag_name="$2"
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    echo "Invalid value for ${flag_name}: ${value}" >&2
    exit 1
  fi
}

require_non_negative_int "$TIMEOUT_SEC" "--timeout"
require_non_negative_int "$CONNECTION_STABILITY_SECONDS" "--stability-seconds"
require_non_negative_int "$M2A_STRESS_COUNT" "--m2a-stress-count"
require_non_negative_int "$M2A_STRESS_TIMEOUT_SEC" "--m2a-stress-timeout"

if [[ -n "$ADB_PAIR_ENDPOINT" || -n "$ADB_PAIR_CODE" ]]; then
  if [[ -z "$ADB_PAIR_ENDPOINT" || -z "$ADB_PAIR_CODE" ]]; then
    echo "Both --pair and --pair-code are required together" >&2
    exit 1
  fi
fi

select_target_device() {
  local state

  if [[ -n "$ANDROID_SERIAL" ]]; then
    state="$(adb -s "$ANDROID_SERIAL" get-state 2>/dev/null || true)"
    if [[ "$state" != "device" ]]; then
      echo "Android device '$ANDROID_SERIAL' is not online" >&2
      exit 1
    fi
    ADB=(adb -s "$ANDROID_SERIAL")
    return
  fi

  local all_devices=()
  while IFS= read -r serial; do
    [[ -n "$serial" ]] && all_devices+=("$serial")
  done < <(adb devices | tr -d '\r' | awk -F '\t' 'NR > 1 && $2 == "device" { print $1 }')

  if [[ ${#all_devices[@]} -eq 0 ]]; then
    echo "No online Android device detected via adb" >&2
    if [[ "$WIRELESS_DEBUG" == true ]]; then
      echo "Tip: use --connect <ip:port> (and optionally --pair/--pair-code first)." >&2
    fi
    exit 1
  fi

  if [[ "$WIRELESS_DEBUG" == true ]]; then
    local wireless_devices=()
    local serial
    for serial in "${all_devices[@]}"; do
      if is_wireless_serial "$serial"; then
        wireless_devices+=("$serial")
      fi
    done

    if [[ ${#wireless_devices[@]} -eq 0 ]]; then
      echo "Wireless debugging requested, but no wireless adb device is online." >&2
      echo "Run with --connect <ip:port> after enabling Wireless debugging." >&2
      exit 1
    fi

    if [[ ${#wireless_devices[@]} -gt 1 ]]; then
      echo "Multiple wireless adb devices found: ${wireless_devices[*]}" >&2
      echo "Use --serial <adb-serial> to choose one." >&2
      exit 1
    fi

    ANDROID_SERIAL="${wireless_devices[0]}"
    ADB=(adb -s "$ANDROID_SERIAL")
    return
  fi

  if [[ ${#all_devices[@]} -gt 1 ]]; then
    echo "Multiple adb devices found: ${all_devices[*]}" >&2
    echo "Use --serial <adb-serial> to choose one." >&2
    exit 1
  fi

  ANDROID_SERIAL="${all_devices[0]}"
  ADB=(adb -s "$ANDROID_SERIAL")
}

is_wireless_serial() {
  local serial="$1"
  if [[ "$serial" == *:* ]]; then
    return 0
  fi
  if [[ "$serial" == *"._adb-tls-connect._tcp"* ]]; then
    return 0
  fi
  return 1
}

cleanup_smoke_pairing() {
  if [[ "$KEEP_PAIRING" == true ]]; then
    return
  fi
  if [[ -z "$PAIR_TOKEN" ]]; then
    return
  fi

  echo "- Cleaning up smoke pairing token"
  "$MAC_BIN" --smoke-remove-pairing --token "$PAIR_TOKEN" >/dev/null 2>&1 || true
  "${ADB[@]}" shell am broadcast \
    -n org.cliprelay/.debug.DebugSmokeReceiver \
    -a org.cliprelay.debug.CLEAR_PAIRING \
    --receiver-foreground >/dev/null 2>&1 || true
}

trap cleanup_smoke_pairing EXIT

dump_failure_diagnostics() {
  echo
  echo "==> Failure diagnostics"

  local probe
  probe="$(probe_json)"
  if [[ -n "$probe" ]]; then
    echo "- Android debug probe state:"
    echo "$probe"
  else
    echo "- Android debug probe state unavailable"
  fi

  echo "- Recent Android BLE logs:"
  "${ADB[@]}" logcat -d -s BluetoothGattServer ClipRelayService L2capServer PsmGattServer 2>/dev/null || true

  echo "- Recent macOS ClipRelay logs:"
  /usr/bin/log show --last 2m --style compact --info --debug --predicate 'subsystem == "org.cliprelay"' 2>/dev/null || true
}

on_error() {
  local exit_code=$?
  dump_failure_diagnostics || true
  exit "$exit_code"
}

trap on_error ERR

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Required command not found: $cmd" >&2
    exit 1
  fi
}

probe_json() {
  "${ADB[@]}" shell run-as "$ANDROID_APP_ID" cat files/debug-smoke-state.json 2>/dev/null | tr -d '\r' || true
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

wait_for_stable_probe_connection() {
  local stable_seconds="$1"
  local elapsed=0

  while (( elapsed < stable_seconds )); do
    local connected
    connected="$(probe_get "connected" "false")"
    if [[ "$connected" != "true" ]]; then
      echo "Connection dropped during stability check (elapsed=${elapsed}s/${stable_seconds}s)" >&2
      return 1
    fi
    sleep 1
    elapsed=$((elapsed + 1))
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
  "${ADB[@]}" shell am start \
    -n org.cliprelay/.ui.ShareReceiverActivity \
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

wait_for_android_inbound_text_after() {
  local expected_text="$1"
  local baseline_inbound_ms="$2"
  local timeout="$3"
  local start_ts
  start_ts="$(date +%s)"

  while true; do
    local inbound_ms
    inbound_ms="$(probe_get "last_inbound_at_ms" "0")"
    local inbound_text
    inbound_text="$(probe_get "last_inbound_text" "")"

    if [[ "$inbound_ms" =~ ^[0-9]+$ ]] && (( inbound_ms > baseline_inbound_ms )) && [[ "$inbound_text" == "$expected_text" ]]; then
      return 0
    fi

    local now_ts
    now_ts="$(date +%s)"
    if (( now_ts - start_ts >= timeout )); then
      echo "Timed out waiting for Android inbound payload '$expected_text' (last_inbound_text='$inbound_text', last_inbound_at_ms='$inbound_ms')" >&2
      return 1
    fi
    sleep 1
  done
}

run_m2a_stress_loop() {
  local iterations="$1"
  local per_iteration_timeout="$2"
  local run_id
  run_id="$(date +%s)-$RANDOM"

  echo "- Running Mac -> Android stress loop (${iterations} iterations)"
  for ((i = 1; i <= iterations; i++)); do
    local connected
    connected="$(probe_get "connected" "false")"
    if [[ "$connected" != "true" ]]; then
      echo "Connection dropped before stress iteration ${i}/${iterations}" >&2
      return 1
    fi

    local payload
    payload="smoke-m2a-stress-${run_id}-i${i}"
    local baseline_inbound_ms
    baseline_inbound_ms="$(probe_get "last_inbound_at_ms" "0")"
    if [[ ! "$baseline_inbound_ms" =~ ^[0-9]+$ ]]; then
      baseline_inbound_ms=0
    fi

    printf '%s' "$payload" | pbcopy
    wait_for_android_inbound_text_after "$payload" "$baseline_inbound_ms" "$per_iteration_timeout"

    if (( i == iterations || i % 5 == 0 )); then
      echo "  - Stress progress: ${i}/${iterations}"
    fi
  done
}

broadcast_debug_action() {
  local action="$1"
  shift
  local output
  output="$(
    "${ADB[@]}" shell am broadcast \
      -n org.cliprelay/.debug.DebugSmokeReceiver \
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
  "${ADB[@]}" shell am start -W -n org.cliprelay/.ui.MainActivity >/dev/null 2>&1 || true
}

start_mac_app() {
  if pgrep -f "ClipRelay.app/Contents/MacOS/ClipRelay" >/dev/null 2>&1; then
    return
  fi

  open "$MAC_APP_PATH"

  local attempts=0
  until pgrep -f "ClipRelay.app/Contents/MacOS/ClipRelay" >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    if (( attempts >= 20 )); then
      echo "ClipRelay app did not stay running after launch." >&2
      echo "Check macOS logs: /usr/bin/log show --last 5m --style compact --predicate 'process == \"ClipRelay\"'" >&2
      exit 1
    fi
    sleep 1
  done
}

toggle_bluetooth() {
  if "${ADB[@]}" shell cmd bluetooth_manager disable >/dev/null 2>&1; then
    if ! "${ADB[@]}" shell cmd bluetooth_manager wait-for-state:STATE_OFF >/dev/null 2>&1; then
      return 1
    fi
    if ! "${ADB[@]}" shell cmd bluetooth_manager enable >/dev/null 2>&1; then
      return 1
    fi
    if ! "${ADB[@]}" shell cmd bluetooth_manager wait-for-state:STATE_ON >/dev/null 2>&1; then
      return 1
    fi
    return 0
  fi

  if "${ADB[@]}" shell svc bluetooth disable >/dev/null 2>&1; then
    sleep 3
    "${ADB[@]}" shell svc bluetooth enable >/dev/null 2>&1
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

if [[ -n "$ADB_PAIR_ENDPOINT" ]]; then
  echo "- Pairing wireless debugging endpoint: $ADB_PAIR_ENDPOINT"
  adb pair "$ADB_PAIR_ENDPOINT" "$ADB_PAIR_CODE" >/dev/null
fi

if [[ -n "$WIRELESS_ENDPOINT" ]]; then
  echo "- Connecting to wireless debugging target: $WIRELESS_ENDPOINT"
  adb connect "$WIRELESS_ENDPOINT" >/dev/null
fi

select_target_device
echo "- Using adb device: $ANDROID_SERIAL"

BLE_CONNECT_TIMEOUT_SEC="$TIMEOUT_SEC"
if (( BLE_CONNECT_TIMEOUT_SEC > BLE_CONNECT_TIMEOUT_MAX_SEC )); then
  BLE_CONNECT_TIMEOUT_SEC="$BLE_CONNECT_TIMEOUT_MAX_SEC"
fi

if [[ ! -d "$MAC_APP_PATH" ]]; then
  echo "Missing macOS app bundle: $MAC_APP_PATH" >&2
  echo "Build first: ./scripts/build-all.sh" >&2
  exit 1
fi

if [[ ! -x "$MAC_BIN" ]]; then
  echo "Missing macOS binary: $MAC_BIN" >&2
  exit 1
fi

if [[ ! -f "$DIST_DIR/cliprelay-debug.apk" ]]; then
  echo "Missing Android APK: $DIST_DIR/cliprelay-debug.apk" >&2
  echo "Build first: ./scripts/build-all.sh" >&2
  exit 1
fi

echo "- Installing latest debug APK"
"${ADB[@]}" install -r "$DIST_DIR/cliprelay-debug.apk" >/dev/null

for permission in \
  android.permission.BLUETOOTH_SCAN \
  android.permission.BLUETOOTH_CONNECT \
  android.permission.BLUETOOTH_ADVERTISE \
  android.permission.POST_NOTIFICATIONS
do
  "${ADB[@]}" shell pm grant "$ANDROID_APP_ID" "$permission" >/dev/null 2>&1 || true
done

ANDROID_MODEL="$("${ADB[@]}" shell getprop ro.product.model | tr -d '\r')"
MAC_NAME_RAW="$(scutil --get ComputerName 2>/dev/null || hostname)"
MAC_NAME="$(printf '%s' "$MAC_NAME_RAW" | tr -cs '[:alnum:]_-.' '_')"
PAIR_TOKEN="$(openssl rand -hex 32)"

echo "- Android device: ${ANDROID_MODEL}"
echo "- Importing fresh pairing token"

pkill -f "ClipRelay.app/Contents/MacOS/ClipRelay" >/dev/null 2>&1 || true
"$MAC_BIN" --smoke-import-pairing --token "$PAIR_TOKEN" --name "$ANDROID_MODEL" >/dev/null

"${ADB[@]}" shell am force-stop "$ANDROID_APP_ID" >/dev/null 2>&1 || true
start_android_app
sleep 2

broadcast_debug_action "org.cliprelay.debug.IMPORT_PAIRING" --es token "$PAIR_TOKEN" --es device_name "$MAC_NAME"
broadcast_debug_action "org.cliprelay.debug.RESET_PROBE"

start_mac_app

echo "- Waiting for BLE connection"
wait_for_probe_value "connected" "true" "$BLE_CONNECT_TIMEOUT_SEC"
echo "- Verifying stable BLE connection"
wait_for_stable_probe_connection "$CONNECTION_STABILITY_SECONDS"

android_to_mac_text="smoke-a2m-$(date +%s)-$RANDOM"
echo "- Running Android -> Mac transfer"
printf '%s' "pre-smoke-marker" | pbcopy
wait_for_mac_clipboard_with_retries "$android_to_mac_text" "$TIMEOUT_SEC"

echo "- Running Mac -> Android transfer"
mac_to_android_text="$(wait_for_probe_after_mac_copy_with_retries "smoke-m2a-$(date +%s)-$RANDOM" "$TIMEOUT_SEC")"

if (( M2A_STRESS_COUNT > 0 )); then
  run_m2a_stress_loop "$M2A_STRESS_COUNT" "$M2A_STRESS_TIMEOUT_SEC"
fi

echo "- Running reconnect cycle"
counter_before_reconnect="$(probe_get "event_counter" "0")"
if ! toggle_bluetooth; then
  echo "Could not toggle Bluetooth via adb shell commands" >&2
  echo "Try manual toggle and rerun this script." >&2
  exit 1
fi

wait_for_probe_counter_gt "$counter_before_reconnect" 30
wait_for_probe_value "connected" "true" "$BLE_CONNECT_TIMEOUT_SEC"
echo "- Verifying stable BLE connection after reconnect"
wait_for_stable_probe_connection "$CONNECTION_STABILITY_SECONDS"

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
if (( M2A_STRESS_COUNT > 0 )); then
  echo "Mac -> Android stress iterations: $M2A_STRESS_COUNT"
fi
