import Cocoa
import AVFoundation
import CoreAudio
import Carbon.HIToolbox
import IOKit.hid

// MARK: - Recorder (16k mono PCM, live level metering)
class AudioRecorder {
    // A FRESH engine per recording — never a long-lived one. 2026-08-10: unplugging the
    // earphone mid-recording made CoreAudio stop the engine behind the app's back; stop()
    // gated removeTap on engine.isRunning, so the tap leaked on the shared engine and every
    // later installTap raised "CreateRecordingTap: (nullptr == Tap())" — an ObjC exception
    // AppKit's run-loop catcher swallows, so dictation went silently dead until relaunch.
    private var engine: AVAudioEngine?
    private var configObserver: NSObjectProtocol?
    var avoidBluetoothMic = true   // set from Config before start()
    private var hal: HALCapture?      // pinned-device path; engine stays nil while this is live
    private var audioFile: AVAudioFile?
    private var converter: AVAudioConverter?
    private let outputURL = URL(fileURLWithPath: workPath("sori.wav"))
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                             sampleRate: 16000, channels: 1, interleaved: true)!
    var onLevel: ((Float) -> Void)?
    // Noise floor for the level meter, in dBFS, learned per recording (see the tap below).
    // NaN = "not seeded yet"; the first buffer of each recording seeds it.
    private var floorDb: Float = .nan
    private var loggedBufferSize = false
    // Wall-clock of the last tap buffer, read by the config-change guard below.
    private var lastBufferAt: TimeInterval = 0

    func start() {
        if !ensureWorkDir() { wlog("recorder ABORT — work dir gone and could not be recreated") }
        try? FileManager.default.removeItem(at: outputURL)
        floorDb = .nan; loggedBufferSize = false
        teardownEngine()
        if let dev = InputDevice.preferred(avoidBluetooth: avoidBluetoothMic) {
            // Pinned path: never instantiate AVAudioEngine.inputNode (it opens the default device).
            guard let cap = HALCapture(device: dev, handler: { [weak self] buf in self?.consume(buf) }),
                  let fmt = cap.format else { wlog("recorder ABORT — HAL capture unavailable"); return }
            guard openFile() else { return }
            converter = AVAudioConverter(from: fmt, to: targetFormat)
            hal = cap
            if cap.start() { wlog("HAL started") } else { hal = nil; audioFile = nil }
            return
        }
        let engine = AVAudioEngine()
        self.engine = engine
        let inFormat = engine.inputNode.inputFormat(forBus: 0)
        wlog("recorder.start sr=\(inFormat.sampleRate) ch=\(inFormat.channelCount)")
        guard inFormat.sampleRate > 0 else {
            wlog("recorder ABORT — bad format (mic denied?)"); self.engine = nil; return
        }
        guard openFile() else { self.engine = nil; return }
        installRecordingTap(on: engine)
        observeConfigChange(engine)
        do { try engine.start(); wlog("engine started") } catch { wlog("engine.start FAILED: \(error)") }
    }

    private func openFile() -> Bool {
        do {
            audioFile = try AVAudioFile(forWriting: outputURL, settings: targetFormat.settings,
                                        commonFormat: .pcmFormatInt16, interleaved: true)
            return true
        } catch { wlog("AVAudioFile FAILED: \(error)"); return false }
    }

    // Shared per-buffer work for both capture paths: level meter + 16k mono conversion + write.
    private func consume(_ buf: AVAudioPCMBuffer) {
        lastBufferAt = Date().timeIntervalSince1970
        if !loggedBufferSize { loggedBufferSize = true; wlog("tap buffer frames=\(buf.frameLength)") }
        if let ch = buf.floatChannelData?[0] {
            let n = Int(buf.frameLength); var sum: Float = 0
            for i in 0..<n { sum += ch[i] * ch[i] }
            let rms = n > 0 ? sqrtf(sum / Float(n)) : 0
            onLevel?(displayLevel(rms))
        }
        guard let conv = converter, let file = audioFile else { return }
        let ratio = targetFormat.sampleRate / buf.format.sampleRate
        let outCap = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 1024
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCap) else { return }
        var fed = false; var err: NSError?
        conv.convert(to: outBuf, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buf
        }
        if outBuf.frameLength > 0 { try? file.write(from: outBuf) }
    }

    // Tap + converter for the engine's CURRENT input format. The removeTap first is
    // load-bearing: installing over an existing tap raises the swallowed ObjC exception
    // described above, which reads as "mic dead" with zero evidence in this log.
    private func installRecordingTap(on engine: AVAudioEngine) {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let inFormat = input.inputFormat(forBus: 0)
        converter = AVAudioConverter(from: inFormat, to: targetFormat)
        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buf, _ in
            self?.consume(buf)
        }
    }

    // A route change (headphone unplug, device swap, sample-rate change) stops the engine
    // behind the app's back mid-recording. Rebuild capture on the new default device so the
    // rest of the dictation still lands in the same WAV instead of going silently missing.
    private func observeConfigChange(_ engine: AVAudioEngine) {
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            DispatchQueue.main.async { self?.rebuildAfterConfigChange() }
        }
    }

    private func rebuildAfterConfigChange() {
        guard let old = engine, audioFile != nil else { return }   // not recording anymore
        // An engine pinned to a non-default device posts ConfigurationChange on every start
        // (observed 2026-09-20: rebuild → notification → rebuild, every ~250ms, so a 3s
        // dictation kept 32ms of speech). Only a capture that has actually gone quiet needs
        // a rebuild: re-check after a short grace and bail if buffers are still flowing.
        if old.isRunning {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.engine === old, self.audioFile != nil else { return }
                let quiet = Date().timeIntervalSince1970 - self.lastBufferAt
                if quiet < 0.25 { wlog("config change ignored — tap still live (\(Int(quiet*1000))ms ago)"); return }
                wlog("config change: tap quiet for \(Int(quiet*1000))ms — rebuilding")
                self.rebuildNow(old)
            }
            return
        }
        wlog("config change: engine stopped — rebuilding")
        rebuildNow(old)
    }

    private func rebuildNow(_ old: AVAudioEngine) {
        old.inputNode.removeTap(onBus: 0)
        if old.isRunning { old.stop() }
        // Reusing a stopped engine after a device swap is unreliable — start clean.
        let fresh = AVAudioEngine()
        engine = fresh
        let sr = fresh.inputNode.inputFormat(forBus: 0).sampleRate
        guard sr > 0 else { wlog("route change: no usable input — recording stalled"); return }
        installRecordingTap(on: fresh)
        observeConfigChange(fresh)
        do { try fresh.start(); wlog("route change: capture rebuilt (sr=\(sr))") }
        catch { wlog("route change: engine restart FAILED: \(error)") }
    }

    // UNCONDITIONAL removeTap — gating it on engine.isRunning is exactly what leaked the
    // tap on 2026-08-10 (a route change had already stopped the engine). removeTap with no
    // tap installed is a safe no-op (harness-verified).
    private func teardownEngine() {
        if let h = hal { h.stop(); hal = nil }
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
        if let e = engine {
            e.inputNode.removeTap(onBus: 0)
            if e.isRunning { e.stop() }
            engine = nil
        }
    }

    // Map a raw buffer RMS to the 0...1 the meters draw. Amplitude-domain scaling (the old
    // `min(1, rms * 8)`) is the wrong shape for this: measured on a real 51s recording of this
    // mic, speech RMS lands around -45 dBFS and the silence floor around -64 dBFS, so `rms * 8`
    // produced 0.03...0.05 — the bars never left the bottom fifth of their range no matter how
    // loud he spoke. Hearing is logarithmic, so map in dB instead, from a per-recording noise
    // floor up a fixed span, which also makes the meter mic-independent.
    private func displayLevel(_ rms: Float) -> Float {
        let db = 20 * log10f(max(rms, 1e-7))
        if floorDb.isNaN { floorDb = db }
        // The floor may snap DOWN quickly but must never be dragged UP by speech — a floor that
        // rises while he talks would shrink the meter the longer the sentence runs. Only frames
        // already near the floor (i.e. actual room tone) are allowed to raise it, and slowly.
        if db < floorDb {
            floorDb += 0.30 * (db - floorDb)
        } else if db < floorDb + 6 {
            floorDb += 0.02 * (db - floorDb)
        }
        floorDb = min(max(floorDb, -75), -40)
        // +6 dB of dead-band so room tone still reads as silence, then 24 dB of span to full
        // scale. Tuned by replaying a real recording through this exact function: speech lands
        // around 0.73 with peaks touching 1.0 and only ~2% of speaking frames pinned at the top,
        // so the bars swing instead of either hugging the floor (the old bug) or saturating.
        return max(0, min(1, (db - (floorDb + 6)) / 24))
    }

    func stop(completion: @escaping (URL) -> Void) {
        teardownEngine()
        audioFile = nil
        wlog("recorder.stop exists=\(FileManager.default.fileExists(atPath: outputURL.path))")
        completion(outputURL)
    }
    // Cancel without transcribing — stop engine and discard the WAV.
    func cancel() {
        teardownEngine()
        audioFile = nil
        try? FileManager.default.removeItem(at: outputURL)
        wlog("recorder.cancel — audio discarded")
    }
}
