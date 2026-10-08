#!/bin/bash
# Builds a signed, notarized, stapled SoundRadar-<version>.dmg with the confetti installer window.
# Usage: SIGN_ID="Developer ID Application: …" NOTARY_PROFILE=<keychain profile> tools/make-dmg.sh
# Without NOTARY_PROFILE the DMG is signed but not notarized.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${SIGN_ID:?set SIGN_ID to a Developer ID Application identity}"
VERSION="${VERSION:-1.0.0}"
VOL="Sound Radar"
OUT="SoundRadar-$VERSION.dmg"

WORK="$(mktemp -d /tmp/soundradar-dmg.XXXXXX)"
MNT=""
cleanup() {
    if [[ -n "$MNT" && -d "$MNT" ]]; then hdiutil detach "$MNT" -quiet || hdiutil detach "$MNT" -force -quiet || true; fi
    rm -rf "$WORK"
}
trap cleanup EXIT

# 1. Signed app.
SIGN_ID="$SIGN_ID" VERSION="$VERSION" ./build.sh

# 2. Background (1x + 2x merged into one HiDPI TIFF).
swift tools/make-dmg-background.swift "$WORK" >/dev/null
tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" -out "$WORK/background.tiff" >/dev/null

# 3. Staging folder.
STAGE="$WORK/stage"
mkdir -p "$STAGE/.background"
cp -R SoundRadar.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "$WORK/background.tiff" "$STAGE/.background/background.tiff"

# 4. Writable image, laid out by Finder.
hdiutil create -quiet -srcfolder "$STAGE" -volname "$VOL" -fs HFS+ -format UDRW -size 80m "$WORK/rw.dmg"
MNT="$(hdiutil attach -readwrite -noverify -noautoopen "$WORK/rw.dmg" | awk -F'\t' '/\/Volumes\//{print $NF}' | tail -1)"
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$(basename "$MNT")"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 860, 568}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 128
        set text size of opts to 13
        set background picture of opts to file ".background:background.tiff"
        set position of item "SoundRadar.app" of container window to {170, 220}
        set position of item "Applications" of container window to {490, 220}
        -- Keep hidden items out of sight even when Finder shows hidden files.
        repeat with hiddenName in {".background", ".fseventsd", ".Trashes"}
            try
                set position of item hiddenName of container window to {900, 900}
            end try
        end repeat
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT
chflags hidden "$MNT/.background" || true
sync
hdiutil detach "$MNT" -quiet
MNT=""

# 5. Compressed, signed image.
rm -f "$OUT"
hdiutil convert -quiet "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$OUT"
codesign --force --timestamp --sign "$SIGN_ID" "$OUT"
codesign --verify --verbose=2 "$OUT"

# 6. Notarize and staple.
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$OUT" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$OUT"
    xcrun stapler validate "$OUT"
    spctl -a -vv -t open --context context:primary-signature "$OUT"
fi
shasum -a 256 "$OUT"
echo "Built $(pwd)/$OUT"
