import Cocoa
import AVFoundation
import CoreAudio
import Carbon.HIToolbox
import IOKit.hid

// MARK: - Login item (auto-launch) via launchd plist
enum LoginItem {
    static var plistPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/LaunchAgents/dev.sori.app.plist")
    }
    static func isEnabled() -> Bool { FileManager.default.fileExists(atPath: plistPath) }
    static func set(enabled: Bool) {
        if enabled {
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
              <key>Label</key><string>dev.sori.app</string>
              <key>ProgramArguments</key>
              <array><string>/Applications/Sori.app/Contents/MacOS/Sori</string></array>
              <key>RunAtLoad</key><true/>
            </dict></plist>
            """
            let dir = (NSHomeDirectory() as NSString).appendingPathComponent("Library/LaunchAgents")
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? plist.write(toFile: plistPath, atomically: true, encoding: .utf8)
            wlog("login item ENABLED")
        } else {
            try? FileManager.default.removeItem(atPath: plistPath)
            wlog("login item DISABLED")
        }
    }
}
