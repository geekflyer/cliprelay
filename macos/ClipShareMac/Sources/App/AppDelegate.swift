import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusBarController = StatusBarController()
    private let clipboardWriter = ClipboardWriter()
    private let notificationManager = ReceiveNotificationManager()
    private let pairingManager = PairingManager()
    private let pairingWindowController = PairingWindowController()

    private var bleManager: BLECentralManager?
    private var clipboardMonitor: ClipboardMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        notificationManager.requestAuthorization()

        statusBarController.onPairRequested = { [weak self] in
            self?.presentPairingQR()
        }

        bleManager = BLECentralManager(
            clipboardWriter: clipboardWriter,
            sharedSeedProvider: { [weak self] in
                self?.pairingManager.currentSeed() ?? Data("clipboard-sync-dev-seed".utf8)
            }
        )

        bleManager?.setExpectedPairingToken(pairingManager.pairingToken())
        bleManager?.onClipboardReceived = { [weak self] text in
            self?.notificationManager.postClipboardReceived(text: text)
        }

        clipboardMonitor = ClipboardMonitor { [weak self] text in
            self?.bleManager?.sendClipboardText(text)
        }

        statusBarController.setConnected(false)
        bleManager?.onConnectionStateChanged = { [weak self] isConnected in
            DispatchQueue.main.async {
                self?.statusBarController.setConnected(isConnected)
            }
        }

        bleManager?.start()
        clipboardMonitor?.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        clipboardMonitor?.stop()
        bleManager?.stop()
    }

    private func presentPairingQR() {
        guard let uri = pairingManager.generatePairingURI(serviceUUID: BLEProtocol.serviceUUID.uuidString.lowercased()) else {
            return
        }

        bleManager?.setExpectedPairingToken(pairingManager.pairingToken())
        pairingWindowController.showPairingQR(uri: uri)
    }
}
