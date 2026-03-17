// Core app delegate: wires together BLE, clipboard, pairing, and UI subsystems.

import AppKit
import CoreBluetooth
import CryptoKit
import os
import ServiceManagement
import Sparkle

private let appLogger = Logger(subsystem: "org.cliprelay", category: "App")

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let updaterController: SPUStandardUpdaterController
    private let pairingManager = PairingManager()
    private let statusBarController: StatusBarController
    private let clipboardWriter = ClipboardWriter()
    private let notificationManager = ReceiveNotificationManager()
    private let pairingWindowController = PairingWindowController()

    override init() {
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        statusBarController = StatusBarController(updaterController: updaterController)
        super.init()
    }

    private var connectionManager: ConnectionManager!
    private var activeSession: Session?
    private var sessionThread: Thread?
    private var connectedSecret: String?
    private var activeSettingsProvider: DeviceSettingsProvider?
    private var pendingClipboardPayload: Data?

    // Dedup: hash of the last clipboard we received from the remote side
    private var lastReceivedHash: String?
    private var lastReceivedImageHash: String?

    private var clipboardMonitor: ClipboardMonitor?
    private var awaitingNewPairingConnection = false
    private var hasShownBluetoothAlert = false
    private var bluetoothOffDebounceTimer: Timer?
    private static let bluetoothOffDebounceDelay: TimeInterval = 5.0

    func applicationDidFinishLaunching(_ notification: Notification) {
        notificationManager.requestAuthorization()
        pairingManager.removePendingDevices()
        enableLaunchAtLoginIfFirstRun()

        statusBarController.onPairNewDeviceRequested = { [weak self] in
            self?.startPairing()
        }
        statusBarController.onForgetDeviceRequested = { [weak self] token in
            self?.forgetDevice(token: token)
        }
        statusBarController.onToggleLaunchAtLogin = {
            let service = SMAppService.mainApp
            do {
                if service.status == .enabled {
                    try service.unregister()
                } else {
                    try service.register()
                }
            } catch {
                appLogger.error("[App] Failed to toggle launch at login: \(error.localizedDescription)")
            }
        }
        statusBarController.isLaunchAtLoginEnabled = {
            SMAppService.mainApp.status == .enabled
        }
        statusBarController.onToggleImageSync = { [weak self] in
            self?.toggleImageSync()
        }
        statusBarController.isImageSyncEnabled = { [weak self] in
            guard let self, let secret = self.connectedSecret else { return false }
            return self.pairingManager.loadDevices().first(where: { $0.sharedSecret == secret })?.richMediaEnabled ?? false
        }
        statusBarController.isDeviceConnected = { [weak self] in
            self?.connectedSecret != nil
        }
        pairingWindowController.onDidClose = { [weak self] in
            self?.handlePairingWindowClosed()
        }

        // Set up ConnectionManager (L2CAP)
        connectionManager = ConnectionManager()
        connectionManager.delegate = self
        connectionManager.pairedDevices = { [weak self] in
            guard let self else { return [] }
            return self.pairingManager.loadDevices().compactMap { device in
                guard let tag = self.pairingManager.deviceTag(for: device.sharedSecret) else { return nil }
                return (token: device.sharedSecret, tag: tag)
            }
        }

        // Clipboard monitor triggers outbound sends via Session
        clipboardMonitor = ClipboardMonitor { [weak self] text in
            self?.onClipboardChange(text)
        }
        clipboardMonitor?.onImageChange = { [weak self] imageData, contentType, hash in
            guard let self = self else { return }
            guard self.lastReceivedImageHash != hash else { return }
            guard self.activeSettingsProvider?.isRichMediaEnabled() == true else { return }
            self.activeSession?.sendImage(imageData, contentType: contentType)
        }

        // Start scanning and monitoring
        // ConnectionManager starts scanning automatically when Bluetooth powers on
        clipboardMonitor?.start()

        // Refresh trusted device list in the menu
        refreshTrustedPeersMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        bluetoothOffDebounceTimer?.invalidate()
        clipboardMonitor?.stop()
        activeSession?.close()
        connectionManager?.disconnect()
    }

    // MARK: - Launch at Login

    private func enableLaunchAtLoginIfFirstRun() {
        let key = "hasEnabledLaunchAtLogin"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        do {
            try SMAppService.mainApp.register()
            appLogger.info("[App] Launch at login enabled on first run")
        } catch {
            appLogger.error("[App] Failed to enable launch at login: \(error.localizedDescription)")
        }
    }

    // MARK: - Clipboard Change → Session

    private func onClipboardChange(_ text: String) {
        guard connectedSecret != nil else {
            appLogger.debug("[App] Clipboard changed but no connected device")
            return
        }
        guard let plainData = text.data(using: .utf8) else { return }

        // Dedup: skip if we just received this exact text from the remote side
        let hash = SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        if hash == lastReceivedHash {
            appLogger.debug("[App] Skipping send — this clipboard was just received from remote")
            return
        }

        // Retain for retry after reconnect (plaintext, in-memory only)
        pendingClipboardPayload = plainData

        // Try to send immediately
        if let session = activeSession {
            session.sendClipboard(plainData)
            appLogger.info("[App] Queued clipboard for send (\(plainData.count) bytes)")
        } else {
            appLogger.info("[App] Clipboard cached for send on reconnect (\(plainData.count) bytes)")
        }
    }

    // MARK: - Pairing

    private func startPairing() {
        pairingManager.removePendingDevices()

        let privateKey = pairingManager.generateKeyPair()
        let publicKey = privateKey.publicKey

        awaitingNewPairingConnection = true

        guard let uri = pairingManager.pairingURI(publicKey: publicKey) else { return }
        pairingWindowController.showPairingQR(uri: uri)

        // Tell ConnectionManager to scan for pairing tag
        let pairingTag = PairingManager.pairingTag(from: publicKey.rawRepresentation)
        connectionManager.pairingTag = pairingTag

        refreshTrustedPeersMenu()
    }

    private func handlePairingWindowClosed() {
        guard awaitingNewPairingConnection else { return }
        pairingManager.clearEphemeralKey()
        connectionManager.pairingTag = nil
        cancelPendingPairingFlow(removePendingDevice: true)
    }

    private func completePairing(secret: String, deviceName: String?) {
        awaitingNewPairingConnection = false

        // Update the pending device's display name from "Pending pairing…"
        let devices = pairingManager.loadDevices()
        if let pending = devices.first(where: { $0.sharedSecret == secret && $0.displayName.contains("Pending") }) {
            pairingManager.removeDevice(secret: secret)
            let updated = PairedDevice(
                sharedSecret: pending.sharedSecret,
                displayName: deviceName ?? "Android",
                datePaired: pending.datePaired
            )
            pairingManager.addDevice(updated)
        }

        pairingWindowController.close()
        refreshTrustedPeersMenu()
        appLogger.info("[App] Pairing completed")
    }

    private func cancelPendingPairingFlow(removePendingDevice: Bool) {
        awaitingNewPairingConnection = false
        if removePendingDevice {
            pairingManager.removePendingDevices()
        }
        refreshTrustedPeersMenu()
    }

    // MARK: - Device Management

    private func forgetDevice(token: String) {
        pairingManager.removeDevice(secret: token)

        // If the forgotten device is currently connected, disconnect
        if connectedSecret == token {
            activeSession?.close()
            activeSession = nil
            connectedSecret = nil
            connectionManager?.disconnect()
            statusBarController.setConnectedPeers([])
        }

        refreshTrustedPeersMenu()

        // Restart scanning to pick up remaining paired devices
        connectionManager?.startScanning()
    }

    // MARK: - Bluetooth Alert

    private func showBluetoothAlert(message: String, info: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Dismiss")

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - Image Sync Toggle

    private func toggleImageSync() {
        // Determine which device to toggle — prefer connected, fall back to first paired
        let secret = connectedSecret ?? pairingManager.loadDevices().first?.sharedSecret
        guard let secret else { return }

        let devices = pairingManager.loadDevices()
        guard let device = devices.first(where: { $0.sharedSecret == secret }) else { return }

        let newEnabled = !device.richMediaEnabled
        let changedAt = Int64(Date().timeIntervalSince1970)
        pairingManager.setRichMediaEnabled(newEnabled, changedAt: changedAt, forSecret: secret)

        // Send CONFIG_UPDATE to the remote device
        activeSession?.sendConfigUpdate()

        appLogger.info("[App] Image sync toggled to \(newEnabled)")
    }

    // MARK: - Menu Helpers

    private func refreshTrustedPeersMenu() {
        let devices = pairingManager.loadDevices()
        let peers = devices.map { device in
            PeerSummary(
                id: deviceStableID(token: device.sharedSecret),
                description: device.displayName,
                secret: device.sharedSecret,
                deviceTagHex: formattedDeviceTagHex(token: device.sharedSecret)
            )
        }
        .sorted { $0.description.localizedCaseInsensitiveCompare($1.description) == .orderedAscending }

        statusBarController.setTrustedPeers(peers)
    }

    private func deviceStableID(token: String) -> UUID {
        // Derive a stable UUID from the token for UI consistency
        let hash = SHA256.hash(data: Data(token.utf8))
        let bytes = Array(hash)
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private func formattedDeviceTagHex(token: String) -> String? {
        guard let data = pairingManager.deviceTag(for: token) else { return nil }
        let hex = data.prefix(4).map { String(format: "%02X", $0) }.joined()
        return stride(from: 0, to: hex.count, by: 4).map { i in
            let start = hex.index(hex.startIndex, offsetBy: i)
            let end = hex.index(start, offsetBy: min(4, hex.count - i))
            return String(hex[start..<end])
        }.joined(separator: " ")
    }
}

// MARK: - ConnectionManagerDelegate

extension AppDelegate: ConnectionManagerDelegate {
    func connectionManager(_ manager: ConnectionManager, didEstablishChannel inputStream: InputStream,
                           outputStream: OutputStream, for token: String) {
        connectedSecret = token

        // Remove streams from the main RunLoop — Session runs them on its own background thread
        inputStream.remove(from: .main, forMode: .common)
        outputStream.remove(from: .main, forMode: .common)

        // Create session (Mac = initiator)
        let settingsProvider = DeviceSettingsProvider(pairingManager: pairingManager, secret: token)
        let session = Session(inputStream: inputStream, outputStream: outputStream,
                              isInitiator: true, delegate: self,
                              sharedSecretHex: token)
        session.localName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        session.settingsProvider = settingsProvider
        activeSettingsProvider = settingsProvider
        activeSession = session

        // Run session on background thread
        let thread = Thread { [weak self] in
            // Schedule streams on this thread's RunLoop
            let runLoop = RunLoop.current
            inputStream.schedule(in: runLoop, forMode: .common)
            outputStream.schedule(in: runLoop, forMode: .common)

            session.performHandshake()
            session.listenForMessages()

            // If we get here, the session has ended
            DispatchQueue.main.async {
                self?.handleSessionEnded(session)
            }
        }
        thread.name = "L2CAP-Session"
        thread.start()
        sessionThread = thread

        // UI update deferred to sessionDidBecomeReady (after handshake exchanges device name)

        appLogger.info("[App] L2CAP channel established, starting handshake")
    }

    func connectionManager(_ manager: ConnectionManager, didUpdateBluetoothState state: CBManagerState) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch state {
            case .poweredOn:
                // Cancel any pending "Bluetooth off" alert — BT recovered (e.g. after sleep/wake)
                self.bluetoothOffDebounceTimer?.invalidate()
                self.bluetoothOffDebounceTimer = nil
                self.statusBarController.setBluetoothWarning(nil)
                self.hasShownBluetoothAlert = false
            case .poweredOff:
                self.statusBarController.setBluetoothWarning("Bluetooth is turned off")
                // Debounce: wait before showing the modal alert.
                // macOS transiently reports poweredOff during sleep/wake cycles;
                // if BT comes back within the window, the alert is cancelled.
                if !self.hasShownBluetoothAlert && self.bluetoothOffDebounceTimer == nil {
                    self.bluetoothOffDebounceTimer = Timer.scheduledTimer(
                        withTimeInterval: Self.bluetoothOffDebounceDelay, repeats: false
                    ) { [weak self] _ in
                        guard let self else { return }
                        self.bluetoothOffDebounceTimer = nil
                        self.hasShownBluetoothAlert = true
                        self.showBluetoothAlert(
                            message: "Bluetooth is turned off",
                            info: "ClipRelay needs Bluetooth to sync your clipboard. Please enable Bluetooth in System Settings."
                        )
                    }
                }
            case .unauthorized:
                self.statusBarController.setBluetoothWarning("Bluetooth permission denied")
                if !self.hasShownBluetoothAlert {
                    self.hasShownBluetoothAlert = true
                    self.showBluetoothAlert(
                        message: "Bluetooth access denied",
                        info: "ClipRelay needs Bluetooth permission. Please grant access in System Settings > Privacy & Security > Bluetooth."
                    )
                }
            default:
                break
            }
        }
    }

    func connectionManager(_ manager: ConnectionManager, didDisconnectFor token: String) {
        appLogger.info("[App] Connection lost for token")

        activeSession?.close()
        activeSession = nil
        activeSettingsProvider = nil
        connectedSecret = nil
        sessionThread = nil

        DispatchQueue.main.async { [weak self] in
            self?.updateConnectedPeersMenu(token: token, deviceName: nil, connected: false)
        }

        // ConnectionManager handles reconnect automatically via scheduleReconnect
    }

    func connectionManager(_ manager: ConnectionManager, didEstablishPairingChannel inputStream: InputStream,
                           outputStream: OutputStream) {
        // Remove streams from main RunLoop
        inputStream.remove(from: .main, forMode: .common)
        outputStream.remove(from: .main, forMode: .common)

        guard let privateKey = pairingManager.ephemeralPrivateKey else {
            appLogger.error("[App] Pairing channel established but no ephemeral key")
            inputStream.close()
            outputStream.close()
            return
        }

        // Create session in pairing mode (settingsProvider wired after pairing completes)
        let session = Session(inputStream: inputStream, outputStream: outputStream,
                              isInitiator: true, delegate: self,
                              mode: .pairing(privateKey: privateKey))
        session.localName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        activeSession = session

        // Run session on background thread (same pattern as normal connections)
        let thread = Thread { [weak self] in
            let runLoop = RunLoop.current
            inputStream.schedule(in: runLoop, forMode: .common)
            outputStream.schedule(in: runLoop, forMode: .common)

            session.performHandshake()
            session.listenForMessages()

            DispatchQueue.main.async {
                self?.handleSessionEnded(session)
            }
        }
        thread.name = "L2CAP-Pairing"
        thread.start()
        sessionThread = thread

        appLogger.info("[App] Pairing L2CAP channel established, starting ECDH handshake")
    }

    private func handleSessionEnded(_ endedSession: Session) {
        // Only clear if the ended session is still the active one.
        // A rapid reconnect may have already replaced activeSession
        // with a new session before this async dispatch runs.
        guard activeSession === endedSession else { return }
        activeSession = nil
        sessionThread = nil
    }

    private func updateConnectedPeersMenu(token: String, deviceName: String?, connected: Bool) {
        if connected, let deviceName {
            let peer = PeerSummary(
                id: deviceStableID(token: token),
                description: deviceName,
                secret: token,
                deviceTagHex: formattedDeviceTagHex(token: token)
            )
            statusBarController.setConnectedPeers([peer])
        } else {
            statusBarController.setConnectedPeers([])
        }
    }
}

