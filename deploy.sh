#!/bin/bash
# Local deploy that never cuts a dictation: build, wait until Sori is idle (last recording event is a
# stop/cancel, the paste landed, and nothing happened for IDLE_S seconds), SIGTERM, swap, sign, kickstart.
# Swapping the binary under a running Sori SIGKILLs it (lesson 09-20), hence the wait.
#   ./deploy.sh            build + wait + deploy
#   PRE_SWAP="cmd" ./deploy.sh   run cmd while Sori is stopped (store maintenance)
set -euo pipefail
cd "$(dirname "$0")"
APP=/Applications/Sori.app
LOG="$HOME/Library/Logs/Sori/sori.log"
IDLE_S=${IDLE_S:-8}
IDENTITY="Gunny Local Codesign"

swiftc -O -target arm64-apple-macos13.0 $(find Sources -name '*.swift') -o build/Sori-next
./build/Sori-next --learn-test >/dev/null && ./build/Sori-next --script-test >/dev/null || { echo "self-tests FAILED — not deploying"; exit 1; }

idle() {
    local last; last=$(grep -E ">>> (startRecording|stopAndTranscribe|cancelRecording)" "$LOG" | tail -1)
    [[ "$last" == *startRecording* ]] && return 1
    local mtime now; mtime=$(stat -f %m "$LOG"); now=$(date +%s)
    (( now - mtime >= IDLE_S ))
}
for _ in $(seq 1 720); do idle && break; /bin/sleep 5; done
idle || { echo "never idle — not deploying"; exit 1; }

echo "idle at $(date '+%H:%M:%S') — deploying"
cp "$APP/Contents/MacOS/Sori" build/Sori.prev-deployed
launchctl kill SIGTERM "gui/$UID/dev.sori.app" || true
for _ in $(seq 1 20); do pgrep -f "$APP/Contents/MacOS/Sori" >/dev/null || break; /bin/sleep 0.25; done
if [ -n "${PRE_SWAP:-}" ]; then bash -c "$PRE_SWAP"; fi
cp build/Sori-next "$APP/Contents/MacOS/Sori"
codesign --force --sign "$IDENTITY" "$APP"
launchctl kickstart -k "gui/$UID/dev.sori.app"
for _ in $(seq 1 30); do pgrep -f "$APP/Contents/MacOS/Sori" >/dev/null && break; /bin/sleep 0.5; done
pgrep -f "$APP/Contents/MacOS/Sori" >/dev/null && echo "running: $("$APP/Contents/MacOS/Sori" --version)" || { echo "NOT RUNNING after deploy"; exit 1; }
