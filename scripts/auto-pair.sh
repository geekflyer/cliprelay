#!/usr/bin/env bash
# Generates a shared pairing token and injects it into both Mac and Android for automated testing.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
MAC_APP="$DIST_DIR/ClipRelay.app"
MAC_SMOKE_CLI="$DIST_DIR/ClipRelaySmokeCLI"
MAC_BINARY="$MAC_APP/Contents/MacOS/ClipRelay"
ANDROID_PKG="org.cliprelay"

# Shared macOS smoke-test helpers and dedicated keychain setup.
# shellcheck source=/dev/null
source "$ROOT_DIR/scripts/smoke-mac-common.sh"
# shellcheck source=/dev/null
ADB=(adb)
source "$ROOT_DIR/scripts/smoke-android-common.sh"

usage() {
    echo "Usage: $0 [--token TOKEN] [--serial ADB_SERIAL]"
    echo
    echo "Generates a shared pairing token and injects it into both Mac and Android."
    echo "If --token is provided, uses that token instead of generating a new one."
    exit 0
}

TOKEN=""
ANDROID_SERIAL=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --token)
            TOKEN="$2"
            shift 2
            ;;
        --serial)
            ANDROID_SERIAL="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            ;;
    esac
done

# Generate token if not provided (64 hex chars = 32 random bytes)
if [[ -z "$TOKEN" ]]; then
    TOKEN=$(openssl rand -hex 32)
    echo "Generated token: ...${TOKEN:56:8}"
else
    echo "Using provided token: ...${TOKEN:56:8}"
fi

# Validate token format
if [[ ${#TOKEN} -ne 64 ]] || ! echo "$TOKEN" | grep -qE '^[0-9a-fA-F]{64}$'; then
    echo "Error: Token must be exactly 64 hex characters" >&2
    exit 1
fi

TOKEN=$(echo "$TOKEN" | tr '[:upper:]' '[:lower:]')

select_android_device() {
    local state

    if [[ -n "$ANDROID_SERIAL" ]]; then
        state="$(adb -s "$ANDROID_SERIAL" get-state 2>/dev/null || true)"
        if [[ "$state" != "device" ]]; then
            echo "Error: Android device '$ANDROID_SERIAL' is not online" >&2
            exit 1
        fi
        ADB=(adb -s "$ANDROID_SERIAL")
        return
    fi

    local devices=()
    while IFS= read -r serial; do
        [[ -n "$serial" ]] && devices+=("$serial")
    done < <(adb devices | tr -d '\r' | awk -F '\t' 'NR > 1 && $2 == "device" { print $1 }')

    if [[ ${#devices[@]} -eq 0 ]]; then
        echo "Error: No Android device connected (adb)" >&2
        exit 1
    fi

    if [[ ${#devices[@]} -gt 1 ]]; then
        echo "Error: Multiple adb devices detected: ${devices[*]}" >&2
        echo "Use --serial <adb-serial> to choose one." >&2
        exit 1
    fi

    ANDROID_SERIAL="${devices[0]}"
    ADB=(adb -s "$ANDROID_SERIAL")
}

# ── Mac side ──────────────────────────────────────────────────────────

echo
echo "==> Injecting token into Mac keychain..."

# Kill existing Mac app
pkill -f ClipRelay 2>/dev/null || true
sleep 0.5

if [[ ! -x "$MAC_SMOKE_CLI" ]]; then
    echo "Error: Smoke CLI not found at $MAC_SMOKE_CLI. Run scripts/build-all.sh first." >&2
    exit 1
fi

prepare_mac_smoke_keychain
smoke_mac_env "$MAC_SMOKE_CLI" --smoke-import-pairing --token "$TOKEN" --name "Android"
echo "Mac pairing token injected."

# ── Android side ──────────────────────────────────────────────────────

echo
echo "==> Injecting token into Android device..."

select_android_device
echo "Using adb device: $ANDROID_SERIAL"

# Get Mac name for the Android side
MAC_NAME_RAW="$(scutil --get ComputerName 2>/dev/null || hostname)"
MAC_NAME="$(printf '%s' "$MAC_NAME_RAW" | tr -cs '[:alnum:]_-.' '_')"

# Inject token via debug-only file overrides
android_smoke_import_pairing "$TOKEN" "$MAC_NAME"
android_smoke_reset_probe
echo "Android pairing token injected."

# ── Restart both apps ────────────────────────────────────────────────

echo
echo "==> Restarting both apps..."

# Start Mac app
smoke_open_mac_app "$MAC_APP" /tmp/cliprelay-auto-pair-mac.log /tmp/cliprelay-auto-pair-mac.log
echo "Mac app started."

# Bring Android app to foreground
"${ADB[@]}" shell am start -n "$ANDROID_PKG/.ui.MainActivity" >/dev/null
echo "Android app started."

echo
echo "==> Pairing complete!"
echo "Token (tail): ...${TOKEN:56:8}"
echo
echo "Both apps should now discover each other via BLE and establish an L2CAP connection."
