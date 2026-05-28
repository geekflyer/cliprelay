// Keeps a rolling in-memory + persisted log of the last N Android notifications
// that passed the filter and were posted to Notification Centre.

import Foundation

// MARK: - NotificationAction

/// A single tappable action surfaced by Android in the notification (Reply, Mark as read, etc.)
struct NotificationAction: Codable {
    let index: Int
    let title: String
    let hasReply: Bool  // true when the action accepts free-form text input (e.g. "Reply")
}

// MARK: - NotificationRecord

struct NotificationRecord: Codable {
    let appName: String
    let title: String
    let body: String
    let time: TimeInterval           // Date().timeIntervalSince1970
    let notificationKey: String      // opaque key for firing actions back to Android
    let actions: [NotificationAction]

    // Failable init so old persisted records without notificationKey/actions still decode
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appName         = try c.decode(String.self, forKey: .appName)
        title           = try c.decode(String.self, forKey: .title)
        body            = try c.decode(String.self, forKey: .body)
        time            = try c.decode(TimeInterval.self, forKey: .time)
        notificationKey = (try? c.decode(String.self, forKey: .notificationKey)) ?? ""
        actions         = (try? c.decode([NotificationAction].self, forKey: .actions)) ?? []
    }

    init(appName: String, title: String, body: String, time: TimeInterval,
         notificationKey: String, actions: [NotificationAction]) {
        self.appName         = appName
        self.title           = title
        self.body            = body
        self.time            = time
        self.notificationKey = notificationKey
        self.actions         = actions
    }
}

// MARK: - NotificationLog

final class NotificationLog {
    static let shared = NotificationLog()

    private let maxCount    = 15
    private let defaultsKey = "notiLogRecords"

    /// Most-recent-first list of forwarded notifications.
    private(set) var records: [NotificationRecord] = []

    private init() { load() }

    // MARK: - Mutating

    func append(appName: String, title: String, body: String,
                notificationKey: String = "", actions: [NotificationAction] = []) {
        let r = NotificationRecord(
            appName: appName,
            title: title,
            body: body,
            time: Date().timeIntervalSince1970,
            notificationKey: notificationKey,
            actions: actions
        )
        records.insert(r, at: 0)
        if records.count > maxCount {
            records = Array(records.prefix(maxCount))
        }
        save()
    }

    /// Remove a single notification by its timestamp (used for "Mark as Read").
    func remove(byTime time: TimeInterval) {
        records.removeAll { $0.time == time }
        save()
    }

    func clear() {
        records = []
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    // MARK: - Persistence

    private func load() {
        guard
            let data    = UserDefaults.standard.data(forKey: defaultsKey),
            let decoded = try? JSONDecoder().decode([NotificationRecord].self, from: data)
        else { return }
        records = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
