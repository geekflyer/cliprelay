// Manages the macOS menu bar icon, status dot, and dropdown menu for peer management.

import AppKit
import Foundation
import QuartzCore
import Sparkle
import UserNotifications

final class StatusBarController {
    var onPairNewDeviceRequested: (() -> Void)?
    var onForgetDeviceRequested: ((String) -> Void)?
    var onToggleLaunchAtLogin: (() -> Void)?
    var isLaunchAtLoginEnabled: (() -> Bool)?
    var onToggleImageSync: (() -> Void)?
    var isImageSyncEnabled: (() -> Bool)?
    var isDeviceConnected: (() -> Bool)?
    var bleStateProvider: (() -> String)?
    var onShowNotificationFilters: (() -> Void)?

    /// Called by AppDelegate when a new Android notification is logged.
    func refreshMenu() { renderMenu() }

    private var availableUpdateVersion: String?

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let updaterController: SPUStandardUpdaterController

    private var connectedPeers: [PeerSummary] = []
    private var trustedPeers: [PeerSummary] = []
    private var bluetoothWarning: String?

    private static let brandAqua = NSColor(red: 0, green: 1, blue: 0.835, alpha: 1) // #00FFD5

    private lazy var connectedDot: NSImage = makeStatusDot(color: Self.brandAqua)
    private lazy var disconnectedDot: NSImage = makeStatusDot(color: .tertiaryLabelColor)

    private var baseStatusBarImage: NSImage?
    private var syncPulseTimer: Timer?

    init(updaterController: SPUStandardUpdaterController) {
        self.updaterController = updaterController
        baseStatusBarImage = loadStatusBarIcon()
        updateStatusBarIcon()
        renderMenu()
    }

    private func loadStatusBarIcon() -> NSImage? {
        // NSImage(named:) searches the bundle by name regardless of extension
        // (Xcode converts PNG → TIFF at build time, so path-based .png lookup fails)
        if let image = NSImage(named: "StatusBarIcon") {
            image.size = NSSize(width: 18, height: 18)
            return image
        }
        // Fallback: explicit path search for png or tiff
        for ext in ["tiff", "png"] {
            for dir in [Optional<String>.none, "Resources"] {
                if let path = Bundle.main.path(forResource: "StatusBarIcon", ofType: ext, inDirectory: dir) {
                    let image = NSImage(contentsOfFile: path)
                    image?.size = NSSize(width: 18, height: 18)
                    return image
                }
            }
        }
        return nil
    }

    private func updateStatusBarIcon() {
        guard let button = statusItem.button else { return }
        guard let base = baseStatusBarImage else {
            button.title = "GP"
            return
        }
        if !connectedPeers.isEmpty {
            let aqua = base.colorized(with: Self.brandAqua)
            aqua.isTemplate = false
            button.image = aqua
        } else {
            let template = base.copy() as! NSImage
            template.isTemplate = true
            button.image = template
        }
    }

    func setConnectedPeers(_ peers: [PeerSummary]) {
        connectedPeers = peers
        updateStatusBarIcon()
        renderMenu()
    }

    func setTrustedPeers(_ peers: [PeerSummary]) {
        trustedPeers = peers
        renderMenu()
    }

    func setBluetoothWarning(_ warning: String?) {
        bluetoothWarning = warning
        renderMenu()
    }


