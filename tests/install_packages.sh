#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="$(mktemp -d)"

cleanup() {
    rm -rf -- "${tmp_root}"
}
trap cleanup EXIT

if bash "${ROOT_DIR}/scripts/build-install-packages.sh" >/dev/null 2>&1; then
    printf 'build-install-packages unexpectedly accepted a missing version\n' >&2
    exit 1
fi

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
    if bash "${package_root}/install.sh" --skip-dependencies \
        --prefix "${tmp_root}/missing-egress-prefix-${distro}" >/dev/null \
        2>"${tmp_root}/missing-egress.stderr"; then
        printf 'package unexpectedly accepted an implicit systemd egress policy\n' >&2
        exit 1
    fi
    grep -q '首次安装必须提供 --provider-cidr' "${tmp_root}/missing-egress.stderr"
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

    jq -e '.schema_version == 1 and .installed == true and .no_systemd == true' \
        "${prefix}/.install-state.json" >/dev/null
    missing_checksum_root="${tmp_root}/missing-checksum-${distro}"
    cp -a "${package_root}" "${missing_checksum_root}"
    rm -f -- "${missing_checksum_root}/PACKAGE-SHA256SUMS"
    if bash "${missing_checksum_root}/install.sh" --skip-dependencies --no-systemd \
        --prefix "${tmp_root}/missing-checksum-prefix-${distro}" >/dev/null \
        2>"${tmp_root}/missing-checksum.stderr"; then
        printf 'package unexpectedly accepted a missing PACKAGE-SHA256SUMS\n' >&2
        exit 1
    fi
    grep -q '缺少 PACKAGE-SHA256SUMS' "${tmp_root}/missing-checksum.stderr"
done

unmanaged_prefix="${tmp_root}/unmanaged"
mkdir -p "${unmanaged_prefix}/data"
printf 'must-survive\n' >"${unmanaged_prefix}/data/marker"
if bash "${ROOT_DIR}/scripts/install.sh" uninstall --prefix "${unmanaged_prefix}" --no-systemd --purge-data \
    >/dev/null 2>"${tmp_root}/unmanaged-uninstall.stderr"; then
    printf 'unmanaged prefix was unexpectedly accepted for uninstall\n' >&2
    exit 1
fi
grep -q '不是受管安装' "${tmp_root}/unmanaged-uninstall.stderr"
grep -qx 'must-survive' "${unmanaged_prefix}/data/marker"

bash "${ROOT_DIR}/scripts/install.sh" uninstall --prefix "${tmp_root}/prefix-debian" --no-systemd
[[ ! -e "${tmp_root}/prefix-debian/current" ]]
[[ -f "${tmp_root}/prefix-debian/data/config/config.json" ]]
jq -e '.installed == false' "${tmp_root}/prefix-debian/.install-state.json" >/dev/null
bash "${ROOT_DIR}/scripts/install.sh" uninstall --prefix "${tmp_root}/prefix-debian" --no-systemd --purge-data
[[ ! -e "${tmp_root}/prefix-debian" ]]

printf 'install_packages: ok\n'
