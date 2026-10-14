import Cocoa
import AVFoundation
import CoreAudio
import Carbon.HIToolbox
import IOKit.hid

// MARK: - Logging
// All working files live in the per-user private temp dir (mode 0700), never
// world-writable /tmp — a fixed predictable /tmp path can be pre-planted as a
// symlink by any other process running as this user (CWE-59).
let soriWorkDir: String = {
    let d = (NSTemporaryDirectory() as NSString).appendingPathComponent("sori")
    try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    return d
}()
// macOS's temp cleaner purges $TMPDIR entries untouched for ~3 days, so this dir can
// vanish under a long-running app — recreate on demand, never trust the launch-time create.
@discardableResult
func ensureWorkDir() -> Bool {
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: soriWorkDir, isDirectory: &isDir), isDir.boolValue { return true }
    return (try? FileManager.default.createDirectory(atPath: soriWorkDir, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])) != nil
}
func workPath(_ name: String) -> String { (soriWorkDir as NSString).appendingPathComponent(name) }
// The log lives in ~/Library/Logs/Sori, NOT in the work dir: macOS's temp cleaner was
// purging it, so every incident older than ~3 days had no history (moved 2026-09-03).
// Rotated once past 2 MB into sori.log.1, which is overwritten on the next rotation.
let soriLogDir: String = {
    let d = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/Sori")
    try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}()
let logPath = (soriLogDir as NSString).appendingPathComponent("sori.log")
let logRotateBytes: UInt64 = 2_000_000
let wlogDF: DateFormatter = {
    let d = DateFormatter(); d.dateFormat = "MM-dd HH:mm:ss.SSS"; return d
}()
let wlogLock = NSLock()
let wlogToStderr = ProcessInfo.processInfo.environment["SORI_LOG_STDERR"] == "1"
func wlog(_ msg: String) {
    let line = wlogDF.string(from: Date()) + " " + msg + "\n"
    guard let data = line.data(using: .utf8) else { return }
    // CLI probes and benches log to stderr so they never interleave with the live app's log.
    if wlogToStderr { FileHandle.standardError.write(data); return }
    wlogLock.lock(); defer { wlogLock.unlock() }
    if let size = (try? FileManager.default.attributesOfItem(atPath: logPath))?[.size] as? UInt64,
       size > logRotateBytes {
        let prev = logPath + ".1"
        try? FileManager.default.removeItem(atPath: prev)
        try? FileManager.default.moveItem(atPath: logPath, toPath: prev)
    }
    if FileManager.default.fileExists(atPath: logPath),
       let fh = try? FileHandle(forWritingTo: URL(fileURLWithPath: logPath)) {
        fh.seekToEndOfFile(); fh.write(data); try? fh.close()
    } else {
        try? FileManager.default.createDirectory(atPath: soriLogDir, withIntermediateDirectories: true)
        try? line.write(toFile: logPath, atomically: true, encoding: .utf8)
    }
}

// Homebrew's prefix differs by architecture: /opt/homebrew on Apple Silicon,
// /usr/local on Intel. Resolve once per call; hardcoding the Apple Silicon
// path crashed Intel Macs (Process.launch throws ObjC on a missing binary).
func whisperTool(_ name: String) -> String {
    for p in ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"] {
        if FileManager.default.fileExists(atPath: p) { return p }
    }
    return "/opt/homebrew/bin/\(name)"
}
