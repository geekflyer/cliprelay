---
name: notarize-mac-build
description: Produce a local notarized, stapled macOS DMG for standalone install on another Mac (no Sparkle release). Use when asked to build/notarize the Mac app, create a notarized DMG, hand someone a Mac build without a Sparkle update, or set up notarytool credentials. macOS-only.
---

# Local notarized macOS build

Produces `dist/ClipRelay-<version>.dmg` — Developer ID–signed, notarized by Apple, and stapled — installable on any Mac with no Gatekeeper friction. Use this when someone needs the app on another machine **without waiting for a Sparkle release**.

## Steps

1. **Build the signed app:**
   ```
   ./scripts/build-all.sh --mac-only
   ```
   Signs with Developer ID + hardened runtime. Output: `dist/ClipRelay.app`.

2. **Sign → DMG → notarize → staple → validate (one command):**
   ```
   ./scripts/publish-mac.sh --wait
   ```
   `--wait` blocks ~2–5 min on Apple's notary service, then staples + validates. No appcast/upload side effects, so it's safe for a one-off. Output: `dist/ClipRelay-<version>.dmg`.

3. **Verify the app inside the DMG:**
   ```
   hdiutil attach dist/ClipRelay-<version>.dmg
   spctl -a -vvv "/Volumes/ClipRelay/ClipRelay.app"   # expect: accepted / source=Notarized Developer ID
   hdiutil detach /Volumes/ClipRelay
   ```

Then hand over `dist/ClipRelay-<version>.dmg`. First launch on the other Mac shows the normal "downloaded from the internet" prompt — **not** the "unidentified developer" block.

## Prerequisites (one-time per machine)

- **`create-dmg`:** `brew install create-dmg` (publish-mac.sh fails preflight without it).
- **Developer ID Application cert** in the login keychain — already present if `build-all.sh` signs without error. Identity: `Developer ID Application: Christian Theilemann (B66YFKPUA8)`.
- **The `ClipRelay` notarytool keychain profile.** Check it exists:
  ```
  xcrun notarytool history --keychain-profile "ClipRelay"
  ```
  If it errors with `No Keychain password item found`, create it from the 1Password `cliprelay` vault (item `macOS Notarization`, fields `apple-id` / `password` / `team-id`):
  ```
  xcrun notarytool store-credentials "ClipRelay" \
    --apple-id "$(op read 'op://cliprelay/macOS Notarization/apple-id')" \
    --team-id  "$(op read 'op://cliprelay/macOS Notarization/team-id')" \
    --password "$(op read 'op://cliprelay/macOS Notarization/password')"
  ```
  (If the `team-id` field is ever missing, hardcode `--team-id B66YFKPUA8`.)

## Gotcha — `op signin` does NOT reach an agent's shell

An interactive `op signin` authenticates only **that terminal**. An automated/agent Bash tool runs in a separate process and will see `op: not signed in`, so it can't read the 1Password creds itself. On a fresh machine where the profile isn't set up yet, either:

- **(a)** the user runs the `store-credentials` command above in their own signed-in terminal, or
- **(b)** they enable 1Password's CLI ↔ desktop-app integration so any process can authenticate.

**Once the profile is stored in the login keychain it persists and is reusable by any process** (including an agent's `notarytool` / `publish-mac.sh` calls). So this is a one-time setup — an agent only needs the user's help the very first time on a new machine; after that, steps 1–3 are fully hands-off.

## Notes

- The DMG is stapled; the `.app` inside isn't individually stapled (this matches the normal release flow). With internet on first launch it's seamless. For a **guaranteed-offline** first launch the app would also need stapling — only do that if asked.
- Check notarization history any time: `xcrun notarytool history --keychain-profile "ClipRelay"`.
- This is the same `scripts/publish-mac.sh` the real Sparkle releases use, just run standalone — so the artifact matches a normal release build.
