# Android Dark Theme Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Transform the Android app from a light theme to a dark theme matching the website's visual language — dark surfaces, aqua accents, dot grid, glows, gradient text.

**Architecture:** Pure color/visual change across existing Compose components. No structural changes. All colors currently hardcoded in Compose and XML resources — update in-place. The website's design tokens (`#111820` bg, `#182028` surface, `#243038` border, `#E8E8ED` text, `#6B6B7B` dim text, `#00FFD5` aqua accent) map directly to the existing color constants.

**Tech Stack:** Kotlin, Jetpack Compose, Material 3, Android XML resources

---

### Task 1: Expand color tokens in Colors.kt

**Files:**
- Modify: `android/app/src/main/java/org/cliprelay/ui/Colors.kt`

**Step 1: Add dark theme color tokens**

Replace entire file contents with:

```kotlin
package org.cliprelay.ui

// Brand color tokens for the Compose theme.

import androidx.compose.ui.graphics.Color

// ─── Brand tokens ────────────────────────────────────────────────────────────
internal val Aqua = Color(0xFF00FFD5)
internal val Teal = Color(0xFF00796B)

// ─── Dark surface tokens (matching website) ──────────────────────────────────
internal val DarkBg = Color(0xFF111820)
internal val DarkSurface = Color(0xFF182028)
internal val DarkBorder = Color(0xFF243038)
internal val TextPrimary = Color(0xFFE8E8ED)
internal val TextDim = Color(0xFF6B6B7B)
```

**Step 2: Commit**

```bash
git add android/app/src/main/java/org/cliprelay/ui/Colors.kt
git commit -m "feat(android): add dark theme color tokens from website palette"
```

---

### Task 2: Update XML resources — colors.xml and themes.xml

**Files:**
- Modify: `android/app/src/main/res/values/colors.xml`
- Modify: `android/app/src/main/res/values/themes.xml`
- Modify: `android/app/src/main/res/values-v31/themes.xml`

**Step 1: Update colors.xml**

Replace background/UI colors with dark equivalents:

```xml
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="ic_launcher_background">#00FFD5</color>

    <!-- Brand tokens -->
    <color name="aqua">#00FFD5</color>
    <color name="teal">#00796B</color>

    <!-- Dark backgrounds -->
    <color name="dark_bg">#111820</color>
    <color name="dark_surface">#182028</color>

    <!-- UI -->
    <color name="toast_bg">#243038</color>
</resources>
```

**Step 2: Update themes.xml (base)**

```xml
<resources>
    <style name="Theme.ClipRelay" parent="Theme.Material3.Light.NoActionBar">
        <item name="android:windowBackground">@color/dark_bg</item>
        <item name="android:statusBarColor">@color/dark_bg</item>
        <item name="android:navigationBarColor">@color/dark_bg</item>
        <item name="android:windowLightStatusBar">false</item>
        <item name="android:windowLightNavigationBar">false</item>
    </style>
</resources>
```

**Step 3: Update themes.xml (API 31+)**

```xml
<resources>
    <style name="Theme.ClipRelay" parent="Theme.Material3.Light.NoActionBar">
        <item name="android:windowBackground">@color/dark_bg</item>
        <item name="android:statusBarColor">@color/dark_bg</item>
        <item name="android:navigationBarColor">@color/dark_bg</item>
        <item name="android:windowLightStatusBar">false</item>
        <item name="android:windowLightNavigationBar">false</item>
        <!-- Splash screen (API 31+) -->
        <item name="android:windowSplashScreenBackground">@color/dark_bg</item>
        <item name="android:windowSplashScreenAnimatedIcon">@mipmap/ic_launcher</item>
        <item name="android:windowSplashScreenIconBackgroundColor">@color/ic_launcher_background</item>
    </style>
</resources>
```

**Step 4: Commit**

```bash
git add android/app/src/main/res/values/colors.xml \
        android/app/src/main/res/values/themes.xml \
        android/app/src/main/res/values-v31/themes.xml
git commit -m "feat(android): switch XML resources to dark theme"
```

---

### Task 3: Dark background, dot grid, and aurora glow

**Files:**
- Modify: `android/app/src/main/java/org/cliprelay/ui/ClipRelayScreen.kt` (lines 72-145)

**Step 1: Replace background color constants (lines 72-76)**

