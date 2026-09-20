import Cocoa
import AVFoundation
import CoreAudio
import Carbon.HIToolbox
import IOKit.hid

// MARK: - Sounds (clean-room generated pop/blip in ~/.sori-sounds)
final class Sounds {
    static func play(_ name: String) {
        let p = (NSHomeDirectory() as NSString).appendingPathComponent(".sori-sounds/\(name).wav")
        if let s = NSSound(contentsOfFile: p, byReference: true) { s.play() }
    }
}
