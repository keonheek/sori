# Local ASR bench

Compares the free, on-device models Sori could ship. Six configurations, all run on the same Mac
(Apple M5 Pro, 48 GB), 2026-09-30.

## Results

| Model | KO CER | EN WER | Mixed CER | Mixed WER | RTF | Median s / dictation |
|---|---|---|---|---|---|---|
| Qwen3-ASR-1.7B bf16 (mlx-audio, Sori's engine code) | 4.5% | 2.4% | 6.9% | 15.9% | 0.043 | 0.90 |
| Qwen3-ASR-1.7B fp16 (mlx-qwen3-asr) | 4.3% | 2.4% | 7.1% | 13.6% | 0.044 | 0.99 |
| Qwen3-ASR-1.7B 8-bit (mlx-audio, current default) | 4.4% | 2.4% | 13.4% | 25.0% | 0.028 | 0.61 |
| Qwen3-ASR-0.6B fp16 (mlx-qwen3-asr) | 5.0% | 2.6% | 17.7% | 23.9% | 0.020 | 0.44 |
| whisper large-v3 (whisper.cpp) | 5.0% | 3.9% | 12.3% | 20.5% | 0.050 | 1.18 |
| whisper large-v3-turbo (whisper.cpp) | 6.3% | 3.0% | 12.6% | 20.5% | 0.023 | 0.57 |

- KO uses 40 clips from the FLEURS Korean test set with the language forced to Korean, scored by
  character error rate. Parenthetical glosses in the references, such as "(Schengen zone)", are stripped
  because nobody says them aloud.
- EN uses 20 LibriSpeech test-clean clips with the language forced to English, scored by word
  error rate after Whisper's English normalizer. That way "1855" and "eighteen fifty five" count as the same.
- Mixed is one hand-corrected, 8-line Korean/English dictation full of product names (read
  aloud, about 56 s), with language on auto. It is n=1, so treat it as a signal, not a verdict.
- Speed comes from 19 real push-to-talk dictations (median length 29 s, range 4 to 83 s), language on
  auto, timed warm. RTF is compute time divided by audio time over every clip.

## What it says

1. Full-precision Qwen3-ASR-1.7B beats Whisper on every set: Korean, English, and code-switched
   speech. The 8-bit build ties it on read speech but trails Whisper slightly on the mixed clip.
   large-v3-turbo is only competitive on speed.
2. 8-bit and bf16 score the same on read speech but diverge on code-switched dictation. On
   the mixed clip, most of the gap is number formatting: the 8-bit weights spelled numbers out
   ("7시" became "일곱 시", "3번" became "삼 번", "3.8" became "three point eight"). Otherwise the
   words were nearly identical, including the brand-name misses both share. Running bf16 through
   Sori's own mlx-audio call gives 6.9%, so the gap comes from quantization, not the library. For
   dictation that still matters, because you want "7시" pasted, not "일곱 시".
3. bf16 costs about 0.3 s more per dictation and about 1.5 GB more disk (3.8 GB vs 2.3 GB).
4. 0.6B is not worth it: it saves about 0.5 s against bf16 and has 2.5 times the mixed-clip error.
5. One failure to know about: on a 4 s clip containing only the word "Data", every full-precision Qwen run
   with auto language returned Chinese ("对了。"). 8-bit and Whisper returned "Data".

## Run it

```bash
python3 tests/eval/asr_bench/fetch_sets.py                        # FLEURS ko + LibriSpeech en -> data/
~/.sori-venv/bin/python tests/eval/asr_bench/run_mlxaudio.py q17_bf16 mlx-community/Qwen3-ASR-1.7B-bf16
~/.sori-venv/bin/python tests/eval/asr_bench/run_mlxaudio.py q17_8bit mlx-community/Qwen3-ASR-1.7B-8bit
python3 tests/eval/asr_bench/run_whisper.py w_turbo ~/.sori-models/ggml-large-v3-turbo.bin
python3 tests/eval/asr_bench/score_all.py                          # needs: pip install whisper-normalizer
```

`run_qwen.py` covers the `mlx-qwen3-asr` backend (`pip install mlx-qwen3-asr`). Each runner takes
an optional comma list of sets (`ko,en,gold,raw`). `gold` reads `tests/eval/personal/manifest_read.tsv`
and `raw` reads `tests/eval/personal/raw/manifest.tsv` (file names only, used for speed). Both are
your own recordings and stay out of git.
