#!/bin/bash
# Sori installer — builds from source, assembles Sori.app, installs the launch agent.
set -euo pipefail

APP="/Applications/Sori.app"
MODELS="$HOME/.sori-models"
LABEL="dev.sori.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

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
swiftc -O main.swift -o Sori

# 4. Assemble the app bundle
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
    <key>CFBundleVersion</key><string>1.0</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>Used for speech-to-text dictation.</string>
    <key>NSAccessibilityUsageDescription</key><string>Needed to detect the Right Command key globally and paste text.</string>
</dict></plist>
PLIST_EOF

# 5. Codesign. Ad-hoc works, but macOS revokes permissions on every rebuild with
# ad-hoc signatures. For a stable setup, create a self-signed identity named
# "Sori Codesign" in Keychain Access (see README) — the installer uses it if present.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Sori Codesign"; then
    codesign --force --sign "Sori Codesign" "$APP"
    echo "-- Signed with stable 'Sori Codesign' identity (permissions survive rebuilds)"
else
    codesign --force --sign - "$APP"
    echo "-- Ad-hoc signed. NOTE: you must re-grant permissions after every rebuild."
    echo "   See README 'Stable code signing' to fix this permanently."
fi

# 6. Launch agent (start at login)
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

echo ""
echo "== Done. Sori is running (menu-bar mic icon). =="
echo ""
echo "First-time setup — grant these in System Settings > Privacy & Security:"
echo "  1. Microphone            (prompted automatically on first recording)"
echo "  2. Accessibility         (prompted on launch)"
echo "  3. Input Monitoring      (needed for the Right Command hotkey)"
echo ""
echo "Optional — AI cleanup (filler-word removal, punctuation) via Groq's free tier:"
echo "  Put a Groq API key (console.groq.com, free) in ~/.sori-groq:"
echo "  and enable 'AI Cleanup (Groq)' in the menu-bar menu."
