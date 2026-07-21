<p align="center"><img src="docs/icon.png" width="100" alt="Sori"></p>

# Sori (소리)

Push-to-talk dictation for macOS. Hold Right ⌘, speak Korean or English or a mix of both, release, and the text lands at your cursor. Whisper runs locally; nothing is uploaded anywhere.

I built this after I stopped paying for a dictation subscription, and it ended up handling bilingual speech better than the paid tools did. Most Whisper apps break the moment you code-switch: Korean with an English tech term in the middle comes back translated, or as transliterated nonsense. The fix turned out to be small but non-obvious, and it's the main reason this repo might interest you even if you never install it (see [notes](#notes-for-people-building-their-own) below).

## Install

Prebuilt: download the zip from [Releases](https://github.com/keonheek/sori/releases), unzip into `/Applications`, right-click > Open the first time (unsigned app warning, once). Then follow step 4 in the release notes to install whisper-cpp and the models.

From source:

```bash
git clone https://github.com/keonheek/sori && cd sori
./install.sh
```

Either way, macOS will ask for Microphone, Accessibility, and Input Monitoring. All three are needed: mic for obvious reasons, the other two to catch the Right ⌘ key globally and paste the result.

## Use

Hold Right ⌘ and talk, or tap it to toggle. Enter while recording stops, transcribes, pastes, and submits. Escape cancels. The pasted text stays on the clipboard so ⌘V recovers it if it landed in the wrong window.

Dictation comes out cleaned: fillers ("um", "음", "어") stripped and self-corrections resolved to what you meant ("목요일에... 아니다, 금요일에" pastes as 금요일에). The rule-based pass is local. There's a second, optional pass through an LLM on Groq's free tier: put a [free API key](https://console.groq.com) in `~/.sori-groq` and flip "AI Cleanup" in the menu. If the model misbehaves, a guard throws its output away and pastes your raw words instead.

Fix a mis-heard word once (select the correction, ⌘C) and Sori remembers the replacement.

Config is a JSON file at `~/.sori.conf`: model, language (`auto` recommended), vocabulary hints, warm engine on/off. The vocabulary list is truncated from the back at ~223 tokens, so put the names you actually say near the front.

## Notes for people building their own

Four things that cost me real debugging time:

**Whisper's language auto-detect is poisoned by your vocabulary prompt.** Feed it an English glossary and it starts detecting Korean speech as English, at which point it doesn't mis-transcribe, it *translates*. "발표는 목요일에" came back as "The announcement is Monday." The fix: detect the language first in a separate pass with no prompt at all (the base model does it in ~0.2s at p>0.98), then transcribe with the language pinned. After that the English prompt only influences spelling, never language.

**whisper-server and whisper-cli have different decoding defaults.** The server ships with greedy decoding (`beam-size -1`); the CLI uses beam search 5. Greedy is what produces the classic "Monday, Monday, Monday, Monday" repetition loop on non-English audio. Sori keeps a resident whisper-server for speed (0.3-0.6s per dictation on Apple Silicon vs 1.1-1.3s reloading the model each press) but spawns it with `-bs 5 -bo 5` to get CLI-quality output.

**An instruct LLM will answer your dictation instead of cleaning it.** My first cleanup prompt worked until I dictated a sentence that sounded like a request, and the model replied "I can clean up the mixed Korean and English text for you..." straight into the text field I was typing in. Prompt framing helps (transcript in tags, model framed as a pure transform), but the real fix is structural validation of the output: same language as input, sane length ratio, no assistant phrases. Fail any check and the raw transcript pastes.

**Whisper keeps only the last 223 prompt tokens, and proper nouns tokenize at ~2.4 chars each, not 4.** My "under the limit" glossary was silently cutting the names hint off the head of the prompt on every single dictation.

## Rebuilding without losing permissions

macOS ties Accessibility/Input Monitoring grants to the code signature, and ad-hoc signatures change on every build. If you hack on the source, create a self-signed code-signing cert named `Sori Codesign` in Keychain Access; `install.sh` picks it up and your grants survive rebuilds. After the identity switch, clear the stale grants once: `tccutil reset Accessibility dev.sori.app && tccutil reset ListenEvent dev.sori.app`.

## Requirements and credits

macOS 13+, Command Line Tools, Homebrew, ~2 GB disk for models, ~1.7 GB RAM while the warm engine is up (`warmEngine: false` to go without). Built on [whisper.cpp](https://github.com/ggml-org/whisper.cpp). One Swift file, no Xcode project, no dependencies beyond whisper-cpp itself.

MIT.
