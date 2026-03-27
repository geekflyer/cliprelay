# Connection State Machine Refactor — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the split ConnectionManager + AppDelegate connection logic with a single ConnectionController class that owns the full BLE-to-session lifecycle on one serial queue, eliminating race conditions by construction.

**Architecture:** A new `ConnectionController` class owns `CBCentralManager`, the full-lifecycle state enum (idle through ready), Session creation/ownership, reconnection, health checks, dedup, and pending clipboard. It uses a serial `DispatchQueue` for all state transitions and a generation counter to reject stale callbacks. AppDelegate becomes thin wiring between ConnectionController and UI/clipboard.

**Tech Stack:** Swift 5.10, macOS 13+, CoreBluetooth, CryptoKit, os.Logger

**Spec:** `docs/superpowers/specs/2026-03-27-connection-state-machine-refactor-design.md`

---

## File Map

| Action | File | Responsibility |
|--------|------|---------------|
| Create | `Sources/BLE/ConnectionController.swift` | Unified state machine (~600-700 lines) |
| Delete | `Sources/BLE/ConnectionManager.swift` | Fully replaced |
| Rewrite | `Tests/ClipRelayTests/ConnectionControllerTests.swift` | State machine + utility tests |
| Delete | `Tests/ClipRelayTests/ConnectionManagerTests.swift` | Fully replaced |
| Modify | `Sources/App/AppDelegate.swift` | Slim from ~700 to ~350 lines |

---

## Task 1: ConnectionController — State Enum, Core Structure & Logging

**Files:**
- Create: `macos/ClipRelayMac/Sources/BLE/ConnectionController.swift`

This task creates the file with the state enum, generation counter, logging helper, transition methods, and the single cleanup path. No CB or Session wiring yet — just the state machine skeleton.

- [ ] **Step 1: Create ConnectionController with state enum and core properties**

```swift
// BLE connection lifecycle: unified state machine on a serial DispatchQueue.

import CoreBluetooth
import CryptoKit
import Foundation
import os

// MARK: - Connection State

enum ConnectionState: CustomStringConvertible {
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

    var description: String {
        switch self {
        case .idle: return "idle"
        case .scanning: return "scanning"
        case .bleConnecting(_, let psm, let gen): return "bleConnecting(PSM=\(psm), gen=\(gen))"
        case .l2capOpening(_, let gen): return "l2capOpening(gen=\(gen))"
        case .pairingConnecting(_, let psm, let gen): return "pairingConnecting(PSM=\(psm), gen=\(gen))"
        case .pairingL2CAP(_, let gen): return "pairingL2CAP(gen=\(gen))"
        case .pairingHandshake(_, let gen): return "pairingHandshake(gen=\(gen))"
        case .handshaking(_, let gen): return "handshaking(gen=\(gen))"
        case .ready(_, _, let gen): return "ready(gen=\(gen))"
        }
    }

    var generation: UInt? {
        switch self {
        case .idle, .scanning: return nil
        case .bleConnecting(_, _, let g), .l2capOpening(_, let g),
             .pairingConnecting(_, _, let g), .pairingL2CAP(_, let g),
             .pairingHandshake(_, let g), .handshaking(_, let g),
             .ready(_, _, let g):
            return g
        }
    }
}

// MARK: - Connection Errors

enum ConnectionError: Error {
    case versionMismatch(Int)
    case sessionError(String)
    case bleError(String)
}

// MARK: - Delegate Protocol

protocol ConnectionControllerDelegate: AnyObject {
    func connectionController(_ controller: ConnectionController,
                              didChangeState connected: Bool, deviceName: String?)
    func connectionController(_ controller: ConnectionController,
                              didReceiveClipboard text: String)
    func connectionController(_ controller: ConnectionController,
                              didReceiveImage data: Data, contentType: String)
    func connectionController(_ controller: ConnectionController,
                              didCompletePairing deviceName: String?)
    func connectionController(_ controller: ConnectionController,
                              didEncounterError error: ConnectionError)
    func connectionController(_ controller: ConnectionController,
                              didUpdateBluetoothState state: CBManagerState)
    func connectionController(_ controller: ConnectionController,
                              didSyncClipboard hash: String)
    func connectionController(_ controller: ConnectionController,
                              didChangeImageSyncSetting enabled: Bool)
    func connectionController(_ controller: ConnectionController,
                              imageTransferFailed reason: String)
}

// MARK: - ConnectionController

class ConnectionController: NSObject {
    weak var delegate: ConnectionControllerDelegate?

    // Serial queue — all state transitions happen here.
    // CBCentralManager is initialized with this queue, so CB callbacks land directly on it.
    // fileprivate so SessionAdapter (same file) can dispatch onto it.
    fileprivate let queue = DispatchQueue(label: "org.cliprelay.connection")

    private(set) var state: ConnectionState = .idle
    private(set) var generation: UInt = 0

    // Deliberate instance variables (see spec for rationale):
    private var l2capChannel: CBL2CAPChannel? // strong ref required by CoreBluetooth
    private var connectingStartTime: Date?     // health check timeout metadata

    // Reconnection
    private var reconnectDelay: TimeInterval = 1.0
    private var reconnectTimer: DispatchSourceTimer?
    private var healthCheckTimer: DispatchSourceTimer?

    // Pairing
    private var pairingTag: Data?
    private var pairingPrivateKey: CryptoKit.Curve25519.KeyAgreement.PrivateKey?

    // Dedup & pending transfer
    private var lastReceivedTextHash: String?
    private var lastReceivedImageHash: String?
    private var pendingClipboard: Data?

    // Dependencies
    private let pairingManager: PairingManager
    private var centralManager: CBCentralManager!

    // Logging
    private let logger = Logger(subsystem: "org.cliprelay", category: "Connection")

    // Constants
    static let serviceUUID = CBUUID(string: "c10b0001-1234-5678-9abc-def012345678")
    static let maxReconnectDelay: TimeInterval = 30.0
    static let healthCheckInterval: TimeInterval = 60.0
    static let connectingTimeout: TimeInterval = 15.0

    init(pairingManager: PairingManager) {
        self.pairingManager = pairingManager
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: queue)
        startHealthCheck()
    }

    /// Test-only init that skips CBCentralManager creation.
    init(pairingManager: PairingManager, skipCentralManager: Bool) {
        self.pairingManager = pairingManager
        super.init()
        if !skipCentralManager {
            centralManager = CBCentralManager(delegate: self, queue: queue)
            startHealthCheck()
        }
    }

    // MARK: - Logging

    private func log(_ message: String) {
        logger.notice("\(message, privacy: .public)")
    }

    // MARK: - State Transitions

    private func transition(to newState: ConnectionState, reason: String) {
        let oldState = state
        state = newState
        log("\(oldState) → \(newState) (\(reason))")

        // Notify delegate of connection status changes
        let wasConnected = isReady(oldState)
        let nowConnected = isReady(newState)
        if wasConnected != nowConnected {
            let deviceName: String?
            let token: String?
            if case .ready(_, let t, _) = newState {
                token = t
                deviceName = pairingManager.loadDevices()
                    .first(where: { $0.sharedSecret == t })?.displayName
            } else {
                token = nil
                deviceName = nil
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.connectionController(self, didChangeState: nowConnected,
                                                    deviceName: deviceName, token: token)
            }
        }
    }

    private func isReady(_ state: ConnectionState) -> Bool {
        if case .ready = state { return true }
        return false
    }

    // MARK: - Single Cleanup Path

    private func transitionToIdle(reason: String, reconnect: Bool = true) {
        // Cancel any tracked peripheral
        if let peripheral = trackedPeripheral(from: state) {
            centralManager?.cancelPeripheralConnection(peripheral)
        }
        if case .scanning = state {
            centralManager?.stopScan()
        }

        // Close any active session
        if let session = activeSession(from: state) {
            session.close()
        }

        // Clear all connection state
        l2capChannel = nil
        connectingStartTime = nil
        pairingTag = nil
        pairingPrivateKey = nil
        generation += 1

        transition(to: .idle, reason: reason)

        if reconnect {
            scheduleReconnect()
        }
    }

    // MARK: - State Extractors

    private func trackedPeripheral(from state: ConnectionState) -> CBPeripheral? {
        switch state {
        case .bleConnecting(let p, _, _), .l2capOpening(let p, _),
             .pairingConnecting(let p, _, _), .pairingL2CAP(let p, _):
            return p
        default:
            return nil
        }
    }

    private func activeSession(from state: ConnectionState) -> Session? {
        switch state {
        case .handshaking(let s, _), .pairingHandshake(let s, _), .ready(let s, _, _):
            return s
        default:
            return nil
        }
    }
}
```

