#!/bin/sh
# Build and publish signed Sparkle updates. Build is local-only; publish is the
# explicit external boundary that creates the tag, GitHub Release and appcast.
set -eu

if [ -n "${QUILL_RELEASE_ROOT:-}" ]; then
    root=$QUILL_RELEASE_ROOT
else
    root=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
fi
. "$root/release-versioning.sh"
plist="$root/Sources/quill/Info.plist"
publish_dir="$root/.build/publish"
receipt="$publish_dir/release.json"
repo="${GITHUB_REPOSITORY:-mattdoran/quill}"
if [ -n "${SWIFT:-}" ]; then
    swift="$SWIFT"
else
    swift=$(xcrun -f swift)
fi
sparkle_bin="$root/.build/artifacts/sparkle/Sparkle/bin"

usage() {
    cat >&2 <<'EOF'
usage:
  ./release.sh check v0.4.0-beta.1
  ./release.sh build v0.4.0-beta.1
  ./release.sh publish
  ./release.sh prepare-next 0.5.0
EOF
    exit 64
}

die() {
    echo "$*" >&2
    exit 1
}

plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$plist"
}

parse_tag() {
    tag="$1"
    if printf '%s\n' "$tag" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+-beta\.[1-9][0-9]*$'; then
        version=${tag#v}
        base_version=${version%-beta.*}
        channel=beta
    elif printf '%s\n' "$tag" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
        version=${tag#v}
        base_version=$version
        channel=stable
    else
        die "release tag must be vX.Y.Z or vX.Y.Z-beta.N"
    fi
    release_line=${base_version%.*}
}

require_release_source() {
    [ -z "$(git -C "$root" status --porcelain --untracked-files=all)" ] \
        || die "release builds require a clean worktree"
    head=$(git -C "$root" rev-parse HEAD)
    branch=$(git -C "$root" branch --show-current)
    if [ "$branch" = master ]; then
        tracked=$(git -C "$root" rev-parse origin/master)
        [ "$head" = "$tracked" ] || die "master must match origin/master"
        release_source=trunk
    elif [ "$branch" = "release/$release_line" ]; then
        tracked=$(git -C "$root" rev-parse "origin/$branch" 2>/dev/null) \
            || die "$branch must be pushed before building a release"
        [ "$head" = "$tracked" ] || die "$branch must match origin/$branch"
        release_source=maintenance
    elif [ -z "$branch" ] && [ "${GITHUB_ACTIONS:-}" = true ]; then
        git -C "$root" merge-base --is-ancestor "$head" origin/master \
            || die "release tag is not on master"
        release_source=trunk
    else
        die "release builds must come from master, release/$release_line, or a tagged GitHub Actions checkout"
    fi
}

appcast_path() {
    if [ -n "${QUILL_APPCAST_FILE:-}" ]; then
        [ -f "$QUILL_APPCAST_FILE" ] || die "appcast does not exist: $QUILL_APPCAST_FILE"
        printf '%s\n' "$QUILL_APPCAST_FILE"
        return
    fi

    feed_url=$(plist_value SUFeedURL)
    downloaded="${TMPDIR:-/private/tmp}/quill-release-appcast.$$"
    if curl -fsS "$feed_url" -o "$downloaded" 2>/dev/null; then
        printf '%s\n' "$downloaded"
    elif [ "${release_source:-}" = maintenance ]; then
        die "maintenance releases require the published appcast"
    elif [ -f "$root/docs/updates/appcast.xml" ]; then
        printf '%s\n' "$root/docs/updates/appcast.xml"
    else
        die "could not load the published appcast"
    fi
}

maintenance_build_number() {
    appcast=$1
    base_tag=$(git -C "$root" describe --tags --abbrev=0 \
        --match "v$release_line.*" --exclude 'v*-beta.*' HEAD 2>/dev/null) \
        || die "release/$release_line has no stable release tag ancestor"
    printf '%s\n' "$base_tag" | grep -Eq "^v$release_line\.[0-9]+$" \
        || die "$base_tag is not a stable $release_line release tag"

    latest_patch=-1
    for stable in $(/usr/bin/xmllint --xpath \
        "//*[local-name()='item'][not(*[local-name()='channel'])]/*[local-name()='shortVersionString']/text()" \
        "$appcast" 2>/dev/null || true)
    do
        case "$stable" in
            "$release_line".*)
                patch=${stable#"$release_line".}
                case "$patch" in *[!0-9]*|'') continue ;; esac
                [ "$patch" -gt "$latest_patch" ] && latest_patch=$patch
                ;;
        esac
    done
    [ "$latest_patch" -ge 0 ] || die "appcast has no stable $release_line release"
    [ "$base_tag" = "v$release_line.$latest_patch" ] \
        || die "maintenance branch must descend from latest stable v$release_line.$latest_patch"

    target_patch=${base_version#"$release_line".}
    [ "$target_patch" -gt "$latest_patch" ] \
        || die "$base_version must follow v$release_line.$latest_patch"

    stable_version=${base_tag#v}
    base_build=$(/usr/bin/xmllint --xpath \
        "string((//*[local-name()='item'][*[local-name()='shortVersionString' and text()='$stable_version']]/*[local-name()='version'])[1])" \
        "$appcast")
    printf '%s\n' "$base_build" | grep -Eq '^[0-9]+(\.[0-9]+)?$' \
        || die "$stable_version has unsupported build $base_build"
    build_root=${base_build%%.*}
    suffix=0
    for published in $(appcast_builds "$appcast"); do
        case "$published" in
            "$build_root".*)
                published_suffix=${published#"$build_root".}
                case "$published_suffix" in *[!0-9]*|'') continue ;; esac
                [ "$published_suffix" -gt "$suffix" ] && suffix=$published_suffix
                ;;
        esac
    done
    printf '%s.%s\n' "$build_root" "$((suffix + 1))"
}

release_build_number() {
    appcast=$(appcast_path)
    case "$release_source" in
        trunk) trunk_build_number "$appcast" ;;
        maintenance) maintenance_build_number "$appcast" ;;
        *) die "unknown release source: $release_source" ;;
    esac
    case "$appcast" in
        "$root/docs/updates/appcast.xml"|"${QUILL_APPCAST_FILE:-}") ;;
        *) rm -f "$appcast" ;;
    esac
}

