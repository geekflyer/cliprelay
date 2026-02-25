import AppKit
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
    let connectedAt: Date
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
    private let connectionAttemptTimeout: TimeInterval = 60
    private var connectionWatchdogTimer: Timer?
    private var keepaliveTimer: Timer?
    private var scanCycleTimer: Timer?
    private var connectingSinceByPeerID: [UUID: Date] = [:]
    /// Outstanding RSSI probe timestamp per peer.
    private var pendingRSSIProbeByPeerID: [UUID: Date] = [:]
    /// Peers that failed to respond to an RSSI read within the timeout window.
    private var rssiMissCountByPeerID: [UUID: Int] = [:]
    private var isStopped = false
    private var pendingPairingToken: String?
    private var lastInboundHash: String?
    private var lastInboundPeerID: UUID?
    private var pendingInboundHashByPeer: [UUID: String] = [:]
    private var assemblerByPeer: [UUID: ChunkAssembler] = [:]
    private var pendingOutboundFrames: [UUID: (peripheral: CBPeripheral, frames: [Data], nextIndex: Int)] = [:]

    init(clipboardWriter: ClipboardWriter, pairingManager: PairingManager) {
        self.clipboardWriter = clipboardWriter
        self.pairingManager = pairingManager
        super.init()
        self.centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    func start() {
        isStopped = false
        notifyAllState()
        if centralManager.state == .poweredOn {
            scan()
            startConnectionWatchdogIfNeeded()
            startKeepaliveTimer()
            startScanCycleTimer()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSystemWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    func stop() {
        isStopped = true
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        // Cancel both connected and connecting peripherals to release all connection slots.
        for peer in connectedPeers.values {
            centralManager.cancelPeripheralConnection(peer.peripheral)
        }
        for id in connectingPeerIDs {
            if let peripheral = knownPeripherals[id] {
                centralManager.cancelPeripheralConnection(peripheral)
            }
        }
        connectingPeerIDs.removeAll()
        connectingSinceByPeerID.removeAll()
        connectedPeers.removeAll()
        pendingInboundHashByPeer.removeAll()
        assemblerByPeer.removeAll()
        pendingOutboundFrames.removeAll()
        centralManager.stopScan()
        stopConnectionWatchdog()
        stopKeepaliveTimer()
        stopScanCycleTimer()
        notifyAllState()
    }

    @objc private func handleSystemWake() {
        print("[BLE] System wake detected – forcing BLE reconnection cycle")
        guard centralManager.state == .poweredOn else {
            // Bluetooth not ready yet; centralManagerDidUpdateState will
            // trigger scanning once it transitions to poweredOn.
            return
        }

        // Cancel all existing connections – they are stale after sleep.
        for peer in connectedPeers.values {
            centralManager.cancelPeripheralConnection(peer.peripheral)
        }
        for id in connectingPeerIDs {
            if let peripheral = knownPeripherals[id] {
                centralManager.cancelPeripheralConnection(peripheral)
            }
        }

        // Preserve peripheralTokenMap and knownPeripherals so we can
        // immediately reconnect to known devices without waiting for
        // advertisement re-discovery.
        connectingPeerIDs.removeAll()
        connectingSinceByPeerID.removeAll()
        connectedPeers.removeAll()
        pendingInboundHashByPeer.removeAll()
        assemblerByPeer.removeAll()
        pendingOutboundFrames.removeAll()
        rssiMissCountByPeerID.removeAll()
        pendingRSSIProbeByPeerID.removeAll()
        notifyAllState()

        // Reset backoff and restart scanning + direct connection attempts.
        reconnectDelay = 1
        centralManager.stopScan()
        scan()
        startConnectionWatchdogIfNeeded()
        startKeepaliveTimer()
        startScanCycleTimer()

        // Re-queue direct connection attempts for all known paired peripherals.
        for (peripheralID, _) in peripheralTokenMap {
            connectToPairedPeerIfNeeded(peripheralID: peripheralID)
        }
    }

    func forgetDevice(token: String) {
        pairingManager.removeDevice(token: token)
        if pendingPairingToken == token {
            pendingPairingToken = nil
        }

        let peripheralIDs = peripheralTokenMap.filter { $0.value == token }.map(\.key)
        for id in peripheralIDs {
            if let peripheral = knownPeripherals[id] {
                centralManager.cancelPeripheralConnection(peripheral)
            }
            connectingPeerIDs.remove(id)
            connectingSinceByPeerID.removeValue(forKey: id)
            connectedPeers.removeValue(forKey: id)
            pendingInboundHashByPeer.removeValue(forKey: id)
            assemblerByPeer.removeValue(forKey: id)
            pendingOutboundFrames.removeValue(forKey: id)
            rssiMissCountByPeerID.removeValue(forKey: id)
            pendingRSSIProbeByPeerID.removeValue(forKey: id)
            peripheralTokenMap.removeValue(forKey: id)
        }

        notifyAllState()
    }

    func setPendingPairingToken(_ token: String?) {
        pendingPairingToken = token
    }

    func sendClipboardText(_ text: String) {
        let plaintext = Data(text.utf8)
        guard plaintext.count <= 102_400 else { return }

        // Skip the peer that just sent us this exact content to avoid echo.
        let echoHash = sha256Hex(plaintext)
        let skipPeerID: UUID? = (echoHash == lastInboundHash) ? lastInboundPeerID : nil

        let readyPeers = connectedPeers.filter { (id, peer) in
            peer.availableCharacteristic != nil && peer.dataCharacteristic != nil && id != skipPeerID
        }.map(\.value)
        print("[BLE] sendClipboardText: connectedPeers=\(connectedPeers.count) readyPeers=\(readyPeers.count) textLen=\(text.count) skipEcho=\(skipPeerID?.uuidString ?? "none")")
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

            // Queue frames for flow-controlled sending via peripheralIsReady callback
            let peripheralID = peer.peripheral.identifier
            pendingOutboundFrames[peripheralID] = (peer.peripheral, frames, 0)
            drainOutboundQueue(for: peer.peripheral)
        }
    }

    // MARK: - Notify UI

    func notifyAllState() {
        let connected = connectedPeerSummaries()
        onConnectedPeersChanged?(connected)
        onTrustedPeersChanged?(trustedPeerSummaries())
    }

    private func connectedPeerSummaries() -> [PeerSummary] {
        connectedPeers.values
            .filter { $0.availableCharacteristic != nil && $0.dataCharacteristic != nil }
            .map { PeerSummary(id: deviceStableID(token: $0.token), description: $0.displayName, token: $0.token) }
            .sorted { $0.description.localizedCaseInsensitiveCompare($1.description) == .orderedAscending }
    }

    private func trustedPeerSummaries() -> [PeerSummary] {
        pairingManager.loadDevices().map { device in
            PeerSummary(id: deviceStableID(token: device.token), description: device.displayName, token: device.token)
        }
        .sorted { $0.description.localizedCaseInsensitiveCompare($1.description) == .orderedAscending }
    }

    /// Stable UUID derived from token for UI identification (not a BLE peripheral UUID).
    /// Falls back to a deterministic UUID based on the token string if tag derivation fails.
    private func deviceStableID(token: String) -> UUID {
        guard let data = pairingManager.deviceTag(for: token) else {
            // Use a deterministic hash of the token so the same token always yields the same UUID
            let hashBytes = Array(Data(token.utf8).prefix(16))
            var bytes = [UInt8](repeating: 0, count: 16)
            for (i, b) in hashBytes.enumerated() { bytes[i] = b }
            return UUID(uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            ))
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

        // Only cancel if CoreBluetooth still thinks this peripheral has an
        // active/pending link. Calling cancel on an already-disconnected
        // peripheral can prevent the first connection after pairing from
        // completing on some macOS versions.
        if peripheral.state != .disconnected {
            centralManager.cancelPeripheralConnection(peripheral)
        }

        connectingPeerIDs.insert(peripheralID)
        connectingSinceByPeerID[peripheralID] = Date()
        peripheral.delegate = self
        centralManager.connect(peripheral, options: nil)
    }

    private func scan() {
        centralManager.scanForPeripherals(
            withServices: [BLEProtocol.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    private func scheduleReconnect() {
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 30)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.centralManager.state == .poweredOn else { return }
            // Stop then restart the scan to reset CoreBluetooth's duplicate filter so
            // a peripheral that re-appears (e.g. after a phone BT toggle with a new UUID)
            // is reported again via didDiscover.
            self.centralManager.stopScan()
            self.scan()
        }
    }

    private func startConnectionWatchdogIfNeeded() {
        guard connectionWatchdogTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.reapStaleConnectionAttempts()
        }
        connectionWatchdogTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopConnectionWatchdog() {
        connectionWatchdogTimer?.invalidate()
        connectionWatchdogTimer = nil
    }

    private let serviceDiscoveryTimeout: TimeInterval = 15

    private func reapStaleConnectionAttempts() {
        let now = Date()
        let staleIDs = connectingPeerIDs.filter { id in
            guard let startedAt = connectingSinceByPeerID[id] else { return true }
            return now.timeIntervalSince(startedAt) > connectionAttemptTimeout
        }

        // Also reap connected peers that haven't completed characteristic discovery
        let staleDiscoveryIDs = connectedPeers.filter { (_, peer) in
            peer.availableCharacteristic == nil || peer.dataCharacteristic == nil
        }.filter { (_, peer) in
            now.timeIntervalSince(peer.connectedAt) > serviceDiscoveryTimeout
        }.map(\.key)

        for id in staleDiscoveryIDs {
            if let peer = connectedPeers[id] {
                print("[BLE] Service discovery timeout for \(peer.displayName) — disconnecting")
                centralManager.cancelPeripheralConnection(peer.peripheral)
            }
        }

        guard !staleIDs.isEmpty else { return }

        for id in staleIDs {
            if let peripheral = knownPeripherals[id] {
                centralManager.cancelPeripheralConnection(peripheral)
            }
            connectingPeerIDs.remove(id)
            connectingSinceByPeerID.removeValue(forKey: id)
        }
        scheduleReconnect()
    }

    // MARK: - Keepalive (RSSI probe)

    /// Periodically read RSSI on connected peripherals to detect dead BLE links.
    /// If a peripheral fails to respond to two consecutive probes, force-disconnect it
    /// so the normal reconnection logic can kick in.
    private func startKeepaliveTimer() {
        guard keepaliveTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.probeConnectedPeers()
        }
        keepaliveTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopKeepaliveTimer() {
        keepaliveTimer?.invalidate()
        keepaliveTimer = nil
        rssiMissCountByPeerID.removeAll()
        pendingRSSIProbeByPeerID.removeAll()
    }

    private func probeConnectedPeers() {
        guard !connectedPeers.isEmpty else { return }
        let now = Date()
        for (id, peer) in connectedPeers {
            // Check if the previous RSSI probe was answered
            if let pendingProbe = pendingRSSIProbeByPeerID[id] {
                // Wait for callback until timeout. Don't enqueue another probe while
                // one is already outstanding.
                if now.timeIntervalSince(pendingProbe) <= 45 {
                    continue
                }

                let missCount = (rssiMissCountByPeerID[id] ?? 0) + 1
                rssiMissCountByPeerID[id] = missCount
                print("[BLE] RSSI probe timeout for \(peer.displayName) (miss #\(missCount))")
                if missCount >= 2 {
                    print("[BLE] Forcing disconnect of unresponsive peer \(peer.displayName)")
                    centralManager.cancelPeripheralConnection(peer.peripheral)
                    rssiMissCountByPeerID.removeValue(forKey: id)
                    pendingRSSIProbeByPeerID.removeValue(forKey: id)
                    continue
                }
            }

            pendingRSSIProbeByPeerID[id] = now
            peer.peripheral.readRSSI()

            // GATT-level heartbeat: read the Available characteristic to verify
            // the remote GATT server is still functional (not just link-layer alive).
            if let availableChar = peer.availableCharacteristic {
                peer.peripheral.readValue(for: availableChar)
            }
        }
    }

    // MARK: - Periodic scan cycle

    /// Periodically restart scanning to work around CoreBluetooth's duplicate
    /// advertisement filter and to recover from cases where the Android side
    /// silently restarted its advertisement (getting a new advertising set ID).
    private func startScanCycleTimer() {
        guard scanCycleTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            self?.cycleScan()
        }
        scanCycleTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopScanCycleTimer() {
        scanCycleTimer?.invalidate()
        scanCycleTimer = nil
    }

    private func cycleScan() {
        guard centralManager.state == .poweredOn else { return }
        // If we have no connected peers, reset backoff and aggressively re-scan
        if connectedPeers.isEmpty {
            reconnectDelay = 1
            print("[BLE] Scan cycle: no connected peers — resetting backoff and restarting scan")
        }
        centralManager.stopScan()
        scan()

        // Also re-attempt direct connections for any known paired peripherals
        // that aren't currently connected or connecting.
        for (peripheralID, _) in peripheralTokenMap {
            connectToPairedPeerIfNeeded(peripheralID: peripheralID)
        }
    }

    // MARK: - Outbound flow control

    private func drainOutboundQueue(for peripheral: CBPeripheral) {
        let peripheralID = peripheral.identifier
        guard var entry = pendingOutboundFrames[peripheralID] else { return }
        guard let currentPeer = connectedPeers[peripheralID],
              let dataChar = currentPeer.dataCharacteristic else {
            pendingOutboundFrames.removeValue(forKey: peripheralID)
            return
        }

        while entry.nextIndex < entry.frames.count {
            let index = entry.nextIndex
            let frame = entry.frames[index]
            let writeType: CBCharacteristicWriteType = index == 0 ? .withResponse : .withoutResponse

            if writeType == .withoutResponse && !peripheral.canSendWriteWithoutResponse {
                // Wait for peripheralIsReady(toSendWriteWithoutResponse:) callback
                pendingOutboundFrames[peripheralID] = entry
                return
            }

            peripheral.writeValue(frame, for: dataChar, type: writeType)
            entry.nextIndex += 1
        }

        pendingOutboundFrames.removeValue(forKey: peripheralID)
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
        guard let mfgData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data else {
            return nil
        }

        // Most stacks include [2-byte company ID][8-byte tag], but some report
        // only the manufacturer payload bytes in scan responses.
        if mfgData.count >= 10 {
            return mfgData.subdata(in: 2..<10)
        }
        if mfgData.count == 8 {
            return mfgData
        }
        return nil
    }

    private func extractDisplayName(
        peripheral: CBPeripheral,
        advertisementData: [String: Any]
    ) -> String {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advertisedName ?? peripheral.name
        return name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown device"
    }

    private func pendingPairingFallbackToken() -> String? {
        guard let token = pendingPairingToken else { return nil }
        guard pairingManager.isPendingDeviceToken(token) else { return nil }
        return token
    }

    private func connectUsingPendingPairingFallbackIfAvailable(peripheralID: UUID) -> Bool {
        guard peripheralTokenMap[peripheralID] == nil else { return false }
        guard let token = pendingPairingFallbackToken() else { return false }

        print("[BLE]   -> Falling back to pending pairing token for discovered peripheral")
        peripheralTokenMap[peripheralID] = token
        connectToPairedPeerIfNeeded(peripheralID: peripheralID)
        return true
    }
}

// MARK: - CBCentralManagerDelegate

extension BLECentralManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        print("[BLE] Central state: \(central.state.rawValue) (4=poweredOn)")
        if central.state == .poweredOn {
            reconnectDelay = 1
            scan()
            startConnectionWatchdogIfNeeded()
            startKeepaliveTimer()
            startScanCycleTimer()
        } else {
            // Bluetooth turned off — all peripherals are invalidated by CoreBluetooth
            knownPeripherals.removeAll()
            connectingPeerIDs.removeAll()
            connectingSinceByPeerID.removeAll()
            connectedPeers.removeAll()
            peripheralTokenMap.removeAll()
            pendingInboundHashByPeer.removeAll()
            assemblerByPeer.removeAll()
            pendingOutboundFrames.removeAll()
            rssiMissCountByPeerID.removeAll()
            pendingRSSIProbeByPeerID.removeAll()
            stopConnectionWatchdog()
            stopKeepaliveTimer()
            stopScanCycleTimer()
            notifyAllState()
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

        let mfgData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        print("[BLE] Discovered \(peripheral.name ?? "nil") mfgData=\(mfgData?.map { String(format: "%02x", $0) }.joined() ?? "nil") rssi=\(RSSI)")

        guard let tag = extractDeviceTag(from: advertisementData) else {
            print("[BLE]   -> No device tag in advertisement")
            _ = connectUsingPendingPairingFallbackIfAvailable(peripheralID: peripheralID)
            return
        }
        print("[BLE]   -> Tag: \(tag.map { String(format: "%02x", $0) }.joined())")
        guard let device = pairingManager.findDevice(byTag: tag) else {
            print("[BLE]   -> No paired device matches this tag")
            let allDevices = pairingManager.loadDevices()
            for d in allDevices {
                let dt = pairingManager.deviceTag(for: d.token)
                print("[BLE]      stored tag: \(dt?.map { String(format: "%02x", $0) }.joined() ?? "nil") name=\(d.displayName)")
            }
            _ = connectUsingPendingPairingFallbackIfAvailable(peripheralID: peripheralID)
            return
        }
        print("[BLE]   -> Matched paired device: \(device.displayName)")

        peripheralTokenMap[peripheralID] = device.token

        // Capture advertised name early (available from scan response)
        let advName = extractDisplayName(peripheral: peripheral, advertisementData: advertisementData)
        if advName != "Unknown device", device.displayName != advName {
            pairingManager.addDevice(PairedDevice(
                token: device.token,
                displayName: advName,
                datePaired: device.datePaired
            ))
            notifyAllState()
        }

        connectToPairedPeerIfNeeded(peripheralID: peripheralID)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        reconnectDelay = 1
        let peripheralID = peripheral.identifier
        connectingPeerIDs.remove(peripheralID)
        connectingSinceByPeerID.removeValue(forKey: peripheralID)
        print("[BLE] didConnect: \(peripheral.name ?? "nil") id=\(peripheralID)")

        guard let token = peripheralTokenMap[peripheralID] else {
            print("[BLE]   -> No token mapped for this peripheral")
            return
        }

        if pendingPairingToken == token {
            pendingPairingToken = nil
        }

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
            connectedAt: Date(),
            availableCharacteristic: nil,
            dataCharacteristic: nil
        )

        notifyAllState()
        peripheral.discoverServices([BLEProtocol.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("[BLE] didFailToConnect: \(peripheral.name ?? "nil") error=\(error?.localizedDescription ?? "nil")")
        connectingPeerIDs.remove(peripheral.identifier)
        connectingSinceByPeerID.removeValue(forKey: peripheral.identifier)
        scheduleReconnect()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        print("[BLE] didDisconnect: \(peripheral.name ?? "nil") error=\(error?.localizedDescription ?? "nil")")
        let peripheralID = peripheral.identifier
        connectingPeerIDs.remove(peripheralID)
        connectingSinceByPeerID.removeValue(forKey: peripheralID)
        connectedPeers.removeValue(forKey: peripheralID)
        pendingInboundHashByPeer.removeValue(forKey: peripheralID)
        assemblerByPeer.removeValue(forKey: peripheralID)
        pendingOutboundFrames.removeValue(forKey: peripheralID)
        rssiMissCountByPeerID.removeValue(forKey: peripheralID)
        pendingRSSIProbeByPeerID.removeValue(forKey: peripheralID)
        notifyAllState()

        // Don't reconnect if we've been stopped — late CoreBluetooth callbacks
        // can fire after stop() and would otherwise undo the shutdown.
        guard !isStopped else { return }

        // Re-queue a connect on the same peripheral object. CoreBluetooth holds this as a
        // pending request and completes it as soon as the peripheral is available again
        // (e.g. the phone re-enables Bluetooth). This avoids relying on the scan to
        // re-discover the peripheral, which won't happen while the duplicate filter is active.
        if peripheralTokenMap[peripheralID] != nil {
            knownPeripherals[peripheralID] = peripheral
            connectToPairedPeerIfNeeded(peripheralID: peripheralID)
        } else {
            // Only restart scanning for unknown peripherals; the direct connect
            // above is sufficient for paired devices and avoids duplicate requests.
            scheduleReconnect()
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BLECentralManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        print("[BLE] didDiscoverServices: \(peripheral.services?.map(\.uuid.uuidString) ?? []) error=\(error?.localizedDescription ?? "nil")")
        peripheral.services?.forEach {
            peripheral.discoverCharacteristics([BLEProtocol.availableUUID, BLEProtocol.dataUUID], for: $0)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        print("[BLE] didDiscoverCharacteristics: \(service.characteristics?.map(\.uuid.uuidString) ?? []) error=\(error?.localizedDescription ?? "nil")")
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
        notifyAllState()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let peripheralID = peripheral.identifier

        // GATT heartbeat: a read error on any characteristic means the remote
        // GATT server is gone — force-disconnect to trigger reconnection.
        if let error {
            print("[BLE] GATT read error for \(peripheral.name ?? "nil"): \(error.localizedDescription)")
            if let peer = connectedPeers[peripheralID] {
                print("[BLE] GATT heartbeat failure — disconnecting \(peer.displayName)")
                centralManager.cancelPeripheralConnection(peer.peripheral)
            }
            return
        }

        guard let data = characteristic.value else { return }
        print("[BLE] didUpdateValue: char=\(characteristic.uuid.uuidString) bytes=\(data.count)")

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

        // Verify hash against metadata — reject if metadata was never received
        guard let metadataHash = pendingInboundHashByPeer.removeValue(forKey: peripheralID) else {
            print("[BLE] Rejecting assembled data: no metadata hash received for peer \(peripheralID)")
            return
        }
        let assembledHash = sha256Hex(assembledData)
        guard metadataHash == assembledHash else {
            print("[BLE] Hash mismatch: expected=\(metadataHash) got=\(assembledHash)")
            return
        }

        // Decrypt
        guard let key = encryptionKeyForPeer(peripheralID) else { return }
        guard let plaintext = try? E2ECrypto.open(assembledData, key: key) else { return }
        guard let output = String(data: plaintext, encoding: .utf8) else { return }

        let outputHash = sha256Hex(Data(output.utf8))
        guard outputHash != lastInboundHash else { return }

        lastInboundHash = outputHash
        lastInboundPeerID = peripheralID
        clipboardWriter.writeText(output)
        onClipboardReceived?(output)
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        drainOutboundQueue(for: peripheral)
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        let peripheralID = peripheral.identifier
        if error != nil {
            print("[BLE] RSSI read failed for \(peripheral.name ?? "nil"): \(error!.localizedDescription)")
            let missCount = (rssiMissCountByPeerID[peripheralID] ?? 0) + 1
            rssiMissCountByPeerID[peripheralID] = missCount
            pendingRSSIProbeByPeerID.removeValue(forKey: peripheralID)
            if missCount >= 2 {
                if let peer = connectedPeers[peripheralID] {
                    print("[BLE] Forcing disconnect after RSSI read failures for \(peer.displayName)")
                }
                centralManager.cancelPeripheralConnection(peripheral)
                rssiMissCountByPeerID.removeValue(forKey: peripheralID)
            }
            return
        }
        // Successful RSSI response — peer is alive
        rssiMissCountByPeerID.removeValue(forKey: peripheralID)
        pendingRSSIProbeByPeerID.removeValue(forKey: peripheralID)
    }
}
