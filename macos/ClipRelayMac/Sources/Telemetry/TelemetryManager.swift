// Sends periodic heartbeats with app state for anonymous usage insights.

import Foundation
import os

private let logger = Logger(subsystem: "org.cliprelay", category: "Telemetry")

final class TelemetryManager {
    enum HeartbeatState: String {
        case noPeering = "no_peering"
        case idlePeering = "idle_peering"
        case activePeering = "active_peering"
    }

    private let stateProvider: () -> HeartbeatState
    private let installId: String
    private var timer: Timer?

    private static let checkinURL = URL(string: "https://updates.cliprelay.org/v1/checkin")!
    private static let keychainAccount = "telemetry_install_id"

    init(stateProvider: @escaping () -> HeartbeatState) {
        self.stateProvider = stateProvider
        self.installId = Self.resolveInstallId()
    }

    func start() {
        let startupDelay = Double.random(in: 30...90)
        logger.notice("[Telemetry] Scheduling first check-in in \(Int(startupDelay))s")

        let t = Timer(timeInterval: startupDelay, repeats: false) { [weak self] _ in
            self?.sendHeartbeat()
            self?.scheduleRecurring()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Private

    private func scheduleRecurring() {
        let jitter = Double.random(in: -300...300)
        let interval = 3600.0 + jitter

        let t = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            self?.sendHeartbeat()
            self?.scheduleRecurring()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func sendHeartbeat() {
        let state = stateProvider()
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let osVersionString = "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let appBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"

        let payload: [String: String] = [
            "installId": installId,
            "sentAt": ISO8601DateFormatter().string(from: Date()),
            "appVersion": appVersion,
            "appBuild": appBuild,
            "platform": "macos",
            "osVersion": osVersionString,
            "state": state.rawValue,
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

        var request = URLRequest(url: Self.checkinURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error {
                logger.debug("[Telemetry] Check-in failed: \(error.localizedDescription)")
            } else if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                logger.debug("[Telemetry] Check-in sent (state: \(state.rawValue))")
            } else {
                logger.debug("[Telemetry] Check-in returned unexpected status")
            }
        }.resume()
    }

    private static func resolveInstallId() -> String {
        let store = KeychainStore(service: "org.cliprelay")
        if let existing = store.data(for: keychainAccount),
           let id = String(data: existing, encoding: .utf8), !id.isEmpty {
            return id
        }
        let newId = UUID().uuidString
        if let data = newId.data(using: .utf8) {
            store.setData(data, for: keychainAccount)
        }
        logger.notice("[Telemetry] Generated new install ID")
        return newId
    }
}
