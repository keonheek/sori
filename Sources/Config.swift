import Cocoa
import AVFoundation
import CoreAudio
import Carbon.HIToolbox
import IOKit.hid

// MARK: - Config (JSON at ~/.sori.conf — editable in Settings, no rebuild needed)
struct Replacement: Codable { var from: String; var to: String }
struct Config: Codable {
    // Hugging Face repo id for the Qwen3-ASR engine. Replaced the ggml `model`
    // field 2026-08-12; the old key is kept below so an existing ~/.sori.conf
    // still decodes, but nothing reads it any more.
    var asrModel: String? = nil          // default: mlx-community/Qwen3-ASR-1.7B-8bit
    var model: String = "ggml-large-v3-turbo.bin"   // DEAD: pre-Qwen ggml filename
    var lang: String = "en"
    var sound: Bool = true
    var promptHint: String = ""
    var replacements: [Replacement] = []
    var aiTerms: String? = nil           // curated AI/dev vocabulary
    var aiTermsEnabled: Bool? = nil      // toggle the AI vocabulary on/off
    // Feed aiTerms to the ASR engine as a bias prompt. Default OFF: measured
    // 2026-08-12 it fixed "Grok"->"Groq" but hallucinated "Qwen 3.6" into
    // "Claude 3.6" (first glossary entry) and duplicated "Pinecone Pinecone".
    // Net term score was unchanged, so the bias is not worth a confident wrong brand.
    var asrBias: Bool? = nil
    var pressEnter: Bool? = nil          // auto-press Enter after pasting (Spokenly-style submit)
    var cleanupEnabled: Bool? = nil      // Wispr-Flow-style: strip fillers, fix disfluencies (rule-based)
    var llmCleanup: Bool? = nil          // Tier 2: send to a local/remote LLM for grammar+redundancy rewrite
    var learnedReplacements: [Replacement]? = nil  // auto-learned from your repeated edits
    var learnEdits: Bool? = nil          // watch the clipboard for in-place corrections and learn them
    var livePreview: Bool? = nil         // show live partial transcription in the panel (uses a fast model)
    var partialModel: String? = nil      // model for live preview (default ggml-base.bin — fast)
    var warmEngine: Bool? = nil          // keep whisper-server resident (model stays in RAM; ~4x faster final transcription). CLI fallback when the server is down.
    var panelStyle: String? = nil        // "classic" (default, full preview) or "compact" (thin floating indicator)
    // Hide the compact indicator while everything else keeps working (Right ⌘ still dictates,
    // the menu-bar icon still shows state). NOT a style switch — style stays "compact"
    // (feedback 2026-07-27). The old compactFracX/compactFracY position keys are gone: the
    // indicator is now permanently pinned to bottom-center, so there is nothing to store.
    // A stale pair left in an existing ~/.sori.conf is ignored by the decoder and dropped
    // on the next save.
    var compactHidden: Bool? = nil
    // Capture from the built-in mic whenever the system default input is a Bluetooth device
    // (AirPods). Opening a Bluetooth mic flips the link from A2DP to the HFP call profile,
    // which pauses whatever is playing and costs ~1s per switch, each way, on every press.
    // Default ON; set false to dictate through the earbuds' mic anyway. (2026-09-20)
    var avoidBluetoothMic: Bool? = nil
    var inputDeviceUID: String? = nil      // Microphone menu pick (empty/nil = system default)
    // Eval capture: copy every finished recording into this directory (absolute path) before
    // transcription deletes it. Off when nil. Used with tests/eval/personal/capture.sh. (2026-09-20)
    var keepRecordingsDir: String? = nil
    // Smart Rewrite: app-aware grammar/punctuation/phrasing pass (Wispr-Flow-style) instead of
    // deletion-only filler cleanup. Reads the frontmost app + window title at the moment
    // recording stops and adapts register: chat apps stay casual, mail/docs get full sentences,
    // code/terminal/AI-chat keep every technical token verbatim. His ask 2026-09-20.
    var smartRewrite: Bool? = nil
    // Transcriber: "local" (Qwen3-ASR via qwen_server, default) or "openai" (gpt-transcribe over
    // the API, key in ~/.sori-openai). Picked 2026-09-20 on his read-aloud clip: gpt-transcribe
    // 3.1% CER vs local 13.4% / Groq whisper 7.1% / Gemini 3.5 10.6% / ReturnZero 17.1%.
    // The local engine still runs the VAD gate (vad_only) and is the fallback when the API fails.
    var asrProvider: String? = nil
    var asrCloudModel: String? = nil     // default gpt-transcribe ($0.0045/min)
    // Style per destination category (personal / work / email / other): tone + cleanup level.
    // Replaces the cleanupEnabled / llmCleanup / smartRewrite trio as the thing the pipeline reads
    // (those stay for decoding and seed the defaults — see StyleResolver). 2026-09-20.
    var styles: [String: StyleSetting]? = nil
    var historyRetentionDays: Int? = nil   // 0/nil = forever; purge older rows at launch
    var commandMode: Bool? = nil           // Experimental: Right ⌘ + Right ⌥ edits the selection
    var streamingASR: Bool? = nil          // Experimental: transcribe while recording (OpenAI)
    var chunkTerminalPaste: Bool? = nil    // split long terminal pastes so Claude Code shows them inline (default on)
    var skipRewriteInTerminals: Bool? = nil  // terminals (cmux, Claude Code) get Light cleanup instead of Smart Rewrite (default off)
    var screenVocab: Bool? = nil           // gpt-live-transcribe: words read off the focused window become keywords (default on)
    var liveDelay: String? = nil           // gpt-live-transcribe delay: minimal/low/medium/high/xhigh (default medium)
    var streamSegmentSec: Double? = nil    // streaming: commit at a pause once this much audio is pending (0/nil = one commit at release)
    var streamPauseMs: Int? = nil          // streaming: silence that counts as a pause (default 600)
    var streamCarryContext: Bool? = nil    // streaming: feed the text so far into the next segment's prompt
    var instantPaste: Bool? = nil          // Experimental: paste the rule-cleaned text at once, replace in place when the rewrite lands
    var contextAwareness: Bool? = nil      // send the focused field's text before the caret to Smart Rewrite (default on)
    // Paste lands where the dictation was STARTED, not wherever he is when ASR finishes: if he
    // switched app/field during the 1–3 s wait, the target is brought back for the ⌘V (+ Enter),
    // then he is returned to where he had moved. Default on. (2026-09-23)
    var pasteAtOrigin: Bool? = nil

