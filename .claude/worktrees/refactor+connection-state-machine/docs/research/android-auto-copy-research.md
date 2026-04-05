# Android Auto-Copy Research: KDE Connect vs ClipSync

## Problem Statement

Starting with Android 10 (API 29), apps cannot read the clipboard from the background. Only the app with foreground window focus can call `ClipboardManager.getPrimaryClip()`. This makes automatic clipboard syncing significantly harder — an app needs both a way to **detect** that a copy happened and a way to **read** the clipboard content despite not being in the foreground.

## Approach Comparison

| Aspect | KDE Connect | ClipSync |
|--------|-------------|----------|
| **Detection method** | `ClipboardManager.addPrimaryClipChangedListener()` | AccessibilityService heuristics |
| **Clipboard read workaround** | Transparent floating activity (SYSTEM_ALERT_WINDOW) | "Ghost Activity" (invisible activity) |
| **Accessibility permission** | Not used for clipboard | Required (core mechanism) |
| **Android 10+ fallback** | Logcat monitoring + manual triggers | Ghost activity launched by accessibility events |
| **User-facing complexity** | Low (works with defaults, ADB for power users) | Medium (requires enabling accessibility service) |

---

## KDE Connect: ClipboardManager Listener + Logcat + Floating Activity

### Detection

Uses the standard `ClipboardManager.addPrimaryClipChangedListener()` API registered from a singleton `ClipboardListener`. When the listener fires, it reads the clip, deduplicates, and notifies all paired-device plugin instances.

### Android 10+ Workaround (Multi-Layered)

**Layer 1 — Logcat monitoring (requires ADB-granted `READ_LOGS` permission):**
A background thread tails `logcat` filtered for `ClipboardService`. When Android's ClipboardService logs an error about KDE Connect trying to read the clipboard from the background, the watcher detects it and launches `ClipboardFloatingActivity`. The `READ_LOGS` permission must be granted via ADB:
```
adb shell pm grant org.kde.kdeconnect_tp android.permission.READ_LOGS
```

**Layer 2 — `ClipboardFloatingActivity` (transparent activity with SYSTEM_ALERT_WINDOW):**
An invisible, transparent activity that briefly pops to the foreground to gain window focus. Uses `FLAG_LAYOUT_NO_LIMITS`, `FLAG_NOT_TOUCH_MODAL`, `dimAmount = 0`. In `onWindowFocusChanged(true)`, it reads the clipboard then immediately `finish()`es. This is the actual mechanism that makes the read succeed on Android 10+.

**Layer 3 — Manual triggers:**
- A Quick Settings tile (`ClipboardTileService`) labeled "Send Clipboard" that launches the floating activity on tap.
- An in-app "Send Clipboard" button shown on Android 10+ that reads directly (works because the app has focus).

### Permissions

| Permission | Type | Required? |
|---|---|---|
| `SYSTEM_ALERT_WINDOW` | Special | Optional but needed for auto-sync on Android 10+ |
| `READ_LOGS` | Protected (ADB only) | Optional, enables logcat-based detection |

### Strengths
- No accessibility permission needed — lower user friction
- `ClipboardManager` listener is the official API and very reliable when the app has focus
- Graceful degradation: works great pre-Android 10, degrades to manual triggers if permissions aren't granted

### Weaknesses
- `READ_LOGS` requires ADB — most users won't set this up
- The logcat parsing is fragile — depends on Android's internal ClipboardService log format
- Without `READ_LOGS`, background clipboard sync on Android 10+ effectively requires manual action
- `SYSTEM_ALERT_WINDOW` can be revoked by the user and triggers Play Store scrutiny

---

## ClipSync: AccessibilityService + Ghost Activity

### Detection

Uses an `AccessibilityService` that monitors system-wide UI events with a four-tier heuristic strategy:

1. **ACTION_COPY action ID** — checks if a clicked view has `AccessibilityNodeInfo.ACTION_COPY` in its action list (language-independent, most reliable)
2. **Toast "Copied" detection** — listens for `TYPE_NOTIFICATION_STATE_CHANGED` and checks toast text against a 22-language word set for "copied"
3. **Click/Window text matching** — scans event text and contentDescription for copy-related words in multiple languages, with copyright filtering
4. **DFS node tree traversal** — walks the accessibility node tree (max depth 5) looking for nodes with `ACTION_COPY` or copy-related text

### Android 10+ Workaround

