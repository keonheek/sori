import Cocoa
import AVFoundation
import CoreAudio
import Carbon.HIToolbox
import IOKit.hid

// Where the dictation is going: frontmost app + focused window title, read on the main
// thread when recording stops (that IS the target app). Drives Smart Rewrite's register.
struct AppContext {
    let bundleId: String
    let appName: String
    let windowTitle: String
    var fieldText: String = ""     // text already in the focused field before the caret (context awareness)
    // Paste target (2026-09-23): the app + focused field at the moment recording stopped. The
    // paste is async (1–3 s of ASR + rewrite); if he has moved to another app or field by then,
    // the pipeline brings THIS target back before ⌘V instead of pasting wherever he is now.
    var pid: pid_t = 0
    var focusedElement: AXUIElement? = nil
    var summary: String { "\(appName) [\(bundleId)]" + (windowTitle.isEmpty ? "" : " — \(windowTitle)") }

    static func capture() -> AppContext {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return AppContext(bundleId: "", appName: "", windowTitle: "")
        }
        var title = ""
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        var win: CFTypeRef?
        if AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString, &win) == .success, let w = win {
            var t: CFTypeRef?
            if AXUIElementCopyAttributeValue(w as! AXUIElement, kAXTitleAttribute as CFString, &t) == .success {
                title = (t as? String) ?? ""
            }
        }
        var ctx = AppContext(bundleId: app.bundleIdentifier ?? "", appName: app.localizedName ?? "", windowTitle: title)
        ctx.pid = app.processIdentifier
        ctx.focusedElement = focusedElement()
        if Config.load().contextAwareness ?? true, let el = ctx.focusedElement {
            ctx.fieldText = fieldTextBeforeCaret(el, cap: 1500)
        }
        return ctx
    }

    // The system-wide focused UI element (nil when nothing focusable has focus).
    static func focusedElement() -> AXUIElement? {
        let sys = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success, let f = focusedRef else { return nil }
        return (f as! AXUIElement)
    }

    // What is already typed in the field, up to the caret (Wispr's "context awareness"). Data for
    // register and continuation only — the rewrite prompt is told never to repeat or rewrite it.
    static func focusedFieldTextBeforeCaret(cap: Int) -> String {
        guard let el = focusedElement() else { return "" }
        return fieldTextBeforeCaret(el, cap: cap)
    }

    static func fieldTextBeforeCaret(_ el: AXUIElement, cap: Int) -> String {
        var valRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &valRef) == .success, let value = valRef as? String, !value.isEmpty else { return "" }
        var end = value.utf16.count
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success, let rv = rangeRef {
            var r = CFRange()
            if AXValueGetValue(rv as! AXValue, .cfRange, &r), r.location >= 0, r.location <= end { end = r.location }
        }
        let u = Array(value.utf16.prefix(end))
        let tail = u.suffix(cap)
        return String(utf16CodeUnits: Array(tail), count: tail.count).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum Kind: String { case chat, mail, docs, code, aiChat, general }
    var kind: Kind {
        let b = bundleId.lowercased(), t = windowTitle.lowercased(), n = appName.lowercased()
        let chat = ["kakao", "slack", "discord", "com.apple.mobilesms", "telegram", "whatsapp", "line", "messenger"]
        let mail = ["com.apple.mail", "outlook", "spark", "mimestream"]
        let docs = ["notion", "com.apple.iwork.pages", "microsoft.word", "hancom", "obsidian", "bear", "craft"]
        let code = ["vscode", "com.microsoft.vscode", "cursor", "xcode", "terminal", "iterm", "cmux", "warp", "ghostty", "jetbrains", "zed", "windsurf", "com.todesktop"]
        let ai = ["claude", "chatgpt", "openai", "gemini", "grok", "perplexity", "copilot"]
        if chat.contains(where: { b.contains($0) || n.contains($0) }) { return .chat }
        if mail.contains(where: { b.contains($0) }) || t.contains("gmail") || t.contains("mail") { return .mail }
        if code.contains(where: { b.contains($0) || n.contains($0) }) { return .code }
        if ai.contains(where: { b.contains($0) || n.contains($0) || t.contains($0) }) { return .aiChat }
        if docs.contains(where: { b.contains($0) || n.contains($0) }) || t.contains("google docs") || t.contains("- notion") { return .docs }
        return .general
    }
}
