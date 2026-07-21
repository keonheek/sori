<p align="center"><img src="docs/icon.png" width="128" alt="Sori icon"></p>

<h1 align="center">Sori (소리)</h1>

<p align="center"><b>Push-to-talk dictation for macOS that actually handles Korean, English, and switching between them mid-sentence. Runs entirely on your machine.</b></p>

---

Hold **Right ⌘**, speak, release. Your words appear at the cursor. Audio never leaves your machine and there is nothing to subscribe to. Sori started as a replacement for a paid dictation subscription and ended up handling bilingual speech better than the tools it replaced.

## Why another dictation app

Most Whisper-based dictation tools break on bilingual speakers. Speak Korean with an English tech term in the middle, or switch languages between sentences, and you get translations you never asked for, or transliterated gibberish. Sori fixes this with a detail most tools skip: a **prompt-free language pre-detection pass**. Whisper's built-in auto-detect is biased by the English vocabulary prompt most apps feed it, and that bias can silently *translate* your Korean into English. Sori detects the language first with a fast pass on the raw audio (about 0.2s, with no prompt in play), then locks it for transcription. Vocabulary hints improve accuracy without ever flipping the output language.

## Features

- **Push-to-talk or toggle**: hold Right ⌘ to talk, or tap to toggle. Enter submits, Escape cancels. A compact floating indicator shows recording state and mic level.
- **Warm engine**: a resident `whisper-server` keeps the model in RAM. Measured on an M-series Mac, that means 0.3-0.6s per dictation instead of 1.1-1.3s cold (large-v3-turbo, 8-9s clips). Sori falls back to `whisper-cli` automatically if the server is down.
- **Bilingual by design**: Korean, English, and mixed recordings all work. Embedded English inside Korean sentences survives untranslated.
- **AI cleanup (optional, free)**: dictation comes out with fillers ("um", "음", "어") removed, punctuation fixed, and false starts resolved to the corrected form ("Thursday... no wait, Friday" becomes "Friday"). This runs on Groq's free tier via `gpt-oss-120b`. A structural guard rejects any response where the model answered instead of cleaned, so the worst case is always your raw words, never the model's.
- **Custom vocabulary**: a glossary and names list biases recognition toward your terms (product names, teammates, jargon).
- **Learns from your corrections**: fix a mis-transcribed word once (select and copy the corrected text) and Sori learns the replacement.
- **Smart spacing**: consecutive dictations get proper spacing between them.
- **Private**: audio never leaves your machine. The only optional network call is the text-cleanup step, which you can toggle off in the menu.

## Install

```bash
git clone https://github.com/keonheek/sori && cd sori
./install.sh
```

The installer checks for Xcode Command Line Tools and Homebrew, installs `whisper-cpp`, downloads the models (~1.8 GB), builds from source (one Swift file, no Xcode project), and starts Sori. Then grant Microphone, Accessibility, and Input Monitoring in System Settings when prompted.

For the optional AI cleanup, put a free [Groq API key](https://console.groq.com) in `~/.sori-groq` and enable **AI Cleanup (Groq)** in the menu-bar menu.

## Usage

| Action | Result |
|---|---|
| Hold Right ⌘, speak, release | Dictate (push-to-talk) |
| Tap Right ⌘ | Toggle recording on/off |
| Enter while recording | Stop, transcribe, paste, and press Enter |
| Escape while recording | Cancel, nothing pastes |
| Click the floating indicator | Same as Right ⌘ |

Transcribed text is pasted at the cursor and kept on the clipboard, so ⌘V recovers it if the paste landed in the wrong field.

## Configuration

Settings live in the menu-bar menu (Settings…) and in `~/.sori.conf` (JSON):

- `model`: transcription model (default `ggml-large-v3-turbo.bin`)
- `lang`: `"auto"` (recommended), or a fixed code like `"en"` / `"ko"`
- `warmEngine`: resident whisper-server (default on)
- `llmCleanup`: Groq cleanup layer (default off; enable it in the menu)
- `promptHint` / `aiTerms`: names and vocabulary to bias recognition. Terms earlier in the list carry more weight, since Whisper reads only the last ~223 prompt tokens and the list is truncated from the back.

## How it works

```
Right ⌘ down ──▶ record 16 kHz mono
Right ⌘ up   ──▶ language detect (base model, no prompt, ~0.2s)
             ──▶ transcribe (resident whisper-server, beam search, language locked)
             ──▶ rule-based cleanup (fillers, disfluencies)
             ──▶ optional LLM cleanup (Groq gpt-oss-120b, guarded)
             ──▶ paste at cursor
```

Details worth stealing if you're building your own:

- **Language detection must be prompt-free.** An English vocabulary prompt biases Whisper's language auto-detection toward English, enough to translate Korean speech outright. Detect on the raw audio first, then prompt.
- **whisper-server defaults to greedy decoding** (`beam-size -1`), while whisper-cli defaults to beam search 5. Greedy decoding causes repetition loops ("Monday, Monday, Monday...") on non-English speech. Sori spawns the server with `-bs 5 -bo 5`.
- **LLM cleanup needs a trap-test and an output guard.** An instruct model will happily *answer* dictation that sounds like a question ("could you use a better model?") instead of cleaning it. Sori wraps input in `<transcript>` tags, frames the model as a transformation function, and structurally validates the output (language match, length ratio, assistant-phrase detection). Any failure falls back to the raw transcript.
- **Prompt token budget is real.** Whisper keeps only the last ~223 prompt tokens, and dense proper-noun vocabulary tokenizes at ~2.4 chars/token, not 4. A long glossary silently cuts your names hint off the head of the prompt.

## Stable code signing (recommended)

macOS ties permission grants (Accessibility, Input Monitoring) to the app's code signature. With ad-hoc signing, every rebuild invalidates them. Create a self-signed code-signing certificate named `Sori Codesign` in Keychain Access (Certificate Assistant > Create a Certificate > Code Signing) and `install.sh` uses it automatically. Grants then survive rebuilds. After switching identities once, reset stale grants: `tccutil reset Accessibility dev.sori.app && tccutil reset ListenEvent dev.sori.app`, then relaunch.

## Requirements

- Apple Silicon or Intel Mac, macOS 13+
- Xcode Command Line Tools and Homebrew
- About 2 GB of disk for models, and about 1.7 GB of RAM while the warm engine is loaded (set `warmEngine` to false to run without it)

## Credits

Built on [whisper.cpp](https://github.com/ggml-org/whisper.cpp) by Georgi Gerganov and OpenAI's Whisper models. Optional cleanup via [Groq](https://groq.com).

## License

MIT. See [LICENSE](LICENSE).
