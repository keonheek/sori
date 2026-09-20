import SwiftUI
import Combine

// MARK: - Hub view model: one observable object, refreshed from the store on change notifications
final class HubModel: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case home = "Home"
        case dictionary = "Dictionary"
        case snippets = "Snippets"
        case style = "Style"
        case settings = "Settings"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .home: return "house"; case .dictionary: return "character.book.closed"
            case .snippets: return "text.insert"; case .style: return "slider.horizontal.3"
            case .settings: return "gearshape"
            }
        }
    }

    @Published var section: Section = .home
    @Published var query: String = "" { didSet { reloadRows() } }
    @Published var rows: [Dictation] = []
    @Published var stats = DictationStats()
    @Published var dictionary: [DictionaryEntry] = []
    @Published var dictQuery: String = ""
    @Published var snippets: [Snippet] = []
    @Published var cfg = Config.load()
    @Published var overrides: [AppStyleRepo.Override] = []
    @Published var seenApps: [AppStyleRepo.SeenApp] = []
    @Published var inputs: [InputDevice.Info] = []
    @Published var loginItem = LoginItem.isEnabled()
    static let configChanged = Notification.Name("sori.configChanged")
    static var defaultRecordingsDir: String { (NSHomeDirectory() as NSString).appendingPathComponent("Dev/sori/tests/eval/personal/raw") }

    // Read-modify-write on the conf file, then tell the app. Optional keys use `default` for display.
    func binding<T: Equatable>(_ kp: WritableKeyPath<Config, T?>, default d: T) -> Binding<T> {
        Binding(get: { self.cfg[keyPath: kp] ?? d }, set: { self.set(kp, $0) })
    }
    func binding<T: Equatable>(_ kp: WritableKeyPath<Config, T>, default d: T) -> Binding<T> {
        Binding(get: { self.cfg[keyPath: kp] }, set: { self.set(kp, $0) })
    }
    func set<T>(_ kp: WritableKeyPath<Config, T>, _ v: T) {
        var fresh = Config.load()
        fresh[keyPath: kp] = v
        fresh.save()
        cfg = fresh
        NotificationCenter.default.post(name: HubModel.configChanged, object: nil)
    }
    func setLoginItem(_ on: Bool) { LoginItem.set(enabled: on); loginItem = LoginItem.isEnabled() }
    func clearHistory() { Database.shared.run("DELETE FROM dictations"); wlog("history cleared by user"); reload() }

    private var subs: [AnyCancellable] = []

    init() {
        NotificationCenter.default.publisher(for: Database.dictationsChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &subs)
        NotificationCenter.default.publisher(for: Database.dictionaryChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.dictionary = DictionaryRepo.all() }
            .store(in: &subs)
        NotificationCenter.default.publisher(for: Database.snippetsChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.snippets = SnippetRepo.all() }
            .store(in: &subs)
        NotificationCenter.default.publisher(for: AppStyleRepo.changedNote)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.overrides = AppStyleRepo.overrides() }
            .store(in: &subs)
        reload()
    }

    func style(_ c: StyleCategory) -> StyleSetting { StyleResolver.setting(cfg: cfg, category: c) }
    func setStyle(_ c: StyleCategory, tone: Tone? = nil, level: CleanupLevel? = nil) {
        var st = style(c)
        if let t = tone { st.tone = t.rawValue }
        if let l = level { st.level = l.rawValue }
        var fresh = Config.load()            // never clobber keys another writer changed meanwhile
        var map = fresh.styles ?? [:]
        map[c.rawValue] = st
        fresh.styles = map
        fresh.save()
        cfg = fresh
        wlog("style \(c.rawValue) -> \(st.tone)/\(st.level)")
    }

    func reload() {
        cfg = Config.load()
        inputs = InputDevice.allInputs()
        loginItem = LoginItem.isEnabled()
        overrides = AppStyleRepo.overrides()
        seenApps = AppStyleRepo.seenApps()
        stats = DictationRepo.stats()
        reloadRows()
        dictionary = DictionaryRepo.all()
        snippets = SnippetRepo.all()
    }

    func reloadRows() {
        rows = DictationRepo.recent(limit: 500, search: query)
    }

    // Rows grouped by calendar day, newest first, with a human header.
    struct DayGroup: Identifiable {
        let id: String
        let title: String
        let rows: [Dictation]
    }
    var groups: [DayGroup] {
        let cal = Calendar.current
        var order: [String] = []
        var map: [String: (Date, [Dictation])] = [:]
        for r in rows {
            let day = cal.startOfDay(for: r.ts)
            let key = "\(day.timeIntervalSince1970)"
            if map[key] == nil { order.append(key); map[key] = (day, []) }
            map[key]!.1.append(r)
        }
        let df = DateFormatter(); df.dateFormat = "EEEE, MMM d"
        return order.map { key in
            let (day, rs) = map[key]!
            let title: String
            if cal.isDateInToday(day) { title = "Today" }
            else if cal.isDateInYesterday(day) { title = "Yesterday" }
            else { title = df.string(from: day) }
            return DayGroup(id: key, title: title, rows: rs)
        }
    }

    func copy(_ s: String) {
        let pb = NSPasteboard.general
        pb.declareTypes([.string], owner: nil); pb.setString(s, forType: .string)
    }

    func delete(_ d: Dictation) { DictationRepo.delete(d.id) }
}
