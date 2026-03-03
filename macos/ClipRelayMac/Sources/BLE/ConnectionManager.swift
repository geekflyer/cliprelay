import CoreBluetooth
import Foundation
import os

private let connLogger = Logger(subsystem: "com.cliprelay", category: "ConnectionManager")

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
        case connecting(CBPeripheral)
        case readingPSM(CBPeripheral)
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
    static let psmCharUUID = CBUUID(string: "c10b0010-1234-5678-9abc-def012345678")
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
        connLogger.info("Starting BLE scan for ClipRelay peripherals")
        centralManager.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)
    }

    func disconnect() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil

        switch state {
        case .connecting(let peripheral),
             .readingPSM(let peripheral),
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

    // MARK: - Tag Extraction (internal for testing)

    /// Extract the 8-byte device tag from manufacturer data.
    /// Manufacturer data format: [2-byte company ID (0xFFFF)][8-byte device tag]
    static func extractDeviceTag(from manufacturerData: Data) -> Data? {
        guard manufacturerData.count >= 10 else { return nil }
        return manufacturerData.subdata(in: 2..<10)
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
        if central.state == .poweredOn {
            reconnectDelay = 1.0  // reset backoff on BT power cycle
            startScanning()
        } else {
            // BT turned off or unavailable -- go idle
            connLogger.info("Bluetooth state changed: \(central.state.rawValue)")
            state = .idle
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                         advertisementData: [String: Any], rssi: NSNumber) {
        // Extract device tag from manufacturer data
        guard let mfgData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data else { return }
        guard let tag = Self.extractDeviceTag(from: mfgData) else { return }

        // Match against paired tokens
        guard let matched = pairedDevices().first(where: { $0.tag == tag }) else { return }
        matchedToken = matched.token
        connLogger.info("Matched device tag for token: \(matched.token, privacy: .private)")

        // Stop scanning, connect
        central.stopScan()
        state = .connecting(peripheral)
        peripheral.delegate = self
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connLogger.info("Connected to peripheral, discovering services")
        state = .readingPSM(peripheral)
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connLogger.error("Failed to connect: \(error?.localizedDescription ?? "unknown")")
        state = .idle
        scheduleReconnect()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                         error: Error?) {
        connLogger.info("Disconnected from peripheral: \(error?.localizedDescription ?? "clean")")
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
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil,
              let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            connLogger.error("Service discovery failed: \(error?.localizedDescription ?? "service not found")")
            centralManager.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics([Self.psmCharUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                     error: Error?) {
        guard error == nil,
              let char = service.characteristics?.first(where: { $0.uuid == Self.psmCharUUID }) else {
            connLogger.error("Characteristic discovery failed: \(error?.localizedDescription ?? "char not found")")
            centralManager.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.readValue(for: char)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                     error: Error?) {
        guard error == nil,
              characteristic.uuid == Self.psmCharUUID,
              let data = characteristic.value,
              data.count == 2 else {
            connLogger.error("PSM read failed: \(error?.localizedDescription ?? "invalid data")")
            centralManager.cancelPeripheralConnection(peripheral)
            return
        }

        let psm = UInt16(data[0]) << 8 | UInt16(data[1])  // big-endian
        connLogger.info("Read PSM: \(psm)")
        state = .openingL2CAP(peripheral)
        peripheral.openL2CAPChannel(CBL2CAPPSM(psm))
    }

    func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        guard let channel = channel, error == nil else {
            connLogger.error("L2CAP open failed: \(error?.localizedDescription ?? "nil channel")")
            centralManager.cancelPeripheralConnection(peripheral)
            return
        }

        // CRITICAL: Keep strong reference to channel (CoreBluetooth deallocates otherwise)
        l2capChannel = channel
        state = .connected(peripheral)
        reconnectDelay = 1.0  // reset backoff on successful connection
        connLogger.info("L2CAP channel established")

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
