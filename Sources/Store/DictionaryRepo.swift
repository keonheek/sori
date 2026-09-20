import Foundation

// MARK: - Dictionary: names, spellings and corrections (was promptHint + replacements + learned in the conf)
// One row = one term. `word` is what to output; `replacement` empty means "a word to spell exactly"
// (feeds the ASR bias prompt AND canonicalizes casing), non-empty means "heard `word` → paste
// `replacement`" (the old auto-correction). `starred` rows go first into the bias prompt (cap 12).
struct DictionaryEntry: Identifiable, Hashable {
    let id: Int64
    var word: String
    var replacement: String
    var starred: Bool
    var source: String      // manual | learned
    let createdTs: Date
    var isCorrection: Bool { !replacement.isEmpty }
    var canonical: String { replacement.isEmpty ? word : replacement }

    static func from(_ r: Database.Row) -> DictionaryEntry {
        DictionaryEntry(id: r.int("id"), word: r.text("word"), replacement: r.text("replacement"),
                        starred: r.int("starred") != 0, source: r.text("source"),
                        createdTs: Date(timeIntervalSince1970: r.real("created_ts")))
    }
}

enum DictionaryRepo {
    static func all() -> [DictionaryEntry] {
        Database.shared.query("SELECT * FROM dictionary ORDER BY starred DESC, lower(word) ASC").map(DictionaryEntry.from)
    }

    @discardableResult
    static func add(word: String, replacement: String = "", starred: Bool = false, source: String = "manual") -> Int64 {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty else { return -1 }
        let id = Database.shared.run("""
            INSERT INTO dictionary(word,replacement,starred,source,created_ts) VALUES(?,?,?,?,?)
            ON CONFLICT(word) DO UPDATE SET replacement=excluded.replacement, starred=excluded.starred, source=excluded.source
            """, [.text(w), .text(replacement.trimmingCharacters(in: .whitespacesAndNewlines)),
                  .int(starred ? 1 : 0), .text(source), .real(Date().timeIntervalSince1970)])
        changed(); return id
    }

    static func update(_ e: DictionaryEntry) {
        Database.shared.run("UPDATE dictionary SET word=?, replacement=?, starred=? WHERE id=?",
                            [.text(e.word.trimmingCharacters(in: .whitespacesAndNewlines)),
                             .text(e.replacement.trimmingCharacters(in: .whitespacesAndNewlines)),
                             .int(e.starred ? 1 : 0), .int(e.id)])
        changed()
    }

    static func setStarred(_ id: Int64, _ on: Bool) {
        Database.shared.run("UPDATE dictionary SET starred=? WHERE id=?", [.int(on ? 1 : 0), .int(id)]); changed()
    }

    static func delete(_ id: Int64) { Database.shared.run("DELETE FROM dictionary WHERE id=?", [.int(id)]); changed() }

    // Learn-from-edits lands here (source=learned). A manual rule for the same word wins.
    static func upsertLearned(from: String, to: String) {
        if let existing = Database.shared.query("SELECT * FROM dictionary WHERE word=? COLLATE NOCASE", [.text(from)]).first.map(DictionaryEntry.from) {
            if existing.source == "manual" { return }
            Database.shared.run("UPDATE dictionary SET replacement=? WHERE id=?", [.text(to), .int(existing.id)])
            changed()
        } else {
            add(word: from, replacement: to, source: "learned")
        }
    }

    // One-time move of the conf's promptHint / replacements / learnedReplacements into the store.
    // The conf keys are left in place but emptied so nothing reads them twice.
    static func migrateFromConfigIfNeeded() {
        guard Database.shared.meta("dictionary_migrated") == nil else { return }
        var cfg = Config.load()
        var n = 0
        for name in cfg.promptHint.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !name.isEmpty {
            add(word: name, starred: true); n += 1
        }
        for r in cfg.replacements where !r.from.isEmpty { add(word: r.from, replacement: r.to); n += 1 }
        for r in cfg.learnedReplacements ?? [] where !r.from.isEmpty { add(word: r.from, replacement: r.to, source: "learned"); n += 1 }
        cfg.promptHint = ""; cfg.replacements = []; cfg.learnedReplacements = []
        cfg.save()
        Database.shared.setMeta("dictionary_migrated", "\(Date().timeIntervalSince1970)")
        wlog("dictionary: migrated \(n) entries from ~/.sori.conf")
    }

    // ASR bias terms: starred first, then plain words, then correction targets, learned last.
    // Names first because no model can guess them; the AI glossary fills what is left of the cap.
    static func biasPrompt(cfg: Config) -> String {
        var terms: [String] = []
        let entries = all()
        terms += entries.filter { $0.starred }.map { $0.canonical }
        terms += entries.filter { !$0.starred && !$0.isCorrection }.map { $0.word }
        terms += entries.filter { !$0.starred && $0.isCorrection && $0.source == "manual" }.map { $0.replacement }
        if (cfg.aiTermsEnabled ?? true), let t = cfg.aiTerms?.trimmingCharacters(in: .whitespaces), !t.isEmpty {
            terms += t.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        var seen = Set<String>()
        terms = terms.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        guard !terms.isEmpty else { return "" }
        return "Vocabulary that may appear in the audio, spell these exactly: "
             + terms.prefix(Config.maxBiasTerms).joined(separator: ", ")
    }

    // Post-ASR pass: corrections replace, plain words canonicalize casing. Whole-word on LATIN
    // alphanumerics only (see Config.applyReplacements for why not \b).
    static func apply(_ text: String) -> String {
        var out = text
        for e in all() where !e.word.isEmpty {
            let pattern = "(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: e.word) + "(?![A-Za-z0-9])"
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let template = NSRegularExpression.escapedTemplate(for: e.canonical)
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }
        return out
    }

    private static func changed() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: Database.dictionaryChanged, object: nil) }
    }
}
