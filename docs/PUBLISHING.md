# ClipRelay Publishing Checklist

## Overview
Distribution channels:
1. **Android** → Google Play Store
2. **macOS** → Direct download with Apple notarization (website)

Mac App Store is deferred to a later phase. Pricing is free for now; Android may add paid Pro features later (rich content transfer).

---

## Branching: `main` vs `beta`

| Branch | Role | Version format | Android (CI) | macOS (CI) |
|--------|------|----------------|--------------|------------|
| **`main`** | Production releases only | `X.Y.Z` (semver) | Publish to **production** track; tag `android/vX.Y.Z`; GitHub Release | Stable Sparkle feed `appcast.xml` on branch `sparkle`; tag `mac/vX.Y.Z` |
| **`beta`** | Early testers / integration | `X.Y.Z-beta.N` (e.g. `1.2.0-beta.3`) | Publish to **internal** (default) or **beta** (open testing); tag `android/beta/v…`; GitHub prerelease | Beta Sparkle feed `appcast-beta.xml` on `sparkle`; tag `mac/beta/v…`; builds use `--beta-mac` (SUFeedURL → `appcast-beta.xml`) |

**Development flow**

- Open feature branches from **`beta`**, merge into **`beta`** first.
- After tester signoff, promote with a PR **`beta` → `main`** for the release window you want to ship to production.
- **Production hotfixes:** land on **`main`** first, then merge or cherry-pick back into **`beta`** so the branches do not diverge on fixes.

**CI:** [.github/workflows/ci.yml](../.github/workflows/ci.yml) runs on pushes and PRs to **`main`** and **`beta`**.

**Automated releases**

- From repo root, on the correct branch, run [scripts/release.sh](../scripts/release.sh) (bumps `macos/VERSION` / `android/VERSION`, runs tests, pushes, dispatches workflows on the **current** branch):
  - **Stable:** `./scripts/release.sh --mac 0.3.2` (on `main`)
  - **Beta:** `./scripts/release.sh --android 1.2.0-beta.1` (on `beta`)
- **Android beta Play track:** optional env `CLIPRELAY_PLAY_TRACK=beta` (default `internal`) when dispatching from `beta`.

**GitHub Actions:** run **Release Android** / **Release macOS** via *Run workflow* and select branch **`main`** or **`beta`** in the UI (or use `gh workflow run … --ref beta`). Tag patterns and store tracks are derived from that branch.

**macOS hosting:** serve both feeds over HTTPS on the update host (e.g. `https://updates.cliprelay.org/appcast.xml` and `https://updates.cliprelay.org/appcast-beta.xml`). The release workflow appends entries to `appcast.xml` or `appcast-beta.xml` on the **`sparkle`** branch; deploy that branch (or those files) so betas resolve the beta feed.

---

## Rollback (git and stores)

**Principle:** Do **not** force-push or rewrite **`beta`** once testers have consumed builds. Use forward-fixes and `git revert`.

### Bad change only on `beta`

1. On **`beta`:** `git revert <sha>` (for a bad merge, revert the **merge commit**).
2. Push **`beta`**, cut a **new** beta version (`X.Y.Z-beta.N+1`) with `scripts/release.sh` if you need a fixed build for testers.
3. When the fix is ready, merge the corrected work normally (or revert the revert).

### Bad change on `main` (production)

1. On **`main`:** `git revert <sha>` (or hotfix branch → PR → `main`).
2. Ship a new **stable** patch version from **`main`** via `scripts/release.sh`.
3. Merge **`main` → `beta`** (or cherry-pick the revert/hotfix) so **`beta`** includes the same fix.

### Android (Play Console)

- **Production:** roll back or halt rollout in Play Console; fix forward with a new version if needed.
- **Internal / beta:** replace with a newer upload or deactivate the broken release per Play policies.

### macOS (Sparkle)

