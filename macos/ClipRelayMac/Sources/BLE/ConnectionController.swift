// BLE connection controller: maintains one connection per paired Android device
// concurrently. Each device has its own small state machine, backoff, and session;
// scanning runs whenever any paired device is unconnected (or pairing is active).

import CoreBluetooth
import CryptoKit
import Foundation
import os

// MARK: - Per-Device State

enum DeviceState: CustomStringConvertible {
    case idle
    case bleConnecting(CBL2CAPPSM)
    case l2capOpening
    case handshaking(Session)
    case ready(Session)

    var description: String {
        switch self {
        case .idle: return "idle"
        case .bleConnecting(let psm): return "bleConnecting(psm=\(psm))"
        case .l2capOpening: return "l2capOpening"
        case .handshaking: return "handshaking"
        case .ready: return "ready"
        }
    }

    var session: Session? {
        switch self {
        case .handshaking(let s), .ready(let s): return s
        default: return nil
        }
    }

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }
}

/// Exponential reconnect backoff: 1, 2, 4, ... capped at maxReconnectDelay.
struct ReconnectBackoff {
    private(set) var delay: TimeInterval = 1.0

    mutating func next() -> TimeInterval {
        let current = delay
        delay = min(delay * 2, ConnectionController.maxReconnectDelay)
        return current
    }

    mutating func reset() {
        delay = 1.0
    }
}

/// Connection bookkeeping for one paired Android device. Only accessed on the
/// controller's serial queue.
final class DeviceConnection {
    let token: String
    var state: DeviceState = .idle
    /// Peripheral of the current attempt/connection (kept outside `state` so it
    /// can always be cancelled during teardown).
    var peripheral: CBPeripheral?
    /// The open L2CAP channel. Must stay retained — releasing a CBL2CAPChannel
    /// closes the underlying connection.
    var channel: CBL2CAPChannel?
    var connectingStartTime: Date?
    var backoff = ReconnectBackoff()
    /// Earliest time the next connect attempt may start (per-device flap guard).
    var nextAttemptAt = Date.distantPast
    /// Set on version mismatch: stays paired but no reconnect attempts (and no
    /// repeated alerts) until the next Bluetooth power cycle.
    var suspended = false
    var adapter: SessionAdapter?
    var settingsProvider: DeviceSettingsProvider?

    init(token: String) {
        self.token = token
    }
}

// MARK: - Pairing State

private enum PairingPhase {
    case scanning
    case connecting(CBPeripheral, CBL2CAPPSM)
    case l2capOpening(CBPeripheral)
    case handshake(Session)
}

// MARK: - Connection Error

enum ConnectionError {
    case versionMismatch(Int)
    case sessionError(String)
    case bleError(String)
}

// MARK: - Delegate

protocol ConnectionControllerDelegate: AnyObject {
    func didChangeState(connectedTokens: [String])
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

    /// One connection record per paired device, keyed by token. Queue-only.
    private(set) var devices: [String: DeviceConnection] = [:]
    /// Bumped when everything is torn down (BT off, disconnect) so in-flight
    /// session callbacks from before the teardown are ignored.
    private(set) var generation: UInt = 0
    weak var delegate: ConnectionControllerDelegate?

    /// Main-thread-safe cached values, updated on every readiness change.
    private(set) var isConnected: Bool = false
    private(set) var connectedTokens: [String] = []
    var connectedToken: String? { connectedTokens.first }

    // MARK: BLE

    private var centralManager: CBCentralManager!
    /// Peripherals whose cancel happened while Bluetooth was off (a no-op that
    /// leaves dangling CoreBluetooth connection bookkeeping). Re-cancelled at
    /// poweredOn. Cancels issued while powered on take effect immediately and
    /// are not tracked.
    private var staleAttemptedPeripherals: [UUID: CBPeripheral] = [:]

    private func rememberStaleAttemptIfNeeded(_ peripheral: CBPeripheral) {
        guard centralManager?.state != .poweredOn else { return }
        staleAttemptedPeripherals[peripheral.identifier] = peripheral
    }

    // MARK: Timers

