# Sori eval harness

Scores the resident engine on a manifest of clips, one row per utterance, CER for Korean
references and WER for Latin ones, plus both metrics over the code-switched subset.

```bash
./tests/eval/make_smoke_set.sh                 # synthesized plumbing check (say → 16 kHz WAV)
python3 tests/eval/score.py tests/eval/smoke/manifest.tsv
```

Real numbers need real audio. Put your own dictations in `tests/eval/personal/` (ignored by
git) with a `manifest.tsv` of `file.wav<TAB>reference`, hand-corrected once:

```bash
python3 tests/eval/score.py tests/eval/personal/manifest.tsv --json personal.json
```

Run it before and after any change to the engine, the model, the bias vocabulary, or the
cleanup rules. The engine must be running (Sori keeps it warm on port 8918).
