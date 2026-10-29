#!/bin/bash
# Build Minamp.app and install it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/Minamp.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Minamp "$APP/Contents/MacOS/Minamp"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"

pkill -x Minamp 2>/dev/null || true
mkdir -p ~/Applications
rm -rf ~/Applications/Minamp.app
cp -R "$APP" ~/Applications/
echo "Installed ~/Applications/Minamp.app"
[ "${1:-}" = "--open" ] && open ~/Applications/Minamp.app
exit 0
