import Foundation
import AVFoundation

// MARK: - Streaming transcription over the OpenAI Realtime API (Experimental, P7)
// Audio is appended while recording; on release only the tail is pending, so release→text is a
// commit round-trip instead of a full upload. GA shape (2026): session.update with
// session.type = "transcription", audio/pcm 24 kHz, turn_detection null + manual commit.
final class OpenAIRealtime {
    static let sampleRate: Double = 24000
    private let task: URLSessionWebSocketTask
    private let session: URLSession
    private let lock = NSLock()
    private var completed: [String] = []
    private var deltas = 0
    private var failed: String? = nil
    private var closed = false
    private let done = DispatchSemaphore(value: 0)
    private(set) var ready = false
    let startedAt = Date()

    // The server refuses a bare /v1/realtime ("You must provide a model parameter"); transcription
    // sessions connect with intent=transcription (verified 2026-09-20).
    init?(model: String, prompt: String, endpoint: String = "wss://api.openai.com/v1/realtime?intent=transcription") {
        guard let key = OpenAITranscribe.apiKey(), !key.isEmpty,
              let url = URL(string: endpoint) else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        session = URLSession(configuration: .default)
        task = session.webSocketTask(with: req)
        task.resume()
        var transcription: [String: Any] = ["model": model]
        if !prompt.isEmpty { transcription["prompt"] = prompt }
        let update: [String: Any] = ["type": "session.update", "session": [
            "type": "transcription",
            "audio": ["input": [
                "format": ["type": "audio/pcm", "rate": Int(OpenAIRealtime.sampleRate)],
                "transcription": transcription,
                "turn_detection": NSNull(),
            ]],
        ]]
        send(update)
        receiveLoop()
    }

    private func send(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: data, encoding: .utf8) else { return }
        task.send(.string(s)) { [weak self] err in
            if let err { self?.lock.lock(); self?.failed = self?.failed ?? "send: \(err.localizedDescription)"; self?.lock.unlock() }
        }
    }

    func append(pcm16: Data) {
        guard !closed, !pcm16.isEmpty else { return }
        send(["type": "input_audio_buffer.append", "audio": pcm16.base64EncodedString()])
    }

    // Commit and wait for the transcript of everything appended so far. Nil = fall back to batch.
    func finish(timeout: TimeInterval = 5) -> String? {
        send(["type": "input_audio_buffer.commit"])
        let t0 = Date()
        _ = done.wait(timeout: .now() + timeout)
        lock.lock(); let text = completed.joined(separator: " "); let err = failed; let n = deltas; lock.unlock()
        closed = true
        task.cancel(with: .normalClosure, reason: nil)
        if let err { wlog("realtime FAILED: \(err)"); return nil }
        guard !text.isEmpty else { wlog("realtime: no transcript within \(timeout)s (deltas \(n))"); return nil }
        wlog(String(format: "realtime transcript in %.2fs after commit (%d deltas, session %.1fs)", Date().timeIntervalSince(t0), n, Date().timeIntervalSince(startedAt)))
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
                    case "conversation.item.input_audio_transcription.delta":
                        self.lock.lock(); self.deltas += 1; self.lock.unlock()
                    case "conversation.item.input_audio_transcription.completed":
                        let t = (j["transcript"] as? String) ?? ""
                        self.lock.lock(); self.completed.append(t); self.lock.unlock()
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
