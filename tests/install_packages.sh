#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="$(mktemp -d)"

cleanup() {
    rm -rf -- "${tmp_root}"
}
trap cleanup EXIT

mkdir -p "${tmp_root}/first" "${tmp_root}/second"
SOURCE_DATE_EPOCH=0 bash "${ROOT_DIR}/scripts/build-install-packages.sh" \
    v0.0.0-test "${tmp_root}/first" >/dev/null
SOURCE_DATE_EPOCH=0 bash "${ROOT_DIR}/scripts/build-install-packages.sh" \
    v0.0.0-test "${tmp_root}/second" >/dev/null

for distro in debian fedora; do
    archive="linux-agent-v0.0.0-test-${distro}.tar.gz"
    cmp "${tmp_root}/first/${archive}" "${tmp_root}/second/${archive}"
    (
        cd "${tmp_root}/first"
        ! grep -q '/' "${archive}.sha256"
        sha256sum -c "${archive}.sha256" >/dev/null
    )

    extract_dir="${tmp_root}/extract-${distro}"
    package_root="${extract_dir}/linux-agent-v0.0.0-test-${distro}"
    mkdir -p "${extract_dir}"
    tar -xzf "${tmp_root}/first/${archive}" -C "${extract_dir}"
    (
        cd "${package_root}"
        sha256sum -c --strict PACKAGE-SHA256SUMS >/dev/null
    )

    forbidden='(^|/)(tests|logs|tmp|__pycache__|node_modules|\.git)(/|$)|\.pyc$'
    ! find "${package_root}" -type f -printf '%P\n' | grep -Eq "${forbidden}"
    ! find "${package_root}" -type f -printf '%P\n' |
        grep -Eq '(^|/)(README\.md|\.gitignore|config/config\.json|AGENTS\.md|CLAUDE\.md)$'
    ! find "${package_root}" -type f -path '*/config/*.secret' -print -quit |
        grep -q .
    [[ -f "${package_root}/requirements/${distro}.txt" ]]
    [[ -f "${package_root}/requirements/${distro}-optional.txt" ]]
    case "${distro}" in
        debian) [[ ! -e "${package_root}/requirements/fedora.txt" ]] ;;
        fedora)
            [[ ! -e "${package_root}/requirements/debian.txt" ]]
            grep -qx 'procps-ng' "${package_root}/requirements/fedora.txt"
            grep -q 'yum install -y' "${package_root}/INSTALL.md"
            ;;
    esac

    manifest_assets="$(jq -r '[.assets[].name, .skills[].asset.name] | sort | .[]' \
        "${package_root}/release/release-manifest.json")"
    packaged_assets="$(find "${package_root}/release" -maxdepth 1 -type f \
        ! -name release-manifest.json -printf '%f\n' | LC_ALL=C sort)"
    [[ "${manifest_assets}" == "${packaged_assets}" ]]
    while IFS= read -r inner_archive; do
        ! tar -tzf "${inner_archive}" |
            grep -Eq '^(README\.md|\.gitignore|config/config\.json|config/[^/]+\.secret|AGENTS\.md|CLAUDE\.md|\.claude|\.codex|\.agents)(/|$)'
    done < <(find "${package_root}/release" -type f -name '*.tar.gz')

    prefix="${tmp_root}/prefix-${distro}"
    bash "${package_root}/install.sh" --skip-dependencies --no-systemd --prefix "${prefix}" >/dev/null
    bash "${prefix}/current/bin/agent" api health |
        jq -e '.ok == true and .version == "v0.0.0-test"' >/dev/null
done

printf 'install_packages: ok\n'
