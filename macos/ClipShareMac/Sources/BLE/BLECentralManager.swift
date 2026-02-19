import CoreBluetooth
import CryptoKit
import Foundation

enum BLEProtocol {
    static let serviceUUID = CBUUID(string: "C10B0001-1234-5678-9ABC-DEF012345678")
    static let availableUUID = CBUUID(string: "C10B0002-1234-5678-9ABC-DEF012345678")
    static let dataUUID = CBUUID(string: "C10B0003-1234-5678-9ABC-DEF012345678")
}

struct ClipboardAvailableMessage: Codable {
    let hash: String
    let size: Int
    let type: String
    let tx_id: String
}

final class BLECentralManager: NSObject {
    var onConnectionStateChanged: ((Bool) -> Void)?
    var onClipboardReceived: ((String) -> Void)?

    private let clipboardWriter: ClipboardWriter

    private var centralManager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var availableCharacteristic: CBCharacteristic?
    private var dataCharacteristic: CBCharacteristic?

    private let assembler = ChunkAssembler()
    private var reconnectDelay: TimeInterval = 1
    private var lastInboundHash: String?
    private var pendingInboundHashFromMetadata: String?

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
        guard
            let peripheral,
            let availableCharacteristic,
            let dataCharacteristic
        else {
            return
        }

        let payload = Data(text.utf8)
        guard payload.count <= 102_400 else { return }

        let txID = UUID().uuidString.lowercased()
        let metadata = ClipboardAvailableMessage(
            hash: sha256Hex(payload),
            size: payload.count,
            type: "text/plain",
            tx_id: txID
        )

        guard
            let metadataData = try? JSONEncoder().encode(metadata),
            let frames = makeChunkFrames(payload: payload, txID: txID)
        else {
            return
        }

        peripheral.writeValue(metadataData, for: availableCharacteristic, type: .withResponse)

        for (index, frame) in frames.enumerated() {
            let delay = Double(index) * 0.01
            let writeType: CBCharacteristicWriteType = index == 0 ? .withResponse : .withoutResponse
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.peripheral == peripheral, self.dataCharacteristic != nil else { return }
                peripheral.writeValue(frame, for: dataCharacteristic, type: writeType)
            }
        }
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

    private func makeChunkFrames(payload: Data, txID: String) -> [Data]? {
        let chunkPayloadSize = 509
        let totalChunks = Int(ceil(Double(payload.count) / Double(chunkPayloadSize)))
        guard totalChunks > 0 else { return nil }

        let header = ChunkHeader(tx_id: txID, total_chunks: totalChunks, total_bytes: payload.count, encoding: "utf-8")
        guard let headerData = try? JSONEncoder().encode(header) else {
            return nil
        }

        var frames = [headerData]
        frames.reserveCapacity(totalChunks + 1)

        for index in 0..<totalChunks {
            let start = index * chunkPayloadSize
            let end = min(start + chunkPayloadSize, payload.count)
            var frame = Data()
            frame.append(UInt8((index >> 8) & 0xFF))
            frame.append(UInt8(index & 0xFF))
            frame.append(payload[start..<end])
            frames.append(frame)
        }

        return frames
    }

    private func decodeClipboardPayload(_ payload: Data, encoding: String) -> String? {
        guard encoding == "utf-8" else { return nil }
        return String(data: payload, encoding: .utf8)
    }

    private func processAvailableMetadata(_ data: Data) {
        guard let message = try? JSONDecoder().decode(ClipboardAvailableMessage.self, from: data) else {
            return
        }

        pendingInboundHashFromMetadata = message.hash.isEmpty ? nil : message.hash
    }

    private func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
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
        self.peripheral = nil
        availableCharacteristic = nil
        dataCharacteristic = nil
        pendingInboundHashFromMetadata = nil
        assembler.clear()
        scheduleReconnect()
    }
}

extension BLECentralManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        peripheral.services?.forEach {
            peripheral.discoverCharacteristics([BLEProtocol.availableUUID, BLEProtocol.dataUUID], for: $0)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        service.characteristics?.forEach { characteristic in
            if characteristic.uuid == BLEProtocol.availableUUID || characteristic.uuid == BLEProtocol.dataUUID {
                peripheral.setNotifyValue(true, for: characteristic)
            }

            if characteristic.uuid == BLEProtocol.availableUUID {
                availableCharacteristic = characteristic
            }

            if characteristic.uuid == BLEProtocol.dataUUID {
                dataCharacteristic = characteristic
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }

        if characteristic.uuid == BLEProtocol.availableUUID {
            processAvailableMetadata(data)
            return
        }

        guard characteristic.uuid == BLEProtocol.dataUUID else {
            return
        }

        if let header = try? JSONDecoder().decode(ChunkHeader.self, from: data) {
            assembler.reset(with: header)
            return
        }

        assembler.appendChunkFrame(data)
        guard let assembledData = assembler.assembleData() else { return }
        guard let output = decodeClipboardPayload(assembledData, encoding: assembler.encoding) else { return }

        let outputData = Data(output.utf8)
        let hash = sha256Hex(outputData)

        if let metadataHash = pendingInboundHashFromMetadata, !metadataHash.isEmpty, metadataHash != hash {
            pendingInboundHashFromMetadata = nil
            return
        }

        pendingInboundHashFromMetadata = nil

        guard hash != lastInboundHash else { return }

        lastInboundHash = hash
        clipboardWriter.writeText(output)
        onClipboardReceived?(output)
    }
}
