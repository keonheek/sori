import Cocoa

// Screen vocabulary (Wispr's "dynamic vocab": screen_ax / variable_names / file_names, ≤50 each).
// At key-down Sori reads the visible text of the focused window through Accessibility, keeps the
// words a speech model cannot guess (camelCase, ACRONYMS, file names, mixed letters+digits, names
// not in the English word list) and hands them to gpt-live-transcribe as `keywords`. Read-only,
// time-boxed, off the main thread; an app that answers slowly just contributes fewer words.
enum ScreenVocab {
    struct Harvest { var texts: [String] = []; var title = ""; var nodes = 0; var chars = 0; var ms = 0 }

    // Walk the focused window of `pid` breadth-first, collecting string values, titles and
    // descriptions until the node, character or time budget runs out.
    static func harvest(pid: pid_t, budgetMs: Int = 150, maxNodes: Int = 4000, maxChars: Int = 60_000) -> Harvest {
        let t0 = Date()
        var h = Harvest()
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &winRef) == .success, let w = winRef else { return h }
        let win = w as! AXUIElement
        h.title = string(win, kAXTitleAttribute) ?? ""
        var queue: [AXUIElement] = [win]
        var head = 0
        let deadline = t0.addingTimeInterval(Double(budgetMs) / 1000)
        while head < queue.count, h.nodes < maxNodes, h.chars < maxChars, Date() < deadline {
            let el = queue[head]; head += 1; h.nodes += 1
            for attr in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                if let s = string(el, attr), !s.isEmpty {
                    let cut = String(s.suffix(20_000))   // a terminal's value is its whole scrollback: keep the recent end
                    h.texts.append(cut); h.chars += cut.count
                }
            }
            var kids: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids) == .success, let arr = kids as? [AXUIElement] {
                queue.append(contentsOf: arr.prefix(400))
            }
        }
        h.ms = Int(Date().timeIntervalSince(t0) * 1000)
        return h
    }

    private static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }

    // MARK: ranking (pure, gated by --vocab-test)

    static let common: Set<String> = {
        guard let s = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else { return [] }
        return Set(s.split(separator: "\n").filter { $0.first?.isLowercase == true }.map(String.init))
    }()

    // UI chrome and words the word list lacks in this form; never worth a keyword.
    static let stop: Set<String> = ["http", "https", "www", "com", "html", "null", "true", "false", "nil", "self", "todo",
                                    "the", "and", "for", "you", "with", "this", "that", "from", "are", "was", "okay", "ok"]

    // The 1934 word list lacks modern words (inbox, sidebar, download), so anything it misses is
    // asked of the system spell checker in LOWERCASE: "sidebar" passes, "keonhee"/"baseten"/"roland"
    // do not, which keeps names and drops UI chrome. Cached; the checker only runs on the main thread.
    private static var spellCache: [String: Bool] = [:]
    private static let spellLock = NSLock()

    static func isCommon(_ w: String) -> Bool {
        let l = w.lowercased()
        if common.contains(l) || stop.contains(l) { return true }
        for suf in ["s", "es", "ed", "d", "ing", "ly", "er", "ers", "'s"] where l.hasSuffix(suf) && l.count > suf.count + 2 {
            let base = String(l.dropLast(suf.count))
            if common.contains(base) || common.contains(base + "e") { return true }
        }
        spellLock.lock(); let cached = spellCache[l]; spellLock.unlock()
        if let cached { return cached }
        let check = { () -> Bool in
            NSSpellChecker.shared.checkSpelling(of: l, startingAt: 0, language: "en", wrap: false,
                                                inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
        }
        let known = Thread.isMainThread ? check() : DispatchQueue.main.sync(execute: check)
        spellLock.lock(); spellCache[l] = known; spellLock.unlock()
        return known
    }

    static func preload() { DispatchQueue.global(qos: .utility).async { _ = common.count } }

    // 3 = shape no model guesses (camelCase, ACRONYM, file.ext, letters+digits, snake_case);
    // 2 = Capitalized word not in the English list (a name); 1 = other unlisted lowercase word; 0 = skip.
    static func weight(_ t: String) -> Int {
        guard t.count >= 3, t.count <= 40, t.first!.isLetter else { return 0 }
        guard t.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_.-+".contains($0)) }) else { return 0 }
        let digits = t.filter(\.isNumber).count
        if digits >= 5 { return 0 }                                              // ids, timestamps
        if t.count >= 7, digits >= 2, t.allSatisfy({ $0.isHexDigit }) { return 0 } // hashes
        let letters = t.filter(\.isLetter)
        let lower = t.lowercased()
        if lower.hasPrefix("http") || lower.hasPrefix("www.") { return 0 }
        if let dot = t.lastIndex(of: "."), dot != t.startIndex {
            let ext = t[t.index(after: dot)...]
            if (1...5).contains(ext.count), ext.allSatisfy({ $0.isLowercase }), !["com", "net", "org", "io", "ai", "kr", "co"].contains(String(ext)) { return 3 }
            if !ext.isEmpty, ext.allSatisfy(\.isNumber), t[..<dot].last?.isNumber == true { return letters.count >= 2 ? 3 : 0 } // Qwen3.6
            return 0                                                               // "end.Next", domains, member chains (split by tokens())
        }
        if t.contains("_") { return 3 }
        if digits > 0 { return letters.count >= 2 && t.range(of: "[A-Z]{5,}", options: .regularExpression) == nil && t.count <= 24 ? 3 : 0 }
        let caps = letters.filter(\.isUppercase).count
        // base64 / minified noise: long uppercase runs inside a mixed-case token ("tcwAAAAASUVORK5CYII").
        if caps != letters.count, t.count > 24 || t.range(of: "[A-Z]{5,}", options: .regularExpression) != nil { return 0 }
        if caps == letters.count { return letters.count >= 3 && letters.count <= 8 && !isCommon(t) ? 3 : 0 }
        if caps >= 2 || (caps == 1 && !t.first!.isUppercase) { return isCommon(t) ? 0 : 3 } // OpenAIRealtime, iPhone
        if t.contains("-") { return 0 }
        if t.first!.isUppercase { return isCommon(t) ? 0 : 2 }
        return isCommon(t) ? 0 : 1
    }

    static func tokens(_ s: String) -> [String] {
        s.components(separatedBy: CharacterSet(charactersIn: " \t\n\r,;:()[]{}<>\"'`/\\|=!?*&^%$@~").union(.controlCharacters))
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".-+")) }
            .flatMap { t -> [String] in
                // "cfg.asrCloudModel" is a member chain, not a file: score its parts. Files and versions stay whole.
                guard t.contains("."), weight(t) == 0 else { return [t] }
                return t.split(separator: ".").map(String.init)
            }
            .filter { !$0.isEmpty }
    }

    // Best `limit` terms: weight × log-frequency, title words doubled; skips anything already known.
    static func rank(texts: [String], title: String = "", known: Set<String> = [], limit: Int = 30) -> [String] {
        var score: [String: Double] = [:], count: [String: Int] = [:], shape: [String: Int] = [:]
        var spelling: [String: String] = [:]
        for (s, boost) in texts.map({ ($0, 1.0) }) + [(title, 2.0)] {
            for t in tokens(s) {
                let w = weight(t); guard w > 0 else { continue }
                let k = t.lowercased(); guard !known.contains(k) else { continue }
                count[k, default: 0] += 1; shape[k] = max(shape[k] ?? 0, w)
                score[k, default: 0] += boost
                if spelling[k] == nil || (t != t.lowercased() && spelling[k] == spelling[k]!.lowercased()) { spelling[k] = t }
            }
        }
        // A plain unlisted lowercase word needs to recur; once is usually a typo or a code fragment.
        return score.compactMap { k, v -> (String, Double)? in
            let w = shape[k]!; if w == 1 && count[k]! < 3 { return nil }
            return (spelling[k]!, Double(w) * (1 + log(v)))
        }
        .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        .prefix(limit).map(\.0)
    }

    // Keywords must be one line without < or > or the whole session update is rejected.
    static func safe(_ t: String) -> Bool { !t.isEmpty && t.count <= 60 && !t.contains(where: { "<>\r\n".contains($0) }) }

    static let cases: [(String, [String], [String])] = [   // (screen text, must contain, must not contain)
        ("let stream = OpenAIRealtime(model: cfg.asrCloudModel) // see deploy.sh and Learn.swift",
         ["OpenAIRealtime", "asrCloudModel", "deploy.sh", "Learn.swift"], ["let", "stream", "model", "see", "and"]),
        ("Keonhee said the SKKU deck for NextPay is done. Settings General Edit View Window Help",
         ["Keonhee", "SKKU", "NextPay"], ["Settings", "General", "Edit", "View", "Window", "Help", "said", "deck"]),
        ("Qwen3.6 beats gpt-4o on the bench; commit 3eee81e8 at https://github.com/x 1791976363710.wav",
         ["Qwen3.6", "gpt-4o"], ["3eee81e8", "https", "github.com", "1791976363710.wav"]),
        ("running running Running tests passed. The end.Next one",
         [], ["running", "Running", "tests", "passed", "The", "end.Next"]),
        ("<script> a<b c>d MCP MCP", ["MCP"], ["<script>", "a<b"]),
        ("Inbox Sidebar Download Workspace Has Roland Baseten tcwAAAAASUVORK5CYII Groq", ["Roland", "Baseten", "Groq"],
         ["Inbox", "Sidebar", "Download", "Workspace", "Has", "tcwAAAAASUVORK5CYII"]),
    ]

    static func selfTest() -> Bool {
        var ok = true
        for (text, want, not) in cases {
            let got = rank(texts: [text], limit: 30)
            let lower = Set(got.map { $0.lowercased() })
            let miss = want.filter { !lower.contains($0.lowercased()) }
            let extra = not.filter { lower.contains($0.lowercased()) }
            let unsafe = got.filter { !safe($0) }
            let pass = miss.isEmpty && extra.isEmpty && unsafe.isEmpty
            if !pass { ok = false }
            print("\(pass ? "ok  " : "FAIL") \(got.joined(separator: " | "))\(miss.isEmpty ? "" : "  missing \(miss)")\(extra.isEmpty ? "" : "  unwanted \(extra)")")
        }
        return ok
    }
}
