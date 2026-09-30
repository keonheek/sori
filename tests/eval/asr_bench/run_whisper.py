#!/usr/bin/env python3
# whisper.cpp through a warm whisper-server (restarted per set so the language flag matches).
#   run_whisper.py <tag> <ggml model path> [sets]
import json, subprocess, sys, time, urllib.request, uuid
from common import run, default_sets, SETS
PORT = 8931; LANG = {"Korean": "ko", "English": "en", None: "auto"}
def post(p):
    b = uuid.uuid4().hex
    body = (f"--{b}\r\nContent-Disposition: form-data; name=\"response_format\"\r\n\r\njson\r\n--{b}\r\nContent-Disposition: form-data; "
            f"name=\"file\"; filename=\"a.wav\"\r\nContent-Type: audio/wav\r\n\r\n").encode() + open(p, "rb").read() + f"\r\n--{b}--\r\n".encode()
    req = urllib.request.Request(f"http://127.0.0.1:{PORT}/inference", data=body, headers={"Content-Type": f"multipart/form-data; boundary={b}"})
    return json.load(urllib.request.urlopen(req, timeout=300))["text"].strip()
for s in default_sets(sys.argv):
    srv = subprocess.Popen(["whisper-server", "-m", sys.argv[2], "--port", str(PORT), "-l", LANG[SETS[s][1]], "-t", "8"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(120):
        try: urllib.request.urlopen(f"http://127.0.0.1:{PORT}/", timeout=1); break
        except Exception: time.sleep(0.5)
    try: run(f"{sys.argv[1]}_{s}", lambda p, lang: post(p), [s])
    finally: srv.terminate(); srv.wait()
