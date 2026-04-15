// Core app delegate: wires together BLE, clipboard, pairing, and UI subsystems.

import AppKit
import CoreBluetooth
import CryptoKit
import os
import ServiceManagement
import Sparkle
import UserNotifications

private let appLogger = Logger(subsystem: "org.cliprelay", category: "App")

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let updaterController: SPUStandardUpdaterController
    private let updaterDelegate = UpdaterDelegate()
    private let updaterDriverDelegate = UpdaterDriverDelegate()
    private let pairingManager = PairingManager()
    private let statusBarController: StatusBarController
    private let clipboardWriter = ClipboardWriter()
    private let notificationManager = ReceiveNotificationManager()
    private let pairingWindowController = PairingWindowController()

    override init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: updaterDelegate, userDriverDelegate: updaterDriverDelegate)
        statusBarController = StatusBarController(updaterController: updaterController)
        super.init()
    }

    private var connectionController: ConnectionController!

    private var telemetryManager: TelemetryManager?
    private var clipboardMonitor: ClipboardMonitor?
    private var awaitingNewPairingConnection = false
    private var hasShownBluetoothAlert = false
    private var bluetoothOffDebounceTimer: Timer?
    private static let bluetoothOffDebounceDelay: TimeInterval = 60.0

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Start the Sparkle updater now that the app is fully launched.
        // Creating the controller with startingUpdater:false in init() and
        // deferring start to here avoids a race where the updater's scheduled
        // cycle fires before the runloop is running.
        updaterController.startUpdater()
        if updaterController.updater.automaticallyChecksForUpdates {
            updaterController.updater.checkForUpdatesInBackground()
        }

        UNUserNotificationCenter.current().delegate = updaterDriverDelegate
        notificationManager.requestAuthorization()
        pairingManager.removePendingDevices()
        enableLaunchAtLoginIfFirstRun()
        installSleepWakeObservers()

        updaterDriverDelegate.onUpdateAvailabilityChanged = { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                self.statusBarController.setAvailableUpdateVersion(
                    self.updaterDriverDelegate.availableUpdateVersion)
            }
        }
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
            self?.connectionController?.toggleImageSync()
        }
        statusBarController.isImageSyncEnabled = { [weak self] in
            self?.connectionController?.isImageSyncEnabled ?? false
        }
        statusBarController.isDeviceConnected = { [weak self] in
            self?.connectionController?.isConnected ?? false
        }
        statusBarController.bleStateProvider = { [weak self] in
            if self?.connectionController?.isConnected == true { return "connected" }
            let isPaired = !(self?.pairingManager.loadDevices().isEmpty ?? true)
            return isPaired ? "searching" : "unpaired"
        }
        pairingWindowController.onDidClose = { [weak self] in
            self?.handlePairingWindowClosed()
        }

        // Set up ConnectionController (L2CAP)
        connectionController = ConnectionController(pairingManager: pairingManager)
        connectionController.delegate = self

        // Clipboard monitor triggers outbound sends via ConnectionController
        clipboardMonitor = ClipboardMonitor { [weak self] text in
            self?.connectionController?.sendClipboard(text)
        }
        clipboardMonitor?.onImageChange = { [weak self] imageData, contentType, _ in
            self?.connectionController?.sendImage(imageData, contentType: contentType)
        }

        // Start monitoring
        clipboardMonitor?.start()

        // Refresh trusted device list in the menu
        refreshTrustedPeersMenu()

        // Anonymous usage check-ins
        telemetryManager = TelemetryManager { [weak self] in
            guard let self else { return .noPeering }
            if self.connectionController?.isConnected == true { return .activePeering }
            if !self.pairingManager.loadDevices().isEmpty { return .idlePeering }
            return .noPeering
        }
        telemetryManager?.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        bluetoothOffDebounceTimer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        telemetryManager?.stop()
        clipboardMonitor?.stop()
        connectionController?.disconnect()
    }

    // MARK: - Launch at Login

    private func enableLaunchAtLoginIfFirstRun() {
        let key = "hasEnabledLaunchAtLogin"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        do {
            try SMAppService.mainApp.register()
            appLogger.notice("[App] Launch at login enabled on first run")
        } catch {
            appLogger.error("[App] Failed to enable launch at login: \(error.localizedDescription)")
        }
    }

    // MARK: - Pairing

    private func startPairing() {
        awaitingNewPairingConnection = true
        guard let info = connectionController.startPairing() else { return }
        pairingWindowController.showPairingQR(uri: info.uri)
        refreshTrustedPeersMenu()
    }

    private func handlePairingWindowClosed() {
        guard awaitingNewPairingConnection else { return }
        connectionController.cancelPairing()
        cancelPendingPairingFlow(removePendingDevice: true)
    }

    private func completePairing(deviceName: String?) {
        awaitingNewPairingConnection = false
        pairingWindowController.close()
        refreshTrustedPeersMenu()
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
        connectionController.forgetDevice(token: token)
        refreshTrustedPeersMenu()
    }

    // MARK: - Bluetooth Alert

    private func installSleepWakeObservers() {
        // `Timer` deadlines survive sleep: after a long sleep the debounce can fire immediately on wake,
        // before CoreBluetooth delivers `.poweredOn`. Cancel on sleep so wake uses fresh callbacks only.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSystemWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
    }

    @objc private func handleSystemWillSleep(_ notification: Notification) {
        bluetoothOffDebounceTimer?.invalidate()
        bluetoothOffDebounceTimer = nil
        statusBarController.setBluetoothWarning(nil)
    }

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

