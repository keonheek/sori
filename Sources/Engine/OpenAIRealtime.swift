import Foundation
import AVFoundation

// MARK: - Streaming transcription over the OpenAI Realtime API (Experimental, P7)
// Audio is appended while recording. GA shape (2026): session.update with session.type =
// "transcription", audio/pcm 24 kHz, turn_detection null + manual commit.
// The server only transcribes what has been COMMITTED, so one commit at release made release→text
// grow with dictation length (1.0 s for 5 s clips, 2.4-3.9 s past 40 s; 2026-10-14). With
// segmentSec > 0 the client also commits at a pause once that much audio is pending, so earlier
// segments are transcribed while he is still talking and release only waits for the tail.
// Segments are stitched in commit order; with carryContext the text so far becomes the next
// segment's prompt so it continues the sentence instead of starting a new one.
final class OpenAIRealtime {
    static let sampleRate: Double = 24000
    private let task: URLSessionWebSocketTask
    private let session: URLSession
    private let lock = NSLock()
    private var order: [String] = []              // item ids in commit order (input_audio_buffer.committed)
    private var texts: [String: String] = [:]     // item id → transcript
    private var commitsSent = 0
    private var deltas = 0
    private var failed: String? = nil
    private var closed = false
    private let done = DispatchSemaphore(value: 0)
    private(set) var ready = false
    let startedAt = Date()

    // Segmentation state lives on the audio thread (append); counters shared with finish are under lock.
    private let model: String
    private let basePrompt: String
    private let segmentSamples: Int
    private let pauseSamples: Int
    private let carryContext: Bool
    private var pendingSamples = 0
    private var silenceRun = 0
    private var noiseFloor: Float = 0.01
    private var speechInPending = false

    // The server refuses a bare /v1/realtime ("You must provide a model parameter"); transcription
    // sessions connect with intent=transcription (verified 2026-09-20).
    // keywords: the live model's literal-term list (names first). deferConfig holds the session
    // update (and buffers audio) until configure(screenTerms:) adds the words read off the screen at
    // key-down; the socket handshake takes about as long, so nothing waits on it.
    private let baseKeywords: [String]
    private var configured = false
    private var held: [Data] = []

