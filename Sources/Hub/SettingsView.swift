import SwiftUI

// MARK: - Settings inside the Hub: General · System · Experimental · Data & Privacy. Saves on change.
struct SettingsView: View {
    @ObservedObject var model: HubModel
    @State private var confirmClear = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Settings").font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.text)
                    Text("Changes apply immediately.").font(.system(size: 13)).foregroundStyle(Theme.text2)
                }
                general
                system
                experimental
                privacy
            }
            .padding(28)
            .frame(maxWidth: 860, alignment: .leading)
        }
        .background(Theme.bg)
        .alert("Clear dictation history?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) { model.clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Removes every row from Home and the stats. Kept recordings on disk are not touched.") }
    }

    // MARK: sections
    private var general: some View {
        Group2(title: "General") {
            SettingRow(label: "Shortcut", detail: "Hold Right ⌘ to talk, tap to lock hands-free, Right ⌘ + Enter to send, Right ⌘ + Z to undo the AI edit.") {
                Text("Right ⌘").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Theme.bg).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Theme.border, lineWidth: 1))
            }
            SettingRow(label: "Microphone", detail: "AirPods stay on the built-in mic so music never pauses; pick a device to pin it.") {
                Picker("", selection: model.binding(\.inputDeviceUID, default: "")) {
                    Text("System default").tag("")
                    ForEach(model.inputs, id: \.uid) { Text($0.name).tag($0.uid) }
                }
                .labelsHidden().frame(width: 260)
            }
            SettingRow(label: "Language", detail: "Auto lets the recognizer decide per dictation (Korean and English mix is fine).") {
                Picker("", selection: model.binding(\.lang, default: "auto")) {
                    ForEach(["auto", "en", "ko", "ja", "zh", "es", "fr", "de"], id: \.self) { Text($0 == "auto" ? "Auto" : $0.uppercased()).tag($0) }
                }
                .labelsHidden().frame(width: 140)
            }
            SettingRow(label: "Transcriber", detail: "Accurate: gpt-transcribe, 3.1% CER on your read-aloud clip, text ~1.2 s after release when streaming. Fastest: gpt-live-transcribe, ~0.5 s but 6.9% CER on the same clip. Local runs offline and is the fallback either way.") {
                Picker("", selection: Binding(get: { model.transcriberChoice }, set: { model.setTranscriber($0) })) {
                    Text("OpenAI, accurate").tag("openai:gpt-transcribe")
                    Text("OpenAI, fastest").tag("openai:gpt-live-transcribe")
                    Text("Local Qwen3-ASR").tag("local:")
                }
                .labelsHidden().frame(width: 220)
            }
            SettingRow(label: "Local model", detail: "Downloaded on first use.") {
                Picker("", selection: model.binding(\.asrModel, default: QwenServer.defaultRepo)) {
                    ForEach(["mlx-community/Qwen3-ASR-1.7B-8bit", "mlx-community/Qwen3-ASR-1.7B-4bit", "mlx-community/Qwen3-ASR-0.6B-8bit"], id: \.self) {
                        Text($0.replacingOccurrences(of: "mlx-community/", with: "")).tag($0)
                    }
                }
                .labelsHidden().frame(width: 220)
            }
            SettingRow(label: "AI vocabulary", detail: "Bias the recognizer toward modern AI and developer terms. Your own names live in Dictionary.") {
                Toggle("", isOn: model.binding(\.aiTermsEnabled, default: true)).labelsHidden().toggleStyle(.switch)
            }
        }
    }

    private var system: some View {
        Group2(title: "System") {
            SettingRow(label: "Launch at login", detail: "") {
                Toggle("", isOn: Binding(get: { model.loginItem }, set: { model.setLoginItem($0) })).labelsHidden().toggleStyle(.switch)
            }
            SettingRow(label: "Indicator", detail: "Compact: the small pill at the bottom of the screen. Classic: a preview panel while you talk.") {
                Picker("", selection: model.binding(\.panelStyle, default: "compact")) {
                    Text("Compact").tag("compact"); Text("Classic").tag("classic")
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 180)
            }
            SettingRow(label: "Show indicator", detail: "Off keeps everything working with nothing on screen.") {
                Toggle("", isOn: Binding(get: { !(model.cfg.compactHidden ?? false) }, set: { model.set(\.compactHidden, !$0) })).labelsHidden().toggleStyle(.switch)
            }
            SettingRow(label: "Sounds", detail: "Start and stop blips.") {
                Toggle("", isOn: model.binding(\.sound, default: true)).labelsHidden().toggleStyle(.switch)
            }
            SettingRow(label: "Press Enter after pasting", detail: "Submits every dictation. Right ⌘ + Enter does it per dictation without this.") {
                Toggle("", isOn: model.binding(\.pressEnter, default: false)).labelsHidden().toggleStyle(.switch)
            }
        }
    }

    private var experimental: some View {
        Group2(title: "Experimental") {
            SettingRow(label: "Command Mode", detail: "Hold Right ⌘ + Right ⌥, say what to do with the selected text (\"make this shorter\"), release.") {
                Toggle("", isOn: model.binding(\.commandMode, default: false)).labelsHidden().toggleStyle(.switch)
            }
            SettingRow(label: "Streaming recognition", detail: "Transcribe while you talk so only the tail is pending on release. OpenAI only; the upload path is the fallback.") {
                Toggle("", isOn: model.binding(\.streamingASR, default: false)).labelsHidden().toggleStyle(.switch)
            }
        }
    }

    private var privacy: some View {
        Group2(title: "Data & Privacy") {
            SettingRow(label: "Use the cloud transcriber", detail: "Off sends nothing anywhere: local recognition, rule-based cleanup only.") {
                Toggle("", isOn: Binding(get: { (model.cfg.asrProvider ?? "local") == "openai" },
                                         set: { model.set(\.asrProvider, $0 ? "openai" : "local") })).labelsHidden().toggleStyle(.switch)
            }
            SettingRow(label: "Use on-screen text as context", detail: "Sends the text already in the field (before the cursor, up to 1,500 characters) with the rewrite so it matches language and continues your sentence. Off keeps only the app name.") {
                Toggle("", isOn: model.binding(\.contextAwareness, default: true)).labelsHidden().toggleStyle(.switch)
            }
            SettingRow(label: "Keep recordings", detail: "Saves each dictation's audio under ~/Dev/sori/tests/eval/personal/raw. Off by default.") {
                Toggle("", isOn: Binding(get: { !(model.cfg.keepRecordingsDir ?? "").isEmpty },
                                         set: { model.set(\.keepRecordingsDir, $0 ? HubModel.defaultRecordingsDir : nil) })).labelsHidden().toggleStyle(.switch)
            }
            SettingRow(label: "History retention", detail: "Older dictations are removed at launch.") {
                Picker("", selection: model.binding(\.historyRetentionDays, default: 0)) {
                    Text("Forever").tag(0); Text("90 days").tag(90); Text("30 days").tag(30); Text("7 days").tag(7)
                }
                .labelsHidden().frame(width: 140)
            }
            SettingRow(label: "Clear history", detail: "Deletes every dictation row now.") {
                Button("Clear…") { confirmClear = true }
            }
            SettingRow(label: "Setup", detail: "Re-run the permissions and microphone check.") {
                Button("Open setup…") { (NSApp.delegate as? AppDelegate)?.openOnboarding() }
            }
        }
    }
}

struct Group2<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text3)
                .textCase(.uppercase).kerning(0.4).padding(.bottom, 8)
            VStack(spacing: 0) { content }
                .background(Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).stroke(Theme.border, lineWidth: 1))
        }
    }
}

struct SettingRow<Control: View>: View {
    let label: String
    let detail: String
    @ViewBuilder let control: Control
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(label).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                    if !detail.isEmpty {
                        Text(detail).font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                control
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider().overlay(Theme.border).padding(.leading, 16)
        }
    }
}
