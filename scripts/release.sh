#!/usr/bin/env bash
# Creates a release by bumping VERSION, committing, tagging, and pushing.
# Usage: ./scripts/release.sh --mac 0.3.2
#        ./scripts/release.sh --android 0.3.1
#        ./scripts/release.sh --all 0.4.0
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PLATFORMS=()
VERSION=""

usage() {
    cat <<'EOF'
Usage: ./scripts/release.sh --mac|--android|--all <version>

Options:
  --mac       Release macOS only
  --android   Release Android only
  --all       Release both platforms
  -h, --help  Show this help

Example:
  ./scripts/release.sh --mac 0.3.2
  ./scripts/release.sh --all 0.4.0
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mac) PLATFORMS+=("mac"); shift ;;
        --android) PLATFORMS+=("android"); shift ;;
        --all) PLATFORMS+=("mac" "android"); shift ;;
        -h|--help) usage ;;
        *)
            if [[ -z "$VERSION" ]]; then
                VERSION="$1"
            else
                echo "Unknown argument: $1" >&2
                usage
            fi
            shift
            ;;
    esac
done

[[ ${#PLATFORMS[@]} -eq 0 || -z "$VERSION" ]] && usage

# Validate semver format
if ! echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "Error: Version must be semver (e.g., 0.3.2)" >&2
    exit 1
fi

# Confirm on main branch
BRANCH=$(git -C "$ROOT_DIR" rev-parse --abbrev-ref HEAD)
if [[ "$BRANCH" != "main" ]]; then
    echo "Error: Must be on main branch (currently on '$BRANCH')" >&2
    exit 1
fi

# Confirm working tree is clean
if ! git -C "$ROOT_DIR" diff --quiet || ! git -C "$ROOT_DIR" diff --cached --quiet; then
    echo "Error: Working tree is not clean. Commit or stash changes first." >&2
    exit 1
fi

# Run tests first
echo "==> Running tests before release..."
"$ROOT_DIR/scripts/test-all.sh"

# Bump version file(s)
TAGS=()
for platform in "${PLATFORMS[@]}"; do
    case "$platform" in
        mac)
            echo "$VERSION" > "$ROOT_DIR/macos/VERSION"
            TAGS+=("mac/v${VERSION}")
            echo "==> Bumped macos/VERSION to $VERSION"
            ;;
        android)
            echo "$VERSION" > "$ROOT_DIR/android/VERSION"
            TAGS+=("android/v${VERSION}")
            echo "==> Bumped android/VERSION to $VERSION"
            ;;
    esac
done

# Commit version bump — only stage files that were actually modified
FILES_TO_ADD=()
for platform in "${PLATFORMS[@]}"; do
    case "$platform" in
        mac) FILES_TO_ADD+=("macos/VERSION") ;;
        android) FILES_TO_ADD+=("android/VERSION") ;;
    esac
done
git -C "$ROOT_DIR" add "${FILES_TO_ADD[@]}"
git -C "$ROOT_DIR" commit -m "release: bump version to $VERSION for ${PLATFORMS[*]}"

# Create tags
for tag in "${TAGS[@]}"; do
    git -C "$ROOT_DIR" tag "$tag"
    echo "==> Created tag $tag"
done

# Push commit and tags
git -C "$ROOT_DIR" push
git -C "$ROOT_DIR" push --tags
echo "==> Pushed to remote. CI will handle the rest."
