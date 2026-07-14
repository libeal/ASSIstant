#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_TAG="${1:-}"
DIST_DIR="${2:-${ROOT_DIR}/dist/remote}"

fail() {
    printf 'remote release publish failed: %s\n' "$*" >&2
    exit 1
}

if [[ ! "${RELEASE_TAG}" =~ ^v[0-9A-Za-z][0-9A-Za-z._-]*$ ]]; then
    printf 'usage: %s <v-version> [dist-dir]\n' "$0" >&2
    exit 2
fi

for command_name in gh sha256sum cmp mktemp find sort basename awk; do
    command -v "${command_name}" >/dev/null 2>&1 || fail "missing command: ${command_name}"
done

[[ -d "${DIST_DIR}" ]] || fail "distribution directory does not exist: ${DIST_DIR}"

asset_paths=()
while IFS= read -r asset_path; do
    asset_paths+=("${asset_path}")
done < <(find "${DIST_DIR}" -mindepth 1 -maxdepth 1 -type f -printf '%p\n' | sort)

[[ ${#asset_paths[@]} -gt 0 ]] || fail "distribution directory is empty: ${DIST_DIR}"

expected_assets=()
declare -A expected_paths=()
for asset_path in "${asset_paths[@]}"; do
    asset_name="$(basename "${asset_path}")"
    [[ "${asset_name}" != *$'\n'* ]] || fail "asset name contains a newline: ${asset_name@Q}"
    expected_assets+=("${asset_name}")
    expected_paths["${asset_name}"]="${asset_path}"
done

verify_dir="$(mktemp -d)"
cleanup() {
    rm -rf -- "${verify_dir}"
}
trap cleanup EXIT

release_exists=0
is_draft=false
is_prerelease=false
if gh release view "${RELEASE_TAG}" >/dev/null 2>&1; then
    release_exists=1
else
    printf 'release %s does not exist; creating it\n' "${RELEASE_TAG}"
    gh release create "${RELEASE_TAG}" "${asset_paths[@]}" \
        --verify-tag --generate-notes --latest
fi

if [[ "${release_exists}" == "1" ]]; then
    read -r is_draft is_prerelease < <(
        gh release view "${RELEASE_TAG}" \
            --json isDraft,isPrerelease \
            --jq '[.isDraft, .isPrerelease] | @tsv'
    )
    [[ "${is_prerelease}" == "false" ]] || \
        fail "release ${RELEASE_TAG} is marked as a prerelease"

    declare -A published_assets=()
    while IFS= read -r asset_name; do
        [[ -n "${asset_name}" ]] || continue
        published_assets["${asset_name}"]=1
        [[ -n "${expected_paths[${asset_name}]+present}" ]] || \
            fail "release ${RELEASE_TAG} contains unexpected asset: ${asset_name}"
    done < <(
        gh release view "${RELEASE_TAG}" --json assets --jq '.assets[].name' | sort
    )

    missing_paths=()
    for asset_name in "${expected_assets[@]}"; do
        if [[ -z "${published_assets[${asset_name}]+present}" ]]; then
            missing_paths+=("${expected_paths[${asset_name}]}")
        fi
    done
    if [[ ${#missing_paths[@]} -gt 0 ]]; then
        printf 'uploading %d missing asset(s) to release %s\n' \
            "${#missing_paths[@]}" "${RELEASE_TAG}"
        gh release upload "${RELEASE_TAG}" "${missing_paths[@]}"
    fi
fi

for asset_path in "${asset_paths[@]}"; do
    asset_name="$(basename "${asset_path}")"
    rm -f -- "${verify_dir}/${asset_name}"
    gh release download "${RELEASE_TAG}" \
        --pattern "${asset_name}" \
        --dir "${verify_dir}" \
        --clobber >/dev/null
    [[ -f "${verify_dir}/${asset_name}" ]] || \
        fail "release asset download produced no file: ${asset_name}"
    if ! cmp -s -- "${asset_path}" "${verify_dir}/${asset_name}"; then
        expected_sha="$(sha256sum "${asset_path}" | awk '{print $1}')"
        actual_sha="$(sha256sum "${verify_dir}/${asset_name}" | awk '{print $1}')"
        fail "release asset differs from this build: ${asset_name} (expected ${expected_sha}, got ${actual_sha})"
    fi
done

if [[ "${release_exists}" == "1" && "${is_draft}" == "true" ]]; then
    gh release edit "${RELEASE_TAG}" --draft=false --latest
fi

printf 'remote release published and verified: %s\n' "${RELEASE_TAG}"
