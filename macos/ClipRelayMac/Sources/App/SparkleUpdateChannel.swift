// Sparkle feed selection: stable production appcast vs beta integration appcast.

import Foundation
import Sparkle

enum SparkleUpdateChannel {
    static let prefersBetaDefaultsKey = "ClipRelaySparklePrefersBetaUpdates"

    static var prefersBeta: Bool {
        get { UserDefaults.standard.bool(forKey: prefersBetaDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: prefersBetaDefaultsKey) }
    }

    /// Resolved HTTPS appcast URL for the current preference.
    static func resolvedFeedURLString() -> String {
        let stable = Bundle.main.object(forInfoDictionaryKey: "ClipRelaySparkleFeedStable") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        let beta = Bundle.main.object(forInfoDictionaryKey: "ClipRelaySparkleFeedBeta") as? String
        let fallbackStable = stable ?? "https://updates.cliprelay.org/appcast.xml"
        let fallbackBeta = beta ?? "https://updates.cliprelay.org/appcast-beta.xml"
        return prefersBeta ? fallbackBeta : fallbackStable
    }
}

/// Supplies `feedURLStringForUpdater:` without capturing `AppDelegate` before `super.init()`.
final class ClipRelaySparkleUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        SparkleUpdateChannel.resolvedFeedURLString()
    }
}