`ClipboardGhostActivity` — an invisible, zero-UI activity with a transparent theme and all animations disabled:
- Launched with `FLAG_ACTIVITY_NEW_TASK | FLAG_ACTIVITY_NO_ANIMATION | FLAG_ACTIVITY_SINGLE_TOP | FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS`
- Has `taskAffinity=""` so it runs in its own task stack
- Clipboard read is deferred to `onResume()` + one extra frame (`window.decorView.post {}`) to guarantee foreground focus
- 2-second safety timeout ensures it always finishes

When the AccessibilityService detects a copy, it launches the Ghost Activity, which reads the clipboard and sends the content upstream.

### Accessibility Service Config

```xml
<accessibility-service
    android:accessibilityEventTypes="typeViewTextSelectionChanged|typeViewClicked|
        typeNotificationStateChanged|typeWindowStateChanged|typeWindowContentChanged|typeViewFocused"
    android:accessibilityFeedbackType="feedbackGeneric"
    android:accessibilityFlags="flagIncludeNotImportantViews|flagRetrieveInteractiveWindows|flagReportViewIds"
    android:canRetrieveWindowContent="true"
    android:notificationTimeout="100" />
```

### Permissions

| Permission | Type | Required? |
|---|---|---|
| `BIND_ACCESSIBILITY_SERVICE` | System | Required (core detection) |
| `SYSTEM_ALERT_WINDOW` | Special | Required (ghost activity) |
| `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` | Special | Recommended (keep service alive) |

### Strengths
- Works reliably on Android 10+ without ADB — the AccessibilityService runs in-process and has elevated privileges
- No fragile logcat parsing
- Multi-language copy detection (22 languages)
- Game apps excluded to reduce noise

### Weaknesses
- Accessibility permission is a significant user friction point — requires navigating to system settings and manually enabling
- Google Play Store increasingly scrutinizes apps that use AccessibilityService, and may reject apps that use it for non-accessibility purposes
- Heuristic detection can have false positives/negatives depending on the app being used
- Higher battery/resource impact from monitoring all UI events system-wide
- Debouncing needed at multiple levels (1000ms between events, 700ms between ghost activity launches)

---

## Proposed Approach for ClipRelay: Foreground Service Listener + Ghost Activity

ClipRelay already runs a **BLE foreground service** to maintain the Bluetooth connection. This is a key advantage over KDE Connect's architecture — a foreground service keeps the process alive, which means `ClipboardManager.addPrimaryClipChangedListener()` should fire reliably even when the app is not visible.

The remaining Android 10+ problem is that the listener callback tells you the clipboard *changed* but you can't *read* the content without window focus. The solution is to combine the listener with a ghost activity:

1. Register `addPrimaryClipChangedListener()` in the existing BLE foreground service
2. When the listener fires, launch an invisible ghost activity (same pattern as ClipSync)
3. Ghost activity gets foreground focus → reads `getPrimaryClip()` → sends content over BLE → finishes immediately

### Why This Is Simpler Than Both Reference Implementations

- **vs KDE Connect**: No need for logcat parsing or the `READ_LOGS` ADB permission. The foreground service already keeps the listener alive, solving KDE Connect's main weakness.
- **vs ClipSync**: No AccessibilityService needed. The standard `ClipboardManager` listener is more reliable than heuristic UI event detection, has zero false positives, and doesn't require the user to enable accessibility in system settings.

### Permissions Required

| Permission | Type | Already have it? |
|---|---|---|
| `FOREGROUND_SERVICE` | Normal | Yes (BLE service) |
| None additional for detection | — | Listener is a standard API |

The ghost activity is a regular `Activity` with a transparent theme — no `SYSTEM_ALERT_WINDOW` needed.

### Risks

- **Ghost activity visibility**: On some devices or launchers, the brief activity launch might cause a subtle flicker or interfere with the current app. Needs testing across devices. ClipSync mitigates this with `FLAG_ACTIVITY_NO_ANIMATION`, a transparent theme, and `taskAffinity=""`.
- **Android future restrictions**: Google could further restrict clipboard access in future Android versions. The ghost activity trick works today but relies on the assumption that a focused activity can always read the clipboard.
- **OEM-specific process killing**: See the section below for details.

### Fallback: AccessibilityService as Optional Enhancement

If the foreground service listener proves unreliable on certain devices, an AccessibilityService can be added later as an opt-in "enhanced auto-copy" mode — similar to what ClipSync does. This would be gated behind a settings toggle with a clear explanation of why the permission is needed. The ghost activity component would be shared between both approaches.

---

## OEM Background Process Killing: Impact on ClipRelay

