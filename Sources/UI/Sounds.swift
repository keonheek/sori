import Cocoa
import AVFoundation
import CoreAudio
import Carbon.HIToolbox
import IOKit.hid

// MARK: - Sounds (clean-room generated pop/blip in ~/.sori-sounds)
final class Sounds {
    // Off the main thread: with AirPods connected and idle, NSSound.play() wakes the Bluetooth
    // output link and blocked the event-tap callback for 360–460 ms per press (his "the first
    // press doesn't feel snappy", 2026-09-21). The indicator and the mic now start immediately.
    private static let q = DispatchQueue(label: "sori.sounds", qos: .userInteractive)
    private static var cache: [String: NSSound] = [:]
    static func play(_ name: String) {
        q.async {
            let s: NSSound
            if let c = cache[name] { s = c }
            else {
                let p = (NSHomeDirectory() as NSString).appendingPathComponent(".sori-sounds/\(name).wav")
                guard let loaded = NSSound(contentsOfFile: p, byReference: true) else { return }
                cache[name] = loaded; s = loaded
            }
            if s.isPlaying { s.stop() }
            s.play()
        }
    }
}
