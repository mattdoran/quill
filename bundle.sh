#!/bin/sh
# Wrap the built binary in quill.app. UserNotifications cannot resolve an
# identity for a bare Mach-O, so anything richer than a plain banner needs this.
set -eu

config="${1:-release}"
root="$(cd "$(dirname "$0")" && pwd)"
binary="$root/.build/$config/quill"
app="$root/.build/$config/quill.app"

if [ ! -x "$binary" ]; then
    echo "build first:  swift build -c $config" >&2
    exit 1
fi

rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$binary" "$app/Contents/MacOS/quill"
cp "$root/Sources/quill/Info.plist" "$app/Contents/Info.plist"

# Ad-hoc sign so the Info.plist is bound to the code. TCC and the notification
# centre both read quill's identity from there.
codesign --force --sign - "$app" >/dev/null

echo "$app"
