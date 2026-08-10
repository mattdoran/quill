#!/bin/sh
# Wrap the built binary in Quill.app and sign it. UserNotifications cannot
# resolve an identity for a bare Mach-O, so anything richer than an anonymous
# banner needs the bundle.
#
#   ./bundle.sh                      release, signed with whatever is available
#   ./bundle.sh debug                debug build
#   ./bundle.sh --notarize           also submit to Apple and staple the ticket
#
# Signing identity is read from the keychain, and notarization settings from
# signing.conf if it exists. Neither is committed: see signing.conf.example.
set -eu

config=release
notarize=no
for arg in "$@"; do
    case "$arg" in
        --notarize) notarize=yes ;;
        debug|release) config="$arg" ;;
        *) echo "unknown argument: $arg" >&2; exit 64 ;;
    esac
done

root="$(cd "$(dirname "$0")" && pwd)"
binary="$root/.build/$config/quill"
app="$root/.build/$config/Quill.app"

if [ ! -x "$binary" ]; then
    echo "build first:  swift build -c $config" >&2
    exit 1
fi

SIGN_IDENTITY=""
NOTARY_PROFILE=""
# shellcheck source=/dev/null
[ -f "$root/signing.conf" ] && . "$root/signing.conf"

# Fall back to whatever Developer ID is in the keychain, so a checkout needs no
# configuration to produce a distributable build on a machine that has one.
if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/Developer ID Application/ { print $2; exit }')
fi

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/quill"
cp "$root/Sources/quill/Info.plist" "$app/Contents/Info.plist"
cp "$root/Sources/quill/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"

build_hash=$(git -C "$root" rev-parse --short=8 HEAD 2>/dev/null || echo dev)
build_commit=$build_hash
if [ -n "$(git -C "$root" status --porcelain -- Sources Package.swift Package.resolved bundle.sh 2>/dev/null)" ]; then
    build_commit="$build_commit-dirty"
fi
build_date=$(LC_ALL=C date '+%e %b %Y' | sed 's/^ //')
plist="$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :QuillBuildCommit string $build_commit" "$plist"
/usr/libexec/PlistBuddy -c "Add :QuillBuildDate string $build_date" "$plist"

# Apache 2.0 requires its licence to travel with distributed binaries, and MIT
# requires upstream's notice to travel too. Collected from the checkouts, since
# that is the version actually linked.
licenses="$app/Contents/Resources/Licenses"
mkdir -p "$licenses"
cp "$root/LICENSE" "$licenses/quill.txt"
for dep in FluidAudio swift-argument-parser; do
    for name in LICENSE LICENSE.txt; do
        if [ -f "$root/.build/checkouts/$dep/$name" ]; then
            cp "$root/.build/checkouts/$dep/$name" "$licenses/$dep.txt"
            break
        fi
    done
done

if [ -n "$SIGN_IDENTITY" ]; then
    # Hardened runtime and a secure timestamp are both required by notarization,
    # and harmless without it.
    codesign --force --timestamp --options runtime \
        --entitlements "$root/Sources/quill/quill.entitlements" \
        --sign "$SIGN_IDENTITY" "$app"
else
    # Ad-hoc runs on this Mac only: Gatekeeper rejects it anywhere else, and the
    # code hash changes every build, so TCC re-prompts each time.
    echo "note: no Developer ID found, signing ad-hoc (this Mac only)" >&2
    codesign --force --sign - "$app"
fi

if [ "$notarize" = yes ]; then
    if [ -z "$NOTARY_PROFILE" ]; then
        echo "--notarize needs NOTARY_PROFILE in signing.conf" >&2
        exit 1
    fi
    zip="$root/.build/$config/Quill.zip"
    ditto -c -k --keepParent "$app" "$zip"
    xcrun notarytool submit "$zip" --keychain-profile "$NOTARY_PROFILE" --wait
    # Staples the ticket into the bundle so it validates without a network trip.
    xcrun stapler staple "$app"
    rm -f "$zip"
fi

echo "$app"
