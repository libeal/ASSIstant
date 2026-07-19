#!/usr/bin/env bash

set -euo pipefail

REPOSITORY="libeal/ASSIstant"
COMMAND="${1:-}"
[[ $# -gt 0 ]] && shift

VERSION=""
PREFIX="/opt/linux-agent"
FROM_DIST=""
SERVICE_USER="linux-agent"
SERVICE_GROUP="linux-agent"
SERVICE_USER_EXPLICIT=0
SERVICE_USER_CREATED=0
SERVICE_USER_CREATED_THIS_RUN=0
REQUIRE_SIGNATURE=0
NO_SYSTEMD=0
KEEP=2
PURGE_DATA=0
EGRESS_MODE="preserve"
declare -a PROVIDER_CIDRS=()
WORK_DIR=""
PREPARED_RELEASE_DIR=""
SYSTEMD_UNIT_PATH="${LINUX_AGENT_SYSTEMD_UNIT_PATH:-/etc/systemd/system/linux-agent-web.service}"
SYSTEMD_UNIT_DIR="${SYSTEMD_UNIT_PATH%/*}"
SYSTEMD_HELPER_SERVICE_PATH="${LINUX_AGENT_SYSTEMD_HELPER_SERVICE_PATH:-${SYSTEMD_UNIT_DIR}/linux-agent-observer-helper.service}"
SYSTEMD_HELPER_SOCKET_PATH="${LINUX_AGENT_SYSTEMD_HELPER_SOCKET_PATH:-${SYSTEMD_UNIT_DIR}/linux-agent-observer-helper.socket}"
SYSTEMD_EGRESS_DROPIN_PATH="${LINUX_AGENT_SYSTEMD_EGRESS_DROPIN_PATH:-${SYSTEMD_UNIT_DIR}/linux-agent-web.service.d/10-provider-egress.conf}"
TRANSACTION_MODE=""
TRANSACTION_OLD_VERSION=""
TRANSACTION_TARGET_VERSION=""
TRANSACTION_BACKUP_DIR=""
TRANSACTION_COMMITTED=0
CONFIG_STATE_CAPTURED=0
SYSTEMD_STATE_CAPTURED=0
SYSTEMD_UNIT_EXISTED=0
SYSTEMD_HELPER_SERVICE_EXISTED=0
SYSTEMD_HELPER_SOCKET_EXISTED=0
SYSTEMD_EGRESS_DROPIN_EXISTED=0
SYSTEMD_WAS_ENABLED=0
SYSTEMD_WAS_ACTIVE=0
SYSTEMD_HELPER_SOCKET_WAS_ENABLED=0
SYSTEMD_HELPER_SOCKET_WAS_ACTIVE=0
INSTALL_STATE_CAPTURED=0
INSTALL_STATE_EXISTED=0
INSTALL_STATE_SERVICE_USER=""
INSTALL_STATE_SERVICE_USER_CREATED=0
INSTALL_STATE_NO_SYSTEMD=0

fail() {
    printf '[install:error] %s\n' "$*" >&2
    exit 1
}

warn() {
    printf '[install:warn] %s\n' "$*" >&2
}

info() {
    printf '[install] %s\n' "$*" >&2
}

usage() {
    cat <<'EOF'
用法:
  linux-agent-install.sh install --version vX.Y.Z [选项]
  linux-agent-install.sh upgrade --version vX.Y.Z [选项]
  linux-agent-install.sh rollback [选项]
  linux-agent-install.sh health [--prefix <目录>]
  linux-agent-install.sh status [选项]
  linux-agent-install.sh uninstall [--purge-data] [选项]

选项:
  --from-dist <目录>       从本地发布物目录安装，不访问网络
  --prefix <目录>          安装前缀，默认 /opt/linux-agent
  --service-user <用户>    systemd 服务用户，默认 linux-agent
  --require-signature      强制使用 cosign 验证 release manifest
  --keep <数量>            升级成功后保留的版本总数，默认 2
  --no-systemd             不创建用户、不安装或操作 systemd unit
  --provider-cidr <CIDR>   systemd 仅放行该 Provider 网段；可重复指定
  --allow-unrestricted-provider-egress
                           明确不启用 systemd Provider 出站过滤
  --purge-data             uninstall 时同时删除持久数据

签名验证可通过 LINUX_AGENT_SIGNATURE_PUBKEY、LINUX_AGENT_SIGNATURE_IDENTITY
和 LINUX_AGENT_SIGNATURE_ISSUER 配置。生产环境必须显式固定 --version。
systemd 模式的 --prefix 不能位于 /home、/root、/run/user、/tmp 或 /var/tmp；
这些目录会被 unit 的 ProtectHome/PrivateTmp 沙箱隐藏。
EOF
}

cleanup() {
    local exit_status=$?
    set +e
    if [[ "${exit_status}" -ne 0 && -n "${TRANSACTION_MODE}" && "${TRANSACTION_COMMITTED}" -eq 0 ]] &&
        declare -F rollback_transaction >/dev/null 2>&1; then
        rollback_transaction
    fi
    if [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" ]]; then
        case "${WORK_DIR}" in
            "${PREFIX}"/.install-staging.*) rm -rf -- "${WORK_DIR}" ;;
            *) warn "拒绝清理非预期 staging 目录: ${WORK_DIR}" ;;
        esac
    fi
    if [[ -n "${TRANSACTION_BACKUP_DIR}" && -d "${TRANSACTION_BACKUP_DIR}" ]]; then
        case "${TRANSACTION_BACKUP_DIR}" in
            "${PREFIX}"/.install-rollback.*) rm -rf -- "${TRANSACTION_BACKUP_DIR}" ;;
            *) warn "拒绝清理非预期 rollback 目录: ${TRANSACTION_BACKUP_DIR}" ;;
        esac
    fi
    return "${exit_status}"
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            [[ $# -ge 2 ]] || fail '--version 缺少参数'
            VERSION="$2"
            shift 2
            ;;
        --from-dist)
            [[ $# -ge 2 ]] || fail '--from-dist 缺少参数'
            FROM_DIST="$2"
            shift 2
            ;;
        --prefix)
            [[ $# -ge 2 ]] || fail '--prefix 缺少参数'
            PREFIX="$2"
            shift 2
            ;;
        --service-user)
            [[ $# -ge 2 ]] || fail '--service-user 缺少参数'
            SERVICE_USER="$2"
            SERVICE_USER_EXPLICIT=1
            shift 2
            ;;
        --keep)
            [[ $# -ge 2 ]] || fail '--keep 缺少参数'
            KEEP="$2"
            shift 2
            ;;
        --require-signature)
            REQUIRE_SIGNATURE=1
            shift
            ;;
        --no-systemd)
            NO_SYSTEMD=1
            shift
            ;;
        --provider-cidr)
            [[ $# -ge 2 ]] || fail '--provider-cidr 缺少参数'
            [[ "${EGRESS_MODE}" != "unrestricted" ]] || fail '--provider-cidr 不能与 --allow-unrestricted-provider-egress 同时使用'
            EGRESS_MODE="enforce"
            PROVIDER_CIDRS+=("$2")
            shift 2
            ;;
        --allow-unrestricted-provider-egress)
            [[ "${#PROVIDER_CIDRS[@]}" -eq 0 ]] || fail '--allow-unrestricted-provider-egress 不能与 --provider-cidr 同时使用'
            EGRESS_MODE="unrestricted"
            shift
            ;;
        --purge-data)
            PURGE_DATA=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *) fail "未知参数: $1" ;;
    esac
done

case "${COMMAND}" in
    install | upgrade | rollback | health | status | uninstall) ;;
    -h | --help | "")
        usage
        [[ -n "${COMMAND}" ]] && exit 0
        exit 2
        ;;
    *) fail "未知子命令: ${COMMAND}" ;;
esac