check_signing() {
    SIGN_IDENTITY="${SIGN_IDENTITY:-}"
    NOTARY_PROFILE="${NOTARY_PROFILE:-}"
    if [ -f "$root/signing.conf" ]; then
        # shellcheck source=/dev/null
        . "$root/signing.conf"
    fi
    if [ -z "$SIGN_IDENTITY" ]; then
        SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
            | awk -F'"' '/Developer ID Application/ { print $2; exit }')
    fi
    [ -n "$SIGN_IDENTITY" ] || die "no Developer ID Application identity found"
    [ -n "$NOTARY_PROFILE" ] || die "NOTARY_PROFILE is missing from signing.conf"
    security find-identity -v -p codesigning | grep -Fq "\"$SIGN_IDENTITY\"" \
        || die "Developer ID identity is unavailable"
    [ -x "$sparkle_bin/generate_keys" ] || die "resolve Swift packages first"
    public_key=$($sparkle_bin/generate_keys -p)
    [ "$public_key" = "$(plist_value SUPublicEDKey)" ] \
        || die "Sparkle Keychain key does not match SUPublicEDKey"
}

check_release() {
    [ "$#" -eq 1 ] || usage
    parse_tag "$1"
    source_version=$(plist_value CFBundleShortVersionString)
    [ "$source_version" = "$base_version-dev" ] \
        || die "$tag requires source version $base_version-dev, found $source_version"
    require_release_source
    build_number=$(release_build_number)
    check_signing
    command -v gh >/dev/null 2>&1 || die "gh is required"
    gh auth status >/dev/null 2>&1 || die "gh is not authenticated"
    if git -C "$root" rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
        [ "$(git -C "$root" rev-list -n 1 "$tag")" = "$(git -C "$root" rev-parse HEAD)" ] \
            || die "$tag already points to another commit"
    fi
    echo "$tag: version=$version build=$build_number channel=$channel"
}

run_audio_checks() {
    binary="$root/.build/release/quill"
    "$binary" check-live-aec --out /private/tmp/quill-release-aec-zero
    "$binary" check-live-aec --skew-ms 250 \
        --out /private/tmp/quill-release-aec-system-late
    "$binary" check-live-aec --skew-ms=-250 \
        --out /private/tmp/quill-release-aec-system-early
    control=/private/tmp/quill-release-aec-control.log
    if "$binary" check-live-aec --skew-ms 250 --misalign-ms 200 \
        --out /private/tmp/quill-release-aec-control >"$control" 2>&1
    then
        die "deliberately misaligned AEC control unexpectedly passed"
    fi
    grep -Fq 'cancels echo: FAIL' "$control" \
        || die "misaligned AEC control failed for the wrong reason"
}