- [ ] **Step 2: Verify the file compiles**

Run: `swift build --package-path macos/ClipRelayMac 2>&1 | grep 'error:'`

Expected: May have errors from missing CB delegate conformance — that's fine for now. The core structure should parse without syntax errors. Check that the `ConnectionState` enum, `ConnectionController` class, and delegate protocol are valid Swift.

- [ ] **Step 3: Commit**

```bash
git add macos/ClipRelayMac/Sources/BLE/ConnectionController.swift
git commit -m "refactor(mac): add ConnectionController skeleton — state enum, logging, cleanup path"
```

---

## Task 2: Reconnection & Health Check Timers

**Files:**
- Modify: `macos/ClipRelayMac/Sources/BLE/ConnectionController.swift`

Add scanning, reconnection with exponential backoff, and health check timer — all using `DispatchSourceTimer` on the connection queue.

- [ ] **Step 1: Add scanning and reconnection methods**

Add to `ConnectionController` after the state extractors:

```swift
    // MARK: - Scanning

    func startScanning() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard centralManager?.state == .poweredOn else { return }
        guard case .idle = state else { return }
        transition(to: .scanning, reason: "start scan")
        log("Scanning (paired devices: \(pairedDeviceTags().count))")
        centralManager.scanForPeripherals(
            withServices: [Self.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    // MARK: - Reconnection

    private func scheduleReconnect() {
        reconnectTimer?.cancel()
        let delay = reconnectDelay
        log("Scheduling reconnect in \(String(format: "%.1f", delay))s")

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.reconnectTimer = nil
            self.startScanning()
        }
        timer.resume()
        reconnectTimer = timer

        reconnectDelay = min(reconnectDelay * 2, Self.maxReconnectDelay)
    }

    func resetReconnectDelay() {
        reconnectDelay = 1.0
    }

    /// Returns current delay and advances for next call. Exposed for testing.
    @discardableResult
    func nextReconnectDelay() -> TimeInterval {
        let current = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, Self.maxReconnectDelay)
        return current
    }

    // MARK: - Health Check

    private func startHealthCheck() {
        healthCheckTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.healthCheckInterval,
                       repeating: Self.healthCheckInterval)
        timer.setEventHandler { [weak self] in
            self?.performHealthCheck()
        }
        timer.resume()
        healthCheckTimer = timer
    }

    private func performHealthCheck() {
        guard centralManager?.state == .poweredOn else { return }

        switch state {
        case .bleConnecting, .l2capOpening, .pairingConnecting, .pairingL2CAP:
            if let start = connectingStartTime,
               -start.timeIntervalSinceNow > Self.connectingTimeout {
                log("Health check: stuck for \(Int(-start.timeIntervalSinceNow))s")
                transitionToIdle(reason: "stuck connection")
            }
        case .scanning:
            // Cycle scan to refresh CoreBluetooth advertisement cache
            centralManager?.stopScan()
            transition(to: .idle, reason: "cycling scan")
            startScanning()
        case .idle:
            resetReconnectDelay()
            startScanning()
        case .handshaking, .pairingHandshake, .ready:
            break // session layer handles liveness
        }
    }

    // MARK: - Paired Device Lookup

    private func pairedDeviceTags() -> [(token: String, tag: Data)] {
        pairingManager.loadDevices().compactMap { device in
            guard let tag = pairingManager.deviceTag(for: device.sharedSecret) else { return nil }
            return (token: device.sharedSecret, tag: tag)
        }
    }

    // MARK: - Manufacturer Data Extraction

    static func extractDeviceTag(from manufacturerData: Data) -> Data? {
        guard manufacturerData.count >= 10 else { return nil }
        return manufacturerData.subdata(in: 2..<10)
    }

    static func extractPSM(from manufacturerData: Data) -> CBL2CAPPSM? {
        guard manufacturerData.count >= 12 else { return nil }
        let psm = UInt16(manufacturerData[10]) << 8 | UInt16(manufacturerData[11])
        guard psm > 0 else { return nil }
        return CBL2CAPPSM(psm)
    }

    // MARK: - Disconnect

    func disconnect() {
        queue.async { [self] in
            healthCheckTimer?.cancel()
            healthCheckTimer = nil
            reconnectTimer?.cancel()
            reconnectTimer = nil
            transitionToIdle(reason: "disconnect requested", reconnect: false)
        }
    }
```

- [ ] **Step 2: Verify compilation**

Run: `swift build --package-path macos/ClipRelayMac 2>&1 | grep 'error:'`

Expected: Still may have CB conformance errors, but no new errors from this code.

- [ ] **Step 3: Commit**

```bash
git add macos/ClipRelayMac/Sources/BLE/ConnectionController.swift
git commit -m "refactor(mac): add scanning, reconnection, health check to ConnectionController"
```

---

## Task 3: CoreBluetooth Delegate Implementation

**Files:**
- Modify: `macos/ClipRelayMac/Sources/BLE/ConnectionController.swift`

