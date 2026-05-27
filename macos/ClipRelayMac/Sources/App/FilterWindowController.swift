// Settings panel for notification filters (by app name and keyword).

import AppKit

/// Controls the Notification Filters settings panel.
/// Show it by calling `showWindow()`. The window is a floating panel; clicking
/// its close button destroys the reference so it can be re-created later.
final class FilterWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private let store = NotificationFilterStore.shared

    // Apps tab
    private var appsSegment: NSSegmentedControl!
    private var appsDescLabel: NSTextField!
    private var appsScrollView: NSScrollView!
    private var appsTable: NSTableView!
    private var appsRemoveButton: NSButton!

    // Keywords tab
    private var kwScrollView: NSScrollView!
    private var kwTable: NSTableView!
    private var kwRemoveButton: NSButton!

    // Table helpers (kept alive by the controller)
    private lazy var appsHelper  = TableHelper(owner: self, kind: .apps)
    private lazy var kwHelper    = TableHelper(owner: self, kind: .keywords)

    // MARK: - Public API

    func showWindow() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        buildWindow()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        window = nil
    }

    // MARK: - Window construction

    private func buildWindow() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = "Notification Filters"
        w.center()
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.delegate = self

        // Tab view fills the window content area with a small margin.
        let tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false

        let appsTab = NSTabViewItem()
        appsTab.label = "Apps"
        appsTab.view = buildAppsTab()
        tabView.addTabViewItem(appsTab)

        let kwTab = NSTabViewItem()
        kwTab.label = "Keywords"
        kwTab.view = buildKeywordsTab()
        tabView.addTabViewItem(kwTab)

        let cv = w.contentView!
        cv.addSubview(tabView)
        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: cv.topAnchor, constant: 8),
            tabView.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 8),
            tabView.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -8),
            tabView.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -8),
        ])

        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }

    // MARK: - Apps tab

    private func buildAppsTab() -> NSView {
        // Mode selector row
        let modeLabel = NSTextField(labelWithString: "Filter mode:")
        modeLabel.font = .systemFont(ofSize: 13, weight: .medium)
        modeLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        appsSegment = NSSegmentedControl(
            labels: NotificationFilterMode.allCases.map { $0.displayName },
            trackingMode: .selectOne,
            target: self,
            action: #selector(modeChanged(_:))
        )
        appsSegment.selectedSegment = NotificationFilterMode.allCases.firstIndex(of: store.filterMode) ?? 0

        let modeRow = NSStackView(views: [modeLabel, appsSegment])
        modeRow.orientation = .horizontal
        modeRow.spacing = 8
        modeRow.alignment = .centerY

        // Description label
        appsDescLabel = NSTextField(wrappingLabelWithString: descriptionForMode(store.filterMode))
        appsDescLabel.font = .systemFont(ofSize: 11)
        appsDescLabel.textColor = .secondaryLabelColor

        // Table + scroll view
        let (sv, table) = makeTableView()
        appsScrollView = sv
        appsTable = table
        appsTable.dataSource = appsHelper
        appsTable.delegate   = appsHelper

        // Buttons
        let addBtn = NSButton(title: "+", target: self, action: #selector(addApp))
        addBtn.bezelStyle = .smallSquare
        appsRemoveButton = NSButton(title: "−", target: self, action: #selector(removeApp))
        appsRemoveButton.bezelStyle = .smallSquare
        let btnRow = NSStackView(views: [addBtn, appsRemoveButton])
        btnRow.orientation = .horizontal
        btnRow.spacing = 4

        // Outer vertical stack
        let stack = buildVerticalStack(views: [modeRow, appsDescLabel, appsScrollView, btnRow])
        appsScrollView.heightAnchor.constraint(equalToConstant: 160).isActive = true

        updateAppsUI()
        return stack
    }

    // MARK: - Keywords tab

    private func buildKeywordsTab() -> NSView {
        let label = NSTextField(wrappingLabelWithString:
            "Notifications whose title or body contains any of these words are always hidden " +
            "(applies in Block Selected and Allow Only modes).")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor

        let (sv, table) = makeTableView()
        kwScrollView = sv
        kwTable = table
        kwTable.dataSource = kwHelper
        kwTable.delegate   = kwHelper

        let addBtn = NSButton(title: "+", target: self, action: #selector(addKeyword))
        addBtn.bezelStyle = .smallSquare
        kwRemoveButton = NSButton(title: "−", target: self, action: #selector(removeKeyword))
        kwRemoveButton.bezelStyle = .smallSquare
        let btnRow = NSStackView(views: [addBtn, kwRemoveButton])
        btnRow.orientation = .horizontal
        btnRow.spacing = 4

        let stack = buildVerticalStack(views: [label, kwScrollView, btnRow])
        kwScrollView.heightAnchor.constraint(equalToConstant: 200).isActive = true
        return stack
    }

    // MARK: - Helpers

    /// Wraps `views` in a vertical NSStackView that fills its superview via Auto Layout.
    private func buildVerticalStack(views: [NSView]) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 12, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
        ])
        // Make scroll views inside the stack expand to fill available width.
        for v in views where v is NSScrollView {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        return container
    }

    private func makeTableView() -> (NSScrollView, NSTableView) {
        let col = NSTableColumn(identifier: .init("value"))
        col.title = ""
        col.isEditable = false

        let table = NSTableView()
        table.addTableColumn(col)
        table.headerView = nil
        table.usesAlternatingRowBackgroundColors = true
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        let sv = NSScrollView()
        sv.documentView = table
        sv.hasVerticalScroller = true
        sv.borderType = .bezelBorder

        return (sv, table)
    }

    private func descriptionForMode(_ mode: NotificationFilterMode) -> String {
        switch mode {
        case .off:
            return "All Android notifications are forwarded to this Mac."
        case .blocklist:
            return "Notifications from apps listed below are hidden; all others are shown."
        case .allowlist:
            return "Only notifications from apps listed below are shown; all others are hidden."
        }
    }

    private func updateAppsUI() {
        let mode = store.filterMode
        let showList = mode != .off
        appsScrollView.isHidden = !showList
        appsRemoveButton.isHidden = !showList
        appsDescLabel.stringValue = descriptionForMode(mode)
        appsTable.reloadData()
    }

    // MARK: - Actions

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        store.filterMode = NotificationFilterMode.allCases[sender.selectedSegment]
        updateAppsUI()
    }

    @objc private func addApp() {
        guard store.filterMode != .off else { return }
        let verb = store.filterMode == .blocklist ? "block" : "allow"
        promptForText(
            title: "Add App",
            message: "Enter the exact app name to \(verb):",
            placeholder: "e.g. WhatsApp"
        ) { [weak self] name in
            guard let self, !name.isEmpty else { return }
            if self.store.filterMode == .blocklist {
                var list = self.store.blockedApps
                if !list.contains(where: { $0.lowercased() == name.lowercased() }) {
                    list.append(name)
                    self.store.blockedApps = list
                }
            } else {
                var list = self.store.allowedApps
                if !list.contains(where: { $0.lowercased() == name.lowercased() }) {
                    list.append(name)
                    self.store.allowedApps = list
                }
            }
            self.appsTable.reloadData()
        }
    }

    @objc private func removeApp() {
        let row = appsTable.selectedRow
        guard row >= 0 else { return }
        if store.filterMode == .blocklist {
            var list = store.blockedApps
            guard row < list.count else { return }
            list.remove(at: row)
            store.blockedApps = list
        } else if store.filterMode == .allowlist {
            var list = store.allowedApps
            guard row < list.count else { return }
            list.remove(at: row)
            store.allowedApps = list
        }
        appsTable.reloadData()
    }

    @objc private func addKeyword() {
        promptForText(
            title: "Add Keyword",
            message: "Notifications containing this word or phrase will be hidden:",
            placeholder: "e.g. advertisement"
        ) { [weak self] kw in
            guard let self, !kw.isEmpty else { return }
            var list = self.store.blockedKeywords
            if !list.contains(where: { $0.lowercased() == kw.lowercased() }) {
                list.append(kw)
                self.store.blockedKeywords = list
            }
            self.kwTable.reloadData()
        }
    }

    @objc private func removeKeyword() {
        let row = kwTable.selectedRow
        guard row >= 0 else { return }
        var list = store.blockedKeywords
        guard row < list.count else { return }
        list.remove(at: row)
        store.blockedKeywords = list
        kwTable.reloadData()
    }

    private func promptForText(title: String, message: String, placeholder: String, completion: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        input.placeholderString = placeholder
        alert.accessoryView = input

        if let w = window {
            alert.beginSheetModal(for: w) { response in
                if response == .alertFirstButtonReturn {
                    completion(input.stringValue.trimmingCharacters(in: .whitespaces))
                }
            }
        } else {
            if alert.runModal() == .alertFirstButtonReturn {
                completion(input.stringValue.trimmingCharacters(in: .whitespaces))
            }
        }
    }

    // MARK: - Table data source / delegate

    private enum TableKind { case apps, keywords }

    private final class TableHelper: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var owner: FilterWindowController?
        let kind: TableKind

        init(owner: FilterWindowController, kind: TableKind) {
            self.owner = owner
            self.kind  = kind
        }

        private var items: [String] {
            guard let o = owner else { return [] }
            switch kind {
            case .keywords:
                return o.store.blockedKeywords
            case .apps:
                switch o.store.filterMode {
                case .off:       return []
                case .blocklist: return o.store.blockedApps
                case .allowlist: return o.store.allowedApps
                }
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { items.count }

        func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
            guard row < items.count else { return nil }
            return items[row]
        }
    }
}
