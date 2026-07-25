#!/bin/bash
# Sori installer — builds from source, assembles Sori.app, installs the launch agent.
set -euo pipefail

APP="/Applications/Sori.app"
MODELS="$HOME/.sori-models"
LABEL="dev.sori.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Single source of truth for the version: the `let soriVersion` line in main.swift.
VERSION="$(sed -n 's/^let soriVersion = "\(.*\)"/\1/p' "$SRC/main.swift")"
[ -n "$VERSION" ] || { echo "ERROR: could not read soriVersion from main.swift"; exit 1; }

echo "== Sori installer =="

# 1. Toolchain checks
command -v swiftc >/dev/null || { echo "ERROR: swiftc not found. Install Xcode Command Line Tools: xcode-select --install"; exit 1; }
command -v brew >/dev/null || { echo "ERROR: Homebrew not found. Install from https://brew.sh"; exit 1; }
if ! command -v whisper-cli >/dev/null; then
    echo "-- Installing whisper-cpp (provides whisper-cli + whisper-server)..."
    brew install whisper-cpp
fi

# 2. Models (base for language detection + live preview, large-v3-turbo for transcription)
mkdir -p "$MODELS"
dl() {
    local f="$1"
    [ -f "$MODELS/$f" ] && { echo "-- $f already present"; return; }
    echo "-- Downloading $f ..."
    # -f: fail on HTTP errors instead of saving the error page as a "model".
    # .tmp + mv: an interrupted download never leaves a truncated file at the
    # final path (which would pass the existence check above forever).
    curl -fL --progress-bar -o "$MODELS/$f.tmp" "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$f"
    mv "$MODELS/$f.tmp" "$MODELS/$f"
}
dl ggml-base.bin
dl ggml-large-v3-turbo.bin

# 3. Build
echo "-- Building..."
swiftc -O -target "$(uname -m)-apple-macos11.0" main.swift -o Sori

# 4. Assemble the app bundle.
# Read the existing install's signing identity BEFORE overwriting it — step 5 falls back
# to this so a rebuild can't silently downgrade a properly signed app to ad-hoc.
# Empty for a first install or an ad-hoc one (no Authority line in that case).
PREV_IDENTITY="$(codesign -dvvv "$APP" 2>&1 | awk -F= '/^Authority=/{print $2; exit}' || true)"
echo "-- Assembling $APP ..."
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
rm -f "$APP/Contents/MacOS/Sori"
cp Sori "$APP/Contents/MacOS/Sori"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleExecutable</key><string>Sori</string>
    <key>CFBundleIdentifier</key><string>$LABEL</string>
    <key>CFBundleName</key><string>Sori</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>Used for speech-to-text dictation.</string>
    <key>NSAccessibilityUsageDescription</key><string>Needed to detect the Right Command key globally and paste text.</string>
</dict></plist>
PLIST_EOF

# 5. Codesign. Ad-hoc works, but macOS revokes permissions on every rebuild with
# ad-hoc signatures. For a stable setup, create a self-signed identity named
# "Sori Codesign" in Keychain Access (see README) — the installer uses it if present.
# Override the name with SORI_CODESIGN_IDENTITY. If neither is found but an earlier
# install was signed with some identity, reuse THAT one: re-signing an installed app
# ad-hoc silently revokes its Microphone / Accessibility / Input Monitoring grants,
# and a rebuild is the worst possible moment to discover that.
sign_with() { codesign --force --sign "$1" "$APP"; }
if [ -n "${SORI_CODESIGN_IDENTITY:-}" ] \
   && security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SORI_CODESIGN_IDENTITY"; then
    sign_with "$SORI_CODESIGN_IDENTITY"
    echo "-- Signed with '$SORI_CODESIGN_IDENTITY' (from SORI_CODESIGN_IDENTITY)"
elif security find-identity -v -p codesigning 2>/dev/null | grep -qF "Sori Codesign"; then
    sign_with "Sori Codesign"
    echo "-- Signed with stable 'Sori Codesign' identity (permissions survive rebuilds)"
elif [ -n "$PREV_IDENTITY" ] \
     && security find-identity -v -p codesigning 2>/dev/null | grep -qF "$PREV_IDENTITY"; then
    sign_with "$PREV_IDENTITY"
    echo "-- Reused the identity the installed app already had: '$PREV_IDENTITY'"
    echo "   (keeps your existing permission grants; set SORI_CODESIGN_IDENTITY to change it)"
else
    codesign --force --sign - "$APP"
    echo "-- Ad-hoc signed. NOTE: you must re-grant permissions after every rebuild."
    echo "   See README 'Stable code signing' to fix this permanently."
fi

# 6. Record where this source lives, so the app's "Check for Updates…" knows it can pull and
# rebuild in place (and therefore keep your permissions) instead of sending you to a download.
printf '%s\n' "$SRC" > "$HOME/.sori-src"

# 7. Launch agent (start at login)
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array><string>$APP/Contents/MacOS/Sori</string></array>
    <key>RunAtLoad</key><true/>
</dict></plist>
PLIST_EOF
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -f "$APP/Contents/MacOS/Sori" 2>/dev/null || true
pkill -f "whisper-server.*--port 8917" 2>/dev/null || true
sleep 1
launchctl bootstrap "gui/$(id -u)" "$PLIST"
# bootstrap REGISTERS the job; RunAtLoad does not reliably start it right after a bootout
# (observed: bootstrap returns 0, `launchctl print` shows runs = 0, and nothing runs until the
# next login). Start it explicitly, then trust only launchd's own view — pgrep would happily
# match an orphaned older process and report a false success.
launchctl kickstart "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
sleep 2
if launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | grep -q "state = running"; then
    echo ""
    echo "== Done. Sori $VERSION is running (menu-bar mic icon). =="
else
    echo ""
    echo "== Installed, but Sori is NOT running. =="
    echo "   Start it with: launchctl kickstart -k gui/$(id -u)/$LABEL"
    echo "   If that fails, check the log: tail \$(getconf DARWIN_USER_TEMP_DIR)sori/sori.log"
    exit 1
fi
echo ""
echo "First-time setup — grant these in System Settings > Privacy & Security:"
echo "  1. Microphone            (prompted automatically on first recording)"
echo "  2. Accessibility         (prompted on launch)"
echo "  3. Input Monitoring      (needed for the Right Command hotkey)"
echo ""
echo "Optional — AI cleanup (filler-word removal, punctuation) via Groq's free tier:"
echo "  Put a Groq API key (console.groq.com, free) in ~/.sori-groq:"
echo "  and enable 'AI Cleanup (Groq)' in the menu-bar menu."