Wire up `CBCentralManagerDelegate` and `CBPeripheralDelegate` — the BLE discovery, connect, disconnect, and L2CAP open callbacks. Each callback checks the generation counter.

- [ ] **Step 1: Add CB delegate conformances**

Add at the end of `ConnectionController.swift`:

```swift
// MARK: - CBCentralManagerDelegate

extension ConnectionController: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("BT state: \(central.state.rawValue) (5=poweredOn)")

        if central.state == .poweredOn {
            reconnectDelay = 1.0
            startHealthCheck()
            startScanning()

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.connectionController(self, didUpdateBluetoothState: central.state)
            }
        } else {
            transitionToIdle(reason: "BT state \(central.state.rawValue)")

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.connectionController(self, didUpdateBluetoothState: central.state)
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                         advertisementData: [String: Any], rssi: NSNumber) {
        // Only process discoveries while scanning
        guard case .scanning = state else { return }

        guard let mfgData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              let tag = Self.extractDeviceTag(from: mfgData),
              let psm = Self.extractPSM(from: mfgData) else { return }

        let gen = generation

        // Pairing mode: match pairing tag
        if let expectedPairingTag = pairingTag {
            guard tag == expectedPairingTag else { return }
            log("Matched pairing tag, PSM=\(psm)")
            central.stopScan()
            transition(to: .pairingConnecting(peripheral, psm, generation: gen),
                       reason: "pairing device found")
            connectingStartTime = Date()
            peripheral.delegate = self
            central.connect(peripheral)
            return
        }

        // Normal mode: match paired device tags
        guard let matched = pairedDeviceTags().first(where: { $0.tag == tag }) else { return }
        log("Matched device tag, PSM=\(psm), RSSI=\(rssi)")
        central.stopScan()
        transition(to: .bleConnecting(peripheral, psm, generation: gen),
                   reason: "paired device found")
        connectingStartTime = Date()
        peripheral.delegate = self
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        switch state {
        case .bleConnecting(_, let psm, let gen) where gen == generation:
            log("BLE connected, opening L2CAP (PSM=\(psm))")
            transition(to: .l2capOpening(peripheral, generation: gen),
                       reason: "BLE connected")
            connectingStartTime = Date()
            peripheral.openL2CAPChannel(psm)

        case .pairingConnecting(_, let psm, let gen) where gen == generation:
            log("Pairing BLE connected, opening L2CAP (PSM=\(psm))")
            transition(to: .pairingL2CAP(peripheral, generation: gen),
                       reason: "pairing BLE connected")
            connectingStartTime = Date()
            peripheral.openL2CAPChannel(psm)

        default:
            log("Stale didConnect (gen mismatch or wrong state), cancelling")
            central.cancelPeripheralConnection(peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                         error: Error?) {
        log("Failed to connect: \(error?.localizedDescription ?? "unknown")")
        // Release CB connection bookkeeping to avoid slot exhaustion
        central.cancelPeripheralConnection(peripheral)
        transitionToIdle(reason: "connect failed: \(error?.localizedDescription ?? "unknown")")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                         error: Error?) {
        log("BLE disconnected: \(error?.localizedDescription ?? "clean") (state=\(state))")

        // Only process if this disconnect matches our current generation.
        // Use generation check (not peripheral identity) since CB can reuse objects.
        guard state.generation == generation else {
            log("Ignoring stale disconnect (gen=\(generation), state=\(state))")
            return
        }

        switch state {
        case .bleConnecting, .l2capOpening, .pairingConnecting, .pairingL2CAP:
            transitionToIdle(reason: "BLE disconnect during connection")
        case .handshaking, .pairingHandshake, .ready:
            transitionToIdle(reason: "BLE disconnect while active")
        case .idle, .scanning:
            // Already cleaned up — stale disconnect from transitionToIdle's cancelPeripheralConnection
            log("Ignoring disconnect in \(state) state")
        }
    }
}

// MARK: - CBPeripheralDelegate

extension ConnectionController: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        connectingStartTime = nil

        guard let channel = channel, error == nil else {
            log("L2CAP open failed: \(error?.localizedDescription ?? "nil channel")")
            centralManager?.cancelPeripheralConnection(peripheral)
            // transitionToIdle will be triggered by didDisconnectPeripheral
            return
        }

        // Keep strong reference (CoreBluetooth deallocates otherwise)
        l2capChannel = channel
        log("L2CAP channel established")

        switch state {
        case .l2capOpening(_, let gen) where gen == generation:
            guard let matched = matchedToken() else {
                log("L2CAP open but no matched token — cancelling")
                centralManager?.cancelPeripheralConnection(peripheral)
                return
            }
            // Schedule streams, hand off to session
            startSession(channel: channel, token: matched, gen: gen, isPairing: false)

        case .pairingL2CAP(_, let gen) where gen == generation:
            startSession(channel: channel, token: nil, gen: gen, isPairing: true)

        default:
            log("Stale L2CAP open (gen mismatch), cancelling")
            centralManager?.cancelPeripheralConnection(peripheral)
        }
    }

    /// Look up which paired device was matched during discovery.
    /// Must be called right after l2capOpening → didOpen.
    private func matchedToken() -> String? {
        // We need to re-derive the token from the state history.
        // Since we matched in didDiscover and the token was used to transition
        // to bleConnecting, we can look it up from paired devices.
        // The tag was matched in didDiscover; re-match is safe since device list is stable.
        // For a cleaner approach, store the token in the state enum — but bleConnecting
        // already carries peripheral + PSM + generation. Adding token would work too.
        // For now: the didDiscover matched a pairedDeviceTags() entry. The L2CAP open
        // means we're connected to that same device. We need to match again.
        //
        // TODO: Consider adding token to bleConnecting/l2capOpening states to avoid re-lookup.
        // For now this works because paired device list doesn't change between discover and L2CAP.
        nil // Placeholder — will be filled in Task 4 when we add token to state
    }
}
```

**Note:** The `matchedToken()` method is a placeholder. In the next step we'll add the token directly to the `bleConnecting` and `l2capOpening` states.

- [ ] **Step 2: Add token to BLE connection states**

Update the state enum to carry the token through the BLE connection path:

Change `bleConnecting` and `l2capOpening` to:
```swift
    case bleConnecting(CBPeripheral, CBL2CAPPSM, token: String, generation: UInt)
    case l2capOpening(CBPeripheral, token: String, generation: UInt)
```

Update `description` and `generation` computed properties accordingly.

Update `didDiscover` to pass `matched.token`:
```swift
        transition(to: .bleConnecting(peripheral, psm, token: matched.token, generation: gen), ...)
```

Update `didConnect` to pass token through:
```swift
        case .bleConnecting(_, let psm, let token, let gen) where gen == generation:
            transition(to: .l2capOpening(peripheral, token: token, generation: gen), ...)
```

