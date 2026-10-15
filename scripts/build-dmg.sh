#!/usr/bin/env bash
# Build a designed, compressed DMG: dark ASCII background with a white arrow (dmg/background*.png), app icon on the
# left, /Applications link on the right, fixed 660x400 icon-view window, app icon as the volume icon.
#
# Usage: scripts/build-dmg.sh "path/to/Local Flow.app" "out/Local-Flow-1.2.3.dmg"
# Runs headless (Finder via AppleScript) — works on the macos GitHub runners. Sign/notarize the result separately.
set -euo pipefail

APP="$1"
OUT="$2"
VOLNAME="${VOLNAME:-$(basename "$APP" .app)}"
# Window geometry (points). ICON_Y must match ARROW_Y in scripts/make-dmg-background.py.
WIN_X=200 WIN_Y=120 WIDTH=660 HEIGHT=400 ICON=128 ICON_Y=180 APP_X=165 APPS_X=495

REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
STAGE="$WORK/stage"
RW="$WORK/rw.dmg"
MOUNT="/Volumes/$VOLNAME"
ATTACHED=""
mounted() { mount | grep -q " on $MOUNT "; }
cleanup() {
  if [[ -n "$ATTACHED" ]] && mounted; then hdiutil detach "$MOUNT" -force >/dev/null || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT
# Finder addresses the disk by name, so refuse to run (rather than eject) if a same-named volume is mounted.
if mounted; then echo "A volume is already mounted at $MOUNT; eject it first." >&2; exit 1; fi

mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
# One TIFF with 1x + 2x representations so Finder picks the retina background on HiDPI displays.
tiffutil -cathidpicheck "$REPO/dmg/background.png" "$REPO/dmg/background@2x.png" \
  -out "$STAGE/.background/background.tiff"

# Read-write image with headroom for the .DS_Store, laid out in Finder, then compressed.
SIZE_MB=$(( $(du -sm "$STAGE" | cut -f1) + 20 ))
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -fs HFS+ -fsargs "-c c=64,a=16,e=16" \
  -format UDRW -size "${SIZE_MB}m" -ov "$RW" >/dev/null
hdiutil attach -readwrite -noverify -noautoopen "$RW" >/dev/null
ATTACHED=1

osascript - "$VOLNAME" "$(basename "$APP")" "$WIN_X" "$WIN_Y" "$WIDTH" "$HEIGHT" "$ICON" "$APP_X" "$APPS_X" "$ICON_Y" <<'APPLESCRIPT'
on run argv
  set volName to item 1 of argv
  set appName to item 2 of argv
  set winX to item 3 of argv as integer
  set winY to item 4 of argv as integer
  set winW to item 5 of argv as integer
  set winH to item 6 of argv as integer
  set iconSize to item 7 of argv as integer
  set appX to item 8 of argv as integer
  set appsX to item 9 of argv as integer
  set iconY to item 10 of argv as integer
  tell application "Finder"
    tell disk volName
      open
      set current view of container window to icon view
      set toolbar visible of container window to false
      set statusbar visible of container window to false
      set pathbar visible of container window to false
      set the bounds of container window to {winX, winY, winX + winW, winY + winH}
      set opts to the icon view options of container window
      set arrangement of opts to not arranged
      set icon size of opts to iconSize
      set text size of opts to 12
      set label position of opts to bottom
      set shows item info of opts to false
      set shows icon preview of opts to true
      set background picture of opts to file ".background:background.tiff"
      set position of item appName of container window to {appX, iconY}
      set position of item "Applications" of container window to {appsX, iconY}
      close
      open
      update without registering applications
      delay 2
      close
    end tell
  end tell
end run
APPLESCRIPT

# Volume icon goes in *after* Finder has written the layout: Finder's `update` deletes a pre-existing
# .VolumeIcon.icns and clears the custom-icon flag.
cp "$APP/Contents/Resources/AppIcon.icns" "$MOUNT/.VolumeIcon.icns"
xcrun SetFile -c icnC "$MOUNT/.VolumeIcon.icns"
xcrun SetFile -a C "$MOUNT"
sync
for _ in 1 2 3 4 5; do [[ -f "$MOUNT/.DS_Store" ]] && break; sleep 1; done
[[ -f "$MOUNT/.DS_Store" ]] || { echo "Finder did not write .DS_Store" >&2; exit 1; }
hdiutil detach "$MOUNT" >/dev/null
ATTACHED=""

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null
echo "wrote $OUT"
