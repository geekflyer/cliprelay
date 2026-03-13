#!/usr/bin/env bash
# Signs, packages, notarizes, and staples the macOS app for distribution.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/ClipRelay.app"
DMG_PATH="$DIST_DIR/ClipRelay.dmg"
NOTARY_DIR="$DIST_DIR/notary"
ENTITLEMENTS="$ROOT_DIR/macos/ClipRelayMac/Resources/ClipRelay.entitlements"
SIGNING_IDENTITY="Developer ID Application: Christian Theilemann (B66YFKPUA8)"
KEYCHAIN_PROFILE="ClipRelay"

usage() {
  cat <<'EOF'
Usage: ./scripts/publish-mac.sh [options]

Signs, packages into DMG, notarizes, and staples the macOS app.

Modes:
  (default)           Sign, create DMG, submit for notarization (async)
  --wait              Sign, create DMG, notarize (blocking), and auto-staple
  --staple <id>       Check status and staple a previous submission
  --status [id]       Check notarization status (latest if no id given)
  --list              List all tracked submissions

Prerequisites:
  - Run ./scripts/build-all.sh --mac-only first
  - Developer ID certificate in Keychain
  - Notarytool keychain profile "ClipRelay" configured

Options:
  -h, --help    Show this help message
EOF
}

# ── --list: show tracked submissions ──

