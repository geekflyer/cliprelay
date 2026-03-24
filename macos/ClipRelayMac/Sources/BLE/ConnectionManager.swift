// BLE Central manager: scanning, L2CAP connections, and bidirectional data exchange with Android peers.

import CoreBluetooth
import Foundation
import os

private let connLogger = Logger(subsystem: "org.cliprelay", category: "ConnectionManager")

// MARK: - Delegate

protocol ConnectionManagerDelegate: AnyObject {
    /// Called when an L2CAP channel is established. Caller should create a Session with these streams.
    func connectionManager(_ manager: ConnectionManager, didEstablishChannel inputStream: InputStream,
                           outputStream: OutputStream, for token: String)
    /// Called when connection is lost. Caller should clean up the Session.
    func connectionManager(_ manager: ConnectionManager, didDisconnectFor token: String)
    /// Called when an L2CAP channel is established during pairing (no token yet).
    func connectionManager(_ manager: ConnectionManager, didEstablishPairingChannel inputStream: InputStream,
                           outputStream: OutputStream)
    /// Called when the Bluetooth hardware state changes.
    func connectionManager(_ manager: ConnectionManager, didUpdateBluetoothState state: CBManagerState)
}

extension ConnectionManagerDelegate {
    func connectionManager(_ manager: ConnectionManager, didEstablishPairingChannel inputStream: InputStream,
                           outputStream: OutputStream) {}
    func connectionManager(_ manager: ConnectionManager, didUpdateBluetoothState state: CBManagerState) {}
}

// MARK: - ConnectionManager

class ConnectionManager: NSObject {
    enum State: Equatable {
        case idle
        case scanning
        case connecting(CBPeripheral, CBL2CAPPSM)
        case openingL2CAP(CBPeripheral)
        case connected(CBPeripheral)
    }

    weak var delegate: ConnectionManagerDelegate?

    /// Provide paired device info for tag matching.
    /// Returns array of (token, tag) tuples where tag is 8-byte Data.
    var pairedDevices: () -> [(token: String, tag: Data)] = { [] }

    /// When set, scan for this pairing tag instead of paired device tags.
    var pairingTag: Data? {
        didSet {
            if pairingTag != nil {
                // Restart scanning in pairing mode
                if case .scanning = state { centralManager?.stopScan() }
                state = .idle
                startScanning()
            }
        }
    }

    private(set) var state: State = .idle
    private var centralManager: CBCentralManager!
    private var reconnectDelay: TimeInterval = 1.0
    private var reconnectTimer: Timer?
    private var l2capChannel: CBL2CAPChannel?  // strong reference required!
    private var matchedToken: String?
    private var healthCheckTimer: Timer?

    /// Timestamp when we entered .connecting or .openingL2CAP state.
    /// Used by health check to detect stuck connection attempts.
    private var connectingStartTime: Date?

