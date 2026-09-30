#!/usr/bin/env python3
# moona3k/mlx-qwen3-asr backend (pip install mlx-qwen3-asr), fp16 from the official Qwen weights.
#   run_qwen.py <tag> <repo> [sets]    e.g. q17_fp16 Qwen/Qwen3-ASR-1.7B
import sys, mlx.core as mx, mlx_qwen3_asr as q
from common import run, default_sets
model, _ = q.load_model(sys.argv[2], dtype=mx.float16)
run(sys.argv[1], lambda p, lang: q.transcribe(p, model=model, language=lang).text.strip(), default_sets(sys.argv))
