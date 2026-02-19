import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusBarController = StatusBarController()
    private let clipboardWriter = ClipboardWriter()
    private let notificationManager = ReceiveNotificationManager()

    private var bleManager: BLECentralManager?
    private var clipboardMonitor: ClipboardMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        notificationManager.requestAuthorization()

        statusBarController.onPairRequested = { [weak self] in
            self?.presentPairingInstructions()
        }

        bleManager = BLECentralManager(clipboardWriter: clipboardWriter)
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

    private func presentPairingInstructions() {
        let alert = NSAlert()
        alert.messageText = "Pair via Bluetooth Settings"
        alert.informativeText = "Open Bluetooth settings on macOS and Android, pair the devices, then keep GreenPaste running on both devices."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
