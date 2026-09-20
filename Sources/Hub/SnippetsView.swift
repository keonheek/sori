import SwiftUI

// MARK: - Snippets: say the trigger, paste the block
struct SnippetsView: View {
    @ObservedObject var model: HubModel
    @State private var editing: Snippet? = nil
    @State private var adding = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Snippets").font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.text)
                        Text("Start a dictation with a trigger phrase and Sori pastes the whole block. Up to 4,000 characters each.")
                            .font(.system(size: 13)).foregroundStyle(Theme.text2)
                    }
                    Spacer()
                    Button("New snippet") { adding = true }.buttonStyle(.borderedProminent).tint(Theme.accent)
                }
                list
            }
            .padding(28)
            .frame(maxWidth: 860, alignment: .leading)
        }
        .background(Theme.bg)
        .sheet(item: $editing) { s in SnippetSheet(snippet: s) { editing = nil } }
        .sheet(isPresented: $adding) { SnippetSheet(snippet: nil) { adding = false } }
    }

    @ViewBuilder private var list: some View {
        if model.snippets.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("No snippets yet").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text)
                Text("Example: trigger “my address”, expansion your full postal address.")
                    .font(.system(size: 13)).foregroundStyle(Theme.text2)
            }
            .frame(maxWidth: .infinity, alignment: .leading).card()
        } else {
            VStack(spacing: 0) {
                ForEach(Array(model.snippets.enumerated()), id: \.element.id) { i, s in
                    SnippetRow(s: s, onEdit: { editing = s })
                    if i < model.snippets.count - 1 { Divider().overlay(Theme.border).padding(.leading, 16) }
                }
            }
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).stroke(Theme.border, lineWidth: 1))
        }
    }
}

struct SnippetRow: View {
    let s: Snippet
    let onEdit: () -> Void
    @State private var hover = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("“\(s.trigger)”").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                Spacer()
                if hover {
                    HStack(spacing: 14) {
                        RowAction(title: "Edit", action: onEdit)
                        RowAction(title: "Delete", role: .destructive) { SnippetRepo.delete(s.id) }
                    }
                } else {
                    Text("\(s.expansion.count) characters").font(.system(size: 11)).foregroundStyle(Theme.text3)
                }
            }
            Text(s.expansion).font(.system(size: 13)).foregroundStyle(Theme.text2).lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(hover ? Theme.cardHover : Theme.card)
        .onHover { hover = $0 }
    }
}

struct SnippetSheet: View {
    let snippet: Snippet?
    let done: () -> Void
    @State private var trigger: String
    @State private var expansion: String
    init(snippet: Snippet?, done: @escaping () -> Void) {
        self.snippet = snippet; self.done = done
        _trigger = State(initialValue: snippet?.trigger ?? "")
        _expansion = State(initialValue: snippet?.expansion ?? "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(snippet == nil ? "New snippet" : "Edit snippet").font(.system(size: 15, weight: .semibold))
            VStack(alignment: .leading, spacing: 4) {
                Text("Trigger phrase (what you say)").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.text3)
                HubTextField(text: $trigger, placeholder: "my address")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Expansion (what gets pasted)").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.text3)
                TextEditor(text: $expansion)
                    .font(.system(size: 13)).frame(minHeight: 140)
                    .padding(6)
                    .background(Theme.bg)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.border, lineWidth: 1))
                Text("\(expansion.count) / \(SnippetRepo.maxExpansion)").font(.system(size: 11)).foregroundStyle(Theme.text3)
            }
            HStack {
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Save") {
                    if let s = snippet { SnippetRepo.update(Snippet(id: s.id, trigger: trigger, expansion: expansion, createdTs: s.createdTs)) }
                    else { SnippetRepo.add(trigger: trigger, expansion: expansion) }
                    done()
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(Theme.accent)
                .disabled(trigger.trimmingCharacters(in: .whitespaces).isEmpty || expansion.isEmpty)
            }
        }
        .padding(20).frame(width: 520)
    }
}
