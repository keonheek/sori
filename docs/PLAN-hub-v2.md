# Sori v2 — Wispr Flow parity plan

Written 2026-09-20 evening for execution starting 2026-09-21. Scope he chose: **full parity** —
Hub window (history, dictionary, snippets, style, stats), Flow-Bar-style indicator, onboarding /
permissions flow, restructured settings. Plan only tonight; phases run in order tomorrow.

## 0. What Wispr Flow actually is (research receipts)

Pipeline: audio → cloud ASR (OpenAI as subprocessor) → fine-tuned Llama formatter on Baseten
(TensorRT-LLM) → paste. Target: whole pipeline under 700 ms after release (ASR <200, LLM <200,
network <200). Context personalization (dictionary, corrections, style) lives on-device.
Sources: wisprflow.ai/post/technical-challenges, baseten.co/resources/customers/wispr-flow.

Desktop UI (docs.wisprflow.ai "Navigating the app", reviews):

| Surface | What it holds |
|---|---|
| **Hub window, sidebar** | Home · Dictionary · Snippets · Style · Scratchpad · Settings/Help |
| Home | transcript history grouped by date, search, hover → copy / flag / retry / play; usage stats above (words, shortcut, per-app usage, WPM) |
| Dictionary | add / search / edit / star / delete words and spelling replacements; auto-learns when you type over a correction |
| Snippets | voice-triggered text blocks (trigger phrase → up to 4,000 chars) |
| Style | tone per category: Personal messages · Work messages · Email · Other (Very Casual → Formal); Auto cleanup level None / Light / Medium / High; "Undo AI edit" reveals raw |
| Scratchpad | voice notes: create, search, pin (skip for v2) |
| Settings | General (shortcuts, mic, languages) · System (startup, Flow Bar visibility, notifications) · Experimental (Command Mode) · Account · Data & Privacy (context awareness toggle, zero retention) |
| **Flow Bar** | floating pill, bottom of screen; states idle / listening (waveform) / processing; right-click → mic choice, history, Settings, "Paste last transcript" |
| Hotkeys | hold Fn = push-to-talk; double-tap = hands-free lock; Command Mode = hold Fn+Ctrl, speak an instruction, release → runs on selected text or opens a web search ("ask Claude …") |

Where Sori already stands (main.swift, 3,266 lines, AppKit, one file):

- Pipeline parity is DONE today: gpt-transcribe (3.1 % CER on his KO/EN clip) + local VAD gate +
  local fallback; Smart Rewrite with app context (chat / mail / docs / code / aiChat registers);
  deletion-only cleanup as the light level; AirPods-safe capture.
- Exists but hidden or thin: replacements + auto-learned corrections (`learnEdits`), prompt hint,
  compact indicator with level bars, Settings window (General · Vocabulary · Sounds · About),
  menu-bar menu, `Check for Updates`, `keepRecordingsDir`.
- Missing: history store, stats, Hub window, snippets, style categories + cleanup levels, undo
  AI edit, onboarding, Command Mode, hands-free lock UI, streaming ASR.

## 1. Architecture decisions (settled, not open)

1. **Split the monolith first.** `Sources/` with one file per unit; `install.sh` and
   `make-release.sh` compile `Sources/*.swift`. No behaviour change in that phase — the gate is
   "same log lines on the same 3 dictations". Min target moves macOS 11 → **macOS 13** (SwiftUI
   `NavigationSplitView`, `Table`). His Mac is macOS 16.
2. **Hub = SwiftUI window hosted from AppKit** (`NSHostingController`). The floating indicator and
   the event tap stay AppKit — they work and are latency-critical.
3. **Local store = SQLite via the C API** (no SPM dependency, keeps `swiftc` builds). File
   `~/Library/Application Support/Sori/sori.sqlite`. Tables: `dictations`, `dictionary`,
   `snippets`, `app_styles`. Migrate `~/.sori.conf` replacements / learned into `dictionary`
   on first run; conf stays the source for scalar settings.
4. **Dictation record** = id, ts, app bundle, app name, window title, kind, raw, final, provider,
   audio_ms, latency_ms (ASR / rewrite / total), words, pasted(bool), audio path (only when
   `keepRecordings` is on). This one table powers Home, stats, undo, retry, and the eval set.
5. **Cleanup levels map to what exists:** None = raw; Light = `TextCleanup` rules; Medium =
   deletion-only LLM; High = Smart Rewrite. Style category (Personal / Work / Email / Other) is
   derived from `AppContext.kind` with a per-app override table; tone slider feeds the Smart
   Rewrite style block.
6. **Design language:** Wispr-like — white/near-white surfaces, one accent, rounded 12 px, SF
   Pro, no gradients, no chips-as-decoration, no status-dot rows (feedback_no_ai_slop_ui). First
   renderable Hub goes to him for a taste check BEFORE any polish loop (deliverables rule).
7. **Streaming ASR is last, not first.** Everything above works on the batch path; OpenAI's
   realtime transcription is a latency upgrade to bolt on once the UI exists.

## 2. Phases with gates (run in order; each ends with a commit)

### P0 — Module split + build scripts
- `Sources/Log.swift, Config.swift, TextCleanup.swift, LLMCleanup.swift, AppContext.swift,
  Engine/QwenServer.swift, Engine/OpenAITranscribe.swift, Audio/InputDevice.swift,
  Audio/HALCapture.swift, Audio/Recorder.swift, UI/RecordingPanel.swift, UI/Settings.swift,
  App/AppDelegate.swift, main.swift`.
- `install.sh`, `make-release.sh`: `swiftc -O -target arm64-apple-macos13.0 Sources/**/*.swift`.
- **Gate:** build clean; 3 real dictations produce the same log sequence as 605d469
  (`HAL capture` → `openai transcribe` → `smart rewrite ctx` → `pasted`); `tests/eval/smoke`
  still runs.

