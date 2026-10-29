#!/bin/bash
# Build Minamp.app.
#   ./build.sh            build for this Mac and install to ~/Applications
#   ./build.sh --open     same, then launch it
#   ./build.sh --release  universal (Apple Silicon + Intel) build zipped to build/Minamp.zip
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Minamp.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [ "${1:-}" = "--release" ]; then
    swift build -c release --triple arm64-apple-macosx14.0
    swift build -c release --triple x86_64-apple-macosx14.0
    lipo -create -output "$APP/Contents/MacOS/Minamp" \
        .build/arm64-apple-macosx/release/Minamp .build/x86_64-apple-macosx/release/Minamp
else
    swift build -c release
    cp .build/release/Minamp "$APP/Contents/MacOS/Minamp"
fi
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"

if [ "${1:-}" = "--release" ]; then
    rm -f build/Minamp.zip
    ditto -c -k --keepParent "$APP" build/Minamp.zip
    echo "Built build/Minamp.zip"
    exit 0
fi

pkill -x Minamp 2>/dev/null || true
mkdir -p ~/Applications
rm -rf ~/Applications/Minamp.app
cp -R "$APP" ~/Applications/
echo "Installed ~/Applications/Minamp.app"
[ "${1:-}" = "--open" ] && open ~/Applications/Minamp.app
exit 0
