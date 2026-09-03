#!/bin/bash
# Synthesizes a small English / Korean / code-switched smoke set with macOS `say`.
# This is a PLUMBING check (engine up, scoring works), not an accuracy benchmark:
# TTS audio is far cleaner than real dictation. Record your own clips into
# tests/eval/personal/ for numbers that mean anything.
set -euo pipefail
OUT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/smoke"
mkdir -p "$OUT"
KO_VOICE="${SORI_SMOKE_KO_VOICE:-Yuna}"
say -v "$KO_VOICE" "" 2>/dev/null || KO_VOICE="Flo"
: > "$OUT/manifest.tsv"
n=0
clip() {   # clip <voice> <text>
    n=$((n+1)); local f="$OUT/$(printf '%02d' $n).wav"
    say -v "$1" -o "$OUT/tmp.aiff" "$2"
    afconvert -f WAVE -d LEI16@16000 -c 1 "$OUT/tmp.aiff" "$f"
    printf '%s\t%s\n' "$(basename "$f")" "$2" >> "$OUT/manifest.tsv"
}
clip Samantha "We meet at SKKU on Friday to review the LangGraph agent."
clip Samantha "Push the fix to GitHub once the eval harness passes."
clip Samantha "The vector database uses cosine similarity over OpenAI embeddings."
clip "$KO_VOICE" "회의는 금요일 오후 두 시에 시작합니다."
clip "$KO_VOICE" "지원서 마감은 목요일 오후 다섯 시입니다."
clip "$KO_VOICE" "이번 주에 Claude Code로 MCP 서버를 만들었습니다."
clip "$KO_VOICE" "RAG 파이프라인에 Pinecone 대신 로컬 벡터 디비를 썼어요."
rm -f "$OUT/tmp.aiff"
echo "wrote $n clips + manifest to $OUT"
