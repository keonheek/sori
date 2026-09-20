import Foundation

// MARK: - One-off backfill from sori.log (history that predates the store, 2026-09-20)
// Reads the "stopAndTranscribe → transcribe → smart rewrite ctx → raw/final → pasted"
// sequences the app has always logged and inserts them as dictation rows. Idempotent:
// a row with the same timestamp and raw text is skipped.
enum LogImport {
    static func run(path: String) -> Int {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { wlog("import: cannot read \(path)"); return 0 }
        let year = Calendar.current.component(.year, from: Date())
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; df.timeZone = .current
        let rawFinal = try! NSRegularExpression(pattern: #"^raw="(.*?)" -> final="(.*)"$"#)
        let ctxRe = try! NSRegularExpression(pattern: #"^smart rewrite ctx: (\w+) — (.*?) \[([^\]]*)\](?: — (.*))?$"#)
        let asrRe = try! NSRegularExpression(pattern: #"^openai transcribe \S+ ([\d.]+)s$"#)
        let keptRe = try! NSRegularExpression(pattern: #"^kept (.+\.wav)$"#)

        var ts = Date(), provider = "", asrMs = 0, ctx = AppContext(bundleId: "", appName: "", windowTitle: ""), kept = ""
        var pending: (ts: Date, ctx: AppContext, raw: String, final: String, provider: String, asrMs: Int, kept: String)?
        var inserted = 0
        func flush(pasted: Bool) {
            guard let p = pending else { return }
            pending = nil
            let exists = Database.shared.scalar("SELECT COUNT(*) FROM dictations WHERE ts=? AND raw=?",
                                                [.real(p.ts.timeIntervalSince1970), .text(p.raw)]) > 0
            if exists { return }
            let bytes = (try? FileManager.default.attributesOfItem(atPath: p.kept)[.size] as? Int) ?? 0
            let audioMs = bytes > 44 ? (bytes - 44) / 32 : 0
            let id = DictationRepo.insert(.init(ts: p.ts, context: p.ctx, raw: p.raw, final: p.final, provider: p.provider,
                                                audioMs: audioMs, asrMs: p.asrMs, rewriteMs: 0, totalMs: 0, audioPath: p.kept))
            if pasted { DictationRepo.markPasted(id) }
            inserted += 1
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let l = String(line)
            guard l.count > 19, l[l.index(l.startIndex, offsetBy: 5)] == " " else { continue }
            let stamp = String(l.prefix(18)), body = String(l.dropFirst(19))
            guard let t = df.date(from: "\(year)-\(stamp)") else { continue }
            let ns = NSRange(body.startIndex..., in: body)
            if body.hasPrefix(">>> stopAndTranscribe") {
                flush(pasted: false); ts = t; provider = ""; asrMs = 0; kept = ""
                ctx = AppContext(bundleId: "", appName: "", windowTitle: "")
            } else if let m = keptRe.firstMatch(in: body, range: ns) {
                kept = String(body[Range(m.range(at: 1), in: body)!])
            } else if let m = asrRe.firstMatch(in: body, range: ns) {
                asrMs = Int((Double(body[Range(m.range(at: 1), in: body)!]) ?? 0) * 1000); provider = "openai"
            } else if body.hasPrefix("transcribed via qwen") {
                provider = "qwen"
            } else if let m = ctxRe.firstMatch(in: body, range: ns) {
                let name = String(body[Range(m.range(at: 2), in: body)!])
                let bid = String(body[Range(m.range(at: 3), in: body)!])
                let title = m.range(at: 4).location == NSNotFound ? "" : String(body[Range(m.range(at: 4), in: body)!])
                ctx = AppContext(bundleId: bid, appName: name, windowTitle: title)
            } else if let m = rawFinal.firstMatch(in: body, range: ns) {
                let raw = String(body[Range(m.range(at: 1), in: body)!])
                let fin = String(body[Range(m.range(at: 2), in: body)!])
                pending = (ts, ctx, raw, fin, provider, asrMs, kept)
            } else if body.hasPrefix("pasted") {
                flush(pasted: true)
            }
        }
        flush(pasted: false)
        wlog("import: \(inserted) dictations from \(path)")
        return inserted
    }
}
