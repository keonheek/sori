import Cocoa
import AVFoundation
import CoreAudio
import Carbon.HIToolbox
import IOKit.hid

// MARK: - Cloud transcriber (OpenAI gpt-transcribe)
enum OpenAITranscribe {
    static func apiKey() -> String? {
        if let env = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !env.isEmpty { return env }
        let p = (NSHomeDirectory() as NSString).appendingPathComponent(".sori-openai")
        return (try? String(contentsOfFile: p, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    // Multipart upload of the 16 kHz mono WAV. `prompt` carries names + vocabulary (the API's
    // documented use: "domain terms and multilingual audio"). Returns nil on any failure so the
    // caller can fall back to the local engine; never returns a partial/garbled body.
    static func transcribe(wav: String, model: String, prompt: String, timeout: TimeInterval = 8) -> String? {
        guard let key = apiKey(), !key.isEmpty else { wlog("openai transcribe: no key (~/.sori-openai)"); return nil }
        guard let audio = FileManager.default.contents(atPath: wav),
              let url = URL(string: "https://api.openai.com/v1/audio/transcriptions") else { return nil }
        let b = "sori\(UUID().uuidString)"
        var body = Data()
        func field(_ n: String, _ v: String) { body.append("--\(b)\r\nContent-Disposition: form-data; name=\"\(n)\"\r\n\r\n\(v)\r\n".data(using: .utf8)!) }
        field("model", model); field("response_format", "json")
        if !prompt.isEmpty { field("prompt", prompt) }
        body.append("--\(b)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"sori.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audio); body.append("\r\n--\(b)--\r\n".data(using: .utf8)!)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(b)", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = body
        req.timeoutInterval = timeout
        let sem = DispatchSemaphore(value: 0)
        var out: String? = nil
        let t0 = Date()
        URLSession.shared.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if let err = err { wlog("openai transcribe error: \(err.localizedDescription)"); return }
            guard let data = data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            if let e = json["error"] as? [String: Any] { wlog("openai transcribe API error: \(e["message"] as? String ?? "?")"); return }
            if let t = json["text"] as? String { out = t.trimmingCharacters(in: .whitespacesAndNewlines) }
            _ = resp
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 1)
        if out != nil { wlog(String(format: "openai transcribe %@ %.2fs", model, Date().timeIntervalSince(t0))) }
        return out
    }
}
