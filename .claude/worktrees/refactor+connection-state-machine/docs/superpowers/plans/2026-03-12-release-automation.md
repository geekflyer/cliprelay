# Release Automation Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Automate ClipRelay's release pipeline — version management, CI builds/tests/linting, signing, publishing, auto-updates, and changelog generation — for both macOS and Android.

**Architecture:** Per-platform VERSION files as source of truth, local scripts for all logic (CI just calls them), GitHub Actions for automation, Sparkle for macOS auto-updates, GitHub Releases for distribution.

**Tech Stack:** GitHub Actions, Sparkle 2 (Swift), SwiftLint, ktlint, Gradle Play Publisher, `create-dmg`, `xcrun notarytool`

**Spec:** `docs/superpowers/specs/2026-03-12-release-automation-design.md`

---

## Chunk 1: Version Management & Build Integration

### Task 1: Create VERSION files and wire into build scripts

**Files:**
- Create: `macos/VERSION`
- Create: `android/VERSION`
- Modify: `scripts/build-all.sh:117-119` (replace hardcoded version in Info.plist heredoc)
- Modify: `android/app/build.gradle.kts:67-68` (read version from file)

- [ ] **Step 1: Create VERSION files**

```bash
# macos/VERSION
0.1.0
```

```bash
# android/VERSION
0.1.0
```

- [ ] **Step 2: Modify `scripts/build-all.sh` to read `macos/VERSION`**

In `scripts/build-all.sh`, near the top of the file (after ROOT_DIR definition around line 5), add:

```bash
MAC_VERSION=$(cat "$ROOT_DIR/macos/VERSION" 2>/dev/null || echo "0.0.0")
GIT_HASH=$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
```

**Important:** The existing heredoc on line 99 uses single-quoted `<<'PLIST'` which prevents variable expansion. Change it to unquoted `<<PLIST` so that `${MAC_VERSION}` etc. are resolved. (The rest of the plist is plain XML with no dollar signs, so this is safe.)

Then replace the hardcoded version strings in the Info.plist heredoc (lines ~117-119):

```xml
<!-- Replace: -->
<key>CFBundleShortVersionString</key>
<string>0.1.0</string>
<key>CFBundleVersion</key>
<string>1</string>

<!-- With: -->
<key>CFBundleShortVersionString</key>
<string>${MAC_VERSION}</string>
<key>CFBundleVersion</key>
<string>${MAC_BUILD_NUMBER}</string>
<key>ClipRelayGitHash</key>
<string>${GIT_HASH}</string>
```

Where `MAC_BUILD_NUMBER` is derived from git commit count: `MAC_BUILD_NUMBER=$(git -C "$ROOT_DIR" rev-list --count HEAD)`. Add this to the variables near the top alongside `MAC_VERSION` and `GIT_HASH`. This keeps `CFBundleVersion` as a monotonically increasing integer (required by Apple and Sparkle), while the git hash goes into a custom `ClipRelayGitHash` key.

- [ ] **Step 3: Modify `android/app/build.gradle.kts` to read `android/VERSION`**

Replace the hardcoded version values (lines 67-68):

```kotlin
// Before:
versionCode = 5
versionName = "0.1.0"

// After:
versionCode = extra.properties.getOrDefault("cliVersionCode", "5").toString().toInt()
versionName = file("../VERSION").readText().trim()
```

The `versionCode` is passed in from the build script via `-PcliVersionCode=N`. In `scripts/build-all.sh`, compute it from git tags: `ANDROID_VERSION_CODE=$(git tag -l 'android/v*' | wc -l | tr -d ' ')` and pass `-PcliVersionCode=$ANDROID_VERSION_CODE` to the Gradle command. The default of 5 preserves backward compatibility for local dev builds. In CI workflows, add `fetch-tags: true` to the `actions/checkout@v4` step to ensure all tags are available.

Also add `buildConfig = true` to the existing `buildFeatures` block (line ~105-107):

```kotlin
// Before:
buildFeatures {
    compose = true
}

// After:
buildFeatures {
    compose = true
    buildConfig = true
}
```

And add a `buildConfigField` for the git hash inside `defaultConfig` (after versionName):

```kotlin
val gitHash = providers.exec {
    commandLine("git", "rev-parse", "--short", "HEAD")
}.standardOutput.asText.get().trim()
buildConfigField("String", "GIT_HASH", "\"$gitHash\"")
```

- [ ] **Step 4: Verify builds still work**

Run: `./scripts/build-all.sh`
Expected: Both macOS and Android builds succeed, macOS app shows version from `macos/VERSION`

- [ ] **Step 5: Commit**

```bash
git add macos/VERSION android/VERSION scripts/build-all.sh android/app/build.gradle.kts
git commit -m "feat: add per-platform VERSION files and wire into build scripts"
```

---

### Task 2: Display version in macOS UI

