#!/usr/bin/env python3
# Sori's own engine call (mlx-audio, as in engine/qwen_server.py). Run with ~/.sori-venv/bin/python.
#   run_mlxaudio.py <tag> <mlx repo> [sets]    e.g. q17_bf16 mlx-community/Qwen3-ASR-1.7B-bf16
import sys, warnings; warnings.filterwarnings("ignore")
from mlx_audio.stt.utils import load_model
from common import run, default_sets
m = load_model(sys.argv[2])
def fn(p, lang):
    r = m.generate(p, **({"language": lang} if lang else {})); t = getattr(r, "text", None)
    return (t if t is not None else str(r)).strip()
run(sys.argv[1], fn, default_sets(sys.argv))
