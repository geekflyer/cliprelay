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

    private(set) var state: ConnectionState = .idle
    private(set) var generation: UInt = 0
    weak var delegate: ConnectionControllerDelegate?

    // MARK: BLE

    private var centralManager: CBCentralManager!
    private var l2capChannel: CBL2CAPChannel?
    private var connectingStartTime: Date?

    // MARK: Reconnect

    private var reconnectDelay: TimeInterval = 1.0
    private var reconnectTimer: DispatchSourceTimer?
    private var healthCheckTimer: DispatchSourceTimer?

    // MARK: Pairing

    private let pairingManager: PairingManager
    private var pairingTag: Data?
    private var pairingPrivateKey: Curve25519.KeyAgreement.PrivateKey?

    // MARK: Dedup

    private var lastReceivedTextHash: String?
    private var lastReceivedImageHash: String?

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
            case .ready(_, let t, _), .handshaking(_, let t, _):
                token = t
                deviceName = pairingManager.loadDevices().first(where: { $0.sharedSecret == token })?.displayName
            default:
                token = nil
                deviceName = nil
            }
            let connected = nowReady
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.didChangeState(connected: connected, deviceName: deviceName, token: token)
            }
        }
    }

    private func isReady(_ state: ConnectionState) -> Bool {
        if case .ready = state { return true }
        return false
    }

    // MARK: - Cleanup (single path)

    private func transitionToIdle(reason: String, reconnect: Bool) {
        // Cancel peripheral connection if we have one
        if let peripheral = trackedPeripheral(from: state) {
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

        // Clear all connection state
        l2capChannel = nil
        connectingStartTime = nil
        pairingTag = nil
        pairingPrivateKey = nil
        pendingClipboard = nil

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
        guard centralManager.state == .poweredOn else {
            log("startScanning: BT not poweredOn (\(centralManager.state.rawValue))")
            return
        }
        guard case .idle = state else {
            log("startScanning: not idle (\(state))")
            return
        }
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
                transitionToIdle(reason: "connectingTimeout", reconnect: true)
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

// MARK: - CBCentralManagerDelegate

extension ConnectionController: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("BT state: \(central.state.rawValue)")
        if central.state == .poweredOn {
            resetReconnectDelay()
            startHealthCheck()
            startScanning()
        } else {
            transitionToIdle(reason: "BT state \(central.state.rawValue)", reconnect: false)
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
            peripheral.delegate = self
            central.connect(peripheral, options: nil)
            return
        }

        // Check against paired devices
        let paired = pairedDeviceTags()
        if let matched = paired.first(where: { $0.tag == deviceTag }) {
            central.stopScan()
            generation &+= 1
            transition(
                to: .bleConnecting(peripheral, psm, token: matched.token, generation: generation),
                reason: "pairedDeviceDiscovered"
            )
            connectingStartTime = Date()
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
            connectingStartTime = nil
            peripheral.openL2CAPChannel(psm)

        case .pairingConnecting(_, let psm, let gen) where gen == generation:
            transition(
                to: .pairingL2CAP(peripheral, generation: gen),
                reason: "didConnect(pairing)"
            )
            connectingStartTime = nil
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
        transitionToIdle(reason: "didFailToConnect", reconnect: true)
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
        case .bleConnecting, .l2capOpening, .pairingConnecting, .pairingL2CAP:
            transitionToIdle(reason: "didDisconnect(connecting)", reconnect: true)
        case .handshaking, .ready, .pairingHandshake:
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
            centralManager?.cancelPeripheralConnection(peripheral)
            return
        }

        guard let channel else {
            log("L2CAP open returned nil channel")
            centralManager?.cancelPeripheralConnection(peripheral)
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

// MARK: - Session Start (Task 4)

extension ConnectionController {
    fileprivate func startSession(channel: CBL2CAPChannel, token: String?, gen: UInt, isPairing: Bool) {
        // Implemented in Task 4
    }
}
