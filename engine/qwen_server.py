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
                      -> {"text": "..."}  or  {"error": "..."} with 500

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
        if self.path.rstrip("/") != "/inference":
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
            with _lock:
                r = _model.generate(path, **kwargs)
            raw = getattr(r, "text", None)
            text = (raw if raw is not None else str(r)).strip()
            log(f"inference {time.time() - t0:.2f}s -> {len(text)} chars")
            self._send(200, {"text": text})
        except TypeError:
            # Older mlx-audio builds reject `system_prompt`; retry without it
            # rather than failing the dictation outright.
            try:
                kwargs.pop("system_prompt", None)
                with _lock:
                    r = _model.generate(path, **kwargs)
                raw = getattr(r, "text", None)
                text = (raw if raw is not None else str(r)).strip()
                self._send(200, {"text": text})
            except Exception as e:                           # noqa: BLE001
                self._send(500, {"error": f"{type(e).__name__}: {e}"})
        except Exception as e:                               # noqa: BLE001
            log(f"inference FAILED: {type(e).__name__}: {e}")
            self._send(500, {"error": f"{type(e).__name__}: {e}"})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8918)
    ap.add_argument("--model", default=os.environ.get("SORI_QWEN_REPO", DEFAULT_REPO))
    args = ap.parse_args()

    # Load in the background so the port opens immediately and Sori's health check
    # can distinguish "still loading" (503) from "not running at all" (connection refused).
    threading.Thread(target=load, args=(args.model,), daemon=True).start()

    srv = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    log(f"listening on 127.0.0.1:{args.port}")
    srv.serve_forever()


if __name__ == "__main__":
    main()
