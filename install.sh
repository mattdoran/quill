#!/bin/sh
# Install the reviewed bundle for this user, make it the CLI source of truth,
# and restart Quill so the running process always matches the installed files.
set -eu

root="$(cd "$(dirname "$0")" && pwd)"
source_app="$root/.build/release/Quill.app"

user_name="$(id -un)"
user_home="$(dscl . -read "/Users/$user_name" NFSHomeDirectory | awk '{print $2}')"
case "$user_home" in
    /Users/*) ;;
    *) echo "refusing unexpected user home: $user_home" >&2; exit 1 ;;
esac

applications_dir="$user_home/Applications"
target_app="$applications_dir/Quill.app"
target_executable="$target_app/Contents/MacOS/quill"
bin_dir="$user_home/.local/bin"
cli_link="$bin_dir/quill"
stage="$applications_dir/.Quill.app.installing.$$"
app_backup="$applications_dir/.Quill.app.previous.$$"
cli_backup="$bin_dir/.quill.previous.$$"
rollback_needed=no

case "$target_app" in
    /Users/*/Applications/Quill.app) ;;
    *) echo "refusing unexpected install target: $target_app" >&2; exit 1 ;;
esac

cleanup() {
    status=$?
    if [ "$rollback_needed" = yes ] && [ "$status" -ne 0 ]; then
        echo "install failed; restoring previous Quill" >&2
        if [ -d "$target_app" ]; then
            /bin/rm -rf -- "$target_app"
        fi
        if [ -d "$app_backup" ]; then
            mv "$app_backup" "$target_app"
        fi
        if [ -e "$cli_link" ] || [ -L "$cli_link" ]; then
            /bin/rm -f -- "$cli_link"
        fi
        if [ -e "$cli_backup" ] || [ -L "$cli_backup" ]; then
            mv "$cli_backup" "$cli_link"
        fi
        if [ -d "$target_app" ]; then
            /usr/bin/open "$target_app" || true
        fi
    fi
    if [ -d "$stage" ]; then
        /bin/rm -rf -- "$stage"
    fi
    exit "$status"
}
trap cleanup EXIT HUP INT TERM

if [ ! -x "$source_app/Contents/MacOS/quill" ]; then
    echo "bundle first: ./bundle.sh" >&2
    exit 1
fi

mkdir -p "$applications_dir" "$bin_dir"
/usr/bin/ditto "$source_app" "$stage"
/usr/bin/codesign --verify --deep --strict "$stage"

if /usr/bin/pgrep -x quill >/dev/null 2>&1; then
    /usr/bin/osascript -e 'tell application id "com.mattdoran.quill" to quit' \
        >/dev/null 2>&1 || true
    attempts=0
    while /usr/bin/pgrep -x quill >/dev/null 2>&1 && [ "$attempts" -lt 40 ]; do
        sleep 0.25
        attempts=$((attempts + 1))
    done
fi
/usr/bin/pkill -x quill >/dev/null 2>&1 || true

rollback_needed=yes
if [ -d "$target_app" ]; then
    mv "$target_app" "$app_backup"
fi
mv "$stage" "$target_app"

if [ -e "$cli_link" ] || [ -L "$cli_link" ]; then
    mv "$cli_link" "$cli_backup"
fi
ln -s "$target_executable" "$cli_link"

/usr/bin/open "$target_app"
attempts=0
while ! /usr/bin/pgrep -f "$target_executable" >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 40 ]; then
        echo "installed Quill did not start" >&2
        exit 1
    fi
    sleep 0.25
done

if [ "$(readlink "$cli_link")" != "$target_executable" ]; then
    echo "CLI link does not point to the installed app" >&2
    exit 1
fi

rollback_needed=no
if [ -d "$app_backup" ]; then
    /bin/rm -rf -- "$app_backup"
fi
if [ -e "$cli_backup" ] || [ -L "$cli_backup" ]; then
    /bin/rm -f -- "$cli_backup"
fi
trap - EXIT HUP INT TERM

echo "$target_app"
echo "$cli_link -> $target_executable"
