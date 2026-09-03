<div align="center">
  <img src="docs/icon.png" width="140" alt="Sori icon" />
  <h1>Sori (소리)</h1>
  <p><strong>Push-to-talk dictation for macOS that handles Korean, English, and code-switching between them.</strong></p>

  [![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
  ![Platform](https://img.shields.io/badge/platform-macOS%2011%2B-brightgreen)
  [![Release](https://img.shields.io/github/v/release/keonheek/sori)](https://github.com/keonheek/sori/releases)

  <a href="https://github.com/keonheek/sori/releases"><strong>Download</strong></a>
</div>

---

Hold Right ⌘, speak, release. The text lands at your cursor, in whatever app has focus. Qwen3-ASR runs locally on your machine; audio is never uploaded.

## Why Sori

- **Bilingual for real.** Most dictation apps break on code-switched speech: Korean with an English term in the middle comes back translated or transliterated. Measured on an 8-line Korean/English script scored over 13 technical terms: Qwen3-ASR 11-12/13, whisper large-v3-turbo 8/13 (with a vocabulary glossary), Apple's on-device SpeechAnalyzer 1/13 — the last one dropped an entire English sentence, because its API pins one locale per transcriber and a Korean-only model transliterates the English.
- **Fast.** A resident engine process keeps the model in RAM: 0.3-0.4s per dictation on Apple Silicon. Loading per keypress instead would cost ~9s, almost all of it Python interpreter startup.
- **Clean output.** Fillers ("um", "음", "어") are stripped and self-corrections resolve to what you meant: "목요일에... 아니다, 금요일에" pastes as 금요일에. An optional second pass on Groq's free tier fixes grammar and punctuation, with a guard that pastes your raw words if the model misbehaves.
- **Free and private.** No subscription, no account, no telemetry. The only optional network call is the cleanup step, and it can be toggled off in the menu bar.

## How it works

1. **Hold** Right ⌘ and speak (or tap to toggle)
2. **Release** and a fast prompt-free pass detects the language (~0.2s), then the warm engine transcribes with the language pinned
3. **Paste**: cleaned text lands at the cursor and stays on the clipboard for ⌘V recovery

Enter while recording stops, transcribes, and submits. Escape cancels. Mis-heard a name? Select your correction and ⌘C once, and Sori learns the replacement.

## Install

**Prebuilt:** download the zip from [Releases](https://github.com/keonheek/sori/releases), unzip into `/Applications`, right-click > Open on first launch. Note that the prebuilt zips predate the Qwen3-ASR engine — build from source below until a new release is cut.

**Requirements:** Apple Silicon (the engine runs on MLX), Python 3, and Homebrew. `install.sh` creates `~/.sori-venv`, installs `mlx-audio` and `ten-vad`, and pulls the ~1.9GB Qwen3-ASR weights. whisper-cpp is still installed: the live-preview partials use it.

**From source:**

```bash
git clone https://github.com/keonheek/sori && cd sori
./install.sh
```

macOS will ask for Microphone, Accessibility, and Input Monitoring; all three are required (mic to hear you, the other two to catch Right ⌘ globally and paste the result).

## Updating

**Check for Updates…** in the menu-bar menu compares your version against the latest release. What happens next depends on how you installed, and the difference is worth understanding once:

- **Installed from source:** click **Update & Restart**. A Terminal window opens, pulls, rebuilds, re-signs with the same identity your install already uses, and restarts Sori. Nothing else to do — your permissions survive, and the models are left alone. If you've edited `main.swift`, it stops and tells you rather than clobbering your work.
- **Installed from the prebuilt zip:** it points you at the release page. Replace the app in `/Applications`, then re-enable Sori under System Settings > Privacy & Security > **Accessibility** and **Input Monitoring**. macOS ties those two grants to the code signature, and an unnotarized build gets a new signature every time it's built, so it sees each download as a different app. Only a paid Apple Developer ID would avoid that, and Sori doesn't have one — so source installs are the smoother path if you update often.

Either way, updating never re-downloads the models — `install.sh` skips any that are already in `~/.sori-models`.

From a terminal, without the menu:

```bash
/Applications/Sori.app/Contents/MacOS/Sori --check-update
```

## Configuration

Settings live in the menu-bar menu and in `~/.sori.conf` (JSON): model (a Qwen3-ASR MLX repo id), language (`auto` recommended — the engine identifies language itself across 52 languages), vocabulary hints, warm engine, cleanup toggles. The vocabulary bias is capped at 12 terms and names are sent first; see the design note below on why the cap matters. For the optional AI cleanup, put a [free Groq API key](https://console.groq.com) in `~/.sori-groq` and enable "AI Cleanup" in the menu.

## Diagnostics

The log is `~/Library/Logs/Sori/sori.log` (rotated at 2 MB into `sori.log.1`). Every dictation writes its raw and final text there, plus the engine's inference time and how much speech the voice-activity gate found. If Right ⌘ ever goes dead, that file says why: a disabled event tap, secure input left on by the lock screen, a missing venv, or an engine that had to be respawned.

`tests/eval/` scores the engine on your own clips (CER for Korean, WER for English, both over code-switched lines). Run it before and after changing the model, the vocabulary, or the cleanup rules; see its README.

## Design notes

Problems that shaped the architecture, documented because they will bite anyone building a dictation app:

- **Gate on a real VAD before the model, not on what the model says about silence.** Qwen3-ASR returns an empty string on a blank clip, which is honest, but it still costs a full inference and Whisper before it returned "Thank you." Sori now runs TEN-VAD (Apache-2.0, about 13 ms per second of audio) inside the engine and skips inference when a clip holds under 200 ms of speech, so an accidental tap never reaches the model. Silero's ONNX build was tried first and scored 0.12 on clear synthesized speech under its documented input contract, so it was not adopted.
- **A hung inference must kill the engine, not hold the lock.** MLX generate is serialized behind one lock; a single stuck call would have made every later dictation wait out the 60 s client timeout. The server now runs generate on a worker thread and exits if it exceeds 45 s; Sori respawns it on the next request, and launchd relaunches Sori itself if it ever crashes.
- **A vocabulary bias list is a strong prior, and a long one hurts.** Any brand in the list can be substituted for one that isn't. Scored on the same 13 terms: no bias 11/13; a 9-term hand-picked list 12/13; a 44-term glossary 11/13 but it rendered "Qwen 3.6" as "Claude 3.6" — Claude was first in the list. Capping that glossary at its first 12 entries was *worse still*, 7/13, because the cap kept exactly the competing brand and dropped the useful terms. Sori sends names first and caps the total; the honest default for a general glossary is off.
- **Language auto-detect used to be poisoned by the vocabulary prompt.** Under Whisper, an English glossary biased detection toward English on Korean speech, and it then *translated* rather than mis-transcribed ("발표는 목요일에" → "The announcement is Monday"), which forced a separate prompt-free detection pass. Qwen3-ASR takes no style prompt and identifies language itself, so that whole pass — and that failure — is gone.
- **whisper-server defaults to greedy decoding** (`beam-size -1`) while whisper-cli defaults to beam search 5. Greedy is what produces the "Monday, Monday, Monday" repetition loop on non-English audio; even with beam search the loop recurred often enough to need a collapse pass. It has not reappeared under Qwen3-ASR.
- **An instruct LLM will answer dictation that sounds like a request** instead of cleaning it, replying "I can clean up the text for you..." straight into the text field. Prompt framing (transcript in tags, model as pure transform) helps, but the reliable fix is structural output validation: same language as input, sane length ratio, no assistant phrases. Any failure falls back to the raw transcript.
- **Whisper keeps only the last 223 prompt tokens**, and dense proper nouns tokenize at ~2.4 chars each, not 4. A long glossary silently cut the names hint off the head of the prompt — the reason Sori's glossary was ordered by frequency, which later became a liability when that same ordering was reused as a bias list.

## Windows (experimental)

The `windows/` folder has a Python port with the same pipeline: prompt-free language pre-detection, beam-search transcription via faster-whisper, and the guarded LLM cleanup. Hold Right Ctrl instead of Right ⌘.

```
cd windows
pip install -r requirements.txt
python sori_win.py
```

The transcription engine was validated against the same Korean/English/mixed audio used while building the macOS app (the suite itself is not yet committed); the hotkey and paste layer has not been verified on real Windows hardware yet, which is why this stays marked experimental. If you run it, an issue with your results (working or not) genuinely helps.

## Rebuilding without losing permissions

macOS ties Accessibility/Input Monitoring grants to the code signature, and ad-hoc signatures change every build. If you hack on the source, create a self-signed cert named `Sori Codesign` in Keychain Access; `install.sh` picks it up and grants survive rebuilds. After switching identities, reset stale grants once: `tccutil reset Accessibility dev.sori.app && tccutil reset ListenEvent dev.sori.app`.

## Requirements

macOS 11+ (universal: Apple Silicon and Intel) · Xcode Command Line Tools · Homebrew · ~2 GB disk for models · ~1.7 GB RAM while the warm engine is loaded (`warmEngine: false` to go without)

Built on [Qwen3-ASR](https://github.com/QwenLM/Qwen3-ASR) via [mlx-audio](https://github.com/Blaizzy/mlx-audio), with [whisper.cpp](https://github.com/ggml-org/whisper.cpp) still driving the live-preview partials. One Swift file plus a small Python engine server; no Xcode project.

## License

[MIT](LICENSE)
