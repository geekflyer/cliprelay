# BLE Hardware Smoke Checklist

Use this checklist for real-device validation with one macOS host and one Android device.

## Preflight

- Build artifacts exist: `dist/GreenPaste.app` and `dist/greenpaste-debug.apk`
- Android app installed and launchable
- Devices paired through app QR flow and visible as trusted peers
- Android foreground service running

Optional helper:

```bash
./scripts/ble-hardware-smoke.sh
```

Automated helper for debug builds (includes automated pairing import):

```bash
./scripts/ble-hardware-smoke-auto.sh
```

Notes for automated helper:

- Requires debug APK build and USB debugging enabled.
- Uses a debug-only Android receiver to import a fresh pairing token.
- Uses a macOS CLI mode (`--smoke-import-pairing`) to import the same token locally.
- Reads debug probe state from app private storage via `adb run-as`.
- Removes the temporary smoke pairing at the end by default (pass `--keep-pairing` to keep it).

## Manual Test Cases

### 1) Mac -> Android clipboard sync

1. Copy unique text on macOS (include timestamp to avoid stale match).
2. On Android, paste into a text field.
3. Confirm pasted text matches exactly.

Expected result: Android receives new text within a few seconds.

### 2) Android Share -> Mac clipboard sync

1. On Android, select text and use Share -> GreenPaste.
2. On macOS, paste into a text field.
3. Confirm pasted text matches exactly.

Expected result: macOS receives shared text within a few seconds.

### 3) Reconnect after Bluetooth toggle

1. On Android, turn Bluetooth OFF.
2. Wait 5-10 seconds, then turn Bluetooth ON.
3. Wait for reconnect.
4. Repeat test case 1 and 2.

Expected result: connection recovers automatically and both transfer directions still work.

## Run Log Template

- Date:
- macOS version:
- Android device/model:
- Android version:
- Result Mac -> Android: pass/fail
- Result Android -> Mac: pass/fail
- Result reconnect cycle: pass/fail
- Notes/log excerpts:
