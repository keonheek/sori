import Foundation

// MARK: - Dictation records — the one table behind Home, stats, undo, retry and the eval set
struct Dictation: Identifiable, Hashable {
    let id: Int64
    let ts: Date
    let bundleId: String
    let appName: String
    let windowTitle: String
    let kind: String
    let raw: String
    let final: String
    let provider: String
    let audioMs: Int
    let asrMs: Int
    let rewriteMs: Int
    let totalMs: Int
    let words: Int
    let pasted: Bool
    let audioPath: String

    static func from(_ r: Database.Row) -> Dictation {
        Dictation(id: r.int("id"), ts: Date(timeIntervalSince1970: r.real("ts")),
                  bundleId: r.text("bundle_id"), appName: r.text("app_name"), windowTitle: r.text("window_title"),
                  kind: r.text("kind"), raw: r.text("raw"), final: r.text("final"), provider: r.text("provider"),
                  audioMs: Int(r.int("audio_ms")), asrMs: Int(r.int("asr_ms")), rewriteMs: Int(r.int("rewrite_ms")),
                  totalMs: Int(r.int("total_ms")), words: Int(r.int("words")), pasted: r.int("pasted") != 0,
                  audioPath: r.text("audio_path"))
    }
}

struct DictationStats {
    var wordsToday = 0
    var wordsWeek = 0
    var countToday = 0
    var countWeek = 0
    var avgLatencyMs = 0          // ASR + rewrite, this week
    var topApps: [(name: String, count: Int)] = []
    var wpm = 0                   // words per minute of audio, this week
}

enum DictationRepo {
    static func wordCount(_ s: String) -> Int { s.split(whereSeparator: { $0.isWhitespace }).count }

    struct Draft {
        var ts = Date()
        var context: AppContext
        var raw: String
        var final: String
        var provider: String
        var audioMs: Int
        var asrMs: Int
        var rewriteMs: Int
        var totalMs: Int
        var audioPath: String
    }

    @discardableResult
    static func insert(_ d: Draft) -> Int64 {
        let id = Database.shared.run("""
            INSERT INTO dictations(ts,bundle_id,app_name,window_title,kind,raw,final,provider,
              audio_ms,asr_ms,rewrite_ms,total_ms,words,pasted,audio_path)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,0,?)
            """, [.real(d.ts.timeIntervalSince1970), .text(d.context.bundleId), .text(d.context.appName),
                  .text(d.context.windowTitle), .text(d.context.kind.rawValue), .text(d.raw), .text(d.final),
                  .text(d.provider), .int(Int64(d.audioMs)), .int(Int64(d.asrMs)), .int(Int64(d.rewriteMs)),
                  .int(Int64(d.totalMs)), .int(Int64(wordCount(d.final))), .text(d.audioPath)])
        changed()
        return id
    }

    static func markPasted(_ id: Int64, totalMs: Int? = nil) {
        if let t = totalMs {
            Database.shared.run("UPDATE dictations SET pasted=1, total_ms=? WHERE id=?", [.int(Int64(t)), .int(id)])
        } else {
            Database.shared.run("UPDATE dictations SET pasted=1 WHERE id=?", [.int(id)])
        }
        changed()
    }

    static func delete(_ id: Int64) {
        Database.shared.run("DELETE FROM dictations WHERE id=?", [.int(id)])
        changed()
    }

    static func get(_ id: Int64) -> Dictation? {
        Database.shared.query("SELECT * FROM dictations WHERE id=?", [.int(id)]).first.map(Dictation.from)
    }

    static func last() -> Dictation? {
        Database.shared.query("SELECT * FROM dictations ORDER BY ts DESC LIMIT 1").first.map(Dictation.from)
    }

    static func recent(limit: Int = 500, search: String = "") -> [Dictation] {
        let s = search.trimmingCharacters(in: .whitespaces)
        if s.isEmpty {
            return Database.shared.query("SELECT * FROM dictations ORDER BY ts DESC LIMIT ?", [.int(Int64(limit))]).map(Dictation.from)
        }
        let like = "%" + s.replacingOccurrences(of: "%", with: "\\%") + "%"
        return Database.shared.query("""
            SELECT * FROM dictations WHERE final LIKE ? ESCAPE '\\' OR raw LIKE ? ESCAPE '\\' OR app_name LIKE ? ESCAPE '\\'
            ORDER BY ts DESC LIMIT ?
            """, [.text(like), .text(like), .text(like), .int(Int64(limit))]).map(Dictation.from)
    }

    static func stats(now: Date = Date()) -> DictationStats {
        var st = DictationStats()
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: now).timeIntervalSince1970
        let weekStart = cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: now))!.timeIntervalSince1970
        let db = Database.shared
        st.wordsToday = Int(db.scalar("SELECT COALESCE(SUM(words),0) FROM dictations WHERE ts>=? AND pasted=1", [.real(dayStart)]))
        st.countToday = Int(db.scalar("SELECT COUNT(*) FROM dictations WHERE ts>=? AND pasted=1", [.real(dayStart)]))
        st.wordsWeek = Int(db.scalar("SELECT COALESCE(SUM(words),0) FROM dictations WHERE ts>=? AND pasted=1", [.real(weekStart)]))
        st.countWeek = Int(db.scalar("SELECT COUNT(*) FROM dictations WHERE ts>=? AND pasted=1", [.real(weekStart)]))
        st.avgLatencyMs = Int(db.scalar("SELECT COALESCE(AVG(asr_ms+rewrite_ms),0) FROM dictations WHERE ts>=? AND asr_ms>0", [.real(weekStart)]))
        let audioMs = db.scalar("SELECT COALESCE(SUM(audio_ms),0) FROM dictations WHERE ts>=? AND pasted=1 AND audio_ms>0", [.real(weekStart)])
        let audioWords = db.scalar("SELECT COALESCE(SUM(words),0) FROM dictations WHERE ts>=? AND pasted=1 AND audio_ms>0", [.real(weekStart)])
        st.wpm = audioMs > 0 ? Int(audioWords / (audioMs / 60000.0)) : 0
        st.topApps = db.query("""
            SELECT app_name, COUNT(*) AS c FROM dictations WHERE ts>=? AND app_name<>'' GROUP BY app_name ORDER BY c DESC LIMIT 3
            """, [.real(weekStart)]).map { ($0.text("app_name"), Int($0.int("c"))) }
        return st
    }

    private static func changed() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: Database.dictationsChanged, object: nil) }
    }
}
