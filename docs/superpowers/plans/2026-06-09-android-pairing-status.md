# Android Pairing Status & Progress Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show truthful pairing progress on Android after the QR scan ("Connecting to your Mac…" → "Exchanging keys…"), with a 20 s service-owned timeout that surfaces an actionable error card with retry.

**Architecture:** `ClipRelayService` owns the pairing lifecycle: it broadcasts a new `ACTION_PAIRING_STATUS` (stages `CONNECTING` / `EXCHANGING_KEYS` / `FAILED`) and enforces a 20 s deadline that cleans up BLE/pending keys on failure. `MainViewModel` gains an `AppState.Pairing(stage)` state plus a `pairingFailed` flag; `ClipRelayScreen` renders the new state as a spinner status row with Cancel, and a failure card with Try again.

**Tech Stack:** Kotlin, Jetpack Compose, Android Service + broadcasts, JUnit 4 (JVM unit tests).

**Spec:** `docs/superpowers/specs/2026-06-09-android-pairing-status-design.md`

**Branch:** `fix/56-remove-play-services-qr` (continues PR #73)

**Build env note:** `JAVA_HOME` must be set: `export JAVA_HOME="/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home"`

**Codebase idiom note:** `ClipRelayScreen.kt` hardcodes user-facing strings in composables (e.g. `"Searching for Mac"`, `"Pair with Mac"`). Follow that idiom for the new Compose strings rather than adding `strings.xml` entries.

---

### Task 1: ViewModel pairing states (TDD)

**Files:**
- Modify: `android/app/src/main/java/org/cliprelay/ui/MainViewModel.kt`
- Create: `android/app/src/test/java/org/cliprelay/ui/MainViewModelTest.kt`

- [ ] **Step 1: Write the failing tests**

Create `android/app/src/test/java/org/cliprelay/ui/MainViewModelTest.kt`:

```kotlin
package org.cliprelay.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MainViewModelTest {

    @Test
    fun pairingStarted_entersConnectingState_andClearsFailedFlag() {
        val vm = MainViewModel()
        vm.onPairingFailed() // not in Pairing state, so flag must stay false
        vm.onPairingStarted()
        assertEquals(AppState.Pairing(PairingStage.Connecting), vm.state.value)
        assertFalse(vm.pairingFailed.value)
    }

    @Test
    fun pairingStatus_exchangingKeys_advancesStage() {
        val vm = MainViewModel()
        vm.onPairingStarted()
        vm.onPairingStatus(PairingStage.ExchangingKeys)
        assertEquals(AppState.Pairing(PairingStage.ExchangingKeys), vm.state.value)
    }

    @Test
    fun pairingStatus_ignoredWhenNotPairing() {
        val vm = MainViewModel()
        vm.initState(isPaired = true, deviceName = "Mac")
        vm.onPairingStatus(PairingStage.ExchangingKeys)
        assertTrue(vm.state.value is AppState.Searching)
    }

    @Test
    fun pairingFailed_whilePairing_revertsToUnpairedAndSetsFlag() {
        val vm = MainViewModel()
        vm.onPairingStarted()
        vm.onPairingFailed()
        assertEquals(AppState.Unpaired, vm.state.value)
        assertTrue(vm.pairingFailed.value)
    }

    @Test
    fun pairingFailed_afterPairingComplete_isIgnored() {
        val vm = MainViewModel()
        vm.onPairingStarted()
        vm.onPaired(deviceTag = "AB12 CD34")
        vm.onPairingFailed()
        assertTrue(vm.state.value is AppState.Searching)
        assertFalse(vm.pairingFailed.value)
    }

    @Test
    fun pairingCancelled_revertsToUnpairedWithoutFailedFlag() {
        val vm = MainViewModel()
        vm.onPairingStarted()
        vm.onPairingCancelled()
        assertEquals(AppState.Unpaired, vm.state.value)
        assertFalse(vm.pairingFailed.value)
    }

    @Test
    fun pairingFailedDismissed_clearsFlag() {
        val vm = MainViewModel()
        vm.onPairingStarted()
        vm.onPairingFailed()
        vm.onPairingFailedDismissed()
        assertFalse(vm.pairingFailed.value)
    }

    @Test
    fun disconnectedBroadcast_doesNotKickOutOfPairingState() {
        val vm = MainViewModel()
        vm.onPairingStarted()
        // Service answers ACTION_QUERY_CONNECTION with connected=false on resume
        vm.onConnectionChanged(connected = false, deviceName = null)
        assertEquals(AppState.Pairing(PairingStage.Connecting), vm.state.value)
    }

    @Test
    fun pairedThenConnected_reachesConnectedState() {
        val vm = MainViewModel()
        vm.onPairingStarted()
        vm.onPaired(deviceTag = "AB12 CD34")
        vm.onConnectionChanged(connected = true, deviceName = "Mac")
        assertTrue(vm.state.value is AppState.Connected)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd android && ./gradlew testDebugUnitTest --tests 'org.cliprelay.ui.MainViewModelTest' 2>&1 | tail -20`
Expected: FAIL — compile errors (`PairingStage`, `AppState.Pairing`, `onPairingStarted`, etc. unresolved).

- [ ] **Step 3: Implement ViewModel changes**

In `android/app/src/main/java/org/cliprelay/ui/MainViewModel.kt`:

Replace the `AppState` sealed class (lines 12–16) with:

```kotlin
enum class PairingStage { Connecting, ExchangingKeys }

sealed class AppState {
    object Unpaired : AppState()
    data class Pairing(val stage: PairingStage) : AppState()
    data class Searching(val deviceName: String? = null, val deviceTag: String? = null) : AppState()
    data class Connected(val deviceName: String?, val deviceTag: String? = null) : AppState()
}
```

Add after the `_showVersionMismatch` declarations (around line 38):

```kotlin
    private val _pairingFailed = MutableStateFlow(false)
    val pairingFailed: StateFlow<Boolean> = _pairingFailed.asStateFlow()
```

Replace `onPaired` (lines 51–54) with:

```kotlin
    fun onPaired(deviceTag: String? = null) {
        _state.value = AppState.Searching(deviceTag = deviceTag)
        _pairingFailed.value = false
        _showBurst.value = true
    }

    fun onPairingStarted() {
        _state.value = AppState.Pairing(PairingStage.Connecting)
        _pairingFailed.value = false
    }

    fun onPairingStatus(stage: PairingStage) {
        if (_state.value !is AppState.Pairing) return
        _state.value = AppState.Pairing(stage)
    }

    fun onPairingFailed() {
        if (_state.value !is AppState.Pairing) return
        _state.value = AppState.Unpaired
        _pairingFailed.value = true
    }

    fun onPairingCancelled() {
        _state.value = AppState.Unpaired
        _pairingFailed.value = false
    }

    fun onPairingFailedDismissed() {
        _pairingFailed.value = false
    }
```

In `onConnectionChanged` (line 65), replace the guard line:

```kotlin
    fun onConnectionChanged(connected: Boolean, deviceName: String?) {
        // Don't let stale connection broadcasts override the Unpaired state,
        // and don't let "disconnected" answers kick us out of an in-progress pairing.
        if (_state.value is AppState.Unpaired) return
        if (_state.value is AppState.Pairing && !connected) return
        val currentTag = when (val s = _state.value) {
            is AppState.Searching -> s.deviceTag
            is AppState.Connected -> s.deviceTag
            else -> null
        }
        _state.value = if (connected) AppState.Connected(deviceName, currentTag) else AppState.Searching(deviceName, currentTag)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd android && ./gradlew testDebugUnitTest --tests 'org.cliprelay.ui.MainViewModelTest' 2>&1 | tail -5`
Expected: BUILD SUCCESSFUL. (Note: `ClipRelayScreen.kt` will not compile yet — that's Task 3. If the main source set fails to compile here, proceed to Task 3 and run the tests at the end of Task 3 instead; commit Tasks 1–3 together in that case.)

- [ ] **Step 5: Commit (if compile succeeds standalone)**

```bash
git add android/app/src/main/java/org/cliprelay/ui/MainViewModel.kt android/app/src/test/java/org/cliprelay/ui/MainViewModelTest.kt
git commit -m "feat(android): add pairing progress states to MainViewModel"
```

---

### Task 2: Service pairing lifecycle (status broadcasts, timeout, cancel)

**Files:**
- Modify: `android/app/src/main/java/org/cliprelay/service/ClipRelayService.kt`

No JVM test harness exists for the service (it's exercised by hardware smoke tests); verification is compile + on-device in Task 5.

- [ ] **Step 1: Add constants**

In the `companion object` after `ACTION_PAIRING_COMPLETE` (line 53):

```kotlin
        const val ACTION_PAIRING_STATUS = "org.cliprelay.action.PAIRING_STATUS"
        const val ACTION_CANCEL_PAIRING = "org.cliprelay.action.CANCEL_PAIRING"
        const val EXTRA_PAIRING_STAGE = "extra_pairing_stage"
        const val PAIRING_STAGE_CONNECTING = "CONNECTING"
        const val PAIRING_STAGE_EXCHANGING_KEYS = "EXCHANGING_KEYS"
        const val PAIRING_STAGE_FAILED = "FAILED"
```

And in the private constants (near `CLIPBOARD_DEBOUNCE_MS`, line 75):

```kotlin
        private const val PAIRING_TIMEOUT_MS = 20_000L
```

- [ ] **Step 2: Add timeout handler fields**

Near the existing `pendingMacPublicKeyRaw` field (line 111):

```kotlin
    private val pairingTimeoutHandler = Handler(Looper.getMainLooper())
    private var pairingTimeoutRunnable: Runnable? = null
```

- [ ] **Step 3: Add status-broadcast and cancel helpers**

In the `// ── Pairing ──` section, after `handleStartPairing()` (line 655):

```kotlin
    private fun sendPairingStatus(stage: String) {
        val intent = Intent(ACTION_PAIRING_STATUS)
        intent.setPackage(packageName)
        intent.putExtra(EXTRA_PAIRING_STAGE, stage)
        sendBroadcast(intent)
    }

    private fun clearPairingTimeout() {
        pairingTimeoutRunnable?.let { pairingTimeoutHandler.removeCallbacks(it) }
        pairingTimeoutRunnable = null
    }

    /// Aborts an in-progress pairing: stops advertising, clears pending keys/prefs.
    /// broadcastFailed=true for timeouts/errors (UI shows the error card);
    /// false for user-initiated cancel (UI already knows).
    private fun cancelPairing(broadcastFailed: Boolean) {
        clearPairingTimeout()
        if (!pairingInProgress) return
        Log.w(TAG, "Pairing cancelled (broadcastFailed=$broadcastFailed)")
        pairingInProgress = false
        pendingPairingKeyPair = null
        pendingMacPublicKeyRaw = null
        getSharedPreferences(PREFS_NAME, MODE_PRIVATE).edit()
            .remove("pending_pairing_pubkey")
            .apply()
        if (broadcastFailed) {
            // Broadcast FAILED before tearing down BLE so the ViewModel is already
            // in Unpaired state when the disconnected broadcast arrives.
            sendPairingStatus(PAIRING_STAGE_FAILED)
        }
        stopBleComponents(broadcastDisconnected = false)
    }
```

- [ ] **Step 4: Extend `handleStartPairing()`**

Replace the existing `handleStartPairing()` (lines 635–655) with:

```kotlin
    private fun handleStartPairing() {
        val prefs = getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
        val macPubKeyHex = prefs.getString("pending_pairing_pubkey", null) ?: return
        val macPubKeyRaw = E2ECrypto.hexToBytes(macPubKeyHex)

        // Replace any pairing already in flight (e.g. user re-scanned).
        clearPairingTimeout()

        // Generate ephemeral X25519 key pair
        val keyPair = E2ECrypto.generateX25519KeyPair()

        // Store pairing state for session creation
        pendingPairingKeyPair = keyPair
        pendingMacPublicKeyRaw = macPubKeyRaw
        pairingInProgress = true

        Log.w(TAG, "Started pairing mode with pairing tag")

        // Restart BLE components with pairing tag
        if (bleStarted) {
            stopBleComponents(broadcastDisconnected = false)
        }
        ensureBleComponentsState()

        if (!bleStarted) {
            // BLE startup failed (e.g. Bluetooth off) — fail fast instead of
            // letting the user stare at "Connecting…" for the full timeout.
            cancelPairing(broadcastFailed = true)
            return
        }

        sendPairingStatus(PAIRING_STAGE_CONNECTING)
        pairingTimeoutRunnable = Runnable {
            if (pairingInProgress) {
                Log.w(TAG, "Pairing timed out after ${PAIRING_TIMEOUT_MS}ms")
                cancelPairing(broadcastFailed = true)
            }
        }.also { pairingTimeoutHandler.postDelayed(it, PAIRING_TIMEOUT_MS) }
    }
```

- [ ] **Step 5: Wire the remaining lifecycle points**

a) In `onStartCommand`'s `when` (after the `ACTION_START_PAIRING` branch, line 182):

```kotlin
            ACTION_CANCEL_PAIRING -> {
                cancelPairing(broadcastFailed = false)
                return START_STICKY
            }
```

b) In `onClientConnected` (line 368), right after the `Log.w(TAG, "L2CAP client connected")` line:

```kotlin
        if (pairingInProgress) {
            sendPairingStatus(PAIRING_STAGE_EXCHANGING_KEYS)
        }
```

c) In `onPairingComplete` (line 492), right after the `Log.w(TAG, "ECDH pairing complete, storing shared secret")` line:

