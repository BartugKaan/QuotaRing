#!/usr/bin/env bash
#
# Import the Developer ID Application identity into a temporary keychain so that
# `xcodebuild` and `codesign` can sign the release on a CI runner.
#
# Usage:
#   import-cert.sh [import]   create the keychain and import the identity (default)
#   import-cert.sh cleanup    delete the keychain created by `import`
#
# Environment (import):
#   DEVELOPER_ID_P12_BASE64    base64 of the exported .p12 file         (secret)
#   DEVELOPER_ID_P12_PASSWORD  password protecting the .p12             (secret)
#   APPLE_TEAM_ID              optional; must match the imported identity
#   RUNNER_TEMP                directory for the keychain (default: $TMPDIR)
#   KEYCHAIN_PATH              optional override for the keychain location
#   GITHUB_ENV                 optional; receives KEYCHAIN_PATH=<path>
#
# The keychain stays in place after a successful import because later steps need
# it. On any failure it is deleted by the EXIT trap. The workflow also runs
# `cleanup` so the signing key never outlives the steps that use it.
#
# Secrets are only ever passed through variables and pipes. Never enable `set -x`
# in this script, and never print the variables above.
#
# Note: `security` has no way to read a password from stdin, so the generated
# keychain password and the .p12 password do appear in this process's argument
# list. That is acceptable on an ephemeral, single-tenant CI VM; do not run this
# script on a shared machine.

set -euo pipefail

mode="${1:-import}"
tmp_root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
tmp_root="${tmp_root%/}"
keychain_path="${KEYCHAIN_PATH:-${tmp_root}/quotaring-signing.keychain-db}"

fail() {
    echo "error: $*" >&2
    exit 1
}

remove_keychain() {
    security delete-keychain "$keychain_path" >/dev/null 2>&1 || true
    rm -f "$keychain_path"
}

case "$mode" in
import) ;;
cleanup)
    remove_keychain
    echo "Removed the temporary signing keychain."
    exit 0
    ;;
*) fail "unknown mode '${mode}' (expected 'import' or 'cleanup')" ;;
esac

: "${DEVELOPER_ID_P12_BASE64:?DEVELOPER_ID_P12_BASE64 is not set}"
: "${DEVELOPER_ID_P12_PASSWORD:?DEVELOPER_ID_P12_PASSWORD is not set}"

# Everything created below (keychain, decoded .p12) must be private to this user.
umask 077

p12_file=""
imported=0
on_exit() {
    if [[ -n "$p12_file" ]]; then
        rm -f "$p12_file"
    fi
    if [[ "$imported" -ne 1 ]]; then
        remove_keychain
    fi
}
trap on_exit EXIT
trap 'exit 1' HUP INT TERM

# Start from a clean slate in case an earlier attempt left a keychain behind.
remove_keychain

keychain_password="$(openssl rand -base64 32)"
security create-keychain -p "$keychain_password" "$keychain_path"
# No auto-lock on sleep; lock after 6 hours (longer than any release job).
security set-keychain-settings -lut 21600 "$keychain_path"
security unlock-keychain -p "$keychain_password" "$keychain_path"

p12_file="$(mktemp "${tmp_root}/developer-id.XXXXXX")"
if ! printf '%s' "$DEVELOPER_ID_P12_BASE64" | base64 --decode >"$p12_file" 2>/dev/null; then
    fail "DEVELOPER_ID_P12_BASE64 is not valid base64 (create it with: base64 -i DeveloperID.p12)"
fi
if [[ ! -s "$p12_file" ]]; then
    fail "DEVELOPER_ID_P12_BASE64 decoded to an empty file"
fi

# The keychain stays unlocked in the search list until the cleanup step, and the
# build runs code in that window (the generated project's build phases, any
# future package plugin). So the key is protected against being copied out:
#   -x  imports the private key non-extractable: no tool, `security export`
#       included, can export the identity from the keychain, even unlocked.
#   -T  puts only codesign on the key's access list. `/usr/bin/security` is
#       deliberately not on it; it only lists identities here, which needs no
#       access to the key.
# Signing still works: codesign uses the key inside the keychain and never needs
# to export it. If codesign cannot use the key on a first release, see "When
# something fails" in docs/RELEASING.md.
security import "$p12_file" \
    -f pkcs12 \
    -k "$keychain_path" \
    -P "$DEVELOPER_ID_P12_PASSWORD" \
    -x \
    -T /usr/bin/codesign >/dev/null

# Let codesign and other Apple tools use the private key without a UI prompt.
security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s -k "$keychain_password" "$keychain_path" >/dev/null

# Put the new keychain first in the user search list, keeping the existing ones.
existing=()
while IFS= read -r entry; do
    entry="${entry#"${entry%%[![:space:]]*}"}"
    entry="${entry#\"}"
    entry="${entry%\"}"
    if [[ -n "$entry" ]]; then
        existing+=("$entry")
    fi
done < <(security list-keychains -d user)
security list-keychains -d user -s "$keychain_path" ${existing[@]+"${existing[@]}"}

# Confirm that a usable Developer ID Application identity is now available.
identities="$(security find-identity -v -p codesigning "$keychain_path")"
count="$(grep -c 'Developer ID Application' <<<"$identities" || true)"
if [[ "$count" -lt 1 ]]; then
    fail "no valid 'Developer ID Application' identity found in the imported .p12" \
        "(wrong certificate type, expired, or the private key is missing)"
fi
if [[ -n "${APPLE_TEAM_ID:-}" ]]; then
    team_matches="$(grep -F 'Developer ID Application' <<<"$identities" | grep -cF "(${APPLE_TEAM_ID})" || true)"
    if [[ "$team_matches" -lt 1 ]]; then
        fail "the imported certificate does not belong to the team in APPLE_TEAM_ID"
    fi
fi

if [[ -n "${GITHUB_ENV:-}" ]]; then
    printf 'KEYCHAIN_PATH=%s\n' "$keychain_path" >>"$GITHUB_ENV"
fi

imported=1
echo "Imported ${count} Developer ID Application identity into a temporary keychain."