    private var healthCheckTimer: DispatchSourceTimer?

    // MARK: Pairing

    private let pairingManager: PairingManager
    private var pairingTag: Data?
    private var pairingPrivateKey: Curve25519.KeyAgreement.PrivateKey?
    private var pairingPhase: PairingPhase = .scanning
    private var pairingPeripheral: CBPeripheral?
    /// Retained for the same reason as DeviceConnection.channel.
    private var pairingChannel: CBL2CAPChannel?
    private var pairingConnectingStartTime: Date?
    private var pairingAdapter: SessionAdapter?

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
        // Also persist to the shareable diagnostic file — os.Logger output is
        // invisible in release builds, so this is the only trace users can send.
        DiagnosticLog.shared.log(message, category: "Connection")
    }

    /// Full NSError detail. `localizedDescription` alone hides the CoreBluetooth
    /// domain/code we need to tell apart L2CAP open failures (e.g. encryption
    /// insufficient vs. peer removed pairing vs. unsupported).
    private func describe(_ error: Error?) -> String {
        guard let error else { return "none" }
        let ns = error as NSError
        var detail = "\(ns.domain) code=\(ns.code): \(ns.localizedDescription)"
        if !ns.userInfo.isEmpty {
            detail += " userInfo=\(ns.userInfo)"
        }
        return detail
    }

    /// Human-readable Bluetooth state for shared logs — a bare rawValue like
    /// "BT state: 4" is opaque to a user reading their exported log.
    /// poweredOff = OS Bluetooth disabled; unauthorized = app lacks permission
    /// (Bluetooth may still be on).
    private func describe(_ state: CBManagerState) -> String {
        let name: String
        switch state {
        case .poweredOn: name = "poweredOn"
        case .poweredOff: name = "poweredOff"
        case .unauthorized: name = "unauthorized"
        case .unsupported: name = "unsupported"
        case .resetting: name = "resetting"
        case .unknown: name = "unknown"
        @unknown default: name = "unknown"
        }
        return "\(name) (\(state.rawValue))"
    }

    // MARK: - Device list

    /// Reconcile the per-device connection records with the pairing store.
    private func syncDevicesWithStore() {
        let stored = Set(pairingManager.loadDevices().map(\.sharedSecret))
        for token in stored where devices[token] == nil {
            devices[token] = DeviceConnection(token: token)
        }
        for token in devices.keys where !stored.contains(token) {
            if let device = devices[token] {
                closeConnection(of: device)
            }
            devices.removeValue(forKey: token)
        }
    }

    /// Tear down a device's session/peripheral and return it to idle.
    /// Does NOT notify the delegate — callers decide.
    private func closeConnection(of device: DeviceConnection) {
        device.state.session?.close()
        if let peripheral = device.peripheral {
            centralManager?.cancelPeripheralConnection(peripheral)
            rememberStaleAttemptIfNeeded(peripheral)
        }
        device.peripheral = nil
        device.channel = nil
        device.connectingStartTime = nil
        device.adapter = nil
        device.settingsProvider = nil
        device.state = .idle
    }

    /// A connect attempt failed or the connection dropped: back off and retry
    /// via scanning.
    private func failAttempt(_ device: DeviceConnection, reason: String) {
        let wasReady = device.state.isReady
        let delay = device.backoff.next()
        log("[\(reason)] \(device.token.prefix(8))… \(device.state) → idle (retry in \(String(format: "%.1f", delay))s)")
        closeConnection(of: device)
        device.nextAttemptAt = Date().addingTimeInterval(delay)
        if wasReady {
            notifyConnectionChanged()
        }
        ensureScanning()
    }

    // MARK: - Scanning

    /// Start or stop scanning based on need: scanning runs while pairing is
    /// active or any paired device is unconnected.
    fileprivate func ensureScanning() {
        guard let centralManager, centralManager.state == .poweredOn else { return }
        let needScan = pairingTag != nil
            || devices.values.contains { $0.state.isIdle && !$0.suspended }
        if needScan && !centralManager.isScanning {
            log("Scanning (paired: \(devices.count), pairing: \(pairingTag != nil))")
            centralManager.scanForPeripherals(
                withServices: [Self.serviceUUID],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
            )
        } else if !needScan && centralManager.isScanning {
            log("All paired devices connected — stopping scan")
            centralManager.stopScan()
        }
    }

    // MARK: - Health Check

    private func startHealthCheck() {
        healthCheckTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.healthCheckInterval, repeating: Self.healthCheckInterval)
        timer.setEventHandler { [weak self] in self?.performHealthCheck() }
        timer.resume()
        healthCheckTimer = timer
    }

    private func performHealthCheck() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let centralManager, centralManager.state == .poweredOn else { return }

        // Per-device connecting timeout
        for device in devices.values {
            switch device.state {
            case .bleConnecting, .l2capOpening:
                if let start = device.connectingStartTime,
                   Date().timeIntervalSince(start) > Self.connectingTimeout {
                    failAttempt(device, reason: "connectingTimeout")
                }
            default:
                break
            }
        }

        // Pairing connecting timeout
        if pairingTag != nil {
            switch pairingPhase {
            case .connecting, .l2capOpening:
                if let start = pairingConnectingStartTime,
                   Date().timeIntervalSince(start) > Self.connectingTimeout {
                    log("Health check: pairing connect timed out — back to scanning")
                    abortPairingAttempt()
                }
            default:
                break
            }
        }

        // Cycle the scan to pick up new advertisements
        if centralManager.isScanning {
            centralManager.stopScan()
        }
        ensureScanning()
    }

    // MARK: - Teardown

    /// Tear down all connections (BT off, app shutdown). Preserves pairing
    /// context when requested so pairing resumes once BT returns.
    private func teardownAll(reason: String, preservePairingContext: Bool) {
        log("[\(reason)] tearing down all connections")
        for device in devices.values {
            closeConnection(of: device)
            device.backoff.reset()
            device.nextAttemptAt = .distantPast
        }
        if case .handshake(let session) = pairingPhase {
            session.close()
        }
        if let peripheral = pairingPeripheral {
            centralManager?.cancelPeripheralConnection(peripheral)
            rememberStaleAttemptIfNeeded(peripheral)
        }
        pairingPeripheral = nil
        pairingChannel = nil
        pairingConnectingStartTime = nil
        pairingAdapter = nil
        pairingPhase = .scanning
        if !preservePairingContext {
            pairingTag = nil
            pairingPrivateKey = nil
        }
        if centralManager?.isScanning == true {
            centralManager?.stopScan()
        }
        generation &+= 1
        notifyConnectionChanged()
    }

    // MARK: - Notifications

    fileprivate func notifyConnectionChanged() {
        let readyTokens = devices.values
            .filter { $0.state.isReady }
            .map(\.token)
            .sorted()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isConnected = !readyTokens.isEmpty
            self.connectedTokens = readyTokens
            self.delegate?.didChangeState(connectedTokens: readyTokens)
        }
    }

    // MARK: - Paired Device Lookup

    /// First device that matches the advertised tag AND is eligible for a
    /// connect attempt. Several records can share a tag (e.g. a stale record
    /// left behind by re-pairing the same phone), so don't stop at the first
    /// tag match — a perpetually-failing stale record must not shadow the
    /// valid one.
    private func connectableDevice(matching tag: Data) -> DeviceConnection? {
        let now = Date()
        for paired in pairingManager.loadDevices() {
            guard pairingManager.scanTag(for: paired) == tag,
                  let device = devices[paired.sharedSecret],
                  device.state.isIdle,
                  !device.suspended,
                  now >= device.nextAttemptAt
            else { continue }
            return device
        }
        return nil
    }

    private func device(of peripheral: CBPeripheral) -> DeviceConnection? {
        devices.values.first { $0.peripheral === peripheral }
    }

    private func device(of session: Session) -> DeviceConnection? {
        devices.values.first { $0.state.session === session }
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
            self.teardownAll(reason: "disconnect", preservePairingContext: false)
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
    /// Existing device connections stay up — only the scan gains a pairing tag.
    func startPairing() -> PairingInfo? {
        pairingManager.removePendingDevices()
        let privateKey = pairingManager.generateKeyPair()
        guard let uri = pairingManager.pairingURI(publicKey: privateKey.publicKey) else { return nil }
        let tag = PairingManager.pairingTag(from: privateKey.publicKey.rawRepresentation)
        queue.async { [self] in
            pairingPrivateKey = privateKey
            pairingTag = tag
            pairingPhase = .scanning
            ensureScanning()
        }
        return PairingInfo(uri: uri)
    }

    func cancelPairing() {
        queue.async { [self] in
            pairingManager.clearEphemeralKey()
            pairingManager.removePendingDevices()
            abortPairingAttempt()
            pairingTag = nil
            pairingPrivateKey = nil
            ensureScanning()
        }
    }

    /// Abort an in-flight pairing connection attempt, returning the pairing
    /// flow to scanning (pairing tag/key stay set unless cleared by caller).
    fileprivate func abortPairingAttempt() {
        if case .handshake(let session) = pairingPhase {
            session.close()
        }
        if let peripheral = pairingPeripheral {
            centralManager?.cancelPeripheralConnection(peripheral)
            rememberStaleAttemptIfNeeded(peripheral)
        }
        pairingPeripheral = nil
        pairingChannel = nil
        pairingConnectingStartTime = nil
        pairingAdapter = nil
        pairingPhase = .scanning
        ensureScanning()
    }

    // MARK: Sending

    func sendClipboard(_ text: String) {
        queue.async { [self] in
            guard let data = text.data(using: .utf8) else { return }
            let hash = Session.sha256Hex(data)
            // Don't cache text we just received for reconnect-replay — it would
            // be sent back to its originator when that device reconnects.
            // (Live relay to *other* devices below is unaffected.)
            if hash != lastReceivedTextHash {
                pendingClipboard = data
            }
            var sentCount = 0
            for device in devices.values where device.state.isReady {
                // Skip the device that delivered this text to us (echo guard);
                // other devices still receive it, which relays a clipboard
                // from one phone to the rest.
                if device.adapter?.lastTextHash == hash { continue }
                device.state.session?.sendClipboard(data)
                sentCount += 1
            }
            if sentCount > 0 {
                log("Queued clipboard (\(data.count) bytes) to \(sentCount) device(s)")
            } else {
                log("Clipboard cached for reconnect (\(data.count) bytes)")
            }
        }
    }

    func sendImage(_ data: Data, contentType: String) {
        queue.async { [self] in
            let hash = Session.sha256Hex(data)
            guard hash != lastReceivedImageHash else { return }
            for device in devices.values where device.state.isReady {
                guard imageSyncEnabled(for: device.token) else { continue }
                device.state.session?.sendImage(data, contentType: contentType)
            }
        }
    }

    // MARK: Device Management

    func forgetDevice(token: String, completion: (() -> Void)? = nil) {
        queue.async { [self] in
            pairingManager.removeDevice(secret: token)
            if let device = devices[token] {
                let wasReady = device.state.isReady
                closeConnection(of: device)
                devices.removeValue(forKey: token)
                if wasReady {
                    notifyConnectionChanged()
                }
            }
            ensureScanning()
            if let completion {
                DispatchQueue.main.async(execute: completion)
            }
        }
    }

    var pairedDevices: [PairedDevice] {
        pairingManager.loadDevices()
    }

    // MARK: Settings

    /// Toggle image sync. With multiple connected devices the new value is
    /// applied to all of them (the setting syncs last-write-wins anyway).
    func toggleImageSync() {
        queue.async { [self] in
            let readyTokens = devices.values.filter { $0.state.isReady }.map(\.token)
            let targets = readyTokens.isEmpty
                ? pairingManager.loadDevices().prefix(1).map(\.sharedSecret)
                : readyTokens
            guard let first = targets.first else { return }
            let current = pairingManager.loadDevices()
                .first(where: { $0.sharedSecret == first })?.richMediaEnabled ?? false
            let newEnabled = !current
            let changedAt = Int64(Date().timeIntervalSince1970)
            for token in targets {
                pairingManager.setRichMediaEnabled(newEnabled, changedAt: changedAt, forSecret: token)
            }
            for device in devices.values where device.state.isReady {
                device.state.session?.sendConfigUpdate()
            }
            log("Image sync toggled to \(newEnabled) for \(targets.count) device(s)")
        }
    }

    /// Safe to call from main thread — uses cached `connectedTokens`.
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
        log("BT state: \(describe(central.state))")
        if central.state == .poweredOn {
            // Re-cancel peripherals from before the power cycle. cancelPeripheralConnection
            // during BT-off is a no-op, so internal CB connection bookkeeping can accumulate
            // across brief power nap cycles. Re-cancelling now releases dangling slots.
            for stale in staleAttemptedPeripherals.values {
                central.cancelPeripheralConnection(stale)
            }
            staleAttemptedPeripherals.removeAll()
            syncDevicesWithStore()
            for device in devices.values {
                device.backoff.reset()
                device.nextAttemptAt = .distantPast
                device.suspended = false  // version-mismatch suspension lifts on BT cycle
            }
            startHealthCheck()
            ensureScanning()
        } else {
            teardownAll(
                reason: "BT state \(describe(central.state))",
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
        guard let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              let deviceTag = Self.extractDeviceTag(from: manufacturerData),
              let psm = Self.extractPSM(from: manufacturerData)
        else { return }

        // Active pairing request takes priority
        if let pairingTag, pairingTag == deviceTag {
            guard case .scanning = pairingPhase else { return }
            log("Pairing target discovered, PSM=\(psm), RSSI=\(RSSI)")
            pairingPhase = .connecting(peripheral, psm)
            pairingPeripheral = peripheral
            pairingConnectingStartTime = Date()
            peripheral.delegate = self
            central.connect(peripheral, options: nil)
            ensureScanning()
            return
        }

        // In pairing mode, only match the pairing tag — don't start new
        // connections to existing paired devices (live ones stay connected).
        if pairingTag != nil { return }

        // Match against paired devices that are idle and past their backoff
        guard let device = connectableDevice(matching: deviceTag) else { return }

        log("Matched device tag for \(device.token.prefix(8))…, PSM=\(psm), RSSI=\(RSSI)")
        device.state = .bleConnecting(psm)
        device.peripheral = peripheral
        device.connectingStartTime = Date()
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
        // Keep scanning if other devices are still unconnected
        ensureScanning()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        if peripheral === pairingPeripheral, case .connecting(_, let psm) = pairingPhase {
            pairingPhase = .l2capOpening(peripheral)
            pairingConnectingStartTime = Date()  // reset for L2CAP open timeout
            log("Pairing: connected, opening L2CAP channel psm=\(psm)")
            peripheral.openL2CAPChannel(psm)
            return
        }

        guard let device = device(of: peripheral), case .bleConnecting(let psm) = device.state else {
            log("Stale didConnect, cancelling")
            central.cancelPeripheralConnection(peripheral)
            return
        }
        device.state = .l2capOpening
        device.connectingStartTime = Date()  // reset for L2CAP open timeout
        log("Connected \(device.token.prefix(8))…, opening L2CAP channel psm=\(psm)")
        peripheral.openL2CAPChannel(psm)
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        log("didFailToConnect: \(describe(error))")
        central.cancelPeripheralConnection(peripheral)
        if peripheral === pairingPeripheral {
            abortPairingAttempt()
            return
        }
        if let device = device(of: peripheral) {
            failAttempt(device, reason: "didFailToConnect")
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        log("didDisconnect: \(error == nil ? "clean" : describe(error))")
        if peripheral === pairingPeripheral {
            abortPairingAttempt()
            return
        }
        guard let device = device(of: peripheral) else {
            log("didDisconnect for unknown peripheral, ignoring")
            return
        }
        failAttempt(device, reason: "didDisconnect")
    }
}

// MARK: - CBPeripheralDelegate

extension ConnectionController: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        let isPairing = peripheral === pairingPeripheral

        if let error {
            log("L2CAP open error (\(isPairing ? "pairing" : "reconnect")): \(describe(error))")
            if isPairing {
                abortPairingAttempt()
            } else if let device = device(of: peripheral) {
                failAttempt(device, reason: "L2CAP open error")
            }
            return
        }

        guard let channel else {
            log("L2CAP open returned nil channel")
            if isPairing {
                abortPairingAttempt()
            } else if let device = device(of: peripheral) {
                failAttempt(device, reason: "L2CAP nil channel")
            }
            return
        }

        log("L2CAP channel opened (\(isPairing ? "pairing" : "reconnect")) — starting session")

        if isPairing {
            guard case .l2capOpening = pairingPhase else {
                log("Stale pairing didOpen, cancelling")
                centralManager?.cancelPeripheralConnection(peripheral)
                return
            }
            pairingConnectingStartTime = nil
            pairingChannel = channel
            startSession(channel: channel, device: nil)
            return
        }

        guard let device = device(of: peripheral), case .l2capOpening = device.state else {
            log("Stale didOpen, cancelling")
            centralManager?.cancelPeripheralConnection(peripheral)
            return
        }
        device.connectingStartTime = nil
        device.channel = channel
        startSession(channel: channel, device: device)
    }
}