- **Stable:** edit the **`sparkle`** branch `appcast.xml` only with care (users upgrade from the feed). Prefer shipping a **new** version that fixes the issue; for emergencies, remove or repoint items per Sparkle ops guidance.
- **Beta:** same for `appcast-beta.xml`; beta testers can reinstall from the GitHub Release DMG if needed.

---

## Phase 1: Android — Google Play Store

### 1.1 Developer Account Setup
- [ ] Create a Google Play Developer account ($25 one-time fee) at https://play.google.com/console
- [ ] Complete identity verification (personal or organization)
- [ ] Set up a developer profile (name, email, website, privacy policy URL)

### 1.2 Release Signing
- [ ] Generate a production keystore (`cliprelay-release.keystore`) — **back up securely, losing this = can never update the app**
- [ ] Add `signingConfigs` block to `android/app/build.gradle.kts` for the `release` build type
- [ ] Configure ProGuard/R8 minification for release builds
- [ ] Update `build-all.sh` to support `--release` flag producing a signed AAB (Android App Bundle, required by Play Store)
- [ ] Verify the release build installs and runs correctly on a real device

#### Quick release checklist (per version)
1. Bump Android `versionCode` and `versionName` in `android/app/build.gradle.kts`
2. Ensure `android/keystore.properties` exists (copy `android/keystore.properties.example` and fill secrets locally)
   - Optional: use 1Password CLI instead of local file by exporting these env vars:
     - `CLIPRELAY_STORE_FILE`
     - `CLIPRELAY_STORE_PASSWORD`
     - `CLIPRELAY_KEY_ALIAS`
     - `CLIPRELAY_KEY_PASSWORD`
   - Example:

```bash
op run --env-file .env.play -- ./scripts/test-all.sh && op run --env-file .env.play -- ./scripts/build-all.sh --android-only --release
```

3. Run one command from repo root:

```bash
./scripts/test-all.sh && ./scripts/build-all.sh --android-only --release
```

4. Upload `dist/cliprelay-release.aab` to Play Console (Internal testing first)

#### Optional CLI publishing (Gradle Play Publisher)
1. In Play Console, go to `Setup` → `API access` and link a Google Cloud project.
2. Create a Google Cloud service account and grant it Play Console access (Release manager or higher).
3. Download the service account JSON key to `android/play-service-account.json` (local only, never commit).
4. Create `android/play.properties` from `android/play.properties.example`:

```properties
serviceAccountCredentials=play-service-account.json
track=internal
```

5. Publish from repo root:

```bash
op run --env-file .env.play -- ./scripts/publish-android.sh --track internal
```

For production rollout after internal validation:

```bash
op run --env-file .env.play -- ./scripts/publish-android.sh --track production
```

### 1.3 Store Listing Assets
- [ ] App icon: 512x512 PNG (high-res, no transparency)
- [ ] Feature graphic: 1024x500 PNG
- [ ] Screenshots: minimum 2, recommended 4-8 (phone + tablet if applicable)
  - Show pairing flow (QR scan)
  - Show clipboard sync in action
  - Show share sheet integration
- [ ] Short description (80 chars max)
- [ ] Full description (4000 chars max)
- [ ] App category: Tools / Productivity

### 1.4 Policy & Legal
- [ ] Write a privacy policy (required — explain BLE-only, no cloud, no data collection)
- [ ] Host privacy policy at a public URL (can be a GitHub Pages site or the future website)
- [ ] Complete the Data Safety questionnaire in Play Console
  - Data collected: None (clipboard data is transient, never persisted or transmitted to servers)
  - Encryption: Yes (AES-256-GCM end-to-end)
- [ ] Complete the App Content declarations (target audience, ads, etc.)

### 1.5 App Review Prep
- [ ] Ensure `targetSdk` is current (currently 35 — check latest requirement)
- [ ] Add BLE permission rationale strings in `strings.xml` for runtime permission dialogs
- [ ] Test all permission flows on a fresh install (BLE, notifications, nearby devices)
- [ ] Verify app works correctly after being killed/restarted by system