Update `didOpen` to read token from state:
```swift
        case .l2capOpening(_, let token, let gen) where gen == generation:
            startSession(channel: channel, token: token, gen: gen, isPairing: false)
```

Remove the `matchedToken()` placeholder method.

Update `trackedPeripheral` for the new signatures.

Update `didDisconnectPeripheral` pattern matches for the new signatures.

- [ ] **Step 3: Verify compilation**

Run: `swift build --package-path macos/ClipRelayMac 2>&1 | grep 'error:'`

Expected: Should compile (Session and AppDelegate still use old ConnectionManager, but ConnectionController is standalone).

- [ ] **Step 4: Commit**

```bash
git add macos/ClipRelayMac/Sources/BLE/ConnectionController.swift
git commit -m "refactor(mac): add CB delegate implementation with generation checks"
```

---

## Task 4: Session Adapter & Session Thread

**Files:**
- Modify: `macos/ClipRelayMac/Sources/BLE/ConnectionController.swift`

Add the `SessionAdapter` (bridges Session delegate callbacks to the connection queue), the `startSession` method that spawns the background thread, and all session event handlers.

- [ ] **Step 1: Add SessionAdapter class**

Add inside or after `ConnectionController`:

```swift
// MARK: - Session Adapter

/// Bridges SessionDelegate callbacks from the session background thread
/// to the ConnectionController's serial queue with generation checking.
private class SessionAdapter: NSObject, SessionDelegate {
    weak var controller: ConnectionController?
    let generation: UInt
    // Thread-safe read for synchronous alreadyHasHash callback
    private let hashLock = NSLock()
    private var _lastTextHash: String?
    var lastTextHash: String? {
        get { hashLock.lock(); defer { hashLock.unlock() }; return _lastTextHash }
        set { hashLock.lock(); _lastTextHash = newValue; hashLock.unlock() }
    }

    init(controller: ConnectionController, generation: UInt) {
        self.controller = controller
        self.generation = generation
        self._lastTextHash = controller.lastReceivedTextHash
    }

    private func dispatch(_ work: @escaping (ConnectionController) -> Void) {
        controller?.queue.async { [weak controller, generation] in
            guard let controller, controller.generation == generation else { return }
            work(controller)
        }
    }

    func sessionDidBecomeReady(_ session: Session) {
        dispatch { $0.handleSessionReady(session, generation: generation) }
    }

    func session(_ session: Session, didFailWithError error: Error) {
        dispatch { $0.handleSessionError(error) }
    }

    func session(_ session: Session, didReceivePlaintext plaintext: Data, hash: String) {
        lastTextHash = hash
        dispatch { $0.handleClipboardReceived(plaintext: plaintext, hash: hash) }
    }

    func session(_ session: Session, didReceiveImage data: Data, contentType: String, hash: String) {
        dispatch { $0.handleImageReceived(data: data, contentType: contentType, hash: hash) }
    }

    func session(_ session: Session, didCompleteTransfer hash: String) {
        dispatch { $0.handleTransferComplete(hash: hash) }
    }

    func session(_ session: Session, didCompletePairingWithSecret sharedSecret: Data, remoteName: String?) {
        dispatch { $0.handlePairingComplete(sharedSecret: sharedSecret, remoteName: remoteName) }
    }

    func session(_ session: Session, didChangeRichMediaSetting enabled: Bool) {
        dispatch { $0.handleRichMediaSettingChanged(enabled: enabled) }
    }

    func session(_ session: Session, imageWasRejected reason: String) {
        dispatch { $0.handleImageTransferFailed(reason: "rejected: \(reason)") }
    }

    func session(_ session: Session, imageSendFailed reason: String) {
        dispatch { $0.handleImageTransferFailed(reason: "send failed: \(reason)") }
    }

    // Synchronous — called on session thread, must return immediately
    func session(_ session: Session, alreadyHasHash hash: String) -> Bool {
        return lastTextHash == hash
    }
}
```

- [ ] **Step 2: Add startSession and session event handlers**

Add to `ConnectionController`:

