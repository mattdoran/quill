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
    exec "$swift" test --package-path "$root" --no-color-diagnostics
fi
exec "$swift" build --package-path "$root" --no-color-diagnostics -c "$action"
