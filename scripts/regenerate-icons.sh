#!/usr/bin/env bash
set -euo pipefail

# Regenerate raster icon assets from SVG sources.
# Requires: rsvg-convert (from librsvg) or falls back to qlmanage (macOS).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
DESIGN="$ROOT/design"
ANDROID_RES="$ROOT/android/app/src/main/res"
MACOS_RES="$ROOT/macos/ClipRelayMac/Resources"

# ─── Helpers ──────────────────────────────────────────────────────────────────

has_cmd() { command -v "$1" &>/dev/null; }

svg_to_png() {
  local svg="$1" out="$2" size="$3"
  if has_cmd rsvg-convert; then
    rsvg-convert -w "$size" -h "$size" "$svg" -o "$out"
  elif has_cmd qlmanage; then
    qlmanage -t -s "$size" -o /tmp "$svg" 2>/dev/null
    local ql_out="/tmp/$(basename "$svg").png"
    if [[ -f "$ql_out" ]]; then
      mv "$ql_out" "$out"
    else
      echo "  SKIP: qlmanage could not convert $svg at ${size}px" >&2
      return 1
    fi
  else
    echo "  SKIP: no rsvg-convert or qlmanage available" >&2
    return 1
  fi
}

# ─── Android mipmap icons ────────────────────────────────────────────────────

echo "=== Android mipmap icons ==="

gen_android_density() {
  local density="$1" launcher_size="$2" fg_size="$3"
  local dir="$ANDROID_RES/mipmap-$density"
  mkdir -p "$dir"

  echo "  $density: ic_launcher.png (${launcher_size}px)"
  svg_to_png "$DESIGN/logo-android-icon.svg" "$dir/ic_launcher.png" "$launcher_size" || true

  echo "  $density: ic_launcher_foreground.png (${fg_size}px)"
  svg_to_png "$DESIGN/logo-android-icon.svg" "$dir/ic_launcher_foreground.png" "$fg_size" || true
}

gen_android_density mdpi    48  108
gen_android_density hdpi    72  162
gen_android_density xhdpi   96  216
gen_android_density xxhdpi  144 324
gen_android_density xxxhdpi 192 432

# ─── macOS StatusBar icons ───────────────────────────────────────────────────

echo "=== macOS StatusBar icons ==="
mkdir -p "$MACOS_RES"

echo "  StatusBarIcon.png (18px)"
svg_to_png "$DESIGN/logo-menubar.svg" "$MACOS_RES/StatusBarIcon.png" 18 || true

echo "  StatusBarIcon@2x.png (36px)"
svg_to_png "$DESIGN/logo-menubar.svg" "$MACOS_RES/StatusBarIcon@2x.png" 36 || true

# ─── macOS AppIcon.icns ─────────────────────────────────────────────────────

echo "=== macOS AppIcon.icns ==="

if has_cmd rsvg-convert && has_cmd iconutil; then
  ICONSET="/tmp/ClipRelay.iconset"
  rm -rf "$ICONSET"
  mkdir -p "$ICONSET"

  for size in 16 32 128 256 512; do
    echo "  icon_${size}x${size}.png"
    rsvg-convert -w "$size" -h "$size" "$DESIGN/logo-full-dark.svg" -o "$ICONSET/icon_${size}x${size}.png"
    double=$((size * 2))
    echo "  icon_${size}x${size}@2x.png (${double}px)"
    rsvg-convert -w "$double" -h "$double" "$DESIGN/logo-full-dark.svg" -o "$ICONSET/icon_${size}x${size}@2x.png"
  done

  iconutil -c icns -o "$MACOS_RES/AppIcon.icns" "$ICONSET"
  rm -rf "$ICONSET"
  echo "  -> AppIcon.icns generated"
else
  echo "  SKIP: need rsvg-convert + iconutil for .icns generation"
fi

echo "=== Done ==="
