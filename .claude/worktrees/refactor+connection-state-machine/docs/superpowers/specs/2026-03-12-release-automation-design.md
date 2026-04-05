# Release Automation Design

**Date:** 2026-03-12
**Status:** Approved

## Overview

Automate the ClipRelay release and testing process across macOS and Android platforms. Replaces the current fully-manual workflow with CI-driven builds, testing, signing, publishing, and auto-updates.

## 1. Version Management

### Per-Platform Version Files
- `macos/VERSION` — contains semver string (e.g., `0.3.2`)
- `android/VERSION` — contains semver string (e.g., `0.3.0`)

### Version Convention
- **Major version**: Protocol-breaking changes — both platforms bump together
- **Minor version**: Feature additions — bump whichever platform(s) it applies to
- **Patch version**: Bug fixes / UI tweaks — bump only the affected platform

### Build Identifier
- Short git commit hash injected at build time (e.g., `0.3.2 (a1b2c3f)`)
- **macOS**: `build-all.sh` injects git hash into Info.plist using a custom `ClipRelayGitHash` key via `PlistBuddy` or sed replacement in the heredoc template. `CFBundleVersion` remains the build number.
- **Android**: Requires `buildFeatures { buildConfig = true }` in `build.gradle.kts`, then `buildConfigField("String", "GIT_HASH", "\"${gitHash}\"")` where `gitHash` is computed via `git rev-parse --short HEAD`.

### Build Scripts — Migration from Hardcoded Versions
Currently, versions are hardcoded:
- `build-all.sh` line ~117 hardcodes `CFBundleShortVersionString` as `0.1.0` in the Info.plist heredoc
- `android/app/build.gradle.kts` line ~68 hardcodes `versionName = "0.1.0"`

These must be replaced:
- `build-all.sh`: Read `macos/VERSION` file and substitute into the Info.plist heredoc template
- `build.gradle.kts`: Read `android/VERSION` file via `file("../VERSION").readText().trim()` for `versionName`

### Android `versionCode` Strategy
Use git tag count for the `android/v*` tags: `git tag -l 'android/v*' | wc -l`. This auto-increments with each release without requiring manual tracking. The existing manual `versionCode` policy in `android/AGENTS.md` should be removed once this is implemented.

### Version Display in UI
- **Android**: Settings/About screen shows version from `BuildConfig.VERSION_NAME` + `BuildConfig.GIT_HASH`
- **macOS**: Menu bar or status bar tooltip shows version from `Bundle.main.infoDictionary`

### Release Script (`scripts/release.sh`)
```bash
./scripts/release.sh --mac 0.3.2      # bumps macos/VERSION, commits, tags mac/v0.3.2, pushes
./scripts/release.sh --android 0.3.1   # bumps android/VERSION, commits, tags android/v0.3.1, pushes
./scripts/release.sh --all 0.4.0       # bumps both, commits, tags both, pushes
```

The script:
- Validates the version is valid semver
- Confirms you're on `main` branch
- Runs `test-all.sh` before tagging
- Commits version bump, creates tag(s), pushes

## 2. CI Pipeline (GitHub Actions)

### Design Principle
All logic lives in local scripts. CI just calls them. Everything that runs in CI can be reproduced locally.

### On Every Push / PR (`ci.yml`)
```bash
./scripts/lint-all.sh       # SwiftLint + ktlint
./scripts/test-all.sh       # Unit tests for both platforms
./scripts/build-all.sh      # Build verification (compilation check)
```

### On Tag `mac/v*` (`release-mac.yml`)
```bash
./scripts/build-all.sh --mac-only --release
./scripts/publish-mac.sh    # Sign, notarize, create DMG
```
Then: create GitHub Release with DMG attached, update Sparkle appcast.

### On Tag `android/v*` (`release-android.yml`)
```bash
./scripts/build-all.sh --android-only --release
./scripts/publish-android.sh --track internal
```
Then: create GitHub Release with APK attached.

### Manual Workflow Dispatch — Promote Android
```bash
./scripts/publish-android.sh --promote --from internal --to production
```
Triggered via GitHub Actions UI when ready to promote from internal testing to production.

**Note:** The existing `publish-android.sh` only supports `--track`. The `--promote`, `--from`, and `--to` flags are new functionality to be added, wrapping Gradle Play Publisher's `promoteArtifact` task.

### GitHub Actions Secrets Required
- **macOS**: Developer ID certificate (.p12) + password
- **Android**: Keystore file + passwords, Play Console service account JSON
- **Sparkle**: EdDSA private signing key

