#!/usr/bin/env bash
# Regenerates raster icon assets (PNG) from SVG sources. Requires rsvg-convert.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
DESIGN="$ROOT/design"
ANDROID_RES="$ROOT/android/app/src/main/res"
MACOS_RES="$ROOT/macos/ClipRelayMac/Resources"

has_cmd() { command -v "$1" &>/dev/null; }

if ! has_cmd rsvg-convert; then
  echo "ERROR: rsvg-convert is required. Install with: brew install librsvg" >&2
  exit 1
fi

svg_to_png() {
  local svg="$1" out="$2" size="$3"
  rsvg-convert -w "$size" -h "$size" "$svg" -o "$out"
}

# ─── Android mipmap icons ────────────────────────────────────────────────────

echo "=== Android mipmap icons ==="

gen_android_density() {
  local density="$1" fg_size="$2"
  local dir="$ANDROID_RES/mipmap-$density"
  mkdir -p "$dir"

  # Adaptive icon foreground (mark only, transparent bg, safe-zone padded)
  echo "  $density: ic_launcher_foreground.png (${fg_size}px)"
  svg_to_png "$DESIGN/logo-android-foreground.svg" "$dir/ic_launcher_foreground.png" "$fg_size"
}

gen_android_density mdpi    108
gen_android_density hdpi    162
gen_android_density xhdpi   216
gen_android_density xxhdpi  324
gen_android_density xxxhdpi 432

# ─── macOS StatusBar icons ───────────────────────────────────────────────────

echo "=== macOS StatusBar icons ==="
mkdir -p "$MACOS_RES"

# Menu bar template images (black shapes, macOS auto-tints)
echo "  StatusBarIcon.png (18px)"
svg_to_png "$DESIGN/logo-menubar.svg" "$MACOS_RES/StatusBarIcon.png" 18

echo "  StatusBarIcon@2x.png (36px)"
svg_to_png "$DESIGN/logo-menubar.svg" "$MACOS_RES/StatusBarIcon@2x.png" 36

# ─── macOS AppIcon.icns ─────────────────────────────────────────────────────

echo "=== macOS AppIcon.icns ==="

if has_cmd iconutil; then
  ICONSET="/tmp/ClipRelay.iconset"
  rm -rf "$ICONSET"
  mkdir -p "$ICONSET"

  # App icon uses the dedicated appicon SVG (solid dark bg + glowing mark)
  for size in 16 32 128 256 512; do
    echo "  icon_${size}x${size}.png"
    svg_to_png "$DESIGN/logo-appicon.svg" "$ICONSET/icon_${size}x${size}.png" "$size"
    double=$((size * 2))
    echo "  icon_${size}x${size}@2x.png (${double}px)"
    svg_to_png "$DESIGN/logo-appicon.svg" "$ICONSET/icon_${size}x${size}@2x.png" "$double"
  done

  iconutil -c icns -o "$MACOS_RES/AppIcon.icns" "$ICONSET"
  rm -rf "$ICONSET"
  echo "  -> AppIcon.icns generated"
else
  echo "  SKIP: iconutil not available (macOS only)"
fi

echo "=== Done ==="