```kotlin
        clearPairingTimeout()
```

d) In `handleUnpairRequest` (line 659), as the first line of the function body:

```kotlin
        cancelPairing(broadcastFailed = false)
```

e) In `onDestroy` (line 162), after `clipboardAutoClearHandler.removeCallbacksAndMessages(null)`:

```kotlin
        clearPairingTimeout()
```

- [ ] **Step 6: Verify it compiles**

Run: `cd android && ./gradlew compileDebugKotlin 2>&1 | tail -5`
Expected: BUILD SUCCESSFUL (Task 1's `ClipRelayScreen` breakage is fixed in Task 3 — if this fails on `ClipRelayScreen.kt` only, that's expected; service file itself must show no errors).

- [ ] **Step 7: Commit (or fold into the Task 3 commit if compile is blocked by the UI file)**

```bash
git add android/app/src/main/java/org/cliprelay/service/ClipRelayService.kt
git commit -m "feat(android): service-owned pairing lifecycle with status broadcasts and 20s timeout"
```

---

### Task 3: MainActivity wiring

**Files:**
- Modify: `android/app/src/main/java/org/cliprelay/ui/MainActivity.kt`

- [ ] **Step 1: Handle the new broadcast**

In `connectionReceiver`'s `when` (after the `ACTION_PAIRING_COMPLETE` branch, line 51):