[[ "${PREFIX}" == /* && "${PREFIX}" != "/" && "${PREFIX}" != *$'\n'* ]] ||
    fail '--prefix 必须是非根目录的绝对路径'
case "/${PREFIX#/}/" in
    */../* | */./*) fail '--prefix 不能包含 . 或 .. 路径分量' ;;
esac
[[ "${SERVICE_USER}" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || fail '--service-user 格式非法'
[[ "${KEEP}" =~ ^[0-9]+$ && "${KEEP}" -ge 1 && "${KEEP}" -le 100 ]] ||
    fail '--keep 必须是 1-100 的整数'

if [[ "${COMMAND}" == "install" || "${COMMAND}" == "upgrade" ]]; then
    [[ "${VERSION}" =~ ^v[0-9A-Za-z][0-9A-Za-z._-]*$ ]] || fail '必须提供格式合法的 --version'
fi
if [[ -n "${FROM_DIST}" ]]; then
    [[ "${COMMAND}" == "install" || "${COMMAND}" == "upgrade" ]] ||
        fail '--from-dist 仅适用于 install 和 upgrade'
    [[ -d "${FROM_DIST}" && ! -L "${FROM_DIST}" ]] || fail '--from-dist 必须指向普通目录'
    FROM_DIST="$(readlink -f -- "${FROM_DIST}")"
fi
if [[ "${NO_SYSTEMD}" -eq 0 && "${COMMAND}" != "health" && "${COMMAND}" != "status" ]]; then
    [[ "${EUID}" -eq 0 ]] || fail '操作 systemd 需要 root；测试或容器环境请使用 --no-systemd'
fi

for command_name in bash curl python3 jq sha256sum stat mktemp readlink cp mv ln mkdir chmod find sort awk; do
    command -v "${command_name}" >/dev/null 2>&1 || fail "缺少依赖命令: ${command_name}"
done

if [[ "${NO_SYSTEMD}" -eq 1 && "${EGRESS_MODE}" != "preserve" ]]; then
    fail 'Provider 出站过滤选项仅适用于 systemd 模式'
fi
if [[ "${#PROVIDER_CIDRS[@]}" -gt 64 ]]; then
    fail '--provider-cidr 最多允许 64 项'
fi
if [[ "${EGRESS_MODE}" == "enforce" ]]; then
    normalized_cidrs="$(
        python3 - "${PROVIDER_CIDRS[@]}" <<'PY'
import ipaddress
import sys

seen = set()
for raw in sys.argv[1:]:
    try:
        network = ipaddress.ip_network(raw, strict=False)
    except ValueError as exc:
        raise SystemExit(f"invalid Provider CIDR {raw!r}: {exc}")
    if network.prefixlen == 0:
        raise SystemExit(f"refusing unrestricted Provider CIDR: {raw}")
    value = str(network)
    if value not in seen:
        seen.add(value)
        print(value)
PY
    )" || fail '--provider-cidr 格式非法'
    mapfile -t PROVIDER_CIDRS <<<"${normalized_cidrs}"
    [[ "${#PROVIDER_CIDRS[@]}" -gt 0 && -n "${PROVIDER_CIDRS[0]}" ]] || fail '至少需要一个有效的 --provider-cidr'
fi

if [[ "${NO_SYSTEMD}" -eq 0 ]]; then
    case "${COMMAND}" in
        install)
            [[ "${EGRESS_MODE}" != "preserve" ]] ||
                fail 'systemd 首次安装必须提供 --provider-cidr，或显式使用 --allow-unrestricted-provider-egress'
            ;;
        upgrade | rollback)
            if [[ "${EGRESS_MODE}" == "preserve" && ! -f "${SYSTEMD_EGRESS_DROPIN_PATH}" ]]; then
                fail '现有安装没有受管 Provider 出站策略；请提供 --provider-cidr，或显式使用 --allow-unrestricted-provider-egress'
            fi
            ;;
    esac
fi

ensure_prefix() {
    local mode="${1:-create}"
    if [[ -L "${PREFIX}" || (-e "${PREFIX}" && ! -d "${PREFIX}") ]]; then
        fail "安装前缀必须是普通目录且不能是符号链接: ${PREFIX}"
    fi
    if [[ "${mode}" == "create" ]]; then
        mkdir -p -- "${PREFIX}"
    else
        [[ -d "${PREFIX}" ]] || fail "安装前缀不存在: ${PREFIX}"
    fi
    PREFIX="$(readlink -f -- "${PREFIX}")"
    [[ "${PREFIX}" != "/" ]] || fail '拒绝使用根目录作为安装前缀'
    if [[ "${NO_SYSTEMD}" -eq 0 ]]; then
        case "${PREFIX}/" in
            /home/* | /root/* | /run/user/* | /tmp/* | /var/tmp/*)
                if [[ "${LINUX_AGENT_ALLOW_UNSAFE_SYSTEMD_TEST_PREFIX:-0}" == "1" &&
                    "${SYSTEMD_UNIT_PATH}" == "${PREFIX}/"* ]]; then
                    warn "仅测试：允许 systemd 沙箱不可见的安装前缀 ${PREFIX}"
                elif [[ ("${COMMAND}" == "health" || "${COMMAND}" == "status") &&
                    -f "${PREFIX}/.install-state.json" &&
                    ! -L "${PREFIX}/.install-state.json" &&
                    "$(jq -r '.no_systemd // false' "${PREFIX}/.install-state.json" 2>/dev/null || printf false)" == "true" ]]; then
                    :
                else
                    fail 'systemd 模式的 --prefix 不能位于 /home、/root、/run/user、/tmp 或 /var/tmp；请使用 /opt、/srv 等系统服务目录，或显式使用 --no-systemd'
                fi
                ;;
        esac
    fi
}

install_state_path() {
    printf '%s/.install-state.json\n' "${PREFIX}"
}

read_install_state() {
    local state_path
    state_path="$(install_state_path)"
    [[ -e "${state_path}" ]] || return 1
    [[ -f "${state_path}" && ! -L "${state_path}" ]] ||
        fail "安装状态文件类型非法: ${state_path}"
    jq -e --arg prefix "${PREFIX}" '
        type == "object"
        and .schema_version == 1
        and .prefix == $prefix
        and (.installed | type == "boolean")
        and (.no_systemd | type == "boolean")
        and (.service_user | type == "string")
        and (.service_user_created | type == "boolean")
        and (.service_user == "" or (.service_user | test("^[a-z_][a-z0-9_-]*[$]?$")))
    ' "${state_path}" >/dev/null || fail '安装状态文件契约无效'
    INSTALL_STATE_SERVICE_USER="$(jq -er '.service_user' "${state_path}")"
    INSTALL_STATE_SERVICE_USER_CREATED="$(jq -er 'if .service_user_created then 1 else 0 end' "${state_path}")"
    INSTALL_STATE_NO_SYSTEMD="$(jq -er 'if .no_systemd then 1 else 0 end' "${state_path}")"
    return 0
}

validate_service_identity() {
    local uid
    [[ "${SERVICE_USER}" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || fail '--service-user 格式非法'
    [[ "${NO_SYSTEMD}" -eq 0 ]] || return 0
    if [[ "${SERVICE_USER}" == "root" && "${LINUX_AGENT_ALLOW_ROOT_SERVICE_USER_FOR_TESTS:-0}" != "1" ]]; then
        fail 'systemd 服务必须使用非 root 用户'
    fi
    if id "${SERVICE_USER}" >/dev/null 2>&1; then
        uid="$(id -u "${SERVICE_USER}")"
        if [[ "${uid}" == "0" && "${LINUX_AGENT_ALLOW_ROOT_SERVICE_USER_FOR_TESTS:-0}" != "1" ]]; then
            fail 'systemd 服务用户不能映射到 UID 0'
        fi
    fi
}

load_existing_service_identity() {
    local installed_user=""
    if read_install_state; then
        if [[ "${INSTALL_STATE_NO_SYSTEMD}" -ne "${NO_SYSTEMD}" ]]; then
            if [[ ("${COMMAND}" == "health" || "${COMMAND}" == "status") &&
                "${NO_SYSTEMD}" -eq 0 && "${INSTALL_STATE_NO_SYSTEMD}" -eq 1 ]]; then
                NO_SYSTEMD=1
            else
                fail '当前安装的 systemd 模式与本次参数不一致'
            fi
        fi
        if [[ -n "${INSTALL_STATE_SERVICE_USER}" ]]; then
            if [[ "${SERVICE_USER_EXPLICIT}" -eq 1 && "${SERVICE_USER}" != "${INSTALL_STATE_SERVICE_USER}" ]]; then
                fail "服务用户必须保持为已安装用户: ${INSTALL_STATE_SERVICE_USER}"
            fi
            SERVICE_USER="${INSTALL_STATE_SERVICE_USER}"
            SERVICE_USER_CREATED="${INSTALL_STATE_SERVICE_USER_CREATED}"
        fi
        return 0
    fi
    [[ "${NO_SYSTEMD}" -eq 0 ]] || return 0
    if [[ -f "${SYSTEMD_UNIT_PATH}" && ! -L "${SYSTEMD_UNIT_PATH}" ]]; then
        installed_user="$(sed -n 's/^User=//p' "${SYSTEMD_UNIT_PATH}" | head -n 1)"
        if [[ -n "${installed_user}" ]]; then
            if [[ "${SERVICE_USER_EXPLICIT}" -eq 1 && "${SERVICE_USER}" != "${installed_user}" ]]; then
                fail "服务用户必须保持为已安装用户: ${installed_user}"
            fi
            SERVICE_USER="${installed_user}"
        fi
    fi
    return 0
}

write_install_state() {
    local installed="$1"
    local state_path state_tmp service_user=""
    state_path="$(install_state_path)"
    state_tmp="$(mktemp "${PREFIX}/.install-state.XXXXXX")"
    if [[ "${NO_SYSTEMD}" -eq 0 ]]; then
        service_user="${SERVICE_USER}"
    fi
    jq -S -n \
        --arg prefix "${PREFIX}" \
        --arg service_user "${service_user}" \
        --argjson installed "${installed}" \
        --argjson no_systemd "$([[ "${NO_SYSTEMD}" -eq 1 ]] && printf true || printf false)" \
        --argjson service_user_created "$([[ "${NO_SYSTEMD}" -eq 0 && "${SERVICE_USER_CREATED}" -eq 1 ]] && printf true || printf false)" \
        '{schema_version:1,prefix:$prefix,installed:$installed,no_systemd:$no_systemd,service_user:$service_user,service_user_created:$service_user_created}' \
        >"${state_tmp}" || {
        rm -f -- "${state_tmp}"
        fail '无法写入安装状态文件'
    }
    chmod 0600 "${state_tmp}"
    if [[ "${NO_SYSTEMD}" -eq 0 ]]; then
        chown root:root "${state_tmp}" || {
            rm -f -- "${state_tmp}"
            fail '无法设置安装状态文件所有权'
        }
    fi
    mv -f -- "${state_tmp}" "${state_path}"
}

begin_transaction() {
    local mode="$1"
    local old_version="$2"
    local target_version="$3"
    local name source backup state_path

    TRANSACTION_MODE="${mode}"
    TRANSACTION_OLD_VERSION="${old_version}"
    TRANSACTION_TARGET_VERSION="${target_version}"
    TRANSACTION_COMMITTED=0
    CONFIG_STATE_CAPTURED=0
    SYSTEMD_STATE_CAPTURED=0
    SYSTEMD_UNIT_EXISTED=0
    SYSTEMD_HELPER_SERVICE_EXISTED=0
    SYSTEMD_HELPER_SOCKET_EXISTED=0
    SYSTEMD_EGRESS_DROPIN_EXISTED=0
    SYSTEMD_WAS_ENABLED=0
    SYSTEMD_WAS_ACTIVE=0
    SYSTEMD_HELPER_SOCKET_WAS_ENABLED=0
    SYSTEMD_HELPER_SOCKET_WAS_ACTIVE=0
    INSTALL_STATE_CAPTURED=0
    INSTALL_STATE_EXISTED=0
    SERVICE_USER_CREATED_THIS_RUN=0
    TRANSACTION_BACKUP_DIR="$(mktemp -d "${PREFIX}/.install-rollback.XXXXXX")"
    chmod 0700 "${TRANSACTION_BACKUP_DIR}"
    mkdir -p "${TRANSACTION_BACKUP_DIR}/config"

    for name in config.json config.example.json ai-providers.json; do
        source="${PREFIX}/data/config/${name}"
        backup="${TRANSACTION_BACKUP_DIR}/config/${name}"
        if [[ -L "${source}" || (-e "${source}" && ! -f "${source}") ]]; then
            fail "持久配置备份源类型非法: ${source}"
        fi
        if [[ -f "${source}" ]]; then
            cp -p -- "${source}" "${backup}"
        fi
    done
    CONFIG_STATE_CAPTURED=1
    state_path="$(install_state_path)"
    if [[ -L "${state_path}" || (-e "${state_path}" && ! -f "${state_path}") ]]; then
        fail "安装状态文件类型非法: ${state_path}"
    fi
    if [[ -f "${state_path}" ]]; then
        cp -p -- "${state_path}" "${TRANSACTION_BACKUP_DIR}/install-state.json"
        INSTALL_STATE_EXISTED=1
    fi
    INSTALL_STATE_CAPTURED=1
}

capture_systemd_state() {
    local path backup_name existed_var egress_dir
    [[ "${NO_SYSTEMD}" -eq 0 ]] || return 0
    command -v systemctl >/dev/null 2>&1 || fail '缺少 systemctl'
    egress_dir="$(dirname -- "${SYSTEMD_EGRESS_DROPIN_PATH}")"
    if [[ -L "${egress_dir}" || (-e "${egress_dir}" && ! -d "${egress_dir}") ]]; then
        fail "systemd Provider 出站策略目录类型非法: ${egress_dir}"
    fi

    while IFS=$'\t' read -r path backup_name existed_var; do
        if [[ -L "${path}" || (-e "${path}" && ! -f "${path}") ]]; then
            fail "现有 systemd unit 类型非法: ${path}"
        fi
        if [[ -f "${path}" ]]; then
            cp -p -- "${path}" "${TRANSACTION_BACKUP_DIR}/${backup_name}"
            printf -v "${existed_var}" '%s' 1
        fi
    done <<EOF
${SYSTEMD_UNIT_PATH}	linux-agent-web.service	SYSTEMD_UNIT_EXISTED
${SYSTEMD_HELPER_SERVICE_PATH}	linux-agent-observer-helper.service	SYSTEMD_HELPER_SERVICE_EXISTED
${SYSTEMD_HELPER_SOCKET_PATH}	linux-agent-observer-helper.socket	SYSTEMD_HELPER_SOCKET_EXISTED
${SYSTEMD_EGRESS_DROPIN_PATH}	10-provider-egress.conf	SYSTEMD_EGRESS_DROPIN_EXISTED
EOF
    if systemctl is-enabled --quiet linux-agent-web.service >/dev/null 2>&1; then
        SYSTEMD_WAS_ENABLED=1
    fi
    if systemctl is-active --quiet linux-agent-web.service >/dev/null 2>&1; then
        SYSTEMD_WAS_ACTIVE=1
    fi
    if systemctl is-enabled --quiet linux-agent-observer-helper.socket >/dev/null 2>&1; then
        SYSTEMD_HELPER_SOCKET_WAS_ENABLED=1
    fi
    if systemctl is-active --quiet linux-agent-observer-helper.socket >/dev/null 2>&1; then
        SYSTEMD_HELPER_SOCKET_WAS_ACTIVE=1
    fi
    SYSTEMD_STATE_CAPTURED=1
}

restore_persistent_config() {
    local name backup target temp
    [[ "${CONFIG_STATE_CAPTURED}" -eq 1 ]] || return 0
    mkdir -p "${PREFIX}/data/config"
    for name in config.json config.example.json ai-providers.json; do
        backup="${TRANSACTION_BACKUP_DIR}/config/${name}"
        target="${PREFIX}/data/config/${name}"
        if [[ -f "${backup}" ]]; then
            temp="${target}.rollback.$$"
            cp -p -- "${backup}" "${temp}" && mv -f -- "${temp}" "${target}"
        else
            rm -f -- "${target}"
        fi
    done
}

restore_install_state() {
    local state_path
    state_path="$(install_state_path)"
    [[ "${INSTALL_STATE_CAPTURED}" -eq 1 ]] || return 0
    if [[ "${INSTALL_STATE_EXISTED}" -eq 1 ]]; then
        cp -p -- "${TRANSACTION_BACKUP_DIR}/install-state.json" "${state_path}"
    else
        rm -f -- "${state_path}"
    fi
}

restore_systemd_state() {
    [[ "${NO_SYSTEMD}" -eq 0 && "${SYSTEMD_STATE_CAPTURED}" -eq 1 ]] || return 0
    if [[ "${SYSTEMD_UNIT_EXISTED}" -eq 1 ]]; then
        cp -p -- "${TRANSACTION_BACKUP_DIR}/linux-agent-web.service" "${SYSTEMD_UNIT_PATH}"
    else
        rm -f -- "${SYSTEMD_UNIT_PATH}"
    fi
    if [[ "${SYSTEMD_HELPER_SERVICE_EXISTED}" -eq 1 ]]; then
        cp -p -- "${TRANSACTION_BACKUP_DIR}/linux-agent-observer-helper.service" "${SYSTEMD_HELPER_SERVICE_PATH}"
    else
        rm -f -- "${SYSTEMD_HELPER_SERVICE_PATH}"
    fi
    if [[ "${SYSTEMD_HELPER_SOCKET_EXISTED}" -eq 1 ]]; then
        cp -p -- "${TRANSACTION_BACKUP_DIR}/linux-agent-observer-helper.socket" "${SYSTEMD_HELPER_SOCKET_PATH}"
    else
        rm -f -- "${SYSTEMD_HELPER_SOCKET_PATH}"
    fi
    if [[ "${SYSTEMD_EGRESS_DROPIN_EXISTED}" -eq 1 ]]; then
        mkdir -p -- "$(dirname -- "${SYSTEMD_EGRESS_DROPIN_PATH}")"
        cp -p -- "${TRANSACTION_BACKUP_DIR}/10-provider-egress.conf" "${SYSTEMD_EGRESS_DROPIN_PATH}"
    else
        rm -f -- "${SYSTEMD_EGRESS_DROPIN_PATH}"
        rmdir -- "$(dirname -- "${SYSTEMD_EGRESS_DROPIN_PATH}")" 2>/dev/null || true
    fi
    systemctl daemon-reload >/dev/null 2>&1 || warn '回滚后 systemd daemon-reload 失败'
    if [[ "${SYSTEMD_HELPER_SOCKET_WAS_ENABLED}" -eq 1 ]]; then
        systemctl enable linux-agent-observer-helper.socket >/dev/null 2>&1 || warn '无法恢复 observer helper socket enabled 状态'
    else
        systemctl disable linux-agent-observer-helper.socket >/dev/null 2>&1 || true
    fi
    if [[ "${SYSTEMD_HELPER_SOCKET_WAS_ACTIVE}" -eq 1 ]]; then
        systemctl start linux-agent-observer-helper.socket >/dev/null 2>&1 || warn '无法恢复 observer helper socket active 状态'
    else
        systemctl stop linux-agent-observer-helper.socket >/dev/null 2>&1 || true
    fi
    if [[ "${SYSTEMD_WAS_ENABLED}" -eq 1 ]]; then
        systemctl enable linux-agent-web.service >/dev/null 2>&1 || warn '无法恢复 systemd enabled 状态'
    else
        systemctl disable linux-agent-web.service >/dev/null 2>&1 || true
    fi
    if [[ "${SYSTEMD_WAS_ACTIVE}" -eq 1 ]]; then
        systemctl restart linux-agent-web.service >/dev/null 2>&1 || warn '无法恢复操作前的 Web 服务进程'
    else
        systemctl stop linux-agent-web.service >/dev/null 2>&1 || true
    fi
}

rollback_transaction() {
    local current_target="" link_tmp

    [[ -n "${TRANSACTION_MODE}" && "${TRANSACTION_COMMITTED}" -eq 0 ]] || return 0
    TRANSACTION_COMMITTED=1
    current_target="$(readlink -- "${PREFIX}/current" 2>/dev/null || true)"

    if [[ "${NO_SYSTEMD}" -eq 0 && "${SYSTEMD_STATE_CAPTURED}" -eq 1 &&
        "${current_target}" == "releases/${TRANSACTION_TARGET_VERSION}" ]]; then
        systemctl stop linux-agent-web.service >/dev/null 2>&1 || true
        systemctl stop linux-agent-observer-helper.socket >/dev/null 2>&1 || true
    fi

    if [[ "${current_target}" == "releases/${TRANSACTION_TARGET_VERSION}" ]]; then
        if [[ "${TRANSACTION_MODE}" == "install" ]]; then
            rm -f -- "${PREFIX}/current"
        elif [[ -n "${TRANSACTION_OLD_VERSION}" &&
            -d "${PREFIX}/releases/${TRANSACTION_OLD_VERSION}" &&
            ! -L "${PREFIX}/releases/${TRANSACTION_OLD_VERSION}" ]]; then
            link_tmp="${PREFIX}/.current.rollback.$$"
            rm -f -- "${link_tmp}"
            if ln -s "releases/${TRANSACTION_OLD_VERSION}" "${link_tmp}"; then
                mv -Tf -- "${link_tmp}" "${PREFIX}/current" || rm -f -- "${link_tmp}"
            fi
        else
            warn "无法恢复升级前 current: ${TRANSACTION_OLD_VERSION}"
        fi
    fi

    restore_persistent_config || warn '无法完整恢复持久配置'
    restore_install_state || warn '无法完整恢复安装状态'
    restore_systemd_state || warn '无法完整恢复 systemd unit 状态'

    if [[ "${TRANSACTION_MODE}" == "install" && "${SERVICE_USER_CREATED_THIS_RUN}" -eq 1 &&
        "${NO_SYSTEMD}" -eq 0 && "${SERVICE_USER}" != "root" ]]; then
        if command -v userdel >/dev/null 2>&1 && id "${SERVICE_USER}" >/dev/null 2>&1; then
            userdel "${SERVICE_USER}" >/dev/null 2>&1 ||
                warn "安装失败后无法删除本次创建的服务用户: ${SERVICE_USER}"
        fi
    fi
    SERVICE_USER_CREATED_THIS_RUN=0

    if [[ "${TRANSACTION_MODE}" == "install" || "${TRANSACTION_MODE}" == "upgrade" ]]; then
        current_target="$(readlink -- "${PREFIX}/current" 2>/dev/null || true)"
        if [[ "${current_target}" != "releases/${TRANSACTION_TARGET_VERSION}" &&
            -n "${PREPARED_RELEASE_DIR}" &&
            "${PREPARED_RELEASE_DIR}" == "${PREFIX}/releases/${TRANSACTION_TARGET_VERSION}" &&
            -d "${PREPARED_RELEASE_DIR}" && ! -L "${PREPARED_RELEASE_DIR}" ]]; then
            rm -rf -- "${PREPARED_RELEASE_DIR}"
        fi
    fi
}

commit_transaction() {
    TRANSACTION_COMMITTED=1
    TRANSACTION_MODE=""
    if [[ -n "${TRANSACTION_BACKUP_DIR}" && -d "${TRANSACTION_BACKUP_DIR}" ]]; then
        rm -rf -- "${TRANSACTION_BACKUP_DIR}"
    fi
    TRANSACTION_BACKUP_DIR=""
}

current_version() {
    local target resolved releases_root
    [[ -L "${PREFIX}/current" ]] || return 1
    target="$(readlink -- "${PREFIX}/current")"
    if [[ "${target}" == /* ]]; then
        resolved="$(readlink -f -- "${target}" 2>/dev/null || true)"
    else
        resolved="$(readlink -f -- "${PREFIX}/${target}" 2>/dev/null || true)"
    fi
    releases_root="$(readlink -f -- "${PREFIX}/releases" 2>/dev/null || true)"
    [[ -n "${resolved}" && -n "${releases_root}" && "${resolved}" == "${releases_root}/"* ]] ||
        fail 'current 符号链接未指向受管 releases 目录'
    basename -- "${resolved}"
}

atomic_switch() {
    local version="$1"
    local target="${PREFIX}/releases/${version}"
    local link_tmp="${PREFIX}/.current.$$"
    [[ -d "${target}" && ! -L "${target}" ]] || fail "目标版本不存在: ${version}"
    rm -f -- "${link_tmp}"
    ln -s "releases/${version}" "${link_tmp}"
    mv -Tf -- "${link_tmp}" "${PREFIX}/current"
}

append_history() {
    local version="$1"
    [[ -n "${version}" ]] || return 0
    printf '%s\n' "${version}" >>"${PREFIX}/releases/.history"
    chmod 0600 "${PREFIX}/releases/.history"
}

set_config_version() {
    local version="$1"
    local config_path="${PREFIX}/data/config/config.json"
    local config_tmp="${config_path}.tmp.$$"
    local expected_uid expected_gid
    [[ -f "${config_path}" && ! -L "${config_path}" ]] || fail '持久配置文件缺失或类型非法'
    if ! jq --arg version "${version}" '
        .remote = ((.remote // {}) + {
            enabled:true,
            release_version:$version,
            storage_backend:"local"
        })
        | .providers_security = ((.providers_security // {}) + {require_https:true})
    ' "${config_path}" >"${config_tmp}"; then
        rm -f -- "${config_tmp}"
        fail '无法更新持久配置中的 release 版本'
    fi
    chmod 0600 "${config_tmp}"
    if [[ "${NO_SYSTEMD}" -eq 0 ]]; then
        SERVICE_GROUP="$(id -gn "${SERVICE_USER}")" || fail "无法确定服务用户主组: ${SERVICE_USER}"
        chown "${SERVICE_USER}:${SERVICE_GROUP}" "${config_tmp}"
    fi
    mv -f -- "${config_tmp}" "${config_path}"
    if [[ "${NO_SYSTEMD}" -eq 0 ]]; then
        expected_uid="$(id -u "${SERVICE_USER}")"
        expected_gid="$(id -g "${SERVICE_USER}")"
        [[ "$(stat -c '%u' "${config_path}")" == "${expected_uid}" &&
        "$(stat -c '%g' "${config_path}")" == "${expected_gid}" ]] ||
            fail 'config.json 所有权未归属 systemd 服务用户'
    fi
}

fetch_url() {
    local url="$1"
    local output="$2"
    local max_size="$3"
    curl -fsSL --proto '=https' --tlsv1.2 --max-time 60 --max-filesize "${max_size}" \
        "${url}" -o "${output}"
}

copy_local_asset() {
    local name="$1"
    local output="$2"
    local source="${FROM_DIST}/${name}"
    [[ -f "${source}" && ! -L "${source}" ]] || fail "本地发布物缺失或类型非法: ${name}"
    cp -- "${source}" "${output}"
}

validate_manifest() {
    local manifest="$1"
    jq -e --arg repository "${REPOSITORY}" --arg version "${VERSION}" '
        def valid_asset:
            type == "object"
            and (.name | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]+$"))
            and (.sha256 | type == "string" and test("^[0-9a-f]{64}$"))
            and (.size_bytes | type == "number" and floor == . and . > 0)
            and (.max_size_bytes | type == "number" and floor == . and . >= 1)
            and (.size_bytes <= .max_size_bytes)
            and (.max_size_bytes <= 52428800);
        type == "object"
        and .schema_version == 1
        and .repository == $repository
        and .version == $version
        and (.assets | type == "object")
        and (.assets.core | valid_asset)
        and (.assets.web | valid_asset)
        and (.assets.installer | valid_asset)
        and ([.assets[] | valid_asset] | all)
        and (.assets.installer.name == "linux-agent-install.sh")
        and ((.skills | type) == "object" and (.skills | length) > 0)
        and ([.skills | to_entries[] | . as $skill | select(
            ($skill.key | test("^[a-z0-9][a-z0-9-]*$") | not)
            or (($skill.value | type) != "object")
            or ($skill.value.asset | valid_asset | not)
            or (($skill.value.refs | type) != "array" or ($skill.value.refs | length) == 0)
            or ([$skill.value.refs[] | select(
                ((.ref | type) != "string")
                or (.ref | startswith($skill.key + "/") | not)
                or ((.description | type) != "string" or (.description | length) == 0)
                or (.risk | IN("low", "medium", "high", "critical") | not)
            )] | length > 0)
        )] | length == 0)
        and ([.assets[].name, .skills[].asset.name] as $names
            | ($names | length) == ($names | unique | length))
    ' "${manifest}" >/dev/null ||
        fail 'release manifest 契约无效；旧发布物可能不包含 installer 资产'
}

obtain_signature_bundle() {
    local output="$1"
    local base_url="$2"
    local source http_code curl_status
    if [[ -n "${FROM_DIST}" ]]; then
        source="${FROM_DIST}/release-manifest.json.sigstore.json"
        if [[ -f "${source}" && ! -L "${source}" ]]; then
            cp -- "${source}" "${output}"
            return 0
        fi
        return 1
    fi

    set +e
    http_code="$(curl -fsSL --proto '=https' --tlsv1.2 --max-time 60 --max-filesize 10485760 \
        -w '%{http_code}' "${base_url}/release-manifest.json.sigstore.json" -o "${output}")"
    curl_status="$?"
    set -e
    if [[ "${curl_status}" -eq 0 ]]; then
        return 0
    fi
    rm -f -- "${output}"
    [[ "${http_code}" == "404" ]] && return 1
    fail 'release 签名 bundle 下载失败'
}

verify_manifest_signature() {
    local manifest="$1"
    local base_url="$2"
    local bundle="${WORK_DIR}/release-manifest.json.sigstore.json"
    local public_key="${LINUX_AGENT_SIGNATURE_PUBKEY:-}"
    local identity="${LINUX_AGENT_SIGNATURE_IDENTITY:-^https://github.com/libeal/ASSIstant/\\.github/workflows/remote-release\\.yml@refs/tags/v.*$}"
    local issuer="${LINUX_AGENT_SIGNATURE_ISSUER:-https://token.actions.githubusercontent.com}"
    local bundle_available=0

    if ! command -v cosign >/dev/null 2>&1; then
        [[ "${REQUIRE_SIGNATURE}" -eq 0 ]] || fail '已要求验证 release 签名，但系统未安装 cosign'
        warn '未安装 cosign，继续执行 SHA256 校验'
        return 0
    fi
    if obtain_signature_bundle "${bundle}" "${base_url}"; then
        bundle_available=1
        [[ -s "${bundle}" && "$(stat -c '%s' "${bundle}")" -le 10485760 ]] ||
            fail 'release 签名 bundle 大小非法'
    fi
    if [[ "${bundle_available}" -eq 0 ]]; then
        [[ "${REQUIRE_SIGNATURE}" -eq 0 ]] || fail '已要求验证 release 签名，但发布物没有签名 bundle'
        warn 'release 未提供签名 bundle（可能是旧版本），回退到 SHA256 校验'
        return 0
    fi

    if [[ -n "${public_key}" ]]; then
        [[ -f "${public_key}" && ! -L "${public_key}" ]] ||
            fail 'LINUX_AGENT_SIGNATURE_PUBKEY 必须指向普通文件'
        cosign verify-blob --offline --insecure-ignore-tlog \
            --key "${public_key}" --bundle "${bundle}" "${manifest}" >/dev/null ||
            fail 'release manifest 签名验证失败'
    else
        cosign verify-blob \
            --bundle "${bundle}" \
            --certificate-oidc-issuer "${issuer}" \
            --certificate-identity-regexp "${identity}" \
            "${manifest}" >/dev/null || fail 'release manifest keyless 签名验证失败'
    fi
}

verify_running_installer_asset() {
    local manifest="$1"
    local source_path resolved_path expected_sha expected_size actual_sha actual_size
    source_path="${BASH_SOURCE[0]}"
    [[ -n "${source_path}" && -f "${source_path}" && ! -L "${source_path}" ]] ||
        fail '安装器必须先保存为普通文件并完成外部验证，不能从管道或符号链接运行'
    resolved_path="$(readlink -f -- "${source_path}")"
    expected_sha="$(jq -er '.assets.installer.sha256' "${manifest}")" || fail 'manifest 缺少 installer SHA256'
    expected_size="$(jq -er '.assets.installer.size_bytes' "${manifest}")" || fail 'manifest 缺少 installer 大小'
    actual_size="$(stat -c '%s' -- "${resolved_path}")"
    actual_sha="$(sha256sum -- "${resolved_path}" | awk '{print $1}')"
    [[ "${actual_size}" -eq "${expected_size}" ]] || fail '当前安装器与签名 manifest 登记的大小不一致'
    [[ "${actual_sha}" == "${expected_sha}" ]] || fail '当前安装器与签名 manifest 登记的 SHA256 不一致'
}

obtain_asset() {
    local manifest="$1"
    local selector="$2"
    local base_url="$3"
    local name expected_sha expected_size max_size output actual_sha actual_size
    name="$(jq -er "${selector}.name" "${manifest}")" || fail "manifest 缺少资产: ${selector}"
    expected_sha="$(jq -er "${selector}.sha256" "${manifest}")"
    expected_size="$(jq -er "${selector}.size_bytes" "${manifest}")"
    max_size="$(jq -er "${selector}.max_size_bytes" "${manifest}")"
    output="${WORK_DIR}/${name}"
    if [[ -n "${FROM_DIST}" ]]; then
        copy_local_asset "${name}" "${output}"
    else
        fetch_url "${base_url}/${name}" "${output}" "${max_size}" || fail "资产下载失败: ${name}"
    fi
    [[ -f "${output}" && ! -L "${output}" ]] || fail "资产类型非法: ${name}"
    actual_size="$(stat -c '%s' "${output}")"
    [[ "${actual_size}" -eq "${expected_size}" && "${actual_size}" -le "${max_size}" ]] ||
        fail "资产大小校验失败: ${name}"
    actual_sha="$(sha256sum "${output}" | awk '{print $1}')"
    [[ "${actual_sha}" == "${expected_sha}" ]] || fail "资产 SHA256 校验失败: ${name}"
    printf '%s\n' "${output}"
}

extract_archive_safely() {
    local archive="$1"
    local destination="$2"
    python3 - "${archive}" "${destination}" <<'PY'
import os
import shutil
import sys
import tarfile
from pathlib import Path, PurePosixPath

MAX_MEMBERS = 10000
MAX_FILE_BYTES = 64 * 1024 * 1024
MAX_TOTAL_BYTES = 256 * 1024 * 1024
MIN_FREE_RESERVE_BYTES = 64 * 1024 * 1024

archive_path = Path(sys.argv[1])
root = Path(sys.argv[2]).resolve()
root.mkdir(parents=True, exist_ok=True)

with tarfile.open(archive_path, "r:gz") as archive:
    members = archive.getmembers()
    if not members or len(members) > MAX_MEMBERS:
        raise SystemExit("archive member count is invalid")
    seen = set()
    total_size = 0
    for member in members:
        path = PurePosixPath(member.name)
        if path.is_absolute() or not path.parts or any(part in ("", ".", "..") for part in path.parts):
            raise SystemExit(f"unsafe archive path: {member.name}")
        if not (member.isdir() or member.isfile()):
            raise SystemExit(f"unsupported archive member: {member.name}")
        normalized = path.as_posix().rstrip("/")
        if normalized in seen:
            raise SystemExit(f"duplicate archive member: {member.name}")
        seen.add(normalized)
        if member.isfile():
            if member.size < 0 or member.size > MAX_FILE_BYTES:
                raise SystemExit(f"archive member is too large: {member.name}")
            total_size += member.size
            if total_size > MAX_TOTAL_BYTES:
                raise SystemExit("archive expands beyond the allowed size")
        target = root.joinpath(*path.parts)
        if os.path.commonpath((root, target.resolve(strict=False))) != str(root):
            raise SystemExit(f"archive path escapes destination: {member.name}")

    free_bytes = shutil.disk_usage(root).free
    if total_size > max(0, free_bytes - MIN_FREE_RESERVE_BYTES):
        raise SystemExit("archive expansion would exhaust destination storage")

    for member in members:
        path = PurePosixPath(member.name)
        target = root.joinpath(*path.parts)
        if member.isdir():
            target.mkdir(parents=True, exist_ok=True)
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists() or target.is_symlink():
            raise SystemExit(f"archive file collides with existing path: {member.name}")
        source = archive.extractfile(member)
        if source is None:
            raise SystemExit(f"cannot read archive member: {member.name}")
        with source, target.open("xb") as output:
            remaining = member.size
            while remaining:
                chunk = source.read(min(1024 * 1024, remaining))
                if not chunk:
                    raise SystemExit(f"truncated archive member: {member.name}")
                output.write(chunk)
                remaining -= len(chunk)
            output.flush()
            os.fsync(output.fileno())
        os.chmod(target, member.mode & 0o755)
PY
}

prepare_release() {
    local release_dir="${PREFIX}/releases/${VERSION}"
    local manifest base_url core_archive web_archive skill_name skill_archive selector
    [[ ! -e "${release_dir}" && ! -L "${release_dir}" ]] || fail "版本已经安装: ${VERSION}"
    mkdir -p -- "${PREFIX}/releases"
    WORK_DIR="$(mktemp -d "${PREFIX}/.install-staging.XXXXXX")"
    chmod 0700 "${WORK_DIR}"
    manifest="${WORK_DIR}/release-manifest.json"
    if [[ -n "${FROM_DIST}" ]]; then
        copy_local_asset release-manifest.json "${manifest}"
        base_url=""
    else
        base_url="https://github.com/${REPOSITORY}/releases/download/${VERSION}"
        fetch_url "${base_url}/release-manifest.json" "${manifest}" 1048576 ||
            fail 'release manifest 下载失败'
    fi
    [[ "$(stat -c '%s' "${manifest}")" -le 1048576 ]] || fail 'release manifest 超过 1MiB'
    validate_manifest "${manifest}"
    verify_manifest_signature "${manifest}" "${base_url}"
    verify_running_installer_asset "${manifest}"

    core_archive="$(obtain_asset "${manifest}" '.assets.core' "${base_url}")"
    web_archive="$(obtain_asset "${manifest}" '.assets.web' "${base_url}")"
    mkdir -p "${WORK_DIR}/release"
    extract_archive_safely "${core_archive}" "${WORK_DIR}/release" || fail 'core archive 安全解包失败'
    extract_archive_safely "${web_archive}" "${WORK_DIR}/release" || fail 'web archive 安全解包失败'
    while IFS= read -r skill_name; do
        [[ "${skill_name}" =~ ^[a-z0-9][a-z0-9-]*$ ]] ||
            fail "Skill 名称非法: ${skill_name}"
        selector=".skills[\"${skill_name}\"].asset"
        skill_archive="$(obtain_asset "${manifest}" "${selector}" "${base_url}")"
        extract_archive_safely "${skill_archive}" "${WORK_DIR}/release" ||
            fail "Skill archive 安全解包失败: ${skill_name}"
    done < <(jq -r '.skills | keys[]' "${manifest}")
    [[ -x "${WORK_DIR}/release/bin/agent" && -x "${WORK_DIR}/release/bin/agent-web" ]] ||
        fail '发布物缺少可执行入口'
    [[ -f "${WORK_DIR}/release/config/config.example.json" &&
        -f "${WORK_DIR}/release/packaging/linux-agent-web.service" &&
        -f "${WORK_DIR}/release/packaging/linux-agent-observer-helper.service" &&
        -f "${WORK_DIR}/release/packaging/linux-agent-observer-helper.socket" ]] ||
        fail '发布物缺少配置或 systemd unit'

    # Validate the bundled registry against the bundled configuration. The
    # operator's persistent config may be invalid or point at an external
    # skills_dir; neither should change the release-integrity verdict.
    cp -- "${WORK_DIR}/release/config/config.example.json" "${WORK_DIR}/release/config/config.json"
    chmod 0600 "${WORK_DIR}/release/config/config.json"
    if ! bash "${WORK_DIR}/release/bin/agent" api skills validate '{}' |
        jq -e '.ok == true' >/dev/null; then
        fail '安装包内的 Skill registry 校验失败'
    fi
    rm -f -- "${WORK_DIR}/release/config/config.json"
    rm -rf -- "${WORK_DIR}/release/logs" "${WORK_DIR}/release/tmp"

    mkdir -p "${PREFIX}/data/config" "${PREFIX}/data/logs" "${PREFIX}/data/tmp"
    cp -- "${WORK_DIR}/release/config/config.example.json" "${PREFIX}/data/config/config.example.json"
    cp -- "${WORK_DIR}/release/config/ai-providers.json" "${PREFIX}/data/config/ai-providers.json"
    if [[ ! -e "${PREFIX}/data/config/config.json" ]]; then
        cp -- "${WORK_DIR}/release/config/config.example.json" "${PREFIX}/data/config/config.json"
    fi
    [[ -f "${PREFIX}/data/config/config.json" && ! -L "${PREFIX}/data/config/config.json" ]] ||
        fail 'config.json 必须是普通文件'
    chmod 0600 "${PREFIX}/data/config/config.json"
    chmod 0700 "${PREFIX}/data" "${PREFIX}/data/config" "${PREFIX}/data/logs" "${PREFIX}/data/tmp"

    rm -rf -- "${WORK_DIR}/release/config"
    ln -s ../../data/config "${WORK_DIR}/release/config"
    ln -s ../../data/logs "${WORK_DIR}/release/logs"
    ln -s ../../data/tmp "${WORK_DIR}/release/tmp"
    find "${WORK_DIR}/release" -type f -exec chmod a-w -- {} +
    find "${WORK_DIR}/release" -type d -exec chmod 0755 -- {} +
    mv -- "${WORK_DIR}/release" "${release_dir}"
    PREPARED_RELEASE_DIR="${release_dir}"
}

ensure_service_identity() {
    local uid
    [[ "${NO_SYSTEMD}" -eq 0 ]] || return 0
    command -v chown >/dev/null 2>&1 || fail '缺少 chown，无法设置服务数据所有权'
    validate_service_identity
    if ! id "${SERVICE_USER}" >/dev/null 2>&1; then
        command -v useradd >/dev/null 2>&1 || fail '缺少 useradd，无法创建 systemd 服务用户'
        useradd --system --home-dir "${PREFIX}" --shell /usr/sbin/nologin "${SERVICE_USER}"
        SERVICE_USER_CREATED=1
        SERVICE_USER_CREATED_THIS_RUN=1
    fi
    uid="$(id -u "${SERVICE_USER}")"
    [[ "${uid}" != "0" || "${LINUX_AGENT_ALLOW_ROOT_SERVICE_USER_FOR_TESTS:-0}" == "1" ]] ||
        fail 'systemd 服务用户不能映射到 UID 0'
    SERVICE_GROUP="$(id -gn "${SERVICE_USER}")"
    [[ -n "${SERVICE_GROUP}" ]] || fail "无法确定服务用户主组: ${SERVICE_USER}"
    chown -R "${SERVICE_USER}:${SERVICE_GROUP}" "${PREFIX}/data"
    chown -R root:root "${PREFIX}/releases"
}

install_provider_egress_policy() {
    local dropin_dir rendered target_tmp cidr
    [[ "${NO_SYSTEMD}" -eq 0 ]] || return 0
    case "${EGRESS_MODE}" in
        preserve)
            return 0
            ;;
        unrestricted)
            rm -f -- "${SYSTEMD_EGRESS_DROPIN_PATH}"
            rmdir -- "$(dirname -- "${SYSTEMD_EGRESS_DROPIN_PATH}")" 2>/dev/null || true
            warn '已明确选择不限制 AI Provider 网络出口'
            return 0
            ;;
        enforce) ;;
        *) fail "未知 Provider 出站策略模式: ${EGRESS_MODE}" ;;
    esac

    dropin_dir="$(dirname -- "${SYSTEMD_EGRESS_DROPIN_PATH}")"
    if [[ -L "${dropin_dir}" || (-e "${dropin_dir}" && ! -d "${dropin_dir}") ]]; then
        fail "systemd Provider 出站策略目录类型非法: ${dropin_dir}"
    fi
    if [[ -L "${SYSTEMD_EGRESS_DROPIN_PATH}" ||
        (-e "${SYSTEMD_EGRESS_DROPIN_PATH}" && ! -f "${SYSTEMD_EGRESS_DROPIN_PATH}") ]]; then
        fail "systemd Provider 出站策略文件类型非法: ${SYSTEMD_EGRESS_DROPIN_PATH}"
    fi
    mkdir -p -- "${dropin_dir}"
    rendered="${WORK_DIR:-${TRANSACTION_BACKUP_DIR}}/.linux-agent-provider-egress.$$"
    {
        printf '%s\n' '# Managed by linux-agent-install.sh. Re-run the installer to change this policy.'
        printf '%s\n' '[Service]' 'IPAddressDeny=any' 'IPAddressAllow=localhost'
        for cidr in "${PROVIDER_CIDRS[@]}"; do
            printf 'IPAddressAllow=%s\n' "${cidr}"
        done
    } >"${rendered}"
    chmod 0644 "${rendered}"
    target_tmp="$(mktemp "${dropin_dir}/.10-provider-egress.conf.XXXXXX")"
    if ! cp -- "${rendered}" "${target_tmp}"; then
        rm -f -- "${target_tmp}"
        fail '无法暂存 systemd Provider 出站策略'
    fi
    chmod 0644 "${target_tmp}"
    mv -f -- "${target_tmp}" "${SYSTEMD_EGRESS_DROPIN_PATH}"
}

install_systemd_unit() {
    local source="${PREFIX}/current/packaging/linux-agent-web.service"
    local helper_source="${PREFIX}/current/packaging/linux-agent-observer-helper.service"
    local socket_source="${PREFIX}/current/packaging/linux-agent-observer-helper.socket"
    local render_root="${WORK_DIR:-${TRANSACTION_BACKUP_DIR:-${PREFIX}}}"
    local rendered="${render_root}/.linux-agent-web.service.$$"
    local helper_rendered="${render_root}/.linux-agent-observer-helper.service.$$"
    local socket_rendered="${render_root}/.linux-agent-observer-helper.socket.$$"
    [[ "${NO_SYSTEMD}" -eq 0 ]] || return 0
    command -v systemctl >/dev/null 2>&1 || fail '缺少 systemctl'
    [[ -f "${source}" && -f "${helper_source}" && -f "${socket_source}" ]] ||
        fail '当前版本缺少 systemd unit'
    python3 - "${source}" "${rendered}" "${helper_source}" "${helper_rendered}" \
        "${socket_source}" "${socket_rendered}" "/opt/linux-agent" "${PREFIX}" \
        "linux-agent" "${SERVICE_USER}" "${SERVICE_GROUP}" <<'PY'
import sys
from pathlib import Path

(
    source,
    output,
    helper_source,
    helper_output,
    socket_source,
    socket_output,
    old_prefix,
    prefix,
    old_user,
    user,
    group,
) = sys.argv[1:]

web = Path(source).read_text(encoding="utf-8")
web = web.replace(old_prefix, prefix)
web = web.replace(f"User={old_user}", f"User={user}")
web = web.replace(f"Group={old_user}", f"Group={group}")
Path(output).write_text(web, encoding="utf-8")

helper = Path(helper_source).read_text(encoding="utf-8").replace(old_prefix, prefix)
Path(helper_output).write_text(helper, encoding="utf-8")

socket = Path(socket_source).read_text(encoding="utf-8")
socket = socket.replace(f"SocketGroup={old_user}", f"SocketGroup={group}")
Path(socket_output).write_text(socket, encoding="utf-8")
PY
    mkdir -p -- \
        "$(dirname -- "${SYSTEMD_UNIT_PATH}")" \
        "$(dirname -- "${SYSTEMD_HELPER_SERVICE_PATH}")" \
        "$(dirname -- "${SYSTEMD_HELPER_SOCKET_PATH}")"
    cp -- "${rendered}" "${SYSTEMD_UNIT_PATH}"
    cp -- "${helper_rendered}" "${SYSTEMD_HELPER_SERVICE_PATH}"
    cp -- "${socket_rendered}" "${SYSTEMD_HELPER_SOCKET_PATH}"
    chmod 0644 "${SYSTEMD_UNIT_PATH}" "${SYSTEMD_HELPER_SERVICE_PATH}" "${SYSTEMD_HELPER_SOCKET_PATH}"
    install_provider_egress_policy
    systemctl daemon-reload
}

web_health_request() {
    local config_path="${PREFIX}/data/config/config.json"
    local token_file="${PREFIX}/data/tmp/web/auth-token"
    local port token
    [[ -f "${config_path}" && ! -L "${config_path}" ]] || return 1
    port="$(jq -er '.web.port // 8765' "${config_path}" 2>/dev/null)" || return 1
    [[ "${port}" =~ ^[0-9]+$ && "${port}" -ge 1 && "${port}" -le 65535 ]] || return 1
    token="$(jq -er '.web.token // empty' "${config_path}" 2>/dev/null || true)"
    if [[ -z "${token}" ]]; then
        [[ -f "${token_file}" && ! -L "${token_file}" ]] || return 1
        token="$(<"${token_file}")"
    fi
    [[ -n "${token}" ]] || return 1
    curl --noproxy '*' -fsS --max-time 2 \
        -H "Authorization: Bearer ${token}" \
        "http://127.0.0.1:${port}/api/health"
}

observer_helper_health_request() {
    local helper="${PREFIX}/current/lib/observer_helper.py"
    local socket_path="${LINUX_AGENT_OBSERVER_HELPER_SOCKET:-/run/linux-agent/observer.sock}"
    local current_user
    [[ -f "${helper}" && ! -L "${helper}" ]] || {
        printf 'observer helper 客户端不存在: %s\n' "${helper}" >&2
        return 1
    }
    if [[ "${EUID}" -eq 0 && "${SERVICE_USER}" != "root" ]]; then
        command -v runuser >/dev/null 2>&1 || {
            printf '缺少 runuser，无法以 Web 服务用户 %s 检查 observer helper\n' "${SERVICE_USER}" >&2
            return 1
        }
        runuser -u "${SERVICE_USER}" -- \
            python3 "${helper}" request --socket "${socket_path}" ping
        return
    fi
    current_user="$(id -un)" || return 1
    if [[ "${current_user}" != "${SERVICE_USER}" ]]; then
        printf 'observer helper 健康检查必须由 root 或 Web 服务用户 %s 执行（当前用户: %s）\n' \
            "${SERVICE_USER}" "${current_user}" >&2
        return 1
    fi
    python3 "${helper}" request --socket "${socket_path}" ping
}

health_request() {
    local output
    output="$(web_health_request)" || return 1
    if [[ "${NO_SYSTEMD}" -eq 1 ]]; then
        printf '%s\n' "${output}"
        return 0
    fi
    observer_helper_health_request || return 1
    jq -c '. + {observer_helper:{ok:true,status:"ready"}}' <<<"${output}"
}

wait_for_health() {
    local output error_file attempts="${LINUX_AGENT_INSTALL_HEALTH_ATTEMPTS:-60}"
    [[ "${attempts}" =~ ^[0-9]+$ && "${attempts}" -ge 1 && "${attempts}" -le 600 ]] || attempts=60
    error_file="$(mktemp)"
    for _ in $(seq 1 "${attempts}"); do
        if output="$(health_request 2>"${error_file}")" &&
            jq -e '.ok == true and .status == "ok"' >/dev/null <<<"${output}"; then
            rm -f -- "${error_file}"
            printf '%s\n' "${output}"
            return 0
        fi
        sleep 0.5
    done
    if [[ -s "${error_file}" ]]; then
        printf '最后一次健康检查错误：\n' >&2
        sed -n '1,20p' "${error_file}" >&2
    fi
    rm -f -- "${error_file}"
    return 1
}

restart_and_check() {
    [[ "${NO_SYSTEMD}" -eq 0 ]] || return 0
    systemctl restart linux-agent-observer-helper.socket linux-agent-web.service || return 1
    wait_for_health >/dev/null || return 1
}

run_install_health_check() {
    local health_started_at health_ok=0 startup_ok=0 cleanup_ok=1 unit
    local -a units=(
        linux-agent-web.service
        linux-agent-observer-helper.service
        linux-agent-observer-helper.socket
    )

    health_started_at="$(date --iso-8601=seconds)"

    # systemctl start does not replace an already-running process. Stop any
    # pre-existing instance so the health request always reaches this release.
    for unit in "${units[@]}"; do
        systemctl stop "${unit}" || cleanup_ok=0
    done
    if [[ "${cleanup_ok}" -ne 1 ]]; then
        warn '无法停止安装前已存在的服务进程'
        report_install_health_failure "${health_started_at}"
    elif
        systemctl start linux-agent-observer-helper.socket linux-agent-web.service
    then
        startup_ok=1
        if wait_for_health >/dev/null; then
            health_ok=1
        else
            warn '新安装版本未在超时时间内通过认证健康检查'
            report_install_health_failure "${health_started_at}"
        fi
    else
        warn '无法启动新安装版本的临时健康检查服务'
        report_install_health_failure "${health_started_at}"
    fi
    for unit in "${units[@]}"; do
        systemctl stop "${unit}" || cleanup_ok=0
    done
    for unit in "${units[@]}"; do
        if systemctl is-active --quiet "${unit}"; then
            cleanup_ok=0
        fi
    done
    [[ "${cleanup_ok}" -eq 1 ]] || return 2
    [[ "${startup_ok}" -eq 1 ]] || return 3
    [[ "${health_ok}" -eq 1 ]]
}

report_install_health_failure() {
    local health_started_at="$1"
    local -a units=(
        linux-agent-web.service
        linux-agent-observer-helper.service
        linux-agent-observer-helper.socket
    )

    warn '以下为安装健康检查失败时的 systemd 状态：'
    systemctl status --no-pager --full "${units[@]}" >&2 || true
    if command -v journalctl >/dev/null 2>&1; then
        warn '以下为本次安装健康检查期间的 journal：'
        journalctl --no-pager --since "${health_started_at}" -n 80 \
            -u linux-agent-web.service \
            -u linux-agent-observer-helper.service \
            -u linux-agent-observer-helper.socket >&2 || true
    fi
}

prune_releases() {
    local current keep_others version line
    local -a candidates=()
    current="$(current_version)"
    keep_others=$((KEEP - 1))
    while IFS= read -r line; do
        [[ -n "${line}" ]] || continue
        version="${line#* }"
        [[ "${version}" == "${current}" ]] && continue
        candidates+=("${version}")
    done < <(
        find "${PREFIX}/releases" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %f\n' |
            sort -k1,1nr -k2,2r
    )
    for ((i = keep_others; i < ${#candidates[@]}; i++)); do
        version="${candidates[$i]}"
        [[ "${version}" =~ ^v[0-9A-Za-z][0-9A-Za-z._-]*$ ]] || continue
        rm -rf -- "${PREFIX}/releases/${version}"
    done
}

rollback_target() {
    local current line i
    local -a history=()
    current="$(current_version)"
    [[ -f "${PREFIX}/releases/.history" ]] || return 1
    mapfile -t history <"${PREFIX}/releases/.history"
    for ((i = ${#history[@]} - 1; i >= 0; i--)); do
        line="${history[$i]}"
        if [[ "${line}" != "${current}" && "${line}" =~ ^v[0-9A-Za-z][0-9A-Za-z._-]*$ &&
            -d "${PREFIX}/releases/${line}" ]]; then
            printf '%s\n' "${line}"
            return 0
        fi
    done
    return 1
}

do_install() {
    local release_dir install_health_status=0
    ensure_prefix
    load_existing_service_identity
    validate_service_identity
    if [[ -e "${PREFIX}/current" || -L "${PREFIX}/current" ]]; then
        fail '检测到已有安装，请使用 upgrade'
    fi
    if read_install_state && [[ "$(jq -r '.installed' "$(install_state_path)")" == "true" ]]; then
        fail '安装状态表明当前前缀仍在使用，请先执行 upgrade 或 uninstall'
    fi
    begin_transaction install "" "${VERSION}"
    prepare_release
    release_dir="${PREPARED_RELEASE_DIR}"
    ensure_service_identity
    capture_systemd_state
    set_config_version "${VERSION}"
    atomic_switch "${VERSION}"
    if [[ "${NO_SYSTEMD}" -eq 0 ]]; then
        install_systemd_unit
        run_install_health_check || install_health_status=$?
        case "${install_health_status}" in
            0) ;;
            1) fail '安装后健康检查失败；临时服务已停止' ;;
            2) fail '安装后无法停止临时健康检查服务' ;;
            3) fail '安装后无法启动临时健康检查服务；临时单元已停止' ;;
            *) fail '安装后临时健康检查失败' ;;
        esac
    fi
    write_install_state true
    commit_transaction
    info "已安装 ${VERSION}: ${release_dir}"
    if [[ "${NO_SYSTEMD}" -eq 0 ]]; then
        info '安装后健康检查已通过，临时服务已停止；安装器未修改原有开机启用状态，需要长期运行时请显式执行 systemctl enable --now linux-agent-observer-helper.socket linux-agent-web.service'
    fi
}

do_upgrade() {
    local old_version release_dir
    ensure_prefix
    load_existing_service_identity
    validate_service_identity
    old_version="$(current_version)" || fail '未检测到现有安装，请先执行 install'
    [[ "${old_version}" != "${VERSION}" ]] || fail '目标版本已经是当前版本'
    begin_transaction upgrade "${old_version}" "${VERSION}"
    prepare_release
    release_dir="${PREPARED_RELEASE_DIR}"
    ensure_service_identity
    capture_systemd_state
    set_config_version "${VERSION}"
    atomic_switch "${VERSION}"
    install_systemd_unit
    if ! restart_and_check; then
        warn "${VERSION} 健康检查失败，正在自动回滚到 ${old_version}"
        fail '升级失败，已恢复旧版本'
    fi
    append_history "${old_version}"
    write_install_state true
    commit_transaction
    prune_releases
    info "已从 ${old_version} 升级到 ${VERSION}: ${release_dir}"
}

do_rollback() {
    local old_version target
    ensure_prefix
    load_existing_service_identity
    validate_service_identity
    old_version="$(current_version)" || fail '未检测到现有安装'
    target="$(rollback_target)" || fail '没有可回滚的历史版本'
    begin_transaction rollback "${old_version}" "${target}"
    ensure_service_identity
    capture_systemd_state
    set_config_version "${target}"
    atomic_switch "${target}"
    install_systemd_unit
    if ! restart_and_check; then
        fail '回滚目标健康检查失败，已恢复原版本'
    fi
    append_history "${old_version}"
    write_install_state true
    commit_transaction
    info "已从 ${old_version} 回滚到 ${target}"
}

do_health() {
    ensure_prefix
    load_existing_service_identity
    validate_service_identity
    health_request || fail '健康检查失败'
}

do_status() {
    local current="" service_status="not-managed" egress_policy="not-managed" releases='[]'
    local helper_socket_status="not-managed" helper_service_status="not-managed"
    local helper_reachable="null" helper_error="" helper_error_file=""
    ensure_prefix
    load_existing_service_identity
    validate_service_identity
    current="$(current_version 2>/dev/null || true)"
    if [[ -d "${PREFIX}/releases" ]]; then
        releases="$(find "${PREFIX}/releases" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' |
            sort | jq -Rsc 'split("\n") | map(select(length > 0))')"
    fi
    if [[ "${NO_SYSTEMD}" -eq 0 ]] && command -v systemctl >/dev/null 2>&1; then
        service_status="$(systemctl is-active linux-agent-web.service 2>/dev/null || true)"
        [[ -n "${service_status}" ]] || service_status="inactive"
        helper_socket_status="$(systemctl is-active linux-agent-observer-helper.socket 2>/dev/null || true)"
        [[ -n "${helper_socket_status}" ]] || helper_socket_status="inactive"
        helper_error_file="$(mktemp)"
        if observer_helper_health_request 2>"${helper_error_file}"; then
            helper_reachable="true"
        else
            helper_reachable="false"
            helper_error="$(sed -n '1,5p' "${helper_error_file}")"
        fi
        rm -f -- "${helper_error_file}"
        helper_service_status="$(systemctl is-active linux-agent-observer-helper.service 2>/dev/null || true)"
        [[ -n "${helper_service_status}" ]] || helper_service_status="inactive"
        if [[ -f "${SYSTEMD_EGRESS_DROPIN_PATH}" && ! -L "${SYSTEMD_EGRESS_DROPIN_PATH}" ]]; then
            egress_policy="enforced"
        else
            egress_policy="unrestricted"
        fi
    fi
    jq -n --arg prefix "${PREFIX}" --arg current "${current}" \
        --arg service_status "${service_status}" --arg egress_policy "${egress_policy}" \
        --arg helper_socket_status "${helper_socket_status}" \
        --arg helper_service_status "${helper_service_status}" \
        --arg helper_error "${helper_error}" --argjson helper_reachable "${helper_reachable}" \
        --argjson releases "${releases}" \
        '{ok:true,status:"installed_status",prefix:$prefix,current_version:$current,releases:$releases,service_status:$service_status,provider_egress_policy:$egress_policy,observer_helper:{socket_status:$helper_socket_status,service_status:$helper_service_status,reachable:$helper_reachable,error:$helper_error}}'
}

stop_and_disable_unit() {
    local unit="$1"
    if systemctl is-active --quiet "${unit}"; then
        systemctl stop "${unit}" || fail "无法停止 systemd 单元: ${unit}"
    fi
    if systemctl is-active --quiet "${unit}"; then
        fail "systemd 单元仍在运行: ${unit}"
    fi
    if systemctl is-enabled --quiet "${unit}"; then
        systemctl disable "${unit}" || fail "无法禁用 systemd 单元: ${unit}"
    fi
}

validate_uninstall_target() {
    local state_path state_installed
    ensure_prefix existing
    state_path="$(install_state_path)"
    if [[ -L "${state_path}" || (-e "${state_path}" && ! -f "${state_path}") ]]; then
        fail "安装状态文件类型非法: ${state_path}"
    fi
    if [[ -f "${state_path}" ]]; then
        read_install_state
        if [[ -n "${INSTALL_STATE_SERVICE_USER}" ]]; then
            SERVICE_USER="${INSTALL_STATE_SERVICE_USER}"
            SERVICE_USER_CREATED="${INSTALL_STATE_SERVICE_USER_CREATED}"
        fi
        [[ "${INSTALL_STATE_NO_SYSTEMD}" -eq "${NO_SYSTEMD}" ]] ||
            fail '当前安装的 systemd 模式与本次参数不一致'
        state_installed="$(jq -r '.installed' "${state_path}")"
        if [[ "${state_installed}" == "true" ]]; then
            current_version >/dev/null || fail '安装状态存在但 current 不是受管版本'
        fi
        return 0
    fi
    current_version >/dev/null || fail '目标前缀不是受管安装，拒绝卸载'
    [[ -x "${PREFIX}/current/bin/agent" ]] || fail '目标前缀缺少受管 Agent 入口，拒绝卸载'
}

do_uninstall() {
    validate_uninstall_target
    if [[ "${NO_SYSTEMD}" -eq 0 ]]; then
        command -v systemctl >/dev/null 2>&1 || fail '缺少 systemctl'
        stop_and_disable_unit linux-agent-web.service
        stop_and_disable_unit linux-agent-observer-helper.socket
        stop_and_disable_unit linux-agent-observer-helper.service
        rm -f -- "${SYSTEMD_UNIT_PATH}" "${SYSTEMD_HELPER_SERVICE_PATH}" "${SYSTEMD_HELPER_SOCKET_PATH}" \
            "${SYSTEMD_EGRESS_DROPIN_PATH}"
        rmdir -- "$(dirname -- "${SYSTEMD_EGRESS_DROPIN_PATH}")" 2>/dev/null || true
        systemctl daemon-reload
    fi
    rm -f -- "${PREFIX}/current"
    rm -rf -- "${PREFIX}/releases"
    if [[ "${PURGE_DATA}" -eq 1 ]]; then
        rm -rf -- "${PREFIX}/data"
        rm -f -- "$(install_state_path)"
        if [[ "${SERVICE_USER_CREATED}" -eq 1 && "${SERVICE_USER}" != "root" &&
            -n "${SERVICE_USER}" ]] && id "${SERVICE_USER}" >/dev/null 2>&1; then
            command -v userdel >/dev/null 2>&1 || fail '缺少 userdel，无法删除安装器创建的服务用户'
            userdel "${SERVICE_USER}" || fail "无法删除安装器创建的服务用户: ${SERVICE_USER}"
        fi
    else
        write_install_state false
    fi
    if [[ -z "$(find "${PREFIX}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
        rmdir -- "${PREFIX}"
    fi
    if [[ "${PURGE_DATA}" -eq 1 ]]; then
        info '已卸载代码并删除持久数据'
    else
        info "已卸载代码，持久数据保留在 ${PREFIX}/data"
    fi
}

case "${COMMAND}" in
    install) do_install ;;
    upgrade) do_upgrade ;;
    rollback) do_rollback ;;
    health) do_health ;;
    status) do_status ;;
    uninstall) do_uninstall ;;
esac
