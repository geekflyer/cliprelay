// App entry point: single-instance guard, smoke-test CLI dispatch, and NSApplication bootstrap.

import AppKit
import os

private let bootstrapLogger = Logger(subsystem: "com.cliprelay", category: "Bootstrap")

private func hasAnotherRunningInstance() -> Bool {
    guard let bundleID = Bundle.main.bundleIdentifier else { return false }
    let currentPID = ProcessInfo.processInfo.processIdentifier
    return NSRunningApplication
        .runningApplications(withBundleIdentifier: bundleID)
        .contains { $0.processIdentifier != currentPID }
}

if let exitCode = SmokeAutomationCLI.runIfRequested(arguments: CommandLine.arguments) {
    exit(exitCode)
}

if hasAnotherRunningInstance() {
    bootstrapLogger.error("Another ClipRelay instance detected; refusing secondary launch")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