```kotlin
                ClipRelayService.ACTION_PAIRING_STATUS -> {
                    when (intent.getStringExtra(ClipRelayService.EXTRA_PAIRING_STAGE)) {
                        ClipRelayService.PAIRING_STAGE_CONNECTING ->
                            viewModel.onPairingStatus(PairingStage.Connecting)
                        ClipRelayService.PAIRING_STAGE_EXCHANGING_KEYS ->
                            viewModel.onPairingStatus(PairingStage.ExchangingKeys)
                        ClipRelayService.PAIRING_STAGE_FAILED ->
                            viewModel.onPairingFailed()
                    }
                }
```

- [ ] **Step 2: Register the action in the resume filter**

In `onResume` (line 209), add to the `IntentFilter` builder block:

```kotlin
            it.addAction(ClipRelayService.ACTION_PAIRING_STATUS)
```

- [ ] **Step 3: Optimistic state on scanner result**

Replace the `scannerLauncher` callback body (lines 76–84) with:

```kotlin
    private val scannerLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result ->
        if (result.resultCode == RESULT_OK) {
            // The service broadcasts pairing progress (CONNECTING → EXCHANGING_KEYS →
            // PAIRING_COMPLETE/FAILED); set Connecting optimistically since the
            // CONNECTING broadcast may fire before this activity resumes.
            viewModel.onPairingStarted()
        }
    }
```