Replace the four `BgTop/BgBottom` constants with dark equivalents:

```kotlin
// ─── UI-specific background colors ───────────────────────────────────────────
private val BgTopUnpaired = DarkBg
private val BgTopConnected = Color(0xFF131E28)
private val BgBottomUnpaired = DarkBg
private val BgBottomConnected = Color(0xFF111E22)
```

**Step 2: Update background gradient mid-stop (line 111)**

Change the mid-gradient color from light gray to dark:

```kotlin
0.60f to Color(0xFF121A22),
```

(was `0.60f to Color(0xFFF5F5F5)`)

**Step 3: Update dot grid colors (line 120)**

Change dots from dark-on-light to aqua-on-dark:

```kotlin
val dotColor = if (isConnected) Color(0x1F00FFD5) else Color(0x1400FFD5)
```

(was dark/black tinted dots)

**Step 4: Boost aurora glow for dark background (lines 131-134)**

The existing glow values are tuned for light backgrounds. Increase alpha for dark:

```kotlin
val auroraColors = if (isConnected) {
    listOf(Color(0x3300FFD5), Color(0x1A00FFD5), Color(0x0A00FFD5), Color.Transparent)
} else {
    listOf(Color(0x2000FFD5), Color(0x1000FFD5), Color(0x0500FFD5), Color.Transparent)
}
```

**Step 5: Commit**

```bash
git add android/app/src/main/java/org/cliprelay/ui/ClipRelayScreen.kt
git commit -m "feat(android): dark background with aqua dot grid and aurora glow"
```

---

### Task 4: Dark StatusChip

**Files:**
- Modify: `android/app/src/main/java/org/cliprelay/ui/ClipRelayScreen.kt` (lines 182-202)

**Step 1: Update chip color styles**

Replace the three `ChipStyle` blocks (lines 184-201):

```kotlin
is AppState.Unpaired -> ChipStyle(
    bg = DarkSurface,
    dot = TextDim,
    text = TextDim,
    label = "Not paired"
)
is AppState.Searching -> ChipStyle(
    bg = Color(0x1A00FFD5),
    dot = Aqua,
    text = TextPrimary,
    label = "Searching for Mac"
)
is AppState.Connected -> ChipStyle(
    bg = Color(0x2000FFD5),
    dot = Aqua,
    text = Aqua,
    label = "Connected"
)
```

**Step 2: Commit**

```bash
git add android/app/src/main/java/org/cliprelay/ui/ClipRelayScreen.kt
git commit -m "feat(android): dark status chip styling"
```

---

### Task 5: Dark MainCard — surface, border, title, subtitle

**Files:**
- Modify: `android/app/src/main/java/org/cliprelay/ui/ClipRelayScreen.kt` (lines 274-355)

**Step 1: Update card gradient colors (lines 274-282)**

```kotlin
val cardTopColor by animateColorAsState(
    targetValue = when (state) {
        is AppState.Unpaired -> DarkSurface
        is AppState.Searching -> Color(0xFF1A2530)
        is AppState.Connected -> Color(0xFF1C2832)
    },
    animationSpec = tween(600),
    label = "cardTop"
)
```

**Step 2: Update card border colors (lines 284-292)**

```kotlin
val borderColor by animateColorAsState(
    targetValue = when (state) {
        is AppState.Unpaired -> DarkBorder
        is AppState.Searching -> Color(0x3300FFD5)
        is AppState.Connected -> Color(0x5500FFD5)
    },
    animationSpec = tween(600),
    label = "cardBorder"
)
```

**Step 3: Update card shadow and background (lines 309-315)**

Change spot color and background gradient:

The shadow spotColor for non-connected: `Color(0x1A000000)` → `Color(0x40000000)`

The background gradient: `listOf(cardTopColor, Color.White)` → `listOf(cardTopColor, DarkSurface)`

**Step 4: Update title text (line 344)**

Change `color = Teal` to `color = TextPrimary` and add a gradient brush for the title. Replace the title Text composable:

```kotlin
Text(
    text = "ClipRelay",
    fontSize = 34.sp,
    fontWeight = FontWeight.Bold,
    style = androidx.compose.ui.text.TextStyle(
        brush = Brush.linearGradient(
            colors = listOf(Color.White, Aqua),
            start = Offset(0f, 0f),
            end = Offset(400f, 400f)
        )
    ),
    modifier = Modifier.fillMaxWidth(),
    textAlign = TextAlign.Center
)
```

