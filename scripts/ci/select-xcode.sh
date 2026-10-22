#!/usr/bin/env bash
#
# Select an Xcode installed on a GitHub macOS runner, then print the toolchain
# versions that the job will use. By default that is the newest stable Xcode (at
# least MIN_XCODE). With XCODE_VERSION set it is exactly that version, and the
# script fails when it is not installed (used to test the minimum Xcode that the
# README promises).
#
# GitHub's macOS images keep several versions side by side as
# /Applications/Xcode_<version>.app. Pre-release names such as
# Xcode_26_beta.app or Xcode_16.4_Release_Candidate.app are ignored. If no
# installed Xcode is new enough, a warning is emitted and the runner default
# is kept so the job can still run (and fail on its own terms).
#
# Environment:
#   XCODE_VERSION     exact version to select, for example 16.4. Fails if
#                     Xcode_<version>.app is not installed. MIN_XCODE is ignored.
#   MIN_XCODE         minimum acceptable version        (default: 16.4)
#   XCODE_SEARCH_DIR  directory holding Xcode_*.app     (default: /Applications)
#   DRY_RUN=1         print the chosen Xcode.app and exit; do not call sudo

set -euo pipefail

min_version="${MIN_XCODE:-16.4}"
search_dir="${XCODE_SEARCH_DIR:-/Applications}"
exact_version="${XCODE_VERSION:-}"

# version_ge A B: succeeds when dotted numeric version A >= B.
version_ge() {
    local IFS=.
    # Splitting on dots is intended here.
    # shellcheck disable=SC2206
    local -a a=($1)
    # shellcheck disable=SC2206
    local -a b=($2)
    local n=${#a[@]}
    local i x y
    if ((${#b[@]} > n)); then n=${#b[@]}; fi
    for ((i = 0; i < n; i++)); do
        x=${a[i]:-0}
        y=${b[i]:-0}
        if ((10#$x > 10#$y)); then return 0; fi
        if ((10#$x < 10#$y)); then return 1; fi
    done
    return 0
}

best_app=""
best_version=""
if [[ -n "$exact_version" ]]; then
    if [[ ! "$exact_version" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
        echo "::error::XCODE_VERSION '${exact_version}' must look like 16.4."
        exit 1
    fi
    if [[ ! -d "${search_dir}/Xcode_${exact_version}.app" ]]; then
        echo "::error::Xcode ${exact_version} is required but ${search_dir}/Xcode_${exact_version}.app is not installed on this runner."
        echo "Installed: $(cd "$search_dir" 2>/dev/null && ls -d Xcode*.app 2>/dev/null | tr '\n' ' ')"
        exit 1
    fi
    best_app="${search_dir}/Xcode_${exact_version}.app"
    best_version="$exact_version"
else
    for app in "$search_dir"/Xcode_*.app; do
        [[ -d "$app" ]] || continue
        name="${app##*/}"
        version="${name#Xcode_}"
        version="${version%.app}"
        [[ "$version" =~ ^[0-9]+(\.[0-9]+)*$ ]] || continue
        version_ge "$version" "$min_version" || continue
        if [[ -z "$best_version" ]] || ! version_ge "$best_version" "$version"; then
            best_app="$app"
            best_version="$version"
        fi
    done
fi

if [[ -z "$best_app" ]]; then
    echo "::warning::No stable Xcode >= ${min_version} found in ${search_dir}; keeping the runner default."
elif [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "$best_app"
    exit 0
else
    echo "Selecting ${best_app} (version ${best_version})"
    sudo xcode-select -s "${best_app}/Contents/Developer"
fi

if [[ "${DRY_RUN:-0}" == "1" ]]; then
    exit 0
fi

xcodebuild -version
swift --version

# An exact selection must really be in effect, not just requested.
if [[ -n "$exact_version" ]]; then
    reported="$(xcodebuild -version | head -n 1)"
    if [[ "$reported" != "Xcode ${exact_version}" ]]; then
        echo "::error::Expected 'Xcode ${exact_version}' but xcodebuild reports '${reported}'."
        exit 1
    fi
fi
