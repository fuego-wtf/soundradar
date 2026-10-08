#!/bin/bash
# Builds SoundRadar.app next to this script. Usage: ./build.sh [--open]
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/SoundRadar"
APP="SoundRadar.app"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SoundRadar"
# App icon: render the iconset with tools/make-icon.swift, then compile to .icns.
ICONTMP="$(mktemp -d "${TMPDIR:-/tmp}/soundradar-icon.XXXXXX")"
trap 'rm -rf "$ICONTMP"' EXIT
swift tools/make-icon.swift "$ICONTMP/AppIcon.iconset"
rm -f "$ICONTMP/AppIcon.iconset/AppIcon-1024.png"
iconutil -c icns "$ICONTMP/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Sound Radar</string>
    <key>CFBundleIdentifier</key><string>dev.local.soundradar</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleExecutable</key><string>SoundRadar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAudioCaptureUsageDescription</key><string>Sound Radar measures how loud each app is and sets per-app volume. Audio never leaves your Mac and is never recorded.</string>
    <key>NSAppleEventsUsageDescription</key><string>Sound Radar asks your browser which tab is open so it can show where a sound comes from and switch to it.</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $(pwd)/$APP"

if [[ "${1:-}" == "--open" ]]; then open "$APP"; fi
