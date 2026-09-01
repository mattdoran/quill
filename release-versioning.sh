#!/bin/sh

appcast_builds() {
    grep -o '<sparkle:version>[^<]*' "$1" \
        | sed 's/.*>//' || true
}

trunk_build_number() {
    candidate=$(git -C "$root" rev-list --count --first-parent HEAD)
    for published in $(appcast_builds "$1"); do
        printf '%s\n' "$published" | grep -Eq '^[0-9]+(\.[0-9]+){0,2}$' || continue
        published_trunk=${published%%.*}
        if [ "$candidate" -le "$published_trunk" ]; then
            echo "trunk build $candidate must follow published build $published" >&2
            return 1
        fi
    done
    printf '%s\n' "$candidate"
}

bundle_build_number() {
    quill_requested_build=$1
    quill_effective_version=$2
    quill_appcast=$3
    if [ -n "$quill_requested_build" ]; then
        printf '%s\n' "$quill_requested_build"
        return
    fi
    case "$quill_effective_version" in
        *-dev) trunk_build_number "$quill_appcast" ;;
        *) printf '\n' ;;
    esac
}
