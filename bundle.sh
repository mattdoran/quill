#!/bin/sh
# Wrap the built binary in Quill.app and sign it. UserNotifications cannot
# resolve an identity for a bare Mach-O, so anything richer than an anonymous
# banner needs the bundle.
#
#   ./bundle.sh                      release, signed with whatever is available
#   ./bundle.sh debug                debug build
#   ./bundle.sh --notarize           also submit to Apple and staple the ticket
#   ./bundle.sh --version 0.4.0 --build 123 [--channel beta]
#
# Signing identity is read from the keychain, and notarization settings from
# signing.conf if it exists. Neither is committed: see signing.conf.example.
set -eu

config=release
notarize=no
version=""
build=""
channel=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --notarize) notarize=yes ;;
        --version)
            [ "$#" -ge 2 ] || { echo "--version needs a value" >&2; exit 64; }
            version="$2"
            shift
            ;;
        --build)
            [ "$#" -ge 2 ] || { echo "--build needs a value" >&2; exit 64; }
            build="$2"
            shift
            ;;
        --channel)
            [ "$#" -ge 2 ] || { echo "--channel needs a value" >&2; exit 64; }
            channel="$2"
            shift
            ;;
        debug|release) config="$1" ;;
        *) echo "unknown argument: $1" >&2; exit 64 ;;
    esac
    shift
done

case "$build" in
    ""|*[!0-9]*) [ -z "$build" ] || { echo "--build must be an integer" >&2; exit 64; } ;;
esac
case "$channel" in
    ""|beta) ;;
    *) echo "--channel must be beta" >&2; exit 64 ;;
esac

root="$(cd "$(dirname "$0")" && pwd)"
binary="$root/.build/$config/quill"
app="$root/.build/$config/Quill.app"
sparkle="$root/.build/$config/Sparkle.framework"

if [ ! -x "$binary" ]; then
    echo "build first:  ./build.sh $config" >&2
    exit 1
fi
if [ ! -d "$sparkle" ]; then
    echo "Sparkle.framework is missing: build first" >&2
    exit 1
fi

SIGN_IDENTITY="${SIGN_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
# shellcheck source=/dev/null
[ -f "$root/signing.conf" ] && . "$root/signing.conf"

# Fall back to whatever Developer ID is in the keychain, so a checkout needs no
# configuration to produce a distributable build on a machine that has one.
if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/Developer ID Application/ { print $2; exit }')
fi

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp "$binary" "$app/Contents/MacOS/quill"
cp "$root/Sources/quill/Info.plist" "$app/Contents/Info.plist"
cp "$root/Sources/quill/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
/usr/bin/ditto "$sparkle" "$app/Contents/Frameworks/Sparkle.framework"

build_hash=$(git -C "$root" rev-parse --short=8 HEAD 2>/dev/null || echo dev)
build_commit=$build_hash
if [ -n "$(git -C "$root" status --porcelain -- Sources Package.swift Package.resolved bundle.sh 2>/dev/null)" ]; then
    build_commit="$build_commit-dirty"
fi
build_date=$(LC_ALL=C date '+%e %b %Y' | sed 's/^ //')
plist="$app/Contents/Info.plist"
[ -n "$version" ] && /usr/libexec/PlistBuddy \
    -c "Set :CFBundleShortVersionString $version" "$plist"
[ -n "$build" ] && /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build" "$plist"
if [ "$channel" = beta ]; then
    /usr/libexec/PlistBuddy -c "Add :QuillUpdateChannel string beta" "$plist"
else
    /usr/libexec/PlistBuddy -c "Delete :QuillUpdateChannel" "$plist" 2>/dev/null || true
fi
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
cp "$root/VendorLicenses/WebRTC/pywebrtc-audio-LICENSE" \
    "$licenses/pywebrtc-audio.txt"
cp "$root/VendorLicenses/WebRTC/LICENSE" "$licenses/WebRTC.txt"
cp "$root/VendorLicenses/WebRTC/PATENTS" "$licenses/WebRTC-PATENTS.txt"
cp "$root/VendorLicenses/WebRTC/AUTHORS" "$licenses/WebRTC-AUTHORS.txt"

if [ -n "$SIGN_IDENTITY" ]; then
    framework="$app/Contents/Frameworks/Sparkle.framework"
    for nested in \
        "$framework/Versions/B/XPCServices/Installer.xpc" \
        "$framework/Versions/B/Autoupdate" \
        "$framework/Versions/B/Updater.app"
    do
        if [ -e "$nested" ]; then
            codesign --force --timestamp --options runtime \
                --sign "$SIGN_IDENTITY" "$nested"
        fi
    done
    downloader="$framework/Versions/B/XPCServices/Downloader.xpc"
    if [ -e "$downloader" ]; then
        codesign --force --timestamp --options runtime \
            --preserve-metadata=entitlements --sign "$SIGN_IDENTITY" "$downloader"
    fi
    codesign --force --timestamp --options runtime \
        --sign "$SIGN_IDENTITY" "$framework"
    # Hardened runtime and a secure timestamp are both required by notarization,
    # and harmless without it.
    codesign --force --timestamp --options runtime \
        --entitlements "$root/Sources/quill/quill.entitlements" \
        --sign "$SIGN_IDENTITY" "$app"
else
    # Ad-hoc runs on this Mac only: Gatekeeper rejects it anywhere else, and the
    # code hash changes every build, so TCC re-prompts each time.
    echo "note: no Developer ID found, signing ad-hoc (this Mac only)" >&2
    codesign --force --deep --sign - "$app"
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

codesign --verify --deep --strict "$app"

echo "$app"