write_receipt() {
    /usr/bin/plutil -create xml1 "$receipt"
    /usr/bin/plutil -insert tag -string "$tag" "$receipt"
    /usr/bin/plutil -insert version -string "$version" "$receipt"
    /usr/bin/plutil -insert build -string "$build_number" "$receipt"
    /usr/bin/plutil -insert channel -string "$channel" "$receipt"
    /usr/bin/plutil -insert commit -string "$(git -C "$root" rev-parse HEAD)" "$receipt"
    /usr/bin/plutil -insert archive -string "$archive" "$receipt"
    /usr/bin/plutil -insert sha256 -string "$archive_sha" "$receipt"
    /usr/bin/plutil -insert dmg -string "$dmg" "$receipt"
    /usr/bin/plutil -insert dmgSha256 -string "$dmg_sha" "$receipt"
    /usr/bin/plutil -insert edSignature -string "$ed_signature" "$receipt"
    /usr/bin/plutil -convert json "$receipt"
}

build_release() {
    [ "$#" -eq 1 ] || usage
    check_release "$1"
    tag="$1"
    export QUILL_HOME="${QUILL_HOME:-/private/tmp/quill-release-home}"
    SWIFT="$swift" "$root/build.sh" test
    SWIFT="$swift" "$root/build.sh" release
    run_audio_checks

    [ "$publish_dir" = "$root/.build/publish" ] || die "unexpected publish directory"
    rm -rf "$publish_dir"
    mkdir -p "$publish_dir"
    bundle_args="--notarize --version $version --build $build_number"
    [ "$channel" = beta ] && bundle_args="$bundle_args --channel beta"
    # Arguments are generated above and contain only validated versions and build numbers.
    # shellcheck disable=SC2086
    "$root/bundle.sh" $bundle_args

    app="$root/.build/release/Quill.app"
    archive="$publish_dir/Quill-$version.zip"
    dmg_source="$root/.build/release/Quill-$version.dmg"
    dmg="$publish_dir/Quill-$version.dmg"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
    "$root/build-dmg.sh" --notarize
    cp "$dmg_source" "$dmg"
    codesign --verify --deep --strict "$app"
    xcrun stapler validate "$app"
    codesign --verify --strict "$dmg"
    xcrun stapler validate "$dmg"
    [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
        "$app/Contents/Info.plist")" = "$version" ] || die "bundle version mismatch"
    [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
        "$app/Contents/Info.plist")" = "$build_number" ] || die "bundle build mismatch"
    archive_sha=$(shasum -a 256 "$archive" | awk '{print $1}')
    dmg_sha=$(shasum -a 256 "$dmg" | awk '{print $1}')
    ed_signature=$($sparkle_bin/sign_update -p "$archive")
    "$sparkle_bin/sign_update" --verify "$archive" "$ed_signature"
    write_receipt
    echo "$receipt"
}

receipt_value() {
    /usr/bin/plutil -extract "$1" raw "$receipt"
}

activate_appcast() {
    generated_appcast=$1
    if [ "$release_source" = trunk ] || [ "${GITHUB_ACTIONS:-}" = true ]; then
        mkdir -p "$root/docs/updates"
        cp "$generated_appcast" "$root/docs/updates/appcast.xml"
    fi

    if [ "${GITHUB_ACTIONS:-}" = true ]; then
        echo "published $tag; deploy docs/ as the GitHub Pages artifact"
    elif [ "$release_source" = maintenance ]; then
        git -C "$root" fetch origin master
        activation="$publish_dir/appcast-master-worktree"
        [ ! -e "$activation" ] || die "stale appcast worktree exists: $activation"
        git -C "$root" worktree add --detach "$activation" origin/master
        mkdir -p "$activation/docs/updates"
        cp "$generated_appcast" "$activation/docs/updates/appcast.xml"
        git -C "$activation" add docs/updates/appcast.xml
        git -C "$activation" commit -m "Publish $version update feed"
        git -C "$activation" push origin HEAD:master
        git -C "$root" worktree remove "$activation"
        echo "published $tag; appcast is active on master"
    else
        git -C "$root" add docs/updates/appcast.xml
        git -C "$root" commit -m "Publish $version update feed"
        git -C "$root" push
        echo "published $tag; appcast is the activation commit"
    fi
}

