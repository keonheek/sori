#!/usr/bin/env python3
"""Download the public reference sets: FLEURS Korean test (40 clips) and LibriSpeech test-clean (20 clips).
Pulled through the Hugging Face datasets-server, resampled to 16 kHz mono with ffmpeg, into data/."""
import json, os, subprocess, urllib.request
HERE = os.path.dirname(os.path.abspath(__file__))
def fetch(dataset, config, text_key, n, stride, out):
    out = os.path.join(HERE, "data", out); os.makedirs(out, exist_ok=True); man, off = [], 0
    while len(man) < n:
        u = f"https://datasets-server.huggingface.co/rows?dataset={dataset}&config={config}&split=test&offset={off}&length=20"
        rows = json.load(urllib.request.urlopen(u))["rows"]; off += stride      # stride spreads clips across speakers
        for r in rows[:5]:
            row = r["row"]; a = row["audio"]; src = (a[0] if isinstance(a, list) else a)["src"]
            fn = f"{config}_{row['id']}_{len(man):02d}.wav"; tmp = os.path.join(out, "tmp.bin")
            urllib.request.urlretrieve(src, tmp)
            subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", tmp, "-ar", "16000", "-ac", "1", os.path.join(out, fn)], check=True)
            man.append(f"{fn}\t{row[text_key].strip()}")
            if len(man) >= n: break
    os.remove(os.path.join(out, "tmp.bin"))
    open(os.path.join(out, "manifest.tsv"), "w", encoding="utf-8").write("\n".join(man) + "\n"); print(out, len(man))
fetch("google/fleurs", "ko_kr", "raw_transcription", 40, 37, "fleurs_ko")
fetch("openslr/librispeech_asr", "clean", "text", 20, 131, "ls_en")