**Files:**
- Modify: `macos/ClipRelayMac/Sources/App/StatusBarController.swift` (add version to menu)

- [ ] **Step 1: Read StatusBarController.swift to find exact menu construction**

Read `/Users/christian/dev/cliprelay/macos/ClipRelayMac/Sources/App/StatusBarController.swift` to find where the NSMenu items are created.

- [ ] **Step 2: Modify existing version display to include git hash**

A version menu item already exists at `StatusBarController.swift:131-134`. Modify it to also show the git hash:

```swift
// Replace existing code at lines 131-134:
let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
let hash = Bundle.main.infoDictionary?["ClipRelayGitHash"] as? String ?? "?"
let versionItem = NSMenuItem(title: "ClipRelay v\(version) (\(hash))", action: nil, keyEquivalent: "")
versionItem.isEnabled = false
menu.addItem(versionItem)
```

- [ ] **Step 3: Build and verify**

Run: `./scripts/build-all.sh --mac-only`
Expected: Build succeeds. Launching the app shows the version in the menu bar dropdown.

- [ ] **Step 4: Commit**

```bash
git add macos/ClipRelayMac/Sources/App/StatusBarController.swift
git commit -m "feat(mac): display version and build hash in menu bar dropdown"
```

---

### Task 3: Display version in Android UI

**Files:**
- Modify: `android/app/src/main/java/org/cliprelay/ui/MainActivity.kt` (or relevant Compose screen)

- [ ] **Step 1: Read current UI code to find where to add version display**

Read `/Users/christian/dev/cliprelay/android/app/src/main/java/org/cliprelay/ui/MainActivity.kt` and any Compose screen files to find the appropriate place to show version info.

- [ ] **Step 2: Add version text to the UI**

Add a small text element showing the version in the app's main screen or settings area:

```kotlin
Text(
    text = "v${BuildConfig.VERSION_NAME} (${BuildConfig.GIT_HASH})",
    style = MaterialTheme.typography.bodySmall,
    color = MaterialTheme.colorScheme.onSurfaceVariant
)
```

- [ ] **Step 3: Build and verify**

Run: `./scripts/build-all.sh --android-only`
Expected: Build succeeds. If device connected, install and verify version displays.

- [ ] **Step 4: Commit**

```bash
git add android/app/src/main/java/org/cliprelay/
git commit -m "feat(android): display version and build hash in UI"
```

---

### Task 4: Update `android/AGENTS.md` to remove manual versionCode policy

**Files:**
- Modify: `android/AGENTS.md:3`

- [ ] **Step 1: Replace all manual version instructions**

Replace lines 3-5 (all three version-related lines):
```
- When the user asks for an Android release build or Play publish, increment `versionCode` in `android/app/build.gradle.kts` before creating the release artifact.
- Keep `versionName` unchanged unless the user explicitly asks to change it.
- Apply the versionCode bump once per requested release build so every uploaded AAB/APK has a new Play-acceptable version code.
```

With:
```
- `versionCode` is automatically derived from the count of `android/v*` git tags via the build script. No manual increment is needed.
- `versionName` is read from `android/VERSION`. Update that file to change the version (or use `scripts/release.sh`).
```

- [ ] **Step 2: Commit**

```bash
git add android/AGENTS.md
git commit -m "docs: update AGENTS.md for automated versionCode"
```

---

## Chunk 2: Linting Setup

### Task 5: Add SwiftLint configuration

**Files:**
- Create: `.swiftlint.yml`

- [ ] **Step 1: Create `.swiftlint.yml` in repo root**

```yaml
included:
  - macos/ClipRelayMac/Sources
  - macos/ClipRelayMac/Tests

disabled_rules:
  - trailing_whitespace
  - line_length

opt_in_rules:
  - empty_count
  - closure_spacing
```

Keep it minimal — start with defaults and disable only the noisiest rules.

- [ ] **Step 2: Install SwiftLint locally if not present**

Run: `brew install swiftlint` (if not already installed)

- [ ] **Step 3: Run SwiftLint to check for issues**

Run: `swiftlint lint --config .swiftlint.yml`
Expected: Either clean output or a list of warnings/errors to review. Fix any errors that seem like real issues; suppress any that are noise by adding to `disabled_rules`.

- [ ] **Step 4: Commit**

```bash
git add .swiftlint.yml
git commit -m "chore: add SwiftLint configuration"
```

---

### Task 6: Add ktlint to Android project

**Files:**
- Modify: `android/app/build.gradle.kts` (add ktlint plugin)

- [ ] **Step 1: Read `android/build.gradle.kts` (root) to see existing plugins**

Read `/Users/christian/dev/cliprelay/android/build.gradle.kts` for the plugins block.

- [ ] **Step 2: Add ktlint Gradle plugin**

Add the `org.jlleitschuh.gradle.ktlint` plugin to the root `android/build.gradle.kts`:

