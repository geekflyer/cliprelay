# AGENTS Instructions

## Commit Policy
- When the worktree has unrelated changes, commit only files relevant to the task.

## Build Verification
- After completing any set of code changes, ALWAYS run `scripts/build-all.sh` before reporting completion.
- If a full rebuild is not possible, run the closest relevant target build and clearly report what was run and what could not be run.

## Integration Tests
- After every major code change (new feature, bug fix, refactor), run the full test suite using `scripts/test-all.sh` before committing.
- If any tests fail, fix the failures before committing or reporting completion.
- If the test suite cannot be run (e.g., missing toolchain), clearly report which tests were skipped and why.

## Hardware Integration Tests
- After every major code change, check if an Android device is connected by running `adb get-state 2>/dev/null`.
- If a device is connected (output is "device"), run the automated BLE hardware smoke tests using `scripts/hardware-smoke-test.sh` before committing.
- If the hardware tests fail, fix the failures before committing or reporting completion.
- If no Android device is connected, skip the hardware tests and report that they were skipped due to no device being available.

## App Restart After Code Changes
- After every major code change (new feature, bug fix, refactor), restart both apps so the user can immediately verify the fix:
  - **Mac**: Kill any running ClipRelay process (`pkill -f ClipRelay`) and relaunch with `open dist/ClipRelay.app`
  - **Android**: Install the new APK (`adb install -r dist/cliprelay-debug.apk`), force-stop the app (`adb shell am force-stop org.cliprelay`), and relaunch (`adb shell am start -n org.cliprelay/.ui.MainActivity`)
- Do not skip this step or tell the user to do it manually.

## macOS Notarization
- Keychain profile name: `ClipRelay`
- Use with: `xcrun notarytool submit <file> --keychain-profile "ClipRelay" --wait`
- Check history: `xcrun notarytool history --keychain-profile "ClipRelay"`

## Android UI Design Verification
- After any visual/design change to the Android app, take a screenshot of the running app to verify the result before reporting completion.
- Use `adb exec-out screencap -p > /tmp/cliprelay-screenshot.png` to capture, then read the image to visually inspect the layout.
- Use this as a feedback loop: if something looks off, fix it before committing.
- This applies to any change affecting UI layout, colors, spacing, icons, animations, or theming.
