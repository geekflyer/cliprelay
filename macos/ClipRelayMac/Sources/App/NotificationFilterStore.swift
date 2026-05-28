// Persists notification filter settings and evaluates whether a notification should be shown.

import Foundation

enum NotificationFilterMode: String, CaseIterable {
    /// Pass all Android notifications through — no filtering.
    case off = "off"
    /// Block notifications from apps on the list; show everything else.
    case blocklist = "blocklist"
    /// Only show notifications from apps on the list; block everything else.
    case allowlist = "allowlist"

    var displayName: String {
        switch self {
        case .off:       return "Off"
        case .blocklist: return "Block Selected"
        case .allowlist: return "Allow Only"
        }
    }
}

/// Singleton that stores filter settings in UserDefaults and decides whether
/// a given Android notification should be forwarded to the Mac notification centre.
final class NotificationFilterStore {
    static let shared = NotificationFilterStore()
    private init() {}

    private let defaults = UserDefaults.standard
    private let modeKey            = "notiFilterMode"
    private let blockedAppsKey     = "notiFilterBlockedApps"
    private let allowedAppsKey     = "notiFilterAllowedApps"
    private let blockedKeywordsKey = "notiFilterBlockedKeywords"

    var filterMode: NotificationFilterMode {
        get { NotificationFilterMode(rawValue: defaults.string(forKey: modeKey) ?? "") ?? .off }
        set { defaults.set(newValue.rawValue, forKey: modeKey) }
    }

    /// App names to hide (used in blocklist mode). Stored sorted; duplicates ignored.
    var blockedApps: [String] {
        get { (defaults.stringArray(forKey: blockedAppsKey) ?? []).sorted() }
        set { defaults.set(newValue.sorted(), forKey: blockedAppsKey) }
    }

    /// App names to show (used in allowlist mode). Stored sorted; duplicates ignored.
    var allowedApps: [String] {
        get { (defaults.stringArray(forKey: allowedAppsKey) ?? []).sorted() }
        set { defaults.set(newValue.sorted(), forKey: allowedAppsKey) }
    }

    /// Words / phrases that suppress a notification regardless of mode (unless Off).
    var blockedKeywords: [String] {
        get { (defaults.stringArray(forKey: blockedKeywordsKey) ?? []).sorted() }
        set { defaults.set(newValue.sorted(), forKey: blockedKeywordsKey) }
    }

    // MARK: - Filter logic

    /// Returns `true` if the notification should be posted to Notification Centre.
    func shouldShow(appName: String, title: String, body: String) -> Bool {
        // Keyword filter applies in blocklist and allowlist modes (not Off).
        if filterMode != .off {
            let combined = "\(title) \(body)".lowercased()
            for kw in blockedKeywords where !kw.isEmpty {
                if combined.contains(kw.lowercased()) { return false }
            }
        }

        switch filterMode {
        case .off:
            return true
        case .blocklist:
            let name = appName.lowercased()
            return !blockedApps.contains { $0.lowercased() == name }
        case .allowlist:
            // Empty allowlist means "nothing configured yet" → let everything through.
            guard !allowedApps.isEmpty else { return true }
            let name = appName.lowercased()
            return allowedApps.contains { $0.lowercased() == name }
        }
    }
}
