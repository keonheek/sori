import Foundation

// MARK: - Snippets: a spoken trigger phrase expands to a block of text (≤ 4,000 chars)
struct Snippet: Identifiable, Hashable {
    let id: Int64
    var trigger: String
    var expansion: String
    let createdTs: Date
    static func from(_ r: Database.Row) -> Snippet {
        Snippet(id: r.int("id"), trigger: r.text("trigger"), expansion: r.text("expansion"),
                createdTs: Date(timeIntervalSince1970: r.real("created_ts")))
    }
}

enum SnippetRepo {
    static let maxExpansion = 4000

    static func all() -> [Snippet] {
        Database.shared.query("SELECT * FROM snippets ORDER BY lower(trigger) ASC").map(Snippet.from)
    }

    @discardableResult
    static func add(trigger: String, expansion: String) -> Int64 {
        let t = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !expansion.isEmpty else { return -1 }
        let id = Database.shared.run("""
            INSERT INTO snippets(trigger,expansion,created_ts) VALUES(?,?,?)
            ON CONFLICT(trigger) DO UPDATE SET expansion=excluded.expansion
            """, [.text(t), .text(String(expansion.prefix(maxExpansion))), .real(Date().timeIntervalSince1970)])
        changed(); return id
    }

    static func update(_ s: Snippet) {
        Database.shared.run("UPDATE snippets SET trigger=?, expansion=? WHERE id=?",
                            [.text(s.trigger.trimmingCharacters(in: .whitespacesAndNewlines)),
                             .text(String(s.expansion.prefix(maxExpansion))), .int(s.id)])
        changed()
    }

    static func delete(_ id: Int64) { Database.shared.run("DELETE FROM snippets WHERE id=?", [.int(id)]); changed() }

    // Normalized (lowercase, punctuation stripped, whitespace collapsed) word list.
    static func words(_ s: String) -> [String] {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted).joined()
            .split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    // The dictation begins with a trigger phrase → expansion replaces it, the rest of the
    // dictation follows on the same line. Longest trigger wins. Nil when nothing matches.
    static func expand(_ text: String) -> (text: String, trigger: String)? {
        let tw = words(text)
        guard !tw.isEmpty else { return nil }
        let candidates = all().map { ($0, words($0.trigger)) }
            .filter { !$0.1.isEmpty && $0.1.count <= tw.count && Array(tw.prefix($0.1.count)) == $0.1 }
            .sorted { $0.1.count > $1.1.count }
        guard let (snip, trigWords) = candidates.first else { return nil }
        // Remainder = the original words after the trigger's word count (keeps their punctuation).
        let originalWords = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let rest = originalWords.dropFirst(trigWords.count).joined(separator: " ")
        let out = rest.isEmpty ? snip.expansion : snip.expansion + " " + rest
        return (out, snip.trigger)
    }

    private static func changed() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: Database.snippetsChanged, object: nil) }
    }
}
