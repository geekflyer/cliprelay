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

struct PeerSummary {
    let id: UUID
    let description: String
    var token: String?
}

private struct ConnectedPeer {
    let peripheral: CBPeripheral
    let token: String
    let displayName: String
    var availableCharacteristic: CBCharacteristic?
    var dataCharacteristic: CBCharacteristic?
}

final class BLECentralManager: NSObject {
    var onConnectedPeersChanged: (([PeerSummary]) -> Void)?
    var onTrustedPeersChanged: (([PeerSummary]) -> Void)?
    var onClipboardReceived: ((String) -> Void)?

    private let clipboardWriter: ClipboardWriter
    private let pairingManager: PairingManager

    private var centralManager: CBCentralManager!
    private var knownPeripherals: [UUID: CBPeripheral] = [:]
    private var peripheralTokenMap: [UUID: String] = [:]
    private var connectingPeerIDs: Set<UUID> = []
    private var connectedPeers: [UUID: ConnectedPeer] = [:]

    private var reconnectDelay: TimeInterval = 1
    private var lastInboundHash: String?
    private var pendingInboundHashByPeer: [UUID: String] = [:]
    private var assemblerByPeer: [UUID: ChunkAssembler] = [:]

    init(clipboardWriter: ClipboardWriter, pairingManager: PairingManager) {
        self.clipboardWriter = clipboardWriter
        self.pairingManager = pairingManager
        super.init()
        self.centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    func start() {
        notifyAllState()
        if centralManager.state == .poweredOn {
            scan()
        }
    }

    func stop() {
        for peer in connectedPeers.values {
            centralManager.cancelPeripheralConnection(peer.peripheral)
        }
        connectingPeerIDs.removeAll()
        connectedPeers.removeAll()
        pendingInboundHashByPeer.removeAll()
        assemblerByPeer.removeAll()
        centralManager.stopScan()
        notifyAllState()
    }

    func forgetDevice(token: String) {
        pairingManager.removeDevice(token: token)

        let peripheralIDs = peripheralTokenMap.filter { $0.value == token }.map(\.key)
        for id in peripheralIDs {
            if let peer = connectedPeers[id] {
                centralManager.cancelPeripheralConnection(peer.peripheral)
            }
            connectingPeerIDs.remove(id)
            connectedPeers.removeValue(forKey: id)
            pendingInboundHashByPeer.removeValue(forKey: id)
            assemblerByPeer.removeValue(forKey: id)
            peripheralTokenMap.removeValue(forKey: id)
        }

        notifyAllState()
    }

    func sendClipboardText(_ text: String) {
        let plaintext = Data(text.utf8)
        guard plaintext.count <= 102_400 else { return }

        let readyPeers = connectedPeers.values.filter { peer in
            peer.availableCharacteristic != nil && peer.dataCharacteristic != nil
        }
        guard !readyPeers.isEmpty else { return }

        for peer in readyPeers {
            guard
                let key = pairingManager.encryptionKey(for: peer.token),
                let encrypted = try? E2ECrypto.seal(plaintext, key: key)
            else { continue }

            let txID = UUID().uuidString.lowercased()
            let metadata = ClipboardAvailableMessage(
                hash: sha256Hex(encrypted),
                size: encrypted.count,
                type: "text/plain",
                tx_id: txID
            )

            guard
                let metadataData = try? JSONEncoder().encode(metadata),
                let frames = makeChunkFrames(payload: encrypted, txID: txID),
                let availableChar = peer.availableCharacteristic
            else { continue }

            peer.peripheral.writeValue(metadataData, for: availableChar, type: .withResponse)

            for (index, frame) in frames.enumerated() {
                let delay = Double(index) * 0.01
                let writeType: CBCharacteristicWriteType = index == 0 ? .withResponse : .withoutResponse
                let peripheral = peer.peripheral
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard
                        let self,
                        let currentPeer = self.connectedPeers[peripheral.identifier],
                        let dataChar = currentPeer.dataCharacteristic
                    else { return }
                    peripheral.writeValue(frame, for: dataChar, type: writeType)
                }
            }
        }
    }

