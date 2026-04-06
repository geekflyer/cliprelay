#!/usr/bin/env bash
# Creates a release by bumping VERSION, committing, pushing, and dispatching the CI workflow.
# The workflow creates the git tag only after a successful build+publish.
# Usage: ./scripts/release.sh --mac 0.3.2
#        ./scripts/release.sh --android 0.3.1
#        ./scripts/release.sh --all 0.4.0
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PLATFORMS=()
VERSION=""
# macOS workflow_dispatch: git ref to build and Sparkle feed to update
MAC_GIT_REF=""
MAC_SPARKLE_CHANNEL="stable"

usage() {
  cat <<'EOF'
Usage: ./scripts/release.sh --mac|--android|--all <version>

Options:
  --mac                Release macOS only
  --android            Release Android only
  --all                Release both platforms
  --beta               macOS: release from branch beta (integration); updates beta Sparkle feed
  --git-ref <ref>      macOS: branch or ref for CI checkout (default: main, or beta with --beta)
  --sparkle-channel <stable|beta>  macOS: which appcast to update (default: stable)
  -h, --help           Show this help

Example:
  ./scripts/release.sh --mac 0.3.2
  ./scripts/release.sh --mac 0.4.0 --beta
  ./scripts/release.sh --all 0.4.0
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
        --mac) PLATFORMS+=("mac"); shift ;;
        --android) PLATFORMS+=("android"); shift ;;
        --all) PLATFORMS+=("mac" "android"); shift ;;
        --beta)
            MAC_GIT_REF="beta"
            MAC_SPARKLE_CHANNEL="beta"
            shift
            ;;
        --git-ref)
            [[ $# -lt 2 ]] && usage
            MAC_GIT_REF="$2"
            shift 2
            ;;
        --sparkle-channel)
            [[ $# -lt 2 ]] && usage
            MAC_SPARKLE_CHANNEL="$2"
            shift 2
            ;;
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

if [[ "$MAC_SPARKLE_CHANNEL" != "stable" && "$MAC_SPARKLE_CHANNEL" != "beta" ]]; then
    echo "Error: --sparkle-channel must be stable or beta" >&2
    exit 1
fi

# Validate semver format
if ! echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "Error: Version must be semver (e.g., 0.3.2)" >&2
    exit 1
fi

BRANCH=$(git -C "$ROOT_DIR" rev-parse --abbrev-ref HEAD)
if [[ -z "$MAC_GIT_REF" ]]; then
    MAC_GIT_REF="main"
fi

# Android releases stay on main; macOS can track a long-lived beta branch.
if printf '%s\n' "${PLATFORMS[@]}" | grep -q '^android$'; then
    if [[ "$BRANCH" != "main" ]]; then
        echo "Error: Android releases must be run from main (currently on '$BRANCH')" >&2
        exit 1
    fi
fi

if printf '%s\n' "${PLATFORMS[@]}" | grep -q '^mac$'; then
    if [[ "$BRANCH" != "$MAC_GIT_REF" ]]; then
        echo "Error: macOS release uses git ref '$MAC_GIT_REF' but workspace is on '$BRANCH'. Check out the matching branch." >&2
        exit 1
    fi
    if [[ "$MAC_GIT_REF" == "main" && "$MAC_SPARKLE_CHANNEL" == "beta" ]]; then
        echo "Warning: Updating beta Sparkle feed while on main is unusual — confirm this is intentional." >&2
    fi
fi

if printf '%s\n' "${PLATFORMS[@]}" | grep -q '^android$' && printf '%s\n' "${PLATFORMS[@]}" | grep -q '^mac$'; then
    if [[ "$BRANCH" != "main" ]]; then
        echo "Error: Combined --all releases must be run from main" >&2
        exit 1
    fi
    if [[ "$MAC_GIT_REF" != "main" || "$MAC_SPARKLE_CHANNEL" != "stable" ]]; then
        echo "Error: Use separate ./scripts/release.sh --android and --mac ... --beta for mixed channels" >&2
        exit 1
    fi
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
for platform in "${PLATFORMS[@]}"; do
    case "$platform" in
        mac)
            echo "$VERSION" > "$ROOT_DIR/macos/VERSION"
            echo "==> Bumped macos/VERSION to $VERSION"
            ;;
        android)
            echo "$VERSION" > "$ROOT_DIR/android/VERSION"
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
if git -C "$ROOT_DIR" diff --cached --quiet; then
    echo "==> VERSION already at $VERSION, skipping commit"
else
    git -C "$ROOT_DIR" commit -m "release: bump version to $VERSION for ${PLATFORMS[*]}"
fi

# Push commit (no tags — workflow creates tags on success)
git -C "$ROOT_DIR" push

# Detect GitHub repo from remote
REPO=$(git -C "$ROOT_DIR" remote get-url origin | sed -E 's#.+github\.com[:/](.+)\.git$#\1#')

# Dispatch workflows and poll for run URLs
for platform in "${PLATFORMS[@]}"; do
    case "$platform" in
        mac) WORKFLOW="release-mac.yml" ;;
        android) WORKFLOW="release-android.yml" ;;
    esac
    echo "==> Dispatching $WORKFLOW with version=$VERSION..."
    if [[ "$platform" == "mac" ]]; then
        gh workflow run "$WORKFLOW" --repo "$REPO" \
            -f version="$VERSION" \
            -f git_ref="$MAC_GIT_REF" \
            -f sparkle_channel="$MAC_SPARKLE_CHANNEL"
    else
        gh workflow run "$WORKFLOW" --repo "$REPO" -f version="$VERSION"
    fi

    echo "    Polling for workflow run..."
    RUN_URL=""
    for i in $(seq 1 30); do
        sleep 2
        RUN_URL=$(gh run list --repo "$REPO" --workflow="$WORKFLOW" --limit 1 \
            --json url,status,createdAt --jq '.[0].url' 2>/dev/null)
        if [[ -n "$RUN_URL" ]]; then
            break
        fi
    done
    if [[ -n "$RUN_URL" ]]; then
        echo "    Release job: $RUN_URL"
    else
        echo "    Could not find workflow run. Check: https://github.com/$REPO/actions"
    fi
done
