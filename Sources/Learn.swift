import Foundation

// Learn-from-edits decision, pure so `--learn-test` can gate it. A correction is a short span the
// user re-spelled ("Cacaotalk" -> "KakaoTalk", "gun hee" -> "Keonhee"). Everything else is noise:
// punctuation/case-only edits, continuing to type in a terminal that repaints, or replacing the
// whole dictation. 2026-10-14: "Any loss function." -> "in a" and "is." -> "is" were learned from
// cmux repaints and would have been auto-applied forever.
enum Learn {
    static func correction(pasted: String, edited: String) -> (from: String, to: String)? {
        // Align from BOTH ends so an inserted/removed word doesn't shift every later token.
        let fa = pasted.split(separator: " ").map(String.init)
        let ta = edited.split(separator: " ").map(String.init)
        guard !fa.isEmpty, !ta.isEmpty, abs(fa.count - ta.count) <= 2 else { return nil }
        var i = 0
        while i < min(fa.count, ta.count), fa[i] == ta[i] { i += 1 }
        var j = 0
        while j < min(fa.count, ta.count) - i, fa[fa.count - 1 - j] == ta[ta.count - 1 - j] { j += 1 }
        let f = fa[i..<(fa.count - j)].joined(separator: " ")
        let t = ta[i..<(ta.count - j)].joined(separator: " ")
        // The differing span must be short (a word or two) — otherwise it's a rewrite.
        guard f.count >= 2, f.count <= 40, !t.isEmpty, t.count <= 40 else { return nil }
        guard f.split(separator: " ").count <= 3, t.split(separator: " ").count <= 3 else { return nil }
        // Replacing every word of a multi-word dictation is a rewrite, not a re-spelling.
        if i == 0, j == 0, fa.count > 1 { return nil }
        // Punctuation / spacing only, or just the first letter's case (sentence casing): nothing to
        // learn. A real casing fix inside the word ("Skku" -> "SKKU") is kept.
        let nf = letters(f), nt = letters(t)
        guard !nf.isEmpty, !nt.isEmpty else { return nil }
        let cf = Array(f.filter { $0.isLetter || $0.isNumber }), ct = Array(t.filter { $0.isLetter || $0.isNumber })
        if cf == ct { return nil }
        if nf == nt, cf.dropFirst().elementsEqual(ct.dropFirst()) { return nil }
        // A re-spelling stays close to what was heard; "any loss function" -> "in a" does not.
        let d = distance(nf, nt)
        guard d <= max(2, Int(Double(max(nf.count, nt.count)) * 0.6)) else { return nil }
        return (f, t)
    }

    // Terminals repaint their whole line as the user keeps typing; the AX value is not a text field.
    static let fieldWatchSkip: Set<String> = [
        "com.cmuxterm.app", "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "io.alacritty", "co.zeit.hyper",
    ]

    static func letters(_ s: String) -> [Character] {
        Array(s.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    static func distance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }; if b.isEmpty { return a.count }
        var prev = Array(0...b.count), cur = [Int](repeating: 0, count: b.count + 1)
        for x in 1...a.count {
            cur[0] = x
            for y in 1...b.count {
                cur[y] = min(prev[y] + 1, cur[y - 1] + 1, prev[y - 1] + (a[x - 1] == b[y - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    // (pasted, edited, should learn) — the 10-14 junk must be refused, his real fixes must pass.
    static let cases: [(String, String, Bool)] = [
        ("Any loss function.", "in a", false),
        ("I don't really understand what minimizing the loss is.", "I don't really understand what minimizing the loss is", false),
        ("Send it on Cacaotalk please.", "Send it on KakaoTalk please.", true),
        ("Ask gun hee about it.", "Ask Keonhee about it.", true),
        ("Render it with promotion today.", "Render it with Remotion today.", true),
        ("Open the worp tree now.", "Open the worktree now.", true),
        ("Hello there.", "hello there.", false),
        ("We met at Skku. yesterday", "We met at SKKU yesterday", true),
        ("Tell me about the k fold split.", "Tell me about the cross validation split.", false),
    ]

    static func selfTest() -> Bool {
        var ok = true
        for (p, e, want) in cases {
            let got = correction(pasted: p, edited: e)
            let pass = (got != nil) == want
            if !pass { ok = false }
            print("\(pass ? "ok  " : "FAIL") learn=\(got.map { "\"\($0.from)\" -> \"\($0.to)\"" } ?? "no") | \(p) => \(e)")
        }
        return ok
    }
}
