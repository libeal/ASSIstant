#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-v1.1.2}"
OUTPUT_DIR="${2:-${ROOT_DIR}}"
SOURCE_EPOCH="${SOURCE_DATE_EPOCH:-0}"

[[ "${VERSION}" =~ ^v[0-9A-Za-z][0-9A-Za-z._-]*$ ]] || {
    printf 'usage: %s [v-version] [output-dir]\n' "$0" >&2
    exit 2
}
for command_name in bash jq tar gzip sha256sum stat find sort cp mktemp readlink; do
    command -v "${command_name}" >/dev/null 2>&1 || {
        printf 'missing build command: %s\n' "${command_name}" >&2
        exit 1
    }
done
[[ -d "${OUTPUT_DIR}" && ! -L "${OUTPUT_DIR}" ]] || {
    printf 'output directory must be an existing ordinary directory: %s\n' "${OUTPUT_DIR}" >&2
    exit 1
}
OUTPUT_DIR="$(readlink -f -- "${OUTPUT_DIR}")"

tmp_root="$(mktemp -d)"
cleanup() {
    rm -rf -- "${tmp_root}"
}
trap cleanup EXIT

release_dir="${tmp_root}/remote-release"
SOURCE_DATE_EPOCH="${SOURCE_EPOCH}" bash "${ROOT_DIR}/scripts/build-remote-release.sh" \
    "${VERSION}" "${release_dir}" >/dev/null

copy_manifest_asset() {
    local manifest="$1"
    local selector="$2"
    local destination="$3"
    local name
    name="$(jq -er "${selector}.name" "${manifest}")"
    [[ "${name}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]+$ ]] || {
        printf 'invalid release asset name: %s\n' "${name}" >&2
        exit 1
    }
    [[ -f "${release_dir}/${name}" && ! -L "${release_dir}/${name}" ]] || {
        printf 'release asset is missing: %s\n' "${name}" >&2
        exit 1
    }
    cp -a -- "${release_dir}/${name}" "${destination}/${name}"
}

assert_not_ignored_or_private_path() {
    local path="${1%/}"
    case "${path}" in
        README.md | .gitignore | config/config.json | config/*.secret | logs | logs/* | tmp | tmp/* | \
            __pycache__ | __pycache__/* | *.pyc | AGENTS.md | dist | dist/* | docs | docs/* | \
            CLAUDE.md | .claude | .codex | .agents)
            printf 'forbidden source path entered package: %s\n' "${path}" >&2
            exit 1
            ;;
    esac
}

assert_archive_clean() {
    local archive="$1"
    local listing member
    listing="$(tar -tzf "${archive}")" || {
        printf 'cannot inspect package archive: %s\n' "${archive}" >&2
        exit 1
    }
    while IFS= read -r member; do
        [[ -n "${member}" ]] || continue
        assert_not_ignored_or_private_path "${member}"
    done <<<"${listing}"
}

for distro in debian fedora; do
    package_name="linux-agent-${VERSION}-${distro}"
    stage_root="${tmp_root}/${package_name}"
    mkdir -p "${stage_root}/release" "${stage_root}/requirements"
    manifest="${release_dir}/release-manifest.json"

    # A local package only needs assets consumed by install.sh. Keep the
    # package manifest truthful instead of carrying remote-only assets.
    jq -S '{schema_version, version, repository, assets:{core:.assets.core, web:.assets.web, installer:.assets.installer}, skills}' \
        "${manifest}" >"${stage_root}/release/release-manifest.json"
    copy_manifest_asset "${manifest}" '.assets.core' "${stage_root}/release"
    copy_manifest_asset "${manifest}" '.assets.web' "${stage_root}/release"
    copy_manifest_asset "${manifest}" '.assets.installer' "${stage_root}/release"
    while IFS= read -r skill_name; do
        copy_manifest_asset "${manifest}" ".skills[\"${skill_name}\"].asset" "${stage_root}/release"
    done < <(jq -r '.skills | keys[]' "${manifest}")

    cp -a -- "${ROOT_DIR}/packaging/install-package.sh" "${stage_root}/install.sh"
    cp -a -- "${ROOT_DIR}/packaging/INSTALL_PACKAGE.md" "${stage_root}/INSTALL.md"
    cp -a -- "${ROOT_DIR}/requirements/${distro}.txt" "${stage_root}/requirements/${distro}.txt"
    cp -a -- "${ROOT_DIR}/requirements/${distro}-optional.txt" "${stage_root}/requirements/${distro}-optional.txt"
    chmod 0755 "${stage_root}/install.sh" "${stage_root}/release/linux-agent-install.sh"

    while IFS= read -r path; do
        assert_not_ignored_or_private_path "${path}"
    done < <(cd "${stage_root}" && find . -mindepth 1 -printf '%P\n')
    while IFS= read -r archive; do
        assert_archive_clean "${archive}"
    done < <(find "${stage_root}/release" -maxdepth 1 -type f -name '*.tar.gz' -print)

    (
        cd "${stage_root}"
        file_list=".package-file-list"
        find . -type f ! -name PACKAGE-SHA256SUMS ! -name "${file_list}" \
            -printf '%P\n' | LC_ALL=C sort >"${file_list}"
        : >PACKAGE-SHA256SUMS
        while IFS= read -r file; do
            sha256sum -- "${file}" >>PACKAGE-SHA256SUMS
        done <"${file_list}"
        rm -f -- "${file_list}"
    )

    output_path="${OUTPUT_DIR}/${package_name}.tar.gz"
    archive_tmp="${tmp_root}/${package_name}.tar.gz"
    tar --sort=name --mtime="@${SOURCE_EPOCH}" --owner=0 --group=0 --numeric-owner \
        --format=gnu -C "${tmp_root}" -cf - "${package_name}" | gzip -n >"${archive_tmp}"
    mv -f -- "${archive_tmp}" "${output_path}"
    (
        cd "${OUTPUT_DIR}"
        sha256sum -- "${package_name}.tar.gz" >"${package_name}.tar.gz.sha256"
    )
    printf 'built: %s (%s bytes)\n' "${output_path}" "$(stat -c '%s' "${output_path}")"
done
