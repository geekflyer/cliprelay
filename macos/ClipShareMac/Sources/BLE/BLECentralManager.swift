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
}

private struct ConnectedPeer {
    let peripheral: CBPeripheral
    let description: String
    var availableCharacteristic: CBCharacteristic?
    var dataCharacteristic: CBCharacteristic?
}

final class BLECentralManager: NSObject {
    var onConnectionStateChanged: ((Bool) -> Void)?
    var onConnectedPeersChanged: (([PeerSummary]) -> Void)?
    var onDiscoveredPeersChanged: (([PeerSummary]) -> Void)?
    var onTrustedPeersChanged: (([PeerSummary]) -> Void)?
    var onClipboardReceived: ((String) -> Void)?

    private static let approvedPeerIDsDefaultsKey = "greenpaste.approvedPeerIDs"

    private let clipboardWriter: ClipboardWriter

    private var centralManager: CBCentralManager!
    private var knownPeripherals: [UUID: CBPeripheral] = [:]
    private var seenPeerDescriptions: [UUID: String] = [:]
    private var discoveredUnapprovedPeers: [UUID: String] = [:]
    private var discoveredNameToPeerID: [String: UUID] = [:]
    private var approvedPeerIDs: Set<UUID> = []
    private var connectingPeerIDs: Set<UUID> = []
    private var connectedPeers: [UUID: ConnectedPeer] = [:]

    private var reconnectDelay: TimeInterval = 1
    private var lastInboundHash: String?
    private var pendingInboundHashByPeer: [UUID: String] = [:]
    private var assemblerByPeer: [UUID: ChunkAssembler] = [:]

    init(clipboardWriter: ClipboardWriter) {
        self.clipboardWriter = clipboardWriter
        self.approvedPeerIDs = Self.loadApprovedPeerIDs()
        super.init()
        self.centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    func start() {
        notifyAllPeerState()
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
        notifyConnectionAndPeerState()
    }

    func approvePeer(id: UUID) {
        guard !approvedPeerIDs.contains(id) else { return }
        approvedPeerIDs.insert(id)
        persistApprovedPeerIDs()
        removeDiscoveredPeer(id: id)
        discoveredUnapprovedPeers.removeValue(forKey: id)
        connectToApprovedPeerIfNeeded(id: id)
        notifyTrustedAndDiscoveredPeers()
    }

    func revokePeer(id: UUID) {
        guard approvedPeerIDs.contains(id) else { return }
        approvedPeerIDs.remove(id)
        persistApprovedPeerIDs()

        if let peer = connectedPeers[id] {
            centralManager.cancelPeripheralConnection(peer.peripheral)
        }
        connectingPeerIDs.remove(id)
        connectedPeers.removeValue(forKey: id)
        pendingInboundHashByPeer.removeValue(forKey: id)
        assemblerByPeer.removeValue(forKey: id)

        if let description = seenPeerDescriptions[id] {
            discoveredUnapprovedPeers[id] = description
        }

        notifyAllPeerState()
    }

    func sendClipboardText(_ text: String) {
        let payload = Data(text.utf8)
        guard payload.count <= 102_400 else { return }

        let readyPeers = connectedPeers.values.filter { peer in
            peer.availableCharacteristic != nil && peer.dataCharacteristic != nil
        }
        guard !readyPeers.isEmpty else { return }

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

        for peer in readyPeers {
            guard let availableCharacteristic = peer.availableCharacteristic else { continue }
            peer.peripheral.writeValue(metadataData, for: availableCharacteristic, type: .withResponse)

            for (index, frame) in frames.enumerated() {
                let delay = Double(index) * 0.01
                let writeType: CBCharacteristicWriteType = index == 0 ? .withResponse : .withoutResponse
                let peripheral = peer.peripheral
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard
                        let self,
                        let currentPeer = self.connectedPeers[peripheral.identifier],
                        let dataCharacteristic = currentPeer.dataCharacteristic
                    else {
                        return
                    }
                    peripheral.writeValue(frame, for: dataCharacteristic, type: writeType)
                }
            }
        }
    }