```kotlin
plugins {
    // ... existing plugins ...
    id("org.jlleitschuh.gradle.ktlint") version "12.1.2" apply false
}
```

And apply it in `android/app/build.gradle.kts`:

```kotlin
plugins {
    // ... existing plugins ...
    id("org.jlleitschuh.gradle.ktlint")
}
```

- [ ] **Step 3: Run ktlint to check for issues**

Run: `cd android && ./gradlew ktlintCheck`
Expected: Either clean or a list of formatting issues. Fix with `./gradlew ktlintFormat` if needed.

- [ ] **Step 4: Commit**

```bash
git add android/build.gradle.kts android/app/build.gradle.kts
git commit -m "chore: add ktlint to Android project"
```

---

### Task 7: Create `scripts/lint-all.sh`

**Files:**
- Create: `scripts/lint-all.sh`

- [ ] **Step 1: Create the lint script**

```bash
#!/usr/bin/env bash
# Runs all linters (SwiftLint for macOS, ktlint for Android).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANDROID_PROJECT_DIR="$ROOT_DIR/android"

FAILED=0

echo "==> Running SwiftLint"
if command -v swiftlint >/dev/null 2>&1; then
    swiftlint lint --config "$ROOT_DIR/.swiftlint.yml" --strict || FAILED=1
else
    echo "swiftlint not found. Install with: brew install swiftlint" >&2
    FAILED=1
fi

echo "==> Running ktlint"
(
    cd "$ANDROID_PROJECT_DIR"
    ./gradlew ktlintCheck
) || FAILED=1

if [[ $FAILED -ne 0 ]]; then
    echo "==> Linting FAILED"
    exit 1
fi

echo "==> All linters passed"
```

- [ ] **Step 2: Make executable and test**

Run: `chmod +x scripts/lint-all.sh && ./scripts/lint-all.sh`
Expected: Both linters run and either pass or show actionable errors.

- [ ] **Step 3: Commit**

```bash
git add scripts/lint-all.sh
git commit -m "feat: add lint-all.sh script for SwiftLint and ktlint"
```

---

## Chunk 3: Release & Changelog Scripts

### Task 8: Create `scripts/changelog.sh`

**Files:**
- Create: `scripts/changelog.sh`

- [ ] **Step 1: Create the changelog generation script**

```bash
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
```

- [ ] **Step 2: Make executable**

Run: `chmod +x scripts/changelog.sh`

- [ ] **Step 3: Commit**

```bash
git add scripts/changelog.sh
git commit -m "feat: add changelog generation script"
```

---

### Task 9: Create `scripts/release.sh`

**Files:**
- Create: `scripts/release.sh`

- [ ] **Step 1: Create the release script**

```bash
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
```

- [ ] **Step 2: Make executable**

Run: `chmod +x scripts/release.sh`

- [ ] **Step 3: Commit**

```bash
git add scripts/release.sh
git commit -m "feat: add release.sh script for version bumping and tagging"
```

---

### Task 10: Add `--promote` support to `scripts/publish-android.sh`

**Files:**
- Modify: `scripts/publish-android.sh`

- [ ] **Step 1: Read current publish-android.sh**

Read `/Users/christian/dev/cliprelay/scripts/publish-android.sh` for current structure.

- [ ] **Step 2: Add --promote, --from, and --to flags**

Add argument parsing for the promote flow. When `--promote` is passed, run `./gradlew promoteArtifact` instead of `publishReleaseBundle`. Add to the `usage()` and `while` loop:

```bash
# Add new variables near top:
PROMOTE=false
FROM_TRACK=""
TO_TRACK=""

# Add to usage():
#   --promote         Promote existing artifact instead of publishing
#   --from <track>    Source track for promotion (default: internal)
#   --to <track>      Destination track for promotion (default: production)

# Add to while loop:
--promote) PROMOTE=true; shift ;;
--from) FROM_TRACK="$2"; shift 2 ;;
--to) TO_TRACK="$2"; shift 2 ;;

# After arg parsing, add mutual exclusivity check:
# if [[ "$PROMOTE" == "true" && "$TRACK" != "${PLAY_TRACK:-internal}" ]]; then
#     echo "Error: --promote and --track are mutually exclusive" >&2; exit 1
# fi

# Add promote logic before the existing publish command:
if [[ "$PROMOTE" == "true" ]]; then
    FROM_TRACK="${FROM_TRACK:-internal}"
    TO_TRACK="${TO_TRACK:-production}"
    echo "==> Promoting from track '$FROM_TRACK' to '$TO_TRACK'"
    (
        cd "$ANDROID_PROJECT_DIR"
        # Gradle Play Publisher 3.x uses promoteReleaseArtifact task;
        # track config is passed via properties since CLI flags are not supported
        PLAY_TRACK="$TO_TRACK" ./gradlew :app:promoteReleaseArtifact \
            -Pplay.fromTrack="$FROM_TRACK"
    )
    echo "==> Promotion complete"
    exit 0
fi
```

