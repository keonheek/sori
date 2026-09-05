#!/usr/bin/env python3
"""
qwen_server.py -- resident Qwen3-ASR engine for Sori.

Mirrors what whisper-server did for the ggml lane: load the model ONCE, keep it in
RAM, answer transcription requests over loopback HTTP. The model load is ~1s and
warm inference is ~0.4s on an 8s clip, so paying the load per keypress (the CLI
path costs ~9s, almost all of it Python startup) is not an option.

Contract (loopback only, no auth -- it is bound to 127.0.0.1):

    GET  /            -> 200 "ok" once the model is loaded, 503 while loading
    POST /inference   -> {"path": "/abs/file.wav", "language": "ko"|null,
                          "context": "Groq, Pinecone, ..."}
                      -> {"text": "...", "speech_ms": N|null}
                         (text is "" when TEN-VAD found < --vad-min-ms of speech;
                          inference is skipped entirely in that case)
                         or {"error": "..."} with 400/403/500

`language` may be omitted: Qwen3-ASR does its own language identification across
52 languages, which is why Sori no longer runs a separate ggml-base detection pass.
`context` is the hotword/vocabulary bias -- Sori's aiTerms list goes here.
"""
import argparse
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DEFAULT_REPO = "mlx-community/Qwen3-ASR-1.7B-8bit"

_model = None
_model_err = None
_lock = threading.Lock()   # mlx generate is not reentrant; serialize inference
_vad = None                # TEN-VAD instance, or None when unavailable / disabled
_allow_dir = None          # only transcribe files under this dir (Sori's work dir)
_gen_timeout = 45.0        # seconds; a hung generate exits the process so Sori respawns it
_vad_min_ms = 200          # below this much detected speech the clip is treated as silence


def log(msg):
    print(f"[qwen_server] {msg}", file=sys.stderr, flush=True)


def load(repo):
    global _model, _model_err
    try:
        import warnings
        warnings.filterwarnings("ignore")
        from mlx_audio.stt.utils import load_model
        t0 = time.time()
        _model = load_model(repo)
        log(f"model ready in {time.time() - t0:.2f}s ({repo})")
    except Exception as e:                                   # noqa: BLE001
        _model_err = f"{type(e).__name__}: {e}"
        log(f"model load FAILED: {_model_err}")


def load_vad():
    """TEN-VAD (Apache-2.0, `pip install ten-vad`): 16 kHz, 256-sample hops, ~13 ms per
    second of audio on Apple Silicon. Gates short taps and noise-only clips BEFORE the
    1.7B model runs. Chosen 2026-09-03 over Silero's ONNX build, which scored 0.12 on
    clear synthesized speech under its documented input contract. Optional: a missing
    package just disables the gate."""
    global _vad
    try:
        from ten_vad import TenVad
        _vad = TenVad(hop_size=256, threshold=0.5)
        log("vad ready (ten-vad)")
    except Exception as e:                                   # noqa: BLE001
        log(f"vad unavailable ({type(e).__name__}: {e}) -- short-tap gate off")


def speech_ms(path):
    """Milliseconds of detected speech in a 16 kHz mono int16 WAV, or None when the
    file is not in that format (Sori always writes it) or the VAD is off."""
    if _vad is None:
        return None
    try:
        import wave
        import numpy as np
        with wave.open(path) as w:
            if w.getframerate() != 16000 or w.getnchannels() != 1 or w.getsampwidth() != 2:
                return None
            a = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16)
        hop = 256
        n = 0
        for i in range(0, len(a) - hop + 1, hop):
            prob, _flag = _vad.process(a[i:i + hop])
            if prob > 0.5:
                n += 1
        return n * hop * 1000 // 16000
    except Exception as e:                                   # noqa: BLE001
        log(f"vad error ({type(e).__name__}: {e}) -- clip passed through")
        return None


def _read_pcm(path):
    """int16 samples of a 16 kHz mono WAV, or None when the file is not in that format."""
    import wave
    import numpy as np
    with wave.open(path) as w:
        if w.getframerate() != 16000 or w.getnchannels() != 1 or w.getsampwidth() != 2:
            return None
        return np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16)


def _write_pcm(path, a):
    import wave
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(16000)
        w.writeframes(a.tobytes())


def _slice_wav(path, offset_ms, end_ms=None):
    """Write samples [offset_ms, end_ms) of `path` to a sibling temp WAV and return its
    path, or None when the format is wrong. Sibling so --allow-dir still covers it."""
    a = _read_pcm(path)
    if a is None:
        return None
    lo = max(0, offset_ms * 16)
    hi = len(a) if end_ms is None else min(len(a), end_ms * 16)
    out = os.path.join(os.path.dirname(path), f".seg_{os.getpid()}_{threading.get_ident()}.wav")
    _write_pcm(out, a[lo:hi])
    return out


