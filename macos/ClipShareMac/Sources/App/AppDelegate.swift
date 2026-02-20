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
                if !peers.isEmpty {
                    self?.pairingWindowController.close()
                }
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

}