### P1 — Dictation store + Hub Home
- `Store/Database.swift` (sqlite3 wrapper, migrations), `Store/DictationRepo.swift`.
- Hook in `transcribe()`: insert on every run, update `pasted`.
- `Hub/HubWindow.swift` (NavigationSplitView), `Hub/HomeView.swift`: stats strip (words today /
  this week, dictations, avg latency, top 3 apps) + history list grouped by day, search field,
  row hover actions: copy final, copy raw, re-paste, delete.
- Menu bar: "Open Sori Hub" (⌘H-ish), Flow Bar right-click gets "Paste last transcript".
- **Gate:** after 3 dictations the Home list shows 3 rows with correct app names; search for a
  word in one of them returns exactly that row; "Paste last transcript" pastes into TextEdit
  (verified by reading the doc back via AX).
- **Taste checkpoint:** screenshot of Home to him before P2.

### P2 — Flow Bar
- Replace the compact indicator with `UI/FlowBar.swift`: pill 180×36, bottom-center, states
  idle (dot) / listening (live waveform from `onLevel`) / transcribing (pulse) / locked
  (hands-free, "Tap ⌘ to stop") / error (red, message). Hide-while-idle option kept.
- Right-click menu: Microphone (list from `InputDevice`), History (opens Hub), Paste last
  transcript, Settings, Hide bar.
- **Gate:** each state reachable by a real action and screenshotted; hidden state never steals
  focus (`NSPanel .nonactivatingPanel` unchanged); level bars move while speaking.

### P3 — Dictionary + Snippets
- `Hub/DictionaryView.swift`: table of entries (word, replacement, starred, source: manual /
  learned), add / edit / delete, star. Learned corrections from `learnEdits` land here instead
  of silently into conf.
- Dictionary feeds two places: the ASR `prompt` term list (starred first, cap 12, names first —
  keep the existing bias rule) and post-ASR replacements.
- `Hub/SnippetsView.swift` + `Snippets.swift`: trigger phrase → expansion (≤4,000 chars).
  Matching: normalized (lowercase, strip punctuation) prefix match on the final text; expansion
  replaces the trigger, rest of the dictation follows. Multi-line expansion pastes as-is.
- **Gate:** add snippet "my address" → dictate "my address" → full block pasted; add dictionary
  entry Keonhee → dictate a sentence with the name → spelled correctly on 3/3 tries.

### P4 — Style + cleanup levels + Undo AI edit
- `Hub/StyleView.swift`: four categories with tone (Very casual · Casual · Neutral · Formal)
  and cleanup level (None · Light · Medium · High); per-app override list (app → category).
- Smart Rewrite consumes tone + category; Medium keeps the deletion-only guard; High uses the
  rewrite guard.
- Undo AI edit: menu-bar item + Hub row action + optional hotkey (Right ⌘ + Z within 10 s of a
  paste) → replaces the pasted text with raw (select-back via AX shift-arrow count, paste).
- **Gate:** the 49-input rewrite bench re-run per tone (chat casual / email formal) with 0 trap
  executions; undo restores raw in TextEdit and in Chrome's Gmail composer.

### P5 — Onboarding + Settings restructure
- First run (or `--onboard`): window with three permission cards (Microphone · Accessibility ·
  Input Monitoring) showing live status, a "Test mic" meter, hotkey explainer, and "Try it"
  field. Reuses the existing TCC probes (`AXIsProcessTrusted`, `IOHIDRequestAccess`,
  `AVCaptureDevice.requestAccess`).
- Settings sidebar becomes: General (hotkey, mic, language, transcriber local/OpenAI) · System
  (launch at login, Flow Bar visibility, sounds) · Experimental (Command Mode, streaming) ·
  Data & Privacy (keep recordings, cloud on/off, history retention).
- **Gate:** fresh bundle id in a copy of the app walks through all three grants and the "Try
  it" field receives a dictation.

### P6 — Command Mode (Experimental)
- Hotkey: hold Right ⌘ + Right ⌥ (configurable). Flow Bar shows "Command".
- On release: selected text via AX (`kAXSelectedTextAttribute`) + spoken instruction → Groq
  qwen3.8 with an edit prompt → replace selection by paste. No selection → nothing, bar says so.
  "ask Claude / search Google …" → open URL with query + selection appended.
- **Gate:** select a paragraph in TextEdit, say "make this more concise" → replaced; trap test
  ("what is the capital of France") with nothing selected → no paste, no browser.

### P7 — Streaming ASR (latency)
- OpenAI realtime transcription over WebSocket while recording; on release only the tail is
  pending. Keep batch path as fallback. Measure release→paste on 10 dictations before/after.
- **Gate:** median release→paste ≤ 700 ms on 10 dictations of 5–10 s; batch path untouched.

## 3. Order of work tomorrow

P0 → P1 (+ taste checkpoint) → P2 → P3 → P4 → P5. P6 and P7 only if P0–P5 are green; they are
independent of each other. Every phase: build, deploy to /Applications/Sori.app (sign with
"Gunny Local Codesign", `launchctl kickstart -k gui/$UID/dev.sori.app`), run the gate, commit
locally. Nothing pushed without his word.

## 4. Open calls (his)

1. Hub window keyboard shortcut and whether the menu-bar icon opens the Hub or the menu on click.
2. Keep recordings by default (needed for "play" in history) — privacy trade-off; default OFF
   unless he says otherwise.
3. Undo hotkey binding (Right ⌘ + Z proposed).
4. macOS 13 minimum (drops Big Sur/Monterey support in the public repo).
