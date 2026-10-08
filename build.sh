#!/bin/bash
# Builds SoundRadar.app next to this script. Usage: ./build.sh [--open]
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/SoundRadar"
APP="SoundRadar.app"

mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/SoundRadar"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Sound Radar</string>
    <key>CFBundleIdentifier</key><string>dev.local.soundradar</string>
    <key>CFBundleExecutable</key><string>SoundRadar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>14.2</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $(pwd)/$APP"

if [[ "${1:-}" == "--open" ]]; then open "$APP"; fi