    init?(model: String, prompt: String, keywords: [String] = [], names: Int = 0, deferConfig: Bool = false,
          segmentSec: Double = 0, pauseMs: Int = 600, carryContext: Bool = true,
          endpoint: String = "wss://api.openai.com/v1/realtime?intent=transcription") {
        guard let key = OpenAITranscribe.apiKey(), !key.isEmpty,
              let url = URL(string: endpoint) else { return nil }
        self.model = model
        self.basePrompt = prompt
        self.segmentSamples = Int(segmentSec * OpenAIRealtime.sampleRate)
        self.pauseSamples = Int(Double(pauseMs) / 1000 * OpenAIRealtime.sampleRate)
        self.carryContext = carryContext
        self.baseKeywords = keywords
        self.nameCount = names
        var req = URLRequest(url: url)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        session = URLSession(configuration: .default)
        task = session.webSocketTask(with: req)
        task.resume()
        if deferConfig {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.configure(screenTerms: []) }
        } else {
            configured = true
            sendSessionUpdate(prompt: prompt)
        }
        receiveLoop()
    }

    // Once: send the session update with the screen words merged in, then release held audio.
    func configure(screenTerms: [String]) {
        lock.lock()
        guard !configured else { lock.unlock(); return }
        configured = true
        screenKeywords = screenTerms
        sendSessionUpdate(prompt: basePrompt)
        let audio = held; held = []
        for d in audio { send(["type": "input_audio_buffer.append", "audio": d.base64EncodedString()]) }
        lock.unlock()
    }
    private var screenKeywords: [String] = []

    // Names (dictionary) first, then screen words, then the rest; one line each, no < >.
    static let maxKeywords = 80
    static func mergeKeywords(base: [String], names: Int, screen: [String]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for t in Array(base.prefix(names)) + screen + Array(base.dropFirst(names)) {
            let k = t.trimmingCharacters(in: .whitespaces)
            guard ScreenVocab.safe(k), seen.insert(k.lowercased()).inserted else { continue }
            out.append(k)
        }
        return Array(out.prefix(maxKeywords))
    }
    private let nameCount: Int

    // gpt-live-transcribe (2026-07-28) emits deltas while audio arrives instead of starting at the
    // commit; it takes literal terms as `keywords` (one line each, no < >), a `delay` knob, and
    // `languages` hints. The bias list Sori builds is comma-joined terms, so it maps onto keywords.
    var isLive: Bool { model.hasPrefix("gpt-live") }
    // medium: same release→text as low/minimal on his clips (p50 0.77 s) with the best accuracy
    // (3.1% CER on the read-aloud set vs 5.1% at low; bench 2026-10-14). Conf key liveDelay overrides.
    static var liveDelay: String { ProcessInfo.processInfo.environment["SORI_LIVE_DELAY"] ?? Config.load().liveDelay ?? "medium" }

    private func sendSessionUpdate(prompt: String) {
        var transcription: [String: Any] = ["model": model]
        if isLive {
            // 2026-10-14: this used to re-split the 12-term bias PROMPT, so only 11 of ~55 terms
            // arrived (the cap, and the first term carried the "…exactly:" prefix and was dropped).
            let kw = OpenAIRealtime.mergeKeywords(base: baseKeywords, names: nameCount, screen: screenKeywords)
            if !kw.isEmpty { transcription["keywords"] = kw }
            transcription["languages"] = ["ko", "en"]
            transcription["delay"] = OpenAIRealtime.liveDelay
            transcription["prompt"] = "Push-to-talk dictation by one speaker who mixes Korean and English, often about AI and software."
        } else if !prompt.isEmpty { transcription["prompt"] = prompt }
        send(["type": "session.update", "session": [
            "type": "transcription",
            "audio": ["input": [
                "format": ["type": "audio/pcm", "rate": Int(OpenAIRealtime.sampleRate)],
                "transcription": transcription,
                "turn_detection": NSNull(),
            ]],
        ]])
    }

    private func send(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: data, encoding: .utf8) else { return }
        task.send(.string(s)) { [weak self] err in
            if let err { self?.lock.lock(); self?.failed = self?.failed ?? "send: \(err.localizedDescription)"; self?.lock.unlock() }
        }
    }

    func append(pcm16: Data) {
        guard !closed, !pcm16.isEmpty else { return }
        lock.lock()
        if !configured { held.append(pcm16); lock.unlock() }
        else { lock.unlock(); send(["type": "input_audio_buffer.append", "audio": pcm16.base64EncodedString()]) }
        guard segmentSamples > 0 else { return }
        // Energy pause detector: a chunk is silence when it sits near the tracked noise floor.
        let n = pcm16.count / 2
        var sum: Float = 0
        pcm16.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for i in 0..<n { let v = Float(p[i]) / 32768; sum += v * v }
        }
        let rms = n > 0 ? sqrtf(sum / Float(n)) : 0
        noiseFloor = rms < noiseFloor ? rms : noiseFloor + (rms - noiseFloor) * 0.002
        let silent = rms < max(noiseFloor * 3, 0.004)
        pendingSamples += n
        if silent { silenceRun += n } else { silenceRun = 0; speechInPending = true }
        lock.lock(); let released = committedAt != nil; lock.unlock()
        if !released, speechInPending, pendingSamples >= segmentSamples, silenceRun >= pauseSamples {
            commitSegment(final: false)
        }
    }

    private func commitSegment(final: Bool) {
        lock.lock(); commitsSent += 1; let k = commitsSent; lock.unlock()
        pendingSamples = 0; silenceRun = 0; speechInPending = false
        send(["type": "input_audio_buffer.commit"])
        if !final { wlog(String(format: "realtime: segment %d committed at a pause (%.1fs)", k, Date().timeIntervalSince(startedAt))) }
    }

    // Commit the tail as soon as the key comes up, so the server starts on it while the app is still
    // moving the WAV and running the local VAD gate (that work cost 0.1-0.5 s before the commit).
    private var committedAt: Date?
    func commit() {
        configure(screenTerms: [])   // a press shorter than the screen read: send what we have
        lock.lock(); let already = committedAt != nil; if !already { committedAt = Date() }; let sent = commitsSent; lock.unlock()
        guard !already else { return }
        // A silent tail after a pause commit is skipped: the server rejects an empty buffer, and that
        // error would throw the whole dictation onto the batch fallback.
        if sent > 0 && (!speechInPending || pendingSamples < Int(0.15 * OpenAIRealtime.sampleRate)) {
            wlog("realtime: tail after the last segment is silence — not committed")
            return
        }
        commitSegment(final: true)
    }

    // Commit (if not already) and wait for every committed segment's transcript. Nil = fall back to batch.
    func finish(timeout: TimeInterval = 5) -> String? {
        commit()
        lock.lock(); let t0 = committedAt ?? Date(); lock.unlock()
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            lock.lock(); let have = texts.count; let need = commitsSent; let err = failed; lock.unlock()
            if err != nil || (need > 0 && have >= need) { break }
            if done.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow)) == .timedOut { break }
        }
        lock.lock()
        let ids = order + texts.keys.filter { !order.contains($0) }.sorted()
        let text = ids.compactMap { texts[$0] }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        let err = failed; let n = deltas; let have = texts.count; let need = commitsSent
        lock.unlock()
        closed = true
        task.cancel(with: .normalClosure, reason: nil)
        if let err { wlog("realtime FAILED: \(err)"); return nil }
        guard have >= need else { wlog("realtime: \(have)/\(need) segments within \(timeout)s (deltas \(n))"); return nil }
        guard !text.isEmpty else { wlog("realtime: no transcript within \(timeout)s (deltas \(n))"); return nil }
        wlog(String(format: "realtime transcript in %.2fs after commit (%d segments, %d deltas, session %.1fs)", Date().timeIntervalSince(t0), need, n, Date().timeIntervalSince(startedAt)))
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() { closed = true; task.cancel(with: .normalClosure, reason: nil) }

    private func receiveLoop() {
        task.receive { [weak self] result in
            guard let self, !self.closed else { return }
            switch result {
            case .failure(let e):
                self.lock.lock(); self.failed = self.failed ?? "receive: \(e.localizedDescription)"; self.lock.unlock()
                self.done.signal()
            case .success(let msg):
                if case .string(let s) = msg, let data = s.data(using: .utf8),
                   let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let type = j["type"] as? String {
                    switch type {
                    case "session.created", "session.updated", "transcription_session.updated":
                        self.ready = true
                    case "input_audio_buffer.committed":
                        if let id = j["item_id"] as? String { self.lock.lock(); self.order.append(id); self.lock.unlock() }
                    case "conversation.item.input_audio_transcription.delta":
                        self.lock.lock(); self.deltas += 1; self.lock.unlock()
                    case "conversation.item.input_audio_transcription.completed":
                        let t = (j["transcript"] as? String) ?? ""
                        let id = (j["item_id"] as? String) ?? UUID().uuidString
                        self.lock.lock()
                        self.texts[id] = t
                        let soFar = self.order.compactMap { self.texts[$0] }.joined(separator: " ")
                        let more = self.committedAt == nil
                        self.lock.unlock()
                        // The next segment continues this text instead of starting a fresh sentence.
                        if self.carryContext, more, !soFar.isEmpty {
                            let tail = String(soFar.suffix(400))
                            self.sendSessionUpdate(prompt: [self.basePrompt, tail].filter { !$0.isEmpty }.joined(separator: "\n\n"))
                        }
                        self.done.signal()
                    case "error":
                        let m = ((j["error"] as? [String: Any])?["message"] as? String) ?? s
                        self.lock.lock(); self.failed = self.failed ?? m; self.lock.unlock()
                        self.done.signal()
                    default: break
                    }
                }
                self.receiveLoop()
            }
        }
    }

    // 16 kHz mono int16 WAV → 24 kHz int16 PCM chunks (for the CLI probe and tests).
    static func pcm24k(fromWav path: String) -> [Data] {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return [] }
        let inFmt = file.processingFormat
        let outFmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!
        guard let conv = AVAudioConverter(from: inFmt, to: outFmt),
              let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: AVAudioFrameCount(file.length)) else { return [] }
        try? file.read(into: inBuf)
        let outCap = AVAudioFrameCount(Double(inBuf.frameLength) * (sampleRate / inFmt.sampleRate)) + 4096
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: outCap) else { return [] }
        var fed = false; var err: NSError?
        conv.convert(to: outBuf, error: &err) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true; status.pointee = .haveData; return inBuf
        }
        let bytes = Int(outBuf.frameLength) * 2
        let all = Data(bytes: outBuf.int16ChannelData![0], count: bytes)
        let chunk = Int(sampleRate * 0.1) * 2   // 100 ms
        return stride(from: 0, to: all.count, by: chunk).map { all.subdata(in: $0..<min($0 + chunk, all.count)) }
    }
}
