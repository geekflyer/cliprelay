# Connection State Machine Refactor — Design Spec

## Problem

The Mac app's BLE connection management has recurring race conditions and reconnection bugs. The root cause is structural: connection lifecycle state is split across three classes (`ConnectionManager`, `AppDelegate`, `Session`) with no threading contract, duplicate cleanup paths, and no mechanism to reject stale callbacks.

Specific issues:
1. **Split state ownership.** `ConnectionManager` owns BLE state (`state`, `matchedToken`, `l2capChannel`). `AppDelegate` owns session state (`activeSession`, `connectedSecret`, `sessionThread`). Both mutate shared state from different threads.
2. **Partial state enum.** `ConnectionManager.State` covers idle/scanning/connecting/openingL2CAP/connected but not handshaking or session-ready. The handshake and ready phases live implicitly in AppDelegate variables.
3. **Duplicate cleanup.** Five or more code paths clear connection state: BLE disconnect, BT power off, session error, health check timeout, forget device. Each does slightly different cleanup.
4. **No threading model.** CB callbacks run on the main queue. Session callbacks run on a background thread. Both mutate the same AppDelegate properties.
5. **No stale callback rejection.** `didDisconnectPeripheral` doesn't know which connection attempt it belongs to. Stale disconnects from a BT power cycle can clobber a new connection in progress.

## Solution

Replace `ConnectionManager` and AppDelegate's connection logic with a single `ConnectionController` class that owns the full lifecycle on a dedicated serial `DispatchQueue`.

## Architecture

### State Enum

One enum covers the full lifecycle:

```
idle → scanning → bleConnecting → l2capOpening → handshaking → ready
                → pairingConnecting → pairingL2CAP → pairingHandshake → handshaking → ready
```

```swift
enum ConnectionState {
    case idle
    case scanning

    // Normal connection path
    case bleConnecting(CBPeripheral, CBL2CAPPSM, generation: UInt)
    case l2capOpening(CBPeripheral, generation: UInt)

    // Pairing path
    case pairingConnecting(CBPeripheral, CBL2CAPPSM, generation: UInt)
    case pairingL2CAP(CBPeripheral, generation: UInt)
    case pairingHandshake(Session, generation: UInt)

    // Shared final states
    case handshaking(Session, generation: UInt)
    case ready(Session, token: String, generation: UInt)
}
```

States carry their primary owned objects (peripheral, session, token) directly. Two deliberate exceptions kept as instance variables:

- **`l2capChannel: CBL2CAPChannel?`** — CoreBluetooth deallocates the channel if no strong reference is held. The channel is set when `didOpen` fires and cleared in `transitionToIdle`. It doesn't belong in the enum because it's a retain-only reference that no state transition logic reads.
- **`connectingStartTime: Date?`** — Metadata about when we entered a connecting state, used only by the health check timeout. Set when entering `bleConnecting`/`l2capOpening`/`pairingConnecting`/`pairingL2CAP`, cleared in `transitionToIdle`.

### Generation Counter

A monotonic `UInt` incremented each time `transitionToIdle` is called. Every connection-phase state carries the generation it was created with. Every CB callback and session callback checks `gen == self.generation` before processing. Mismatches are silently dropped. This eliminates the entire class of stale-callback bugs.

### Serial DispatchQueue

```swift
private let queue = DispatchQueue(label: "org.cliprelay.connection")
```

- `CBCentralManager` is initialized with `queue: queue`, so all CB delegate callbacks land directly on it.
- Session delegate callbacks are dispatched onto this queue via a `SessionAdapter` (see Threading section).
- Timers use `DispatchSourceTimer` targeting this queue. No RunLoop dependency.
- All state reads and writes happen on this queue. No locks needed.

### Single Cleanup Path

Every failure funnels through one method:

```swift
private func transitionToIdle(reason: String, reconnect: Bool = true) {
    // Cancel any tracked peripheral
    if let peripheral = trackedPeripheral(from: state) {
        centralManager.cancelPeripheralConnection(peripheral)
    }
    if case .scanning = state {
        centralManager.stopScan()
    }

    // Close any active session
    if let session = activeSession(from: state) {
        session.close()
    }

    // Clear all connection state
    l2capChannel = nil
    pairingTag = nil
    pairingPrivateKey = nil
    generation += 1

    transition(to: .idle, reason: reason)

    if reconnect {
        scheduleReconnect()
    }
}
```

Helper functions `trackedPeripheral(from:)` and `activeSession(from:)` extract objects from the current state enum without separate instance variables.

All triggers use this one path:

| Trigger | Call |
|---|---|
| BLE disconnect | `transitionToIdle(reason: "BLE disconnect")` |
| BT power off | `transitionToIdle(reason: "BT powered off")` |
| Session error | `transitionToIdle(reason: "session error: ...")` |
| Health check timeout | `transitionToIdle(reason: "stuck connection")` |
| Forget device | `transitionToIdle(reason: "device forgotten", reconnect: false)` |

