#!/bin/sh
set -eu

project=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
test_root=$(mktemp -d "${TMPDIR:-/private/tmp}/quill-build-script.XXXXXX")
trap 'rm -rf "$test_root"' EXIT HUP INT TERM

fake_swift="$test_root/swift"
arguments="$test_root/arguments"
cat >"$fake_swift" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >"$QUILL_BUILD_ARGUMENTS"
EOF
chmod +x "$fake_swift"

QUILL_BUILD_ARGUMENTS="$arguments" SWIFT="$fake_swift" "$project/build.sh" debug
grep -Fxq -- '--build-system' "$arguments"
grep -Fxq -- 'native' "$arguments"

truncated_swift="$test_root/truncated-swift"
printf '#!/bin/sh\necho "Test run started."\n' >"$truncated_swift"
chmod +x "$truncated_swift"
if SWIFT="$truncated_swift" "$project/build.sh" test >/dev/null 2>&1; then
    echo "build.sh test accepted a run that never reported a result" >&2
    exit 1
fi

failing_swift="$test_root/failing-swift"
printf '#!/bin/sh\nexit 3\n' >"$failing_swift"
chmod +x "$failing_swift"
status=0
SWIFT="$failing_swift" "$project/build.sh" test >/dev/null 2>&1 || status=$?
[ "$status" -eq 3 ]

echo "build script tests passed"
