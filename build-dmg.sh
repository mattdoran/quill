#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
config=release
app="$root/.build/$config/Quill.app"

if [ ! -d "$app" ]; then
    echo "bundle first: ./bundle.sh" >&2
    exit 1
fi

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$app/Contents/Info.plist")
output="$root/.build/$config/Quill-$version.dmg"
working=$(mktemp -d)
stage="$working/stage"
rw="$working/Quill-rw.dmg"
set_icon="$working/set-icon"
background_1x="$working/dmg-background.png"
background_2x="$working/dmg-background@2x.png"
background="$working/dmg-background.tiff"
mount=""

cleanup() {
    if [ -n "$mount" ] && mount | grep -Fq "on $mount "; then
        hdiutil detach "$mount" -quiet || true
    fi
    rm -rf "$working"
}
trap cleanup EXIT INT TERM

mkdir -p "$stage/.background"
if ! command -v rsvg-convert >/dev/null 2>&1; then
    echo "rsvg-convert is required to build the DMG" >&2
    exit 1
fi
rsvg-convert -w 660 -h 400 "$root/packaging/dmg-background.svg" -o "$background_1x"
rsvg-convert -w 1320 -h 800 "$root/packaging/dmg-background.svg" -o "$background_2x"
tiffutil -cathidpicheck "$background_1x" "$background_2x" -out "$background"
swiftc "$root/packaging/set-icon.swift" -o "$set_icon"
ditto "$app" "$stage/Quill.app"
ln -s /Applications "$stage/Applications"
cp "$background" "$stage/.background/background.tiff"

hdiutil create -quiet -volname Quill -srcfolder "$stage" -fs HFS+ -ov -format UDRW "$rw"
attach_output=$(hdiutil attach "$rw" -readwrite -noverify -noautoopen)
mount=$(printf '%s\n' "$attach_output" | awk '/\/Volumes\/Quill/ { sub(/^.*\/Volumes/, "/Volumes"); print; exit }')
if [ -z "$mount" ]; then
    echo "couldn't find mounted Quill volume" >&2
    exit 1
fi
osascript - "$mount" <<'APPLESCRIPT'
on run argv
    set mountPath to item 1 of argv
    set volumeName to do shell script "/usr/bin/basename " & quoted form of mountPath
    tell application "Finder"
        tell disk volumeName
            open
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set pathbar visible of container window to false
            set bounds of container window to {180, 180, 840, 580}
            set viewOptions to icon view options of container window
            set arrangement of viewOptions to not arranged
            set icon size of viewOptions to 96
            set text size of viewOptions to 13
            set background picture of viewOptions to file ".background:background.tiff"
            set position of item "Quill.app" of container window to {170, 220}
            set position of item "Applications" of container window to {490, 220}
            close
            open
            update without registering applications
            delay 1
        end tell
    end tell
end run
APPLESCRIPT

sync
hdiutil detach "$mount" -quiet
mount=""
hdiutil convert "$rw" -quiet -format UDZO -imagekey zlib-level=9 -ov -o "$output"
"$set_icon" "$root/Sources/quill/AppIcon.icns" "$output"
echo "$output"
