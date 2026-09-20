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
        return AppContext(bundleId: app.bundleIdentifier ?? "", appName: app.localizedName ?? "", windowTitle: title)
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
