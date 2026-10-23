#!/usr/bin/env bash
#
# Build and check the QuotaRing release artifacts in dist/:
#
#   dist/QuotaRing-<version>.dmg   Developer ID signed disk image
#   dist/QuotaRing-<version>.zip   zipped, stapled app (ditto)
#   dist/SHA256SUMS                checksums of the two files above
#
# Usage:
#   package.sh <stage> <version>        version without the leading "v", e.g. 0.1.0
#
# Stages, in the order the release workflow runs them:
#   check       sanity-check the exported app (version, signature, hardened
#               runtime, secure timestamp, no entitlements, universal binary)
#               before notarizing
#   dmg         create the disk image from the (already stapled) app and sign it
#   zip         create the zip from the (already stapled) app
#   checksums   write dist/SHA256SUMS; run this after the DMG has been stapled,
#               because stapling changes the file
#   verify      final Gatekeeper and stapler assessment of the app, the DMG and
#               the app inside the zip
#
# Environment:
#   APP_PATH         exported app bundle      (default: build/export/QuotaRing.app)
#   DIST_DIR         output directory         (default: dist)
#   KEYCHAIN_PATH    keychain that holds the Developer ID identity (dmg stage)
#   APPLE_TEAM_ID    optional; `check` verifies the signature's team identifier
#
# Nothing in here handles secrets. Never enable `set -x` regardless.

set -euo pipefail

app_name="QuotaRing"
stage="${1:-}"
version="${2:-}"
app_path="${APP_PATH:-build/export/${app_name}.app}"
dist_dir="${DIST_DIR:-dist}"

fail() {
    echo "error: $*" >&2
    exit 1
}

usage() {
    fail "usage: package.sh <check|dmg|zip|checksums|verify> <version, e.g. 0.1.0>"
}

if [[ -z "$stage" || -z "$version" ]]; then
    usage
fi
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    fail "version '${version}' must look like 0.1.0 (no leading 'v')"
fi

dmg_path="${dist_dir}/${app_name}-${version}.dmg"
zip_path="${dist_dir}/${app_name}-${version}.zip"

scratch=""
trap 'if [[ -n "$scratch" ]]; then rm -rf "$scratch"; fi' EXIT
trap 'exit 1' HUP INT TERM

require_app() {
    [[ -d "$app_path" ]] || fail "app bundle not found at ${app_path}"
}

# `stapler validate` asks Apple's ticket service (CloudKit) over the network. A connection the runner drops fails it
# with error 68 even though the ticket is stapled, which once failed a whole release after both notarization rounds.
# Try a few times before calling the artifact unstapled; a real failure still fails after the last attempt.
stapler_validate() {
    local attempt
    for attempt in 1 2 3 4; do
        if xcrun stapler validate "$1"; then
            return 0
        fi
        if ((attempt < 4)); then
            echo "stapler validate failed for $1 (attempt ${attempt} of 4); retrying in $((attempt * 15)) s" >&2
            sleep $((attempt * 15))
        fi
    done
    return 1
}

check_app() {
    require_app
    local info="${app_path}/Contents/Info.plist"

    local bundle_version
    bundle_version="$(plutil -extract CFBundleShortVersionString raw -o - "$info")"
    if [[ "$bundle_version" != "$version" ]]; then
        fail "the app reports version ${bundle_version}, expected ${version}"
    fi

    codesign --verify --deep --strict --verbose=2 "$app_path"

    local details
    details="$(codesign -dvv "$app_path" 2>&1)"
    if ! grep -Eq 'flags=0x[0-9a-f]+\([^)]*runtime' <<<"$details"; then
        fail "the Hardened Runtime is not enabled on ${app_path}"
    fi
    if ! grep -q '^Authority=Developer ID Application' <<<"$details"; then
        fail "${app_path} is not signed with a Developer ID Application certificate"
    fi
    if ! grep -q '^Timestamp=' <<<"$details"; then
        fail "the signature has no secure timestamp (OTHER_CODE_SIGN_FLAGS=--timestamp missing?)"
    fi
    if [[ -n "${APPLE_TEAM_ID:-}" ]] && ! grep -qx "TeamIdentifier=${APPLE_TEAM_ID}" <<<"$details"; then
        fail "the app is signed by a different team than APPLE_TEAM_ID"
    fi
    check_no_entitlements

    local executable archs
    executable="$(plutil -extract CFBundleExecutable raw -o - "$info")"
    archs="$(lipo -archs "${app_path}/Contents/MacOS/${executable}")"
    if [[ " ${archs} " != *" arm64 "* || " ${archs} " != *" x86_64 "* ]]; then
        fail "expected a universal binary (arm64 and x86_64), found: ${archs}"
    fi

    echo "App checks passed: version ${bundle_version}, Developer ID, Hardened Runtime, timestamp, no entitlements, ${archs}."
}

