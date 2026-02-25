# BLE Disconnection Troubleshooting Progress

## Problem
After some time (hours), the macOS desktop app loses BLE connection to the Android phone and cannot reconnect. The connection was working earlier but silently dies.

## Root Causes Identified

### 1. Android silently kills BLE advertisements (CONFIRMED - 2026-02-24)
**Evidence:** Running `adb shell "dumpsys bluetooth_manager"` showed that `com.cliprelay` was registered as a GATT Server (`app_if: 61`) but was **NOT present in the GATT Advertiser Map**. The advertisement had been silently stopped by Android OS without any callback to the app.

**Why it happens:** Android can silently stop BLE advertisements due to:
- Doze mode / battery optimization
- Too many concurrent advertisers (system limit)
- Internal BLE stack resets
- App Standby buckets reducing BLE access

**The `AdvertiseCallback.onStartFailure` is NOT called** when Android silently removes an advertisement — only when the initial `startAdvertising()` call fails.

**Fix applied:** Added a periodic health-check timer (`HEALTH_CHECK_INTERVAL_MS = 4 min`) in `Advertiser.kt` that cycles the advertisement (stop + start) every 4 minutes. This ensures that even if Android silently killed the ad, it gets restarted within the next cycle.

### 2. No connection-level keepalive on macOS (CONFIRMED - 2026-02-24)
**Evidence:** The Mac had no way to detect a "zombie" BLE connection — one where CoreBluetooth still considers the peripheral connected but the actual radio link is dead (e.g., after Android's BLE stack internally reset).

**Fix applied:** Added a keepalive timer in `BLECentralManager.swift` that reads RSSI from connected peripherals every 30 seconds. If a peripheral fails to respond to 2 consecutive probes (within the 45-second timeout window), the Mac force-disconnects it, which triggers the normal reconnection flow.

### 3. Mac scan stalls when Android stops advertising
**Evidence:** The Mac's `scheduleReconnect()` used exponential backoff up to 30 seconds but only reset on successful connect or system wake. If the scan kept running but couldn't find the device (because Android stopped advertising), the Mac just kept scanning indefinitely.

**Fix applied:** Added a periodic scan cycle timer (every 2 minutes) that:
- Restarts scanning to reset CoreBluetooth's duplicate advertisement filter
- Resets the reconnect backoff delay when no peers are connected
- Re-attempts direct connections for all known paired peripherals

## Previous Fixes (still in place)
- **Sleep/wake reconnection** (`bd36cb0`): Handles macOS sleep/wake by canceling all connections and restarting scan
- **Pairing tag fallback** (`7e2756f`): Handles case where advertisement tag is missing during pairing
- **Stale pending entry cleanup** (`49269e1`): Prevents stale pending pairing entries from interfering

## Diagnostic Commands

### Check if Android is advertising
```bash
adb shell "dumpsys bluetooth_manager" | grep -B5 -A30 "cliprelay"
```
Look for `com.cliprelay` in both the GATT Server Map AND the GATT Advertiser Map. If it's only in the server map but not the advertiser map, advertising has been silently killed.

### Check Android app service status
```bash
adb shell "dumpsys activity services com.cliprelay"
```
Should show `isForeground=true`.

### Check Mac BLE logs
The Mac app logs to stdout with `[BLE]` prefix. Look for:
- `[BLE] RSSI probe timeout` — keepalive detected dead link
- `[BLE] Forcing disconnect of unresponsive peer` — keepalive triggered reconnection
- `[BLE] Scan cycle: no connected peers` — periodic scan restart kicking in
- `[BLE] Periodic advertising health-check` — Android ad cycling (visible in adb logcat)

### Check Android logs
```bash
adb logcat -s Advertiser:* GattServerManager:* ClipRelayService:*
```

## Things NOT Yet Tried (Future Investigation)
- [ ] Android battery optimization exclusion (request `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`)
- [ ] Using Android `BluetoothLeAdvertiser.startAdvertisingSet()` (API 26+) which supports duration=0 (unlimited) and may be more resilient
- [ ] Adding a BLE connection parameter update to request longer supervision timeout
- [ ] Implementing an L2CAP channel for more reliable connection detection
- [ ] Investigating if `CBCentralManagerOptionRestoreIdentifierKey` (state restoration) helps on macOS
