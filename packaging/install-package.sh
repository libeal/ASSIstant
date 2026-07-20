#!/usr/bin/env bash

set -euo pipefail

PACKAGE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_DIR="${PACKAGE_ROOT}/release"
REQUIREMENTS_DIR="${PACKAGE_ROOT}/requirements"

fail() {
    printf '[package-install:error] %s\n' "$*" >&2
    exit 1
}

info() {
    printf '[package-install] %s\n' "$*" >&2
}

if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3))); then
    fail "Bash 版本过低: ${BASH_VERSION}；需要 Bash 4.3+"
fi

usage() {
    cat <<'EOF'
用法:
  sudo bash install.sh --provider-cidr <CIDR> [选项]

包选项:
  --skip-dependencies      跳过 dnf/yum/apt-get 依赖安装（用于已准备好的系统）
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
[[ -f "${RELEASE_DIR}/linux-agent-install.sh" && ! -L "${RELEASE_DIR}/linux-agent-install.sh" &&
    -x "${RELEASE_DIR}/linux-agent-install.sh" ]] || fail '安装包缺少可执行 linux-agent-install.sh'

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
[[ -f "${package_checksum_file}" && ! -L "${package_checksum_file}" ]] ||
    fail '安装包缺少 PACKAGE-SHA256SUMS，拒绝执行未完整校验的内容'
command -v sha256sum >/dev/null 2>&1 || fail '缺少 sha256sum，无法校验安装包内容'
(cd "${PACKAGE_ROOT}" && sha256sum -c --strict "${package_checksum_file}") ||
    fail '安装包内容校验失败，请重新解压可信归档'

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
        dnf | yum)
            "${runner[@]}" "${package_manager}" install -y "${packages[@]}"
            ;;
        *)
            fail "不支持的包管理器: ${package_manager}"
            ;;
    esac
}

read_os_release_field() {
    local field="$1" line value=""
    # Fedora/RPM systems commonly expose /etc/os-release as a symlink to
    # /usr/lib/os-release. -f follows the link while still rejecting devices.
    [[ -f "${OS_RELEASE_PATH}" ]] || return 1
    line="$(sed -n "s/^${field}=//p" "${OS_RELEASE_PATH}" | head -n 1)"
    [[ -n "${line}" ]] || return 1
    value="${line}"
    if [[ "${value}" == \"*\" && "${value}" == *\" ]]; then
        value="${value:1:${#value}-2}"
    elif [[ "${value}" == \'*\' && "${value}" == *\' ]]; then
        value="${value:1:${#value}-2}"
    fi
    [[ "${value}" =~ ^[A-Za-z0-9._[:space:]-]+$ ]] || return 1
    printf '%s\n' "${value}"
}

detect_host_family() {
    local os_id os_like identity
    os_id="$(read_os_release_field ID 2>/dev/null || true)"
    os_like="$(read_os_release_field ID_LIKE 2>/dev/null || true)"
    identity="$(printf '%s %s' "${os_id}" "${os_like}" | tr '[:upper:]' '[:lower:]')"
    [[ -n "${identity//[[:space:]]/}" ]] || return 1
    if [[ "${identity}" == *kylin* ]]; then
        printf 'rpm\n'
    elif [[ " ${identity} " == *" debian "* || " ${identity} " == *" ubuntu "* ]]; then
        printf 'debian\n'
    elif [[ " ${identity} " == *" fedora "* || " ${identity} " == *" rhel "* ||
        " ${identity} " == *" centos "* || " ${identity} " == *" rocky "* ||
        " ${identity} " == *" almalinux "* || " ${identity} " == *" openeuler "* ||
        " ${identity} " == *" anolis "* ]]; then
        printf 'rpm\n'
    else
        printf 'unknown\n'
    fi
}

select_rpm_manager() {
    if command -v dnf >/dev/null 2>&1; then
        printf 'dnf\n'
    elif command -v yum >/dev/null 2>&1; then
        printf 'yum\n'
    else
        return 1
    fi
}

has_no_systemd=0
has_egress_policy=0
for installer_arg in "${installer_args[@]}"; do
    case "${installer_arg}" in
        --no-systemd) has_no_systemd=1 ;;
        --provider-cidr | --allow-unrestricted-provider-egress) has_egress_policy=1 ;;
    esac
done
if [[ "${has_no_systemd}" -eq 0 && "${has_egress_policy}" -eq 0 ]]; then
    fail 'systemd 首次安装必须提供 --provider-cidr，或显式使用 --allow-unrestricted-provider-egress'
fi

OS_RELEASE_PATH="${LINUX_AGENT_OS_RELEASE_PATH:-/etc/os-release}"
if [[ -f "${REQUIREMENTS_DIR}/debian.txt" ]]; then
    requirement_prefix=debian
elif [[ -f "${REQUIREMENTS_DIR}/fedora.txt" ]]; then
    requirement_prefix=fedora
else
    fail '安装包缺少发行版依赖清单'
fi

if [[ "${skip_dependencies}" -eq 0 ]]; then
    declare -a required_packages=()
    declare -a optional_packages=()
    host_family="$(detect_host_family)" ||
        fail "无法从 ${OS_RELEASE_PATH} 识别主机发行版"
    case "${requirement_prefix}:${host_family}" in
        debian:debian) package_manager=apt-get ;;
        fedora:rpm) package_manager="$(select_rpm_manager)" || fail '当前 RPM 系统缺少 dnf/yum' ;;
        *)
            fail "安装包与主机不匹配: package=${requirement_prefix}, host=${host_family}；请使用正确发行版安装包"
            ;;
    esac
    info "已识别 package=${requirement_prefix}, host=${host_family}, manager=${package_manager}"
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