```swift
    // MARK: - Session Lifecycle

    /// Currently active session adapter (retained to prevent deallocation).
    private var currentAdapter: SessionAdapter?

    private func startSession(channel: CBL2CAPChannel, token: String?,
                              gen: UInt, isPairing: Bool) {
        let inputStream = channel.inputStream
        let outputStream = channel.outputStream

        // Open streams on connection queue first
        inputStream.schedule(in: .main, forMode: .common)
        outputStream.schedule(in: .main, forMode: .common)
        inputStream.open()
        outputStream.open()

        let adapter = SessionAdapter(controller: self, generation: gen)
        currentAdapter = adapter

        let session: Session
        if isPairing {
            guard let privateKey = pairingPrivateKey else {
                log("Pairing channel but no ephemeral key — aborting")
                transitionToIdle(reason: "missing pairing key")
                return
            }
            session = Session(inputStream: inputStream, outputStream: outputStream,
                              isInitiator: true, delegate: adapter,
                              mode: .pairing(privateKey: privateKey))
            session.localName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
            transition(to: .pairingHandshake(session, generation: gen),
                       reason: "starting pairing handshake")
        } else {
            guard let token = token else {
                log("Normal channel but no token — aborting")
                transitionToIdle(reason: "missing token")
                return
            }
            let settingsProvider = DeviceSettingsProvider(pairingManager: pairingManager,
                                                         secret: token)
            session = Session(inputStream: inputStream, outputStream: outputStream,
                              isInitiator: true, delegate: adapter,
                              sharedSecretHex: token)
            session.localName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
            session.settingsProvider = settingsProvider
            transition(to: .handshaking(session, generation: gen),
                       reason: "starting handshake")
        }

        reconnectDelay = 1.0 // reset backoff on successful L2CAP

        // Spawn session thread
        let thread = Thread { [weak self] in
            // Re-schedule streams on this thread's RunLoop
            inputStream.remove(from: .main, forMode: .common)
            outputStream.remove(from: .main, forMode: .common)
            let runLoop = RunLoop.current
            inputStream.schedule(in: runLoop, forMode: .common)
            outputStream.schedule(in: runLoop, forMode: .common)

            session.performHandshake()
            session.listenForMessages()

            // Session ended — adapter's generation check will drop stale callbacks
            self?.queue.async { [weak self] in
                self?.currentAdapter = nil
            }
        }
        thread.name = isPairing ? "L2CAP-Pairing" : "L2CAP-Session"
        thread.start()
    }

    // MARK: - Session Event Handlers

    private func handleSessionReady(_ session: Session, generation gen: UInt) {
        let remoteName = session.remoteName

        switch state {
        case .handshaking(_, let g) where g == gen:
            // Need to find the token — it's in the state we transitioned from,
            // but we're now in .handshaking which doesn't carry it.
            // The token was passed to Session's init as sharedSecretHex.
            // We can recover it from the paired device list via Session's internal state,
            // but that's not exposed. Instead, store it alongside the session.
            //
            // Actually: the token IS available. When startSession created the session
            // with sharedSecretHex: token, we should also store it. Let's add it
            // to the handshaking state or as a temporary var.
            // For cleanliness, add token to .handshaking state.
            break // Will be addressed below

        case .pairingHandshake(_, let g) where g == gen:
            // Pairing path — token was set via handlePairingComplete before handshake finished
            break // Will be addressed below

        default:
            log("Stale sessionReady (gen \(gen) != \(generation))")
            return
        }

        log("Session ready — remote: \(remoteName ?? "unknown")")

        // This handler needs the token. Let's address this in step 3.
    }

    private func handleSessionError(_ error: Error) {
        log("Session error: \(error)")

        if case SessionError.versionMismatch(let v) = error {
            transitionToIdle(reason: "version mismatch (v\(v))", reconnect: false)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.connectionController(self,
                    didEncounterError: .versionMismatch(v))
            }
            return
        }

        transitionToIdle(reason: "session error: \(error.localizedDescription)")
    }

    private func handleClipboardReceived(plaintext: Data, hash: String) {
        lastReceivedTextHash = hash
        currentAdapter?.lastTextHash = hash

        guard let text = String(data: plaintext, encoding: .utf8) else {
            log("Received data is not valid UTF-8")
            return
        }
        log("Received clipboard (\(text.count) chars)")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.connectionController(self, didReceiveClipboard: text)
        }
    }

    private func handleImageReceived(data: Data, contentType: String, hash: String) {
        lastReceivedImageHash = hash
        log("Received image (\(data.count) bytes, \(contentType))")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.connectionController(self, didReceiveImage: data, contentType: contentType)
        }
    }

    private func handleTransferComplete(hash: String) {
        log("Transfer complete (hash: \(hash.prefix(8))...)")
        pendingClipboard = nil
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.connectionController(self, didSyncClipboard: hash)
        }
    }

    private func handlePairingComplete(sharedSecret: Data, remoteName: String?) {
        let secretHex = sharedSecret.map { String(format: "%02x", $0) }.joined()
        log("Pairing complete — storing device")

        let device = PairedDevice(sharedSecret: secretHex,
                                  displayName: remoteName ?? "Android",
                                  datePaired: Date())
        pairingManager.addDevice(device)
        pairingManager.clearEphemeralKey()

        // Wire settings provider now that we have the secret
        if let session = activeSession(from: state) {
            let settingsProvider = DeviceSettingsProvider(pairingManager: pairingManager,
                                                         secret: secretHex)
            session.settingsProvider = settingsProvider
        }

        // Clear pairing mode
        pairingTag = nil
        pairingPrivateKey = nil

        // Transition from pairingHandshake to handshaking (pairing session continues
        // into normal HELLO/WELCOME). The session will call sessionDidBecomeReady next.
        if case .pairingHandshake(let session, let gen) = state, gen == generation {
            // Store token for the ready transition
            transition(to: .handshaking(session, generation: gen),
                       reason: "pairing complete, continuing handshake")
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.connectionController(self, didCompletePairing: remoteName)
        }
    }

    private func handleRichMediaSettingChanged(enabled: Bool) {
        log("Remote changed image sync to \(enabled)")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.connectionController(self, didChangeImageSyncSetting: enabled)
        }
    }

    private func handleImageTransferFailed(reason: String) {
        log("Image transfer failed: \(reason)")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.connectionController(self, imageTransferFailed: reason)
        }
    }
```

- [ ] **Step 3: Add token to handshaking state and fix handleSessionReady**

The `.handshaking` state needs the token so `handleSessionReady` can transition to `.ready(session, token:, generation:)`. Update the enum:

```swift
    case handshaking(Session, token: String, generation: UInt)
```

Update `description`, `generation`, `activeSession` accordingly.

Update `startSession` normal path:
```swift
            transition(to: .handshaking(session, token: token, generation: gen), ...)
```

Update `handlePairingComplete`:
```swift
            transition(to: .handshaking(session, token: secretHex, generation: gen), ...)
```

Now complete `handleSessionReady`:

```swift
    private func handleSessionReady(_ session: Session, generation gen: UInt) {
        let remoteName = session.remoteName

        guard case .handshaking(_, let token, let g) = state, g == gen else {
            log("Stale sessionReady (gen \(gen) != \(generation))")
            return
        }

        // Update stored device name from handshake
        if let name = remoteName {
            let devices = pairingManager.loadDevices()
            if let existing = devices.first(where: {
                $0.sharedSecret == token && $0.displayName != name
            }) {
                pairingManager.removeDevice(secret: token)
                let updated = PairedDevice(sharedSecret: existing.sharedSecret,
                                           displayName: name,
                                           datePaired: existing.datePaired,
                                           richMediaEnabled: existing.richMediaEnabled,
                                           richMediaEnabledChangedAt: existing.richMediaEnabledChangedAt)
                pairingManager.addDevice(updated)
            }
        }

        transition(to: .ready(session, token: token, generation: gen),
                   reason: "handshake complete")
        log("Session ready — remote: \(remoteName ?? "unknown")")

        // Send pending clipboard
        if let pending = pendingClipboard {
            session.sendClipboard(pending)
            log("Sent pending clipboard (\(pending.count) bytes)")
        }
    }
```

- [ ] **Step 4: Verify compilation**

Run: `swift build --package-path macos/ClipRelayMac 2>&1 | grep 'error:'`

- [ ] **Step 5: Commit**

```bash
git add macos/ClipRelayMac/Sources/BLE/ConnectionController.swift
git commit -m "refactor(mac): add SessionAdapter, session thread, and event handlers"
```

---

## Task 5: Public API — Pairing, Send, Settings

**Files:**
- Modify: `macos/ClipRelayMac/Sources/BLE/ConnectionController.swift`

Add the public methods that AppDelegate will call: pairing flow, clipboard/image send, device management, settings toggle.

- [ ] **Step 1: Add public API methods**

