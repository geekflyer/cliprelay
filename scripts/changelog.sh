#!/usr/bin/env bash
# Generates a compact changelog between two tags for a given platform.
# Usage: ./scripts/changelog.sh --mac v0.3.1..v0.3.2
#        ./scripts/changelog.sh --android v0.3.0..HEAD
set -euo pipefail

PLATFORM=""
RANGE=""

usage() {
    echo "Usage: $0 --mac|--android <tag1>..<tag2|HEAD>"
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
FROM_PART="${RANGE%..*}"
TO_PART="${RANGE#*..}"

# Resolve git refs: accept legacy v0.3.1..HEAD, full platform tags (android/beta/v...), or beta/v1.0.0-beta.1..HEAD
resolve_ref() {
    local part="$1"
    if [[ "$part" == "HEAD" ]]; then
        echo "HEAD"
    elif [[ "$part" == ${PLATFORM}/* ]]; then
        echo "$part"
    elif [[ "$part" == beta/* ]]; then
        echo "${PLATFORM}/${part}"
    else
        echo "${PLATFORM}/${part}"
    fi
}

FROM_REF="$(resolve_ref "$FROM_PART")"
TO_REF="$(resolve_ref "$TO_PART")"

# Platform-specific paths
case "$PLATFORM" in
    mac) PLATFORM_DIR="macos/" ;;
    android) PLATFORM_DIR="android/" ;;
esac

echo "## Changes"
echo ""

# Single git log with all relevant paths to avoid duplicates
CHANGES=$(git log "${FROM_REF}..${TO_REF}" \
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
