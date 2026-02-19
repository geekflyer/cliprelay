import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusBarController = StatusBarController()
    private let clipboardWriter = ClipboardWriter()
    private var bleManager: BLECentralManager?
    private var clipboardMonitor: ClipboardMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        bleManager = BLECentralManager(clipboardWriter: clipboardWriter)
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
}