// MARK: - Session Start

extension ConnectionController {

    /// Start a session on an opened L2CAP channel. `device == nil` means this
    /// is the pairing flow.
    fileprivate func startSession(channel: CBL2CAPChannel, device: DeviceConnection?) {
        guard let inputStream = channel.inputStream, let outputStream = channel.outputStream else {
            log("L2CAP channel missing streams")
            if let device {
                failAttempt(device, reason: "missing streams")
            } else {
                abortPairingAttempt()
            }
            return
        }

        // Open streams temporarily on main RunLoop (CoreBluetooth requirement)
        inputStream.schedule(in: .main, forMode: .common)
        outputStream.schedule(in: .main, forMode: .common)
        inputStream.open()
        outputStream.open()

        let adapter = SessionAdapter(controller: self, generation: generation)

        let session: Session
        if let device {
            let settingsProvider = DeviceSettingsProvider(pairingManager: pairingManager, secret: device.token)
            session = Session(inputStream: inputStream, outputStream: outputStream,
                              isInitiator: true, delegate: adapter, sharedSecretHex: device.token)
            session.localName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
            session.settingsProvider = settingsProvider
            device.adapter = adapter
            device.settingsProvider = settingsProvider  // retain (Session.settingsProvider is weak)
            device.state = .handshaking(session)
        } else {
            guard let privateKey = pairingPrivateKey else {
                log("Pairing channel but no ephemeral key")
                abortPairingAttempt()
                return
            }
            session = Session(inputStream: inputStream, outputStream: outputStream,
                              isInitiator: true, delegate: adapter,
                              mode: .pairing(privateKey: privateKey))
            session.localName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
            pairingAdapter = adapter
            pairingPhase = .handshake(session)
        }

        device?.backoff.reset()  // successful L2CAP — reset backoff

        // Spawn session thread
        let thread = Thread {
            inputStream.remove(from: .main, forMode: .common)
            outputStream.remove(from: .main, forMode: .common)
            let runLoop = RunLoop.current
            inputStream.schedule(in: runLoop, forMode: .common)
            outputStream.schedule(in: runLoop, forMode: .common)
            session.performHandshake()
            session.listenForMessages()
        }
        thread.name = device == nil ? "L2CAP-Pairing" : "L2CAP-Session"
        thread.start()
    }
}