// MARK: - ConnectionControllerDelegate

extension AppDelegate: ConnectionControllerDelegate {
    func didChangeState(connected: Bool, deviceName: String?, token: String?) {
        if connected, let deviceName, let token {
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

    func didReceiveClipboard(text: String) {
        clipboardWriter.writeText(text)
        notificationManager.postClipboardReceived(text: text)
        statusBarController.flashSyncIndicator()
    }

    func didReceiveImage(data: Data, contentType: String) {
        clipboardWriter.writeImage(data, contentType: contentType)
        statusBarController.flashSyncIndicator()
    }

    func didCompletePairing(deviceName: String?) {
        if awaitingNewPairingConnection {
            completePairing(deviceName: deviceName)
        }
    }

    func didEncounterError(error: ConnectionError) {
        switch error {
        case .versionMismatch:
            showBluetoothAlert(
                message: "App Update Required",
                info: "Your Android app needs to be updated to continue syncing. Update via Google Play."
            )
        default: break
        }
    }

    func didUpdateBluetoothState(state: CBManagerState) {
        switch state {
        case .poweredOn:
            bluetoothOffDebounceTimer?.invalidate()
            bluetoothOffDebounceTimer = nil
            statusBarController.setBluetoothWarning(nil)
            hasShownBluetoothAlert = false
        case .unauthorized:
            statusBarController.setBluetoothWarning("Bluetooth permission denied")
            if !hasShownBluetoothAlert {
                hasShownBluetoothAlert = true
                showBluetoothAlert(
                    message: "Bluetooth access denied",
                    info: "ClipRelay needs Bluetooth permission. Please grant access in System Settings > Privacy & Security > Bluetooth."
                )
            }
        case .poweredOff:
            if !hasShownBluetoothAlert && bluetoothOffDebounceTimer == nil {
                bluetoothOffDebounceTimer = Timer.scheduledTimer(
                    withTimeInterval: Self.bluetoothOffDebounceDelay, repeats: false
                ) { [weak self] _ in
                    guard let self else { return }
                    self.bluetoothOffDebounceTimer = nil
                    self.hasShownBluetoothAlert = true
                    self.statusBarController.setBluetoothWarning("Bluetooth is turned off")
                    self.showBluetoothAlert(
                        message: "Bluetooth is turned off",
                        info: "ClipRelay needs Bluetooth to sync your clipboard. Please enable Bluetooth in System Settings."
                    )
                }
            }
        default: break
        }
    }

    func didSyncClipboard(hash: String) {
        statusBarController.flashSyncIndicator()
    }

    func didChangeImageSyncSetting(enabled: Bool) {
        // Refresh the menu to update the checkmark
        if let cc = connectionController, let token = cc.connectedToken {
            let deviceName = cc.pairedDevices.first(where: { $0.sharedSecret == token })?.displayName ?? "Android"
            let peer = PeerSummary(id: deviceStableID(token: token), description: deviceName, secret: token, deviceTagHex: formattedDeviceTagHex(token: token))
            statusBarController.setConnectedPeers([peer])
        }
    }

    func imageTransferFailed(reason: String) {
        // Logged by ConnectionController
    }
}