- [ ] **Step 4: Pass new state/callbacks into the screen**

In `setContent`, add after the `showVersionMismatch` collection (line 130):

```kotlin
            val pairingFailed by viewModel.pairingFailed.collectAsState()
```

In the `ClipRelayScreen(...)` call, add these parameters (after `imageSyncEnabled = imageSyncEnabled,`):

```kotlin
                pairingFailed = pairingFailed,
                onPairingCancelClick = {
                    viewModel.onPairingCancelled()
                    val cancelIntent = Intent(this, ClipRelayService::class.java)
                    cancelIntent.action = ClipRelayService.ACTION_CANCEL_PAIRING
                    startServiceSafely(cancelIntent)
                },
                onPairingErrorDismiss = {
                    viewModel.onPairingFailedDismissed()
                },
```

(`onPairClick` already exists and doubles as "Try again" — the error card calls it after dismissing.)

- [ ] **Step 5: Compile check**

Run: `cd android && ./gradlew compileDebugKotlin 2>&1 | tail -5`
Expected: fails only in `ClipRelayScreen.kt` (missing params / non-exhaustive `when`) — fixed next task.

---

### Task 4: ClipRelayScreen UI (chip, card, status row, error card)

**Files:**
- Modify: `android/app/src/main/java/org/cliprelay/ui/ClipRelayScreen.kt`