### 1.6 First Release
- [ ] Create an internal testing track first (invite a few testers)
- [ ] Graduate to closed/open testing if desired
- [ ] Submit for production release
- [ ] Monitor the review process (typically 1-3 days for first submission)

---

## Phase 2: macOS — Direct Download + Notarization

### 2.1 Apple Developer Account
- [ ] Enroll in Apple Developer Program ($99/year) at https://developer.apple.com
- [ ] Set up Developer ID Application certificate (for distribution outside the App Store)
- [ ] Set up a Developer ID Installer certificate (for .pkg if needed)

### 2.2 Code Signing & Notarization
- [ ] Add code signing to the build process using `codesign` with the Developer ID certificate
- [ ] Sign all embedded frameworks/binaries (if any)
- [ ] Set up `notarytool` for submitting to Apple's notarization service
- [ ] Add hardened runtime entitlements file:
  - `com.apple.security.device.bluetooth` (CoreBluetooth)
  - Any other required entitlements
- [ ] Update `build-all.sh` to support `--release` flag that signs, notarizes, and staples
- [ ] Verify the notarized app launches without Gatekeeper warnings on a clean Mac

### 2.3 Distribution Packaging
- [ ] Create a `.dmg` installer (drag ClipRelay.app to Applications)
- [ ] Sign and notarize the `.dmg` itself
- [ ] Consider adding a "Login Items" helper or prompt for launch-at-login setup
- [ ] Set up Sparkle (or similar) for auto-updates — include an `appcast.xml` feed URL
- [ ] Determine version numbering scheme (semver, build numbers for each release)

### 2.4 Website
- [ ] Register a domain (e.g., `cliprelay.app` or similar)
- [ ] Create a simple landing page with:
  - App description and key features
  - Download button for macOS `.dmg`
  - Link to Google Play Store for Android
  - Privacy policy page
  - Minimum system requirements (macOS 13+, Android 11+)
- [ ] Set up HTTPS (e.g., Cloudflare, Netlify, GitHub Pages with custom domain)
- [ ] Host the Sparkle appcast.xml for macOS auto-updates

---

## Phase 3: Shared / Cross-Cutting

### 3.1 Branding & Assets
- [ ] Finalize app icon for both platforms (consistent design)
- [ ] Create status bar icon variants if needed (light/dark mode)
- [ ] Write marketing copy (tagline, description)

### 3.2 Privacy Policy & Legal
- [ ] Write a single privacy policy covering both platforms
- [ ] Host at a stable URL (e.g., `cliprelay.app/privacy`)
- [ ] Consider adding a simple Terms of Service

### 3.3 Version & Release Management
- [x] GitHub Actions release workflows: **Release macOS**, **Release Android** (manual `workflow_dispatch` from `main` or `beta`)
- [x] GitHub Releases with attached Android APK / macOS DMG
- [x] Long-lived **`beta`** branch for phased tester builds; **`main`** for production
- [ ] Align version numbers across platforms per release window
- [ ] Optional: root `CHANGELOG.md` (today: [scripts/changelog.sh](../scripts/changelog.sh) generates notes per release)

---

## Future / Deferred

- [ ] Mac App Store submission (requires sandbox entitlements and App Store review)
- [ ] Android in-app purchase for Pro features (rich content transfer)
- [ ] Crash reporting / analytics (privacy-respecting, e.g., Sentry with minimal data)

---

## Verification Checklist
- [ ] Build a signed release APK/AAB and install on a real device — verify BLE pairing and clipboard sync work
- [ ] Build a signed + notarized macOS .app, put in a .dmg, download on a clean Mac — verify Gatekeeper passes and BLE works
- [ ] Test the full user journey: download from website/store → install → pair → sync clipboard both directions
