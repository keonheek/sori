import Cocoa
import AVFoundation
import CoreAudio
import Carbon.HIToolbox
import IOKit.hid

// Resident Qwen3-ASR engine (engine/qwen_server.py). Replaced whisper.cpp as the
// transcription path 2026-08-12 after an A/B on an 8-line Korean/English clip:
//
//   qwen3-asr-1.7b            11-12 / 13 technical terms, no repetition loop
//   whisper large-v3-turbo     8 / 13 WITH Sori's own aiTerms glossary, loop 3x
//   apple SpeechAnalyzer       1 / 13, silently DROPPED a whole English sentence
//
// whisper's glossary already contained Pinecone/Groq/Whisper/Qwen and still missed
// them, so the gap is the model, not the prompt. Qwen also does its own language
// identification, which is why the ggml-base pre-detection pass is gone.
//
// The model load (~1.4s) is paid once at launch, not per keypress: invoking the
// mlx CLI per dictation costs ~9s, nearly all of it Python interpreter startup.
enum QwenServer {
    static let port = 8918
    static let defaultRepo = "mlx-community/Qwen3-ASR-1.7B-8bit"
    // Absolute path to the venv python that has mlx-audio installed; install.sh
    // creates it. Kept separate from any system python so a `brew upgrade` of
    // python3 cannot silently break dictation.
    static var pythonPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".sori-venv/bin/python3")
    }
    static var serverScript: String {
        // Bundled next to the executable in Sori.app; falls back to the source
        // checkout so `swiftc main.swift && ./main` works during development.
        let bundled = Bundle.main.bundlePath + "/Contents/Resources/qwen_server.py"
        if FileManager.default.fileExists(atPath: bundled) { return bundled }
        // install.sh records the source checkout in ~/.sori-src; a clone anywhere other
        // than ~/Dev/sori used to get "qwen engine MISSING" here (2026-09-03).
        if let src = Updater.sourceRepo() {
            let p = (src as NSString).appendingPathComponent("engine/qwen_server.py")
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        return (NSHomeDirectory() as NSString).appendingPathComponent("Dev/sori/engine/qwen_server.py")
    }
    private static var proc: Process?
    private static var runningModel: String?   // model the CURRENT server was spawned with
    private static let lock = NSLock()

    static func healthy(timeout: TimeInterval = 0.4) -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/") else { return false }
        var req = URLRequest(url: url); req.timeoutInterval = timeout
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            ok = ((resp as? HTTPURLResponse)?.statusCode ?? 0) == 200
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 0.1)
        return ok
    }

    // Anything listening on the port (healthy or not) — a plain TCP connect, no HTTP.
    static func portInUse() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET); addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        return rc == 0
    }

    static func ensureRunning(modelPath: String) {
        lock.lock(); defer { lock.unlock() }
        if healthy() {
            // A healthy server is only trustworthy if WE spawned it with THIS model.
            // Otherwise it's an orphan from an earlier SIGKILL redeploy, or a server
            // on the old repo after a Settings switch — either way it would silently
            // transcribe with the WRONG model.
            if runningModel == modelPath { return }
            wlog("qwen_server on :\(port) is stale/orphaned (model \(runningModel ?? "unknown")) — replacing")
            if let p = proc, p.isRunning { p.terminate() }
            let kill = Process()
            kill.launchPath = "/usr/bin/pkill"
            kill.arguments = ["-f", "qwen_server.py.*--port \(port)"]
            try? kill.run(); kill.waitUntilExit()
            proc = nil; runningModel = nil
            usleep(300_000)   // let the port free up before respawn
        } else if proc == nil, portInUse() {
            // Not healthy, not ours: an orphan from a previous Sori process that never finished
            // loading — its stdout pipe died with the parent, the load thread hit BrokenPipe,
            // and it sat on :8918 forever while every fresh spawn died with EADDRINUSE
            // (2026-09-20, three redeploys in a row). Clear it before spawning.
            wlog("qwen_server on :\(port) is unresponsive and not ours — killing the orphan")
            let kill = Process()
            kill.launchPath = "/usr/bin/pkill"
            kill.arguments = ["-f", "qwen_server.py.*--port \(port)"]
            try? kill.run(); kill.waitUntilExit()
            usleep(300_000)
        }
        // A spawn may still be loading the model (health returns 503 during load) —
        // don't stack a second one on top.
        if let p = proc, p.isRunning { return }
        guard FileManager.default.fileExists(atPath: pythonPath) else {
            wlog("qwen engine MISSING: no venv python at \(pythonPath) — run install.sh")
            return
        }
        guard FileManager.default.fileExists(atPath: serverScript) else {
            wlog("qwen engine MISSING: no qwen_server.py at \(serverScript)")
            return
        }
        let t = Process()
        t.launchPath = pythonPath
        t.arguments = [serverScript, "--port", String(port), "--model", modelPath,
                       "--allow-dir", soriWorkDir]
        t.standardOutput = FileHandle.nullDevice
        // Keep stderr: the server logs model-load failures there, and a silent
        // engine is the one failure mode that looks identical to a dead hotkey.
        let errPipe = Pipe()
        t.standardError = errPipe
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            for line in s.split(separator: "\n") where !line.isEmpty { wlog("[qwen] \(line)") }
        }
        do { try t.run(); proc = t; runningModel = modelPath; wlog("qwen_server spawned (pid \(t.processIdentifier))") }
        catch { wlog("qwen_server spawn FAILED: \(error)") }
    }

    static func stop() {
        lock.lock(); defer { lock.unlock() }
        if let p = proc, p.isRunning { p.terminate(); wlog("qwen_server stopped") }
        proc = nil; runningModel = nil
    }

    // POST the wav path to /inference. The server is loopback-local, so the audio
    // is passed by path rather than uploaded.
    //
    // `lang` may be empty: Qwen3-ASR identifies the language itself across 52
    // languages, which is what let the ggml-base pre-detection pass be deleted.
    // `vocabulary` is the aiTerms glossary and is normally EMPTY — see the note in
    // qwen_server.py: biasing fixed "Groq" but hallucinated "Qwen 3.6" into
    // "Claude 3.6", which is a worse error because it survives proofreading.
    // Blocks until the server answers 200 on "/", or `limit` seconds pass. Used for the
    // first dictation after launch: the model takes ~2-3 s to load and used to fail
    // that dictation outright with "engine UNAVAILABLE" (2026-09-03).
    static func waitHealthy(limit: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(limit)
        while Date() < deadline {
            if healthy() { return true }
            usleep(400_000)
        }
        return false
    }

    // Speech gate only (TEN-VAD in the engine), no inference. nil = engine unavailable
    // (caller decides), true = speech present, false = silence / short tap.
    static func hasSpeech(wav: String) -> Bool? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/inference"),
              let body = try? JSONSerialization.data(withJSONObject: ["path": wav, "vad_only": true]) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"; req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body; req.timeoutInterval = 3
        let sem = DispatchSemaphore(value: 0); var result: Bool? = nil
        URLSession.shared.dataTask(with: req) { data, _, _ in
            defer { sem.signal() }
            guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            if json["error"] != nil { return }
            // Engine answers text:"" when VAD found too little speech, text:null when it passed.
            result = !(json["text"] is String)
        }.resume()
        _ = sem.wait(timeout: .now() + 3.5)
        return result
    }

    static func transcribe(wav: String, lang: String, vocabulary: String = "") -> String? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/inference") else { return nil }
        var payload: [String: String] = ["path": wav]
        if !lang.isEmpty && lang != "auto" { payload["language"] = lang }
        if !vocabulary.isEmpty { payload["context"] = vocabulary }
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.timeoutInterval = 60   // generous: long recordings

        // One retry, only for "still loading" (503) or "not up yet" (connection refused):
        // both mean the engine is on its way, not broken.
        for attempt in 0..<2 {
            let sem = DispatchSemaphore(value: 0)
            var out: String? = nil
            var retryable = false
            URLSession.shared.dataTask(with: req) { data, resp, err in
                defer { sem.signal() }
                if let err = err {
                    retryable = (err as NSError).code == NSURLErrorCannotConnectToHost
                    wlog("qwen_server inference error: \(err)"); return
                }
                if (resp as? HTTPURLResponse)?.statusCode == 503 { retryable = true }
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                if let e = json["error"] as? String { wlog("qwen_server inference failed: \(e)"); return }
                guard let t = json["text"] as? String else { return }
                out = t.trimmingCharacters(in: .whitespacesAndNewlines)
            }.resume()
            _ = sem.wait(timeout: .now() + 61)
            if let out { return out }
            guard attempt == 0, retryable else { return nil }
            wlog("engine not ready — waiting for health before one retry")
            guard waitHealthy(limit: 15) else { return nil }
        }
        return nil
    }
}