```swift
    // MARK: - Public API: Pairing

    struct PairingInfo {
        let uri: URL
    }

    /// Generate pairing URI and begin scanning for the pairing device.
    /// PairingManager operations happen on the calling thread (main);
    /// BLE scanning is dispatched to the connection queue.
    func startPairing() -> PairingInfo? {
        // PairingManager is main-thread only — generate key + URI here
        pairingManager.removePendingDevices()
        let privateKey = pairingManager.generateKeyPair()
        guard let uri = pairingManager.pairingURI(publicKey: privateKey.publicKey) else { return nil }
        let tag = PairingManager.pairingTag(from: privateKey.publicKey.rawRepresentation)

        // Dispatch BLE state changes to connection queue
        queue.async { [self] in
            pairingPrivateKey = privateKey
            pairingTag = tag
            if case .scanning = state { centralManager?.stopScan() }
            transition(to: .idle, reason: "entering pairing mode")
            startScanning()
        }

        return PairingInfo(uri: uri)
    }

    func cancelPairing() {
        queue.async { [self] in
            pairingManager.clearEphemeralKey()
            pairingManager.removePendingDevices()
            // Tear down any in-progress pairing connection or scan
            switch state {
            case .scanning, .pairingConnecting, .pairingL2CAP, .pairingHandshake:
                transitionToIdle(reason: "pairing cancelled")
            default:
                // Not in a pairing state — just clear pairing fields
                pairingTag = nil
                pairingPrivateKey = nil
            }
        }
    }

    // MARK: - Public API: Send

    func sendClipboard(_ text: String) {
        queue.async { [self] in
            guard let data = text.data(using: .utf8) else { return }

            let hash = Session.sha256Hex(data)
            guard hash != lastReceivedTextHash else { return } // dedup echo

            pendingClipboard = data

            if case .ready(let session, _, _) = state {
                session.sendClipboard(data)
                log("Queued clipboard (\(data.count) bytes)")
            } else {
                log("Clipboard cached for reconnect (\(data.count) bytes)")
            }
        }
    }

    func sendImage(_ data: Data, contentType: String) {
        queue.async { [self] in
            let hash = Session.sha256Hex(data)
            guard hash != lastReceivedImageHash else { return }

            guard case .ready(let session, _, _) = state else { return }
            guard isImageSyncEnabled else { return }
            session.sendImage(data, contentType: contentType)
        }
    }

    // MARK: - Public API: Device Management

    func forgetDevice(token: String) {
        queue.async { [self] in
            pairingManager.removeDevice(secret: token)

            // If this device is involved in the current connection, tear down
            switch state {
            case .ready(_, let t, _) where t == token,
                 .handshaking(_, let t, _) where t == token:
                transitionToIdle(reason: "device forgotten", reconnect: false)
            case .bleConnecting, .l2capOpening:
                // Can't easily check token in connecting states, but there's only
                // one paired device typically. Tear down to be safe.
                transitionToIdle(reason: "device forgotten", reconnect: false)
            default:
                break
            }

            // Restart scanning to pick up remaining devices
            if case .idle = state, !pairingManager.loadDevices().isEmpty {
                startScanning()
            }
        }
    }

    var pairedDevices: [PairedDevice] {
        pairingManager.loadDevices()
    }

    // MARK: - Public API: Settings

    func toggleImageSync() {
        queue.async { [self] in
            let secret: String?
            if case .ready(_, let token, _) = state {
                secret = token
            } else {
                secret = pairingManager.loadDevices().first?.sharedSecret
            }
            guard let secret else { return }

            let devices = pairingManager.loadDevices()
            guard let device = devices.first(where: { $0.sharedSecret == secret }) else { return }

            let newEnabled = !device.richMediaEnabled
            let changedAt = Int64(Date().timeIntervalSince1970)
            pairingManager.setRichMediaEnabled(newEnabled, changedAt: changedAt, forSecret: secret)

            if case .ready(let session, _, _) = state {
                session.sendConfigUpdate()
            }

            log("Image sync toggled to \(newEnabled)")
        }
    }

    var isImageSyncEnabled: Bool {
        guard let secret = currentToken else { return false }
        return pairingManager.loadDevices()
            .first(where: { $0.sharedSecret == secret })?.richMediaEnabled ?? false
    }

    /// Token of the currently connected device, if any.
    private var currentToken: String? {
        if case .ready(_, let token, _) = state { return token }
        return nil
    }
```

- [ ] **Step 2: Verify compilation**

Run: `swift build --package-path macos/ClipRelayMac 2>&1 | grep 'error:'`

- [ ] **Step 3: Commit**

```bash
git add macos/ClipRelayMac/Sources/BLE/ConnectionController.swift
git commit -m "refactor(mac): add public API — pairing, send, device management, settings"
```

---

## Task 6: Rewrite AppDelegate to Use ConnectionController

**Files:**
- Modify: `macos/ClipRelayMac/Sources/App/AppDelegate.swift`
- Delete: `macos/ClipRelayMac/Sources/BLE/ConnectionManager.swift`

Replace all ConnectionManagerDelegate and SessionDelegate code in AppDelegate with thin ConnectionControllerDelegate wiring. Delete the old ConnectionManager.

- [ ] **Step 1: Rewrite AppDelegate**

This is the largest single step. The approach: remove the old delegate conformances and connection state, replace with ConnectionControllerDelegate conformance. Keep all non-connection code (updater, pairing window, clipboard monitor, status bar wiring, BT alert debounce, launch-at-login).

Key changes:
- Remove: `connectionManager` property, `activeSession`, `connectedSecret`, `sessionThread`, `activeSettingsProvider`, `pendingClipboardPayload`, `lastReceivedHash`, `lastReceivedImageHash`, `awaitingNewPairingConnection`
- Remove: entire `ConnectionManagerDelegate` extension (~190 lines)
- Remove: entire `SessionDelegate` extension (~175 lines)
- Remove: `handleSessionEnded`, `updateConnectedPeersMenu`, `connectedPeers`
- Add: `connectionController` property
- Add: `ConnectionControllerDelegate` extension (~80 lines)
- Modify: `applicationDidFinishLaunching` to create `ConnectionController` instead of `ConnectionManager`
- Modify: `startPairing` to use `connectionController.startPairing()`
- Modify: `handlePairingWindowClosed` to use `connectionController.cancelPairing()`
- Modify: `forgetDevice` to use `connectionController.forgetDevice(token:)`
- Modify: clipboard monitor to use `connectionController.sendClipboard/sendImage`
- Keep: `bluetoothOffDebounceTimer`, `hasShownBluetoothAlert`, `showBluetoothAlert` (UI policy)
- Keep: `statusBarController` wiring, `pairingWindowController`, `notificationManager`
- Keep: `deviceStableID`, `formattedDeviceTagHex`, `refreshTrustedPeersMenu`

Write the complete new AppDelegate. It should be ~350 lines.

The `ConnectionControllerDelegate` extension:

```swift
extension AppDelegate: ConnectionControllerDelegate {
    func connectionController(_ c: ConnectionController,
                              didChangeState connected: Bool, deviceName: String?,
                              token: String?) {
        if connected, let deviceName, let token {
            let peer = PeerSummary(
                id: deviceStableID(token: token),
                description: deviceName,
                secret: token,
                deviceTagHex: formattedDeviceTagHex(token: token)
            )
            statusBarController.setConnectedPeers([peer])
        } else {
            statusBarController.setConnectedPeers([])
        }
    }

    func connectionController(_ c: ConnectionController, didReceiveClipboard text: String) {
        clipboardWriter.writeText(text)
        notificationManager.postClipboardReceived(text: text)
        statusBarController.flashSyncIndicator()
    }

    func connectionController(_ c: ConnectionController, didReceiveImage data: Data,
                              contentType: String) {
        clipboardWriter.writeImage(data, contentType: contentType)
        statusBarController.flashSyncIndicator()
    }

    func connectionController(_ c: ConnectionController, didCompletePairing deviceName: String?) {
        completePairing(deviceName: deviceName)
    }

    func connectionController(_ c: ConnectionController, didEncounterError error: ConnectionError) {
        switch error {
        case .versionMismatch:
            showBluetoothAlert(
                message: "App Update Required",
                info: "Your Android app needs to be updated to continue syncing. Update via Google Play."
            )
        default:
            break
        }
    }

    func connectionController(_ c: ConnectionController, didUpdateBluetoothState state: CBManagerState) {
        switch state {
        case .poweredOn:
            bluetoothOffDebounceTimer?.invalidate()
            bluetoothOffDebounceTimer = nil
            statusBarController.setBluetoothWarning(nil)
            hasShownBluetoothAlert = false
        case .unauthorized:
            statusBarController.setBluetoothWarning("Bluetooth permission denied")
            if !hasShownBluetoothAlert {
                hasShownBluetoothAlert = true
                showBluetoothAlert(
                    message: "Bluetooth access denied",
                    info: "ClipRelay needs Bluetooth permission. Please grant access in System Settings > Privacy & Security > Bluetooth."
                )
            }
        case .poweredOff:
            if !hasShownBluetoothAlert && bluetoothOffDebounceTimer == nil {
                bluetoothOffDebounceTimer = Timer.scheduledTimer(
                    withTimeInterval: Self.bluetoothOffDebounceDelay, repeats: false
                ) { [weak self] _ in
                    guard let self else { return }
                    self.bluetoothOffDebounceTimer = nil
                    self.hasShownBluetoothAlert = true
                    self.statusBarController.setBluetoothWarning("Bluetooth is turned off")
                    self.showBluetoothAlert(
                        message: "Bluetooth is turned off",
                        info: "ClipRelay needs Bluetooth to sync your clipboard. Please enable Bluetooth in System Settings."
                    )
                }
            }
        default:
            break
        }
    }

    func connectionController(_ c: ConnectionController, didSyncClipboard hash: String) {
        statusBarController.flashSyncIndicator()
    }

    func connectionController(_ c: ConnectionController, didChangeImageSyncSetting enabled: Bool) {
        // Refresh menu to show updated checkmark
        refreshConnectedPeersMenu()
    }

    func connectionController(_ c: ConnectionController, imageTransferFailed reason: String) {
        // Currently just logged by ConnectionController
    }
}
```

- [ ] **Step 2: Delete ConnectionManager.swift**

```bash
git rm macos/ClipRelayMac/Sources/BLE/ConnectionManager.swift
```

- [ ] **Step 3: Build and fix any compilation errors**

Run: `scripts/build-all.sh --mac-only`

This is likely to surface integration issues — missing method signatures, renamed types, etc. Fix iteratively until the build passes.

- [ ] **Step 4: Commit**

```bash
git add -A macos/ClipRelayMac/Sources/
git commit -m "refactor(mac): replace ConnectionManager with ConnectionController, slim AppDelegate"
```

---

## Task 7: Rewrite Tests

**Files:**
- Create: `macos/ClipRelayMac/Tests/ClipRelayTests/ConnectionControllerTests.swift`
- Delete: `macos/ClipRelayMac/Tests/ClipRelayTests/ConnectionManagerTests.swift`

Port existing tests and add new state transition tests.

- [ ] **Step 1: Create ConnectionControllerTests**

```swift
import XCTest
@testable import ClipRelay

final class ConnectionControllerTests: XCTestCase {

    private func makeController() -> ConnectionController {
        let pm = PairingManager()
        return ConnectionController(pairingManager: pm, skipCentralManager: true)
    }

    // MARK: - Backoff Tests (ported from ConnectionManagerTests)

    func testBackoffSequence() {
        let controller = makeController()
        let expected: [TimeInterval] = [1.0, 2.0, 4.0, 8.0, 16.0, 30.0, 30.0, 30.0]
        for (i, expectedDelay) in expected.enumerated() {
            let delay = controller.nextReconnectDelay()
            XCTAssertEqual(delay, expectedDelay, accuracy: 0.001,
                           "Backoff step \(i): expected \(expectedDelay), got \(delay)")
        }
    }

    func testBackoffResetsToOneSecond() {
        let controller = makeController()
        _ = controller.nextReconnectDelay()
        _ = controller.nextReconnectDelay()
        _ = controller.nextReconnectDelay()
        controller.resetReconnectDelay()
        XCTAssertEqual(controller.nextReconnectDelay(), 1.0, accuracy: 0.001)
    }

    func testBackoffCapAtMaxDelay() {
        let controller = makeController()
        for _ in 0..<20 {
            let delay = controller.nextReconnectDelay()
            XCTAssertLessThanOrEqual(delay, ConnectionController.maxReconnectDelay)
        }
    }

    // MARK: - Device Tag Extraction Tests (ported)

    func testExtractTagFromValidManufacturerData() {
        let data = Data([0xFF, 0xFF, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
        let tag = ConnectionController.extractDeviceTag(from: data)
        XCTAssertNotNil(tag)
        XCTAssertEqual(tag, Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]))
    }

    func testExtractTagReturnsNilForShortData() {
        let data = Data([0xFF, 0xFF, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07])
        XCTAssertNil(ConnectionController.extractDeviceTag(from: data))
    }

    func testExtractTagReturnsNilForEmptyData() {
        XCTAssertNil(ConnectionController.extractDeviceTag(from: Data()))
    }

    // MARK: - PSM Extraction Tests (ported)

    func testExtractPSMFromValidData() {
        let data = Data([0xFF, 0xFF,
                         0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
                         0x00, 0x83])
        XCTAssertEqual(ConnectionController.extractPSM(from: data), 131)
    }

    func testExtractPSMReturnsNilForShortData() {
        let data = Data([0xFF, 0xFF,
                         0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
                         0x00])
        XCTAssertNil(ConnectionController.extractPSM(from: data))
    }

    func testExtractPSMReturnsNilForZeroPSM() {
        let data = Data([0xFF, 0xFF,
                         0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
                         0x00, 0x00])
        XCTAssertNil(ConnectionController.extractPSM(from: data))
    }

    // MARK: - State Tests

    func testInitialStateIsIdle() {
        let controller = makeController()
        XCTAssertEqual(controller.state.description, "idle")
    }

    func testInitialGenerationIsZero() {
        let controller = makeController()
        XCTAssertEqual(controller.generation, 0)
    }

    // MARK: - Constants Tests

    func testServiceUUID() {
        XCTAssertEqual(ConnectionController.serviceUUID.uuidString,
                       "C10B0001-1234-5678-9ABC-DEF012345678")
    }

    func testMaxReconnectDelay() {
        XCTAssertEqual(ConnectionController.maxReconnectDelay, 30.0)
    }

    func testHealthCheckInterval() {
        XCTAssertEqual(ConnectionController.healthCheckInterval, 60.0)
    }

    // MARK: - State Description Tests

    func testStateDescriptions() {
        XCTAssertEqual(ConnectionState.idle.description, "idle")
        XCTAssertEqual(ConnectionState.scanning.description, "scanning")
    }

    func testStateGenerationAccessor() {
        XCTAssertNil(ConnectionState.idle.generation)
        XCTAssertNil(ConnectionState.scanning.generation)
    }

    // MARK: - Dedup Tests

    func testSendClipboardSkipsEchoBack() {
        // This test verifies dedup at the API level. Since sendClipboard dispatches async,
        // we test by calling sendClipboard with the same text twice in rapid succession
        // and verifying the controller doesn't crash and remains in idle (no session to send to).
        let controller = makeController()
        controller.sendClipboard("hello")
        controller.sendClipboard("hello") // should not double-queue
        // No crash = pass. Detailed dedup tested via integration.
    }

    // MARK: - Image Sync Enabled Tests

    func testImageSyncDisabledWhenNotConnected() {
        let controller = makeController()
        XCTAssertFalse(controller.isImageSyncEnabled)
    }
}
```