    static let serviceUUID = CBUUID(string: "c10b0001-1234-5678-9abc-def012345678")
    static let maxReconnectDelay: TimeInterval = 30.0
    static let healthCheckInterval: TimeInterval = 60.0
    /// Max time to wait in .connecting/.openingL2CAP before giving up.
    /// Actual detection time is up to connectingTimeout + healthCheckInterval
    /// since the health check runs on a 60s repeating timer.
    static let connectingTimeout: TimeInterval = 15.0

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
        startHealthCheck()
    }

    /// Internal init that skips CBCentralManager creation (for testing).
    init(skipCentralManager: Bool) {
        super.init()
        if !skipCentralManager {
            centralManager = CBCentralManager(delegate: self, queue: nil)
            startHealthCheck()
        }
    }

    /// Set the matched token after pairing completes so that disconnect
    /// handling properly notifies the delegate.
    func setMatchedToken(_ token: String) {
        matchedToken = token
    }

    func startScanning() {
        guard centralManager?.state == .poweredOn else { return }
        guard case .idle = state else { return }
        state = .scanning
        connLogger.info("Starting BLE scan for ClipRelay peripherals")
        // allowDuplicates=true ensures we receive scan response data (manufacturer
        // data with device tag + PSM) even if CoreBluetooth initially reports the
        // peripheral with only the advertisement packet. Without this, a peripheral
        // discovered without scan response data is cached and never re-reported,
        // permanently blocking reconnection.
        centralManager.scanForPeripherals(
            withServices: [Self.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    func disconnect() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
        reconnectTimer?.invalidate()
        reconnectTimer = nil

        switch state {
        case .connecting(let peripheral, _),
             .openingL2CAP(let peripheral),
             .connected(let peripheral):
            centralManager?.cancelPeripheralConnection(peripheral)
        default:
            break
        }

        if case .scanning = state {
            centralManager?.stopScan()
        }

        l2capChannel = nil
        matchedToken = nil
        connectingStartTime = nil
        state = .idle
    }

    /// Tear down the current connection and start the reconnection cycle.
    /// Use when the session layer detects a failure but the BLE link may still be alive.
    func triggerReconnect() {
        switch state {
        case .connecting(let peripheral, _),
             .openingL2CAP(let peripheral),
             .connected(let peripheral):
            l2capChannel = nil
            matchedToken = nil
            connectingStartTime = nil
            centralManager?.cancelPeripheralConnection(peripheral)
            // didDisconnectPeripheral will set state to .idle and call scheduleReconnect()
        case .scanning:
            break  // already scanning for devices
        case .idle:
            resetReconnectDelay()
            startScanning()
        }
    }

    // MARK: - Health Check

    private func startHealthCheck() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: Self.healthCheckInterval, repeats: true) { [weak self] _ in
            self?.performHealthCheck()
        }
    }

    private func performHealthCheck() {
        guard centralManager?.state == .poweredOn else { return }

        // Handle stuck connection attempts: if we've been in .connecting or
        // .openingL2CAP for too long, cancel and start over. This prevents
        // permanent stalls when the L2CAP open hangs (e.g., wrong PSM after
        // Android BLE stack restart).
        switch state {
        case .connecting(let peripheral, _), .openingL2CAP(let peripheral):
            if let start = connectingStartTime, -start.timeIntervalSinceNow > Self.connectingTimeout {
                connLogger.warning("Health check: connection attempt stuck for \(Int(-start.timeIntervalSinceNow))s, cancelling")
                connectingStartTime = nil
                l2capChannel = nil
                matchedToken = nil
                // Set state to .idle immediately rather than waiting for
                // didDisconnectPeripheral — the CB delegate may never fire
                // in edge cases (sleep/wake BLE stack races).
                state = .idle
                centralManager?.cancelPeripheralConnection(peripheral)
                // Don't call scheduleReconnect() here — didDisconnectPeripheral
                // will handle it if it fires. If it doesn't, the next health
                // check will see .idle and restart scanning.
            }
            return
        default:
            break
        }

        // If we're scanning, cycle the scan periodically.
        // CoreBluetooth may not deliver scan response data on every report;
        // cycling ensures we get fresh advertisement data.
        if case .scanning = state {
            connLogger.info("Health check: cycling scan")
            centralManager?.stopScan()
            state = .idle
            startScanning()
            return
        }

        // If we're connected, the session layer handles liveness detection
        // via stream status checks. Nothing to do here.
        guard case .idle = state else { return }

        // If idle with no reconnect scheduled (e.g., timer expired but
        // startScanning failed due to a transient BT state), restart.
        connLogger.info("Health check: idle with no active reconnect, restarting scan")
        resetReconnectDelay()
        startScanning()
    }

    // MARK: - Reconnect Logic

    private func scheduleReconnect() {
        reconnectTimer?.invalidate()
        let delay = reconnectDelay
        connLogger.info("Scheduling reconnect in \(delay, format: .fixed(precision: 1))s")
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.reconnectTimer = nil  // clear reference so health check doesn't skip
            self?.startScanning()
        }
        reconnectDelay = min(reconnectDelay * 2, Self.maxReconnectDelay)
    }

    // MARK: - Manufacturer Data Extraction (internal for testing)

    /// Extract the 8-byte device tag from manufacturer data.
    /// Manufacturer data format: [2-byte company ID][8-byte device tag][2-byte PSM]
    static func extractDeviceTag(from manufacturerData: Data) -> Data? {
        guard manufacturerData.count >= 10 else { return nil }
        return manufacturerData.subdata(in: 2..<10)
    }

    /// Extract the L2CAP PSM from manufacturer data.
    /// Manufacturer data format: [2-byte company ID][8-byte device tag][2-byte PSM big-endian]
    static func extractPSM(from manufacturerData: Data) -> CBL2CAPPSM? {
        guard manufacturerData.count >= 12 else { return nil }
        let psm = UInt16(manufacturerData[10]) << 8 | UInt16(manufacturerData[11])
        guard psm > 0 else { return nil }
        return CBL2CAPPSM(psm)
    }

    // MARK: - Backoff (internal for testing)

    /// Calculate reconnect delay sequence. Returns the delay that *would* be used,
    /// and advances the internal delay for the next call.
    @discardableResult
    func nextReconnectDelay() -> TimeInterval {
        let current = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, Self.maxReconnectDelay)
        return current
    }

    /// Reset reconnect delay to initial value.
    func resetReconnectDelay() {
        reconnectDelay = 1.0
    }
}