- [ ] **Step 3: Commit**

```bash
git add scripts/publish-android.sh
git commit -m "feat: add --promote support to publish-android.sh"
```

---

## Chunk 4: GitHub Actions CI

### Task 11: Create `.github/workflows/ci.yml`

**Files:**
- Create: `.github/workflows/ci.yml`

- [ ] **Step 1: Create the CI workflow**

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  lint-test-build-mac:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
          fetch-tags: true
      - name: Install SwiftLint
        run: brew install swiftlint
      - name: Lint (Swift)
        run: swiftlint lint --config .swiftlint.yml --strict
      - name: Test (macOS)
        run: swift test --package-path macos/ClipRelayMac
      - name: Build macOS
        run: ./scripts/build-all.sh --mac-only

  lint-test-build-android:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
          fetch-tags: true
      - name: Set up JDK 17
        uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: 17
      - name: Lint (ktlint)
        run: cd android && ./gradlew ktlintCheck
      - name: Test (Android)
        run: cd android && ./gradlew testDebugUnitTest
      - name: Build Android
        run: ./scripts/build-all.sh --android-only
```

- [ ] **Step 2: Commit**

```bash
mkdir -p .github/workflows
git add .github/workflows/ci.yml
git commit -m "ci: add CI workflow for lint, test, and build on push/PR"
```

---

### Task 12: Create `.github/workflows/release-mac.yml`

**Files:**
- Create: `.github/workflows/release-mac.yml`

- [ ] **Step 1: Create the macOS release workflow**

```yaml
name: Release macOS

on:
  push:
    tags:
      - 'mac/v*'

jobs:
  release:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
          fetch-tags: true

      - name: Extract version from tag
        id: version
        run: echo "version=${GITHUB_REF#refs/tags/mac/v}" >> "$GITHUB_OUTPUT"

      - name: Import signing certificate
        env:
          CERTIFICATE_P12: ${{ secrets.MACOS_CERTIFICATE_P12 }}
          CERTIFICATE_PASSWORD: ${{ secrets.MACOS_CERTIFICATE_PASSWORD }}
        run: |
          echo "$CERTIFICATE_P12" | base64 --decode > certificate.p12
          security create-keychain -p "" build.keychain
          security default-keychain -s build.keychain
          security unlock-keychain -p "" build.keychain
          security import certificate.p12 -k build.keychain -P "$CERTIFICATE_PASSWORD" -T /usr/bin/codesign
          security set-key-partition-list -S apple-tool:,apple: -s -k "" build.keychain
          rm certificate.p12

      - name: Store notarization credentials
        env:
          NOTARY_APPLE_ID: ${{ secrets.NOTARY_APPLE_ID }}
          NOTARY_PASSWORD: ${{ secrets.NOTARY_PASSWORD }}
          NOTARY_TEAM_ID: ${{ secrets.NOTARY_TEAM_ID }}
        run: |
          xcrun notarytool store-credentials "ClipRelay" \
            --apple-id "$NOTARY_APPLE_ID" \
            --password "$NOTARY_PASSWORD" \
            --team-id "$NOTARY_TEAM_ID"

      - name: Install create-dmg
        run: brew install create-dmg

      - name: Build
        run: ./scripts/build-all.sh --mac-only

      - name: Sign, notarize, and create DMG
        run: ./scripts/publish-mac.sh --wait
        # Note: publish-mac.sh needs a --wait flag added that calls
        # `xcrun notarytool submit ... --wait` and then `xcrun stapler staple`
        # in a single synchronous flow. Currently it submits and returns.
        # This modification is part of this task.

      - name: Generate changelog
        id: changelog
        run: |
          PREV_TAG=$(git tag -l 'mac/v*' --sort=-v:refname | sed -n '2p' | sed 's|^mac/||')
          if [[ -n "$PREV_TAG" ]]; then
            BODY=$(./scripts/changelog.sh --mac "${PREV_TAG}..v${{ steps.version.outputs.version }}")
          else
            BODY="- Initial release"
          fi
          echo "body<<EOF" >> "$GITHUB_OUTPUT"
          echo "$BODY" >> "$GITHUB_OUTPUT"
          echo "EOF" >> "$GITHUB_OUTPUT"

      - name: Create GitHub Release
        uses: softprops/action-gh-release@v2
        with:
          name: "macOS v${{ steps.version.outputs.version }}"
          body: ${{ steps.changelog.outputs.body }}
          files: dist/ClipRelay.dmg
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}

      # TODO: Sparkle appcast update step (Task 16)