### Session Threading

Session's `listenForMessages()` is a blocking polling loop on a background thread. ConnectionController bridges session callbacks to the connection queue via a `SessionAdapter`:

```swift
private class SessionAdapter: SessionDelegate {
    weak var controller: ConnectionController?
    let generation: UInt

    func sessionDidBecomeReady(_ session: Session) {
        controller?.queue.async { [weak controller] in
            guard let controller, controller.generation == generation else { return }
            controller.handleSessionReady(session)
        }
    }

    func session(_ session: Session, didFailWithError error: Error) {
        controller?.queue.async { [weak controller] in
            guard let controller, controller.generation == generation else { return }
            controller.handleSessionError(error)
        }
    }

    // Same pattern for all SessionDelegate methods
}
```

Each new connection creates a new `SessionAdapter` with the current generation. Stale session threads that outlive their connection attempt produce callbacks with an old generation, which are silently dropped.

**Stream scheduling sequence** (all on the connection queue unless noted):

1. `didOpen` callback (connection queue): schedule streams on a temporary RunLoop source and open them. This satisfies CoreBluetooth's requirement that streams be opened promptly.
2. `startSession` (connection queue): spawn the session thread.
3. Session thread (background): remove streams from any previous RunLoop scheduling, re-schedule on the thread's own RunLoop, then call `performHandshake()` + `listenForMessages()`.

This matches the current pattern but all setup steps happen on the connection queue instead of main.

**Concurrent close safety:** When `transitionToIdle` calls `session.close()`, Session's `_closed` flag (NSLock-protected) ensures only one path executes the close body. If the session thread concurrently detects a stream error and also tries to close, the lock prevents double-close. The session thread's error callback dispatches to the connection queue via SessionAdapter, where the stale generation check drops it. This is a residual race on Foundation stream `.close()` calls (not documented as thread-safe for concurrent close), inherited from the current code. Acceptable risk given no crashes observed in practice.

### Pairing

Pairing uses dedicated states in the same enum rather than a separate flow. Discovery branches based on whether `pairingTag` is set:

- If pairing: `scanning → pairingConnecting → pairingL2CAP → pairingHandshake → handshaking → ready`
- If normal: `scanning → bleConnecting → l2capOpening → handshaking → ready`

Both paths converge at `handshaking` (since the pairing handshake transitions into a normal HELLO/WELCOME handshake within the same Session). One state machine, no coordination logic between separate flows.

**Pairing key flow:** `startPairing()` generates an ECDH private key via `PairingManager`, stores it as `pairingPrivateKey`, computes the `pairingTag` from the public key, and begins scanning. When the pairing device is found and L2CAP is established, the controller creates a Session with `mode: .pairing(privateKey: pairingPrivateKey!)` and transitions to `.pairingHandshake`. The private key is cleared in `transitionToIdle`.

### Public API

ConnectionController exposes a callback-based delegate protocol to AppDelegate. **All delegate methods are dispatched to `DispatchQueue.main`** so AppDelegate never handles threading.

```swift
protocol ConnectionControllerDelegate: AnyObject {
    func connectionController(_ c: ConnectionController,
                              didChangeState connected: Bool, deviceName: String?)
    func connectionController(_ c: ConnectionController,
                              didReceiveClipboard text: String)
    func connectionController(_ c: ConnectionController,
                              didReceiveImage data: Data, contentType: String)
    func connectionController(_ c: ConnectionController,
                              didCompletePairing deviceName: String?)
    func connectionController(_ c: ConnectionController,
                              didEncounterError error: ConnectionError)
    func connectionController(_ c: ConnectionController,
                              didUpdateBluetoothState available: Bool)
    func connectionController(_ c: ConnectionController,
                              didSyncClipboard hash: String)
    func connectionController(_ c: ConnectionController,
                              didChangeImageSyncSetting enabled: Bool)
    func connectionController(_ c: ConnectionController,
                              imageTransferFailed reason: String)
}
```

**Error types:** `ConnectionError` distinguishes recoverable errors (BLE disconnect, session error) from non-recoverable ones (`versionMismatch`). ConnectionController suppresses reconnection for `versionMismatch` internally. AppDelegate uses the error type to decide whether to show a user-facing alert.

**Bluetooth debounce:** `didUpdateBluetoothState` fires immediately on state change. AppDelegate retains its existing 60-second debounce timer for the "Bluetooth is off" alert — this is UI policy, not connection logic.

Public methods:

```swift
func sendClipboard(_ text: String)
func sendImage(_ data: Data, contentType: String)
func startPairing() -> PairingInfo
func cancelPairing()
func forgetDevice(token: String)
func toggleImageSync()
var pairedDevices: [PairedDevice] { get }
var isImageSyncEnabled: Bool { get }
```

**Dependencies:** ConnectionController receives `PairingManager` as an init parameter. It uses PairingManager to look up paired device tags for discovery matching, store new paired devices, read/write rich media settings, and remove forgotten devices.

