// Unified BLE connection controller: owns the full lifecycle from scanning through
// session ready state, with a single cleanup path and generation-based cancellation.

import CoreBluetooth
import CryptoKit
import Foundation
import os

// MARK: - Connection State

enum ConnectionState: CustomStringConvertible {
    case idle
    case scanning
    case bleConnecting(CBPeripheral, CBL2CAPPSM, token: String, generation: UInt)
    case l2capOpening(CBPeripheral, token: String, generation: UInt)
    case pairingConnecting(CBPeripheral, CBL2CAPPSM, generation: UInt)
    case pairingL2CAP(CBPeripheral, generation: UInt)
    case pairingHandshake(Session, generation: UInt)
    case handshaking(Session, token: String, generation: UInt)
    case ready(Session, token: String, generation: UInt)

    var generation: UInt? {
        switch self {
        case .idle, .scanning:
            return nil
        case .bleConnecting(_, _, _, let g),
             .l2capOpening(_, _, let g),
             .pairingConnecting(_, _, let g),
             .pairingL2CAP(_, let g),
             .pairingHandshake(_, let g),
             .handshaking(_, _, let g),
             .ready(_, _, let g):
            return g
        }
    }

    var description: String {
        switch self {
        case .idle: return "idle"
        case .scanning: return "scanning"
        case .bleConnecting(_, let psm, _, let g): return "bleConnecting(psm=\(psm), gen=\(g))"
        case .l2capOpening(_, _, let g): return "l2capOpening(gen=\(g))"
        case .pairingConnecting(_, let psm, let g): return "pairingConnecting(psm=\(psm), gen=\(g))"
        case .pairingL2CAP(_, let g): return "pairingL2CAP(gen=\(g))"
        case .pairingHandshake(_, let g): return "pairingHandshake(gen=\(g))"
        case .handshaking(_, _, let g): return "handshaking(gen=\(g))"
        case .ready(_, _, let g): return "ready(gen=\(g))"
        }
    }
}

// MARK: - Connection Error

enum ConnectionError {
    case versionMismatch(Int)
    case sessionError(String)
    case bleError(String)
}

// MARK: - Delegate

protocol ConnectionControllerDelegate: AnyObject {
    func didChangeState(connected: Bool, deviceName: String?, token: String?)
    func didReceiveClipboard(text: String)
    func didReceiveImage(data: Data, contentType: String)
    func didCompletePairing(deviceName: String?)
    func didEncounterError(error: ConnectionError)
    func didUpdateBluetoothState(state: CBManagerState)
    func didSyncClipboard(hash: String)
    func didChangeImageSyncSetting(enabled: Bool)
    func imageTransferFailed(reason: String)
}

// MARK: - ConnectionController

class ConnectionController: NSObject {
    // MARK: Constants

    static let serviceUUID = CBUUID(string: "c10b0001-1234-5678-9abc-def012345678")
    static let maxReconnectDelay: TimeInterval = 30.0
    static let healthCheckInterval: TimeInterval = 60.0
    static let connectingTimeout: TimeInterval = 15.0

    // MARK: Queue & Logging

    fileprivate let queue = DispatchQueue(label: "org.cliprelay.connection")
    private let logger = Logger(subsystem: "org.cliprelay", category: "Connection")

    // MARK: State

    /// Internal state — only access from the connection queue.
    private(set) var state: ConnectionState = .idle
    private(set) var generation: UInt = 0
    weak var delegate: ConnectionControllerDelegate?

    /// Main-thread-safe cached values, updated on every state transition.
    /// Use these from AppDelegate/UI closures instead of reading `state` directly.
    private(set) var isConnected: Bool = false
    private(set) var connectedToken: String?

    // MARK: BLE

    private var centralManager: CBCentralManager!
    private var l2capChannel: CBL2CAPChannel?
    private var connectingStartTime: Date?
    /// Last peripheral we attempted to connect to. Retained across transitionToIdle
    /// so we can re-cancel it when BT powers on (cancelPeripheralConnection during
    /// BT-off may be a no-op, leaving internal CB connection bookkeeping dangling).
    private var lastAttemptedPeripheral: CBPeripheral?

    // MARK: Reconnect

    private var reconnectDelay: TimeInterval = 1.0
    private var reconnectTimer: DispatchSourceTimer?
    private var healthCheckTimer: DispatchSourceTimer?

    // MARK: Pairing

    private let pairingManager: PairingManager
    private var pairingTag: Data?
    private var pairingPrivateKey: Curve25519.KeyAgreement.PrivateKey?

