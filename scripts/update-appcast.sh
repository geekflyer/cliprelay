#!/usr/bin/env bash
# Inserts a new <item> into the Sparkle appcast XML.
# Usage: ./scripts/update-appcast.sh --version 0.3.2 --signature "..." --size 12345 --url "https://..."
set -euo pipefail

VERSION="" SIGNATURE="" SIZE="" URL="" BUILD_NUMBER="" APPCAST=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --build-number) BUILD_NUMBER="$2"; shift 2 ;;
        --signature) SIGNATURE="$2"; shift 2 ;;
        --size) SIZE="$2"; shift 2 ;;
        --url) URL="$2"; shift 2 ;;
        --appcast) APPCAST="$2"; shift 2 ;;
        *) echo "Unknown: $1" >&2; exit 1 ;;
    esac
done

[[ -z "$APPCAST" ]] && APPCAST="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/sparkle/appcast.xml"

[[ -z "$VERSION" || -z "$SIGNATURE" || -z "$SIZE" || -z "$URL" || -z "$BUILD_NUMBER" ]] && {
    echo "Usage: $0 --version VER --build-number NUM --signature SIG --size BYTES --url URL [--appcast PATH]" >&2
    exit 1
}

DATE=$(date -R 2>/dev/null || date -u +"%a, %d %b %Y %H:%M:%S %z")

# Build the new <item> XML block
ITEM="        <item>\n            <title>Version ${VERSION}<\/title>\n            <pubDate>${DATE}<\/pubDate>\n            <sparkle:version>${BUILD_NUMBER}<\/sparkle:version>\n            <sparkle:shortVersionString>${VERSION}<\/sparkle:shortVersionString>\n            <enclosure url=\"${URL}\"\n                       sparkle:edSignature=\"${SIGNATURE}\"\n                       length=\"${SIZE}\"\n                       type=\"application\/octet-stream\" \/>\n        <\/item>"

# Insert before </channel> closing tag
sed -i.bak "s|</channel>|${ITEM}\n    </channel>|" "$APPCAST"
rm -f "${APPCAST}.bak"

echo "==> Updated appcast with version ${VERSION}"
