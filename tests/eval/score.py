#!/usr/bin/env python3
"""
score.py -- per-utterance accuracy of the resident Sori engine on a manifest of clips.

    python3 tests/eval/score.py tests/eval/smoke/manifest.tsv
    python3 tests/eval/score.py tests/eval/personal/manifest.tsv --json out.json

Manifest: one clip per line, `path<TAB>reference`. Paths are relative to the manifest.
Each clip is POSTed to the running qwen_server (Sori's own engine, port 8918 unless
--port says otherwise), so what is scored is exactly what dictation would paste,
minus Sori's post-processing.

Metric per utterance: CER when the reference is mostly Hangul, WER otherwise. Korean is
scored on characters because Korean word segmentation is unstable across models and a
single spacing choice would otherwise count as two word errors. Mixed clips are the
whole point (HiKE, EACL 2026: code-switched error rates run 3-13x monolingual), so the
report also prints both metrics over the mixed subset.

Keep personal audio OUT of git: tests/eval/personal/ is ignored. Only the smoke set
(synthesized by make_smoke_set.sh) is reproducible from the repo.
"""
import argparse
import json
import os
import re
import shutil
import sys
import tempfile
import urllib.request

PUNCT = re.compile(r"[^\w\s]", re.UNICODE)


def norm(s):
    s = s.lower().strip()
    s = PUNCT.sub("", s)
    return re.sub(r"\s+", " ", s)


def hangul_ratio(s):
    chars = [c for c in s if not c.isspace()]
    if not chars:
        return 0.0
    return sum(1 for c in chars if "가" <= c <= "힣") / len(chars)


def edit_distance(a, b):
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def wer(ref, hyp):
    r, h = norm(ref).split(), norm(hyp).split()
    return edit_distance(r, h) / max(len(r), 1)


def cer(ref, hyp):
    r, h = norm(ref).replace(" ", ""), norm(hyp).replace(" ", "")
    return edit_distance(r, h) / max(len(r), 1)


def transcribe(port, path, allow_dir):
    # The engine only accepts paths under Sori's work dir, so stage a copy there.
    staged = os.path.join(allow_dir, "eval_" + os.path.basename(path))
    shutil.copyfile(path, staged)
    try:
        body = json.dumps({"path": staged}).encode()
        req = urllib.request.Request(f"http://127.0.0.1:{port}/inference", data=body,
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=120) as r:
            return json.load(r).get("text", "")
    finally:
        try:
            os.remove(staged)
        except OSError:
            pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("manifest")
    ap.add_argument("--port", type=int, default=8918)
    ap.add_argument("--json", help="write per-utterance rows here")
    ap.add_argument("--allow-dir", default=os.path.join(tempfile.gettempdir(), "sori"),
                    help="Sori's work dir (the engine refuses paths outside it)")
    args = ap.parse_args()
    os.makedirs(args.allow_dir, exist_ok=True)

    base = os.path.dirname(os.path.abspath(args.manifest))
    rows = []
    with open(args.manifest, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            rel, ref = line.split("\t", 1)
            path = os.path.join(base, rel)
            hyp = transcribe(args.port, path, args.allow_dir)
            hr = hangul_ratio(ref)
            metric = "CER" if hr > 0.5 else "WER"
            score = cer(ref, hyp) if metric == "CER" else wer(ref, hyp)
            rows.append({"clip": rel, "ref": ref, "hyp": hyp, "metric": metric,
                         "score": round(score, 4), "mixed": 0.05 < hr < 0.95,
                         "cer": round(cer(ref, hyp), 4), "wer": round(wer(ref, hyp), 4)})
            print(f"{score:6.1%} {metric}  {rel}")
            if score > 0:
                print(f"         ref: {ref}\n         hyp: {hyp}")

    if not rows:
        sys.exit("empty manifest")
    def mean(xs):
        return sum(xs) / len(xs) if xs else float("nan")
    print("\n" + "-" * 60)
    print(f"clips: {len(rows)}")
    print(f"mean WER (Latin refs): {mean([r['score'] for r in rows if r['metric']=='WER']):.1%}")
    print(f"mean CER (Hangul refs): {mean([r['score'] for r in rows if r['metric']=='CER']):.1%}")
    mixed = [r for r in rows if r["mixed"]]
    if mixed:
        print(f"mixed subset ({len(mixed)}): CER {mean([r['cer'] for r in mixed]):.1%}, "
              f"WER {mean([r['wer'] for r in mixed]):.1%}")
    if args.json:
        with open(args.json, "w", encoding="utf-8") as f:
            json.dump(rows, f, ensure_ascii=False, indent=1)
        print(f"rows -> {args.json}")


if __name__ == "__main__":
    main()