    // MARK: Session Adapter

    /// Retained to prevent adapter deallocation during session lifetime.
    fileprivate var currentAdapter: SessionAdapter?
    /// Strong reference to settings provider (Session.settingsProvider is weak).
    private var settingsProviderRef: DeviceSettingsProvider?

    // MARK: Dedup

    fileprivate var lastReceivedTextHash: String?
    fileprivate var lastReceivedImageHash: String?

    // MARK: Pending

    private var pendingClipboard: Data?

    // MARK: - Init

    init(pairingManager: PairingManager) {
        self.pairingManager = pairingManager
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: queue)
        startHealthCheck()
    }

    /// Test-only initialiser that optionally skips CBCentralManager creation.
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
        let wasReady = isReady(state)
        let oldDesc = state.description
        state = newState
        let nowReady = isReady(state)
        log("[\(reason)] \(oldDesc) → \(newState)")

        if wasReady != nowReady {
            let token: String?
            let deviceName: String?
            switch newState {
            case .ready(_, let t, _):
                token = t
                deviceName = pairingManager.loadDevices().first(where: { $0.sharedSecret == t })?.displayName
            default:
                token = nil
                deviceName = nil
            }
            let connected = nowReady
            // Update main-thread-safe cached values
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isConnected = connected
                self.connectedToken = token
                self.delegate?.didChangeState(connected: connected, deviceName: deviceName, token: token)
            }
        }
    }

    private func isReady(_ state: ConnectionState) -> Bool {
        if case .ready = state { return true }
        return false
    }

    // MARK: - Cleanup (single path)

    private func transitionToIdle(reason: String, reconnect: Bool, preservePairingContext: Bool = false) {
        // Cancel peripheral connection if we have one
        if let peripheral = trackedPeripheral(from: state) ?? lastAttemptedPeripheral {
            centralManager?.cancelPeripheralConnection(peripheral)
        }

        // Stop scanning
        if case .scanning = state {
            centralManager?.stopScan()
        }

        // Close session if active
        if let session = activeSession(from: state) {
            session.close()
        }

        // Clear all connection state (pendingClipboard intentionally preserved
        // across reconnection cycles so it can be sent after reconnecting)
        l2capChannel = nil
        connectingStartTime = nil
        if !preservePairingContext {
            pairingTag = nil
            pairingPrivateKey = nil
        }
        settingsProviderRef = nil

        // Increment generation so any in-flight callbacks from the old connection are ignored
        generation &+= 1

        transition(to: .idle, reason: reason)

        if reconnect {
            scheduleReconnect()
        }
    }

    // MARK: - State Helpers

    private func trackedPeripheral(from state: ConnectionState) -> CBPeripheral? {
        switch state {
        case .bleConnecting(let p, _, _, _),
             .l2capOpening(let p, _, _),
             .pairingConnecting(let p, _, _),
             .pairingL2CAP(let p, _):
            return p
        case .idle, .scanning, .pairingHandshake, .handshaking, .ready:
            return nil
        }
    }

    private func activeSession(from state: ConnectionState) -> Session? {
        switch state {
        case .pairingHandshake(let s, _),
             .handshaking(let s, _, _),
             .ready(let s, _, _):
            return s
        default:
            return nil
        }
    }

    private func shouldPreservePairingContext(for state: ConnectionState) -> Bool {
        switch state {
        case .pairingConnecting, .pairingL2CAP, .pairingHandshake:
            return true
        default:
            return false
        }
    }

    // MARK: - Timers

    private func startHealthCheck() {
        healthCheckTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.healthCheckInterval, repeating: Self.healthCheckInterval)
        timer.setEventHandler { [weak self] in self?.performHealthCheck() }
        timer.resume()
        healthCheckTimer = timer
    }

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

    // MARK: - Scanning

    func startScanning() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let centralManager else {
            log("startScanning: no central manager")
            return
        }
        guard centralManager.state == .poweredOn else {
            log("startScanning: BT not poweredOn (\(centralManager.state.rawValue))")
            return
        }
        guard case .idle = state else {
            log("startScanning: not idle (\(state))")
            return
        }
        log("Scanning (paired: \(pairedDeviceTags().count))")
        transition(to: .scanning, reason: "startScanning")
        centralManager.scanForPeripherals(
            withServices: [Self.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    // MARK: - Health Check

    private func performHealthCheck() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard centralManager.state == .poweredOn else { return }

        switch state {
        case .bleConnecting, .l2capOpening, .pairingConnecting, .pairingL2CAP:
            if let start = connectingStartTime,
               Date().timeIntervalSince(start) > Self.connectingTimeout {
                log("Health check: connecting timed out")
                transitionToIdle(
                    reason: "connectingTimeout",
                    reconnect: true,
                    preservePairingContext: shouldPreservePairingContext(for: state)
                )
            }
        case .scanning:
            // Cycle the scan to pick up new advertisements
            centralManager.stopScan()
            centralManager.scanForPeripherals(
                withServices: [Self.serviceUUID],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
            )
        case .idle:
            resetReconnectDelay()
            startScanning()
        case .handshaking, .ready:
            break
        case .pairingHandshake:
            break
        }
    }

    // MARK: - Reconnect Delay

    func resetReconnectDelay() {
        reconnectDelay = 1.0
    }

    @discardableResult
    func nextReconnectDelay() -> TimeInterval {
        let current = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, Self.maxReconnectDelay)
        return current
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
        return manufacturerData[2..<10]
    }

    static func extractPSM(from manufacturerData: Data) -> CBL2CAPPSM? {
        guard manufacturerData.count >= 12 else { return nil }
        let psm = UInt16(manufacturerData[10]) << 8 | UInt16(manufacturerData[11])
        guard psm > 0 else { return nil }
        return CBL2CAPPSM(psm)
    }

    // MARK: - Disconnect

    func disconnect() {
        queue.async { [weak self] in
            guard let self else { return }
            self.healthCheckTimer?.cancel()
            self.healthCheckTimer = nil
            self.reconnectTimer?.cancel()
            self.reconnectTimer = nil
            self.transitionToIdle(reason: "disconnect", reconnect: false)
        }
    }
}

