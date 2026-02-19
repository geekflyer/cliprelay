import CoreBluetooth
import CryptoKit
import Foundation
import Security

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

struct EncryptedClipboardEnvelope: Codable {
    let algorithm: String?
    let session: String?
    let nonce: String
    let ciphertext: String
}

final class BLECentralManager: NSObject {
    var onConnectionStateChanged: ((Bool) -> Void)?
    var onClipboardReceived: ((String) -> Void)?

    private let clipboardWriter: ClipboardWriter
    private let sharedSeedProvider: () -> Data

    private var centralManager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var pushCharacteristic: CBCharacteristic?
    private var availableCharacteristic: CBCharacteristic?
    private let assembler = ChunkAssembler()
    private var reconnectDelay: TimeInterval = 1
    private var expectedPairingTokenHex: String?
    private var lastInboundHash: String?

    init(
        clipboardWriter: ClipboardWriter,
        sharedSeedProvider: @escaping () -> Data = { Data("clipboard-sync-dev-seed".utf8) }
    ) {
        self.clipboardWriter = clipboardWriter
        self.sharedSeedProvider = sharedSeedProvider
        super.init()
        self.centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    func setExpectedPairingToken(_ tokenHex: String?) {
        let normalized = tokenHex?.trimmingCharacters(in: .whitespacesAndNewlines)
        expectedPairingTokenHex = normalized?.isEmpty == false ? normalized?.lowercased() : nil

        if centralManager.state == .poweredOn {
            centralManager.stopScan()
            if peripheral == nil {
                scan()
            }
        }
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

        if let availableCharacteristic {
            let metadata = ClipboardAvailableMessage(
                hash: sha256Hex(data),
                size: data.count,
                type: "text/plain"
            )
            if let metadataData = try? JSONEncoder().encode(metadata) {
                peripheral.writeValue(metadataData, for: availableCharacteristic, type: .withResponse)
            }
        }

        guard let frames = makeEncryptedChunkFrames(plaintext: data) else { return }

        for (index, frame) in frames.enumerated() {
            let delay = Double(index) * 0.01
            let type: CBCharacteristicWriteType = index == 0 ? .withResponse : .withoutResponse
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.peripheral == peripheral, self.pushCharacteristic != nil else { return }
                peripheral.writeValue(frame, for: characteristic, type: type)
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

    private func shouldConnect(advertisementData: [String: Any]) -> Bool {
        guard
            let tokenHex = expectedPairingTokenHex,
            !tokenHex.isEmpty
        else {
            return true
        }

        guard
            let expectedPrefix = PairingManager.tokenPrefixData(tokenHex: tokenHex, length: 8),
            let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data],
            let advertisedTokenPrefix = serviceData[BLEProtocol.serviceUUID]
        else {
            return false
        }

        return advertisedTokenPrefix.starts(with: expectedPrefix)
    }

    private func makeEncryptedChunkFrames(plaintext: Data) -> [Data]? {
        let sessionNonce = randomData(length: 16)
        let nonceData = randomData(length: 12)

        let key = E2ECrypto.transportKey(seed: sharedSeedProvider(), sessionNonce: sessionNonce)
        guard let nonce = try? AES.GCM.Nonce(data: nonceData) else { return nil }
        guard let sealed = try? AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: Data("clipboard-sync-v1".utf8)) else {
            return nil
        }

        let payload = sealed.ciphertext + sealed.tag
        let envelope = EncryptedClipboardEnvelope(
            algorithm: "aes-256-gcm",
            session: sessionNonce.base64EncodedString(),
            nonce: nonceData.base64EncodedString(),
            ciphertext: payload.base64EncodedString()
        )

        guard let envelopeData = try? JSONEncoder().encode(envelope) else {
            return nil
        }

        let chunkPayloadSize = 509
        let totalChunks = Int(ceil(Double(envelopeData.count) / Double(chunkPayloadSize)))
        guard totalChunks > 0 else { return nil }

        let header = ChunkHeader(total_chunks: totalChunks, total_bytes: envelopeData.count, encoding: "aes-gcm-json")
        guard let headerData = try? JSONEncoder().encode(header) else {
            return nil
        }

        var frames: [Data] = [headerData]
        frames.reserveCapacity(totalChunks + 1)

        for index in 0..<totalChunks {
            let start = index * chunkPayloadSize
            let end = min(start + chunkPayloadSize, envelopeData.count)
            var frame = Data()
            frame.append(UInt8((index >> 8) & 0xFF))
            frame.append(UInt8(index & 0xFF))
            frame.append(envelopeData[start..<end])
            frames.append(frame)
        }

        return frames
    }

    private func decodeClipboardPayload(_ payload: Data, encoding: String) -> String? {
        if encoding == "aes-gcm-json" {
            return decryptEnvelope(payload)
        }
        return String(data: payload, encoding: .utf8)
    }

    private func decryptEnvelope(_ payload: Data) -> String? {
        guard
            let envelope = try? JSONDecoder().decode(EncryptedClipboardEnvelope.self, from: payload),
            let nonceData = Data(base64Encoded: envelope.nonce),
            let ciphertextData = Data(base64Encoded: envelope.ciphertext)
        else {
            return nil
        }

        let sessionNonce = envelope.session.flatMap { Data(base64Encoded: $0) }

        var blob = Data()
        blob.append(nonceData)
        blob.append(ciphertextData)

        let key = E2ECrypto.transportKey(seed: sharedSeedProvider(), sessionNonce: sessionNonce)
        guard let plaintext = try? E2ECrypto.open(blob, key: key) else {
            return nil
        }

        return String(data: plaintext, encoding: .utf8)
    }

    private func randomData(length: Int) -> Data {
        var bytes = Data(count: length)
        _ = bytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, length, $0.baseAddress!)
        }
        return bytes
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
        guard shouldConnect(advertisementData: advertisementData) else {
            return
        }

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
        self.pushCharacteristic = nil
        self.availableCharacteristic = nil
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
            if characteristic.uuid == BLEProtocol.availableUUID {
                availableCharacteristic = characteristic
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        if characteristic.uuid == BLEProtocol.dataUUID {
            if let header = try? JSONDecoder().decode(ChunkHeader.self, from: data) {
                assembler.reset(with: header)
                return
            }

            assembler.appendChunkFrame(data)
            guard let assembledData = assembler.assembleData() else { return }
            guard let output = decodeClipboardPayload(assembledData, encoding: assembler.encoding) else { return }

            let outputData = Data(output.utf8)
            let hash = sha256Hex(outputData)
            guard hash != lastInboundHash else { return }

            lastInboundHash = hash
            clipboardWriter.writeText(output)
            onClipboardReceived?(output)
        }
    }
}
