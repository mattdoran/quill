#!/bin/sh
set -eu

project=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
test_root=$(mktemp -d "${TMPDIR:-/private/tmp}/quill-release-versioning.XXXXXX")
trap 'rm -rf "$test_root"' EXIT HUP INT TERM

QUILL_RELEASE_LIBRARY_ONLY=1
QUILL_RELEASE_ROOT=$project
export QUILL_RELEASE_LIBRARY_ONLY QUILL_RELEASE_ROOT
# shellcheck source=../release.sh
. "$project/release.sh"

origin="$test_root/origin.git"
work="$test_root/work"
fixture="$test_root/appcast.xml"
git init --bare -q "$origin"
git init -q -b master "$work"
git -C "$work" config user.name "Quill Tests"
git -C "$work" config user.email "quill-tests@example.invalid"
git -C "$work" remote add origin "$origin"

for revision in 1 2 3; do
    printf '%s\n' "$revision" >"$work/revision"
    git -C "$work" add revision
    git -C "$work" commit -q -m "revision $revision"
done
git -C "$work" push -q -u origin master

write_appcast() {
    maintenance=${1:-}
    {
        printf '%s\n' '<?xml version="1.0" encoding="utf-8"?>'
        printf '%s\n' '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>'
        printf '%s\n' '<item><sparkle:version>2</sparkle:version><sparkle:shortVersionString>0.5.0-beta.1</sparkle:shortVersionString><sparkle:channel>beta</sparkle:channel></item>'
        printf '%s\n' '<item><sparkle:version>80</sparkle:version><sparkle:shortVersionString>0.4.0</sparkle:shortVersionString></item>'
        case "$maintenance" in
            beta)
                printf '%s\n' '<item><sparkle:version>80.1</sparkle:version><sparkle:shortVersionString>0.4.1-beta.1</sparkle:shortVersionString><sparkle:channel>beta</sparkle:channel></item>'
                ;;
            stable)
                printf '%s\n' '<item><sparkle:version>80.1</sparkle:version><sparkle:shortVersionString>0.4.1</sparkle:shortVersionString></item>'
                ;;
        esac
        printf '%s\n' '</channel></rss>'
    } >"$fixture"
}

root="$work"
QUILL_APPCAST_FILE="$fixture"
export QUILL_APPCAST_FILE
printf '%s\n' \
    '<?xml version="1.0" encoding="utf-8"?>' \
    '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>' \
    '<item><sparkle:version>2</sparkle:version><sparkle:shortVersionString>0.5.0-beta.1</sparkle:shortVersionString><sparkle:channel>beta</sparkle:channel></item>' \
    '</channel></rss>' >"$fixture"
parse_tag v0.5.0-beta.2
require_release_source
[ "$(release_build_number)" = 3 ] || die "trunk build was not derived from first-parent count"
[ "$(bundle_build_number '' 0.5.0-dev "$fixture")" = 3 ] \
    || die "development bundle build was not derived from first-parent count"
[ "$(bundle_build_number 42 0.5.0-dev "$fixture")" = 42 ] \
    || die "explicit bundle build was not preserved"
[ -z "$(bundle_build_number '' 0.5.0 "$fixture")" ] \
    || die "unstamped release bundle unexpectedly derived a development build"

git -C "$work" tag v0.4.0
git -C "$work" checkout -q -b release/0.4
printf '%s\n' hotfix >"$work/hotfix"
git -C "$work" add hotfix
git -C "$work" commit -q -m hotfix
git -C "$work" push -q -u origin release/0.4

write_appcast
parse_tag v0.4.1
require_release_source
[ "$(release_build_number)" = 80.1 ] || die "first maintenance build was not derived from stable build 80"

write_appcast beta
parse_tag v0.4.1-beta.2
[ "$(release_build_number)" = 80.2 ] || die "maintenance suffix did not advance"

write_appcast stable
parse_tag v0.4.2
if (release_build_number) >/dev/null 2>&1; then
    die "stale maintenance ancestry was accepted"
fi

receipt="$test_root/release.json"
tag=v0.4.1
version=0.4.1
build_number=80.1
channel=stable
archive="$test_root/Quill-0.4.1.zip"
archive_sha=archive-sha
dmg="$test_root/Quill-0.4.1.dmg"
dmg_sha=dmg-sha
ed_signature=signature
write_receipt
[ "$(receipt_value build)" = 80.1 ] || die "receipt did not preserve dotted build"

publish_dir="$test_root/publish"
mkdir -p "$publish_dir"
release_source=maintenance
activate_appcast "$fixture" >/dev/null 2>&1
git --git-dir="$origin" show master:docs/updates/appcast.xml >"$test_root/activated-appcast.xml"
cmp "$fixture" "$test_root/activated-appcast.xml"

echo "release versioning tests passed"