Data sourced primarily from [dontkillmyapp.com](https://dontkillmyapp.com/) and OEM developer documentation.

### OEM Severity Rankings

| Rank | OEM | Severity | Foreground Service Impact |
|------|-----|----------|--------------------------|
| #1 | Huawei | Worst | PowerGenie kills all non-whitelisted apps; no reliable developer-side workaround |
| #2 | Xiaomi | Very Bad | MIUI Security app runs a second layer of lifecycle management independent of Android |
| #3 | OnePlus | Very Bad | Settings reset on firmware updates; Deep Optimization kills aggressively |
| #4 | **Samsung** | Bad | ChimeraPolicyHandler can kill foreground services; improved in One UI 6.0 |
| #9 | Oppo | Bad | Kills background services when screen turns ocliff on some models |
| #10 | Vivo | Bad | Requires explicit autostart permissions |
| Best | **Google Pixel** | Minimal | Follows stock Android; no non-standard restrictions |

### Samsung Details

Samsung uses a three-tier app management system:

- **Sleeping Mode** (3 days unused): Restricts Jobs, Alarms, and foreground services
- **Deep Sleeping Mode** (16 days unused): App can only run when user opens it directly
- **Never Sleeping**: User must manually exempt the app

On Android 11+, Samsung's `ChimeraPolicyHandler` runs multiple times per hour in `system_server`, evaluating apps based on priority/memory scores, and has been observed killing foreground services despite visible notifications.

**One UI 6.0+ improvement (Android 14)**: Samsung partnered with Google and committed that foreground services of apps targeting Android 14 will be protected, *provided they use proper `foregroundServiceType` declarations*. ClipRelay already declares `foregroundServiceType="connectedDevice"`, which should benefit from this guarantee. However, the sleeping/deep-sleeping categorization still applies if the user doesn't open ClipRelay for 3+ days.

### Google Pixel

No non-standard restrictions. Standard Doze mode applies. Foreground services work as documented. No concerns for ClipRelay.

### Impact on the Clipboard Listener Approach

The foreground service process-killing issue affects both the BLE connection and the clipboard listener equally — if the OEM kills the foreground service, both stop working. This is **not a new risk introduced by auto-copy**; it's an existing concern for BLE connectivity.

However, there is one difference: BLE connections have OS-level connection management that can survive brief process restarts (the OS maintains the GATT connection). The clipboard listener has no such persistence — if the process is killed and restarted, the listener must be re-registered, and any clipboard changes during the downtime are lost.

### Recommended Mitigations

**Developer-side:**
- Target Android 14+ to benefit from Samsung's One UI 6.0 foreground service guarantee
- Use proper `foregroundServiceType="connectedDevice"` (already done)
- Request `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` — though Google Play policy restricts this to apps whose core function requires it (ClipRelay likely qualifies)

**User-side (guide in-app on affected devices):**
- **Samsung**: Add ClipRelay to "Never sleeping apps" list (Settings > Battery > Background usage limits)
- **Xiaomi**: Enable Autostart in Security app; set battery saver to "No restrictions"; lock app in Recent Apps
- **Huawei**: Set App Launch to "Manage manually"
- **OnePlus**: Disable Deep Optimization; lock app in Recent Apps

Consider detecting the OEM at runtime and showing device-specific guidance if the foreground service is being killed. The site [dontkillmyapp.com](https://dontkillmyapp.com/) provides per-OEM instructions that could be linked or adapted.

### Sources

- [dontkillmyapp.com](https://dontkillmyapp.com/) — OEM rankings and per-device workarounds
- [Samsung Developer - App Management](https://developer.samsung.com/mobile/app-management.html) — official Samsung three-tier model docs
- [Samsung One UI 6.0 foreground service guarantee](https://www.sammobile.com/news/samsung-android-14-one-ui-6-0-update-kill-background-apps-less-frequently/)
- [Google Issue Tracker #179644471](https://issuetracker.google.com/issues/179644471) — OEM battery optimization problems

### Key Implementation Details

1. **Ghost Activity**: Transparent theme, `FLAG_ACTIVITY_NEW_TASK | FLAG_ACTIVITY_NO_ANIMATION | FLAG_ACTIVITY_SINGLE_TOP | FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS`, `taskAffinity=""`, read clipboard in `onResume()` after one extra frame post, 2-second safety timeout
2. **Debouncing**: 500-1000ms between ghost activity launches to avoid rapid-fire launches from clipboard manager events
3. **Echo prevention**: Extend ClipRelay's existing hash-based dedup to skip clipboard changes that originated from the remote Mac
4. **User toggle**: Make auto-copy opt-in in settings since users may not want every copy sent to the Mac