// MARK: - Public API

struct PairingInfo {
    let uri: URL
}

extension ConnectionController {

    // MARK: Pairing

    /// Start pairing flow. Generates ECDH key pair, returns QR URI.
    /// PairingManager operations happen on the calling thread (main).
    /// BLE scanning dispatched to connection queue.
    func startPairing() -> PairingInfo? {
        pairingManager.removePendingDevices()
        let privateKey = pairingManager.generateKeyPair()
        guard let uri = pairingManager.pairingURI(publicKey: privateKey.publicKey) else { return nil }
        let tag = PairingManager.pairingTag(from: privateKey.publicKey.rawRepresentation)
        queue.async { [self] in
            pairingPrivateKey = privateKey
            pairingTag = tag
            transitionToIdle(
                reason: "entering pairing mode",
                reconnect: false,
                preservePairingContext: true
            )
            startScanning()
        }
        return PairingInfo(uri: uri)
    }

    func cancelPairing() {
        queue.async { [self] in
            pairingManager.clearEphemeralKey()
            pairingManager.removePendingDevices()
            switch state {
            case .scanning, .pairingConnecting, .pairingL2CAP, .pairingHandshake:
                transitionToIdle(reason: "pairing cancelled", reconnect: false)
            default:
                pairingTag = nil
                pairingPrivateKey = nil
            }
        }
    }

    // MARK: Sending

    func sendClipboard(_ text: String) {
        queue.async { [self] in
            guard let data = text.data(using: .utf8) else { return }
            let hash = Session.sha256Hex(data)
            guard hash != lastReceivedTextHash else { return }
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
            guard case .ready(let session, let token, _) = state else { return }
            guard imageSyncEnabled(for: token) else { return }
            session.sendImage(data, contentType: contentType)
        }
    }

    // MARK: Device Management

    func forgetDevice(token: String) {
        queue.async { [self] in
            pairingManager.removeDevice(secret: token)
            switch state {
            case .ready(_, let t, _) where t == token:
                transitionToIdle(reason: "device forgotten", reconnect: false)
            case .handshaking(_, let t, _) where t == token:
                transitionToIdle(reason: "device forgotten", reconnect: false)
            case .bleConnecting(_, _, let t, _) where t == token:
                transitionToIdle(reason: "device forgotten", reconnect: false)
            case .l2capOpening(_, let t, _) where t == token:
                transitionToIdle(reason: "device forgotten", reconnect: false)
            default:
                break
            }
            if case .idle = state, !pairingManager.loadDevices().isEmpty {
                startScanning()
            }
        }
    }

    var pairedDevices: [PairedDevice] {
        pairingManager.loadDevices()
    }

    // MARK: Settings

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

