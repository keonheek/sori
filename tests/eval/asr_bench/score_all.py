#!/usr/bin/env python3
"""Summarise out/*.jsonl. KO = CER on FLEURS (parenthetical glosses stripped: they are not spoken);
EN = WER after Whisper's English normalizer (pip install whisper-normalizer), so "1855" = "eighteen fifty five";
mixed = CER/WER from ../score.py on the hand-corrected personal clips; RTF = compute secs / audio secs."""
import glob, json, os, re, statistics, sys, wave
HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, os.path.join(HERE, ".."))
from score import cer, wer
from whisper_normalizer.english import EnglishTextNormalizer
EN, PAREN = EnglishTextNormalizer(), re.compile(r"\([^)]*\)")
def dur(p): w = wave.open(p); return w.getnframes() / w.getframerate()
R = {}
for p in sorted(glob.glob(os.path.join(HERE, "out", "*.jsonl"))):
    tag = re.sub(r"_(ko|en|gold|raw)$", "", os.path.basename(p)[:-6])
    R.setdefault(tag, []).extend(json.loads(l) for l in open(p, encoding="utf-8"))
pct = lambda xs: f"{statistics.mean(xs)*100:5.1f}%" if xs else "  -   "
print(f"| model | KO CER | EN WER | mixed CER | mixed WER | RTF | median s/dictation |\n|---|---|---|---|---|---|---|")
for tag, rows in R.items():
    by = lambda s: [r for r in rows if r["set"] == s]
    ko = [cer(PAREN.sub("", r["ref"]).replace("-", " "), r["hyp"].replace("-", " ")) for r in by("ko")]
    en = [wer(EN(r["ref"]), EN(r["hyp"])) for r in by("en")]
    g, raw = by("gold"), [r["secs"] for r in by("raw")]
    rtf = sum(r["secs"] for r in rows) / sum(dur(r["path"]) for r in rows)
    print(f"| {tag} | {pct(ko)} | {pct(en)} | {pct([cer(r['ref'], r['hyp']) for r in g])} | {pct([wer(r['ref'], r['hyp']) for r in g])} | {rtf:.3f} | {statistics.median(raw) if raw else float('nan'):.2f} |")
