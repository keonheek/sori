<div align="center">
  <img src="docs/icon.png" width="140" alt="Sori icon" />
  <h1>Sori (소리)</h1>
  <p><strong>Push-to-talk dictation for macOS that handles Korean, English, and code-switching between them.</strong></p>

  [![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
  ![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-brightgreen)
  [![Release](https://img.shields.io/github/v/release/keonheek/sori)](https://github.com/keonheek/sori/releases)

  <a href="https://github.com/keonheek/sori/releases"><strong>Download</strong></a>
</div>

---

Hold Right ⌘, speak, release. The text lands at your cursor, in whatever app has focus. Whisper runs locally on your machine; audio is never uploaded.

## Why Sori

- **Bilingual for real.** Most Whisper apps break on code-switched speech: Korean with an English term in the middle comes back translated or transliterated. Sori pins the language before decoding (details below), so 한국어, English, and mixed sentences all survive intact.
- **Fast.** A resident whisper-server keeps the model in RAM: 0.3-0.6s per dictation on Apple Silicon, instead of 1.1-1.3s when the model reloads on every press.
- **Clean output.** Fillers ("um", "음", "어") are stripped and self-corrections resolve to what you meant: "목요일에... 아니다, 금요일에" pastes as 금요일에. An optional second pass on Groq's free tier fixes grammar and punctuation, with a guard that pastes your raw words if the model misbehaves.
- **Free and private.** No subscription, no account, no telemetry. The only optional network call is the cleanup step, and it can be toggled off in the menu bar.

## How it works

1. **Hold** Right ⌘ and speak (or tap to toggle)
2. **Release** and a fast prompt-free pass detects the language (~0.2s), then the warm engine transcribes with the language pinned
3. **Paste**: cleaned text lands at the cursor and stays on the clipboard for ⌘V recovery

Enter while recording stops, transcribes, and submits. Escape cancels. Mis-heard a name? Select your correction and ⌘C once, and Sori learns the replacement.

## Install

**Prebuilt:** download the zip from [Releases](https://github.com/keonheek/sori/releases), unzip into `/Applications`, right-click > Open on first launch. Then follow step 4 in the release notes to install whisper-cpp and the models.

**From source:**

```bash
git clone https://github.com/keonheek/sori && cd sori
./install.sh
```

macOS will ask for Microphone, Accessibility, and Input Monitoring; all three are required (mic to hear you, the other two to catch Right ⌘ globally and paste the result).

## Configuration

Settings live in the menu-bar menu and in `~/.sori.conf` (JSON): model, language (`auto` recommended), vocabulary hints, warm engine, cleanup toggles. Vocabulary is truncated from the back at ~223 tokens, so put the names you actually say near the front. For the optional AI cleanup, put a [free Groq API key](https://console.groq.com) in `~/.sori-groq` and enable "AI Cleanup" in the menu.

## Design notes

Four problems that shaped the architecture, documented because they will bite anyone building on Whisper:

- **Language auto-detect is poisoned by the vocabulary prompt.** An English glossary biases Whisper into detecting Korean speech as English, and then it *translates* rather than mis-transcribes ("발표는 목요일에" → "The announcement is Monday"). Sori detects language in a separate prompt-free pass (base model, ~0.2s, p>0.98), then transcribes with the language pinned. The prompt then influences spelling, never language.
- **whisper-server defaults to greedy decoding** (`beam-size -1`) while whisper-cli defaults to beam search 5. Greedy is what produces the "Monday, Monday, Monday" repetition loop on non-English audio. Sori spawns the server with `-bs 5 -bo 5` for CLI-quality output at server speed.
- **An instruct LLM will answer dictation that sounds like a request** instead of cleaning it, replying "I can clean up the text for you..." straight into the text field. Prompt framing (transcript in tags, model as pure transform) helps, but the reliable fix is structural output validation: same language as input, sane length ratio, no assistant phrases. Any failure falls back to the raw transcript.
- **Whisper keeps only the last 223 prompt tokens**, and dense proper nouns tokenize at ~2.4 chars each, not 4. A long glossary silently cuts the names hint off the head of the prompt.

## Windows (experimental)

The `windows/` folder has a Python port with the same pipeline: prompt-free language pre-detection, beam-search transcription via faster-whisper, and the guarded LLM cleanup. Hold Right Ctrl instead of Right ⌘.

```
cd windows
pip install -r requirements.txt
python sori_win.py
```

The transcription engine is tested (same Korean/English/mixed suite as the macOS app); the hotkey and paste layer has not been verified on real Windows hardware yet, which is why this stays marked experimental. If you run it, an issue with your results (working or not) genuinely helps.

## Rebuilding without losing permissions

macOS ties Accessibility/Input Monitoring grants to the code signature, and ad-hoc signatures change every build. If you hack on the source, create a self-signed cert named `Sori Codesign` in Keychain Access; `install.sh` picks it up and grants survive rebuilds. After switching identities, reset stale grants once: `tccutil reset Accessibility dev.sori.app && tccutil reset ListenEvent dev.sori.app`.

## Requirements

macOS 13+ · Xcode Command Line Tools · Homebrew · ~2 GB disk for models · ~1.7 GB RAM while the warm engine is loaded (`warmEngine: false` to go without)

Built on [whisper.cpp](https://github.com/ggml-org/whisper.cpp). One Swift file, no Xcode project, no dependencies beyond whisper-cpp itself.

## License

[MIT](LICENSE)
