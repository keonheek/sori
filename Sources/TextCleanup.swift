import Cocoa
import AVFoundation
import CoreAudio
import Carbon.HIToolbox
import IOKit.hid

// MARK: - Wispr-Flow-style text cleanup (rule-based, local, instant)
enum TextCleanup {
    // Filler words / disfluencies to strip when they stand alone.
    // ONLY pure disfluencies. "like", "actually", "i mean", "sort of" etc. were here
    // before and silently ATE legitimate words ("I like this" -> "I this").
    static let fillers = ["um","uh","umm","uhh","er","erm","ah"]

    static func clean(_ input: String) -> String {
        var t = input

        // 1) Remove standalone filler words. Consume separators on BOTH sides and
        //    rejoin with one space — the old trailing-only pattern left dangling
        //    commas behind ("I want, um, to go" -> "I want, to go").
        for f in fillers {
            let pat = "(?i)[ ,]*\\b" + NSRegularExpression.escapedPattern(for: f) + "\\b[ ,]*"
            if let re = try? NSRegularExpression(pattern: pat) {
                t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: " ")
            }
        }

        // 2) [REMOVED] Self-correction cue stripping ("no wait", "scratch that", ...).
        //    It destroyed legitimate sentences ("There is no wait at the restaurant" ->
        //    "At the restaurant") while MISSING real corrections, because whisper
        //    punctuates them as "no, wait," which the literal cue never matched.
        //    Net-negative feature; corrections are the user's edit to make.

        // 3) Collapse immediate duplicate words ("the the" -> "the").
        if let re = try? NSRegularExpression(pattern: "(?i)\\b(\\w+)(\\s+\\1\\b)+") {
            t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "$1")
        }

        // 4) Normalize whitespace + spacing before punctuation.
        if let re = try? NSRegularExpression(pattern: "\\s{2,}") {
            t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: " ")
        }
        if let re = try? NSRegularExpression(pattern: "\\s+([.,;!?])") {
            t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "$1")
        }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)

        // 5) Capitalize first letter.
        if let first = t.first, first.isLowercase {
            t = first.uppercased() + t.dropFirst()
        }

        // 6) Terminal punctuation: whisper sometimes drops the final period on longer
        //    dictation. Only when it clearly reads as a sentence (4+ words) and ends
        //    bare — never touches short fragments meant for mid-sentence insertion.
        if t.count >= 20, t.split(separator: " ").count >= 4, let last = t.last,
           last.isLetter || last.isNumber {
            t += "."
        }
        return t
    }

    // Hallucination repetition loop: on long recordings the decoder can lock onto one
    // sentence and emit it over and over, generating from its language prior instead of
    // the audio (observed live 2026-08-10: "한 번 더 확인해 주실 수 있을 것 같습니다." ×9,
    // in 습니다체 the speaker never used — register drift is part of the same failure).
    // Beam search (-bs 5) reduced but did not eliminate this. A sentence repeated 3+
    // times VERBATIM is never real dictation; keep one copy. Word-level stutter
    // ("Monday, Monday, Monday") is separate — clean() rule 3 handles it. Runs on every
    // final transcript regardless of cleanupEnabled: this is a decode-failure guard,
    // not style cleanup.
    static func collapseRepetitionLoop(_ input: String) -> String {
        let terminators: Set<Character> = [".", "!", "?", "…"]
        // Split into sentence chunks, each keeping its terminator run + trailing space,
        // so joined() reconstructs the text byte-for-byte when nothing collapses.
        var chunks: [Substring] = []
        var start = input.startIndex
        var i = input.startIndex
        while i < input.endIndex {
            if terminators.contains(input[i]) {
                var j = input.index(after: i)
                while j < input.endIndex, terminators.contains(input[j]) { j = input.index(after: j) }
                while j < input.endIndex, input[j].isWhitespace { j = input.index(after: j) }
                chunks.append(input[start..<j])
                start = j; i = j
            } else {
                i = input.index(after: i)
            }
        }
        if start < input.endIndex { chunks.append(input[start...]) }
        guard chunks.count >= 3 else { return input }

        func norm(_ s: Substring) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        var out: [Substring] = []
        var idx = 0
        while idx < chunks.count {
            var runEnd = idx + 1
            while runEnd < chunks.count, norm(chunks[runEnd]) == norm(chunks[idx]) { runEnd += 1 }
            if runEnd - idx >= 3 {
                wlog("repetition loop collapsed: \(runEnd - idx)x \"\(norm(chunks[idx]).prefix(50))\"")
                out.append(chunks[idx])
            } else {
                out.append(contentsOf: chunks[idx..<runEnd])
            }
            idx = runEnd
        }
        return out.joined()
    }
}