cmd_list() {
  if [[ ! -d "$NOTARY_DIR" ]] || [ -z "$(ls -A "$NOTARY_DIR" 2>/dev/null)" ]; then
    echo "No tracked submissions in dist/notary/"
    exit 0
  fi
  echo "Tracked submissions:"
  for dir in "$NOTARY_DIR"/*/; do
    id=$(basename "$dir")
    if [[ -f "$dir/info.txt" ]]; then
      date=$(grep "^date:" "$dir/info.txt" | cut -d' ' -f2-)
      git_hash=$(grep "^git:" "$dir/info.txt" | cut -d' ' -f2-)
      echo "  $id  ($date)  ${git_hash:0:12}"
    else
      echo "  $id"
    fi
  done
}

# ── --status: check notarization status ──

cmd_status() {
  local id="$1"
  if [[ -z "$id" ]]; then
    # Find most recent submission
    if [[ ! -d "$NOTARY_DIR" ]]; then
      echo "No tracked submissions." >&2
      exit 1
    fi
    id=$(ls -t "$NOTARY_DIR" | head -1)
    if [[ -z "$id" ]]; then
      echo "No tracked submissions." >&2
      exit 1
    fi
  fi
  echo "Checking status for $id..."
  xcrun notarytool info "$id" --keychain-profile "$KEYCHAIN_PROFILE"
}

# ── --staple: staple a previously notarized submission ──

cmd_staple() {
  local id="$1"
  local sub_dir="$NOTARY_DIR/$id"

  if [[ ! -d "$sub_dir" ]]; then
    echo "Submission $id not found in dist/notary/" >&2
    echo "Run --list to see tracked submissions." >&2
    exit 1
  fi

  local dmg="$sub_dir/ClipRelay.dmg"
  if [[ ! -f "$dmg" ]]; then
    echo "DMG not found: $dmg" >&2
    exit 1
  fi

  echo "==> Checking notarization status for $id..."
  local status
  status=$(xcrun notarytool info "$id" --keychain-profile "$KEYCHAIN_PROFILE" 2>&1)
  echo "$status"

  if ! echo "$status" | grep -q "status: Accepted"; then
    echo ""
    echo "Submission is not yet accepted. Cannot staple." >&2
    exit 1
  fi

  echo ""
  echo "==> Stapling notarization ticket"
  xcrun stapler staple "$dmg"

  echo "==> Copying stapled DMG to dist/ClipRelay.dmg"
  cp "$dmg" "$DMG_PATH"

  echo "==> Verification"
  xcrun stapler validate "$DMG_PATH"

  echo ""
  echo "==> Staple complete: $DMG_PATH"
}

# ── Parse arguments ──

MODE="submit"
WAIT_MODE=false
STAPLE_ID=""
STATUS_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --wait)
      WAIT_MODE=true
      shift
      ;;
    --list)
      MODE="list"
      shift
      ;;
    --status)
      MODE="status"
      STATUS_ID="${2:-}"
      [[ -n "$STATUS_ID" ]] && shift
      shift
      ;;
    --staple)
      MODE="staple"
      STAPLE_ID="${2:-}"
      if [[ -z "$STAPLE_ID" ]]; then
        echo "Usage: --staple <submission-id>" >&2
        exit 1
      fi
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

case "$MODE" in
  list)   cmd_list; exit 0 ;;
  status) cmd_status "$STATUS_ID"; exit 0 ;;
  staple) cmd_staple "$STAPLE_ID"; exit 0 ;;
esac

# ── Submit mode: sign, create DMG, submit for notarization ──

# ── Preflight checks ──

if [[ ! -d "$APP_DIR" ]]; then
  echo "dist/ClipRelay.app not found. Run ./scripts/build-all.sh --mac-only first." >&2
  exit 1
fi

if ! command -v create-dmg &>/dev/null; then
  echo "create-dmg not found. Install with: brew install create-dmg" >&2
  exit 1
fi

if ! security find-identity -v -p codesigning | grep -q "$SIGNING_IDENTITY"; then
  echo "Signing identity not found: $SIGNING_IDENTITY" >&2
  exit 1
fi

if [[ ! -f "$ENTITLEMENTS" ]]; then
  echo "Entitlements file not found: $ENTITLEMENTS" >&2
  exit 1
fi

# ── 1. Re-sign with Developer ID ──

echo "==> Signing with Developer ID + hardened runtime"
codesign --force --deep --sign "$SIGNING_IDENTITY" \
    --entitlements "$ENTITLEMENTS" \
    --options runtime \
    --timestamp \
    "$APP_DIR"
echo "Signing complete."

codesign -dvv "$APP_DIR" 2>&1 | grep -E "Authority|TeamIdentifier"

# ── 2. Create DMG ──

echo "==> Generating DMG background"
swift "$ROOT_DIR/scripts/generate-dmg-background.swift"

echo "==> Creating styled DMG with drag-to-install layout"
rm -f "$DMG_PATH"
create-dmg \
    --volname "ClipRelay" \
    --volicon "$ROOT_DIR/macos/ClipRelayMac/Resources/AppIcon.icns" \
    --background "$ROOT_DIR/design/dmg-background.png" \
    --window-pos 200 120 \
    --window-size 660 400 \
    --icon-size 128 \
    --icon "ClipRelay.app" 165 175 \
    --app-drop-link 495 175 \
    --hide-extension "ClipRelay.app" \
    --no-internet-enable \
    "$DMG_PATH" \
    "$APP_DIR" \
    || test $? -eq 2  # create-dmg returns 2 when skipping deprecated internet-enable
echo "DMG created: $DMG_PATH"

# ── 3. Submit for notarization ──

if [[ "$WAIT_MODE" == true ]]; then
  echo "==> Submitting to Apple notarization (--wait mode, this may take several minutes)..."
  if ! xcrun notarytool submit "$DMG_PATH" \
      --keychain-profile "$KEYCHAIN_PROFILE" \
      --wait; then
    echo "Notarization failed." >&2
    exit 1
  fi

  echo ""
  echo "==> Stapling notarization ticket"
  xcrun stapler staple "$DMG_PATH"

  echo "==> Verification"
  xcrun stapler validate "$DMG_PATH"

  echo ""
  echo "==> Notarization and stapling complete: $DMG_PATH"
else
  echo "==> Submitting to Apple notarization..."
  SUBMIT_OUTPUT=$(xcrun notarytool submit "$DMG_PATH" \
      --keychain-profile "$KEYCHAIN_PROFILE" 2>&1)
  echo "$SUBMIT_OUTPUT"

  SUBMISSION_ID=$(echo "$SUBMIT_OUTPUT" | grep "^  id:" | head -1 | awk '{print $2}')

  if [[ -z "$SUBMISSION_ID" ]]; then
    echo "Failed to parse submission ID from output." >&2
    exit 1
  fi

  # ── 4. Save DMG to notary tracking directory ──

  mkdir -p "$NOTARY_DIR/$SUBMISSION_ID"
  cp "$DMG_PATH" "$NOTARY_DIR/$SUBMISSION_ID/ClipRelay.dmg"
  cat > "$NOTARY_DIR/$SUBMISSION_ID/info.txt" <<EOF
id: $SUBMISSION_ID
date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
git: $(git -C "$ROOT_DIR" rev-parse HEAD)
EOF

  echo ""
  echo "==> Submitted! DMG saved to dist/notary/$SUBMISSION_ID/"
  echo ""
  echo "Next steps:"
  echo "  Check status:  ./scripts/publish-mac.sh --status $SUBMISSION_ID"
  echo "  Staple when ready:  ./scripts/publish-mac.sh --staple $SUBMISSION_ID"
fi
