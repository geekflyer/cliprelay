# CI/CD Setup Guide

## Prerequisites

- [1Password CLI](https://developer.1password.com/docs/cli/) (`op`) installed and authenticated
- [GitHub CLI](https://cli.github.com/) (`gh`) installed and authenticated
- Access to the 1Password `cliprelay` shared vault

## GitHub Actions Secrets

Only one GitHub Actions secret is needed:

| Secret | Description |
|--------|-------------|
| `OP_SERVICE_ACCOUNT_TOKEN` | 1Password service account token with read access to the `cliprelay` vault |

All other secrets are loaded at runtime from 1Password using `1Password/load-secrets-action@v3`.

## 1Password Vault Structure

Vault: `cliprelay`

| Item | Fields | Used by |
|------|--------|---------|
| `macOS Signing Certificate` | `p12-base64`, `password` | `release-mac.yml` |
| `macOS Notarization` | `apple-id`, `password`, `team-id` | `release-mac.yml` |
| `Android Keystore` | `keystore-base64`, `password`, `key-alias`, `key-password` | `release-android.yml` |
| `Android Play Store` | `service-account-json` | `release-android.yml` |
| `Sparkle Update Signing` | `private-key`, `public-key` | `release-mac.yml` |
| `Cloudflare Pages` | `api-token` | `release-mac.yml` |

## Initial Setup

Run the setup script to populate both GitHub and 1Password:

```bash
./scripts/setup-github-secrets.sh
```

This will:
1. Set `OP_SERVICE_ACCOUNT_TOKEN` as a GitHub Actions secret
2. Create all items in the 1Password `cliprelay` vault
3. Pull credentials from existing local files and 1Password items where possible
4. Prompt for anything that can't be automated (Apple app-specific password, Sparkle public key)

## Rotating Secrets

To rotate a secret, update the field in the 1Password `cliprelay` vault. No GitHub Actions changes needed — workflows read from 1Password at runtime.

To rotate the service account token, generate a new one in 1Password admin console and update the `OP_SERVICE_ACCOUNT_TOKEN` GitHub secret.

## Workflows

| Workflow | Trigger | What it does |
|----------|---------|-------------|
| `ci.yml` | Push to main, PRs | Lint, test, build for both platforms |
| `release-mac.yml` | Tag `mac/v*` | Build, sign, notarize, create GitHub Release, update Sparkle appcast |
| `release-android.yml` | Tag `android/v*` | Build, sign, publish to Play Store internal track, create GitHub Release |
| `release-android.yml` | Manual dispatch (promote) | Promote from internal to production track |

## Release Process

```bash
# Release macOS only
./scripts/release.sh --mac 0.2.0

# Release Android only
./scripts/release.sh --android 0.2.0

# Release both
./scripts/release.sh --all 0.2.0

# Promote Android to production (after testing internal build)
# Go to GitHub Actions → Release Android → Run workflow → Check "Promote"
```

### Pre-release versions

`scripts/release.sh` also supports semver pre-release versions for beta/release-candidate builds.

- Preferred format: `0.4.7-rc.1`, `0.4.7-beta.1`, `0.4.7-alpha.1`
- Currently accepted but less clear: `0.4.7-rc1`
- Any version containing `-` is treated as a beta release automatically

Examples:

```bash
# Release both platforms as a release candidate
./scripts/release.sh --all 0.4.7-rc.1

# Release Android only as a beta
./scripts/release.sh --android 0.4.7-beta.1
```

Behavior:

- Stable releases such as `0.4.7` must be run from `main` or `beta`
- Pre-release versions such as `0.4.7-rc.1` may be run from any branch
- If the current branch is `beta`, the release is also treated as beta even without a suffix

Platform-specific beta handling:

- macOS: creates a GitHub prerelease and writes the update to the Sparkle `beta` channel in `appcast.xml`
- Android: creates a GitHub prerelease and publishes to the Play Store `internal` track only

Tag naming is platform-specific and is created by the GitHub Actions workflow after a successful build:

- macOS: `mac/v<version>`
- Android: `android/v<version>`

Examples:

- `mac/v0.4.7-rc.1`
- `android/v0.4.7-beta.1`
