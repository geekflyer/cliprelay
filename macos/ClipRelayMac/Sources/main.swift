import AppKit

if let exitCode = SmokeAutomationCLI.runIfRequested(arguments: CommandLine.arguments) {
    exit(exitCode)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
