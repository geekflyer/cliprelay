import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusBarController = StatusBarController()
    private let clipboardWriter = ClipboardWriter()
    private let notificationManager = ReceiveNotificationManager()

    private var bleManager: BLECentralManager?
    private var clipboardMonitor: ClipboardMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        notificationManager.requestAuthorization()

        statusBarController.onOpenBluetoothSettingsRequested = { [weak self] in
            self?.openBluetoothSettings()
        }
        statusBarController.onApproveDeviceRequested = { [weak self] id in
            self?.bleManager?.approvePeer(id: id)
        }
        statusBarController.onForgetDeviceRequested = { [weak self] id in
            self?.bleManager?.revokePeer(id: id)
        }

        bleManager = BLECentralManager(clipboardWriter: clipboardWriter)
        bleManager?.onClipboardReceived = { [weak self] text in
            self?.notificationManager.postClipboardReceived(text: text)
        }

        clipboardMonitor = ClipboardMonitor { [weak self] text in
            self?.bleManager?.sendClipboardText(text)
        }

        statusBarController.setConnected(false)
        statusBarController.setConnectedPeers([])
        bleManager?.onConnectionStateChanged = { [weak self] isConnected in
            DispatchQueue.main.async {
                self?.statusBarController.setConnected(isConnected)
            }
        }
        bleManager?.onConnectedPeersChanged = { [weak self] peerDescriptions in
            DispatchQueue.main.async {
                self?.statusBarController.setConnectedPeers(peerDescriptions)
            }
        }
        bleManager?.onDiscoveredPeersChanged = { [weak self] peers in
            DispatchQueue.main.async {
                self?.statusBarController.setDiscoveredPeers(peers)
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

    private func openBluetoothSettings() {
        let deepLinks = [
            "x-apple.systempreferences:com.apple.BluetoothSettings",
            "x-apple.systempreferences:com.apple.preference.bluetooth",
            "x-apple.systempreferences:com.apple.Bluetooth"
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
