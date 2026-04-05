#!/usr/bin/env bash
# Publishes the Android release AAB to Google Play via Gradle Play Publisher.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANDROID_PROJECT_DIR="$ROOT_DIR/android"

TRACK="${PLAY_TRACK:-internal}"
PROMOTE=false
FROM_TRACK=""
TO_TRACK=""

usage() {
  cat <<'EOF'
Usage: ./scripts/publish-android.sh [options]

Publishes the Android release AAB to Google Play using Gradle Play Publisher.

Options:
  --track <name>    Play track to publish to (default: internal)
  --promote         Promote existing artifact instead of publishing
  --from <track>    Source track for promotion (default: internal)
  --to <track>      Destination track for promotion (default: production)
  -h, --help        Show this help message

Required configuration:
  - Android release signing (keystore.properties or CLIPRELAY_* env vars)
  - Google Play service account JSON via either:
      1) android/play.properties (serviceAccountCredentials=...)
      2) PLAY_SERVICE_ACCOUNT_JSON env var
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --track)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --track" >&2
        usage
        exit 1
      fi
      TRACK="$2"
      shift 2
      ;;
    --promote) PROMOTE=true; shift ;;
    --from) FROM_TRACK="$2"; shift 2 ;;
    --to) TO_TRACK="$2"; shift 2 ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ ! -x "$ANDROID_PROJECT_DIR/gradlew" ]]; then
  echo "Gradle wrapper missing at android/gradlew" >&2
  exit 1
fi

if ! command -v java >/dev/null 2>&1; then
  echo "java not found. Install JDK 17+ first." >&2
  exit 1
fi

if [[ "$PROMOTE" == "true" ]]; then
    FROM_TRACK="${FROM_TRACK:-internal}"
    TO_TRACK="${TO_TRACK:-production}"
    echo "==> Promoting from track '$FROM_TRACK' to '$TO_TRACK'"
    (
        cd "$ANDROID_PROJECT_DIR"
        PLAY_TRACK="$TO_TRACK" ./gradlew :app:promoteReleaseArtifact \
            -Pplay.fromTrack="$FROM_TRACK"
    )
    echo "==> Promotion complete"
    exit 0
fi

echo "==> Publishing Android release bundle to track: $TRACK"
(
  cd "$ANDROID_PROJECT_DIR"
  PLAY_TRACK="$TRACK" ./gradlew :app:publishReleaseBundle
)

echo "==> Publish command complete"
