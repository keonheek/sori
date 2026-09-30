import json, os, time
HERE = os.path.dirname(os.path.abspath(__file__)); PERSONAL = os.path.join(HERE, "..", "personal")
# set -> (manifest, forced language). gold/raw are your own clips and stay out of git (tests/eval/personal/).
SETS = {"ko": (os.path.join(HERE, "data/fleurs_ko/manifest.tsv"), "Korean"),
        "en": (os.path.join(HERE, "data/ls_en/manifest.tsv"), "English"),
        "gold": (os.path.join(PERSONAL, "manifest_read.tsv"), None),          # hand-corrected references
        "raw": (os.path.join(PERSONAL, "raw/manifest.tsv"), None)}            # no references: speed only
def clips(name):
    man, lang = SETS[name]
    if not os.path.exists(man): return
    for l in open(man, encoding="utf-8"):
        if l.strip():
            f, ref = (l.rstrip("\n").split("\t") + [""])[:2]
            yield os.path.join(os.path.dirname(man), f), ref, lang
def default_sets(argv, i=3): return (argv[i] if len(argv) > i else "ko,en,gold,raw").split(",")
def run(tag, fn, sets):
    warm = next((p for s in sets for p, _, _ in clips(s)), None)
    if warm: fn(warm, None)                         # warm-up: load weights + compile kernels before timing
    os.makedirs(os.path.join(HERE, "out"), exist_ok=True)
    with open(os.path.join(HERE, "out", f"{tag}.jsonl"), "w", encoding="utf-8") as o:
        for s in sets:
            for p, ref, lang in clips(s):
                t = time.time(); hyp = fn(p, lang); dt = time.time() - t
                o.write(json.dumps({"set": s, "file": os.path.basename(p), "path": p, "ref": ref, "hyp": hyp, "secs": dt}, ensure_ascii=False) + "\n"); o.flush()
                print(tag, s, os.path.basename(p), f"{dt:.2f}s", hyp[:60], flush=True)
