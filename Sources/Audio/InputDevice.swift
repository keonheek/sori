import Cocoa
import AVFoundation
import CoreAudio
import Carbon.HIToolbox
import IOKit.hid

// MARK: - Input device selection
// Which CoreAudio device should capture. Returns nil when the system default is fine
// (leave AVAudioEngine alone). Returns the built-in mic when the default input is
// Bluetooth and avoidBluetoothMic is on, so AirPods stay on A2DP and never pause.
enum InputDevice {
    struct Info { let id: AudioDeviceID; let name: String; let transport: UInt32 }

    private static func prop(_ sel: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    private static func u32(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> UInt32? {
        var a = prop(sel); var v: UInt32 = 0; var sz = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(obj, &a, 0, nil, &sz, &v) == noErr ? v : nil
    }
    private static func name(_ dev: AudioDeviceID) -> String {
        var a = prop(kAudioObjectPropertyName); var v: CFString = "" as CFString
        var sz = UInt32(MemoryLayout<CFString>.size)
        let st = withUnsafeMutablePointer(to: &v) { AudioObjectGetPropertyData(dev, &a, 0, nil, &sz, $0) }
        return st == noErr ? (v as String) : "device \(dev)"
    }
    private static func inputChannels(_ dev: AudioDeviceID) -> Int {
        var a = prop(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
        var sz: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &a, 0, nil, &sz) == noErr, sz > 0 else { return 0 }
        let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(sz), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buf.deallocate() }
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &sz, buf) == noErr else { return 0 }
        let abl = UnsafeMutableAudioBufferListPointer(buf.assumingMemoryBound(to: AudioBufferList.self))
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
    static func info(_ dev: AudioDeviceID) -> Info {
        Info(id: dev, name: name(dev), transport: u32(dev, kAudioDevicePropertyTransportType) ?? 0)
    }
    static func isBluetooth(_ t: UInt32) -> Bool {
        t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE
    }
    static func systemDefault() -> Info? {
        guard let id = u32(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice), id != 0 else { return nil }
        return info(id)
    }
    static func builtInMic() -> Info? {
        var a = prop(kAudioHardwarePropertyDevices); var sz: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz) == noErr else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(sz) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &ids) == noErr else { return nil }
        for id in ids where u32(id, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBuiltIn && inputChannels(id) > 0 {
            return info(id)
        }
        return nil
    }
    // The device the recorder should pin, or nil to use the default. Logs the decision.
    static func preferred(avoidBluetooth: Bool) -> Info? {
        let t0 = DispatchTime.now().uptimeNanoseconds
        guard avoidBluetooth, let def = systemDefault(), isBluetooth(def.transport) else { return nil }
        let t1 = DispatchTime.now().uptimeNanoseconds
        guard let mic = builtInMic() else {
            wlog("default input '\(def.name)' is Bluetooth but no built-in mic found — using it anyway"); return nil
        }
        let t2 = DispatchTime.now().uptimeNanoseconds
        // Timings: both queries were ~40ms until 2026-09-20 23:09 when they jumped to ~400ms
        // per press with AirPods idle-connected; the split says which CoreAudio call stalls.
        wlog("default input '\(def.name)' is Bluetooth — capturing from '\(mic.name)' so it stays on A2DP (default \((t1-t0)/1_000_000)ms, enumerate \((t2-t1)/1_000_000)ms)")
        return mic
    }
}