### Workflow Structure
Three workflow files:
- `.github/workflows/ci.yml` — push/PR: lint + test + build
- `.github/workflows/release-mac.yml` — `mac/v*` tag: build, sign, notarize, release
- `.github/workflows/release-android.yml` — `android/v*` tag: build, sign, release + manual promote job

## 3. Sparkle Auto-Update (macOS)

### Integration
- Sparkle 2 framework added as a Swift Package dependency in `Package.swift`
- `SPUStandardUpdaterController` initialized at app startup
- On launch, Sparkle checks an appcast XML file for available updates
- If a newer version exists, the user gets a native macOS update prompt

### Appcast
- CI generates/updates appcast XML as part of `release-mac.yml` after notarization using Sparkle's `generate_appcast` tool
- Hosted at a predictable URL (e.g., `https://raw.githubusercontent.com/geekflyer/cliprelay/main/sparkle/appcast.xml` or GitHub Pages)
- Download URLs in appcast point to GitHub Releases DMGs

### Signing
- Sparkle EdDSA signing key generated once via Sparkle's `generate_keys` tool
- Private key stored as GitHub Actions secret
- Public key embedded in the app's Info.plist as `SUPublicEDKey`

### Update Cadence
- Checks on launch + periodically (Sparkle default: every 24 hours)
- User can disable via "Check for Updates" toggle in the menu bar dropdown (ClipRelay is a menu-bar-only app with `LSUIElement = true`)

### Implementation Note
Sparkle integration requires additional design decisions during implementation (e.g., handling of the update UI in a menu-bar-only context, delta updates, minimum system version checks). These will be resolved during the implementation phase.

## 4. GitHub Releases & Changelogs

### Separate Releases Per Platform
- Tag `mac/v0.3.2` → GitHub Release titled "macOS v0.3.2"
- Tag `android/v0.3.1` → GitHub Release titled "Android v0.3.1"

### Changelog Generation
- Auto-generated from commit messages between previous and current tag for that platform
- Filtered to commits touching relevant platform code (`macos/` for mac; `android/` for android). Commits touching only `scripts/` or root files appear in both changelogs since they may affect either platform.
- Local script: `scripts/changelog.sh --mac v0.3.1..v0.3.2`
- Compact format: one line per meaningful change, grouped by type (features, fixes)

### Release Artifacts
- **macOS**: Notarized DMG attached
- **Android**: Release APK attached (AAB goes to Play Store only)

### Play Store Release Notes
- Same changelog content piped into Play Store upload via Gradle Play Publisher

## 5. Website Integration

### Download Links
Download buttons on `cliprelay.org` dynamically resolve to the latest platform-specific release using a JavaScript snippet that queries the GitHub API:

```js
fetch('https://api.github.com/repos/geekflyer/cliprelay/releases')
  .then(r => r.json())
  .then(releases => releases.find(r => r.tag_name.startsWith('mac/')))
  .then(r => r.assets.find(a => a.name === 'ClipRelay.dmg').browser_download_url)
```

### Benefits
- No website redeployment needed for new releases
- No binary artifacts in the git repo
- DMGs served directly from GitHub Releases (no GitHub UI shown to user)

### Website Deployment
Continues via Cloudflare Pages. Could optionally add a CI job triggered on changes to `website/`.

## 6. Linting

### New Script: `scripts/lint-all.sh`
- **Swift**: SwiftLint (Homebrew locally, GitHub Action in CI)
- **Kotlin**: ktlint (via Gradle plugin, no extra install)

### Configuration
- `.swiftlint.yml` checked into repo for SwiftLint rules
- ktlint config in `build.gradle.kts` or `.editorconfig`
- Same rules enforced locally and in CI

### Behavior
Script exits non-zero on any lint failure, blocking CI and matching local behavior.

## 7. Hardware Tests

BLE hardware smoke tests remain local-only (run when `adb get-state` detects a device). No cloud BLE testing service exists that supports the Mac ↔ Android pairing scenario ClipRelay requires.

## 8. Migration Checklist

Items in the current codebase that need updating as part of this work:
- Remove hardcoded versions from `build-all.sh` and `build.gradle.kts` (replaced by VERSION files)
- Remove manual `versionCode` increment policy from `android/AGENTS.md`
- Remove `website/downloads/` directory and static DMG hosting (replaced by GitHub Releases)
- Add `--promote` support to `publish-android.sh`
- Add `buildFeatures { buildConfig = true }` to Android `build.gradle.kts`
- Add Sparkle 2 dependency to `Package.swift`
- Consider `.gitignore`-ing or removing `cliprelay-release.keystore` from repo root (security concern — should be a CI secret only)
