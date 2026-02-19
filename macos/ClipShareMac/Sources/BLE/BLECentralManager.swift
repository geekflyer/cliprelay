import CoreBluetooth
import CryptoKit
import Foundation

enum BLEProtocol {
    static let serviceUUID = CBUUID(string: "C10B0001-1234-5678-9ABC-DEF012345678")
    static let availableUUID = CBUUID(string: "C10B0002-1234-5678-9ABC-DEF012345678")
    static let dataUUID = CBUUID(string: "C10B0003-1234-5678-9ABC-DEF012345678")
    static let pushUUID = CBUUID(string: "C10B0004-1234-5678-9ABC-DEF012345678")
    static let deviceInfoUUID = CBUUID(string: "C10B0005-1234-5678-9ABC-DEF012345678")
}

struct ClipboardAvailableMessage: Codable {
    let hash: String
    let size: Int
    let type: String
}

final class BLECentralManager: NSObject {
    var onConnectionStateChanged: ((Bool) -> Void)?

    private let clipboardWriter: ClipboardWriter
    private var centralManager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var pushCharacteristic: CBCharacteristic?
    private let assembler = ChunkAssembler()
    private var reconnectDelay: TimeInterval = 1

    init(clipboardWriter: ClipboardWriter) {
        self.clipboardWriter = clipboardWriter
        super.init()
        self.centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    func start() {
        if centralManager.state == .poweredOn {
            scan()
        }
    }

    func stop() {
        if let peripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        centralManager.stopScan()
    }

    func sendClipboardText(_ text: String) {
        guard let peripheral, let characteristic = pushCharacteristic else { return }
        let data = Data(text.utf8)
        guard data.count <= 102_400 else { return }
        peripheral.writeValue(data, for: characteristic, type: .withResponse)
    }

    private func scan() {
        centralManager.scanForPeripherals(withServices: [BLEProtocol.serviceUUID], options: nil)
    }

    private func scheduleReconnect() {
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 30)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.scan()
        }
    }
}

extension BLECentralManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            scan()
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        self.peripheral = peripheral
        peripheral.delegate = self
        central.stopScan()
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        reconnectDelay = 1
        onConnectionStateChanged?(true)
        peripheral.discoverServices([BLEProtocol.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        onConnectionStateChanged?(false)
        scheduleReconnect()
    }
}

extension BLECentralManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        peripheral.services?.forEach {
            peripheral.discoverCharacteristics([BLEProtocol.availableUUID, BLEProtocol.dataUUID, BLEProtocol.pushUUID], for: $0)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        service.characteristics?.forEach { characteristic in
            if characteristic.uuid == BLEProtocol.availableUUID || characteristic.uuid == BLEProtocol.dataUUID {
                peripheral.setNotifyValue(true, for: characteristic)
            }
            if characteristic.uuid == BLEProtocol.pushUUID {
                pushCharacteristic = characteristic
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        if characteristic.uuid == BLEProtocol.dataUUID {
            if let text = String(data: data, encoding: .utf8), let headerData = text.data(using: .utf8), let header = try? JSONDecoder().decode(ChunkHeader.self, from: headerData) {
                assembler.reset(with: header)
            } else {
                assembler.appendChunkFrame(data)
                if let output = assembler.assembleString() {
                    clipboardWriter.writeText(output)
                }
            }
        }
    }
}
