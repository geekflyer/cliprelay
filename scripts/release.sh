#!/usr/bin/env bash
# Creates a release by bumping VERSION, committing, pushing, and dispatching release workflows.
# The workflow creates the git tag only after a successful build+publish.
# Run from branch main (stable X.Y.Z) or beta (prerelease X.Y.Z-beta.N).
#
# Usage: ./scripts/release.sh --mac 0.3.2
#        ./scripts/release.sh --android 0.3.1
#        ./scripts/release.sh --all 0.4.0
#        CLIPRELAY_PLAY_TRACK=beta ./scripts/release.sh --android 1.0.0-beta.1   # beta branch only
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

Branch:
  main — stable version X.Y.Z (published to Play production from CI; macOS stable appcast).
  beta — prerelease X.Y.Z-beta.N (Play track internal or beta via CLIPRELAY_PLAY_TRACK; macOS beta appcast).

Environment (beta branch + Android only):
  CLIPRELAY_PLAY_TRACK   Play track: internal (default) or beta

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

# Confirm branch and validate version
BRANCH=$(git -C "$ROOT_DIR" rev-parse --abbrev-ref HEAD)
case "$BRANCH" in
    main)
        if ! echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
            echo "Error: On main, version must be stable semver X.Y.Z (e.g. 0.3.2)" >&2
            exit 1
        fi
        ;;
    beta)
        if ! echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+-beta\.[0-9]+$'; then
            echo "Error: On beta, version must be X.Y.Z-beta.N (e.g. 1.2.0-beta.3)" >&2
            exit 1
        fi
        ;;
    *)
        echo "Error: Must be on main or beta for release (currently on '$BRANCH')" >&2
        exit 1
        ;;
esac

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

PLAY_TRACK="${CLIPRELAY_PLAY_TRACK:-internal}"

# Dispatch workflows on current branch (main or beta)
for platform in "${PLATFORMS[@]}"; do
    case "$platform" in
        mac)
            WORKFLOW="release-mac.yml"
            echo "==> Dispatching $WORKFLOW with version=$VERSION (ref=$BRANCH)..."
            gh workflow run "$WORKFLOW" --repo "$REPO" --ref "$BRANCH" -f "version=$VERSION"
            ;;
        android)
            WORKFLOW="release-android.yml"
            if [[ "$BRANCH" == "beta" ]]; then
                if [[ "$PLAY_TRACK" != internal && "$PLAY_TRACK" != beta ]]; then
                    echo "Error: CLIPRELAY_PLAY_TRACK must be 'internal' or 'beta' (got '$PLAY_TRACK')" >&2
                    exit 1
                fi
                echo "==> Dispatching $WORKFLOW with version=$VERSION play_track=$PLAY_TRACK (ref=$BRANCH)..."
                gh workflow run "$WORKFLOW" --repo "$REPO" --ref "$BRANCH" \
                    -f "version=$VERSION" \
                    -f "play_track=$PLAY_TRACK"
            else
                echo "==> Dispatching $WORKFLOW with version=$VERSION (ref=$BRANCH)..."
                gh workflow run "$WORKFLOW" --repo "$REPO" --ref "$BRANCH" -f "version=$VERSION"
            fi
            ;;
    esac

    echo "    Polling for workflow run..."
    RUN_URL=""
    for _ in $(seq 1 30); do
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