Note: This requires adding `import androidx.compose.ui.text.TextStyle` to the imports at the top.

**Step 5: Update subtitle text (lines 349-355)**

Change colors to dark-appropriate:

```kotlin
Text(
    text = "Seamless clipboard sharing with your Mac",
    fontSize = 15.sp,
    color = if (isPaired) Aqua.copy(alpha = 0.45f) else TextDim,
    modifier = Modifier.fillMaxWidth(),
    textAlign = TextAlign.Center
)
```

**Step 6: Update divider color (line 359)**

```kotlin
color = if (isPaired) Color(0x2000FFD5) else Color(0x1500FFD5),
```

**Step 7: Update lock watermark text colors (lines 420-432)**

Change `Teal.copy(alpha = 0.4f)` to `Aqua.copy(alpha = 0.3f)` and `Teal.copy(alpha = 0.45f)` to `TextDim`.

**Step 8: Commit**

```bash
git add android/app/src/main/java/org/cliprelay/ui/ClipRelayScreen.kt
git commit -m "feat(android): dark main card with gradient title and aqua accents"
```

---

### Task 6: Dark buttons and auto-clear toggle

**Files:**
- Modify: `android/app/src/main/java/org/cliprelay/ui/ClipRelayScreen.kt` (lines 469-580)

**Step 1: Update "Pair with Mac" button (lines 474-476)**

Change content color from Teal to DarkBg (dark text on aqua button):

```kotlin
colors = ButtonDefaults.buttonColors(
    containerColor = Aqua,
    contentColor = DarkBg
)
```

**Step 2: Update "Unpair" button colors (lines 487-506)**

Update background and border to dark-appropriate:

```kotlin
val unpairBg by animateColorAsState(
    targetValue = if (isConnected) Color(0x1A00FFD5) else Color(0x0D00FFD5),
    animationSpec = tween(400),
    label = "unpairBg"
)
val unpairBorder by animateColorAsState(
    targetValue = if (isConnected) Color(0x3300FFD5) else Color(0x2000FFD5),
    animationSpec = tween(400),
    label = "unpairBorder"
)
```

And the button `contentColor`:

```kotlin
contentColor = Aqua
```

(was `Teal`)

**Step 3: Update AutoClearSettingRow (lines 532-578)**

Update toggle background and border colors:

```kotlin
val toggleBg = if (enabled) Color(0x1A00FFD5) else Color(0x0DFFFFFF)
val toggleBorder = if (enabled) Color(0x3300FFD5) else Color(0x14FFFFFF)
```

Update text colors (line 555 and 561):

```kotlin
color = TextPrimary  // was Color(0xCC000000) — setting title
...
color = TextDim      // was Color(0x80000000) — setting subtitle
```

Update switch colors (lines 571-578):

```kotlin
colors = SwitchDefaults.colors(
    checkedThumbColor = Aqua,
    checkedTrackColor = Aqua.copy(alpha = 0.30f),
    checkedBorderColor = Aqua.copy(alpha = 0.50f),
    uncheckedThumbColor = TextDim,
    uncheckedTrackColor = Color(0x15FFFFFF),
    uncheckedBorderColor = Color(0x30FFFFFF)
)
```

**Step 4: Commit**

```bash
git add android/app/src/main/java/org/cliprelay/ui/ClipRelayScreen.kt
git commit -m "feat(android): dark buttons and auto-clear toggle"
```

---

### Task 7: Dark device nodes

**Files:**
- Modify: `android/app/src/main/java/org/cliprelay/ui/ClipRelayScreen.kt` (lines 595-641)

**Step 1: Update device node colors (lines 595-610)**

```kotlin
val iconBg by animateColorAsState(
    targetValue = if (isActive) Color(0x1A00FFD5) else DarkSurface,
    animationSpec = tween(400),
    label = "iconBg"
)
val iconTint by animateColorAsState(
    targetValue = if (isActive) Aqua else TextDim,
    animationSpec = tween(400),
    label = "iconTint"
)
val borderAlpha by animateColorAsState(
    targetValue = if (isActive) Color(0x3300FFD5) else DarkBorder,
    animationSpec = tween(400),
    label = "borderAlpha"
)
val labelColor = if (isActive) TextPrimary else TextDim
```