```

**Required GitHub Secrets:**
- `MACOS_CERTIFICATE_P12`: Base64-encoded .p12 of the Developer ID certificate
- `MACOS_CERTIFICATE_PASSWORD`: Password for the .p12
- `NOTARY_APPLE_ID`: Apple ID for notarization
- `NOTARY_PASSWORD`: App-specific password for notarization
- `NOTARY_TEAM_ID`: Apple Developer Team ID

- [ ] **Step 1.5: Add `--wait` flag to `scripts/publish-mac.sh`**

The existing `publish-mac.sh` submits for notarization but returns immediately. For CI, add a `--wait` flag that:
1. Submits the DMG with `xcrun notarytool submit dist/ClipRelay.dmg --keychain-profile "ClipRelay" --wait`
2. On success, staples the ticket: `xcrun stapler staple dist/ClipRelay.dmg`
3. Exits non-zero if notarization fails

This ensures the GitHub Release gets a fully notarized, stapled DMG.

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/release-mac.yml scripts/publish-mac.sh
git commit -m "ci: add macOS release workflow with signing and notarization"
```

---

### Task 13: Create `.github/workflows/release-android.yml`

**Files:**
- Create: `.github/workflows/release-android.yml`

- [ ] **Step 1: Create the Android release workflow**

```yaml
name: Release Android

on:
  push:
    tags:
      - 'android/v*'

  workflow_dispatch:
    inputs:
      promote:
        description: 'Promote from internal to production'
        type: boolean
        default: false

jobs:
  release:
    if: github.event_name == 'push'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
          fetch-tags: true

      - name: Extract version from tag
        id: version
        run: echo "version=${GITHUB_REF#refs/tags/android/v}" >> "$GITHUB_OUTPUT"

      - name: Set up JDK 17
        uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: 17

      - name: Decode keystore
        env:
          KEYSTORE_BASE64: ${{ secrets.ANDROID_KEYSTORE_BASE64 }}
        run: echo "$KEYSTORE_BASE64" | base64 --decode > android/cliprelay-release.keystore

      - name: Create keystore.properties
        env:
          KEYSTORE_PASSWORD: ${{ secrets.ANDROID_KEYSTORE_PASSWORD }}
          KEY_ALIAS: ${{ secrets.ANDROID_KEY_ALIAS }}
          KEY_PASSWORD: ${{ secrets.ANDROID_KEY_PASSWORD }}
        run: |
          cat > android/keystore.properties <<PROPS
storeFile=cliprelay-release.keystore
storePassword=$KEYSTORE_PASSWORD
keyAlias=$KEY_ALIAS
keyPassword=$KEY_PASSWORD
PROPS

      - name: Create play.properties
        env:
          PLAY_SERVICE_ACCOUNT_JSON: ${{ secrets.PLAY_SERVICE_ACCOUNT_JSON }}
        run: |
          echo "$PLAY_SERVICE_ACCOUNT_JSON" > android/play-service-account.json
          echo "serviceAccountCredentials=play-service-account.json" > android/play.properties

      - name: Build release
        run: ./scripts/build-all.sh --android-only

      - name: Publish to internal track
        run: ./scripts/publish-android.sh --track internal

      - name: Generate changelog
        id: changelog
        run: |
          PREV_TAG=$(git tag -l 'android/v*' --sort=-v:refname | sed -n '2p' | sed 's|^android/||')
          if [[ -n "$PREV_TAG" ]]; then
            BODY=$(./scripts/changelog.sh --android "${PREV_TAG}..v${{ steps.version.outputs.version }}")
          else
            BODY="- Initial release"
          fi
          echo "body<<EOF" >> "$GITHUB_OUTPUT"
          echo "$BODY" >> "$GITHUB_OUTPUT"
          echo "EOF" >> "$GITHUB_OUTPUT"

      - name: Create GitHub Release
        uses: softprops/action-gh-release@v2
        with:
          name: "Android v${{ steps.version.outputs.version }}"
          body: ${{ steps.changelog.outputs.body }}
          files: dist/cliprelay-release.apk
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}

  promote:
    if: github.event_name == 'workflow_dispatch' && inputs.promote
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Set up JDK 17
        uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: 17

      - name: Create play.properties
        env:
          PLAY_SERVICE_ACCOUNT_JSON: ${{ secrets.PLAY_SERVICE_ACCOUNT_JSON }}
        run: |
          echo "$PLAY_SERVICE_ACCOUNT_JSON" > android/play-service-account.json
          echo "serviceAccountCredentials=play-service-account.json" > android/play.properties

      - name: Promote to production
        run: ./scripts/publish-android.sh --promote --from internal --to production
```