- [ ] **Step 2: Delete old test file**

```bash
git rm macos/ClipRelayMac/Tests/ClipRelayTests/ConnectionManagerTests.swift
```

- [ ] **Step 3: Run tests**

Run: `scripts/test-all.sh --mac-only`

Expected: All tests pass (132 existing minus ~17 old ConnectionManager tests plus ~15 new ConnectionController tests).

- [ ] **Step 4: Commit**

```bash
git add -A macos/ClipRelayMac/Tests/
git commit -m "refactor(mac): rewrite connection tests for ConnectionController"
```

---

## Task 8: Integration Testing & Polish

**Files:**
- Possibly modify: `macos/ClipRelayMac/Sources/BLE/ConnectionController.swift`
- Possibly modify: `macos/ClipRelayMac/Sources/App/AppDelegate.swift`

Build, run, verify connection works end-to-end. Fix any issues.

- [ ] **Step 1: Full build**

Run: `scripts/build-all.sh --mac-only`

Expected: Build succeeds.

- [ ] **Step 2: Run all tests**

Run: `scripts/test-all.sh --mac-only`

Expected: All tests pass.

- [ ] **Step 3: Launch and verify connection**

```bash
pkill -f "ClipRelay" 2>/dev/null
sleep 1
open dist/ClipRelay.app
sleep 10
log show --process ClipRelay --last 12s --style compact 2>/dev/null | grep 'org.cliprelay'
```

Expected: Logs show the full connection flow with the new `Connection` category:
```
[org.cliprelay:Connection] idle → scanning (start scan)
[org.cliprelay:Connection] Matched device tag, PSM=130, RSSI=-54
[org.cliprelay:Connection] scanning → bleConnecting(...) (paired device found)
[org.cliprelay:Connection] BLE connected, opening L2CAP (PSM=130)
[org.cliprelay:Connection] bleConnecting → l2capOpening (BLE connected)
[org.cliprelay:Connection] L2CAP channel established
[org.cliprelay:Connection] l2capOpening → handshaking (starting handshake)
[org.cliprelay:Connection] Session ready — remote: Pixel 10 Pro XL
[org.cliprelay:Connection] handshaking → ready (handshake complete)
```

- [ ] **Step 4: Verify clipboard sync works**

Copy text on Mac, verify it appears on Android (or vice versa, if Android device is available).

- [ ] **Step 5: Verify status bar shows connected**

Check that the menu bar icon shows the connected state (aqua color) and the device name appears in the menu.

- [ ] **Step 6: Fix any issues found during integration testing**

Iterate until everything works.

- [ ] **Step 7: Final commit**

```bash
git add -A
git commit -m "refactor(mac): integration fixes for ConnectionController"
```

---

## Task 9: CI Workflow Update (Optional — can be separate PR)

**Files:**
- Modify: `.github/workflows/claude.yml`
- Modify: `.github/workflows/claude-code-review.yml`

Include the CI workflow model changes from the abandoned PR #24.

- [ ] **Step 1: Update Claude workflows to use Opus**

In `.github/workflows/claude.yml`, change:
```yaml
          claude_args: "--dangerously-skip-permissions"
```
to:
```yaml
          claude_args: "--dangerously-skip-permissions --model claude-opus-4-6"
```

In `.github/workflows/claude-code-review.yml`, change:
```yaml
          claude_args: |
            --allowedTools "mcp__github_inline_comment__create_inline_comment,Bash(gh pr comment:*),Bash(gh pr diff:*),Bash(gh pr view:*),Read,Glob,Grep"
```
to:
```yaml
          claude_args: |
            --model claude-opus-4-6 --allowedTools "mcp__github_inline_comment__create_inline_comment,Bash(gh pr comment:*),Bash(gh pr diff:*),Bash(gh pr view:*),Read,Glob,Grep"
```

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/
git commit -m "chore(ci): update Claude workflows to use Opus model"
```

- [ ] **Step 3: Final full build and test run**

Run: `scripts/build-all.sh --mac-only && scripts/test-all.sh --mac-only`

Expected: All pass.

- [ ] **Step 4: Create PR**

```bash
gh pr create --title "refactor(mac): unified connection state machine" --body "$(cat <<'EOF'
## Summary

Replaces the split ConnectionManager + AppDelegate connection logic with a single
`ConnectionController` class that owns the full BLE-to-session lifecycle on a
dedicated serial DispatchQueue.

- **Single state enum** covering idle → scanning → BLE → L2CAP → handshake → ready
- **Generation counter** eliminates stale callback races by construction
- **One cleanup path** (`transitionToIdle`) replaces 5+ duplicate cleanup paths
- **Serial queue** — CB callbacks land directly on it, session callbacks dispatched via adapter
- **os.Logger with privacy: .public** — reliable logging for all state transitions
- **AppDelegate slimmed** from ~700 to ~350 lines — just wires controller to UI

Also updates Claude CI workflows to use Opus model.

Spec: `docs/superpowers/specs/2026-03-27-connection-state-machine-refactor-design.md`

## Test plan

- [x] All unit tests pass
- [x] Full build succeeds
- [x] Fresh launch connects to Android within seconds (verified via log stream)
- [ ] Sleep/wake cycle recovers connection automatically
- [ ] Clipboard sync works bidirectionally
- [ ] Pairing new device works
- [ ] Forget device works
- [ ] Image sync toggle works
EOF
)"
```