// MARK: - SessionDelegate

extension AppDelegate: SessionDelegate {
    func sessionDidBecomeReady(_ session: Session) {
        let remoteName = session.remoteName
        appLogger.info("[App] Session handshake complete — remote device: \(remoteName ?? "unknown", privacy: .private)")

        // Update stored device name from handshake and refresh UI
        if let token = connectedSecret {
            // Update the persisted device name if the remote sent one
            if let name = remoteName {
                let devices = pairingManager.loadDevices()
                if let existing = devices.first(where: { $0.sharedSecret == token && $0.displayName != name }) {
                    pairingManager.removeDevice(secret: token)
                    let updated = PairedDevice(sharedSecret: existing.sharedSecret, displayName: name, datePaired: existing.datePaired)
                    pairingManager.addDevice(updated)
                }
            }

            let deviceName = remoteName
                ?? pairingManager.loadDevices().first(where: { $0.sharedSecret == token })?.displayName
                ?? "Android"

            DispatchQueue.main.async { [weak self] in
                self?.updateConnectedPeersMenu(token: token, deviceName: deviceName, connected: true)

                // Complete pairing if we were waiting for a new connection
                if self?.awaitingNewPairingConnection == true {
                    self?.completePairing(secret: token, deviceName: remoteName)
                    self?.refreshTrustedPeersMenu()
                }
            }
        }

        // If there's a pending clipboard payload, send it
        if let pending = pendingClipboardPayload {
            session.sendClipboard(pending)
            appLogger.info("[App] Sent pending clipboard after reconnect (\(pending.count) bytes)")
        }
    }

