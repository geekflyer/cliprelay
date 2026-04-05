# Android Auto-Copy & Sharing Enhancements

## Problem

Android 10+ restricts clipboard access to apps with window focus. A foreground service cannot read `getPrimaryClip()` or receive `addPrimaryClipChangedListener()` callbacks — both are gated behind `clipboardAccessAllowed()` in AOSP's [`ClipboardService.sendClipChangedBroadcast()`](https://github.com/aosp-mirror/platform_frameworks_base/blob/main/services/core/java/com/android/server/clipboard/ClipboardService.java). This makes automatic clipboard syncing from a background service impossible using the standard clipboard API alone.

## Approaches Explored

### 1. ClipboardManager Listener in Foreground Service (Rejected)

Register `addPrimaryClipChangedListener()` in `ClipRelayService` and launch a ghost activity to read the clipboard when the listener fires.

**Why it doesn't work:** The listener callback is never delivered to background apps. AOSP's `ClipboardService` checks `clipboardAccessAllowed()` before dispatching each listener callback. If the app doesn't have window focus, the callback is silently skipped. Confirmed by testing on Pixel 10 Pro XL (Android 16) and by reading the AOSP source.

The listener code is still in the codebase as a supplementary mechanism — it works when the app has a visible activity (e.g., split-screen).

### 2. Logcat Monitoring (KDE Connect's Approach, Not Used)

Monitor `logcat` for `ClipboardService` "Denying clipboard access" errors, which prove a copy happened, then launch a floating activity to read the clipboard.

**Why we didn't use it:** Requires `READ_LOGS` permission granted via ADB (`adb shell pm grant`). Most users won't do this. Also fragile — depends on Android's internal log format.

### 3. Accessibility Service (Chosen for Auto-Copy)

Use an `AccessibilityService` to detect copy actions by monitoring click events system-wide.

**Detection strategy:**
- **Tier 1:** Check if the clicked view's `AccessibilityNodeInfo` has `ACTION_COPY` in its action list. Language-independent, most reliable.
- **Tier 3 fallback:** Check the click event's text for "Copy" in 22+ languages. Needed because some apps (e.g., Chrome) don't provide a source node with the click event.

**Tradeoffs:**
- Requires user to enable Accessibility permission in Settings
- System shows "ClipRelay pasted from your clipboard" toast on every auto-copy (unavoidable OS behavior via `showAccessNotificationLocked()` — no workaround for third-party apps)
- May not detect all copy actions (custom copy buttons without ACTION_COPY or standard label)
- Play Store scrutiny for accessibility service usage

### 4. Polling via Ghost Activity (Explored, Rejected)

Periodically launch the ghost activity to read the clipboard and check for changes.

**Why it doesn't work:** The ghost activity steals window focus every time it launches. Doing this every second would constantly interrupt the user — dismiss keyboards, clear selections, etc.

## Architecture

### Ghost Activity (ClipboardGhostActivity)

A transparent, zero-UI activity that briefly gains foreground focus to read the clipboard on Android 10+. Used by both the accessibility service auto-copy path and the Quick Settings tile.

- Reads clipboard in `onWindowFocusChanged(hasFocus=true)` (not `onResume` — foreground focus is required, not just lifecycle state)
- Posts one extra frame via `window.decorView.post {}` before reading
- 2-second safety timeout ensures it always finishes
- Sends `ACTION_GHOST_FINISHED` on all exit paths to clear the in-flight flag
- Transparent theme, `taskAffinity=""`, `excludeFromRecents`, `noHistory`

### Auto-Copy Flow

```
User taps "Copy" in any app
    → AccessibilityService detects ACTION_COPY or "Copy" text
    → Sends ACTION_ACCESSIBILITY_COPY_DETECTED to ClipRelayService
    → Service checks guards (active session, 200ms debounce, ghostInFlight)
    → Launches ClipboardGhostActivity
    → Ghost gains focus → reads clipboard → ACTION_PUSH_TEXT
    → Service encrypts and sends via BLE → Mac
```

### Quick Settings Tile

`ClipboardTileService` — a "Send to Mac" tile in the notification shade. Uses `STATE_INACTIVE` (action button, not toggle). Launches `ClipboardSendActivity` — a visible variant of the ghost activity that shows a brief "Sending clipboard to [Mac name]" overlay animation.

### Direct Share Shortcut

Dynamic shortcut published via `ShortcutManagerCompat` when pairing completes. Shows the paired Mac's device name at the top of the Android share sheet. Points to the existing `ShareReceiverActivity`. Removed on unpair, republished on service restart.

### Echo Prevention

When the Mac sends clipboard to Android, the clipboard write triggers the listener/accessibility service. The echo is prevented by existing protocol-level hash dedup — the Mac rejects the OFFER because it already has that content hash.

## Permissions

| Permission | Purpose |
|------------|---------|
| `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` | Protect foreground service from OEM killing |
| `BIND_ACCESSIBILITY_SERVICE` | Auto-copy detection (optional, user-enabled) |

No `SYSTEM_ALERT_WINDOW` needed — the ghost activity is a regular activity.

## Known Limitations

- `addPrimaryClipChangedListener()` only fires when the app has window focus (since Android 10)
- Android 12+ shows "pasted from clipboard" system toast on every ghost activity clipboard read
- Accessibility-based copy detection may miss custom copy buttons
- Accessibility service must be re-enabled after app reinstall
