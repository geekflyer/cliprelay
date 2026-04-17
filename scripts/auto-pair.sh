#!/usr/bin/env bash
# Generates a shared pairing token and injects it into both Mac and Android for automated testing.
# Rebuilds the local macOS app with smoke-test CLI enabled when needed.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
MAC_APP="$DIST_DIR/ClipRelay.app"
ANDROID_PKG="org.cliprelay"
ANDROID_PREFS_DIR="/data/data/$ANDROID_PKG/shared_prefs"

source "$ROOT_DIR/scripts/smoke-mac-common.sh"

usage() {
    echo "Usage: $0 [--token TOKEN]"
    echo
    echo "Generates a shared pairing token and injects it into both Mac and Android."
    echo "If --token is provided, uses that token instead of generating a new one."
    exit 0
}

TOKEN=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --token)
            TOKEN="$2"
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

# ── Mac side ──────────────────────────────────────────────────────────

echo
echo "==> Importing token into Mac smoke CLI..."

# Kill existing Mac app
pkill -f ClipRelay 2>/dev/null || true
sleep 0.5

ensure_primary_mac_app
run_smoke_mac_cli --smoke-import-pairing --token "$TOKEN" --name "Android"
echo "Mac pairing token imported."

# ── Android side ──────────────────────────────────────────────────────

echo
echo "==> Injecting token into Android device..."

# Check for connected device
if ! adb get-state >/dev/null 2>&1; then
    echo "Error: No Android device connected (adb)" >&2
    exit 1
fi

# Get Mac name for the Android side
MAC_NAME_RAW="$(scutil --get ComputerName 2>/dev/null || hostname)"
MAC_NAME="$(printf '%s' "$MAC_NAME_RAW" | tr -cs '[:alnum:]_-.' '_')"

# Inject token via debug broadcast receiver
adb shell am broadcast \
    -n "$ANDROID_PKG/.debug.DebugSmokeReceiver" \
    -a "org.cliprelay.debug.IMPORT_PAIRING" \
    --es token "$TOKEN" \
    --es device_name "$MAC_NAME" \
    --receiver-foreground 2>&1 | tail -1
echo "Android pairing token injected via broadcast."

# ── Restart both apps ────────────────────────────────────────────────

echo
echo "==> Restarting both apps..."

# Start Mac app
start_primary_mac_app
echo "Mac app started."

# Bring Android app to foreground
adb shell am start -n "$ANDROID_PKG/.ui.MainActivity" >/dev/null
echo "Android app started."

echo
echo "==> Pairing complete!"
echo "Token (tail): ...${TOKEN:56:8}"
echo
echo "Both apps should now discover each other via BLE and establish an L2CAP connection."
