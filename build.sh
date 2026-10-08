#!/bin/bash
# Builds SoundRadar.app next to this script. Usage: ./build.sh [--open]
# Env: VERSION (default 1.0.0); SIGN_ID="Developer ID Application: ..." for a hardened-runtime release signature (default: ad-hoc).
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${VERSION:-1.0.0}"

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

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Sound Radar</string>
    <key>CFBundleIdentifier</key><string>wtf.fuego.soundradar</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleExecutable</key><string>SoundRadar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHumanReadableCopyright</key><string>© 2026 Fuego Labs</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAudioCaptureUsageDescription</key><string>Sound Radar measures how loud each app is and sets per-app volume. Audio never leaves your Mac and is never recorded.</string>
    <key>NSAppleEventsUsageDescription</key><string>Sound Radar asks your browser which tab is open so it can show where a sound comes from and switch to it.</string>
</dict>
</plist>
PLIST
if [[ -n "${SIGN_ID:-}" ]]; then
    codesign --force --options runtime --timestamp --entitlements SoundRadar.entitlements --sign "$SIGN_ID" "$APP"
    codesign --verify --deep --strict --verbose=2 "$APP"
    # Before notarization this reports "Unnotarized Developer ID", which is expected.
    spctl -a -vv -t exec "$APP" || true
else
    codesign --force --sign - "$APP"
fi
echo "Built $(pwd)/$APP"

if [[ "${1:-}" == "--open" ]]; then open "$APP"; fi