- [ ] **Step 1: New parameters on the root composable**

In `ClipRelayScreen(...)` (line 83), add parameters after `imageSyncEnabled`:

```kotlin
    pairingFailed: Boolean = false,
    onPairingCancelClick: () -> Unit = {},
    onPairingErrorDismiss: () -> Unit = {},
```

And forward them in the `MainCard(...)` call (line 168):

```kotlin
                pairingFailed = pairingFailed,
                onPairingCancelClick = onPairingCancelClick,
                onPairingErrorDismiss = onPairingErrorDismiss,
```

In the same function, update the footer state line (185) so pairing renders like searching:

```kotlin
                bleState = when {
                    isConnected -> "connected"
                    state is AppState.Searching -> "searching"
                    state is AppState.Pairing -> "searching"
                    else -> "unpaired"
                },
```

(Leave `isPaired = state !is AppState.Unpaired` as is — treating Pairing as "paired-ish" for the background/footer tint is fine.)

- [ ] **Step 2: Status chip**

In `StatusChip`'s `when` (line 205), add before the `Searching` branch:

```kotlin
        is AppState.Pairing -> ChipStyle(
            bg = Color(0x1400FFD5),
            dot = Color(0xFFBDBDBD),
            text = Teal,
            label = "Pairing…"
        )
```

And make the blinking dot cover pairing (line 239):

```kotlin
        if (state is AppState.Searching || state is AppState.Pairing) {
```

- [ ] **Step 3: MainCard colors + params**

Add the same three parameters to `MainCard(...)` (line 285):

```kotlin
    pairingFailed: Boolean = false,
    onPairingCancelClick: () -> Unit = {},
    onPairingErrorDismiss: () -> Unit = {},
```

In the two color `when`s (lines 303 and 313), add a Pairing branch mirroring Searching:

```kotlin
            is AppState.Pairing -> Color(0xFFF5FFFC)
```

