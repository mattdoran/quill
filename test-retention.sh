#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
test_home=$(mktemp -d)
binary="$test_home/retention-test"
trap 'rm -rf "$test_home"' EXIT

compile() {
    if command -v swiftly >/dev/null 2>&1; then
        swiftly run swiftc "$@"
    else
        swiftc "$@"
    fi
}

CLANG_MODULE_CACHE_PATH="$test_home/module-cache" compile \
    "$root/Sources/quill/MeetingProfile.swift" \
    "$root/Sources/quill/Config.swift" \
    "$root/Sources/quill/AudioRetention.swift" \
    "$root/Tests/RetentionHarness.swift" \
    -o "$binary"

QUILL_HOME="$test_home/home" "$binary"
