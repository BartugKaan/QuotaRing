#!/usr/bin/env bash
#
# Install a pinned XcodeGen release and put it on the PATH of the following
# workflow steps.
#
# `brew install xcodegen` installs whatever version Homebrew has that day and
# trusts the network path. This script instead downloads one exact release from
# the official GitHub releases, refuses to use it unless its SHA-256 matches the
# value pinned below, and only then unpacks it. The unpacked folder is the
# release layout (bin/xcodegen plus share/xcodegen/SettingPresets); keep it as
# it is, because the binary finds its setting presets relative to itself.
#
# To update: change both values below together. Take the version from
# https://github.com/yonaskolb/XcodeGen/releases and compute the hash yourself
# from the file you downloaded:
#   curl -fsSL -o xcodegen.zip \
#     https://github.com/yonaskolb/XcodeGen/releases/download/<version>/xcodegen.zip
#   shasum -a 256 xcodegen.zip
# Dependabot does not track this pin, so check for new releases from time to time.
#
# Environment:
#   RUNNER_TEMP          GitHub sets this; the install goes below it
#   XCODEGEN_INSTALL_DIR where to install when RUNNER_TEMP is not set
#                        (default: a new temporary directory)
#   GITHUB_PATH          GitHub sets this; the bin directory is appended to it
#
# Outside GitHub Actions the script prints the directory to add to PATH.

set -euo pipefail

XCODEGEN_VERSION="2.46.0"
XCODEGEN_SHA256="4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806"
XCODEGEN_URL="https://github.com/yonaskolb/XcodeGen/releases/download/${XCODEGEN_VERSION}/xcodegen.zip"

base="${RUNNER_TEMP:-${XCODEGEN_INSTALL_DIR:-}}"
if [[ -z "$base" ]]; then
    base="$(mktemp -d)"
fi
mkdir -p "$base"
# Only this fixed subdirectory is ever removed, never the directory passed in.
dest="${base}/xcodegen-${XCODEGEN_VERSION}"
rm -rf "$dest"
mkdir -p "$dest"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "Downloading XcodeGen ${XCODEGEN_VERSION} from ${XCODEGEN_URL}"
curl --fail --silent --show-error --location \
    --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 \
    --output "${work}/xcodegen.zip" "$XCODEGEN_URL"

actual="$(shasum -a 256 "${work}/xcodegen.zip" | awk '{ print $1 }')"
if [[ "$actual" != "$XCODEGEN_SHA256" ]]; then
    echo "::error::XcodeGen ${XCODEGEN_VERSION} checksum mismatch. Expected ${XCODEGEN_SHA256}, got ${actual}. Nothing was installed."
    rm -rf "$dest"
    exit 1
fi
echo "SHA-256 verified: ${actual}"

unzip -q "${work}/xcodegen.zip" -d "$dest"

bin_dir="${dest}/xcodegen/bin"
if [[ ! -x "${bin_dir}/xcodegen" ]]; then
    echo "::error::The XcodeGen archive does not contain xcodegen/bin/xcodegen."
    exit 1
fi

# Run the installed binary by its full path: it must report the pinned version.
reported="$("${bin_dir}/xcodegen" --version)"
if [[ "$reported" != *"${XCODEGEN_VERSION}"* ]]; then
    echo "::error::Expected XcodeGen ${XCODEGEN_VERSION} but the binary reports '${reported}'."
    exit 1
fi
echo "Installed XcodeGen ${XCODEGEN_VERSION} in ${bin_dir}"

if [[ -n "${GITHUB_PATH:-}" ]]; then
    echo "$bin_dir" >> "$GITHUB_PATH"
else
    echo "Add it to your PATH with: export PATH=\"${bin_dir}:\$PATH\""
fi
