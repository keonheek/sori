import SwiftUI

// MARK: - Home: usage strip + searchable history grouped by day
struct HomeView: View {
    @ObservedObject var model: HubModel
    var body: some View {
        ScrollView { HomeContent(model: model) }.background(Theme.bg)
    }
}

// Pure SwiftUI body (no NSScrollView / NSTableView underneath) so ImageRenderer can draw it
// for the headless review snapshot; HomeView wraps it in the real ScrollView.
struct HomeContent: View {
    @ObservedObject var model: HubModel
    var maxRows: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            statsStrip
            searchField
            history
        }
        .padding(28)
        .frame(maxWidth: 860, alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Home").font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.text)
            Text("Everything you dictated, with what Sori changed.")
                .font(.system(size: 13)).foregroundStyle(Theme.text2)
        }
    }

    private var statsStrip: some View {
        let s = model.stats
        return HStack(spacing: 12) {
            StatTile(value: fmt(s.wordsToday), label: "Words today", detail: "\(fmt(s.wordsWeek)) this week")
            StatTile(value: "\(s.countToday)", label: "Dictations today", detail: "\(s.countWeek) this week")
            StatTile(value: s.avgLatencyMs > 0 ? "\(String(format: "%.1f", Double(s.avgLatencyMs) / 1000)) s" : "—",
                     label: "Release to text", detail: "ASR + rewrite, 7-day average")
            StatTile(value: s.topApps.first?.name ?? "—", label: "Most used in",
                     detail: s.topApps.dropFirst().map { $0.name }.joined(separator: " · "))
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.text3)
            if maxRows != nil {
                // Snapshot mode: NSTextField does not draw under ImageRenderer.
                Text("Search dictations").font(.system(size: 13)).foregroundStyle(Theme.text3)
                Spacer()
            } else {
                TextField("Search dictations", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
            }
            if !model.query.isEmpty {
                Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.text3) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.border, lineWidth: 1))
    }

    @ViewBuilder private var history: some View {
        if model.rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.query.isEmpty ? "No dictations yet" : "Nothing matches “\(model.query)”")
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text)
                if model.query.isEmpty {
                    Text("Tap Right ⌘ and speak. Each dictation lands here.")
                        .font(.system(size: 13)).foregroundStyle(Theme.text2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        } else {
            ForEach(limitedGroups) { g in
                VStack(alignment: .leading, spacing: 8) {
                    Text(g.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text3)
                        .textCase(.uppercase).kerning(0.4)
                    VStack(spacing: 0) {
                        ForEach(Array(g.rows.enumerated()), id: \.element.id) { i, d in
                            DictationRow(d: d, model: model)
                            if i < g.rows.count - 1 { Divider().overlay(Theme.border).padding(.leading, 16) }
                        }
                    }
                    .background(Theme.card)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).stroke(Theme.border, lineWidth: 1))
                }
            }
        }
    }

    private var limitedGroups: [HubModel.DayGroup] {
        guard let cap = maxRows else { return model.groups }
        var left = cap; var out: [HubModel.DayGroup] = []
        for g in model.groups where left > 0 {
            let take = Array(g.rows.prefix(left)); left -= take.count
            out.append(HubModel.DayGroup(id: g.id, title: g.title, rows: take))
        }
        return out
    }

    private func fmt(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}

struct StatTile: View {
    let value: String
    let label: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value).font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.text)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text2)
            Text(detail.isEmpty ? " " : detail).font(.system(size: 11)).foregroundStyle(Theme.text3).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 14)
    }
}

struct DictationRow: View {
    let d: Dictation
    @ObservedObject var model: HubModel
    @State private var hover = false
    @State private var showRaw = false

    private static let time: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(Self.time.string(from: d.ts)).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.text3)
                Text(d.appName.isEmpty ? "Unknown app" : d.appName).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text2)
                if !d.pasted { Text("not pasted").font(.system(size: 11)).foregroundStyle(Theme.text3) }
                Spacer()
                if hover {
                    HStack(spacing: 14) {
                        if d.raw != d.final {
                            RowAction(title: showRaw ? "Show final" : "Show raw") { showRaw.toggle() }
                        }
                        RowAction(title: "Copy") { model.copy(showRaw ? d.raw : d.final) }
                        RowAction(title: "Delete", role: .destructive) { model.delete(d) }
                    }
                } else {
                    Text(meta).font(.system(size: 11)).foregroundStyle(Theme.text3)
                }
            }
            Text(showRaw ? d.raw : d.final)
                .font(.system(size: 13.5)).foregroundStyle(showRaw ? Theme.text2 : Theme.text)
                .lineSpacing(3).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(hover ? Theme.cardHover : Theme.card)
        .onHover { hover = $0 }
    }

    private var meta: String {
        var parts: [String] = ["\(d.words) words"]
        if d.asrMs > 0 { parts.append(String(format: "%.1f s", Double(d.asrMs + d.rewriteMs) / 1000)) }
        if d.raw != d.final { parts.append("edited") }
        return parts.joined(separator: " · ")
    }
}
