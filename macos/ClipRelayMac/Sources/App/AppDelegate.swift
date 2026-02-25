import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let pairingManager = PairingManager()
    private let statusBarController = StatusBarController()
    private let clipboardWriter = ClipboardWriter()
    private let notificationManager = ReceiveNotificationManager()
    private let pairingWindowController = PairingWindowController()

    private var bleManager: BLECentralManager?
    private var clipboardMonitor: ClipboardMonitor?
    private var lastConnectedPeerIDs: Set<UUID> = []
    private var pairingBaselineConnectedPeerIDs: Set<UUID> = []
    private var awaitingNewPairingConnection = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        notificationManager.requestAuthorization()
        pairingManager.removePendingDevices()

        statusBarController.onPairNewDeviceRequested = { [weak self] in
            self?.startPairing()
        }
        statusBarController.onForgetDeviceRequested = { [weak self] token in
            self?.bleManager?.forgetDevice(token: token)
        }
        pairingWindowController.onDidClose = { [weak self] in
            self?.handlePairingWindowClosed()
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
                guard let self else { return }
                let connectedPeerIDs = Set(peers.map(\.id))
                self.lastConnectedPeerIDs = connectedPeerIDs
                self.statusBarController.setConnectedPeers(peers)

                guard self.awaitingNewPairingConnection else { return }
                guard self.pairingWindowController.isShowing else {
                    self.awaitingNewPairingConnection = false
                    return
                }

                let newlyConnectedPeers = connectedPeerIDs.subtracting(self.pairingBaselineConnectedPeerIDs)
                if !newlyConnectedPeers.isEmpty {
                    self.awaitingNewPairingConnection = false
                    self.bleManager?.setPendingPairingToken(nil)
                    self.pairingWindowController.close()
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
        pairingManager.removePendingDevices()

        guard let token = pairingManager.generateToken() else {
            print("[Pairing] Failed to generate secure token")
            return
        }
        let device = PairedDevice(
            token: token,
            displayName: "Pending pairing\u{2026}",
            datePaired: Date()
        )
        pairingManager.addDevice(device)

        pairingBaselineConnectedPeerIDs = lastConnectedPeerIDs
        awaitingNewPairingConnection = true
        bleManager?.setPendingPairingToken(token)

        guard let uri = pairingManager.pairingURI(token: token) else { return }
        pairingWindowController.showPairingQR(uri: uri)

        // Refresh trusted list to show pending device
        bleManager?.notifyAllState()
    }

    private func handlePairingWindowClosed() {
        guard awaitingNewPairingConnection else { return }
        awaitingNewPairingConnection = false
        pairingManager.removePendingDevices()
        bleManager?.setPendingPairingToken(nil)
        bleManager?.notifyAllState()
    }

}
