#!/bin/sh
# Sourced after signing.conf. Notarizes with the App Store Connect API key in
# NOTARY_KEYS (AuthKey_<key ID>.p8 beside a file `issuer`), shared with Matt's
# other projects: a key is a file, so it works with the screen locked and in an
# agent's sandbox, where the keychain profile NOTARY_PROFILE cannot be read.
NOTARY_KEYS="${NOTARY_KEYS:-${XDG_CONFIG_HOME:-$HOME/.config}/notary}"

notary_key() {
    set -- "$NOTARY_KEYS"/AuthKey_*.p8
    if [ $# -eq 1 ] && [ -f "$1" ] && [ -s "$NOTARY_KEYS/issuer" ]; then
        echo "$1"
    fi
}

notary_ready() {
    [ -n "$(notary_key)" ] || [ -n "$NOTARY_PROFILE" ]
}

notary_missing="needs the API key in $NOTARY_KEYS, or NOTARY_PROFILE in signing.conf"

# notarytool with whichever credential is here: notary submit "$zip" --wait
notary() {
    key=$(notary_key)
    if [ -n "$key" ]; then
        id=$(basename "$key" .p8)
        xcrun notarytool "$@" --key "$key" --key-id "${id#AuthKey_}" \
            --issuer "$(cat "$NOTARY_KEYS/issuer")"
    else
        xcrun notarytool "$@" --keychain-profile "$NOTARY_PROFILE"
    fi
}
