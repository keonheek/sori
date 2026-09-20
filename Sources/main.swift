import Cocoa
import AVFoundation
import CoreAudio
import Carbon.HIToolbox
import IOKit.hid

// Handled before NSApplication exists, and before the single-instance lock: these are
// terminal commands, not a second copy of the app, and must work while Sori is running.
if CommandLine.arguments.contains("--version") { print("Sori \(soriVersion)"); exit(0) }
if CommandLine.arguments.contains("--check-update") { Updater.runCLICheck() }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
