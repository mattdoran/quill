#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
test_home=$(mktemp -d)
binary="$test_home/retention-test"
trap 'rm -rf "$test_home"' EXIT

swiftc \
    "$root/Sources/quill/Config.swift" \
    "$root/Sources/quill/AudioRetention.swift" \
    "$root/Tests/RetentionHarness.swift" \
    -o "$binary"

QUILL_HOME="$test_home/home" "$binary"