    private func connectToApprovedPeerIfNeeded(id: UUID) {
        guard approvedPeerIDs.contains(id) else { return }
        guard connectedPeers[id] == nil else { return }
        guard !connectingPeerIDs.contains(id) else { return }
        guard let peripheral = knownPeripherals[id] else { return }

        connectingPeerIDs.insert(id)
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

    private func notifyConnectionAndPeerState() {
        let connected = connectedPeerSummaries()
        onConnectionStateChanged?(!connected.isEmpty)
        onConnectedPeersChanged?(connected)
    }

    private func notifyTrustedAndDiscoveredPeers() {
        onTrustedPeersChanged?(trustedPeerSummaries())
        onDiscoveredPeersChanged?(discoveredPeerSummaries())
    }

    private func removeDiscoveredPeer(id: UUID) {
        if let description = discoveredUnapprovedPeers.removeValue(forKey: id) {
            let key = discoveryNameKey(for: description)
            if discoveredNameToPeerID[key] == id {
                discoveredNameToPeerID.removeValue(forKey: key)
            }
        }
    }

    private func notifyAllPeerState() {
        notifyConnectionAndPeerState()
        notifyTrustedAndDiscoveredPeers()
    }

    private func connectedPeerSummaries() -> [PeerSummary] {
        connectedPeers.map { PeerSummary(id: $0.key, description: $0.value.description) }
            .sorted { $0.description.localizedCaseInsensitiveCompare($1.description) == .orderedAscending }
    }

    private func discoveredPeerSummaries() -> [PeerSummary] {
        discoveredUnapprovedPeers.map { PeerSummary(id: $0.key, description: $0.value) }
            .sorted { $0.description.localizedCaseInsensitiveCompare($1.description) == .orderedAscending }
    }

    private func trustedPeerSummaries() -> [PeerSummary] {
        approvedPeerIDs
            .map { id in
                let description = connectedPeers[id]?.description
                    ?? seenPeerDescriptions[id]
                    ?? "Unknown device (\(id.uuidString.prefix(8)))"
                return PeerSummary(id: id, description: description)
            }
            .sorted { $0.description.localizedCaseInsensitiveCompare($1.description) == .orderedAscending }
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

    private func processAvailableMetadata(_ data: Data, for peripheralID: UUID) {
        guard let message = try? JSONDecoder().decode(ClipboardAvailableMessage.self, from: data) else {
            return
        }

        if message.hash.isEmpty {
            pendingInboundHashByPeer.removeValue(forKey: peripheralID)
        } else {
            pendingInboundHashByPeer[peripheralID] = message.hash
        }
    }

    private func assembler(for peripheralID: UUID) -> ChunkAssembler {
        if let existing = assemblerByPeer[peripheralID] {
            return existing
        }
        let created = ChunkAssembler()
        assemblerByPeer[peripheralID] = created
        return created
    }

    private func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func makePeerDescription(
        peripheral: CBPeripheral,
        advertisementData: [String: Any]
    ) -> String {
        let name = makeDiscoveryDisplayName(peripheral: peripheral, advertisementData: advertisementData)
        let suffix = peripheral.identifier.uuidString.prefix(8)
        return "\(name) (\(suffix))"
    }

    private func makeDiscoveryDisplayName(
        peripheral: CBPeripheral,
        advertisementData: [String: Any]
    ) -> String {
        if
            let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data],
            let encodedName = serviceData[BLEProtocol.serviceUUID],
            let decodedName = String(data: encodedName, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !decodedName.isEmpty
        {
            return decodedName
        }

        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advertisedName ?? peripheral.name ?? "Unknown device"
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func discoveryNameKey(for displayName: String) -> String {
        displayName.lowercased()
    }

    private static func loadApprovedPeerIDs() -> Set<UUID> {
        let stored = UserDefaults.standard.array(forKey: approvedPeerIDsDefaultsKey) as? [String] ?? []
        return Set(stored.compactMap(UUID.init(uuidString:)))
    }

    private func persistApprovedPeerIDs() {
        let values = approvedPeerIDs.map(\.uuidString).sorted()
        UserDefaults.standard.set(values, forKey: Self.approvedPeerIDsDefaultsKey)
    }
}

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

        let description = makePeerDescription(peripheral: peripheral, advertisementData: advertisementData)
        seenPeerDescriptions[peripheralID] = description

        if approvedPeerIDs.contains(peripheralID) {
            removeDiscoveredPeer(id: peripheralID)
            connectToApprovedPeerIfNeeded(id: peripheralID)
        } else {
            let displayName = makeDiscoveryDisplayName(peripheral: peripheral, advertisementData: advertisementData)

            // didDiscover fires twice per peripheral: once for the primary ad (no name yet)
            // and again when the scan response arrives (with the full local name). Always
            // remove any stale entry for this peripheral before re-evaluating so we don't
            // accumulate "Unknown device" entries from incomplete first-pass advertisements.
            removeDiscoveredPeer(id: peripheralID)

            // BLE address rotation: Android periodically changes its MAC address, causing
            // macOS to assign a new peripheral UUID to the same physical device. If a trusted
            // peer's name matches this device, migrate trust to the new UUID automatically.
            let staleApprovedID = approvedPeerIDs.first { id in
                guard id != peripheralID else { return false }
                guard let desc = seenPeerDescriptions[id] else { return false }
                return desc.hasPrefix(displayName + " (")
            }

            if let staleID = staleApprovedID {
                approvedPeerIDs.remove(staleID)
                connectedPeers.removeValue(forKey: staleID)
                connectingPeerIDs.remove(staleID)
                pendingInboundHashByPeer.removeValue(forKey: staleID)
                assemblerByPeer.removeValue(forKey: staleID)

                approvedPeerIDs.insert(peripheralID)
                persistApprovedPeerIDs()
                connectToApprovedPeerIfNeeded(id: peripheralID)
            } else {
                let nameKey = discoveryNameKey(for: displayName)
                if let existingID = discoveredNameToPeerID[nameKey], existingID != peripheralID {
                    removeDiscoveredPeer(id: existingID)
                }
                discoveredUnapprovedPeers[peripheralID] = displayName
                discoveredNameToPeerID[nameKey] = peripheralID
            }
        }

        notifyTrustedAndDiscoveredPeers()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        reconnectDelay = 1
        let peripheralID = peripheral.identifier
        connectingPeerIDs.remove(peripheralID)

        let description = seenPeerDescriptions[peripheralID]
            ?? peripheral.name
            ?? "Unknown device (\(peripheralID.uuidString.prefix(8)))"
        connectedPeers[peripheralID] = ConnectedPeer(
            peripheral: peripheral,
            description: description,
            availableCharacteristic: nil,
            dataCharacteristic: nil
        )

        notifyConnectionAndPeerState()
        notifyTrustedAndDiscoveredPeers()
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
        notifyConnectionAndPeerState()
        notifyTrustedAndDiscoveredPeers()
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
        let peripheralID = peripheral.identifier
        guard var peer = connectedPeers[peripheralID] else {
            return
        }

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

        guard characteristic.uuid == BLEProtocol.dataUUID else {
            return
        }

        let chunkAssembler = assembler(for: peripheralID)
        if let header = try? JSONDecoder().decode(ChunkHeader.self, from: data) {
            chunkAssembler.reset(with: header)
            return
        }

        chunkAssembler.appendChunkFrame(data)
        guard let assembledData = chunkAssembler.assembleData() else { return }
        guard let output = decodeClipboardPayload(assembledData, encoding: chunkAssembler.encoding) else { return }

        let outputData = Data(output.utf8)
        let hash = sha256Hex(outputData)

        if let metadataHash = pendingInboundHashByPeer[peripheralID], metadataHash != hash {
            pendingInboundHashByPeer.removeValue(forKey: peripheralID)
            return
        }

        pendingInboundHashByPeer.removeValue(forKey: peripheralID)

        guard hash != lastInboundHash else { return }

        lastInboundHash = hash
        clipboardWriter.writeText(output)
        onClipboardReceived?(output)
    }
}
