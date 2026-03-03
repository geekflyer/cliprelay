// BLE Central manager: scanning, L2CAP connections, and bidirectional data exchange with Android peers.

import CoreBluetooth
import Foundation
import os

private let connLogger = Logger(subsystem: "com.cliprelay", category: "ConnectionManager")

private func debugLog(_ message: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "[\(ts)] \(message)\n"
    let path = "/tmp/cliprelay-debug.log"
    if let fh = FileHandle(forWritingAtPath: path) {
        fh.seekToEndOfFile()
        fh.write(Data(line.utf8))
        fh.closeFile()
    } else {
        FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
    }
}

// MARK: - Delegate

protocol ConnectionManagerDelegate: AnyObject {
    /// Called when an L2CAP channel is established. Caller should create a Session with these streams.
    func connectionManager(_ manager: ConnectionManager, didEstablishChannel inputStream: InputStream,
                           outputStream: OutputStream, for token: String)
    /// Called when connection is lost. Caller should clean up the Session.
    func connectionManager(_ manager: ConnectionManager, didDisconnectFor token: String)
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

    private(set) var state: State = .idle
    private var centralManager: CBCentralManager!
    private var reconnectDelay: TimeInterval = 1.0
    private var reconnectTimer: Timer?
    private var l2capChannel: CBL2CAPChannel?  // strong reference required!
    private var matchedToken: String?

    static let serviceUUID = CBUUID(string: "c10b0001-1234-5678-9abc-def012345678")
    static let maxReconnectDelay: TimeInterval = 30.0

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    /// Internal init that skips CBCentralManager creation (for testing).
    init(skipCentralManager: Bool) {
        super.init()
        if !skipCentralManager {
            centralManager = CBCentralManager(delegate: self, queue: nil)
        }
    }

    func startScanning() {
        guard centralManager?.state == .poweredOn else { return }
        guard case .idle = state else { return }
        state = .scanning
        debugLog("[CM] Starting BLE scan")
        connLogger.info("Starting BLE scan for ClipRelay peripherals")
        centralManager.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)
    }

    func disconnect() {
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
        state = .idle
    }

    // MARK: - Reconnect Logic

    private func scheduleReconnect() {
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: reconnectDelay, repeats: false) { [weak self] _ in
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
        debugLog("[CM] Bluetooth state: \(central.state.rawValue)")
        if central.state == .poweredOn {
            reconnectDelay = 1.0  // reset backoff on BT power cycle
            startScanning()
        } else {
            connLogger.info("Bluetooth state changed: \(central.state.rawValue)")
            state = .idle
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                         advertisementData: [String: Any], rssi: NSNumber) {
        // Extract device tag and PSM from manufacturer data
        guard let mfgData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data else { return }
        guard let tag = Self.extractDeviceTag(from: mfgData) else { return }
        guard let psm = Self.extractPSM(from: mfgData) else { return }

        // Match against paired tokens
        guard let matched = pairedDevices().first(where: { $0.tag == tag }) else { return }
        matchedToken = matched.token
        debugLog("[CM] Matched device tag, PSM=\(psm)")
        connLogger.info("Matched device tag for token, PSM=\(psm)")

        // Stop scanning, connect (will open L2CAP after BLE connection)
        central.stopScan()
        state = .connecting(peripheral, psm)
        peripheral.delegate = self
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard case .connecting(_, let psm) = state else {
            connLogger.error("Connected but not in connecting state")
            centralManager.cancelPeripheralConnection(peripheral)
            return
        }
        debugLog("[CM] Connected, opening L2CAP (PSM=\(psm))")
        connLogger.info("Connected to peripheral, opening L2CAP channel (PSM=\(psm))")
        state = .openingL2CAP(peripheral)
        peripheral.openL2CAPChannel(psm)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        debugLog("[CM] Failed to connect: \(error?.localizedDescription ?? "unknown")")
        state = .idle
        scheduleReconnect()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                         error: Error?) {
        debugLog("[CM] Disconnected: \(error?.localizedDescription ?? "clean")")
        let token = matchedToken
        l2capChannel = nil
        matchedToken = nil
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
        guard let channel = channel, error == nil else {
            debugLog("[CM] L2CAP open failed: \(error?.localizedDescription ?? "nil channel")")
            centralManager.cancelPeripheralConnection(peripheral)
            return
        }

        // CRITICAL: Keep strong reference to channel (CoreBluetooth deallocates otherwise)
        l2capChannel = channel
        state = .connected(peripheral)
        reconnectDelay = 1.0  // reset backoff on successful connection
        debugLog("[CM] L2CAP channel established, handing off to delegate")

        // Schedule streams on main RunLoop (avoids threading pitfalls on macOS)
        channel.inputStream.schedule(in: .main, forMode: .common)
        channel.outputStream.schedule(in: .main, forMode: .common)
        channel.inputStream.open()
        channel.outputStream.open()

        // Hand off to delegate
        if let token = matchedToken {
            delegate?.connectionManager(self, didEstablishChannel: channel.inputStream,
                                        outputStream: channel.outputStream, for: token)
        }
    }
}
