#!/usr/bin/env bash

set -euo pipefail

RELEASE_TAG="${1:-}"
DIST_DIR="${2:-}"
MANIFEST_NAME="release-manifest.json"
BUNDLE_NAME="release-manifest.json.sigstore.json"

fail() {
    printf 'release signature preparation failed: %s\n' "$*" >&2
    exit 1
}

if [[ ! "${RELEASE_TAG}" =~ ^v[0-9A-Za-z][0-9A-Za-z._-]*$ || -z "${DIST_DIR}" ]]; then
    printf 'usage: %s <v-version> <dist-dir>\n' "$0" >&2
    exit 2
fi

if [[ "${GITHUB_ACTIONS:-false}" == "true" && "${GITHUB_REF:-}" != "refs/tags/${RELEASE_TAG}" ]]; then
    fail "GitHub Actions signing must run from refs/tags/${RELEASE_TAG}, got ${GITHUB_REF:-missing}"
fi

for command_name in gh cosign cmp cp chmod mktemp rm; do
    command -v "${command_name}" >/dev/null 2>&1 || fail "missing command: ${command_name}"
done

[[ -d "${DIST_DIR}" && ! -L "${DIST_DIR}" ]] || fail "distribution directory is invalid: ${DIST_DIR}"
manifest_path="${DIST_DIR}/${MANIFEST_NAME}"
bundle_path="${DIST_DIR}/${BUNDLE_NAME}"
[[ -f "${manifest_path}" && ! -L "${manifest_path}" ]] || fail "release manifest is missing or unsafe"
[[ ! -L "${bundle_path}" ]] || fail "release signature bundle path is a symlink"

identity="${LINUX_AGENT_SIGNATURE_IDENTITY:-^https://github.com/libeal/ASSIstant/\.github/workflows/remote-release\.yml@refs/tags/v.*$}"
issuer="${LINUX_AGENT_SIGNATURE_ISSUER:-https://token.actions.githubusercontent.com}"
work_dir="$(mktemp -d)"
cleanup() {
    rm -rf -- "${work_dir}"
}
trap cleanup EXIT

release_exists=0
manifest_published=0
bundle_published=0
if gh release view "${RELEASE_TAG}" >/dev/null 2>&1; then
    release_exists=1
    while IFS= read -r asset_name; do
        case "${asset_name}" in
            "${MANIFEST_NAME}") manifest_published=1 ;;
            "${BUNDLE_NAME}") bundle_published=1 ;;
        esac
    done < <(gh release view "${RELEASE_TAG}" --json assets --jq '.assets[].name')
fi

if [[ "${release_exists}" -eq 1 && "${bundle_published}" -eq 1 ]]; then
    [[ "${manifest_published}" -eq 1 ]] || fail "published signature bundle has no matching manifest"
    gh release download "${RELEASE_TAG}" --pattern "${MANIFEST_NAME}" --dir "${work_dir}"
    gh release download "${RELEASE_TAG}" --pattern "${BUNDLE_NAME}" --dir "${work_dir}"
    [[ -f "${work_dir}/${MANIFEST_NAME}" && -f "${work_dir}/${BUNDLE_NAME}" ]] ||
        fail "published signature assets could not be downloaded"
    cmp -s -- "${manifest_path}" "${work_dir}/${MANIFEST_NAME}" ||
        fail "published manifest differs from this deterministic build"
    cosign verify-blob \
        --bundle "${work_dir}/${BUNDLE_NAME}" \
        --certificate-oidc-issuer "${issuer}" \
        --certificate-identity-regexp "${identity}" \
        "${work_dir}/${MANIFEST_NAME}" >/dev/null ||
        fail "published release manifest signature is invalid"
    cp -- "${work_dir}/${BUNDLE_NAME}" "${bundle_path}"
    chmod 0644 "${bundle_path}"
    printf 'reused and verified published release signature: %s\n' "${RELEASE_TAG}"
    exit 0
fi

rm -f -- "${bundle_path}"
cosign sign-blob --yes --bundle "${bundle_path}" "${manifest_path}"
[[ -f "${bundle_path}" && ! -L "${bundle_path}" ]] || fail "cosign did not create a regular signature bundle"
chmod 0644 "${bundle_path}"
printf 'created release signature: %s\n' "${RELEASE_TAG}"
