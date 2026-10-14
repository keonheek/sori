#!/usr/bin/env python3
"""Streaming-ASR bench on his kept dictations: release→text latency and drift from the production transcript.

Each clip is fed in real time (SORI_RT_PACE=1) through `Sori --stream-test`, all clips in parallel, so
pause segmentation behaves as it would live. Reference = the raw transcript Sori pasted for that clip
(whole-clip gpt-transcribe), so a baseline run (SORI_SEG=0) gives the noise floor.

  stream_bench.py <set.json> <label> [ENV=VAL ...]      e.g. stream_bench.py set.json seg8 SORI_SEG=8
Spend: gpt-transcribe ~$0.0045/min of audio; every run is appended to tests/eval/spend.tsv.
"""
import json, os, re, subprocess, sys, statistics as st, time
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
BIN = os.path.join(HERE, "..", "..", "build", "Sori-dev")
PRICE = {"gpt-transcribe": 0.0045, "gpt-live-transcribe": 0.017}


def letters(s):
    return [c for c in s.lower() if c.isalnum()]


def cer(ref, hyp):
    a, b = letters(ref), letters(hyp)
    if not a:
        return 0.0
    prev = list(range(len(b) + 1))
    for i in range(1, len(a) + 1):
        cur = [i] + [0] * len(b)
        for j in range(1, len(b) + 1):
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] != b[j - 1]))
        prev = cur
    return prev[-1] / len(a)


def breaks(s):
    return len(re.findall(r"[.?!。](\s|$)", s))


def run(clip, env):
    e = dict(os.environ, SORI_RT_PACE="1", SORI_LOG_STDERR="1", **env)
    t = time.time()
    p = subprocess.run([BIN, "--stream-test", clip["wav"]] + ([env["MODEL"]] if "MODEL" in env else []), capture_output=True, text=True, env=e, timeout=clip["dur"] + 60)
    out = p.stdout.strip().splitlines()
    lat = next((float(m.group(1)) for l in out if (m := re.match(r"commit→text ([\d.]+)s", l))), None)
    text = out[-1] if out else ""
    segs = len(re.findall(r"segment \d+ committed", p.stderr))
    return {"wav": os.path.basename(clip["wav"]), "dur": clip["dur"], "ko": clip.get("ko", False), "lat": lat,
            "segs": segs, "text": text, "ref": clip["raw"], "ok": p.returncode == 0, "wall": round(time.time() - t, 1)}


def main():
    set_path, label = sys.argv[1], sys.argv[2]
    env = dict(a.split("=", 1) for a in sys.argv[3:])
    clips = json.load(open(set_path))
    minutes = sum(c["dur"] for c in clips) / 60
    with ThreadPoolExecutor(len(clips)) as ex:
        res = list(ex.map(lambda c: run(c, env), clips))
    with open(os.path.join(HERE, "spend.tsv"), "a") as f:
        f.write(f"{time.strftime('%Y-%m-%d %H:%M')}\t{label}\t{minutes:.2f} min\t${minutes * PRICE.get(env.get("MODEL", "gpt-transcribe"), 0.017):.3f}\n")
    good = [r for r in res if r["ok"] and r["lat"] is not None]
    lats = sorted(r["lat"] for r in good)
    for r in res:
        r["cer"] = round(cer(r["ref"], r["text"]), 3) if r["ok"] else None
        r["dbreaks"] = breaks(r["text"]) - breaks(r["ref"])
    print(f"== {label} {env}  clips {len(res)} ok {len(good)}  audio {minutes:.1f} min  ~${minutes * PRICE.get(env.get("MODEL", "gpt-transcribe"), 0.017):.3f}")
    if lats:
        print(f"release→text p50 {st.median(lats):.2f}s  p90 {lats[int(.9 * len(lats)) - 1]:.2f}s  max {lats[-1]:.2f}s")
    cers = [r["cer"] for r in good]
    if cers:
        print(f"CER vs production p50 {st.median(cers):.3f} mean {st.mean(cers):.3f}  extra sentence breaks total {sum(r['dbreaks'] for r in good):+d}  segments {sum(r['segs'] for r in good)}")
    for r in res:
        print(f"  {r['dur']:6.1f}s {'KO' if r['ko'] else 'EN'} lat {r['lat']}  segs {r['segs']}  cer {r['cer']}  breaks {r['dbreaks']:+d}  {r['wav']}")
    json.dump(res, open(os.path.join(os.path.dirname(set_path), f"bench_{label}.json"), "w"), ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()
