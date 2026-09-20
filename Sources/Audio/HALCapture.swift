import Cocoa
import AVFoundation
import CoreAudio
import Carbon.HIToolbox
import IOKit.hid

// MARK: - Direct AUHAL capture on a chosen device
// AVAudioEngine.inputNode instantiates its I/O unit on the DEFAULT input before any pin
// can be applied, and with AirPods that instant is enough to trip the A2DP→HFP switch
// (his report 2026-09-20: 0.5s dip on press even after pinning). Building the HAL output
// unit by hand lets CurrentDevice be set BEFORE AudioUnitInitialize, so the Bluetooth
// device is never touched at all.
final class HALCapture {
    private var unit: AudioUnit?
    private(set) var format: AVAudioFormat?
    private let handler: (AVAudioPCMBuffer) -> Void

    init?(device: InputDevice.Info, handler: @escaping (AVAudioPCMBuffer) -> Void) {
        self.handler = handler
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                             componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { wlog("HAL: no AUHAL component"); return nil }
        var u: AudioUnit?
        guard AudioComponentInstanceNew(comp, &u) == noErr, let unit = u else { wlog("HAL: instance FAILED"); return nil }
        self.unit = unit
        var on: UInt32 = 1, off: UInt32 = 0
        let sz = UInt32(MemoryLayout<UInt32>.size)
        // Input on element 1, output off on element 0 — order matters: EnableIO before CurrentDevice.
        guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, sz) == noErr,
              AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, sz) == noErr
        else { wlog("HAL: EnableIO FAILED"); dispose(); return nil }
        var dev = device.id
        guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                   &dev, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr
        else { wlog("HAL: CurrentDevice '\(device.name)' FAILED"); dispose(); return nil }
        // Hardware format (input scope of element 1) → ask for float32 deinterleaved at the
        // same rate/channels on the output side of the input element.
        var hw = AudioStreamBasicDescription(); var hsz = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hw, &hsz) == noErr,
              hw.mSampleRate > 0,
              let fmt = AVAudioFormat(standardFormatWithSampleRate: hw.mSampleRate, channels: max(1, hw.mChannelsPerFrame))
        else { wlog("HAL: hardware format unreadable"); dispose(); return nil }
        var client = fmt.streamDescription.pointee
        guard AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client,
                                   UInt32(MemoryLayout<AudioStreamBasicDescription>.size)) == noErr
        else { wlog("HAL: client format FAILED"); dispose(); return nil }
        format = fmt
        var cb = AURenderCallbackStruct(inputProc: { refCon, flags, ts, bus, frames, _ in
            let me = Unmanaged<HALCapture>.fromOpaque(refCon).takeUnretainedValue()
            return me.render(flags: flags, ts: ts, bus: bus, frames: frames)
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                                   &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)) == noErr
        else { wlog("HAL: callback FAILED"); dispose(); return nil }
        guard AudioUnitInitialize(unit) == noErr else { wlog("HAL: initialize FAILED"); dispose(); return nil }
        wlog("HAL capture on '\(device.name)' sr=\(fmt.sampleRate) ch=\(fmt.channelCount)")
    }

    private func render(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, ts: UnsafePointer<AudioTimeStamp>,
                        bus: UInt32, frames: UInt32) -> OSStatus {
        guard let unit, let fmt = format, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return noErr }
        buf.frameLength = frames
        let st = AudioUnitRender(unit, flags, ts, bus, frames, buf.mutableAudioBufferList)
        if st == noErr { handler(buf) }
        return st
    }

    func start() -> Bool {
        guard let unit else { return false }
        let st = AudioOutputUnitStart(unit)
        if st != noErr { wlog("HAL: start FAILED \(st)") }
        return st == noErr
    }
    func stop() {
        guard let unit else { return }
        AudioOutputUnitStop(unit); AudioUnitUninitialize(unit); dispose()
    }
    private func dispose() {
        if let u = unit { AudioComponentInstanceDispose(u); unit = nil }
    }
    deinit { stop() }
}