    /// Briefly pulses the status bar icon to indicate a clipboard sync.
    func flashSyncIndicator() {
        guard let button = statusItem.button, let base = baseStatusBarImage else { return }

        // Cancel any in-progress pulse
        syncPulseTimer?.invalidate()

        // Show bright highlight icon
        let highlight = base.colorized(with: .systemYellow)
        highlight.isTemplate = false
        button.image = highlight

        // Enable layer-backed view for Core Animation
        button.wantsLayer = true
        if let layer = button.layer {
            let pulse = CAKeyframeAnimation(keyPath: "transform.scale")
            pulse.values = [1.0, 1.3, 1.0]
            pulse.keyTimes = [0, 0.4, 1.0]
            pulse.duration = 0.35
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(pulse, forKey: "syncPulse")
        }

        // Restore normal icon after the animation completes
        syncPulseTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            self?.updateStatusBarIcon()
        }
    }

    // MARK: - Menu rendering

    func setAvailableUpdateVersion(_ version: String?) {
        availableUpdateVersion = version
        renderMenu()
    }

    private func renderMenu() {
        menu.removeAllItems()

        if let bluetoothWarning {
            let warningItem = NSMenuItem(title: bluetoothWarning, action: nil, keyEquivalent: "")
            warningItem.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "warning")
            warningItem.isEnabled = false
            menu.addItem(warningItem)
            menu.addItem(NSMenuItem.separator())
        }

        renderTrustedDevicesSection()
        menu.addItem(NSMenuItem.separator())

        let pairItem = NSMenuItem(
            title: "Pair New Device\u{2026}",
            action: #selector(handlePairNewDevice),
            keyEquivalent: "n"
        )
        pairItem.target = self
        menu.addItem(pairItem)

        menu.addItem(NSMenuItem.separator())

        let testNotifItem = NSMenuItem(
            title: "Send Test Notification",
            action: #selector(handleTestNotification),
            keyEquivalent: ""
        )
        testNotifItem.target = self
        menu.addItem(testNotifItem)

        let filterItem = NSMenuItem(
            title: "Notification Filters\u{2026}",
            action: #selector(handleNotificationFilters),
            keyEquivalent: ""
        )
        filterItem.target = self
        menu.addItem(filterItem)

        menu.addItem(NSMenuItem.separator())
        renderRecentNotificationsSection()
        renderBlockedAppsSection()

        let launchItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(handleToggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchItem.target = self
        if isLaunchAtLoginEnabled?() == true {
            launchItem.state = .on
        }
        menu.addItem(launchItem)

        let deviceConnected = isDeviceConnected?() ?? false
        let imageSyncItem = NSMenuItem(
            title: "Image Sync (experimental)",
            action: deviceConnected ? #selector(handleToggleImageSync) : nil,
            keyEquivalent: ""
        )
        imageSyncItem.target = self
        if !deviceConnected {
            imageSyncItem.isEnabled = false
        } else if isImageSyncEnabled?() == true {
            imageSyncItem.state = .on
        }
        menu.addItem(imageSyncItem)

        menu.addItem(NSMenuItem.separator())

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let versionItem = NSMenuItem(title: "ClipRelay v\(version)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        let websiteItem = NSMenuItem(
            title: "Visit Website\u{2026}",
            action: #selector(handleVisitWebsite),
            keyEquivalent: ""
        )
        websiteItem.target = self
        menu.addItem(websiteItem)

        let supportItem = NSMenuItem(title: "Feedback & Support", action: nil, keyEquivalent: "")
        let supportMenu = NSMenu()
        let issueItem = NSMenuItem(title: "Report Issue on GitHub\u{2026}", action: #selector(handleOpenGitHubIssue), keyEquivalent: "")
        issueItem.target = self
        supportMenu.addItem(issueItem)
        let emailItem = NSMenuItem(title: "Email Support\u{2026}", action: #selector(handleOpenEmail), keyEquivalent: "")
        emailItem.target = self
        supportMenu.addItem(emailItem)
        supportMenu.addItem(NSMenuItem.separator())
        let discussionsItem = NSMenuItem(title: "Community Discussions\u{2026}", action: #selector(handleOpenDiscussions), keyEquivalent: "")
        discussionsItem.target = self
        supportMenu.addItem(discussionsItem)
        supportItem.submenu = supportMenu
        menu.addItem(supportItem)

        let updateTitle: String
        if let version = availableUpdateVersion {
            updateTitle = "Update Available (\(version))"
        } else {
            updateTitle = "Check for Updates\u{2026}"
        }
        let checkForUpdatesItem = NSMenuItem(title: updateTitle, action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        checkForUpdatesItem.target = updaterController
        menu.addItem(checkForUpdatesItem)

        let autoUpdateItem = NSMenuItem(
            title: "Automatically Check for Updates",
            action: #selector(handleToggleAutoUpdates),
            keyEquivalent: ""
        )
        autoUpdateItem.target = self
        if updaterController.updater.automaticallyChecksForUpdates {
            autoUpdateItem.state = .on
        }
        menu.addItem(autoUpdateItem)

        let betaItem = NSMenuItem(
            title: "Beta Channel",
            action: #selector(handleToggleBetaUpdates),
            keyEquivalent: ""
        )
        betaItem.target = self
        if isBetaChannelEnabled {
            betaItem.state = .on
        }
        menu.addItem(betaItem)

        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(
            title: "Quit ClipRelay",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))

        statusItem.menu = menu
    }

    // MARK: - Recent notifications section

    private func renderRecentNotificationsSection() {
        let header = NSMenuItem(title: "Recent Notifications", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let records = NotificationLog.shared.records
        if records.isEmpty {
            let empty = NSMenuItem(title: "  No notifications yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for record in records {
                // Compose display title: "AppName — Notification title"
                let displayTitle = composeNotifTitle(appName: record.appName, title: record.title)
                let item = NSMenuItem(title: displayTitle, action: nil, keyEquivalent: "")

                let sub = NSMenu()

                // Block app
                let blockItem = NSMenuItem(
                    title: "Block \(record.appName)",
                    action: #selector(handleBlockApp(_:)),
                    keyEquivalent: ""
                )
                blockItem.target = self
                blockItem.representedObject = record.appName
                sub.addItem(blockItem)

                sub.addItem(NSMenuItem.separator())

                // Copy notification body
                let copyItem = NSMenuItem(
                    title: "Copy Text",
                    action: #selector(handleCopyNotification(_:)),
                    keyEquivalent: ""
                )
                copyItem.target = self
                copyItem.representedObject = record.body.isEmpty ? record.title : "\(record.title)\n\(record.body)"
                sub.addItem(copyItem)

                item.submenu = sub
                menu.addItem(item)
            }

            let clearItem = NSMenuItem(
                title: "Clear History",
                action: #selector(handleClearNotificationHistory),
                keyEquivalent: ""
            )
            clearItem.target = self
            menu.addItem(clearItem)
        }

        menu.addItem(NSMenuItem.separator())
    }

    // MARK: - Blocked apps section

    private func renderBlockedAppsSection() {
        let blocked = NotificationFilterStore.shared.blockedApps
        guard !blocked.isEmpty else { return }

        let header = NSMenuItem(title: "Blocked Apps", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        for appName in blocked {
            let item = NSMenuItem(title: "  \(appName)", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            let unblockItem = NSMenuItem(
                title: "Unblock \(appName)",
                action: #selector(handleUnblockApp(_:)),
                keyEquivalent: ""
            )
            unblockItem.target = self
            unblockItem.representedObject = appName
            sub.addItem(unblockItem)
            item.submenu = sub
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())
    }

    private func composeNotifTitle(appName: String, title: String) -> String {
        let combined = title.isEmpty ? appName : "\(appName) — \(title)"
        let limit = 55
        if combined.count > limit {
            return String(combined.prefix(limit)) + "…"
        }
        return combined
    }

    // MARK: - Block / unblock actions

    @objc private func handleBlockApp(_ sender: NSMenuItem) {
        guard let appName = sender.representedObject as? String else { return }
        // Switch to blocklist mode if currently off
        if NotificationFilterStore.shared.filterMode == .off {
            NotificationFilterStore.shared.filterMode = .blocklist
        }
        if NotificationFilterStore.shared.filterMode == .blocklist {
            var list = NotificationFilterStore.shared.blockedApps
            if !list.contains(where: { $0.lowercased() == appName.lowercased() }) {
                list.append(appName)
                NotificationFilterStore.shared.blockedApps = list
            }
        }
        renderMenu()
    }

    @objc private func handleUnblockApp(_ sender: NSMenuItem) {
        guard let appName = sender.representedObject as? String else { return }
        var list = NotificationFilterStore.shared.blockedApps
        list.removeAll { $0.lowercased() == appName.lowercased() }
        NotificationFilterStore.shared.blockedApps = list
        renderMenu()
    }

    @objc private func handleCopyNotification(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func handleClearNotificationHistory() {
        NotificationLog.shared.clear()
        renderMenu()
    }

    private func renderTrustedDevicesSection() {
        let header = NSMenuItem(title: "Paired Devices", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if trustedPeers.isEmpty {
            let empty = NSMenuItem(title: "  No paired devices", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }

        let connectedIDs = Set(connectedPeers.map(\.id))

        for peer in trustedPeers {
            let isConnected = connectedIDs.contains(peer.id)

            let title: String
            if let tag = peer.deviceTagHex {
                title = "\(peer.description)  [Pairing: \(tag)]"
            } else {
                title = peer.description
            }
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.image = isConnected ? connectedDot : disconnectedDot
            item.isEnabled = true

            let submenu = NSMenu()
            let forgetItem = NSMenuItem(
                title: "Forget Device",
                action: #selector(handleForgetDevice(_:)),
                keyEquivalent: ""
            )
            forgetItem.target = self
            forgetItem.representedObject = peer.secret
            submenu.addItem(forgetItem)

            item.submenu = submenu
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
    private func handlePairNewDevice() {
        onPairNewDeviceRequested?()
    }

    @objc
    private func handleToggleLaunchAtLogin() {
        onToggleLaunchAtLogin?()
        renderMenu()
    }

    @objc
    private func handleToggleImageSync() {
        onToggleImageSync?()
        renderMenu()
    }

    @objc
    private func handleVisitWebsite() {
        if let url = URL(string: "https://cliprelay.org") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc
    private func handleOpenGitHubIssue() {
        let context = deviceContext()
        let body = "\n\n---\n" + context.map { "- **\($0.0):** \($0.1)" }.joined(separator: "\n")
        var components = URLComponents(string: "https://github.com/geekflyer/cliprelay/issues/new")!
        components.queryItems = [
            URLQueryItem(name: "body", value: body),
            URLQueryItem(name: "labels", value: "from-app"),
        ]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }

    @objc
    private func handleOpenEmail() {
        let context = deviceContext()
        let body = "\n\n---\n" + context.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
        var components = URLComponents(string: "mailto:info@cliprelay.org")!
        components.queryItems = [
            URLQueryItem(name: "subject", value: "ClipRelay Feedback"),
            URLQueryItem(name: "body", value: body),
        ]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }

    @objc
    private func handleOpenDiscussions() {
        if let url = URL(string: "https://github.com/geekflyer/cliprelay/discussions") {
            NSWorkspace.shared.open(url)
        }
    }

    private func deviceContext() -> [(String, String)] {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let gitHash = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osString = "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        var model = "Unknown Mac"
        var size: Int = 0
        if sysctlbyname("hw.model", nil, &size, nil, 0) == 0 {
            var machine = [CChar](repeating: 0, count: size)
            if sysctlbyname("hw.model", &machine, &size, nil, 0) == 0 {
                model = String(cString: machine)
            }
        }
        let bleState = bleStateProvider?() ?? "unknown"
        return [
            ("App Version", "\(version) (\(gitHash))"),
            ("OS", osString),
            ("Device", model),
            ("BLE State", bleState),
        ]
    }

    @objc
    private func handleToggleAutoUpdates() {
        updaterController.updater.automaticallyChecksForUpdates.toggle()
        renderMenu()
    }

    private var isBetaChannelEnabled: Bool {
        let channels = UserDefaults.standard.stringArray(forKey: "SUDefaultChannels") ?? []
        return channels.contains("beta")
    }

    @objc
    private func handleToggleBetaUpdates() {
        var channels = UserDefaults.standard.stringArray(forKey: "SUDefaultChannels") ?? []
        if isBetaChannelEnabled {
            channels.removeAll { $0 == "beta" }
        } else {
            channels.append("beta")
        }
        if channels.isEmpty {
            UserDefaults.standard.removeObject(forKey: "SUDefaultChannels")
        } else {
            UserDefaults.standard.set(channels, forKey: "SUDefaultChannels")
        }
        renderMenu()
    }

    @objc
    private func handleForgetDevice(_ sender: NSMenuItem) {
        guard let token = sender.representedObject as? String else { return }
        onForgetDeviceRequested?(token)
    }

    @objc
    private func handleNotificationFilters() {
        onShowNotificationFilters?()
    }

    @objc
    private func handleTestNotification() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            DispatchQueue.main.async {
                if let error {
                    let alert = NSAlert()
                    alert.messageText = "Notification permission error"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                    return
                }
                if granted {
                    let content = UNMutableNotificationContent()
                    content.title = "NotiSync Test"
                    content.body = "Notifications are working! Android notifications will appear here."
                    content.sound = .default
                    let request = UNNotificationRequest(identifier: "test-\(Date().timeIntervalSince1970)", content: content, trigger: nil)
                    UNUserNotificationCenter.current().add(request)
                } else {
                    let alert = NSAlert()
                    alert.messageText = "Notifications denied"
                    alert.informativeText = "Please enable notifications for NotiSync in System Settings → Notifications."
                    alert.runModal()
                }
            }
        }
    }
}

// MARK: - NSImage tinting

private extension NSImage {
    /// Returns a copy of the image with every opaque pixel replaced by `color`.
    func colorized(with color: NSColor) -> NSImage {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return self
        }
        return NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setFillColor(color.cgColor)
            ctx.fill(rect)
            ctx.setBlendMode(.destinationIn)
            ctx.draw(cgImage, in: rect)
            return true
        }
    }
}
