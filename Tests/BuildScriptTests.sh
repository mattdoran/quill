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

echo "build script tests passed"
