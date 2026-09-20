import SwiftUI
import Combine

// MARK: - Hub view model: one observable object, refreshed from the store on change notifications
final class HubModel: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case home = "Home"
        case dictionary = "Dictionary"
        case snippets = "Snippets"
        var id: String { rawValue }
        var symbol: String {
            switch self { case .home: return "house"; case .dictionary: return "character.book.closed"; case .snippets: return "text.insert" }
        }
    }

    @Published var section: Section = .home
    @Published var query: String = "" { didSet { reloadRows() } }
    @Published var rows: [Dictation] = []
    @Published var stats = DictationStats()
    @Published var dictionary: [DictionaryEntry] = []
    @Published var dictQuery: String = ""
    @Published var snippets: [Snippet] = []

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
        reload()
    }

    func reload() {
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