```kotlin
            is AppState.Pairing -> Color(0x1F00FFD5)
```

- [ ] **Step 4: Action area — pairing status row, error card, buttons**

Replace the action-button block (lines 498–546, the `if (!isPaired) { Button(...Pair with Mac...) } else { ...Unpair... }` section) with:

```kotlin
            // Action area
            when {
                state is AppState.Pairing -> {
                    PairingStatusRow(
                        stage = state.stage,
                        onCancelClick = onPairingCancelClick
                    )
                }
                state is AppState.Unpaired -> {
                    if (pairingFailed) {
                        PairingFailedCard(
                            onTryAgain = {
                                onPairingErrorDismiss()
                                onPairClick()
                            },
                            onDismiss = onPairingErrorDismiss
                        )
                        Spacer(modifier = Modifier.height(12.dp))
                    }
                    Button(
                        onClick = onPairClick,
                        modifier = Modifier.fillMaxWidth(),
                        shape = RoundedCornerShape(28.dp),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = Aqua,
                            contentColor = Teal
                        )
                    ) {
                        Text(
                            text = "Pair with Mac",
                            fontSize = 15.sp,
                            fontWeight = FontWeight.Medium,
                            modifier = Modifier.padding(vertical = 4.dp)
                        )
                    }
                }
                else -> {
                    val unpairBg by animateColorAsState(
                        targetValue = if (isConnected) Color(0x1400FFD5) else Color(0x0F00FFD5),
                        animationSpec = tween(400),
                        label = "unpairBg"
                    )
                    val unpairBorder by animateColorAsState(
                        targetValue = if (isConnected) Color(0x2600FFD5) else Color(0x1A00FFD5),
                        animationSpec = tween(400),
                        label = "unpairBorder"
                    )
                    Button(
                        onClick = onUnpairClick,
                        modifier = Modifier
                            .fillMaxWidth()
                            .border(1.dp, unpairBorder, RoundedCornerShape(28.dp)),
                        shape = RoundedCornerShape(28.dp),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = unpairBg,
                            contentColor = Teal
                        ),
                        elevation = ButtonDefaults.buttonElevation(0.dp, 0.dp, 0.dp)
                    ) {
                        Text(
                            text = "Unpair",
                            fontSize = 15.sp,
                            fontWeight = FontWeight.Medium,
                            modifier = Modifier.padding(vertical = 4.dp)
                        )
                    }
                }
            }
```

- [ ] **Step 5: New composables**

Add after `MainCard` (after line 567), in the file's existing private-composable style:

```kotlin
@Composable
private fun PairingStatusRow(
    stage: PairingStage,
    onCancelClick: () -> Unit
) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(18.dp))
                .background(Color(0x1400FFD5))
                .border(1.dp, Color(0x2B00FFD5), RoundedCornerShape(18.dp))
                .padding(horizontal = 14.dp, vertical = 12.dp),
            horizontalArrangement = Arrangement.Center,
            verticalAlignment = Alignment.CenterVertically
        ) {
            CircularProgressIndicator(
                modifier = Modifier.size(16.dp),
                strokeWidth = 2.dp,
                color = Teal
            )
            Spacer(modifier = Modifier.width(10.dp))
            Text(
                text = when (stage) {
                    PairingStage.Connecting -> "Connecting to your Mac…"
                    PairingStage.ExchangingKeys -> "Exchanging keys…"
                },
                color = Teal,
                fontSize = 14.sp,
                fontWeight = FontWeight.Medium
            )
        }
        TextButton(onClick = onCancelClick) {
            Text(
                text = "Cancel",
                color = Teal.copy(alpha = 0.6f),
                fontSize = 13.sp
            )
        }
    }
}

@Composable
private fun PairingFailedCard(
    onTryAgain: () -> Unit,
    onDismiss: () -> Unit
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(18.dp))
            .background(Color(0x14FF5252))
            .border(1.dp, Color(0x29FF5252), RoundedCornerShape(18.dp))
            .padding(horizontal = 14.dp, vertical = 12.dp)
    ) {
        Text(
            text = "Couldn't reach your Mac",
            color = Color(0xFFB71C1C),
            fontSize = 14.sp,
            fontWeight = FontWeight.SemiBold
        )
        Spacer(modifier = Modifier.height(4.dp))
        Text(
            text = "Make sure ClipRelay is open on your Mac and Bluetooth is on, then try again.",
            color = Color(0xCC7F0000),
            fontSize = 12.sp
        )
        Spacer(modifier = Modifier.height(8.dp))
        Row(horizontalArrangement = Arrangement.End, modifier = Modifier.fillMaxWidth()) {
            TextButton(onClick = onDismiss) {
                Text(text = "Dismiss", fontSize = 13.sp, color = Color(0x99000000))
            }
            TextButton(onClick = onTryAgain) {
                Text(text = "Try again", fontSize = 13.sp, color = Color(0xFFB71C1C), fontWeight = FontWeight.SemiBold)
            }
        }
    }
}
```

