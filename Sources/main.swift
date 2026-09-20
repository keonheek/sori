import Cocoa
import AVFoundation
import CoreAudio
import Carbon.HIToolbox
import IOKit.hid

// Handled before NSApplication exists, and before the single-instance lock: these are
// terminal commands, not a second copy of the app, and must work while Sori is running.
if CommandLine.arguments.contains("--version") { print("Sori \(soriVersion)"); exit(0) }
if CommandLine.arguments.contains("--check-update") { Updater.runCLICheck() }
// Store maintenance, run while the app is up (the store is multi-process safe: WAL + full mutex).
if let i = CommandLine.arguments.firstIndex(of: "--import-log"), i + 1 < CommandLine.arguments.count {
    let n = LogImport.run(path: CommandLine.arguments[i + 1]); print("imported \(n) dictations"); exit(0)
}
// Headless Hub render for review: never orders a window front, no dock icon, exits when written.
if let i = CommandLine.arguments.firstIndex(of: "--hub-snapshot"), i + 1 < CommandLine.arguments.count {
    let snapApp = NSApplication.shared
    snapApp.setActivationPolicy(.prohibited)
    let ok = MainActor.assumeIsolated { HubController.snapshot(to: CommandLine.arguments[i + 1]) }
    print(ok ? "wrote \(CommandLine.arguments[i + 1])" : "snapshot FAILED"); exit(ok ? 0 : 1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