    /// Safe to call from main thread — uses cached `connectedToken`.
    var isImageSyncEnabled: Bool {
        guard let secret = connectedToken else { return false }
        return imageSyncEnabled(for: secret)
    }

    private func imageSyncEnabled(for secret: String) -> Bool {
        return pairingManager.loadDevices()
            .first(where: { $0.sharedSecret == secret })?.richMediaEnabled ?? false
    }
}

// MARK: - CBCentralManagerDelegate

extension ConnectionController: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("BT state: \(central.state.rawValue)")
        if central.state == .poweredOn {
            // Re-cancel any peripheral from before the power cycle. cancelPeripheralConnection
            // during BT-off is a no-op, so internal CB connection bookkeeping can accumulate
            // across brief power nap cycles (BT on for ~2s, off, repeat). Re-cancelling now
            // that BT is back on releases those dangling slots.
            if let stale = lastAttemptedPeripheral {
                central.cancelPeripheralConnection(stale)
                lastAttemptedPeripheral = nil
            }
            resetReconnectDelay()
            startHealthCheck()
            startScanning()
        } else {
            transitionToIdle(
                reason: "BT state \(central.state.rawValue)",
                reconnect: false,
                preservePairingContext: pairingTag != nil
            )
        }
        let btState = central.state
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.didUpdateBluetoothState(state: btState)
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard case .scanning = state else { return }

        guard let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              let deviceTag = Self.extractDeviceTag(from: manufacturerData),
              let psm = Self.extractPSM(from: manufacturerData)
        else { return }

        // Check for active pairing request
        if let pairingTag, pairingTag == deviceTag {
            central.stopScan()
            generation &+= 1
            transition(
                to: .pairingConnecting(peripheral, psm, generation: generation),
                reason: "pairingDiscovered"
            )
            connectingStartTime = Date()
            lastAttemptedPeripheral = peripheral
            peripheral.delegate = self
            central.connect(peripheral, options: nil)
            return
        }

        // In pairing mode, only match the pairing tag — don't connect to existing paired devices
        if pairingTag != nil { return }

        // Check against paired devices
        let paired = pairedDeviceTags()
        if let matched = paired.first(where: { $0.tag == deviceTag }) {
            log("Matched device tag, PSM=\(psm), RSSI=\(RSSI)")
            central.stopScan()
            generation &+= 1
            transition(
                to: .bleConnecting(peripheral, psm, token: matched.token, generation: generation),
                reason: "pairedDeviceDiscovered"
            )
            connectingStartTime = Date()
            lastAttemptedPeripheral = peripheral
            peripheral.delegate = self
            central.connect(peripheral, options: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        switch state {
        case .bleConnecting(_, let psm, let token, let gen) where gen == generation:
            transition(
                to: .l2capOpening(peripheral, token: token, generation: gen),
                reason: "didConnect"
            )
            connectingStartTime = Date()  // reset for L2CAP open timeout
            peripheral.openL2CAPChannel(psm)

        case .pairingConnecting(_, let psm, let gen) where gen == generation:
            transition(
                to: .pairingL2CAP(peripheral, generation: gen),
                reason: "didConnect(pairing)"
            )
            connectingStartTime = Date()  // reset for L2CAP open timeout
            peripheral.openL2CAPChannel(psm)

        default:
            log("Stale didConnect (\(state)), cancelling")
            central.cancelPeripheralConnection(peripheral)
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        log("didFailToConnect: \(error?.localizedDescription ?? "unknown")")
        central.cancelPeripheralConnection(peripheral)
        transitionToIdle(
            reason: "didFailToConnect",
            reconnect: true,
            preservePairingContext: shouldPreservePairingContext(for: state)
        )
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        log("didDisconnect (\(state)): \(error?.localizedDescription ?? "clean")")

        guard state.generation == generation else {
            log("Stale didDisconnect (state gen \(state.generation?.description ?? "nil") != \(generation))")
            return
        }

        switch state {
        case .bleConnecting, .l2capOpening:
            transitionToIdle(reason: "didDisconnect(connecting)", reconnect: true)
        case .pairingConnecting, .pairingL2CAP, .pairingHandshake:
            transitionToIdle(
                reason: "didDisconnect(pairing)",
                reconnect: true,
                preservePairingContext: true
            )
        case .handshaking, .ready:
            transitionToIdle(reason: "didDisconnect(session)", reconnect: true)
        case .idle, .scanning:
            log("didDisconnect while \(state), ignoring")
        }
    }
}

// MARK: - CBPeripheralDelegate

extension ConnectionController: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        connectingStartTime = nil

        if let error {
            log("L2CAP open error: \(error.localizedDescription)")
            transitionToIdle(
                reason: "L2CAP open error",
                reconnect: true,
                preservePairingContext: shouldPreservePairingContext(for: state)
            )
            return
        }

        guard let channel else {
            log("L2CAP open returned nil channel")
            transitionToIdle(
                reason: "L2CAP nil channel",
                reconnect: true,
                preservePairingContext: shouldPreservePairingContext(for: state)
            )
            return
        }

        l2capChannel = channel

        switch state {
        case .l2capOpening(_, let token, let gen) where gen == generation:
            startSession(channel: channel, token: token, gen: gen, isPairing: false)

        case .pairingL2CAP(_, let gen) where gen == generation:
            startSession(channel: channel, token: nil, gen: gen, isPairing: true)

        default:
            log("Stale didOpen (\(state)), cancelling")
            centralManager?.cancelPeripheralConnection(peripheral)
        }
    }
}