### Dedup & Pending Clipboard

ConnectionController owns dedup state (`lastReceivedTextHash`, `lastReceivedImageHash`) and `pendingClipboard`. Dedup is checked before notifying the delegate. Pending clipboard is sent automatically when session becomes ready and cleared on successful transfer (`didCompleteTransfer` callback from Session). AppDelegate does not touch any of this.

**Image transfer failures:** Session's `imageWasRejected` and `imageSendFailed` callbacks are forwarded through SessionAdapter to the connection queue. ConnectionController surfaces these via the `imageTransferFailed(reason:)` delegate method so AppDelegate can log or display feedback.

**CONFIG_UPDATE flow:** `toggleImageSync()` dispatches to the connection queue, reads the current setting from PairingManager, flips it, persists via PairingManager, and if the state is `.ready`, calls `session.sendConfigUpdate()` to notify the remote device. Incoming CONFIG_UPDATE messages arrive via Session's `didChangeRichMediaSetting` callback, are routed through SessionAdapter to the connection queue, where ConnectionController persists the remote's setting via PairingManager (last-write-wins by timestamp) and notifies AppDelegate via `didChangeImageSyncSetting`. ConnectionController also wires a `DeviceSettingsProvider` to the Session when entering `.handshaking` state (normal path) or after pairing completes (pairing path), matching the current behavior.

**`alreadyHasHash` synchronous callback:** Session calls `session(_:alreadyHasHash:) -> Bool` synchronously from the session thread. Since this only reads `lastReceivedTextHash` (written on the connection queue), the SessionAdapter handles it by reading the value directly with a lightweight lock rather than async dispatch. This is the one exception to the "all session callbacks dispatch to connection queue" pattern — a synchronous return value requires it.

### Reconnection & Health Checks

Same logic as the current implementation:

- **Reconnection:** Exponential backoff 1s → 2s → 4s → 8s → 16s → 30s cap. Reset on successful connection or BT power-on. Uses `DispatchSourceTimer` on the connection queue.
- **Health check:** 60s repeating timer. Detects stuck connecting states (15s timeout), **cycles stale scans** (stop + restart to force CoreBluetooth to re-deliver advertisement data with `allowDuplicates`, working around CB's peripheral caching quirk), and recovers idle states with no active reconnect. Uses `DispatchSourceTimer` on the connection queue.

### Logging

All connection state machine logging uses `os.Logger` with `privacy: .public` on all interpolated values:

```swift
private let logger = Logger(subsystem: "org.cliprelay", category: "Connection")

private func log(_ message: String) {
    logger.notice("\(message, privacy: .public)")
}
```

Every state transition is logged via the `transition(to:reason:)` method, giving a complete audit trail in `log stream`. Key events logged:
- Every state transition with old → new state and reason
- BT hardware state changes
- Device discovery with tag, PSM, RSSI
- Handshake start/completion/failure
- Reconnect scheduling with delay
- Health check actions
- Stale callback rejections (with generation mismatch details)

## File Changes

**New:**
- `Sources/BLE/ConnectionController.swift` (~600-700 lines) — unified state machine

**Deleted:**
- `Sources/BLE/ConnectionManager.swift` (~400 lines) — fully replaced

**Significantly changed:**
- `Sources/App/AppDelegate.swift` (~700 → ~350 lines) — remove ConnectionManagerDelegate, SessionDelegate connection logic, dedup state, pending clipboard. Replace with ~100 lines of ConnectionControllerDelegate wiring.

**Unchanged:**
- `Sources/Protocol/Session.swift` — black box, no changes
- `Sources/Protocol/MessageCodec.swift`
- `Sources/App/StatusBarController.swift`
- All crypto, pairing store, clipboard, TCP transfer files

**Tests:**
- `Tests/ConnectionManagerTests.swift` — rewrite as ConnectionController tests. Backoff and data extraction tests stay similar. Add state transition tests.

## Key Design Decisions

1. **Single class, not split into transport + controller.** BLE and state machine are tightly coupled. Splitting adds an interface boundary that doesn't carry its weight for a single-device app.
2. **Serial DispatchQueue, not Swift Actor.** CB requires a specific queue for its delegate. Actors don't let you specify their executor cleanly, and Session's blocking thread model doesn't mix well with async/await.
3. **Session is a black box.** No changes to Session internals. Only changes are instantiation, threading (adapter pattern), and callback routing.
4. **Pairing as states in the enum, not a separate flow.** Avoids coordination logic between two state machines sharing the same BLE hardware.
5. **Generation counter, not peripheral identity checks.** Peripheral objects can be reused by CoreBluetooth across power cycles. Generation is monotonic and unambiguous.
6. **os.Logger with privacy: .public, not NSLog.** Follows Apple's recommended practice. Privacy annotations were the likely cause of invisible logs in release builds.
7. **Delegate callbacks dispatched to main.** AppDelegate never handles threading.