    func session(_ session: Session, didReceivePlaintext plaintext: Data, hash: String) {
        guard connectedSecret != nil else {
            appLogger.error("[App] Received clipboard but no connected token")
            return
        }
        guard let text = String(data: plaintext, encoding: .utf8) else {
            appLogger.error("[App] Received data is not valid UTF-8")
            return
        }

        // Track hash for dedup (prevent echo back)
        let textHash = SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        lastReceivedHash = textHash

        appLogger.info("[App] Received clipboard from Android (\(text.count) chars)")

        DispatchQueue.main.async { [weak self] in
            self?.clipboardWriter.writeText(text)
            self?.notificationManager.postClipboardReceived(text: text)
            self?.statusBarController.flashSyncIndicator()
        }
    }

    func session(_ session: Session, didReceiveImage data: Data, contentType: String, hash: String) {
        lastReceivedImageHash = hash
        appLogger.info("[App] Received image from Android (\(data.count) bytes, \(contentType))")

        DispatchQueue.main.async { [weak self] in
            self?.clipboardWriter.writeImage(data, contentType: contentType)
            self?.statusBarController.flashSyncIndicator()
        }
    }

    func session(_ session: Session, didCompletePairingWithSecret sharedSecret: Data, remoteName: String?) {
        let secretHex = sharedSecret.map { String(format: "%02x", $0) }.joined()

        // Store the paired device
        let device = PairedDevice(
            sharedSecret: secretHex,
            displayName: remoteName ?? "Android",
            datePaired: Date()
        )
        pairingManager.addDevice(device)
        pairingManager.clearEphemeralKey()

        // Wire settings provider now that we have the secret
        let settingsProvider = DeviceSettingsProvider(pairingManager: pairingManager, secret: secretHex)
        session.settingsProvider = settingsProvider
        activeSettingsProvider = settingsProvider

        // Clear pairing mode and set the matched token so that if the BLE
        // connection drops, didDisconnectPeripheral properly notifies us
        // (matchedToken was nil during pairing discovery).
        connectionManager.pairingTag = nil
        connectionManager.setMatchedToken(secretHex)
        connectedSecret = secretHex

        DispatchQueue.main.async { [weak self] in
            self?.completePairing(secret: secretHex, deviceName: remoteName)
        }
    }

