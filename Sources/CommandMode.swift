import Cocoa

// MARK: - Command Mode (Experimental): hold Right ⌘ + Right ⌥, say what to do with the selection
// "make this more concise" → the selected text is replaced by the edited version. No selection →
// an "ask Claude / search Google …" instruction opens the browser with the query; anything else is
// refused visibly (never pasted, never run).
enum CommandMode {
    // Selected text in the frontmost app via AX (nil when nothing is selected / unsupported field).
    static func selectedText() -> String? {
        let sys = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success, let f = focusedRef else { return nil }
        var selRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(f as! AXUIElement, kAXSelectedTextAttribute as CFString, &selRef) == .success,
              let s = selRef as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }

    enum Outcome { case replace(String), openURL(URL), refused(String) }

    static func run(instruction: String, selection: String?) -> Outcome {
        let inst = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !inst.isEmpty else { return .refused("Heard nothing") }
        if let sel = selection {
            guard let out = LLMCleanup.command(instruction: inst, selection: sel) else { return .refused("Couldn't apply that") }
            return .replace(out)
        }
        // No selection: only a web hand-off is allowed, and only when asked for by name.
        let lower = inst.lowercased()
        let prefixes: [(String, String)] = [
            ("ask claude", "https://claude.ai/new?q="), ("ask chatgpt", "https://chatgpt.com/?q="),
            ("ask perplexity", "https://www.perplexity.ai/search?q="), ("search google", "https://www.google.com/search?q="),
            ("google", "https://www.google.com/search?q="), ("search naver", "https://search.naver.com/search.naver?query="),
        ]
        for (p, base) in prefixes where lower.hasPrefix(p) {
            var q = String(inst.dropFirst(p.count)).trimmingCharacters(in: CharacterSet(charactersIn: " ,:.\"'"))
            if q.hasPrefix("for ") { q = String(q.dropFirst(4)) }
            guard !q.isEmpty, let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed), let url = URL(string: base + enc) else { break }
            return .openURL(url)
        }
        return .refused("Select text first, or say “ask Claude …”")
    }
}

extension LLMCleanup {
    // Edit `selection` per `instruction`. Output is ONLY the edited text; guarded like the rewrite:
    // no think block, sane length band, must differ from the instruction, no leaked tags.
    static func command(instruction: String, selection: String) -> String? {
        guard let key = apiKey(), !key.isEmpty else { return nil }
        guard let url = URL(string: "https://api.groq.com/openai/v1/chat/completions") else { return nil }
        let system = """
You are a text-editing FUNCTION. The user message has two parts: an <instruction> the speaker dictated and the <selection> they had highlighted. Apply the instruction to the selection and output ONLY the resulting text — the full replacement for the selection, nothing else: no preamble, no quotes, no tags, no explanation, no notes. Keep the selection's language unless the instruction says to translate. Keep formatting (line breaks, bullets, code) unless told otherwise. If the instruction cannot be applied to the selection, output the selection unchanged.
"""
        let user = "<instruction>\n\(instruction)\n</instruction>\n<selection>\n\(selection)\n</selection>"
        let body: [String: Any] = [
            "model": "qwen/qwen3.8-27b", "reasoning_effort": "none",
            "max_tokens": min(1000, max(256, selection.utf8.count / 2 + 128)), "temperature": 0.2,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
        ]
        var req = URLRequest(url: url); req.httpMethod = "POST"; req.timeoutInterval = 20
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let sem = DispatchSemaphore(value: 0)
        var out: String?
        let t0 = Date()
        URLSession.shared.dataTask(with: req) { data, _, err in
            defer { sem.signal() }
            guard let data, err == nil,
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            if let e = j["error"] as? [String: Any] { wlog("command API error: \(e["message"] ?? "?")"); return }
            out = ((j["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
        }.resume()
        _ = sem.wait(timeout: .now() + 22)
        guard var text = out?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if let r = text.range(of: "</think>") { text = String(text[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !text.contains("<selection>"), !text.contains("<instruction>"), !text.contains("<think>") else { wlog("command REJECTED: leaked tags"); return nil }
        guard text.lowercased() != instruction.lowercased() else { wlog("command REJECTED: echoed the instruction"); return nil }
        let ratio = Double(text.count) / Double(max(1, selection.count))
        // Translation and expansion legitimately grow; summaries shrink. Refuse only the absurd.
        guard ratio >= 0.05, ratio <= 6 else { wlog("command REJECTED: length ratio \(String(format: "%.2f", ratio))"); return nil }
        wlog(String(format: "command edit %.2fs (%d -> %d chars)", Date().timeIntervalSince(t0), selection.count, text.count))
        return text
    }
}
