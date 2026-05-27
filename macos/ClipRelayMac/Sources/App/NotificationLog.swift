// Keeps a rolling in-memory + persisted log of the last N Android notifications
// that passed the filter and were posted to Notification Centre.

import Foundation

struct NotificationRecord: Codable {
    let appName: String
    let title: String
    let body: String
    let time: TimeInterval   // Date().timeIntervalSince1970
}

final class NotificationLog {
    static let shared = NotificationLog()

    private let maxCount   = 15
    private let defaultsKey = "notiLogRecords"

    /// Most-recent-first list of forwarded notifications.
    private(set) var records: [NotificationRecord] = []

    private init() { load() }

    // MARK: - Mutating

    func append(appName: String, title: String, body: String) {
        let r = NotificationRecord(
            appName: appName,
            title: title,
            body: body,
            time: Date().timeIntervalSince1970
        )
        records.insert(r, at: 0)
        if records.count > maxCount {
            records = Array(records.prefix(maxCount))
        }
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