// MARK: - Session Event Handlers

extension ConnectionController {

    fileprivate func handleSessionReady(_ session: Session) {
        guard let device = device(of: session), case .handshaking = device.state else {
            log("Stale sessionReady, ignoring")
            return
        }
        let remoteName = session.remoteName
        // Update stored device name
        if let name = remoteName {
            let stored = pairingManager.loadDevices()
            if let existing = stored.first(where: { $0.sharedSecret == device.token && $0.displayName != name }) {
                pairingManager.removeDevice(secret: device.token)
                let updated = PairedDevice(sharedSecret: existing.sharedSecret, displayName: name,
                                           datePaired: existing.datePaired,
                                           richMediaEnabled: existing.richMediaEnabled,
                                           richMediaEnabledChangedAt: existing.richMediaEnabledChangedAt,
                                           advertTagHex: existing.advertTagHex)
                pairingManager.addDevice(updated)
            }
        }
        device.state = .ready(session)
        device.backoff.reset()
        device.nextAttemptAt = .distantPast
        log("Session ready — remote: \(remoteName ?? "unknown") (\(connectedReadyCount()) connected)")
        notifyConnectionChanged()
        ensureScanning()
        // Send pending clipboard
        if let pending = pendingClipboard {
            session.sendClipboard(pending)
            log("Sent pending clipboard (\(pending.count) bytes)")
        }
    }

