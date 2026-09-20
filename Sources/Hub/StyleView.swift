import SwiftUI

// MARK: - Style: tone + cleanup level per category, per-app overrides
struct StyleView: View {
    @ObservedObject var model: HubModel
    @State private var pickApp: String = ""
    @State private var pickCategory: StyleCategory = .work

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Style").font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.text)
                    Text("How much Sori changes what you said, by where it is going. Right ⌘ + Z after a paste restores the raw words.")
                        .font(.system(size: 13)).foregroundStyle(Theme.text2)
                }
                ForEach(StyleCategory.allCases) { cat in categoryCard(cat) }
                overridesCard
            }
            .padding(28)
            .frame(maxWidth: 860, alignment: .leading)
        }
        .background(Theme.bg)
    }

    private func categoryCard(_ cat: StyleCategory) -> some View {
        let setting = model.style(cat)
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(cat.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                Text(cat.subtitle).font(.system(size: 12)).foregroundStyle(Theme.text3)
            }
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Tone").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.text3)
                    Picker("", selection: Binding(get: { setting.toneValue }, set: { model.setStyle(cat, tone: $0) })) {
                        ForEach(Tone.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 340)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Cleanup").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.text3)
                    Picker("", selection: Binding(get: { setting.levelValue }, set: { model.setStyle(cat, level: $0) })) {
                        ForEach(CleanupLevel.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 260)
                    Text(setting.levelValue.detail).font(.system(size: 11)).foregroundStyle(Theme.text3)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var overridesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Apps").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                Text("Send an app to a different category than Sori guesses.").font(.system(size: 12)).foregroundStyle(Theme.text3)
            }
            HStack(spacing: 10) {
                Picker("", selection: $pickApp) {
                    Text("Choose an app").tag("")
                    ForEach(model.seenApps) { Text($0.name.isEmpty ? $0.bundleId : $0.name).tag($0.bundleId) }
                }
                .labelsHidden().frame(width: 260)
                Picker("", selection: $pickCategory) {
                    ForEach(StyleCategory.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().frame(width: 180)
                Button("Add") { AppStyleRepo.set(bundleId: pickApp, category: pickCategory); pickApp = "" }
                    .buttonStyle(.borderedProminent).tint(Theme.accent).disabled(pickApp.isEmpty)
            }
            if !model.overrides.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(model.overrides.enumerated()), id: \.element.id) { i, o in
                        OverrideRow(o: o)
                        if i < model.overrides.count - 1 { Divider().overlay(Theme.border) }
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.border, lineWidth: 1))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

struct OverrideRow: View {
    let o: AppStyleRepo.Override
    @State private var hover = false
    var body: some View {
        HStack {
            Text(o.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
            Text(o.category.title).font(.system(size: 12)).foregroundStyle(Theme.text2)
            Spacer()
            if hover { RowAction(title: "Remove", role: .destructive) { AppStyleRepo.remove(bundleId: o.bundleId) } }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(hover ? Theme.cardHover : Color.clear)
        .onHover { hover = $0 }
    }
}
