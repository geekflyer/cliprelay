#!/usr/bin/env bash
# Generates a compact changelog between two tags for a given platform.
# Usage: ./scripts/changelog.sh --mac v0.3.1..v0.3.2
#        ./scripts/changelog.sh --android v0.3.0..v0.3.1
set -euo pipefail

PLATFORM=""
RANGE=""

usage() {
    echo "Usage: $0 --mac|--android <tag1>..<tag2>"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mac) PLATFORM="mac"; shift ;;
        --android) PLATFORM="android"; shift ;;
        *) RANGE="$1"; shift ;;
    esac
done

[[ -z "$PLATFORM" || -z "$RANGE" ]] && usage

# Validate range format
if [[ "$RANGE" != *..* ]]; then
    echo "Error: Range must contain '..' (e.g., v0.3.1..v0.3.2)" >&2
    exit 1
fi

# Extract tags from range
FROM_TAG="${RANGE%..*}"
TO_TAG="${RANGE#*..}"

# Platform-specific paths
case "$PLATFORM" in
    mac) PLATFORM_DIR="macos/" ;;
    android) PLATFORM_DIR="android/" ;;
esac

echo "## Changes"
echo ""

# Single git log with all relevant paths to avoid duplicates
CHANGES=$(git log "${PLATFORM}/${FROM_TAG}..${PLATFORM}/${TO_TAG}" \
    --pretty=format:"%s" \
    -- "$PLATFORM_DIR" "scripts/" "*.md" "*.sh" \
    | sort -u)

if [[ -z "$CHANGES" ]]; then
    echo "No changes."
else
    echo "$CHANGES" | while read -r line; do
        echo "- $line"
    done
fi
