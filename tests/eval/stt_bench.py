#!/usr/bin/env python3
"""Side-by-side STT provider bench on the personal manifest (file<TAB>reference).
Providers: local (Sori engine :8918), groq (whisper-large-v3-turbo, free), gemini (gemini-3.5-transcribe),
openai (gpt-transcribe, gpt-4o-mini-transcribe). Keys: ~/.sori-groq, GEMINI_API_KEY, OPENAI_API_KEY."""
import base64, json, os, sys, time, urllib.request, mimetypes, uuid, statistics
sys.path.insert(0, os.path.dirname(__file__)); from score import cer, transcribe as local_transcribe, norm
HINT = "Claude Code, MCP, LangGraph, RAG, SDIC, SKKU, Notion, Groq, Qwen, Sori, Wispr Flow, 자소서, 제자훈련"
def post(url, data, headers, timeout=120):
    req = urllib.request.Request(url, data=data, headers={"User-Agent": "Sori-bench", **headers}); t = time.time()
    try: r = urllib.request.urlopen(req, timeout=timeout); return json.load(r), time.time() - t, None
    except urllib.error.HTTPError as e: return None, time.time() - t, f"HTTP {e.code} {e.read().decode()[:160]}"
def multipart(fields, fpath):
    b = uuid.uuid4().hex; body = b""
    for k, v in fields.items(): body += f"--{b}\r\nContent-Disposition: form-data; name=\"{k}\"\r\n\r\n{v}\r\n".encode()
    body += f"--{b}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{os.path.basename(fpath)}\"\r\nContent-Type: audio/wav\r\n\r\n".encode() + open(fpath, "rb").read() + f"\r\n--{b}--\r\n".encode()
    return body, {"Content-Type": f"multipart/form-data; boundary={b}"}
def groq(p):
    key = open(os.path.expanduser("~/.sori-groq")).read().strip()
    body, h = multipart({"model": "whisper-large-v3-turbo", "response_format": "json", "prompt": HINT}, p)
    r, dt, err = post("https://api.groq.com/openai/v1/audio/transcriptions", body, {**h, "Authorization": "Bearer " + key})
    return (r or {}).get("text"), dt, err
def openai(model):
    def f(p):
        body, h = multipart({"model": model, "response_format": "json", "prompt": HINT}, p)
        r, dt, err = post("https://api.openai.com/v1/audio/transcriptions", body, {**h, "Authorization": "Bearer " + os.environ["OPENAI_API_KEY"]})
        return (r or {}).get("text"), dt, err
    return f
def gemini(p):
    b64 = base64.b64encode(open(p, "rb").read()).decode()
    body = {"contents": [{"parts": [{"inlineData": {"mimeType": "audio/wav", "data": b64}}, {"text": "Transcribe this audio exactly as spoken. Korean and English may be mixed; keep each language as spoken. Output only the transcript."}]}]}
    r, dt, err = post(f"https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-transcribe:generateContent?key={os.environ['GEMINI_API_KEY']}", json.dumps(body).encode(), {"Content-Type": "application/json"})
    if err: return None, dt, err
    try: return r["candidates"][0]["content"]["parts"][0]["text"].strip(), dt, None
    except Exception: return None, dt, str(r)[:160]
def local(p):
    t = time.time(); return local_transcribe(8918, p, os.path.join(os.environ.get("TMPDIR", "/tmp"), "sori")), time.time() - t, None
PROV = {"local": local, "groq-whisper-turbo": groq, "gemini-3.5-transcribe": gemini, "gpt-transcribe": openai("gpt-transcribe"), "gpt-4o-mini-transcribe": openai("gpt-4o-mini-transcribe")}
def main():
    man = sys.argv[1]; want = sys.argv[2].split(",") if len(sys.argv) > 2 else list(PROV)
    rows = [l.rstrip("\n").split("\t") for l in open(man, encoding="utf-8") if l.strip()]
    base = os.path.dirname(man); res = {n: [] for n in want}
    for f, ref in rows:
        print(f"\n### {f}\nREF : {ref}")
        for n in want:
            hyp, dt, err = PROV[n](os.path.join(base, f))
            if err or hyp is None: print(f"{n:24s} ERR {err}"); continue
            c = cer(ref, hyp); res[n].append((c, dt)); print(f"{n:24s} CER {c*100:5.1f}%  {dt:4.1f}s  {hyp}")
    print("\n=== summary (mean CER over clips, median latency)")
    for n in want:
        if res[n]: print(f"{n:24s} CER {statistics.mean(c for c,_ in res[n])*100:5.1f}%  n={len(res[n])}  {statistics.median(d for _,d in res[n]):.1f}s")
if __name__ == "__main__": main()