If `CircularProgressIndicator` / `TextButton` are not yet imported, add to the imports:

```kotlin
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.TextButton
```

- [ ] **Step 6: Full compile + all unit tests**

Run: `cd android && ./gradlew compileDebugKotlin testDebugUnitTest 2>&1 | tail -5`
Expected: BUILD SUCCESSFUL, all tests (including Task 1's) pass. The compiler will flag any `when (state)` I missed — fix by adding a `Pairing` branch that mirrors `Searching`.

- [ ] **Step 7: Commit**

```bash
git add android/app/src/main/java/org/cliprelay/ui/
git commit -m "feat(android): pairing progress UI with status stages, cancel, and failure card"
```

(If Tasks 1–3 couldn't commit standalone due to cross-file compile dependencies, this commit includes those files too — adjust the message to cover the whole feature.)

---

### Task 5: Build, hardware verification, push

- [ ] **Step 1: Full build + test suite (AGENTS.md requirement)**

```bash
./scripts/build-all.sh && ./scripts/test-all.sh
```
Expected: both succeed (Mac app unchanged but must still build).

- [ ] **Step 2: Install + restart on device (if connected)**

```bash
adb get-state && adb install -r dist/cliprelay-debug.apk && adb shell am force-stop org.cliprelay && adb shell am start -n org.cliprelay/.ui.MainActivity
```

Also restart the Mac app: `pkill -f ClipRelay; open dist/ClipRelay.app` (or `/Applications/ClipRelay.app` if dist bundle isn't preferred).

- [ ] **Step 3: Hardware smoke test (if device connected)**

```bash
./scripts/hardware-smoke-test.sh
```

- [ ] **Step 4: Manual verification of the new UX (needs the user)**

1. Happy path: pair normally — expect chip "Pairing…", "Connecting to your Mac…" → (briefly) "Exchanging keys…" → burst → Searching/Connected.
2. Failure path: quit the Mac app, scan a stale/fresh QR — expect ~20 s of "Connecting…", then the red "Couldn't reach your Mac" card; **Try again** reopens the scanner.
3. Cancel path: start pairing, tap Cancel — back to Unpaired, service stops advertising (check `adb logcat -s ClipRelayService` for "Pairing cancelled").
4. Screenshot each state (`adb exec-out screencap -p > /tmp/cliprelay-screenshot.png`) and visually inspect per AGENTS.md.

- [ ] **Step 5: Push and update PR #73 description**

```bash
git push
```

Then update the PR #73 description via `gh api -X PATCH repos/geekflyer/cliprelay/pulls/73 -F body=@<file>` (write the body to a temp file first; `gh pr edit` is currently broken by a projects-classic deprecation error). Add a "Pairing status UI" section covering: the two-stage progress ("Connecting to your Mac…" / "Exchanging keys…"), the 20 s service-owned timeout with error card + retry, and cancel support.