def find_commit_point(path, offset_ms, min_new_ms, tail_ms):
    """Chunked dictation: look at the audio after `offset_ms` and pick a cut inside the
    LAST pause of at least `tail_ms` of VAD silence. Cutting only inside real silence is
    what keeps a chunk boundary from splitting a word. Returns (cut_ms, speech_ms) or
    None when there is no such pause yet, or the committed span would be shorter than
    `min_new_ms` (a floor so the engine is not called every second for one word)."""
    if _vad is None:
        return None
    a = _read_pcm(path)
    if a is None:
        return None
    a = a[offset_ms * 16:]
    hop = 256                                   # 16 ms per VAD frame
    tail_frames = max(1, tail_ms // 16)
    probs = []
    for i in range(0, len(a) - hop + 1, hop):
        prob, _flag = _vad.process(a[i:i + hop])
        probs.append(prob > 0.5)
    # Last silence run of >= tail_frames. Walk backwards so the newest pause wins.
    run_end = None
    best = None
    i = len(probs) - 1
    while i >= 0:
        if not probs[i]:
            if run_end is None:
                run_end = i
        else:
            if run_end is not None and run_end - i >= tail_frames:
                best = (i + 1, run_end)         # silence frames [i+1, run_end]
                break
            run_end = None
        i -= 1
    if best is None and run_end is not None and run_end + 1 >= tail_frames:
        best = (0, run_end)                     # everything after offset is silence
    if best is None:
        return None
    s, e = best
    cut_frame = s + min(tail_frames // 2, (e - s) // 2)   # a little into the pause
    cut_ms = cut_frame * hop * 1000 // 16000
    if cut_ms < min_new_ms:
        return None
    speech = sum(1 for p in probs[:cut_frame] if p) * hop * 1000 // 16000
    return cut_ms, speech


def generate_with_timeout(path, kwargs):
    """Run the (non-reentrant) generate under the lock on a worker thread. If it does not
    return within _gen_timeout the process EXITS: the lock would otherwise stay held and
    every later dictation would wait out Sori's 60 s client timeout. Sori sees the dead
    engine on its next request and respawns it (launch-time load is ~2-3 s)."""
    box = {}

    def run():
        try:
            with _lock:
                box["r"] = _model.generate(path, **kwargs)
        except BaseException as e:                           # noqa: BLE001
            box["e"] = e

    t = threading.Thread(target=run, daemon=True)
    t.start()
    t.join(_gen_timeout)
    if t.is_alive():
        raise TimeoutError(f"inference exceeded {_gen_timeout:.0f}s")
    if "e" in box:
        raise box["e"]
    r = box["r"]
    raw = getattr(r, "text", None)
    return (raw if raw is not None else str(r)).strip()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):        # silence per-request stderr spam
        pass

    def _send(self, code, payload):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if _model is not None:
            self._send(200, {"status": "ok"})
        else:
            self._send(503, {"status": "loading", "error": _model_err})

    def do_POST(self):
        route = self.path.rstrip("/")
        if route not in ("/inference", "/segment"):
            self._send(404, {"error": "not found"})
            return
        if _model is None:
            self._send(503, {"error": _model_err or "model still loading"})
            return
        try:
            n = int(self.headers.get("Content-Length") or 0)
            req = json.loads(self.rfile.read(n) or b"{}")
        except Exception as e:                               # noqa: BLE001
            self._send(400, {"error": f"bad request: {e}"})
            return

        path = req.get("path") or ""
        if not os.path.isfile(path):
            self._send(400, {"error": f"no such audio file: {path}"})
            return
        # Loopback has no auth, so the one thing worth refusing is "transcribe any file
        # this user can read". Sori passes its own work dir as --allow-dir.
        if _allow_dir and not os.path.realpath(path).startswith(os.path.realpath(_allow_dir) + os.sep):
            self._send(403, {"error": f"path outside the allowed dir: {path}"})
            return

        # Chunked dictation (Sori's chunkedTranscribe). /segment: commit everything after
        # `offset_ms` up to the last real pause; /inference with offset_ms: the tail that
        # was left uncommitted when the key came up. Both transcribe a sliced temp WAV so
        # each second of audio goes through the model exactly once.
        offset_ms = int(req.get("offset_ms") or 0)
        end_ms = None
        commit_ms = None
        if route == "/segment":
            cp = find_commit_point(path, offset_ms, int(req.get("min_new_ms") or 3000),
                                   int(req.get("tail_ms") or 450))
            if cp is None:
                self._send(200, {"text": "", "committed_ms": offset_ms})
                return
            cut_ms, seg_speech = cp
            end_ms = offset_ms + cut_ms
            commit_ms = end_ms
            if seg_speech < _vad_min_ms:
                log(f"segment {offset_ms}-{end_ms}ms: {seg_speech}ms speech -> skipped")
                self._send(200, {"text": "", "committed_ms": commit_ms, "speech_ms": seg_speech})
                return
        seg = None
        if offset_ms > 0 or end_ms is not None:
            seg = _slice_wav(path, offset_ms, end_ms)
            if seg is None:
                self._send(400, {"error": "offset slicing needs a 16 kHz mono int16 WAV"})
                return
            path = seg

        ms = speech_ms(path)
        if ms is not None and ms < _vad_min_ms:
            if seg:
                os.unlink(seg)
            log(f"vad: {ms}ms speech < {_vad_min_ms}ms -> skipped inference")
            self._send(200, {"text": "", "speech_ms": ms})
            return

        kwargs = {}
        if req.get("language"):
            kwargs["language"] = req["language"]
        if req.get("context"):
            # Vocabulary bias. NOTE the parameter is `system_prompt` -- generate()
            # takes **kwargs, so a wrong name (e.g. `context`) is swallowed in
            # silence and looks like the bias simply had no effect.
            #
            # Measured 2026-08-12 on the 8-line bilingual clip: biasing fixed
            # "Grok"->"Groq" but made "Qwen 3.6" come back as "Claude 3.6" (first
            # entry in the glossary) and duplicated "Pinecone Pinecone". Net score
            # unchanged at 11/12, and a plausible wrong brand is worse than an
            # implausible one because it survives proofreading. Sori therefore
            # leaves this empty by default; the plumbing stays for experiments.
            # Passed through verbatim: Sori builds the full sentence (and applies the
            # term cap) in Config.biasPrompt, so wrapping it again here would nest
            # two instruction prefixes.
            kwargs["system_prompt"] = req["context"]

        try:
            t0 = time.time()
            try:
                text = generate_with_timeout(path, kwargs)
            except TypeError:
                # Older mlx-audio builds reject `system_prompt`; retry without it
                # rather than failing the dictation outright.
                kwargs.pop("system_prompt", None)
                text = generate_with_timeout(path, kwargs)
            vad_note = f", vad {ms}ms" if ms is not None else ""
            seg_note = f" [{route[1:]} {offset_ms}-{end_ms if end_ms is not None else 'end'}ms]" if seg else ""
            log(f"inference {time.time() - t0:.2f}s -> {len(text)} chars{vad_note}{seg_note}")
            out = {"text": text, "speech_ms": ms}
            if commit_ms is not None:
                out["committed_ms"] = commit_ms
            self._send(200, out)
        except TimeoutError as e:
            log(f"inference TIMEOUT: {e} -- exiting so Sori respawns the engine")
            self._send(500, {"error": f"TimeoutError: {e}"})
            try:
                self.wfile.flush()
            except Exception:                                # noqa: BLE001
                pass
            threading.Timer(0.2, os._exit, [3]).start()
        except Exception as e:                               # noqa: BLE001
            log(f"inference FAILED: {type(e).__name__}: {e}")
            self._send(500, {"error": f"{type(e).__name__}: {e}"})
        finally:
            if seg:
                try:
                    os.unlink(seg)
                except OSError:
                    pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8918)
    ap.add_argument("--model", default=os.environ.get("SORI_QWEN_REPO", DEFAULT_REPO))
    ap.add_argument("--allow-dir", default=None,
                    help="only transcribe WAVs under this directory (Sori passes its work dir)")
    ap.add_argument("--gen-timeout", type=float, default=45.0,
                    help="seconds before a hung inference exits the process")
    ap.add_argument("--vad-min-ms", type=int, default=200,
                    help="clips with less detected speech than this skip inference; 0 disables")
    args = ap.parse_args()
    global _allow_dir, _gen_timeout, _vad_min_ms
    _allow_dir, _gen_timeout, _vad_min_ms = args.allow_dir, args.gen_timeout, args.vad_min_ms

    # Load in the background so the port opens immediately and Sori's health check
    # can distinguish "still loading" (503) from "not running at all" (connection refused).
    def load_all():
        load(args.model)
        if _vad_min_ms > 0:
            load_vad()
    threading.Thread(target=load_all, daemon=True).start()

    srv = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    log(f"listening on 127.0.0.1:{args.port}")
    srv.serve_forever()


if __name__ == "__main__":
    main()