// MARK: - CBCentralManagerDelegate

extension ConnectionManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        connLogger.info("Bluetooth state: \(central.state.rawValue)")
        delegate?.connectionManager(self, didUpdateBluetoothState: central.state)
        if central.state == .poweredOn {
            reconnectDelay = 1.0  // reset backoff on BT power cycle
            startHealthCheck()
            startScanning()
        } else {
            // BT powered off or transitioning — any in-progress connection is dead.
            // CoreBluetooth will fire didDisconnectPeripheral for connected peripherals,
            // but clear our tracking state now to be safe.
            connectingStartTime = nil
            state = .idle
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                         advertisementData: [String: Any], rssi: NSNumber) {
        // Ignore discoveries if we're already connecting or connected
        // (with allowDuplicates=true, we get many callbacks)
        switch state {
        case .connecting, .openingL2CAP, .connected:
            return
        default:
            break
        }

        // Extract device tag and PSM from manufacturer data (in scan response)
        guard let mfgData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data else { return }
        guard let tag = Self.extractDeviceTag(from: mfgData) else { return }
        guard let psm = Self.extractPSM(from: mfgData) else { return }

        // Check pairing mode first
        if let expectedPairingTag = pairingTag {
            if tag == expectedPairingTag {
                matchedToken = nil  // no token yet — will be set after ECDH
                connLogger.info("Matched pairing tag, PSM=\(psm)")

                central.stopScan()
                state = .connecting(peripheral, psm)
                connectingStartTime = Date()
                peripheral.delegate = self
                central.connect(peripheral)
            }
            return  // in pairing mode, only match pairing tag
        }

        // Match against paired tokens
        guard let matched = pairedDevices().first(where: { $0.tag == tag }) else { return }
        matchedToken = matched.token
        connLogger.info("Matched device tag for token, PSM=\(psm)")

        // Stop scanning, connect (will open L2CAP after BLE connection)
        central.stopScan()
        state = .connecting(peripheral, psm)
        connectingStartTime = Date()
        peripheral.delegate = self
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard case .connecting(_, let psm) = state else {
            connLogger.error("Connected but not in connecting state")
            centralManager.cancelPeripheralConnection(peripheral)
            return
        }
        connLogger.info("Connected to peripheral, opening L2CAP channel (PSM=\(psm))")
        state = .openingL2CAP(peripheral)
        connectingStartTime = Date()  // reset timeout for L2CAP open phase
        peripheral.openL2CAPChannel(psm)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connLogger.info("Failed to connect: \(error?.localizedDescription ?? "unknown")")
        connectingStartTime = nil
        state = .idle
        scheduleReconnect()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                         error: Error?) {
        connLogger.info("Disconnected: \(error?.localizedDescription ?? "clean")")
        let token = matchedToken
        l2capChannel = nil
        matchedToken = nil
        connectingStartTime = nil
        state = .idle
        if let token = token {
            delegate?.connectionManager(self, didDisconnectFor: token)
        }
        scheduleReconnect()
    }
}

// MARK: - CBPeripheralDelegate

extension ConnectionManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        connectingStartTime = nil
        guard let channel = channel, error == nil else {
            connLogger.error("L2CAP open failed: \(error?.localizedDescription ?? "nil channel")")
            centralManager.cancelPeripheralConnection(peripheral)
            return
        }

        // CRITICAL: Keep strong reference to channel (CoreBluetooth deallocates otherwise)
        l2capChannel = channel
        state = .connected(peripheral)
        reconnectDelay = 1.0  // reset backoff on successful connection
        connLogger.info("L2CAP channel established, handing off to delegate")

        // Schedule streams on main RunLoop (avoids threading pitfalls on macOS)
        channel.inputStream.schedule(in: .main, forMode: .common)
        channel.outputStream.schedule(in: .main, forMode: .common)
        channel.inputStream.open()
        channel.outputStream.open()

        // Hand off to delegate
        if let token = matchedToken {
            delegate?.connectionManager(self, didEstablishChannel: channel.inputStream,
                                        outputStream: channel.outputStream, for: token)
        } else if pairingTag != nil {
            // Pairing mode — no token yet
            delegate?.connectionManager(self, didEstablishPairingChannel: channel.inputStream,
                                        outputStream: channel.outputStream)
        }
    }
}
