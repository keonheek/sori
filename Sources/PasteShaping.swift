import Cocoa

// Cursor-context paste shaping, ported from Wispr Flow's matchCasingSpacingAndPunctuation
// (static teardown of 1.6.1147, 2026-10-14). Deterministic, zero latency, applied to the final
// text right before ⌘V, and only when the focused field was actually readable — a terminal's AX
// value is its scrollback, so terminals keep the old recency spacing rule.
enum PasteShaping {
    struct Field { var before: String; var after: String }

    static func isCJK(_ c: Character) -> Bool {
        c.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3040...0x30FF).contains($0.value) || (0x3000...0x303F).contains($0.value) }
    }
    static func isLatinAlnum(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber) }

    // Wispr's Se(): the line before the caret ends a word (skipping dashes, brackets, closing quotes).
    static func continuesSentence(_ lineBefore: String) -> Bool {
        let skip = Set("—–-/:;,()[]{}\"'”’ \t")
        guard let last = lineBefore.last(where: { !skip.contains($0) }) else { return false }
        return isLatinAlnum(last)
    }

    // A capital that must survive lowercasing: I/I'm, ACRONYMS, iPhone-style, his names, words the
    // spell checker only knows capitalized (Claude, Seoul).
    static func keepsCapital(_ word: String, names: Set<String>) -> Bool {
        let w = word.trimmingCharacters(in: .punctuationCharacters)
        guard let f = w.first, f.isUppercase else { return true }
        if w == "I" || w.hasPrefix("I'") || w.hasPrefix("I’") { return true }
        if w.dropFirst().contains(where: { $0.isUppercase }) { return true }
        if names.contains(w.lowercased()) || ScreenVocab.proper.contains(w) { return true }
        // Not an English word at all (Baseten, Keonhee): a name. Known lowercase words get lowercased.
        return !ScreenVocab.common.contains(w.lowercased()) && !ScreenVocab.isCommon(w)
    }

    static func shape(_ text: String, field: Field?, chat: Bool, names: Set<String>) -> String {
        guard let field, !text.isEmpty else { return text }
        var t = text
        let lineBefore = field.before.components(separatedBy: "\n").last ?? ""
        let lineAfter = field.after.components(separatedBy: "\n").first ?? ""
        // Mid-sentence: lowercase the first letter unless it is a name.
        if continuesSentence(lineBefore), let first = t.split(separator: " ").first, !keepsCapital(String(first), names: names) {
            t = t.prefix(1).lowercased() + t.dropFirst()
        }
        // Text after the caret continues: drop our sentence end.
        if let a = lineAfter.first, (a.isLetter && a.isLowercase) || ",.:;!?%>".contains(a),
           let last = t.last, ".!?".contains(last), !t.hasSuffix("..") {
            t.removeLast()
        }
        // Chat (KakaoTalk etc.): a short message with no sentence end in the field loses its final period.
        if chat, !field.before.contains(where: { ".!?".contains($0) }), t.hasSuffix("."), !t.hasSuffix(".."),
           t.filter({ ".!?".contains($0) }).count <= 2 {
            t.removeLast()
        }
        // Spacing against the neighbours. Hangul separates words with spaces; Han/Kana do not.
        if let b = lineBefore.last, !b.isWhitespace, !isCJK(b), b.isLetter || b.isNumber || "!%),.:;>?]}".contains(b),
           let f = t.first, f.isLetter || f.isNumber {
            t = " " + t
        }
        if let a = lineAfter.first, a.isLetter || a.isNumber, let l = t.last, !l.isWhitespace, !isCJK(l) {
            t += " "
        }
        return t
    }

    // Claude Code collapses a paste with 3+ newlines or over ~600 chars into a "[Pasted text]" stub he
    // cannot read or edit; Wispr splits such pastes for terminals (chunks ≤600 chars, ≤2 newlines).
    // Splits prefer a sentence end, then a space.
    static func chunks(_ text: String, maxChars: Int = 600, maxNewlines: Int = 2) -> [String] {
        let nl = text.filter { $0 == "\n" }.count
        guard text.count > maxChars || nl >= 3 else { return [text] }
        var out: [String] = [], rest = Substring(text)
        while !rest.isEmpty {
            var cut = rest.endIndex, n = 0, count = 0
            var i = rest.startIndex
            while i < rest.endIndex {
                if rest[i] == "\n" { n += 1; if n > maxNewlines { cut = i; break } }
                count += 1
                if count > maxChars { cut = i; break }
                i = rest.index(after: i)
            }
            if cut < rest.endIndex, rest[cut] != "\n" {
                let window = rest[rest.startIndex..<cut]
                if let s = window.lastIndex(where: { ".!?。".contains($0) }), window.distance(from: window.startIndex, to: s) > maxChars / 3 {
                    cut = rest.index(after: s)
                } else if let sp = window.lastIndex(of: " "), sp > window.startIndex {
                    cut = rest.index(after: sp)
                }
            }
            out.append(String(rest[rest.startIndex..<cut]))
            rest = rest[cut...]
        }
        return out
    }

    static let cases: [(String, Field?, Bool, String)] = [   // (text, field, chat, expected)
        ("Then we ship it.", Field(before: "I think we test first and", after: ""), false, " then we ship it."),
        ("Claude can do it.", Field(before: "so", after: ""), false, " Claude can do it."),
        ("Seoul is cold.", Field(before: "and", after: ""), false, " Seoul is cold."),
        ("Baseten hosts it.", Field(before: "and", after: ""), false, " Baseten hosts it."),
        ("Also the deck.", Field(before: "the memo,", after: ""), false, " also the deck."),
        ("I'll check.", Field(before: "ok and", after: ""), false, " I'll check."),
        ("SKKU deck is done.", Field(before: "the", after: ""), false, " SKKU deck is done."),
        ("New point here.", Field(before: "First point.", after: ""), false, " New point here."),
        ("Hello there.", Field(before: "", after: ""), false, "Hello there."),
        ("Hello there.", Field(before: "First point.\n", after: ""), false, "Hello there."),
        ("the red one.", Field(before: "I want ", after: "and the blue one"), false, "the red one "),
        ("Sounds good.", Field(before: "", after: ""), true, "Sounds good"),
        ("Sounds good.", Field(before: "Done. ", after: ""), true, "Sounds good."),
        ("오늘 회의는 3시예요.", Field(before: "", after: ""), true, "오늘 회의는 3시예요"),
        ("Then it works.", Field(before: "확인했어요", after: ""), false, " Then it works."),
        ("Then it works.", Field(before: "日本語", after: ""), false, "Then it works."),
        ("Then it works.", nil, false, "Then it works."),
    ]

    static func selfTest() -> Bool {
        var ok = true
        for (text, field, chat, want) in cases {
            let got = shape(text, field: field, chat: chat, names: ["keonhee"])
            if got != want { ok = false }
            print("\(got == want ? "ok  " : "FAIL") [\(got)]\(got == want ? "" : " want [\(want)]")")
        }
        let long = (0..<30).map { "Sentence number \($0) is here." }.joined(separator: " ")
        let parts = chunks(long)
        let joinedOK = parts.joined() == long && parts.allSatisfy { $0.count <= 600 } && parts.count == 2
        let lines = chunks("a\nb\nc\nd\ne")
        let linesOK = lines.joined() == "a\nb\nc\nd\ne" && lines.allSatisfy { $0.filter { $0 == "\n" }.count <= 2 }
        let shortOK = chunks("short one") == ["short one"]
        for (n, p) in [("chunks long", joinedOK), ("chunks newlines", linesOK), ("chunks short", shortOK)] {
            if !p { ok = false }; print("\(p ? "ok  " : "FAIL") \(n) \(n == "chunks long" ? parts.map(\.count).description : "")")
        }
        return ok
    }
}
