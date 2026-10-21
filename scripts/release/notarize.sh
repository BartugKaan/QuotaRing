#!/usr/bin/env bash
#
# Notarize an artifact with Apple's notary service, then staple the ticket to it.
#
# Usage:
#   notarize.sh <artifact>
#
# <artifact> is a Developer ID signed .app bundle, .dmg or .pkg. A .app is zipped
# into a temporary archive for upload (notarytool only accepts zip, dmg and pkg),
# and the ticket is stapled to the bundle itself.
#
# Environment:
#   ASC_KEY_ID          App Store Connect API key ID                      (secret)
#   ASC_ISSUER_ID       App Store Connect issuer ID                       (secret)
#   ASC_KEY_P8_BASE64   base64 of the AuthKey_XXXX.p8 private key         (secret)
#   NOTARY_TIMEOUT      how long to wait for Apple, e.g. 45m              (default: 45m)
#   RUNNER_TEMP         scratch directory root (default: $TMPDIR)
#
# The decoded key lives in a private temp directory that is removed by an EXIT
# trap. Secrets are only ever passed through variables and pipes. Never enable
# `set -x` in this script, and never print the variables above.

set -euo pipefail

fail() {
    echo "error: $*" >&2
    exit 1
}

artifact="${1:-}"
if [[ -z "$artifact" ]]; then
    fail "usage: notarize.sh <App.app | Image.dmg | Package.pkg>"
fi
artifact="${artifact%/}"

: "${ASC_KEY_ID:?ASC_KEY_ID is not set}"
: "${ASC_ISSUER_ID:?ASC_ISSUER_ID is not set}"
: "${ASC_KEY_P8_BASE64:?ASC_KEY_P8_BASE64 is not set}"

timeout="${NOTARY_TIMEOUT:-45m}"
staple_attempts=5
staple_delay="${STAPLE_RETRY_DELAY:-20}"

# Keep the decoded key private to this user and make sure it is always removed.
umask 077
work_dir="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/notarize.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
trap 'exit 1' HUP INT TERM

key_file="${work_dir}/AuthKey.p8"
if ! printf '%s' "$ASC_KEY_P8_BASE64" | base64 --decode >"$key_file" 2>/dev/null; then
    fail "ASC_KEY_P8_BASE64 is not valid base64 (create it with: base64 -i AuthKey_XXXX.p8)"
fi
if ! grep -q 'BEGIN PRIVATE KEY' "$key_file"; then
    fail "ASC_KEY_P8_BASE64 does not decode to a .p8 private key"
fi
auth=(--key "$key_file" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")

case "$artifact" in
*.app)
    [[ -d "$artifact" ]] || fail "not a directory: ${artifact}"
    submit_file="${work_dir}/$(basename "$artifact" .app).zip"
    ditto -c -k --sequesterRsrc --keepParent "$artifact" "$submit_file"
    ;;
*.dmg | *.pkg)
    [[ -f "$artifact" ]] || fail "no such file: ${artifact}"
    submit_file="$artifact"
    ;;
*)
    fail "unsupported artifact '${artifact}' (expected .app, .dmg or .pkg)"
    ;;
esac

result_file="${work_dir}/submit.out"
error_file="${work_dir}/submit.err"
json_file="${work_dir}/submit.json"

echo "Submitting $(basename "$artifact") to the Apple notary service (waiting up to ${timeout})..."
submit_ok=1
if ! xcrun notarytool submit "$submit_file" "${auth[@]}" \
    --wait --timeout "$timeout" --output-format json >"$result_file" 2>"$error_file"; then
    submit_ok=0
fi

# Tolerate stray lines before the JSON object when reading the result.
sed -n '/^{/,$p' "$result_file" >"$json_file" || true
status=""
submission_id=""
if [[ -s "$json_file" ]]; then
    status="$(plutil -extract status raw -o - "$json_file" 2>/dev/null || true)"
    submission_id="$(plutil -extract id raw -o - "$json_file" 2>/dev/null || true)"
fi

if [[ "$submit_ok" -ne 1 || "$status" != "Accepted" ]]; then
    echo "Notarization did not succeed (status: ${status:-unknown}, submission: ${submission_id:-unknown})." >&2
    if [[ -s "$error_file" ]]; then
        cat "$error_file" >&2
    fi
    if [[ -n "$submission_id" ]]; then
        echo "Notary log:" >&2
        xcrun notarytool log "$submission_id" "${auth[@]}" >&2 || true
    fi
    exit 1
fi
echo "Notarization accepted (submission ${submission_id})."

# The ticket can take a short while to become available after acceptance.
stapled=0
attempt=1
while [[ "$attempt" -le "$staple_attempts" ]]; do
    if xcrun stapler staple "$artifact"; then
        stapled=1
        break
    fi
    echo "Stapling failed (attempt ${attempt}/${staple_attempts}); retrying in ${staple_delay}s..." >&2
    sleep "$staple_delay"
    attempt=$((attempt + 1))
done
if [[ "$stapled" -ne 1 ]]; then
    fail "could not staple the notarization ticket to ${artifact}"
fi
xcrun stapler validate "$artifact"
echo "Notarized and stapled $(basename "$artifact")."
