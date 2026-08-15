#!/bin/bash
# Packages publish/MacTime.app into a release disk image. Adapted from
# MonitorDim's tools/make-dmg.sh — same mechanism, see that file for the full
# rationale (App Translocation, .DS_Store via Finder, retina tiff, signing).
#
#   tools/bundle-macos.sh && swift tools/make-icons.swift && tools/make-dmg.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
app="$root/publish/MacTime.app"
assets="$root/Resources"

[ -d "$app" ] || { echo "error: $app not found — run tools/bundle-macos.sh first" >&2; exit 1; }
[ -f "$assets/DmgBackground.png" ] || { echo "error: run swift tools/make-icons.swift first" >&2; exit 1; }

version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")
vol="MacTime"
dmg="$root/publish/MacTime-$version-macos-arm64.dmg"

# Finder window layout — keep in step with drawDmgBackground in make-icons.swift.
win_w=600; win_h=400; titlebar=28
win_x=240; win_y=180
icon_y=190; app_x=160; applications_x=440

staging=$(mktemp -d)
work=$(mktemp -d)
trap 'rm -rf "$staging" "$work"' EXIT

ditto "$app" "$staging/MacTime.app"
ln -s /Applications "$staging/Applications"

mkdir -p "$staging/.background"
tiffutil -cathidpicheck "$assets/DmgBackground.png" "$assets/DmgBackground@2x.png" \
    -out "$staging/.background/background.tiff" >/dev/null

[ -f "$assets/MacTime.icns" ] && cp "$assets/MacTime.icns" "$staging/.VolumeIcon.icns"

size_kb=$(( $(du -sk "$staging" | cut -f1) + 40000 ))
rw="$work/rw.dmg"

hdiutil detach "/Volumes/$vol" -quiet 2>/dev/null || true
hdiutil create -volname "$vol" -srcfolder "$staging" -ov -format UDRW -fs HFS+ \
    -size "${size_kb}k" "$rw" >/dev/null

device=$(hdiutil attach "$rw" -noautoopen -owners on | grep -E '^/dev/' | head -1 | awk '{print $1}')
mount="/Volumes/$vol"
[ -d "$mount" ] || { echo "error: $vol did not mount" >&2; exit 1; }

[ -f "$mount/.VolumeIcon.icns" ] && SetFile -a C "$mount"

osascript <<APPLESCRIPT >/dev/null
tell application "Finder"
    tell disk "$vol"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {$win_x, $win_y, $((win_x + win_w)), $((win_y + win_h + titlebar))}

        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 128
        set text size of opts to 12
        set label position of opts to bottom
        set background picture of opts to file ".background:background.tiff"

        set position of item "MacTime.app" of container window to {$app_x, $icon_y}
        set position of item "Applications" of container window to {$applications_x, $icon_y}

        close
        open
        delay 1
        close
    end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$device" -quiet

rm -f "$dmg"
hdiutil convert "$rw" -format UDZO -imagekey zlib-level=9 -o "$dmg" >/dev/null

identity="${SIGN_IDENTITY:--}"
if [ "$identity" != "-" ]; then
    codesign --force -s "$identity" --timestamp "$dmg"
    echo "signed with: $identity"
fi

echo
echo "Built: $dmg  ($(du -h "$dmg" | cut -f1))"
echo "Check: open '$dmg'"
