#!/bin/bash
# Builds the universal (arm64 + x86_64), macOS 11+ release zip that Releases ships.
# install.sh builds single-arch for the local machine; THIS is the distribution build.
set -euo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Same single source of truth install.sh uses: the `let soriVersion` line in main.swift.
VERSION="$(sed -n 's/^let soriVersion = "\(.*\)"/\1/p' "$SRC/main.swift")"
[ -n "$VERSION" ] || { echo "ERROR: could not read soriVersion from main.swift"; exit 1; }
echo "-- Building Sori $VERSION"

swiftc -O -target arm64-apple-macos11.0 main.swift -o /tmp/sori-arm64
swiftc -O -target x86_64-apple-macos11.0 main.swift -o /tmp/sori-x86_64
lipo -create /tmp/sori-arm64 /tmp/sori-x86_64 -output build/Sori.app/Contents/MacOS/Sori
rm -f /tmp/sori-arm64 /tmp/sori-x86_64

# Keep the shipped plist in step with the binary. The app compares its own soriVersion against
# the latest release tag, so a stale version here tells users to install what they already have.
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" \
                        -c "Set :CFBundleShortVersionString $VERSION" \
                        build/Sori.app/Contents/Info.plist

codesign --force --deep --sign - build/Sori.app
rm -f build/Sori-*.zip
ditto -c -k --sequesterRsrc --keepParent build/Sori.app "build/Sori-$VERSION.zip"
echo "release zip: build/Sori-$VERSION.zip"
echo "tag it as:   v$VERSION"
lipo -info build/Sori.app/Contents/MacOS/Sori
