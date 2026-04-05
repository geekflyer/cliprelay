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

## Initial Setup

1. In GitHub: add repository secret **`OP_SERVICE_ACCOUNT_TOKEN`** (1Password service account with read access to the `cliprelay` vault).
2. In 1Password: ensure the vault items listed above exist and match the field names expected by the workflows.
3. Optional: document any local-only paths (e.g. `android/play-service-account.json`) in [PUBLISHING.md](./PUBLISHING.md).

## Rotating Secrets

To rotate a secret, update the field in the 1Password `cliprelay` vault. No GitHub Actions changes needed — workflows read from 1Password at runtime.

To rotate the service account token, generate a new one in 1Password admin console and update the `OP_SERVICE_ACCOUNT_TOKEN` GitHub secret.

## Workflows

| Workflow | Trigger | What it does |
|----------|---------|-------------|
| `ci.yml` | Push / PR to **`main`** or **`beta`** | Test and build (macOS on `macos-14`, Android on Ubuntu) |
| `release-mac.yml` | Manual `workflow_dispatch` on **`main`** or **`beta`** | Build, sign, notarize, tag `mac/v…` or `mac/beta/v…`, GitHub Release, update `appcast.xml` or `appcast-beta.xml` on **`sparkle`** |
| `release-android.yml` | Manual `workflow_dispatch` on **`main`** or **`beta`** | Release build, publish to Play **production** (from `main`) or **internal** / **beta** (from `beta`), tag `android/v…` or `android/beta/v…`, GitHub Release |
| `release-android.yml` | Manual dispatch **promote** (branch **`main`** only) | Promote Play artifact from **internal** → **production** |

## Release Process

```bash
# Release macOS only
./scripts/release.sh --mac 0.2.0

# Release Android only
./scripts/release.sh --android 0.2.0

# Release both
./scripts/release.sh --all 0.2.0

# Promote Android to production (optional if the last stable release used internal first)
# Actions → Release Android → Run workflow → Branch main → Check "Promote"
```

Branch rules and rollback: see [PUBLISHING.md](./PUBLISHING.md) (**Branching: main vs beta**, **Rollback**).
