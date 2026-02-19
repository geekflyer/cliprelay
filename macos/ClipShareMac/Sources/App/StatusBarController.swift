import AppKit
import Foundation

final class StatusBarController {
    var onOpenBluetoothSettingsRequested: (() -> Void)?
    var onApproveDeviceRequested: ((UUID) -> Void)?
    var onForgetDeviceRequested: ((UUID) -> Void)?

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    private var connectedPeers: [PeerSummary] = []
    private var discoveredPeers: [PeerSummary] = []
    private var trustedPeers: [PeerSummary] = []

    private lazy var connectedDot: NSImage = makeStatusDot(color: .systemGreen)
    private lazy var disconnectedDot: NSImage = makeStatusDot(color: .tertiaryLabelColor)

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
        if let bundlePath = Bundle.main.path(forResource: "StatusBarIcon", ofType: "png") {
            let image = NSImage(contentsOfFile: bundlePath)
            image?.size = NSSize(width: 18, height: 18)
            return image
        }
        return nil
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

    // MARK: - Menu rendering

    private func renderMenu() {
        menu.removeAllItems()

        renderTrustedDevicesSection()
        menu.addItem(NSMenuItem.separator())
        renderDiscoveredDevicesSection()
        menu.addItem(NSMenuItem.separator())

        let openSettings = NSMenuItem(
            title: "Bluetooth Settings\u{2026}",
            action: #selector(handleOpenBluetoothSettings),
            keyEquivalent: "b"
        )
        openSettings.target = self
        menu.addItem(openSettings)

        menu.addItem(NSMenuItem(
            title: "Quit GreenPaste",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))

        statusItem.menu = menu
    }

    private func renderTrustedDevicesSection() {
        let header = NSMenuItem(title: "Trusted Devices", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if trustedPeers.isEmpty {
            let empty = NSMenuItem(title: "  No trusted devices", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }

        let connectedIDs = Set(connectedPeers.map(\.id))

        for peer in trustedPeers {
            let isConnected = connectedIDs.contains(peer.id)

            let item = NSMenuItem(title: peer.description, action: nil, keyEquivalent: "")
            item.image = isConnected ? connectedDot : disconnectedDot
            item.isEnabled = true

            let submenu = NSMenu()
            let statusLabel = NSMenuItem(
                title: isConnected ? "Connected" : "Not in range",
                action: nil,
                keyEquivalent: ""
            )
            statusLabel.isEnabled = false
            submenu.addItem(statusLabel)
            submenu.addItem(NSMenuItem.separator())

            let forgetItem = NSMenuItem(
                title: "Forget Device",
                action: #selector(handleForgetDevice(_:)),
                keyEquivalent: ""
            )
            forgetItem.target = self
            forgetItem.representedObject = peer.id.uuidString
            submenu.addItem(forgetItem)

            item.submenu = submenu
            menu.addItem(item)
        }
    }

    private func renderDiscoveredDevicesSection() {
        let header = NSMenuItem(title: "Discovered Devices", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if discoveredPeers.isEmpty {
            let empty = NSMenuItem(title: "  Scanning\u{2026}", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }

        for peer in discoveredPeers {
            let item = NSMenuItem(
                title: peer.description,
                action: #selector(handleApproveDevice(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = peer.id.uuidString
            item.toolTip = "Click to trust this device"
            menu.addItem(item)
        }
    }

    // MARK: - Status dot

    private func makeStatusDot(color: NSColor) -> NSImage {
        let size = NSSize(width: 8, height: 8)
        let image = NSImage(size: size, flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: - Actions

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
