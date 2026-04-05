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