// MARK: - Session Start

extension ConnectionController {

    fileprivate func startSession(channel: CBL2CAPChannel, token: String?, gen: UInt, isPairing: Bool) {
        guard let inputStream = channel.inputStream, let outputStream = channel.outputStream else {
            log("L2CAP channel missing streams")
            transitionToIdle(
                reason: "missing streams",
                reconnect: true,
                preservePairingContext: isPairing
            )
            return
        }

        // Open streams temporarily on main RunLoop (CoreBluetooth requirement)
        inputStream.schedule(in: .main, forMode: .common)
        outputStream.schedule(in: .main, forMode: .common)
        inputStream.open()
        outputStream.open()

        let adapter = SessionAdapter(controller: self, generation: gen)
        currentAdapter = adapter

        let session: Session
        if isPairing {
            guard let privateKey = pairingPrivateKey else {
                log("Pairing channel but no ephemeral key")
                transitionToIdle(reason: "missing pairing key", reconnect: false)
                return
            }
            session = Session(inputStream: inputStream, outputStream: outputStream,
                              isInitiator: true, delegate: adapter,
                              mode: .pairing(privateKey: privateKey))
            session.localName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
            transition(to: .pairingHandshake(session, generation: gen), reason: "pairing handshake")
        } else {
            guard let token else {
                log("Normal channel but no token")
                transitionToIdle(reason: "missing token", reconnect: false)
                return
            }
            let settingsProvider = DeviceSettingsProvider(pairingManager: pairingManager, secret: token)
            settingsProviderRef = settingsProvider  // retain (Session.settingsProvider is weak)
            session = Session(inputStream: inputStream, outputStream: outputStream,
                              isInitiator: true, delegate: adapter, sharedSecretHex: token)
            session.localName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
            session.settingsProvider = settingsProvider
            transition(to: .handshaking(session, token: token, generation: gen), reason: "handshake")
        }

        reconnectDelay = 1.0  // reset backoff on successful L2CAP

        // Spawn session thread
        let thread = Thread { [weak self] in
            inputStream.remove(from: .main, forMode: .common)
            outputStream.remove(from: .main, forMode: .common)
            let runLoop = RunLoop.current
            inputStream.schedule(in: runLoop, forMode: .common)
            outputStream.schedule(in: runLoop, forMode: .common)
            session.performHandshake()
            session.listenForMessages()
            // Session ended — clean up adapter reference
            self?.queue.async {
                guard self?.currentAdapter === adapter else { return }
                self?.currentAdapter = nil
            }
        }
        thread.name = isPairing ? "L2CAP-Pairing" : "L2CAP-Session"
        thread.start()
    }
}

// MARK: - Session Event Handlers

extension ConnectionController {

    fileprivate func handleSessionReady(_ session: Session, generation gen: UInt) {
        let remoteName = session.remoteName
        guard case .handshaking(_, let token, let g) = state, g == gen else {
            log("Stale sessionReady (gen \(gen) != \(generation))")
            return
        }
        // Update stored device name
        if let name = remoteName {
            let devices = pairingManager.loadDevices()
            if let existing = devices.first(where: { $0.sharedSecret == token && $0.displayName != name }) {
                pairingManager.removeDevice(secret: token)
                let updated = PairedDevice(sharedSecret: existing.sharedSecret, displayName: name,
                                           datePaired: existing.datePaired,
                                           richMediaEnabled: existing.richMediaEnabled,
                                           richMediaEnabledChangedAt: existing.richMediaEnabledChangedAt)
                pairingManager.addDevice(updated)
            }
        }
        transition(to: .ready(session, token: token, generation: gen), reason: "handshake complete")
        log("Session ready — remote: \(remoteName ?? "unknown")")
        // Send pending clipboard
        if let pending = pendingClipboard {
            session.sendClipboard(pending)
            log("Sent pending clipboard (\(pending.count) bytes)")
        }
    }