    // Style anchor appended to every whisper prompt. Whisper mimics the prompt's WRITING
    // STYLE — a punctuated prose prompt yields punctuated output; the old bare comma-list
    // conditioned it toward unpunctuated run-ons. Static so transcribe() can also detect
    // the anchor leaking into transcripts of silence (whisper echoes prompt text).
    static let styleAnchor = "Okay, so here's the plan: first we test it, then we ship it. Sounds good, right? Great — let's begin."

    // Bias prompt for Qwen3-ASR (`system_prompt`). Replaced the whisper --prompt builder
    // 2026-08-12.
    //
    // THE CAP IS THE WHOLE POINT — measured on the 8-line bilingual clip, scoring 13 terms:
    //   no bias          11/13, 0 duplications, no hallucination  (missed Groq AND Qwen)
    //   9-term list      12/13, 1 duplication,  no hallucination  (fixed Groq AND Qwen)
    //   full 44-term     11/13, 1 duplication,  hallucinated "Claude 3.6" for "Qwen 3.6"
    // A long list makes the model reach for whatever brand sits nearest the top (Claude was
    // first in the glossary). Names go FIRST because they are the ones no model can guess;
    // the AI glossary fills whatever budget is left.
    static let maxBiasTerms = 12

    var biasPrompt: String {
        var terms: [String] = []
        let hint = promptHint.trimmingCharacters(in: .whitespaces)
        if !hint.isEmpty {
            terms += hint.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        if (aiTermsEnabled ?? true), let t = aiTerms?.trimmingCharacters(in: .whitespaces), !t.isEmpty {
            terms += t.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        terms = terms.filter { !$0.isEmpty }
        guard !terms.isEmpty else { return "" }
        let capped = Array(terms.prefix(Config.maxBiasTerms))
        return "Vocabulary that may appear in the audio, spell these exactly: "
             + capped.joined(separator: ", ")
    }

    // Kept only so the old whisper prompt builder below still compiles for reference during
    // the transition; nothing calls it. Remove once the Qwen lane has a few weeks on it.
    var combinedPrompt: String {
        let anchor = Config.styleAnchor
        let hint = promptHint.trimmingCharacters(in: .whitespaces)
        let names = hint.isEmpty ? "" : "Names: \(hint)."
        var glossary = ""
        if (aiTermsEnabled ?? true), let t = aiTerms?.trimmingCharacters(in: .whitespaces), !t.isEmpty {
            glossary = "Glossary: \(t)."
        }
        // REAL token cap: this vocabulary tokenizes at ~2.4 chars/token (measured with
        // the whisper tokenizer — the old "850 chars ≈ 220 tokens" assumption was 346
        // tokens, which cut the Names hint off the head on every single dictation).
        // 480 chars ≈ 200 tokens: safely under 223.
        let cap = 480
        let room = cap - names.count - anchor.count - 2
        if glossary.count > room {
            if room <= 20 { glossary = "" }
            else {
                glossary = String(glossary.prefix(room))
                // Trim back to a comma, but only within the tail — a comma-sparse
                // glossary must not pull the cut arbitrarily far back.
                if let cut = glossary.suffix(60).lastIndex(of: ",") { glossary = String(glossary[..<cut]) }
                glossary += "."
            }
        }
        return [glossary, names, anchor].filter { !$0.isEmpty }.joined(separator: " ")
    }

    static var path: String { (NSHomeDirectory() as NSString).appendingPathComponent(".sori.conf") }

    static func load() -> Config {
        guard let data = FileManager.default.contents(atPath: path),
              let c = try? JSONDecoder().decode(Config.self, from: data) else {
            wlog("config load failed -> defaults")
            return Config()
        }
        return c
    }

    func save() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted]
        if let data = try? enc.encode(self) {
            try? data.write(to: URL(fileURLWithPath: Config.path))
            wlog("config saved")
        }
    }

    // Apply find-replace pairs to transcribed text (whole-word, case-insensitive).
    // Includes both manual replacements and auto-learned ones.
    //
    // NOT `\b…\b` (2026-09-03): a rule whose `from` ends in punctuation or a quote
    // ("Skku.", "\"cacao talk\"") never matched, because `\b` after "." needs a word char
    // on the far side, and a sentence ends there. And ICU counts Hangul as \w, so an
    // English term glued to a Korean particle ("SDIC를") had no boundary either — the
    // rules were dead exactly in the bilingual case Sori exists for. Guard on LATIN
    // alphanumerics only: no Latin letter/digit may touch the match on either side, so
    // "bully" still cannot fire inside "bbully", but "SDIC를" and "Skku." both do.
    func applyReplacements(_ text: String) -> String {
        var out = text
        let all = replacements + (learnedReplacements ?? [])
        for r in all where !r.from.isEmpty {
            let pattern = "(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: r.from) + "(?![A-Za-z0-9])"
            if let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: r.to)
            }
        }
        return out
    }
}