    func session(_ session: Session, didCompleteTransfer hash: String) {
        appLogger.info("[App] Transfer complete (hash: \(hash.prefix(8))...)")
        pendingClipboardPayload = nil  // transfer succeeded, clear pending

        DispatchQueue.main.async { [weak self] in
            self?.statusBarController.flashSyncIndicator()
        }
    }

    func session(_ session: Session, didFailWithError error: Error) {
        appLogger.error("[App] Session error: \(error.localizedDescription)")

        if case SessionError.versionMismatch = error {
            activeSession = nil
            sessionThread = nil
            DispatchQueue.main.async { [weak self] in
                self?.statusBarController.setConnectedPeers([])
                self?.showBluetoothAlert(
                    message: "App Update Required",
                    info: "Your Android app needs to be updated to continue syncing. Update via Google Play."
                )
            }
            return
        }

        activeSession = nil
        sessionThread = nil

        DispatchQueue.main.async { [weak self] in
            self?.statusBarController.setConnectedPeers([])
        }

        // ConnectionManager handles reconnect automatically
    }

    func session(_ session: Session, alreadyHasHash hash: String) -> Bool {
        return hash == lastReceivedHash
    }

    func session(_ session: Session, didChangeRichMediaSetting enabled: Bool) {
        appLogger.info("[App] Remote changed image sync setting to \(enabled)")
        // The settings provider already persisted the change via resolveSettings/handleConfigUpdate.
        // Just refresh the menu so the checkmark reflects the new state.
        DispatchQueue.main.async { [weak self] in
            self?.statusBarController.setConnectedPeers(self?.connectedPeers() ?? [])
        }
    }

    private func connectedPeers() -> [PeerSummary] {
        guard let token = connectedSecret else { return [] }
        let deviceName = pairingManager.loadDevices().first(where: { $0.sharedSecret == token })?.displayName ?? "Android"
        return [PeerSummary(
            id: deviceStableID(token: token),
            description: deviceName,
            secret: token,
            deviceTagHex: formattedDeviceTagHex(token: token)
        )]
    }
}