**Required GitHub Secrets:**
- `ANDROID_KEYSTORE_BASE64`: Base64-encoded release keystore
- `ANDROID_KEYSTORE_PASSWORD`: Keystore password
- `ANDROID_KEY_ALIAS`: Key alias
- `ANDROID_KEY_PASSWORD`: Key password
- `PLAY_SERVICE_ACCOUNT_JSON`: Google Play service account JSON contents

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/release-android.yml
git commit -m "ci: add Android release workflow with Play Store publishing"
```

---

## Chunk 5: Sparkle Auto-Update

### Task 14: Add Sparkle 2 dependency to macOS app

**Files:**
- Modify: `macos/ClipRelayMac/Package.swift` (add Sparkle dependency)

- [ ] **Step 1: Add Sparkle to Package.swift**

```swift
// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "clipboard-sync-mac",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ClipRelay", targets: ["ClipRelay"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "ClipRelay",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources"
        ),
        .testTarget(
            name: "ClipRelayTests",
            dependencies: ["ClipRelay"],
            path: "Tests/ClipRelayTests"
        )
    ]
)
```

- [ ] **Step 2: Build to verify dependency resolves**

Run: `swift build --package-path macos/ClipRelayMac`
Expected: Sparkle downloads and builds successfully.

- [ ] **Step 3: Commit**

```bash
git add macos/ClipRelayMac/Package.swift macos/ClipRelayMac/Package.resolved
git commit -m "feat(mac): add Sparkle 2 dependency"
```

---

### Task 15: Integrate Sparkle updater into macOS app

**Files:**
- Modify: `macos/ClipRelayMac/Sources/App/AppDelegate.swift` (initialize Sparkle updater)
- Modify: `macos/ClipRelayMac/Sources/App/StatusBarController.swift` (add "Check for Updates" menu item)
- Modify: `scripts/build-all.sh` (add Sparkle plist keys: `SUFeedURL`, `SUPublicEDKey`)

- [ ] **Step 1: Read AppDelegate.swift and StatusBarController.swift**

Read both files to understand current initialization flow and menu structure.

- [ ] **Step 2: Add Sparkle updater controller to AppDelegate**

Import Sparkle and create an `SPUStandardUpdaterController` instance. Initialize it in `applicationDidFinishLaunching`:

```swift
import Sparkle

// In AppDelegate class:
private var updaterController: SPUStandardUpdaterController!