    fileprivate func handleSessionError(_ error: Error) {
        log("Session error: \(error)")
        if case SessionError.versionMismatch(let v) = error {
            transitionToIdle(reason: "version mismatch (v\(v))", reconnect: false)
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.didEncounterError(error: .versionMismatch(v))
            }
            return
        }
        transitionToIdle(
            reason: "session error",
            reconnect: true,
            preservePairingContext: shouldPreservePairingContext(for: state)
        )
    }

    fileprivate func handleClipboardReceived(plaintext: Data, hash: String) {
        lastReceivedTextHash = hash
        currentAdapter?.lastTextHash = hash
        guard let text = String(data: plaintext, encoding: .utf8) else {
            log("Received data not valid UTF-8")
            return
        }
        log("Received clipboard (\(text.count) chars)")
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.didReceiveClipboard(text: text)
        }
    }

    fileprivate func handleImageReceived(data: Data, contentType: String, hash: String) {
        lastReceivedImageHash = hash
        log("Received image (\(data.count) bytes, \(contentType))")
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.didReceiveImage(data: data, contentType: contentType)
        }
    }

    fileprivate func handleTransferComplete(hash: String) {
        log("Transfer complete (\(hash.prefix(8))...)")
        pendingClipboard = nil
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.didSyncClipboard(hash: hash)
        }
    }

    fileprivate func handlePairingComplete(sharedSecret: Data, remoteName: String?) {
        let secretHex = sharedSecret.map { String(format: "%02x", $0) }.joined()
        log("Pairing complete")
        let device = PairedDevice(sharedSecret: secretHex, displayName: remoteName ?? "Android", datePaired: Date())
        pairingManager.addDevice(device)
        pairingManager.clearEphemeralKey()
        // Wire settings provider (hold strong ref via settingsProviderRef so weak var isn't immediately nil)
        if let session = activeSession(from: state) {
            let provider = DeviceSettingsProvider(pairingManager: pairingManager, secret: secretHex)
            settingsProviderRef = provider
            session.settingsProvider = provider
        }
        pairingTag = nil
        pairingPrivateKey = nil
        // Transition from pairingHandshake to handshaking
        if case .pairingHandshake(let session, let gen) = state, gen == generation {
            transition(to: .handshaking(session, token: secretHex, generation: gen), reason: "pairing complete")
        }
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.didCompletePairing(deviceName: remoteName)
        }
    }

    fileprivate func handleRichMediaSettingChanged(enabled: Bool) {
        log("Remote changed image sync to \(enabled)")
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.didChangeImageSyncSetting(enabled: enabled)
        }
    }

    fileprivate func handleImageTransferFailed(reason: String) {
        log("Image transfer failed: \(reason)")
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.imageTransferFailed(reason: reason)
        }
    }
}

// MARK: - SessionAdapter

/// Bridges `SessionDelegate` callbacks (fired on the session thread) to
/// `ConnectionController` handler methods on its serial queue, guarded by generation.
private class SessionAdapter: NSObject, SessionDelegate {
    weak var controller: ConnectionController?
    let generation: UInt

    private let hashLock = NSLock()
    private var _lastTextHash: String?

    var lastTextHash: String? {
        get { hashLock.lock(); defer { hashLock.unlock() }; return _lastTextHash }
        set { hashLock.lock(); defer { hashLock.unlock() }; _lastTextHash = newValue }
    }

    init(controller: ConnectionController, generation: UInt) {
        self.controller = controller
        self.generation = generation
        self._lastTextHash = controller.lastReceivedTextHash
        super.init()
    }

    /// Dispatch a block on the controller's queue, guarded by generation.
    private func dispatch(_ work: @escaping (ConnectionController) -> Void) {
        controller?.queue.async { [weak controller, generation] in
            guard let controller, controller.generation == generation else { return }
            work(controller)
        }
    }

    // MARK: SessionDelegate

    func sessionDidBecomeReady(_ session: Session) {
        dispatch { $0.handleSessionReady(session, generation: self.generation) }
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

    func session(_ session: Session, alreadyHasHash hash: String) -> Bool {
        return lastTextHash == hash
    }
}
