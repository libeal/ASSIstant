#!/usr/bin/env bash

set -euo pipefail

PACKAGE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_DIR="${PACKAGE_ROOT}/release"
REQUIREMENTS_DIR="${PACKAGE_ROOT}/requirements"

fail() {
    printf '[package-install:error] %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
用法:
  sudo bash install.sh [选项] [安装器选项]

包选项:
  --skip-dependencies      跳过 yum/apt-get 依赖安装（用于已准备好的系统）
  --with-optional-tools    同时安装该发行版的可选 Skill 工具
  -h, --help               显示帮助

其余选项传给 linux-agent-install.sh，例如:
  --no-systemd
  --prefix /opt/linux-agent
  --provider-cidr 203.0.113.0/24
EOF
}

[[ -d "${PACKAGE_ROOT}" && ! -L "${PACKAGE_ROOT}" ]] || fail '安装包目录必须是普通目录'
[[ -d "${RELEASE_DIR}" && ! -L "${RELEASE_DIR}" ]] || fail '安装包缺少 release 目录'
[[ -f "${RELEASE_DIR}/release-manifest.json" && ! -L "${RELEASE_DIR}/release-manifest.json" ]] ||
    fail '安装包缺少 release-manifest.json'
[[ -x "${RELEASE_DIR}/linux-agent-install.sh" ]] || fail '安装包缺少可执行 linux-agent-install.sh'

skip_dependencies=0
optional_tools=0
declare -a installer_args=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-dependencies)
            skip_dependencies=1
            shift
            ;;
        --with-optional-tools)
            optional_tools=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        --)
            shift
            installer_args+=("$@")
            break
            ;;
        *)
            installer_args+=("$1")
            shift
            ;;
    esac
done

package_checksum_file="${PACKAGE_ROOT}/PACKAGE-SHA256SUMS"
if [[ -f "${package_checksum_file}" ]]; then
    command -v sha256sum >/dev/null 2>&1 || fail '缺少 sha256sum，无法校验安装包内容'
    (cd "${PACKAGE_ROOT}" && sha256sum -c --strict "${package_checksum_file}") ||
        fail '安装包内容校验失败，请重新解压可信归档'
fi

read_requirements() {
    local requirements_file="$1"
    local output_var="$2"
    local -n output_ref="${output_var}"
    local -a parsed_packages=()
    local line package extra
    [[ -f "${requirements_file}" && ! -L "${requirements_file}" ]] ||
        fail "缺少依赖清单: ${requirements_file}"
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -n "${line}" ]] || continue
        read -r package extra <<<"${line}"
        [[ -n "${package}" && -z "${extra:-}" && "${package}" =~ ^[A-Za-z0-9][A-Za-z0-9+_.:-]*$ ]] ||
            fail "依赖清单包含非法行: ${line}"
        parsed_packages+=("${package}")
    done <"${requirements_file}"
    [[ "${#parsed_packages[@]}" -gt 0 ]] || fail "依赖清单为空: ${requirements_file}"
    # shellcheck disable=SC2034 # nameref assignment updates the caller's array.
    output_ref=("${parsed_packages[@]}")
}

install_packages() {
    local package_manager="$1"
    shift
    local -a packages=("$@")
    local -a runner=()
    command -v "${package_manager}" >/dev/null 2>&1 ||
        fail "当前系统缺少 ${package_manager}；请手动安装清单中的依赖，或使用 --skip-dependencies"
    if [[ "${EUID}" -ne 0 ]]; then
        command -v sudo >/dev/null 2>&1 || fail "运行 ${package_manager} 需要 root 或 sudo"
        runner=(sudo)
    fi
    case "${package_manager}" in
        apt-get)
            "${runner[@]}" apt-get update
            "${runner[@]}" apt-get install -y --no-install-recommends "${packages[@]}"
            ;;
        yum)
            "${runner[@]}" yum install -y "${packages[@]}"
            ;;
        *)
            fail "不支持的包管理器: ${package_manager}"
            ;;
    esac
}

if [[ "${skip_dependencies}" -eq 0 ]]; then
    declare -a required_packages=()
    declare -a optional_packages=()
    if [[ -f "${REQUIREMENTS_DIR}/debian.txt" ]]; then
        package_manager=apt-get
        requirement_prefix=debian
    elif [[ -f "${REQUIREMENTS_DIR}/fedora.txt" ]]; then
        package_manager=yum
        requirement_prefix=fedora
    else
        fail '安装包缺少发行版依赖清单'
    fi
    read_requirements "${REQUIREMENTS_DIR}/${requirement_prefix}.txt" required_packages
    install_packages "${package_manager}" "${required_packages[@]}"
    if [[ "${optional_tools}" -eq 1 ]]; then
        read_requirements "${REQUIREMENTS_DIR}/${requirement_prefix}-optional.txt" optional_packages
        install_packages "${package_manager}" "${optional_packages[@]}"
    fi
fi

command -v jq >/dev/null 2>&1 || fail '缺少 jq；请先安装依赖或使用正确的发行版安装包'
version="$(jq -er '.version | select(type == "string" and test("^v[0-9A-Za-z][0-9A-Za-z._-]*$"))' \
    "${RELEASE_DIR}/release-manifest.json")" || fail 'release manifest 版本无效'

exec bash "${RELEASE_DIR}/linux-agent-install.sh" install \
    --version "${version}" --from-dist "${RELEASE_DIR}" "${installer_args[@]}"
