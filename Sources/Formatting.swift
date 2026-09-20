import Foundation

// MARK: - Spoken formatting commands: "new line", "new paragraph", "scratch that" (EN + KO)
// Applied to the RAW transcript before cleanup/rewrite so the LLM never sees the command words.
// Segments between commands are cleaned and rewritten separately and re-joined with the breaks.
enum Formatting {
    enum Piece { case text(String), br(String) }

    private static let breaks: [(String, String)] = [
        ("new paragraph", "\n\n"), ("next paragraph", "\n\n"), ("새 문단", "\n\n"), ("문단 바꿈", "\n\n"),
        ("new line", "\n"), ("newline", "\n"), ("next line", "\n"), ("line break", "\n"),
        ("줄바꿈", "\n"), ("줄 바꿈", "\n"), ("다음 줄", "\n"),
    ]
    private static let scratch = ["scratch that", "delete that", "strike that", "undo that", "방금 지워", "방금 거 지워", "그거 지워", "취소 취소"]

    static func hasCommands(_ text: String) -> Bool {
        let l = text.lowercased()
        return breaks.contains { l.contains($0.0) } || scratch.contains { l.contains($0) }
    }

    // Split on command phrases; "scratch that" drops the last sentence of the piece before it.
    static func parse(_ text: String) -> [Piece] {
        var pattern = "(?i)\\b(?:" + (breaks.map { $0.0 } + scratch).map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|") + ")\\b"
        // Korean has no \b at Hangul boundaries; allow the phrase to be glued to punctuation/space instead.
        pattern = pattern.replacingOccurrences(of: "\\b(?:", with: "(?<![A-Za-z])(?:").replacingOccurrences(of: ")\\b", with: ")(?![A-Za-z])")
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [.text(text)] }
        var pieces: [Piece] = []
        var cursor = text.startIndex
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let r = Range(m.range, in: text) else { continue }
            let before = String(text[cursor..<r.lowerBound])
            let cmd = text[r].lowercased()
            if scratch.contains(where: { cmd.contains($0) }) {
                var kept = before
                // Drop the last sentence-ish chunk of what was said before the command.
                if let last = kept.range(of: "[.!?。]\\s+[^.!?。]*$", options: .regularExpression) {
                    kept = String(kept[..<last.lowerBound]) + String(kept[last.lowerBound]).trimmingCharacters(in: .whitespaces)
                } else if case .text(let prev)? = pieces.last, !prev.isEmpty, kept.trimmingCharacters(in: .whitespaces).isEmpty {
                    pieces.removeLast(); kept = ""
                } else {
                    kept = ""
                }
                pieces.append(.text(kept))
            } else {
                pieces.append(.text(before))
                pieces.append(.br(breaks.first { cmd.contains($0.0) }?.1 ?? "\n"))
            }
            cursor = r.upperBound
        }
        pieces.append(.text(String(text[cursor...])))
        // Trim each cut (the ASR punctuates the command itself: "New paragraph." / ", new line"),
        // then merge adjacent text pieces and drop empties.
        func tidy(_ t: String) -> String {
            var s = t.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",")))
            while let f = s.first, ".,!?;:、。".contains(f) { s.removeFirst() }
            s = s.trimmingCharacters(in: .whitespaces)
            if let f = s.first, f.isLowercase, f.isLetter { s = f.uppercased() + s.dropFirst() }
            return s
        }
        var out: [Piece] = []
        for p in pieces {
            switch p {
            case .text(let raw):
                let a = tidy(raw)
                guard !a.isEmpty else { continue }
                if case .text(let b)? = out.last { out[out.count - 1] = .text(b + " " + a) } else { out.append(.text(a)) }
            case .br: out.append(p)
            }
        }
        return out
    }

    // Join processed text pieces with their breaks; a break with no text after it is dropped.
    static func join(_ pieces: [Piece]) -> String {
        var out = ""
        var pendingBreak: String? = nil
        for p in pieces {
            switch p {
            case .br(let b): pendingBreak = (pendingBreak ?? "").count >= b.count ? pendingBreak : b
            case .text(let t):
                if !out.isEmpty { out += pendingBreak ?? " " }
                pendingBreak = nil
                out += t
            }
        }
        return out
    }
}
