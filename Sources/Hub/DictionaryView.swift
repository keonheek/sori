import SwiftUI

// MARK: - Dictionary: add / search / edit / star / delete words and corrections
struct DictionaryView: View {
    @ObservedObject var model: HubModel
    @State private var newWord = ""
    @State private var newReplaces = ""
    @State private var editing: DictionaryEntry? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Dictionary").font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.text)
                    Text("Names and terms Sori should spell exactly, and words it keeps hearing wrong.")
                        .font(.system(size: 13)).foregroundStyle(Theme.text2)
                }
                addForm
                searchField
                list
            }
            .padding(28)
            .frame(maxWidth: 860, alignment: .leading)
        }
        .background(Theme.bg)
        .sheet(item: $editing) { e in EditEntrySheet(entry: e) { editing = nil } }
    }

    private var addForm: some View {
        HStack(alignment: .bottom, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Word or name").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.text3)
                HubTextField(text: $newWord, placeholder: "Keonhee")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Sori hears it as (optional)").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.text3)
                HubTextField(text: $newReplaces, placeholder: "gun hee")
            }
            Button("Add") {
                let word = newWord.trimmingCharacters(in: .whitespaces)
                let heard = newReplaces.trimmingCharacters(in: .whitespaces)
                guard !word.isEmpty else { return }
                // A "heard as" makes it a correction: heard → word. Otherwise a plain word to spell.
                if heard.isEmpty { DictionaryRepo.add(word: word) } else { DictionaryRepo.add(word: heard, replacement: word) }
                newWord = ""; newReplaces = ""
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent).tint(Theme.accent)
            .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .card()
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.text3)
            TextField("Search dictionary", text: $model.dictQuery).textFieldStyle(.plain).font(.system(size: 13))
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.border, lineWidth: 1))
    }

    private var rows: [DictionaryEntry] {
        let q = model.dictQuery.lowercased().trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? model.dictionary : model.dictionary.filter { $0.word.lowercased().contains(q) || $0.replacement.lowercased().contains(q) }
    }

    @ViewBuilder private var list: some View {
        if rows.isEmpty {
            Text(model.dictionary.isEmpty ? "Nothing here yet. Add a name above, or correct a pasted word and copy it — Sori learns the fix."
                                          : "No entries match.")
                .font(.system(size: 13)).foregroundStyle(Theme.text2)
                .frame(maxWidth: .infinity, alignment: .leading).card()
        } else {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, e in
                    DictionaryRow(e: e, onEdit: { editing = e })
                    if i < rows.count - 1 { Divider().overlay(Theme.border).padding(.leading, 16) }
                }
            }
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).stroke(Theme.border, lineWidth: 1))
        }
    }
}

struct DictionaryRow: View {
    let e: DictionaryEntry
    let onEdit: () -> Void
    @State private var hover = false
    var body: some View {
        HStack(spacing: 12) {
            Button { DictionaryRepo.setStarred(e.id, !e.starred) } label: {
                Image(systemName: e.starred ? "star.fill" : "star")
                    .foregroundStyle(e.starred ? Theme.accent : Theme.text3)
            }
            .buttonStyle(.plain).help(e.starred ? "Starred: always in the recognizer's vocabulary" : "Star to prioritize")
            VStack(alignment: .leading, spacing: 2) {
                if e.isCorrection {
                    HStack(spacing: 6) {
                        Text(e.word).font(.system(size: 13)).foregroundStyle(Theme.text2).strikethrough(true, color: Theme.text3)
                        Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(Theme.text3)
                        Text(e.replacement).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                    }
                } else {
                    Text(e.word).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                }
                Text(e.source == "learned" ? "Learned from your edit" : (e.isCorrection ? "Correction" : "Spell exactly"))
                    .font(.system(size: 11)).foregroundStyle(Theme.text3)
            }
            Spacer()
            if hover {
                HStack(spacing: 14) {
                    RowAction(title: "Edit", action: onEdit)
                    RowAction(title: "Delete", role: .destructive) { DictionaryRepo.delete(e.id) }
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(hover ? Theme.cardHover : Theme.card)
        .onHover { hover = $0 }
    }
}

struct EditEntrySheet: View {
    @State var entry: DictionaryEntry
    let done: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit entry").font(.system(size: 15, weight: .semibold))
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.isCorrection ? "Sori hears" : "Word").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.text3)
                HubTextField(text: $entry.word, placeholder: "")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Paste instead (leave empty to keep the word as-is)").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.text3)
                HubTextField(text: $entry.replacement, placeholder: "")
            }
            Toggle("Starred", isOn: $entry.starred).toggleStyle(.checkbox)
            HStack {
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Save") { DictionaryRepo.update(entry); done() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(Theme.accent)
            }
        }
        .padding(20).frame(width: 420)
    }
}

// Bordered single-line field in the Hub's own style.
struct HubTextField: View {
    @Binding var text: String
    let placeholder: String
    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain).font(.system(size: 13))
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Theme.bg)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.border, lineWidth: 1))
    }
}