    private func connectedReadyCount() -> Int {
        devices.values.filter { $0.state.isReady }.count
    }

    fileprivate func handleSessionError(_ session: Session, error: Error) {
        log("Session error: \(error)")
        if case .handshake(let pairingSession) = pairingPhase, pairingSession === session {
            abortPairingAttempt()
            return
        }
        guard let device = device(of: session) else {
            log("Session error for unknown session, ignoring")
            return
        }
        if case SessionError.versionMismatch(let v) = error {
            // Don't keep retrying an outdated peer — every attempt would fail
            // the same way and re-trigger the update alert. Suspend until the
            // next Bluetooth power cycle.
            log("Version mismatch (v\(v)) — suspending \(device.token.prefix(8))…")
            closeConnection(of: device)
            device.suspended = true
            notifyConnectionChanged()
            ensureScanning()
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.didEncounterError(error: .versionMismatch(v))
            }
            return
        }
        failAttempt(device, reason: "session error")
    }

    fileprivate func handleClipboardReceived(plaintext: Data, hash: String) {
        lastReceivedTextHash = hash
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

    fileprivate func handlePairingComplete(_ session: Session, sharedSecret: Data, remoteName: String?) {
        let secretHex = sharedSecret.map { String(format: "%02x", $0) }.joined()
        log("Pairing complete")
        // The phone's stable identity tag arrived in KEY_EXCHANGE (nil on the
        // phone's first pairing — it then advertises the secret-derived tag).
        let advertTagHex = session.remoteAdvertTagHex
        let paired = PairedDevice(sharedSecret: secretHex, displayName: remoteName ?? "Android",
                                  datePaired: Date(), advertTagHex: advertTagHex)
        pairingManager.addDevice(paired)
        pairingManager.clearEphemeralKey()

        // Wire settings provider (hold strong ref via the device record so the
        // session's weak var isn't immediately nil)
        let provider = DeviceSettingsProvider(pairingManager: pairingManager, secret: secretHex)
        session.settingsProvider = provider

        // Promote the pairing session to a normal device connection: the
        // HELLO/WELCOME handshake continues on the same channel.
        syncDevicesWithStore()
        if let device = devices[secretHex] {
            device.state = .handshaking(session)
            device.peripheral = pairingPeripheral
            device.channel = pairingChannel
            device.adapter = pairingAdapter
            device.settingsProvider = provider
        }

        pairingPeripheral = nil
        pairingChannel = nil
        pairingConnectingStartTime = nil
        pairingAdapter = nil
        pairingPhase = .scanning
        pairingTag = nil
        pairingPrivateKey = nil
        ensureScanning()

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
/// `ConnectionController` handler methods on its serial queue, guarded by
/// generation. Handlers additionally locate the owning device by session
/// identity, so callbacks from replaced sessions are ignored.
class SessionAdapter: NSObject, SessionDelegate {
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
        dispatch { $0.handleSessionReady(session) }
    }

    func session(_ session: Session, didFailWithError error: Error) {
        dispatch { $0.handleSessionError(session, error: error) }
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
        dispatch { $0.handlePairingComplete(session, sharedSecret: sharedSecret, remoteName: remoteName) }
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