# The app is signed with no entitlements at all (App/Resources/QuotaRing.entitlements
# is an empty dictionary). Anything else, such as `get-task-allow` or a Hardened
# Runtime exception (`com.apple.security.cs.*`), fails the build before it is
# notarized. An entitlements blob that holds an empty dictionary counts as none.
check_no_entitlements() {
    local entitlements as_json
    if ! entitlements="$(codesign -d --entitlements - --xml "$app_path" 2>/dev/null)"; then
        fail "could not read the entitlements of ${app_path}"
    fi
    if [[ -z "${entitlements//[[:space:]]/}" ]]; then
        return 0
    fi
    if ! as_json="$(plutil -convert json -o - - <<<"$entitlements" 2>/dev/null)"; then
        fail "could not parse the entitlements of ${app_path}"
    fi
    if [[ "$as_json" != "{}" ]]; then
        fail "${app_path} is signed with entitlements, expected none: ${as_json}"
    fi
}

make_dmg() {
    require_app
    mkdir -p "$dist_dir"

    scratch="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/package.XXXXXX")"
    local staging="${scratch}/dmg"
    mkdir "$staging"
    ditto "$app_path" "${staging}/${app_name}.app"
    ln -s /Applications "${staging}/Applications"

    # hdiutil occasionally fails with "Resource busy" on CI runners; retry.
    local attempt=1 created=0
    while [[ "$attempt" -le 3 ]]; do
        rm -f "$dmg_path"
        if hdiutil create -volname "$app_name" -srcfolder "$staging" \
            -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov -quiet "$dmg_path"; then
            created=1
            break
        fi
        echo "hdiutil failed (attempt ${attempt}/3); retrying..." >&2
        sleep 5
        attempt=$((attempt + 1))
    done
    [[ "$created" -eq 1 ]] || fail "could not create ${dmg_path}"

    local sign_args=(--force --sign "Developer ID Application" --timestamp)
    if [[ -n "${KEYCHAIN_PATH:-}" ]]; then
        sign_args+=(--keychain "$KEYCHAIN_PATH")
    fi
    codesign "${sign_args[@]}" "$dmg_path"
    codesign --verify --verbose=2 "$dmg_path"
    echo "Created ${dmg_path}"
}

make_zip() {
    require_app
    if ! stapler_validate "$app_path" >/dev/null; then
        fail "${app_path} is not stapled; notarize and staple the app before zipping it"
    fi
    mkdir -p "$dist_dir"
    rm -f "$zip_path"
    ditto -c -k --sequesterRsrc --keepParent "$app_path" "$zip_path"
    echo "Created ${zip_path}"
}

make_checksums() {
    [[ -f "$dmg_path" ]] || fail "missing ${dmg_path}"
    [[ -f "$zip_path" ]] || fail "missing ${zip_path}"
    (
        cd "$dist_dir"
        shasum -a 256 "${app_name}-${version}.dmg" "${app_name}-${version}.zip" >SHA256SUMS
        shasum -a 256 -c SHA256SUMS
    )
}

verify_all() {
    require_app
    [[ -f "$dmg_path" ]] || fail "missing ${dmg_path}"
    [[ -f "$zip_path" ]] || fail "missing ${zip_path}"

    echo "Verifying the app..."
    codesign --verify --deep --strict --verbose=2 "$app_path"
    spctl --assess --type execute --verbose=2 "$app_path"
    stapler_validate "$app_path" || fail "${app_path} failed stapler validation"

    echo "Verifying the disk image..."
    codesign --verify --verbose=2 "$dmg_path"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg_path"
    stapler_validate "$dmg_path" || fail "${dmg_path} failed stapler validation"

    echo "Verifying the app inside the zip..."
    scratch="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/package.XXXXXX")"
    ditto -x -k "$zip_path" "$scratch"
    codesign --verify --deep --strict --verbose=2 "${scratch}/${app_name}.app"
    stapler_validate "${scratch}/${app_name}.app" || fail "the app inside ${zip_path} failed stapler validation"
    echo "All release artifacts verified."
}

case "$stage" in
check) check_app ;;
dmg) make_dmg ;;
zip) make_zip ;;
checksums) make_checksums ;;
verify) verify_all ;;
*) usage ;;
esac
