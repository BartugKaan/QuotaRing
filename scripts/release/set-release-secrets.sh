#!/usr/bin/env bash
# Stores the six release secrets in the GitHub "release" environment (docs/RELEASING.md, step 5).
#
# Run it yourself, from the repository root:
#
#   scripts/release/set-release-secrets.sh path/to/DeveloperID.p12 path/to/AuthKey_<KEYID>.p8
#
# The .p12 and .p8 files are base64-encoded and piped straight into `gh secret set`; the .p12 password is read from a
# hidden prompt. No value is printed, written to disk or kept in shell history, and none is handed to `gh` on its command
# line. Before anything is sent, the .p12 is imported into a throwaway keychain exactly as the release workflow does
# (`security import`, which takes the password as an argument, so it is visible to your own processes for that moment),
# so a wrong password or a file the workflow cannot use fails here instead of an hour into a release. Add --dry-run to
# check the inputs without contacting GitHub.
set -euo pipefail

REPO="BartugKaan/QuotaRing"
ENVIRONMENT="release"

dry_run=false
args=()
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=true ;;
    *) args+=("$arg") ;;
  esac
done

if (( ${#args[@]} != 2 )); then
  echo "usage: $0 [--dry-run] path/to/DeveloperID.p12 path/to/AuthKey_<KEYID>.p8" >&2
  exit 2
fi
p12="${args[0]}"
p8="${args[1]}"

fail() {
  echo "error: $*" >&2
  exit 1
}

[[ -f "$p12" && -s "$p12" ]] || fail "the .p12 file does not exist or is empty: $p12"
[[ -f "$p8" && -s "$p8" ]] || fail "the .p8 file does not exist or is empty: $p8"
grep -q "BEGIN PRIVATE KEY" "$p8" || fail "$p8 does not look like an App Store Connect API key (.p8)"

if [[ "$(basename "$p8")" =~ ^AuthKey_([A-Z0-9]{10})\.p8$ ]]; then
  key_id="${BASH_REMATCH[1]}"
  echo "App Store Connect Key ID (from the file name): $key_id"
else
  read -r -p "App Store Connect Key ID (10 characters): " key_id
fi
[[ "$key_id" =~ ^[A-Z0-9]{10}$ ]] || fail "the Key ID must be 10 capital letters or digits"

read -r -p "App Store Connect Issuer ID (a UUID): " issuer_id
issuer_id="$(tr '[:upper:]' '[:lower:]' <<<"$issuer_id")"
[[ "$issuer_id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
  || fail "the Issuer ID must be a UUID like 12345678-abcd-..."

read -r -p "Apple Team ID (10 characters, shown as '(TEAMID)' in the certificate name): " team_id
[[ "$team_id" =~ ^[A-Z0-9]{10}$ ]] || fail "the Team ID must be 10 capital letters or digits"

read -r -s -p "Password of the .p12 file (hidden): " p12_password
echo
[[ -n "$p12_password" ]] || fail "the .p12 password is empty"

verify_p12() {
  # Import into a temporary keychain the way scripts/release/import-cert.sh does in CI, then delete it again.
  local dir keychain keychain_password status=0
  dir="$(mktemp -d)"
  keychain="$dir/verify.keychain-db"
  keychain_password="$(uuidgen)"
  security create-keychain -p "$keychain_password" "$keychain" > /dev/null 2>&1 || status=1
  if (( status == 0 )); then
    security import "$p12" -k "$keychain" -P "$p12_password" -x -T /usr/bin/codesign > /dev/null 2>&1 || status=2
    # Without -v: the throwaway keychain lacks Apple's intermediate certificate, so a real Developer ID identity
    # could be listed as not yet valid there; only its presence matters here.
    if (( status == 0 )) && ! security find-identity -p codesigning "$keychain" 2>/dev/null \
      | grep -q "Developer ID Application"; then
      status=3
    fi
    security delete-keychain "$keychain" > /dev/null 2>&1 || true
  fi
  rm -rf "$dir"
  case "$status" in
    0) echo "The .p12 opens with this password and holds a Developer ID Application identity." ;;
    1) fail "could not create a temporary keychain to check the .p12" ;;
    2) fail "the .p12 could not be imported: wrong password, or a file that is not a certificate with its private key" ;;
    *) fail "the .p12 holds no 'Developer ID Application' identity; export that certificate from Xcode" ;;
  esac
}
verify_p12

names=(DEVELOPER_ID_P12_BASE64 DEVELOPER_ID_P12_PASSWORD APPLE_TEAM_ID ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8_BASE64)

if $dry_run; then
  echo "Dry run: the inputs look right. Without --dry-run these secrets would be set in the '$ENVIRONMENT'" \
    "environment of $REPO: ${names[*]}"
  exit 0
fi

command -v gh > /dev/null || fail "the GitHub CLI (gh) is not installed"
gh auth status > /dev/null 2>&1 || fail "gh is not signed in; run 'gh auth login' first"

set_secret() {
  # Reads the value from standard input, so it never appears on a command line.
  gh secret set "$1" --repo "$REPO" --env "$ENVIRONMENT" > /dev/null
  echo "  set $1"
}

echo "Setting the secrets in the '$ENVIRONMENT' environment of $REPO:"
base64 -i "$p12" | tr -d '\n' | set_secret DEVELOPER_ID_P12_BASE64
printf '%s' "$p12_password" | set_secret DEVELOPER_ID_P12_PASSWORD
printf '%s' "$team_id" | set_secret APPLE_TEAM_ID
printf '%s' "$key_id" | set_secret ASC_KEY_ID
printf '%s' "$issuer_id" | set_secret ASC_ISSUER_ID
base64 -i "$p8" | tr -d '\n' | set_secret ASC_KEY_P8_BASE64
unset p12_password

echo
echo "Done. The environment now has these secrets (names only):"
gh secret list --repo "$REPO" --env "$ENVIRONMENT"
echo
echo "Keep the .p12, its password and the .p8 in your password manager, then delete the files from this Mac."
