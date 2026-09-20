import Foundation

// MARK: - Style: tone + cleanup level per destination category (Wispr-style), with per-app overrides
enum StyleCategory: String, CaseIterable, Identifiable {
    case personal, work, email, other
    var id: String { rawValue }
    var title: String {
        switch self { case .personal: return "Personal messages"; case .work: return "Work messages"; case .email: return "Email"; case .other: return "Other" }
    }
    var subtitle: String {
        switch self {
        case .personal: return "Chat apps: KakaoTalk, Messages, Slack DMs"
        case .work: return "Editors, terminals, AI assistants, docs"
        case .email: return "Mail clients and Gmail in the browser"
        case .other: return "Everything else"
        }
    }
    // Default mapping from the app kind the pipeline already detects.
    static func from(kind: AppContext.Kind) -> StyleCategory {
        switch kind {
        case .chat: return .personal
        case .mail: return .email
        case .docs, .code, .aiChat: return .work
        case .general: return .other
        }
    }
}

enum Tone: String, CaseIterable, Identifiable {
    case veryCasual, casual, neutral, formal
    var id: String { rawValue }
    var title: String {
        switch self { case .veryCasual: return "Very casual"; case .casual: return "Casual"; case .neutral: return "Neutral"; case .formal: return "Formal" }
    }
    // Appended to the Smart Rewrite register block. Never changes meaning, language, or 존댓말/반말.
    var promptClause: String {
        switch self {
        case .veryCasual: return "Tone: very casual — keep contractions, relaxed punctuation, lowercase-friendly; never add formality the speaker did not use."
        case .casual: return "Tone: casual — natural spoken phrasing, light punctuation, no stiff constructions."
        case .neutral: return "Tone: neutral — clean standard sentences, neither chatty nor stiff."
        case .formal: return "Tone: formal — complete sentences, precise punctuation, no slang or contractions where a formal equivalent reads naturally; keep 존댓말 as spoken and never invent honorifics."
        }
    }
}

enum CleanupLevel: String, CaseIterable, Identifiable {
    case none, light, medium, high
    var id: String { rawValue }
    var title: String {
        switch self { case .none: return "None"; case .light: return "Light"; case .medium: return "Medium"; case .high: return "High" }
    }
    var detail: String {
        switch self {
        case .none: return "Exactly what was heard. Dictionary corrections still apply."
        case .light: return "Rule-based: fillers stripped, punctuation tidied. Instant, offline."
        case .medium: return "Light plus an LLM pass that only deletes fillers and stutters."
        case .high: return "Smart Rewrite: grammar, punctuation and phrasing for the destination app."
        }
    }
}

struct StyleSetting: Codable, Equatable {
    var tone: String
    var level: String
    var toneValue: Tone { Tone(rawValue: tone) ?? .neutral }
    var levelValue: CleanupLevel { CleanupLevel(rawValue: level) ?? .high }
}

enum StyleResolver {
    // Defaults reproduce what the flags did before categories existed (2026-09-20): Smart
    // Rewrite on = High everywhere; otherwise Medium (deletion-only LLM) or Light.
    static func defaultSetting(cfg: Config, category: StyleCategory) -> StyleSetting {
        let level: CleanupLevel = (cfg.smartRewrite ?? false) ? .high : ((cfg.llmCleanup ?? false) ? .medium : ((cfg.cleanupEnabled ?? true) ? .light : .none))
        let tone: Tone = category == .personal ? .casual : .neutral
        return StyleSetting(tone: tone.rawValue, level: level.rawValue)
    }
    static func setting(cfg: Config, category: StyleCategory) -> StyleSetting {
        cfg.styles?[category.rawValue] ?? defaultSetting(cfg: cfg, category: category)
    }
    static func category(for ctx: AppContext) -> StyleCategory {
        if let o = AppStyleRepo.override(bundleId: ctx.bundleId) { return o }
        return StyleCategory.from(kind: ctx.kind)
    }
}

// Per-app category overrides (app_styles table) + the apps seen in the history for the picker.
enum AppStyleRepo {
    struct SeenApp: Identifiable, Hashable { let bundleId: String; let name: String; var id: String { bundleId } }
    struct Override: Identifiable, Hashable { let bundleId: String; let name: String; let category: StyleCategory; var id: String { bundleId } }

    static func override(bundleId: String) -> StyleCategory? {
        guard !bundleId.isEmpty else { return nil }
        return Database.shared.query("SELECT category FROM app_styles WHERE bundle_id=?", [.text(bundleId)]).first
            .flatMap { StyleCategory(rawValue: $0.text("category")) }
    }
    static func set(bundleId: String, category: StyleCategory) {
        Database.shared.run("INSERT INTO app_styles(bundle_id,category) VALUES(?,?) ON CONFLICT(bundle_id) DO UPDATE SET category=excluded.category",
                            [.text(bundleId), .text(category.rawValue)])
        changed()
    }
    static func remove(bundleId: String) { Database.shared.run("DELETE FROM app_styles WHERE bundle_id=?", [.text(bundleId)]); changed() }
    static func overrides() -> [Override] {
        Database.shared.query("""
            SELECT a.bundle_id, a.category, COALESCE((SELECT app_name FROM dictations d WHERE d.bundle_id=a.bundle_id AND app_name<>'' ORDER BY ts DESC LIMIT 1), a.bundle_id) AS name
            FROM app_styles a ORDER BY name
            """).compactMap { r in StyleCategory(rawValue: r.text("category")).map { Override(bundleId: r.text("bundle_id"), name: r.text("name"), category: $0) } }
    }
    static func seenApps() -> [SeenApp] {
        Database.shared.query("SELECT bundle_id, MAX(app_name) AS name, COUNT(*) AS c FROM dictations WHERE bundle_id<>'' GROUP BY bundle_id ORDER BY c DESC LIMIT 40")
            .map { SeenApp(bundleId: $0.text("bundle_id"), name: $0.text("name")) }
    }
    static let changedNote = Notification.Name("sori.appStylesChanged")
    private static func changed() { DispatchQueue.main.async { NotificationCenter.default.post(name: changedNote, object: nil) } }
}
