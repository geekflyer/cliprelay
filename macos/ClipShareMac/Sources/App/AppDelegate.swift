import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let pairingManager = PairingManager()
    private let statusBarController = StatusBarController()
    private let clipboardWriter = ClipboardWriter()
    private let notificationManager = ReceiveNotificationManager()
    private let pairingWindowController = PairingWindowController()

    private var bleManager: BLECentralManager?
    private var clipboardMonitor: ClipboardMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        notificationManager.requestAuthorization()

        statusBarController.onOpenBluetoothSettingsRequested = { [weak self] in
            self?.openBluetoothSettings()
        }
        statusBarController.onPairNewDeviceRequested = { [weak self] in
            self?.startPairing()
        }
        statusBarController.onForgetDeviceRequested = { [weak self] token in
            self?.bleManager?.forgetDevice(token: token)
        }

        bleManager = BLECentralManager(clipboardWriter: clipboardWriter, pairingManager: pairingManager)
        bleManager?.onClipboardReceived = { [weak self] text in
            self?.notificationManager.postClipboardReceived(text: text)
        }

        clipboardMonitor = ClipboardMonitor { [weak self] text in
            self?.bleManager?.sendClipboardText(text)
        }

        bleManager?.onConnectedPeersChanged = { [weak self] peers in
            DispatchQueue.main.async {
                self?.statusBarController.setConnectedPeers(peers)
            }
        }
        bleManager?.onTrustedPeersChanged = { [weak self] peers in
            DispatchQueue.main.async {
                self?.statusBarController.setTrustedPeers(peers)
            }
        }

        bleManager?.start()
        clipboardMonitor?.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        clipboardMonitor?.stop()
        bleManager?.stop()
    }

    private func startPairing() {
        let token = pairingManager.generateToken()
        let device = PairedDevice(
            token: token,
            displayName: "Pending pairing\u{2026}",
            datePaired: Date()
        )
        pairingManager.addDevice(device)

        guard let uri = pairingManager.pairingURI(token: token) else { return }
        pairingWindowController.showPairingQR(uri: uri)

        // Refresh trusted list to show pending device
        bleManager?.notifyAllState()
    }

    private func openBluetoothSettings() {
        let deepLinks = [
            "x-apple.systempreferences:com.apple.BluetoothSettings",
            "x-apple.systempreferences:com.apple.preference.bluetooth",
            "x-apple.systempreferences:com.apple.Bluetooth",
        ]

        for link in deepLinks {
            guard let url = URL(string: link) else { continue }
            if NSWorkspace.shared.open(url) {
                return
            }
        }

        _ = URL(string: "x-apple.systempreferences:com.apple.SystemPreferences")
            .map { NSWorkspace.shared.open($0) }
    }
}