// In applicationDidFinishLaunching:
updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
```

Pass the updater to StatusBarController so it can add menu items.

- [ ] **Step 3: Add "Check for Updates" menu item to StatusBarController**

```swift
let checkForUpdatesItem = NSMenuItem(title: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
checkForUpdatesItem.target = updaterController
menu.addItem(checkForUpdatesItem)
```

- [ ] **Step 4: Add Sparkle plist keys to build-all.sh**

In the Info.plist heredoc, add:

```xml
<key>SUFeedURL</key>
<string>https://raw.githubusercontent.com/geekflyer/cliprelay/main/sparkle/appcast.xml</string>
<key>SUPublicEDKey</key>
<string>${SPARKLE_PUBLIC_KEY}</string>
```

Read `SPARKLE_PUBLIC_KEY` from environment variable or a file. For dev builds where no key is set, omit the `SUPublicEDKey` entry entirely (an empty key will break Sparkle signature validation). Use a conditional in the build script:

```bash
SPARKLE_PLIST_KEYS=""
if [[ -n "${SPARKLE_PUBLIC_KEY:-}" ]]; then
    SPARKLE_PLIST_KEYS="<key>SUPublicEDKey</key><string>${SPARKLE_PUBLIC_KEY}</string>"
fi
```

Note: The heredoc delimiter was already changed from `<<'PLIST'` to `<<PLIST` (unquoted) in Task 1 to enable variable expansion.

- [ ] **Step 5: Build and verify**

Run: `./scripts/build-all.sh --mac-only`
Expected: Build succeeds with Sparkle integrated. The menu bar dropdown shows "Check for Updates…".

- [ ] **Step 6: Commit**

```bash
git add macos/ClipRelayMac/Sources/ scripts/build-all.sh
git commit -m "feat(mac): integrate Sparkle 2 auto-updater with menu bar UI"
```

---

### Task 16: Add Sparkle appcast generation to release workflow

**Files:**
- Create: `sparkle/` directory (will contain appcast.xml, managed by CI)
- Modify: `.github/workflows/release-mac.yml` (add appcast update step)

- [ ] **Step 1: Create initial empty appcast**

Create `sparkle/appcast.xml`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
        <title>ClipRelay</title>
        <link>https://cliprelay.org</link>
        <description>ClipRelay macOS updates</description>
    </channel>
</rss>
```

- [ ] **Step 2: Add appcast update step to release-mac.yml**

After the DMG is signed and notarized, add a step that uses Sparkle's `generate_appcast` tool or manually appends an `<item>` to the appcast XML, then commits and pushes the updated appcast back to `main`:

```yaml
      - name: Download Sparkle tools
        run: |
          # Download Sparkle release and extract CLI tools
          SPARKLE_VERSION="2.6.0"
          curl -sL "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz" -o /tmp/sparkle.tar.xz
          mkdir -p /tmp/sparkle-tools
          tar xf /tmp/sparkle.tar.xz -C /tmp/sparkle-tools
          # sign_update is at bin/sign_update inside the extracted archive

      - name: Generate Sparkle EdDSA signature
        id: sparkle-sign
        env:
          SPARKLE_PRIVATE_KEY: ${{ secrets.SPARKLE_PRIVATE_KEY }}
        run: |
          DMG_SIZE=$(stat -f%z dist/ClipRelay.dmg)
          SIGNATURE=$(echo "$SPARKLE_PRIVATE_KEY" | /tmp/sparkle-tools/bin/sign_update dist/ClipRelay.dmg)
          echo "signature=$SIGNATURE" >> "$GITHUB_OUTPUT"
          echo "size=$DMG_SIZE" >> "$GITHUB_OUTPUT"

      - name: Update appcast.xml
        run: |
          ./scripts/update-appcast.sh \
            --version "${{ steps.version.outputs.version }}" \
            --signature "${{ steps.sparkle-sign.outputs.signature }}" \
            --size "${{ steps.sparkle-sign.outputs.size }}" \
            --url "https://github.com/geekflyer/cliprelay/releases/download/mac/v${{ steps.version.outputs.version }}/ClipRelay.dmg"

      - name: Commit updated appcast
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git fetch origin main
          git checkout main
          git add sparkle/appcast.xml
          git commit -m "chore: update Sparkle appcast for v${{ steps.version.outputs.version }}"
          git push origin main
```

- [ ] **Step 3: Create `scripts/update-appcast.sh`**

```bash
#!/usr/bin/env bash
# Inserts a new <item> into the Sparkle appcast XML.
# Usage: ./scripts/update-appcast.sh --version 0.3.2 --signature "..." --size 12345 --url "https://..."
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPCAST="$ROOT_DIR/sparkle/appcast.xml"

VERSION="" SIGNATURE="" SIZE="" URL=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --signature) SIGNATURE="$2"; shift 2 ;;
        --size) SIZE="$2"; shift 2 ;;
        --url) URL="$2"; shift 2 ;;
        *) echo "Unknown: $1" >&2; exit 1 ;;
    esac
done

[[ -z "$VERSION" || -z "$SIGNATURE" || -z "$SIZE" || -z "$URL" ]] && { echo "Missing args" >&2; exit 1; }

DATE=$(date -R)

# Build the new <item> XML
ITEM="        <item>
            <title>Version ${VERSION}</title>
            <pubDate>${DATE}</pubDate>
            <sparkle:version>${VERSION}</sparkle:version>
            <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
            <enclosure url=\"${URL}\"
                       sparkle:edSignature=\"${SIGNATURE}\"
                       length=\"${SIZE}\"
                       type=\"application/octet-stream\" />
        </item>"

# Insert before </channel> closing tag
sed -i.bak "s|</channel>|${ITEM}\n    </channel>|" "$APPCAST"
rm -f "${APPCAST}.bak"

echo "==> Updated appcast with version ${VERSION}"
```

- [ ] **Step 4: Commit**

```bash
git add sparkle/appcast.xml .github/workflows/release-mac.yml scripts/update-appcast.sh
git commit -m "feat(mac): add Sparkle appcast generation to release pipeline"
```

---

## Chunk 6: Website & Cleanup

### Task 17: Update website download links to use GitHub Releases

**Files:**
- Modify: `website/index.html:124` (main download button)
- Modify: `website/index.html:529` (footer download link)
- Create: `website/js/download.js` (dynamic latest-release resolver)

- [ ] **Step 1: Create `website/js/download.js`**

```js
(function() {
    const REPO = 'geekflyer/cliprelay';
    const API_URL = `https://api.github.com/repos/${REPO}/releases`;

    async function getLatestMacDownloadUrl() {
        try {
            const response = await fetch(API_URL);
            const releases = await response.json();
            const macRelease = releases.find(r => r.tag_name.startsWith('mac/'));
            if (macRelease) {
                const dmgAsset = macRelease.assets.find(a => a.name === 'ClipRelay.dmg');
                if (dmgAsset) return dmgAsset.browser_download_url;
            }
        } catch (e) {
            console.warn('Failed to fetch latest release URL, using fallback', e);
        }
        // Fallback: direct link to latest release page
        return `https://github.com/${REPO}/releases`;
    }

    document.addEventListener('DOMContentLoaded', async function() {
        const url = await getLatestMacDownloadUrl();
        document.querySelectorAll('a[data-download="mac"]').forEach(link => {
            link.href = url;
        });
    });
})();
```

- [ ] **Step 2: Update download links in `website/index.html`**

Replace the two hardcoded download links (lines 124 and 529):

```html
<!-- Line 124: change href and add data attribute -->
<a href="/downloads/ClipRelay.dmg" data-download="mac" class="btn btn-outline">

