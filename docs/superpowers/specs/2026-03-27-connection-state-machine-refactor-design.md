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

States carry their owned objects (peripheral, session, token) directly. No separate instance variables for tracked objects.

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

Stream scheduling follows the same pattern as today: streams opened on the connection queue (in `didOpen`), removed, then rescheduled on the session thread's RunLoop before handshake.

### Pairing

Pairing uses dedicated states in the same enum rather than a separate flow. Discovery branches based on whether `pairingTag` is set:

- If pairing: `scanning → pairingConnecting → pairingL2CAP → pairingHandshake → handshaking → ready`
- If normal: `scanning → bleConnecting → l2capOpening → handshaking → ready`

Both paths converge at `handshaking` (since the pairing handshake transitions into a normal HELLO/WELCOME handshake within the same Session). One state machine, no coordination logic between separate flows.

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
}
```

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

### Dedup & Pending Clipboard

ConnectionController owns dedup state (`lastReceivedTextHash`, `lastReceivedImageHash`) and `pendingClipboard`. Dedup is checked before notifying the delegate. Pending clipboard is sent automatically when session becomes ready. AppDelegate does not touch any of this.

### Reconnection & Health Checks

Same logic as the current implementation:

- **Reconnection:** Exponential backoff 1s → 2s → 4s → 8s → 16s → 30s cap. Reset on successful connection or BT power-on. Uses `DispatchSourceTimer` on the connection queue.
- **Health check:** 60s repeating timer. Detects stuck connecting states (15s timeout), cycles stale scans, recovers idle states with no active reconnect. Uses `DispatchSourceTimer` on the connection queue.

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
- `Sources/BLE/ConnectionController.swift` (~500 lines) — unified state machine

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
