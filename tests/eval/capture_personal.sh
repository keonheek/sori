#!/bin/zsh
# Builds the personal eval manifest: Sori copies each recording into ./raw (keepRecordingsDir in
# ~/.sori.conf); this tails the log, numbers the clip, and records the raw transcript as the
# provisional reference (correct it by hand in manifest.tsv before trusting CER numbers).
D=$(dirname "$0")/personal; LOG=~/Library/Logs/Sori/sori.log; mkdir -p "$D/raw"
tail -n 0 -F $LOG | while read -r line; do
  case "$line" in
    *" kept "*) src="${line#* kept }";;
    *'raw="'*) [[ -z "$src" ]] && continue
      raw=$(printf '%s' "$line" | sed -E 's/.*raw="(.*)" -> final.*/\1/')
      n=$(printf "%02d" $(( $(ls $D/*.wav 2>/dev/null | wc -l) + 1 )))
      mv "$src" "$D/$n.wav" && printf '%s.wav\t%s\n' "$n" "$raw" >> "$D/manifest.tsv" && echo "captured $n.wav: $raw"
      src="";;
  esac
done
