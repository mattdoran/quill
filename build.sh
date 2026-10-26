#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")" && pwd)

action=${1:-release}
case "$action" in
    debug|release|test) ;;
    *) echo "usage: ./build.sh [debug|release|test]" >&2; exit 64 ;;
esac

if [ -n "${SWIFT:-}" ]; then
    swift="$SWIFT"
else
    swift=$(xcrun --find swift)
fi

# SwiftPM fingerprints its otherwise TTY-dependent diagnostic mode.
if [ "$action" = test ]; then
    output=$(mktemp -d "${TMPDIR:-/private/tmp}/quill-test.XXXXXX")
    trap 'rm -rf "$output"' EXIT HUP INT TERM
    {
        status=0
        "$swift" test --package-path "$root" --build-system native \
            --no-color-diagnostics 2>&1 || status=$?
        echo "$status" >"$output/status"
    } | tee "$output/log"
    status=$(cat "$output/status")
    [ "$status" -eq 0 ] || exit "$status"
    # Swift Testing can exit 0 mid-suite; only its summary proves the run finished.
    if ! grep -q 'Test run with [0-9]* tests* in [0-9]* suites* passed' "$output/log"; then
        echo "test run ended without reporting a result" >&2
        exit 1
    fi
    rm -rf "$output"
    trap - EXIT HUP INT TERM
    "$root/Tests/ReleaseVersioningTests.sh"
    exec "$root/Tests/BuildScriptTests.sh"
fi
exec "$swift" build --package-path "$root" --build-system native \
    --no-color-diagnostics -c "$action"
