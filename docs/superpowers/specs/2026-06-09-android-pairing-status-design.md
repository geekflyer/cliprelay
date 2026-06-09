# Android Pairing Status & Progress Design

**Date:** 2026-06-09
**Status:** Approved
**Related:** issue #56 follow-up (Quickie scanner PR #73)

## Problem

After scanning the pairing QR code, the Android app immediately shows the generic
"Searching for Mac" state — the same state shown whenever the app is paired but
disconnected. There is no indication that pairing is in progress, no distinction
between "waiting for the Mac to connect" and "exchanging keys", and — critically —
no feedback at all when pairing silently fails (e.g. the Mac's BLE central is stuck
post-sleep and never connects, which presents as an indefinite hang).

Evidence from debugging: pairing has two wildly unequal phases. Waiting for the Mac
to discover and connect can take seconds or hang forever; the ECDH key exchange after
L2CAP connect completes in under 100 ms. The status UI should reflect that asymmetry
rather than fake a multi-step checklist.

## Goals

- Distinct, truthful pairing progress after the QR is scanned:
  "Connecting to your Mac…" → "Exchanging keys…" → paired.
- A ~20 s timeout with an actionable error and retry when the Mac never connects.
- Service-owned lifecycle: a failed/abandoned pairing cleans itself up (stops
  advertising, clears pending keys) even if the UI is gone.

## Non-Goals

- No multi-step visual checklist (the key-exchange phase is too short to see).
- No Mac-side changes.
- No changes to the pairing protocol itself.

## Design

### Service (`ClipRelayService`) — owns the pairing lifecycle

New broadcast `ACTION_PAIRING_STATUS` with `EXTRA_PAIRING_STAGE` (String):

| Stage | When |
|---|---|
| `CONNECTING` | `ACTION_START_PAIRING` handled; BLE advertising with the pairing tag |
| `EXCHANGING_KEYS` | L2CAP client connected while `pairingInProgress` |
| `FAILED` | 20 s deadline elapsed without pairing completing, or BLE startup failed |

Lifecycle:

- On `ACTION_START_PAIRING`: start a 20 s deadline (main-looper `Handler`),
  broadcast `CONNECTING`.
- In `onClientConnected` (pairing path): broadcast `EXCHANGING_KEYS`.
- On ECDH completion: clear the deadline; existing `ACTION_PAIRING_COMPLETE`
  broadcast is unchanged and remains the success signal.
- On deadline: cancel pairing — `pairingInProgress = false`, clear
  `pendingPairingKeyPair` / `pendingMacPublicKeyRaw` / `pending_pairing_pubkey`
  pref, stop BLE components (unpaired state stops advertising) — broadcast `FAILED`.
- New `ACTION_CANCEL_PAIRING` intent action performs the same cleanup without
  broadcasting `FAILED` (user-initiated; UI already knows).
- The deadline is also cleared on `ACTION_UNPAIR` and service destroy.

### ViewModel (`MainViewModel`)

- New state: `AppState.Pairing(stage: PairingStage)` where
  `enum class PairingStage { Connecting, ExchangingKeys }`.
- New flow: `pairingFailed: StateFlow<Boolean>`.
- `onPairingStatus(stage)` maps broadcast → state; `FAILED` sets `pairingFailed`
  and reverts state to `Unpaired`.
- `MainActivity`'s scanner-result callback now sets `Pairing(Connecting)`
  (optimistic, immediately confirmed by the `CONNECTING` broadcast) instead of
  the previous `Searching`.
- `PAIRING_COMPLETE` keeps its existing path (`onPaired` → Searching → Connected
  via connection broadcast).

### UI (`ClipRelayScreen`)

- `AppState.Pairing` renders: status chip "Pairing…" plus a status line with a
  small spinner — "Connecting to your Mac…" or "Exchanging keys…" — and a
  "Cancel" text button that sends `ACTION_CANCEL_PAIRING` and returns the UI
  to Unpaired (this is the caller of that new action).
- `pairingFailed` renders an inline error card:
  *"Couldn't reach your Mac. Make sure ClipRelay is open on your Mac and
  Bluetooth is on."* with two actions:
  - **Try again** — dismisses the error and relaunches the QR scanner
    (the Mac pairing QR is ephemeral; a fresh scan is the safe path).
  - **Cancel** — dismisses the error, stays Unpaired.
- Existing version-mismatch dialog continues to work (fires during key exchange).

### Strings

New: `pairing_connecting` ("Connecting to your Mac…"), `pairing_exchanging_keys`
("Exchanging keys…"), `pairing_chip` ("Pairing…"), `pairing_failed_title`,
`pairing_failed_body`, `pairing_try_again`, `pairing_cancel`.

## Error Handling

- BLE startup failure during pairing (e.g. Bluetooth off): broadcast `FAILED`
  immediately rather than waiting out the deadline.
- Broadcast races: `FAILED` arriving after `PAIRING_COMPLETE` is ignored
  (ViewModel only honors `FAILED` while in `Pairing` state).
- App restarted mid-pairing: service deadline still fires and cleans up; the UI
  re-derives state from the pairing store on launch as today.

## Testing

- Unit tests for `MainViewModel` state transitions:
  scanned → Connecting → ExchangingKeys → paired; Connecting → FAILED → retry;
  FAILED-after-complete race ignored.
- Manual hardware test: normal pairing shows both stages and completes; pairing
  with the Mac app closed times out at ~20 s and shows the error card; Try again
  reopens the scanner.
