# Connection Revamp Plan

## Purpose

Document a proposed BLE reliability revamp for peer review before implementation.

Primary goal: stop long-run reconnect thrash and disconnect loops between macOS and Android by moving from a peripheral-first identity model to a token-first model, and by adding Android GATT health recovery.

## Current Problem

Observed behavior from recent diagnostics:

- macOS repeatedly disconnects and reconnects in tight loops, often with `didDisconnect ... error=nil`.
- `bluetoothd` reports heavy GATT flapping (`status 762`, "handle not tracked", "session not found").
- Android advertising appears active, but GATT server state can become stale/inconsistent.
- Around sleep/wake and privacy address churn, one physical phone can appear as multiple BLE peripheral identities.

The current architecture treats `CBPeripheral.identifier` as the primary identity and token as metadata. Over time this can accumulate stale identities for the same phone and trigger parallel reconnect attempts against old endpoints.

## Root Cause Hypothesis

This is likely a multi-factor failure, not a single defect:

1. Identity churn from rotating BLE addresses (or equivalent privacy remapping) causes new peripheral identities for the same paired phone.
2. The macOS peripheral-first bookkeeping allows multiple stale peripheral IDs to remain active for one token.
3. Reconnect scheduling by peripheral ID creates fan-out connect attempts and amplifies stack instability.
4. Android can continue advertising while GATT server state is stale, creating discoverable-but-unusable windows.
5. Sleep/wake transitions increase probability of stale sessions on both sides.

## Proposed Design Direction

### 1) Token-First Connection Model on macOS

Treat paired token as the canonical peer identity. Treat `CBPeripheral.identifier` as an ephemeral transport handle.

Design rules:

- One token maps to at most one active canonical peripheral ID at a time.
- If scan finds a known token on a new peripheral ID, atomically replace the old ID mapping.
- Maintain connect/disconnect/retry state per token, not per peripheral ID.
- At most one active connect attempt per token.

Expected outcome:

- Address/identity rotation no longer multiplies reconnect attempts.
- Reconnect logic remains stable across transport identity churn.

### 2) Aggressive Stale Peripheral Pruning on macOS

Add freshness tracking for discovered peripheral IDs and prune IDs not seen recently.

Design rules:

- Store `lastSeen` timestamp for each peripheral ID.
- During scan/recovery cycle, remove IDs older than a threshold from transient maps.
- Do not retry connection attempts for IDs that have aged out.

Expected outcome:

- Prevents stale IDs from being retried indefinitely.
- Reduces contention and redundant CoreBluetooth work.

### 3) Android GATT Server Health Watchdog

Extend Android health checks to cover GATT server liveness, not only advertising.

Design rules:

- Keep periodic health interval in the foreground service.
- Detect unhealthy state where advertising is active but server is unregistered/stale.
- Recovery action: restart GATT server and advertiser as a coordinated cycle.
- Add explicit logs/metrics for watchdog trigger and recovery success/failure.

Expected outcome:

- Prevents discoverable-but-nonfunctional periods.
- Gives deterministic self-healing path without manual toggles.

### 4) Single-Instance Runtime Guard on macOS

Ensure only one ClipRelay app instance manages BLE at a time.

Design rules:

- Detect another running ClipRelay instance on startup.
- Exit secondary instance (or refuse BLE init) with clear log message.

Expected outcome:

- Removes cross-instance BLE contention and ambiguous logs.

## Why This Plan Is Preferred

This proposal addresses both classes of evidence:

- Identity-layer instability (same phone seen as multiple transport identities).
- Transport/session instability (GATT stack churn and stale server windows).

A token-first model is robust to address rotation by design; Android watchdog closes the gap where advertisements persist but GATT is unusable.

## Non-Goals

- No protocol redesign.
- No user-visible pairing model change.
- No immediate change to copy/paste payload flow.

## Risks and Mitigations

- Risk: over-aggressive pruning drops valid peripherals.
  - Mitigation: conservative timeout defaults and high-signal logging.
- Risk: watchdog restart loop on Android.
  - Mitigation: backoff and max restart attempts per window.
- Risk: token migration bugs could drop active session.
  - Mitigation: atomic map updates and focused integration tests.

## Validation Plan

Before merge:

1. Reproduce long-idle + sleep/wake scenario.
2. Verify one-token/one-connect-attempt invariant from logs.
3. Verify old peripheral IDs are pruned and not retried.
4. Simulate/induce stale Android GATT and confirm watchdog recovery.
5. Run extended soak test (overnight idle + periodic transfer).

Success criteria:

- No reconnect fan-out for a single paired token.
- No sustained disconnect loop under normal RF conditions.
- Automatic recovery when Android GATT enters stale state.

## Proposed Implementation Order

1. macOS token-first mapping and per-token connect gate.
2. macOS stale peripheral pruning.
3. Android GATT watchdog and coordinated restart.
4. macOS single-instance guard.
5. Full soak validation and tuning.

## Open Review Questions

- Preferred stale peripheral timeout and backoff parameters.
- Whether to keep limited historical peripheral IDs for diagnostics.
- Whether watchdog should restart only server first, or server+advertiser together every time.
- Any edge-case concerns with token migration during active transfer.