publish_release() {
    [ "$#" -eq 0 ] || usage
    [ -f "$receipt" ] || die "build a release first"
    tag=$(receipt_value tag)
    version=$(receipt_value version)
    channel=$(receipt_value channel)
    expected_commit=$(receipt_value commit)
    archive=$(receipt_value archive)
    expected_sha=$(receipt_value sha256)
    dmg=$(receipt_value dmg)
    expected_dmg_sha=$(receipt_value dmgSha256)
    ed_signature=$(receipt_value edSignature)
    parse_tag "$tag"
    [ "$(git -C "$root" rev-parse HEAD)" = "$expected_commit" ] \
        || die "HEAD no longer matches the built release"
    require_release_source
    build_number=$(release_build_number)
    [ "$build_number" = "$(receipt_value build)" ] \
        || die "published appcast now assigns this release build $build_number; rebuild it"
    [ -f "$archive" ] || die "release archive is missing"
    [ "$(shasum -a 256 "$archive" | awk '{print $1}')" = "$expected_sha" ] \
        || die "release archive changed after verification"
    [ -f "$dmg" ] || die "release DMG is missing"
    [ "$(shasum -a 256 "$dmg" | awk '{print $1}')" = "$expected_dmg_sha" ] \
        || die "release DMG changed after verification"
    codesign --verify --strict "$dmg"
    xcrun stapler validate "$dmg"
    "$sparkle_bin/sign_update" --verify "$archive" "$ed_signature"

    if git -C "$root" rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
        [ "$(git -C "$root" rev-list -n 1 "$tag")" = "$expected_commit" ] \
            || die "$tag points to another commit"
    else
        git -C "$root" tag -a "$tag" -m "$tag"
    fi
    [ "${GITHUB_ACTIONS:-}" = true ] || git -C "$root" push origin "$tag"

    if ! gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
        release_args="--repo $repo --title $tag --generate-notes"
        [ "$channel" = beta ] && release_args="$release_args --prerelease"
        # Repository and tag values are validated constants or parsed release tags.
        # shellcheck disable=SC2086
        gh release create "$tag" "$archive" "$dmg" $release_args
    fi

    verify_dir=$(mktemp -d "$publish_dir/verify.XXXXXX")
    for asset in "$archive" "$dmg"
    do
        asset_name=$(basename "$asset")
        if ! gh release download "$tag" --repo "$repo" \
            --pattern "$asset_name" --dir "$verify_dir" 2>/dev/null
        then
            gh release upload "$tag" "$asset" --repo "$repo"
            gh release download "$tag" --repo "$repo" \
                --pattern "$asset_name" --dir "$verify_dir"
        fi
        cmp "$asset" "$verify_dir/$asset_name" \
            || die "published $asset_name differs from the receipt"
    done
    rm -rf "$verify_dir"

    appcast_dir=$(mktemp -d "$publish_dir/appcast.XXXXXX")
    cp "$archive" "$appcast_dir/"
    feed_url=$(plist_value SUFeedURL)
    if curl -fsS "$feed_url" -o "$appcast_dir/appcast.xml" 2>/dev/null; then
        :
    elif [ -f "$root/docs/updates/appcast.xml" ]; then
        cp "$root/docs/updates/appcast.xml" "$appcast_dir/appcast.xml"
    fi
    gh release view "$tag" --repo "$repo" --json body --jq .body \
        >"$appcast_dir/Quill-$version.md"
    appcast_args="--maximum-deltas 0 --maximum-versions 0 --embed-release-notes \
--download-url-prefix https://github.com/$repo/releases/download/$tag/ \
--link https://github.com/$repo -o $appcast_dir/appcast.xml"
    [ "$channel" = beta ] && appcast_args="$appcast_args --channel beta"
    # URLs and channel are derived from validated constants and release metadata.
    # shellcheck disable=SC2086
    "$sparkle_bin/generate_appcast" $appcast_args "$appcast_dir"
    generated_appcast="$appcast_dir/appcast.xml"
    activate_appcast "$generated_appcast"
    rm -rf "$appcast_dir"
}

prepare_next() {
    [ "$#" -eq 1 ] || usage
    next="$1"
    printf '%s\n' "$next" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
        || die "next version must be X.Y.Z"
    release_line=${next%.*}
    require_release_source
    /usr/libexec/PlistBuddy \
        -c "Set :CFBundleShortVersionString $next-dev" "$plist"
    echo "prepared $next-dev; review and commit the plist change"
}

main() {
    [ "$#" -ge 1 ] || usage
    command=$1
    shift
    case "$command" in
        check) check_release "$@" ;;
        build) build_release "$@" ;;
        publish) publish_release "$@" ;;
        prepare-next) prepare_next "$@" ;;
        *) usage ;;
    esac
}

[ "${QUILL_RELEASE_LIBRARY_ONLY:-}" = 1 ] || main "$@"
