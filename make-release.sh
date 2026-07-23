#!/bin/bash
# Builds the universal (arm64 + x86_64), macOS 11+ release zip that Releases ships.
# install.sh builds single-arch for the local machine; THIS is the distribution build.
set -euo pipefail
swiftc -O -target arm64-apple-macos11.0 main.swift -o /tmp/sori-arm64
swiftc -O -target x86_64-apple-macos11.0 main.swift -o /tmp/sori-x86_64
lipo -create /tmp/sori-arm64 /tmp/sori-x86_64 -output build/Sori.app/Contents/MacOS/Sori
rm -f /tmp/sori-arm64 /tmp/sori-x86_64
codesign --force --deep --sign - build/Sori.app
rm -f build/Sori-1.0.0.zip
ditto -c -k --sequesterRsrc --keepParent build/Sori.app build/Sori-1.0.0.zip
echo "release zip: build/Sori-1.0.0.zip"
lipo -info build/Sori.app/Contents/MacOS/Sori
