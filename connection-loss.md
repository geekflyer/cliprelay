# Connection Loss Status

> Issue: BLE connection between Mac and Android can die after long idle periods,
> especially around Mac sleep/wake cycles.

Last verified: 2026-03-01

## Implemented Fixes (already in code)

These items are done and can be treated as closed:

1. **Wake timer restart bug** (`BLECentralManager.handleSystemWake`)
   - On wake, timers are explicitly stopped then restarted.
   - Prevents zombie/non-firing `Timer` instances from silently disabling recovery.

2. **Pre-sleep cleanup** (`NSWorkspace.willSleepNotification` handler)
   - Added sleep handler that disconnects peripherals and stops timers before sleep.
   - Reduces stale connection handles on wake.

3. **Mac persistent logging** (`bleLog` now writes to unified logging)
   - BLE logs now go to `os_log` in addition to stdout.
   - Past failures are diagnosable via macOS log tools.

4. **CoreBluetooth connection slot leak mitigation**
   - Cancels connections before state clear on non-`poweredOn` transitions.
   - Adds connection-limit cooldown/recovery path in `didFailToConnect`.
   - Prevents repeated max-connection failure loops.

## Remaining TODOs (relevance check)

### 2) Preserve `peripheralTokenMap` across BT state transitions

- **Status**: Open
- **Still relevant**: **Yes**
- **Why**: `centralManagerDidUpdateState` still clears `peripheralTokenMap` on non-`poweredOn` state (`macos/ClipRelayMac/Sources/BLE/BLECentralManager.swift:760`).
- **Impact**: After BT state churn, reconnection can depend on re-discovery and rematching, adding latency and fragility.

### 4) Add Android GATT server health check / periodic cycle

- **Status**: Open
- **Still relevant**: **Yes**
- **Why**: Advertising has a periodic cycle, but GATT server does not. `GattServerManager` only starts/stops; there is no periodic validation/reopen path (`android/app/src/main/java/com/cliprelay/ble/GattServerManager.kt`).
- **Impact**: If GATT server becomes stale while advertising remains healthy, central can discover but fail service interaction.

### 6) Replace `Handler.postDelayed` ad health checks with idle-resilient scheduling

- **Status**: Open
- **Still relevant**: **Mostly yes (low priority)**
- **Why**: Health checks still use `Handler.postDelayed` (`android/app/src/main/java/com/cliprelay/ble/Advertiser.kt:156`).
- **Impact**: On aggressive OEM power management, health-check cadence can drift and delay recovery.

### 7) Add `CBCentralManager` state restoration identifier

- **Status**: Open
- **Still relevant**: **Yes (low priority)**
- **Why**: Central manager is still created without restoration options (`macos/ClipRelayMac/Sources/BLE/BLECentralManager.swift:104`).
- **Impact**: If app is terminated during sleep/memory pressure, BLE state cannot be restored automatically.

## Current Priority Order

1. Preserve `peripheralTokenMap` across state transitions (Todo #2)
2. Add GATT server health check/cycle (Todo #4)
3. Keep ad health check scheduling improvement as optional hardening (Todo #6)
4. Add central state restoration for long-run reliability (Todo #7)
