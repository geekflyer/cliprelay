import AppKit
import Foundation

final class StatusBarController {
    var onOpenBluetoothSettingsRequested: (() -> Void)?
    var onApproveDeviceRequested: ((UUID) -> Void)?
    var onForgetDeviceRequested: ((UUID) -> Void)?

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    private var isConnected = false
    private var connectedPeers: [PeerSummary] = []
    private var discoveredPeers: [PeerSummary] = []
    private var trustedPeers: [PeerSummary] = []

    init() {
        if let button = statusItem.button {
            if let iconImage = loadStatusBarIcon() {
                iconImage.isTemplate = true
                button.image = iconImage
            } else {
                button.title = "GP"
            }
        }
        renderMenu()
    }

    private func loadStatusBarIcon() -> NSImage? {
        // Look in the app bundle's Resources directory
        if let bundlePath = Bundle.main.path(forResource: "StatusBarIcon", ofType: "png") {
            let image = NSImage(contentsOfFile: bundlePath)
            image?.size = NSSize(width: 18, height: 18)
            return image
        }
        return nil
    }

    func setConnected(_ connected: Bool) {
        isConnected = connected
        renderMenu()
    }

    func setConnectedPeers(_ peers: [PeerSummary]) {
        connectedPeers = peers
        renderMenu()
    }

    func setDiscoveredPeers(_ peers: [PeerSummary]) {
        discoveredPeers = peers
        renderMenu()
    }

    func setTrustedPeers(_ peers: [PeerSummary]) {
        trustedPeers = peers
        renderMenu()
    }

    private func renderMenu() {
        menu.removeAllItems()

        menu.addItem(NSMenuItem(title: isConnected ? "Status: Connected" : "Status: Disconnected", action: nil, keyEquivalent: ""))

        if connectedPeers.isEmpty {
            menu.addItem(NSMenuItem(title: "Devices: Not connected", action: nil, keyEquivalent: ""))
        } else {
            let connectedHeader = NSMenuItem(title: "Connected devices", action: nil, keyEquivalent: "")
            connectedHeader.isEnabled = false
            menu.addItem(connectedHeader)
            connectedPeers.forEach { peer in
                let item = NSMenuItem(title: "  \(peer.description)", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())

        let discoveredHeader = NSMenuItem(title: "Discovered devices", action: nil, keyEquivalent: "")
        discoveredHeader.isEnabled = false
        menu.addItem(discoveredHeader)
        if discoveredPeers.isEmpty {
            let none = NSMenuItem(title: "  No new devices found", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            discoveredPeers.forEach { peer in
                let item = NSMenuItem(title: "  Allow \(peer.description)", action: #selector(handleApproveDevice(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = peer.id.uuidString
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())

        let trustedHeader = NSMenuItem(title: "Trusted devices", action: nil, keyEquivalent: "")
        trustedHeader.isEnabled = false
        menu.addItem(trustedHeader)
        if trustedPeers.isEmpty {
            let none = NSMenuItem(title: "  No trusted devices", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            trustedPeers.forEach { peer in
                let item = NSMenuItem(title: "  Forget \(peer.description)", action: #selector(handleForgetDevice(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = peer.id.uuidString
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())
        let openSettings = NSMenuItem(title: "Open Bluetooth Settings (Troubleshoot)", action: #selector(handleOpenBluetoothSettings), keyEquivalent: "b")
        openSettings.target = self
        menu.addItem(openSettings)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    @objc
    private func handleOpenBluetoothSettings() {
        onOpenBluetoothSettingsRequested?()
    }

    @objc
    private func handleApproveDevice(_ sender: NSMenuItem) {
        guard
            let rawID = sender.representedObject as? String,
            let id = UUID(uuidString: rawID)
        else {
            return
        }
        onApproveDeviceRequested?(id)
    }

    @objc
    private func handleForgetDevice(_ sender: NSMenuItem) {
        guard
            let rawID = sender.representedObject as? String,
            let id = UUID(uuidString: rawID)
        else {
            return
        }
        onForgetDeviceRequested?(id)
    }
}