    // MARK: - Notify UI

    func notifyAllState() {
        let connected = connectedPeerSummaries()
        onConnectedPeersChanged?(connected)
        onTrustedPeersChanged?(trustedPeerSummaries())
    }

    private func connectedPeerSummaries() -> [PeerSummary] {
        connectedPeers.map {
            PeerSummary(id: deviceStableID(token: $0.value.token), description: $0.value.displayName, token: $0.value.token)
        }
        .sorted { $0.description.localizedCaseInsensitiveCompare($1.description) == .orderedAscending }
    }

    private func trustedPeerSummaries() -> [PeerSummary] {
        pairingManager.loadDevices().map { device in
            PeerSummary(id: deviceStableID(token: device.token), description: device.displayName, token: device.token)
        }
        .sorted { $0.description.localizedCaseInsensitiveCompare($1.description) == .orderedAscending }
    }

    /// Stable UUID derived from token for UI identification (not a BLE peripheral UUID).
    private func deviceStableID(token: String) -> UUID {
        guard let data = pairingManager.deviceTag(for: token) else {
            return UUID()
        }
        // Pad to 16 bytes for UUID
        var bytes = [UInt8](repeating: 0, count: 16)
        for (i, b) in data.prefix(16).enumerated() {
            bytes[i] = b
        }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    // MARK: - Connection

    private func connectToPairedPeerIfNeeded(peripheralID: UUID) {
        guard connectedPeers[peripheralID] == nil else { return }
        guard !connectingPeerIDs.contains(peripheralID) else { return }
        guard let peripheral = knownPeripherals[peripheralID] else { return }

        connectingPeerIDs.insert(peripheralID)
        peripheral.delegate = self
        centralManager.connect(peripheral, options: nil)
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

    // MARK: - Crypto helpers

    private func encryptionKeyForPeer(_ peripheralID: UUID) -> SymmetricKey? {
        guard let token = peripheralTokenMap[peripheralID] else { return nil }
        return pairingManager.encryptionKey(for: token)
    }

    // MARK: - Chunking

    private func makeChunkFrames(payload: Data, txID: String) -> [Data]? {
        let chunkPayloadSize = 509
        let totalChunks = Int(ceil(Double(payload.count) / Double(chunkPayloadSize)))
        guard totalChunks > 0 else { return nil }

        let header = ChunkHeader(tx_id: txID, total_chunks: totalChunks, total_bytes: payload.count, encoding: "utf-8")
        guard let headerData = try? JSONEncoder().encode(header) else { return nil }

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

    private func processAvailableMetadata(_ data: Data, for peripheralID: UUID) {
        guard let message = try? JSONDecoder().decode(ClipboardAvailableMessage.self, from: data) else { return }
        if message.hash.isEmpty {
            pendingInboundHashByPeer.removeValue(forKey: peripheralID)
        } else {
            pendingInboundHashByPeer[peripheralID] = message.hash
        }
    }

    private func assembler(for peripheralID: UUID) -> ChunkAssembler {
        if let existing = assemblerByPeer[peripheralID] { return existing }
        let created = ChunkAssembler()
        assemblerByPeer[peripheralID] = created
        return created
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Service data extraction

    private func extractDeviceTag(from advertisementData: [String: Any]) -> Data? {
        guard
            let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data],
            let tag = serviceData[BLEProtocol.serviceUUID],
            tag.count >= 8
        else { return nil }
        return tag.prefix(8)
    }

    private func extractDisplayName(
        peripheral: CBPeripheral,
        advertisementData: [String: Any]
    ) -> String {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advertisedName ?? peripheral.name
        return name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown device"
    }
}

// MARK: - CBCentralManagerDelegate

extension BLECentralManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            scan()
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let peripheralID = peripheral.identifier
        knownPeripherals[peripheralID] = peripheral

        guard let tag = extractDeviceTag(from: advertisementData) else { return }
        guard let device = pairingManager.findDevice(byTag: tag) else { return }

        peripheralTokenMap[peripheralID] = device.token
        connectToPairedPeerIfNeeded(peripheralID: peripheralID)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        reconnectDelay = 1
        let peripheralID = peripheral.identifier
        connectingPeerIDs.remove(peripheralID)

        guard let token = peripheralTokenMap[peripheralID] else { return }

        // Update stored display name from the peripheral's advertised name
        // (replaces "Pending pairing…" after first successful connection).
        let peripheralName = peripheral.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let device = pairingManager.loadDevices().first(where: { $0.token == token })
        let displayName = peripheralName ?? device?.displayName ?? "Unknown device"

        if let peripheralName, device != nil, device?.displayName != peripheralName {
            pairingManager.addDevice(PairedDevice(
                token: token,
                displayName: peripheralName,
                datePaired: device?.datePaired ?? Date()
            ))
        }

        connectedPeers[peripheralID] = ConnectedPeer(
            peripheral: peripheral,
            token: token,
            displayName: displayName,
            availableCharacteristic: nil,
            dataCharacteristic: nil
        )

        notifyAllState()
        peripheral.discoverServices([BLEProtocol.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectingPeerIDs.remove(peripheral.identifier)
        scheduleReconnect()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let peripheralID = peripheral.identifier
        connectingPeerIDs.remove(peripheralID)
        connectedPeers.removeValue(forKey: peripheralID)
        pendingInboundHashByPeer.removeValue(forKey: peripheralID)
        assemblerByPeer.removeValue(forKey: peripheralID)
        notifyAllState()
        scheduleReconnect()
    }
}

// MARK: - CBPeripheralDelegate

extension BLECentralManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        peripheral.services?.forEach {
            peripheral.discoverCharacteristics([BLEProtocol.availableUUID, BLEProtocol.dataUUID], for: $0)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let peripheralID = peripheral.identifier
        guard var peer = connectedPeers[peripheralID] else { return }

        service.characteristics?.forEach { characteristic in
            if characteristic.uuid == BLEProtocol.availableUUID || characteristic.uuid == BLEProtocol.dataUUID {
                peripheral.setNotifyValue(true, for: characteristic)
            }
            if characteristic.uuid == BLEProtocol.availableUUID {
                peer.availableCharacteristic = characteristic
            }
            if characteristic.uuid == BLEProtocol.dataUUID {
                peer.dataCharacteristic = characteristic
            }
        }

        connectedPeers[peripheralID] = peer
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }

        let peripheralID = peripheral.identifier
        if characteristic.uuid == BLEProtocol.availableUUID {
            processAvailableMetadata(data, for: peripheralID)
            return
        }

        guard characteristic.uuid == BLEProtocol.dataUUID else { return }

        let chunkAssembler = assembler(for: peripheralID)
        if let header = try? JSONDecoder().decode(ChunkHeader.self, from: data) {
            chunkAssembler.reset(with: header)
            return
        }

        chunkAssembler.appendChunkFrame(data)
        guard let assembledData = chunkAssembler.assembleData() else { return }

        // Verify hash against metadata
        let assembledHash = sha256Hex(assembledData)
        if let metadataHash = pendingInboundHashByPeer[peripheralID], metadataHash != assembledHash {
            pendingInboundHashByPeer.removeValue(forKey: peripheralID)
            return
        }
        pendingInboundHashByPeer.removeValue(forKey: peripheralID)

        // Decrypt
        guard let key = encryptionKeyForPeer(peripheralID) else { return }
        guard let plaintext = try? E2ECrypto.open(assembledData, key: key) else { return }
        guard let output = String(data: plaintext, encoding: .utf8) else { return }

        let outputHash = sha256Hex(Data(output.utf8))
        guard outputHash != lastInboundHash else { return }

        lastInboundHash = outputHash
        clipboardWriter.writeText(output)
        onClipboardReceived?(output)
    }
}