**Step 2: Update phone/mac icon screen cutout colors (lines 662-670, 692-696)**

Change `Color.White.copy(alpha = 0.25f)` to a darker cutout that works on the new tint:

In `drawPhoneIcon`: screen cutout → `Color(0xFF111820).copy(alpha = 0.35f)`, home button → `Color(0xFF111820).copy(alpha = 0.40f)`

In `drawMacIcon`: screen glass → `Color(0xFF111820).copy(alpha = 0.35f)`

**Step 3: Commit**

```bash
git add android/app/src/main/java/org/cliprelay/ui/ClipRelayScreen.kt
git commit -m "feat(android): dark device node styling"
```

---

### Task 8: Dark footer section

**Files:**
- Modify: `android/app/src/main/java/org/cliprelay/ui/ClipRelayScreen.kt` (lines 786-834)

**Step 1: Update footer text colors**

- Line 795: `color = Teal` → `color = Aqua` (the highlighted "Share" text)
- Line 797: `background = Aqua.copy(alpha = 0.12f)` → `background = Aqua.copy(alpha = 0.15f)`
- Line 804: `color = Color(0x80000000)` → `color = TextDim`
- Line 830: `color = Color(0x99000000)` → `color = TextDim`

**Step 2: Commit**

```bash
git add android/app/src/main/java/org/cliprelay/ui/ClipRelayScreen.kt
git commit -m "feat(android): dark footer section"
```

---

### Task 9: Dark BeamCanvas

**Files:**
- Modify: `android/app/src/main/java/org/cliprelay/ui/BeamCanvas.kt`

**Step 1: Update UnpairedBeam (line 46)**

Change the dashed line from dark to light for visibility on dark background:

```kotlin
color = Color(0x40FFFFFF),
```

(was `Color(0x33000000)`)

**Step 2: Update SearchingBeam packet color (line 125)**

Change `darkGreen.copy(alpha = alpha)` to `Aqua.copy(alpha = alpha)` for the packets, since teal is too dark on the dark background. The `darkGreen` variable (line 92) should be changed to `Aqua`:

Line 92: `val darkGreen = Teal` → `val darkGreen = Aqua`

**Step 3: Update ConnectedBeam packet color (lines 230, 245)**

Same change — the `darkGreen` variable at line 193: `val darkGreen = Teal` → `val darkGreen = Aqua`

And the clipboard icon (lines 264, 272): change `Teal.copy(alpha = iconAlpha)` → `Aqua.copy(alpha = iconAlpha)`

**Step 4: Commit**

```bash
git add android/app/src/main/java/org/cliprelay/ui/BeamCanvas.kt
git commit -m "feat(android): dark beam canvas colors"
```

---

### Task 10: Dark PairingBurst

**Files:**
- Modify: `android/app/src/main/java/org/cliprelay/ui/PairingBurst.kt`

**Step 1: Update flash overlay (line 92)**

The flash color is fine (aqua overlay), but the white background burst overlay should be darkened. The flash stays aqua. The only change needed:

- Line 121: Checkmark circle background `Color.White` → `DarkSurface` (dark circle with aqua check)
- Line 127: Checkmark icon tint `Teal` → `Aqua`

This requires adding the import: `import org.cliprelay.ui.DarkSurface` (but since it's in the same package, just use `DarkSurface` directly).

**Step 2: Commit**

```bash
git add android/app/src/main/java/org/cliprelay/ui/PairingBurst.kt
git commit -m "feat(android): dark pairing burst colors"
```

---

### Task 11: Build, install, and verify

**Step 1: Run the build**

```bash
scripts/build-all.sh
```

**Step 2: Run the test suite**

```bash
scripts/test-all.sh
```

**Step 3: Install on device (if connected) and take screenshot**

```bash
adb install -r dist/cliprelay-debug.apk
adb shell am force-stop org.cliprelay
adb shell am start -n org.cliprelay/.ui.MainActivity
sleep 3
adb exec-out screencap -p > /tmp/cliprelay-dark-theme.png
```

**Step 4: Review screenshot and fix any visual issues**

Visually inspect the dark theme for readability, contrast, and aesthetic match to the website.

**Step 5: Final commit if any fixups were needed**