<!-- Line 529: change href and add data attribute -->
<li><a href="/downloads/ClipRelay.dmg" data-download="mac">macOS Download</a></li>
```

The `href` stays as a fallback; the JS overrides it with the latest GitHub Release URL.

- [ ] **Step 3: Add script tag to `website/index.html`**

Add before `</body>`:

```html
<script src="js/download.js"></script>
```

- [ ] **Step 4: Remove `website/downloads/` directory**

Once GitHub Releases is the source, the static DMG in the repo is no longer needed:

```bash
rm -rf website/downloads/
```

Update `.gitignore` if needed.

- [ ] **Step 5: Commit**

```bash
git add website/js/download.js website/index.html
git rm -r website/downloads/ 2>/dev/null || true
git commit -m "feat(website): dynamic download links from GitHub Releases"
```

---

### Task 18: Generate Sparkle EdDSA key pair

This is a one-time setup task, not automated.

- [ ] **Step 1: Generate keys using Sparkle's tool**

Download Sparkle's release binary and use the bundled tools:

```bash
# Download Sparkle release
SPARKLE_VERSION="2.6.0"
curl -sL "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz" -o /tmp/sparkle.tar.xz
mkdir -p /tmp/sparkle-tools && tar xf /tmp/sparkle.tar.xz -C /tmp/sparkle-tools
/tmp/sparkle-tools/bin/generate_keys
```

This outputs a public key (to embed in Info.plist) and prints the private key to stdout (or stores it in Keychain depending on the version).

- [ ] **Step 2: Export private key and add to GitHub Secrets**

Export the private key and add it as `SPARKLE_PRIVATE_KEY` in GitHub repository secrets.

- [ ] **Step 3: Set the public key**

Add the public key string to `scripts/build-all.sh` or an environment variable so it gets injected into `SUPublicEDKey` in the Info.plist.

- [ ] **Step 4: Document in README or PUBLISHING.md**

Note the key generation process and where keys are stored.

---

### Task 19: Add macOS signing secrets setup documentation

This is a one-time setup task for configuring GitHub Actions secrets.

- [ ] **Step 1: Document required secrets**

Add to `docs/PUBLISHING.md` or a new `docs/CI-SETUP.md`:

```markdown
## GitHub Actions Secrets

### macOS
- `MACOS_CERTIFICATE_P12`: Base64-encoded Developer ID .p12 certificate
  - Export from Keychain Access: select cert → Export → .p12
  - Encode: `base64 -i certificate.p12 | pbcopy`
- `MACOS_CERTIFICATE_PASSWORD`: Password used when exporting .p12
- `NOTARY_APPLE_ID`: Apple ID email for notarization
- `NOTARY_PASSWORD`: App-specific password (generate at appleid.apple.com)
- `NOTARY_TEAM_ID`: Apple Developer Team ID (e.g., B66YFKPUA8)

### Android
- `ANDROID_KEYSTORE_BASE64`: Base64-encoded release keystore
  - Encode: `base64 -i cliprelay-release.keystore | pbcopy`
- `ANDROID_KEYSTORE_PASSWORD`: Keystore password
- `ANDROID_KEY_ALIAS`: Key alias
- `ANDROID_KEY_PASSWORD`: Key password
- `PLAY_SERVICE_ACCOUNT_JSON`: Full JSON contents of Play Console service account

### Sparkle
- `SPARKLE_PRIVATE_KEY`: EdDSA private key for signing Sparkle updates
```

- [ ] **Step 2: Commit**

```bash
git add docs/
git commit -m "docs: add CI secrets setup guide"
```

---

## Task Dependency Graph

```
Task 1 (VERSION files) ──→ Task 2 (macOS version UI)
                       ──→ Task 3 (Android version UI)
                       ──→ Task 4 (AGENTS.md update)
                       ──→ Task 9 (release.sh)

Task 5 (SwiftLint) ──→ Task 7 (lint-all.sh)
Task 6 (ktlint)    ──→ Task 7 (lint-all.sh)

Task 7 (lint-all.sh) ──→ Task 11 (ci.yml)

Task 8 (changelog.sh) ──→ Task 12 (release-mac.yml)
                       ──→ Task 13 (release-android.yml)

Task 10 (publish-android --promote) ──→ Task 13 (release-android.yml)

Task 14 (Sparkle dep) ──→ Task 15 (Sparkle integration)
                       ──→ Task 16 (appcast generation)
                       ──→ Task 18 (EdDSA keys)

Task 12 + Task 13 ──→ Task 17 (website download links)

Task 18 + Task 19 are one-time setup, can happen anytime after Task 14.
```

## Parallelizable Groups

The following task groups are independent and can be worked on concurrently:

- **Group A**: Tasks 1-4 (version management)
- **Group B**: Tasks 5-7 (linting)
- **Group C**: Task 8 (changelog script)
- **Group D**: Tasks 14-16 (Sparkle)

Tasks 9-13 and 17-19 have dependencies and should follow their prerequisites.
