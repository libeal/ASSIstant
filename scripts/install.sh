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
RUNNER_USER="${LINUX_AGENT_RUNNER_USER:-linux-agent-runner}"
RUNNER_GROUP="${LINUX_AGENT_RUNNER_GROUP:-linux-agent-runner}"
RUNNER_USER_CREATED=0
RUNNER_USER_CREATED_THIS_RUN=0
CREDENTIAL_USER="${LINUX_AGENT_CREDENTIAL_USER:-linux-agent-credential}"
CREDENTIAL_GROUP="${LINUX_AGENT_CREDENTIAL_GROUP:-linux-agent-credential}"
CREDENTIAL_USER_CREATED=0
CREDENTIAL_USER_CREATED_THIS_RUN=0
REQUIRE_SIGNATURE=0
NO_SYSTEMD=0
KEEP=2
PURGE_DATA=0
EGRESS_MODE="preserve"
declare -a PROVIDER_CIDRS=()
WORK_DIR=""
PREPARED_RELEASE_DIR=""
PREPARED_SKILLS_DIR=""
PREPARED_SKILLS_MANIFEST=""
SYSTEMD_UNIT_PATH="${LINUX_AGENT_SYSTEMD_UNIT_PATH:-/etc/systemd/system/linux-agent-web.service}"
SYSTEMD_UNIT_DIR="${SYSTEMD_UNIT_PATH%/*}"
SYSTEMD_HELPER_SERVICE_PATH="${LINUX_AGENT_SYSTEMD_HELPER_SERVICE_PATH:-${SYSTEMD_UNIT_DIR}/linux-agent-observer-helper.service}"
SYSTEMD_HELPER_SOCKET_PATH="${LINUX_AGENT_SYSTEMD_HELPER_SOCKET_PATH:-${SYSTEMD_UNIT_DIR}/linux-agent-observer-helper.socket}"
SYSTEMD_RUNNER_SERVICE_PATH="${LINUX_AGENT_SYSTEMD_RUNNER_SERVICE_PATH:-${SYSTEMD_UNIT_DIR}/linux-agent-runner.service}"
SYSTEMD_RUNNER_SOCKET_PATH="${LINUX_AGENT_SYSTEMD_RUNNER_SOCKET_PATH:-${SYSTEMD_UNIT_DIR}/linux-agent-runner.socket}"
SYSTEMD_MCP_STDIO_SERVICE_PATH="${LINUX_AGENT_SYSTEMD_MCP_STDIO_SERVICE_PATH:-${SYSTEMD_UNIT_DIR}/linux-agent-mcp-stdio.service}"
SYSTEMD_MCP_STDIO_SOCKET_PATH="${LINUX_AGENT_SYSTEMD_MCP_STDIO_SOCKET_PATH:-${SYSTEMD_UNIT_DIR}/linux-agent-mcp-stdio.socket}"
SYSTEMD_HOST_SERVICE_PATH="${LINUX_AGENT_SYSTEMD_HOST_SERVICE_PATH:-${SYSTEMD_UNIT_DIR}/linux-agent-host-ops.service}"
SYSTEMD_HOST_SOCKET_PATH="${LINUX_AGENT_SYSTEMD_HOST_SOCKET_PATH:-${SYSTEMD_UNIT_DIR}/linux-agent-host-ops.socket}"
SYSTEMD_POLICY_SERVICE_PATH="${LINUX_AGENT_SYSTEMD_POLICY_SERVICE_PATH:-${SYSTEMD_UNIT_DIR}/linux-agent-policy-writer.service}"
SYSTEMD_POLICY_SOCKET_PATH="${LINUX_AGENT_SYSTEMD_POLICY_SOCKET_PATH:-${SYSTEMD_UNIT_DIR}/linux-agent-policy-writer.socket}"
SYSTEMD_EGRESS_DROPIN_PATH="${LINUX_AGENT_SYSTEMD_EGRESS_DROPIN_PATH:-${SYSTEMD_UNIT_DIR}/linux-agent-web.service.d/10-provider-egress.conf}"
HOST_OPS_POLICY_PATH="${LINUX_AGENT_HOST_OPS_POLICY_PATH:-/etc/linux-agent/host-ops-policy.json}"
TRANSACTION_MODE=""
TRANSACTION_OLD_VERSION=""
TRANSACTION_TARGET_VERSION=""
TRANSACTION_BACKUP_DIR=""
TRANSACTION_COMMITTED=0
CONFIG_STATE_CAPTURED=0
PERSISTENT_DATA_STATE_CAPTURED=0
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
INSTALL_STATE_RUNNER_USER=""
INSTALL_STATE_RUNNER_USER_CREATED=0
INSTALL_STATE_CREDENTIAL_USER=""
INSTALL_STATE_CREDENTIAL_USER_CREATED=0
INSTALL_STATE_NO_SYSTEMD=0
OBSERVER_STATE_CAPTURED=0
OBSERVER_STATE_EXISTED=0
OBSERVER_STATE_PATH=""
OBSERVER_STATE_BACKUP_PATH=""
BUILTIN_SKILLS_STATE_CAPTURED=0
BUILTIN_SKILLS_EXISTED=0
BUILTIN_SKILL_RELEASES_EXISTED=0
RELEASE_MANIFEST_EXISTED=0
RUNTIME_LOCK_FD=""

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

validate_runtime_compatibility() {
    local curl_help tar_help
    if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3))); then
        fail "Bash 版本过低: ${BASH_VERSION}；需要 Bash 4.3+"
    fi
    python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)' ||
        fail "Python 版本过低: $(python3 -V 2>&1)；需要 Python 3.10+"
    stat -c '%a' / >/dev/null 2>&1 || fail '当前 stat 不支持 GNU -c 选项'
    find / -maxdepth 0 -printf '' >/dev/null 2>&1 || fail '当前 find 不支持 GNU -printf 选项'
    tar_help="$(tar --help 2>&1 || true)"
    grep -q -- '--sort' <<<"${tar_help}" || fail '当前 tar 不支持 GNU --sort 选项'
    date --iso-8601=seconds >/dev/null 2>&1 || fail '当前 date 不支持 GNU --iso-8601 选项'
    curl_help="$(curl --help all 2>/dev/null || curl --help 2>/dev/null || true)"
    grep -q -- '--proto ' <<<"${curl_help}" || fail '当前 curl 不支持 --proto 安全选项'
    grep -q -- '--max-filesize ' <<<"${curl_help}" || fail '当前 curl 不支持 --max-filesize 选项'
}

usage() {
    cat <<'EOF'
用法:
  linux-agent-install.sh install --version vX.Y.Z [选项]
  linux-agent-install.sh upgrade --version vX.Y.Z [选项]
  linux-agent-install.sh rollback [选项]
  linux-agent-install.sh health [--prefix <目录>]
  linux-agent-install.sh repair-observer [--prefix <安装或源码目录>] [--service-user <Web 用户>]
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
    if declare -F release_runtime_transaction_lock >/dev/null 2>&1; then
        release_runtime_transaction_lock
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
    install | upgrade | rollback | health | repair-observer | status | uninstall) ;;
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
if [[ "${LINUX_AGENT_ALLOW_ROOT_SERVICE_USER_FOR_TESTS:-0}" == "1" && "${SERVICE_USER}" == "root" ]]; then
    RUNNER_USER="root"
    RUNNER_GROUP="root"
    CREDENTIAL_USER="root"
    CREDENTIAL_GROUP="root"
fi
[[ "${RUNNER_USER}" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || fail 'Runner 用户格式非法'
[[ "${RUNNER_GROUP}" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || fail 'Runner 用户组格式非法'
[[ "${CREDENTIAL_USER}" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || fail 'Credential helper 用户格式非法'
[[ "${CREDENTIAL_GROUP}" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || fail 'Credential helper 用户组格式非法'
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

command -v flock >/dev/null 2>&1 || fail '缺少依赖命令: flock（请安装 util-linux）'
for command_name in bash curl python3 jq sha256sum stat mktemp readlink cp mv ln mkdir chmod \
    find sort awk tar gzip sed grep date id chown dirname basename seq timeout; do
    command -v "${command_name}" >/dev/null 2>&1 || fail "缺少依赖命令: ${command_name}"
done
validate_runtime_compatibility

if [[ "${NO_SYSTEMD}" -eq 1 && "${EGRESS_MODE}" != "preserve" ]]; then
    fail 'Provider 出站过滤选项仅适用于 systemd 模式'
fi
if [[ "${COMMAND}" == "repair-observer" && "${EGRESS_MODE}" != "preserve" ]]; then
    fail 'repair-observer 不接受 Provider 出站策略选项'
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
    local mode="${1:-create}" persistent_root
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
    for persistent_root in "${PREFIX}/data" "${PREFIX}/releases"; do
        if [[ -L "${persistent_root}" || (-e "${persistent_root}" && ! -d "${persistent_root}") ]]; then
            fail "安装目录边界必须是普通目录且不能是符号链接: ${persistent_root}"
        fi
    done
    if [[ "${NO_SYSTEMD}" -eq 0 ]]; then
        case "${PREFIX}/" in
            /home/* | /root/* | /run/user/* | /tmp/* | /var/tmp/*)
                if [[ "${LINUX_AGENT_ALLOW_UNSAFE_SYSTEMD_TEST_PREFIX:-0}" == "1" &&
                    "${SYSTEMD_UNIT_PATH}" == "${PREFIX}/"* ]]; then
                    warn "仅测试：允许 systemd 沙箱不可见的安装前缀 ${PREFIX}"
                elif [[ "${COMMAND}" == "repair-observer" &&
                    -x "${PREFIX}/bin/agent-web" &&
                    -f "${PREFIX}/lib/observer_helper.py" &&
                    -f "${PREFIX}/packaging/linux-agent-observer-helper.socket" ]]; then
                    :
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

assert_plain_directory() {
    local path="$1"
    [[ -L "${path}" || (-e "${path}" && ! -d "${path}") ]] && return 1
    return 0
}

assert_plain_file() {
    local path="$1"
    [[ -L "${path}" || (-e "${path}" && ! -f "${path}") ]] && return 1
    return 0
}

acquire_runtime_transaction_lock() {
    local lock_path="${PREFIX}/data/.runtime.lock"
    [[ -z "${RUNTIME_LOCK_FD}" ]] || return 0
    mkdir -p -- "${PREFIX}/data"
    assert_plain_file "${lock_path}" || fail "runtime 事务锁类型非法: ${lock_path}"
    if [[ ! -e "${lock_path}" ]]; then
        (umask 077 && set -C && : >"${lock_path}") 2>/dev/null || true
    fi
    assert_plain_file "${lock_path}" || fail '无法安全创建 runtime 事务锁'
    exec {RUNTIME_LOCK_FD}<>"${lock_path}" || fail '无法打开 runtime 事务锁'
    flock -x "${RUNTIME_LOCK_FD}" || fail '无法取得 runtime 安装事务锁'
}

release_runtime_transaction_lock() {
    if [[ -n "${RUNTIME_LOCK_FD:-}" ]]; then
        flock -u "${RUNTIME_LOCK_FD}" 2>/dev/null || true
        exec {RUNTIME_LOCK_FD}>&-
        RUNTIME_LOCK_FD=""
    fi
}

fsync_file_and_directory() {
    local file_path="$1"
    local directory_path="${2:-$(dirname -- "${file_path}")}"
    python3 - "${file_path}" "${directory_path}" <<'PY'
import os
import sys

file_path, directory_path = sys.argv[1:]
file_descriptor = os.open(file_path, os.O_RDONLY)
try:
    os.fsync(file_descriptor)
finally:
    os.close(file_descriptor)
directory_descriptor = os.open(directory_path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
try:
    os.fsync(directory_descriptor)
finally:
    os.close(directory_descriptor)
PY
}

atomic_copy_regular_file() {
    local source="$1"
    local target="$2"
    local mode="${3:-0644}"
    local parent temp
    parent="$(dirname -- "${target}")"
    assert_plain_directory "${parent}" || return 1
    assert_plain_file "${source}" || return 1
    assert_plain_file "${target}" || return 1
    temp="$(mktemp "${parent}/.${target##*/}.XXXXXX")" || return 1
    if ! cp -- "${source}" "${temp}" || ! chmod "${mode}" "${temp}" ||
        ! fsync_file_and_directory "${temp}" "${parent}" ||
        ! mv -f -- "${temp}" "${target}" ||
        ! fsync_file_and_directory "${target}" "${parent}"; then
        rm -f -- "${temp}"
        return 1
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
        and ((has("runner_user") | not) or (.runner_user | type == "string" and (. == "" or test("^[a-z_][a-z0-9_-]*[$]?$"))))
        and ((has("runner_user_created") | not) or (.runner_user_created | type == "boolean"))
        and (.credential_user | type == "string" and (. == "" or test("^[a-z_][a-z0-9_-]*[$]?$")))
        and (.credential_user_created | type == "boolean")
    ' "${state_path}" >/dev/null || fail '安装状态文件契约无效'
    INSTALL_STATE_SERVICE_USER="$(jq -er '.service_user' "${state_path}")"
    INSTALL_STATE_SERVICE_USER_CREATED="$(jq -er 'if .service_user_created then 1 else 0 end' "${state_path}")"
    INSTALL_STATE_RUNNER_USER="$(jq -r '.runner_user // ""' "${state_path}")"
    INSTALL_STATE_RUNNER_USER_CREATED="$(jq -r 'if .runner_user_created // false then 1 else 0 end' "${state_path}")"
    INSTALL_STATE_CREDENTIAL_USER="$(jq -r '.credential_user' "${state_path}")"
    INSTALL_STATE_CREDENTIAL_USER_CREATED="$(jq -r 'if .credential_user_created then 1 else 0 end' "${state_path}")"
    INSTALL_STATE_NO_SYSTEMD="$(jq -er 'if .no_systemd then 1 else 0 end' "${state_path}")"
    return 0
}

validate_service_identity() {
    local uid
    [[ "${SERVICE_USER}" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || fail '--service-user 格式非法'
    if [[ "${NO_SYSTEMD}" -eq 1 ]]; then
        if [[ "${SERVICE_USER_EXPLICIT}" -eq 0 && -z "${INSTALL_STATE_SERVICE_USER}" ]]; then
            return 0
        fi
        id "${SERVICE_USER}" >/dev/null 2>&1 || fail "无 systemd 运行用户不存在: ${SERVICE_USER}"
        return 0
    fi
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
        if [[ -n "${INSTALL_STATE_RUNNER_USER}" ]]; then
            RUNNER_USER="${INSTALL_STATE_RUNNER_USER}"
            RUNNER_USER_CREATED="${INSTALL_STATE_RUNNER_USER_CREATED}"
            if id "${RUNNER_USER}" >/dev/null 2>&1; then
                RUNNER_GROUP="$(id -gn "${RUNNER_USER}")"
            fi
        fi
        if [[ -n "${INSTALL_STATE_CREDENTIAL_USER}" ]]; then
            CREDENTIAL_USER="${INSTALL_STATE_CREDENTIAL_USER}"
            CREDENTIAL_USER_CREATED="${INSTALL_STATE_CREDENTIAL_USER_CREATED}"
            if id "${CREDENTIAL_USER}" >/dev/null 2>&1; then
                CREDENTIAL_GROUP="$(id -gn "${CREDENTIAL_USER}")"
            fi
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
    local state_path state_tmp service_user="${SERVICE_USER}"
    state_path="$(install_state_path)"
    state_tmp="$(mktemp "${PREFIX}/.install-state.XXXXXX")"
    jq -S -n \
        --arg prefix "${PREFIX}" \
        --arg service_user "${service_user}" \
        --arg runner_user "$([[ "${NO_SYSTEMD}" -eq 0 ]] && printf '%s' "${RUNNER_USER}" || printf '')" \
        --arg credential_user "$([[ "${NO_SYSTEMD}" -eq 0 ]] && printf '%s' "${CREDENTIAL_USER}" || printf '')" \
        --argjson installed "${installed}" \
        --argjson no_systemd "$([[ "${NO_SYSTEMD}" -eq 1 ]] && printf true || printf false)" \
        --argjson service_user_created "$([[ "${NO_SYSTEMD}" -eq 0 && "${SERVICE_USER_CREATED}" -eq 1 ]] && printf true || printf false)" \
        --argjson runner_user_created "$([[ "${NO_SYSTEMD}" -eq 0 && "${RUNNER_USER_CREATED}" -eq 1 ]] && printf true || printf false)" \
        --argjson credential_user_created "$([[ "${NO_SYSTEMD}" -eq 0 && "${CREDENTIAL_USER_CREATED}" -eq 1 ]] && printf true || printf false)" \
        '{schema_version:1,prefix:$prefix,installed:$installed,no_systemd:$no_systemd,service_user:$service_user,service_user_created:$service_user_created,runner_user:$runner_user,runner_user_created:$runner_user_created,credential_user:$credential_user,credential_user_created:$credential_user_created}' \
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
    local state_path

    TRANSACTION_MODE="${mode}"
    TRANSACTION_OLD_VERSION="${old_version}"
    TRANSACTION_TARGET_VERSION="${target_version}"
    TRANSACTION_COMMITTED=0
    CONFIG_STATE_CAPTURED=0
    PERSISTENT_DATA_STATE_CAPTURED=0
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
    OBSERVER_STATE_CAPTURED=0
    OBSERVER_STATE_EXISTED=0
    OBSERVER_STATE_PATH=""
    OBSERVER_STATE_BACKUP_PATH=""
    BUILTIN_SKILLS_STATE_CAPTURED=0
    BUILTIN_SKILLS_EXISTED=0
    BUILTIN_SKILL_RELEASES_EXISTED=0
    RELEASE_MANIFEST_EXISTED=0
    SERVICE_USER_CREATED_THIS_RUN=0
    RUNNER_USER_CREATED_THIS_RUN=0
    CREDENTIAL_USER_CREATED_THIS_RUN=0
    TRANSACTION_BACKUP_DIR="$(mktemp -d "${PREFIX}/.install-rollback.XXXXXX")"
    chmod 0700 "${TRANSACTION_BACKUP_DIR}"
    mkdir -p "${TRANSACTION_BACKUP_DIR}/config"
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

capture_persistent_data_state() {
    local name source backup unsafe marker marker_backup ledger ledger_backup
    mkdir -p "${TRANSACTION_BACKUP_DIR}/config" "${TRANSACTION_BACKUP_DIR}/persistent"

    assert_plain_directory "${PREFIX}/data" ||
        fail "持久数据目录类型非法: ${PREFIX}/data"
    assert_plain_directory "${PREFIX}/data/config" ||
        fail "持久配置目录类型非法: ${PREFIX}/data/config"

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

    : >"${TRANSACTION_BACKUP_DIR}/persistent/directories.tsv"
    for name in skills policies migration-reports migration-conflicts; do
        source="${PREFIX}/data/${name}"
        backup="${TRANSACTION_BACKUP_DIR}/persistent/${name}"
        if [[ -L "${source}" || (-e "${source}" && ! -d "${source}") ]]; then
            fail "持久数据备份源类型非法: ${source}"
        fi
        if [[ -d "${source}" ]]; then
            unsafe="$(find "${source}" -mindepth 1 \( -type l -o -type b -o -type c -o -type p -o -type s \) -print -quit)"
            [[ -z "${unsafe}" ]] || fail "持久数据包含不安全文件类型: ${unsafe}"
            cp -a -- "${source}" "${backup}"
            printf '%s\t1\n' "${name}" >>"${TRANSACTION_BACKUP_DIR}/persistent/directories.tsv"
        else
            printf '%s\t0\n' "${name}" >>"${TRANSACTION_BACKUP_DIR}/persistent/directories.tsv"
        fi
    done

    marker="${PREFIX}/data/.overlay-layout-v1.json"
    marker_backup="${TRANSACTION_BACKUP_DIR}/persistent/overlay-layout-v1.json"
    if [[ -L "${marker}" || (-e "${marker}" && ! -f "${marker}") ]]; then
        fail "overlay 布局标记类型非法: ${marker}"
    fi
    if [[ -f "${marker}" ]]; then
        cp -p -- "${marker}" "${marker_backup}"
        printf '1\n' >"${TRANSACTION_BACKUP_DIR}/persistent/marker-existed"
    else
        printf '0\n' >"${TRANSACTION_BACKUP_DIR}/persistent/marker-existed"
    fi
    ledger="${PREFIX}/data/skill-components.json"
    ledger_backup="${TRANSACTION_BACKUP_DIR}/persistent/skill-components.json"
    if [[ -L "${ledger}" || (-e "${ledger}" && ! -f "${ledger}") ]]; then
        fail "Skill component ownership ledger 类型非法: ${ledger}"
    fi
    if [[ -f "${ledger}" ]]; then
        cp -p -- "${ledger}" "${ledger_backup}"
        printf '1\n' >"${TRANSACTION_BACKUP_DIR}/persistent/skill-components-existed"
    else
        printf '0\n' >"${TRANSACTION_BACKUP_DIR}/persistent/skill-components-existed"
    fi
    PERSISTENT_DATA_STATE_CAPTURED=1
}

capture_builtin_skills_state() {
    local skills_root="${PREFIX}/skills"
    local skill_releases_root="${PREFIX}/skill-releases"
    local release_manifest="${PREFIX}/release-manifest.json"
    local unsafe
    [[ "${BUILTIN_SKILLS_STATE_CAPTURED}" -eq 0 ]] || return 0
    if [[ -L "${skills_root}" || (-e "${skills_root}" && ! -d "${skills_root}") ]]; then
        fail "内置 Skill 根目录类型非法: ${skills_root}"
    fi
    if [[ -d "${skills_root}" ]]; then
        unsafe="$(find "${skills_root}" -mindepth 1 \( -type l -o -type b -o -type c -o -type p -o -type s \) -print -quit)"
        [[ -z "${unsafe}" ]] || fail "内置 Skill 根目录包含不安全文件类型: ${unsafe}"
        cp -a -- "${skills_root}" "${TRANSACTION_BACKUP_DIR}/builtin-skills"
        BUILTIN_SKILLS_EXISTED=1
    fi
    if [[ -L "${skill_releases_root}" ||
        (-e "${skill_releases_root}" && ! -d "${skill_releases_root}") ]]; then
        fail "内置 Skill 版本快照根目录类型非法: ${skill_releases_root}"
    fi
    if [[ -d "${skill_releases_root}" ]]; then
        unsafe="$(find "${skill_releases_root}" -mindepth 1 \( -type l -o -type b -o -type c -o -type p -o -type s \) -print -quit)"
        [[ -z "${unsafe}" ]] || fail "内置 Skill 版本快照包含不安全文件类型: ${unsafe}"
        cp -a -- "${skill_releases_root}" \
            "${TRANSACTION_BACKUP_DIR}/builtin-skill-releases"
        BUILTIN_SKILL_RELEASES_EXISTED=1
    fi
    if [[ -L "${release_manifest}" || (-e "${release_manifest}" && ! -f "${release_manifest}") ]]; then
        fail "release manifest 类型非法: ${release_manifest}"
    fi
    if [[ -f "${release_manifest}" ]]; then
        cp -p -- "${release_manifest}" "${TRANSACTION_BACKUP_DIR}/release-manifest.json"
        RELEASE_MANIFEST_EXISTED=1
    fi
    BUILTIN_SKILLS_STATE_CAPTURED=1
}

restore_builtin_skills_state() {
    local skills_root="${PREFIX}/skills"
    local skill_releases_root="${PREFIX}/skill-releases"
    local release_manifest="${PREFIX}/release-manifest.json"
    [[ "${BUILTIN_SKILLS_STATE_CAPTURED}" -eq 1 ]] || return 0
    if [[ -L "${skills_root}" || (-e "${skills_root}" && ! -d "${skills_root}") ]]; then
        return 1
    fi
    rm -rf -- "${skills_root}" || return 1
    if [[ "${BUILTIN_SKILLS_EXISTED}" -eq 1 ]]; then
        cp -a -- "${TRANSACTION_BACKUP_DIR}/builtin-skills" "${skills_root}" || return 1
    fi
    if [[ -L "${skill_releases_root}" ||
        (-e "${skill_releases_root}" && ! -d "${skill_releases_root}") ]]; then
        return 1
    fi
    rm -rf -- "${skill_releases_root}" || return 1
    if [[ "${BUILTIN_SKILL_RELEASES_EXISTED}" -eq 1 ]]; then
        cp -a -- "${TRANSACTION_BACKUP_DIR}/builtin-skill-releases" \
            "${skill_releases_root}" || return 1
    fi
    if [[ "${RELEASE_MANIFEST_EXISTED}" -eq 1 ]]; then
        cp -p -- "${TRANSACTION_BACKUP_DIR}/release-manifest.json" "${release_manifest}" || return 1
    else
        rm -f -- "${release_manifest}" || return 1
    fi
}

install_prepared_builtin_skills() {
    local target="${PREFIX}/skills"
    local staging="${PREFIX}/.skills.install.$$"
    local previous="${PREFIX}/.skills.previous.$$"
    local manifest="${PREPARED_SKILLS_MANIFEST:-${WORK_DIR}/release-manifest.json}"
    local history_root="${PREFIX}/skill-releases"
    local history_target="" history_staging=""
    [[ -n "${PREPARED_SKILLS_DIR}" && -d "${PREPARED_SKILLS_DIR}" &&
        ! -L "${PREPARED_SKILLS_DIR}" ]] || fail '内置 Skill staging 不可用'
    [[ -f "${PREPARED_SKILLS_DIR}/INDEX.md" && ! -L "${PREPARED_SKILLS_DIR}/INDEX.md" ]] ||
        fail '内置 Skill staging 缺少 INDEX.md'
    [[ -f "${manifest}" && ! -L "${manifest}" ]] ||
        fail '内置 Skill staging 缺少对应的签名 release manifest'
    [[ ! -e "${staging}" && ! -L "${staging}" &&
        ! -e "${previous}" && ! -L "${previous}" ]] ||
        fail '内置 Skill 原子安装路径已被占用'
    cp -a -- "${PREPARED_SKILLS_DIR}" "${staging}"
    find "${staging}" -type d -exec chmod 0755 -- {} +
    find "${staging}" -type f -exec chmod 0644 -- {} +
    if [[ "${NO_SYSTEMD}" -eq 0 ]]; then
        chown -R root:root "${staging}"
    fi
    if [[ -n "${TRANSACTION_OLD_VERSION}" && -d "${target}" && ! -L "${target}" ]]; then
        [[ "${TRANSACTION_OLD_VERSION}" =~ ^v[0-9A-Za-z][0-9A-Za-z._-]*$ ]] ||
            fail '内置 Skill 快照版本非法'
        [[ ! -L "${history_root}" &&
            (! -e "${history_root}" || -d "${history_root}") ]] ||
            fail '内置 Skill 版本快照根目录类型非法'
        mkdir -p -- "${history_root}"
        history_target="${history_root}/${TRANSACTION_OLD_VERSION}"
        history_staging="${history_root}/.${TRANSACTION_OLD_VERSION}.$$"
        [[ ! -e "${history_staging}" && ! -L "${history_staging}" ]] ||
            fail '内置 Skill 版本快照 staging 已被占用'
        mkdir -- "${history_staging}"
        cp -a -- "${target}" "${history_staging}/skills"
        if [[ -f "${PREFIX}/release-manifest.json" &&
            ! -L "${PREFIX}/release-manifest.json" ]]; then
            cp -p -- "${PREFIX}/release-manifest.json" \
                "${history_staging}/release-manifest.json"
        else
            fail '当前内置 Skill 缺少对应的 release manifest'
        fi
        if [[ -e "${history_target}" || -L "${history_target}" ]]; then
            [[ -d "${history_target}" && ! -L "${history_target}" ]] ||
                fail '现有内置 Skill 版本快照类型非法'
            rm -rf -- "${history_target}"
        fi
        mv -- "${history_staging}" "${history_target}"
        python3 -c 'import os,sys; fd=os.open(sys.argv[1], os.O_RDONLY | os.O_DIRECTORY); os.fsync(fd); os.close(fd)' "${history_root}" ||
            fail '内置 Skill 版本快照 fsync 失败'
    fi
    if [[ -d "${target}" && ! -L "${target}" ]]; then
        mv -- "${target}" "${previous}"
    elif [[ -e "${target}" || -L "${target}" ]]; then
        fail "内置 Skill 根目录类型非法: ${target}"
    fi
    if ! mv -- "${staging}" "${target}"; then
        [[ ! -d "${previous}" ]] || mv -- "${previous}" "${target}"
        fail '内置 Skill 原子提交失败'
    fi
    python3 -c 'import os,sys; fd=os.open(sys.argv[1], os.O_RDONLY | os.O_DIRECTORY); os.fsync(fd); os.close(fd)' "${PREFIX}" ||
        fail '内置 Skill 根目录 fsync 失败'
    rm -rf -- "${previous}"
    atomic_copy_regular_file "${manifest}" "${PREFIX}/release-manifest.json" 0644 ||
        fail '无法持久化签名 release manifest'
    if [[ "${NO_SYSTEMD}" -eq 0 ]]; then
        chown root:root "${PREFIX}/release-manifest.json"
    fi
}

capture_systemd_state() {
    local path backup_name existed_var egress_dir unit enabled active _package component
    local _client _socket_env _socket_path _service_asset socket_asset _egress_dropin
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
    mkdir -p "${TRANSACTION_BACKUP_DIR}/systemd-extra"
    : >"${TRANSACTION_BACKUP_DIR}/systemd-extra/files.tsv"
    while IFS=$'\t' read -r path backup_name; do
        if [[ -L "${path}" || (-e "${path}" && ! -f "${path}") ]]; then
            fail "现有 systemd unit 类型非法: ${path}"
        fi
        if [[ -f "${path}" ]]; then
            cp -p -- "${path}" "${TRANSACTION_BACKUP_DIR}/systemd-extra/${backup_name}"
            printf '%s\t%s\t1\n' "${path}" "${backup_name}" >>"${TRANSACTION_BACKUP_DIR}/systemd-extra/files.tsv"
        else
            printf '%s\t%s\t0\n' "${path}" "${backup_name}" >>"${TRANSACTION_BACKUP_DIR}/systemd-extra/files.tsv"
        fi
    done <<EOF
${SYSTEMD_RUNNER_SERVICE_PATH}	linux-agent-runner.service
${SYSTEMD_RUNNER_SOCKET_PATH}	linux-agent-runner.socket
${SYSTEMD_MCP_STDIO_SERVICE_PATH}	linux-agent-mcp-stdio.service
${SYSTEMD_MCP_STDIO_SOCKET_PATH}	linux-agent-mcp-stdio.socket
${SYSTEMD_HOST_SERVICE_PATH}	linux-agent-host-ops.service
${SYSTEMD_HOST_SOCKET_PATH}	linux-agent-host-ops.socket
${SYSTEMD_POLICY_SERVICE_PATH}	linux-agent-policy-writer.service
${SYSTEMD_POLICY_SOCKET_PATH}	linux-agent-policy-writer.socket
${HOST_OPS_POLICY_PATH}	host-ops-policy.json
EOF
    : >"${TRANSACTION_BACKUP_DIR}/systemd-extra/credential-files.tsv"
    while IFS=$'\t' read -r path backup_name; do
        [[ -n "${path}" ]] || continue
        if [[ -L "${path}" || (-e "${path}" && ! -f "${path}") ]]; then
            fail "现有 Skill credential component 文件类型非法: ${path}"
        fi
        if [[ -f "${path}" ]]; then
            cp -p -- "${path}" "${TRANSACTION_BACKUP_DIR}/systemd-extra/${backup_name}"
            printf '%s\t%s\t1\n' "${path}" "${backup_name}" \
                >>"${TRANSACTION_BACKUP_DIR}/systemd-extra/files.tsv"
            printf '%s\n' "${path}" \
                >>"${TRANSACTION_BACKUP_DIR}/systemd-extra/credential-files.tsv"
        else
            printf '%s\t%s\t0\n' "${path}" "${backup_name}" \
                >>"${TRANSACTION_BACKUP_DIR}/systemd-extra/files.tsv"
            printf '%s\n' "${path}" \
                >>"${TRANSACTION_BACKUP_DIR}/systemd-extra/credential-files.tsv"
        fi
    done < <(transaction_credential_file_rows)
    : >"${TRANSACTION_BACKUP_DIR}/systemd-extra/runtime.tsv"
    for unit in linux-agent-runner.socket linux-agent-mcp-stdio.socket \
        linux-agent-host-ops.socket linux-agent-policy-writer.socket; do
        enabled=0
        active=0
        systemctl is-enabled --quiet "${unit}" >/dev/null 2>&1 && enabled=1
        systemctl is-active --quiet "${unit}" >/dev/null 2>&1 && active=1
        printf '%s\t%s\t%s\n' "${unit}" "${enabled}" "${active}" >>"${TRANSACTION_BACKUP_DIR}/systemd-extra/runtime.tsv"
    done
    while IFS=$'\t' read -r _package component _client _socket_env _socket_path \
        _service_asset socket_asset _egress_dropin; do
        [[ -n "${component}" ]] || continue
        unit="$(basename -- "${socket_asset}")"
        grep -Fq "${unit}"$'\t' "${TRANSACTION_BACKUP_DIR}/systemd-extra/runtime.tsv" && continue
        enabled=0
        active=0
        systemctl is-enabled --quiet "${unit}" >/dev/null 2>&1 && enabled=1
        systemctl is-active --quiet "${unit}" >/dev/null 2>&1 && active=1
        printf '%s\t%s\t%s\n' "${unit}" "${enabled}" "${active}" \
            >>"${TRANSACTION_BACKUP_DIR}/systemd-extra/runtime.tsv"
    done < <(transaction_credential_component_rows | sort -u)
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

stop_transaction_services() {
    local unit _package _component _client _socket_env _socket_path service_asset socket_asset
    local _egress_dropin
    [[ "${NO_SYSTEMD}" -eq 0 ]] || return 0
    for unit in \
        linux-agent-web.service \
        linux-agent-observer-helper.service linux-agent-observer-helper.socket \
        linux-agent-runner.service linux-agent-runner.socket \
        linux-agent-mcp-stdio.service linux-agent-mcp-stdio.socket \
        linux-agent-host-ops.service linux-agent-host-ops.socket \
        linux-agent-policy-writer.service linux-agent-policy-writer.socket; do
        if systemctl is-active --quiet "${unit}" >/dev/null 2>&1; then
            systemctl stop "${unit}" || fail "升级事务无法停止正在运行的 unit: ${unit}"
        fi
    done
    while IFS=$'\t' read -r _package _component _client _socket_env _socket_path \
        service_asset socket_asset _egress_dropin; do
        for unit in "$(basename -- "${service_asset}")" "$(basename -- "${socket_asset}")"; do
            if systemctl is-active --quiet "${unit}" >/dev/null 2>&1; then
                systemctl stop "${unit}" ||
                    fail "升级事务无法停止 Skill credential component unit: ${unit}"
            fi
        done
    done < <(transaction_credential_component_rows | sort -u)
}

restore_persistent_config() {
    local name backup target config_root
    [[ "${CONFIG_STATE_CAPTURED}" -eq 1 ]] || return 0
    config_root="${PREFIX}/data/config"
    assert_plain_directory "${PREFIX}/data" || return 1
    assert_plain_directory "${config_root}" || return 1
    mkdir -p "${config_root}"
    for name in config.json config.example.json ai-providers.json; do
        backup="${TRANSACTION_BACKUP_DIR}/config/${name}"
        target="${config_root}/${name}"
        assert_plain_file "${target}" || return 1
        if [[ -f "${backup}" ]]; then
            atomic_copy_regular_file "${backup}" "${target}" "$(stat -c '%a' "${backup}")" || return 1
        else
            rm -f -- "${target}" || return 1
        fi
    done
}

restore_persistent_data() {
    local name existed backup target marker marker_backup marker_existed
    local ledger ledger_backup ledger_existed
    [[ "${PERSISTENT_DATA_STATE_CAPTURED}" -eq 1 ]] || return 0
    while IFS=$'\t' read -r name existed; do
        case "${name}" in
            skills | policies | migration-reports | migration-conflicts) ;;
            *)
                warn "忽略未知持久数据回滚项: ${name}"
                continue
                ;;
        esac
        backup="${TRANSACTION_BACKUP_DIR}/persistent/${name}"
        target="${PREFIX}/data/${name}"
        if [[ -L "${target}" || (-e "${target}" && ! -d "${target}") ]]; then
            return 1
        fi
        rm -rf -- "${target}" || return 1
        if [[ "${existed}" -eq 1 ]]; then
            cp -a -- "${backup}" "${target}" || return 1
        fi
    done <"${TRANSACTION_BACKUP_DIR}/persistent/directories.tsv"

    marker="${PREFIX}/data/.overlay-layout-v1.json"
    marker_backup="${TRANSACTION_BACKUP_DIR}/persistent/overlay-layout-v1.json"
    marker_existed="$(<"${TRANSACTION_BACKUP_DIR}/persistent/marker-existed")"
    if [[ "${marker_existed}" -eq 1 ]]; then
        cp -p -- "${marker_backup}" "${marker}" || return 1
    else
        rm -f -- "${marker}"
    fi
    ledger="${PREFIX}/data/skill-components.json"
    ledger_backup="${TRANSACTION_BACKUP_DIR}/persistent/skill-components.json"
    ledger_existed="$(<"${TRANSACTION_BACKUP_DIR}/persistent/skill-components-existed")"
    if [[ "${ledger_existed}" -eq 1 ]]; then
        cp -p -- "${ledger_backup}" "${ledger}" || return 1
    else
        rm -f -- "${ledger}" || return 1
    fi
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
    local path backup_name existed unit enabled active
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
    if [[ -f "${TRANSACTION_BACKUP_DIR}/systemd-extra/files.tsv" ]]; then
        while IFS=$'\t' read -r path backup_name existed; do
            [[ -n "${path}" ]] || continue
            if [[ "${existed}" -eq 1 ]]; then
                cp -p -- "${TRANSACTION_BACKUP_DIR}/systemd-extra/${backup_name}" "${path}"
            else
                rm -f -- "${path}"
            fi
        done <"${TRANSACTION_BACKUP_DIR}/systemd-extra/files.tsv"
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
    if [[ -f "${TRANSACTION_BACKUP_DIR}/systemd-extra/runtime.tsv" ]]; then
        while IFS=$'\t' read -r unit enabled active; do
            [[ -n "${unit}" ]] || continue
            if [[ "${enabled}" -eq 1 ]]; then
                systemctl enable "${unit}" >/dev/null 2>&1 || warn "无法恢复 ${unit} enabled 状态"
            else
                systemctl disable "${unit}" >/dev/null 2>&1 || true
            fi
            if [[ "${active}" -eq 1 ]]; then
                systemctl start "${unit}" >/dev/null 2>&1 || warn "无法恢复 ${unit} active 状态"
            else
                systemctl stop "${unit}" >/dev/null 2>&1 || true
            fi
        done <"${TRANSACTION_BACKUP_DIR}/systemd-extra/runtime.tsv"
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
    local current_target="" link_tmp unit _package _component _client _socket_env
    local _socket_path _service_asset socket_asset _egress_dropin

    [[ -n "${TRANSACTION_MODE}" && "${TRANSACTION_COMMITTED}" -eq 0 ]] || return 0
    TRANSACTION_COMMITTED=1
    current_target="$(readlink -- "${PREFIX}/current" 2>/dev/null || true)"

    if [[ "${NO_SYSTEMD}" -eq 0 && "${SYSTEMD_STATE_CAPTURED}" -eq 1 &&
        "${current_target}" == "releases/${TRANSACTION_TARGET_VERSION}" ]]; then
        systemctl stop linux-agent-web.service >/dev/null 2>&1 || true
        systemctl stop linux-agent-observer-helper.socket linux-agent-runner.socket \
            linux-agent-mcp-stdio.socket \
            linux-agent-host-ops.socket linux-agent-policy-writer.socket >/dev/null 2>&1 || true
        while IFS=$'\t' read -r _package _component _client _socket_env _socket_path \
            _service_asset socket_asset _egress_dropin; do
            unit="$(basename -- "${socket_asset}")"
            systemctl stop "${unit}" >/dev/null 2>&1 || true
        done < <(transaction_credential_component_rows | sort -u)
    fi
    acquire_runtime_transaction_lock

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
    restore_persistent_data || warn '无法完整恢复 Skill/策略 overlay'
    restore_builtin_skills_state || warn '无法完整恢复内置 Skill 安装集合'
    restore_install_state || warn '无法完整恢复安装状态'
    restore_observer_helper_state || warn '无法恢复 observer helper capability 状态'
    restore_systemd_state || warn '无法完整恢复 systemd unit 状态'

    if [[ "${RUNNER_USER_CREATED_THIS_RUN}" -eq 1 &&
        "${NO_SYSTEMD}" -eq 0 && "${RUNNER_USER}" != "root" ]]; then
        if command -v userdel >/dev/null 2>&1 && id "${RUNNER_USER}" >/dev/null 2>&1; then
            userdel "${RUNNER_USER}" >/dev/null 2>&1 ||
                warn "安装失败后无法删除本次创建的 Runner 用户: ${RUNNER_USER}"
        fi
    fi
    RUNNER_USER_CREATED_THIS_RUN=0
    if [[ "${CREDENTIAL_USER_CREATED_THIS_RUN}" -eq 1 &&
        "${NO_SYSTEMD}" -eq 0 && "${CREDENTIAL_USER}" != "root" ]]; then
        if command -v userdel >/dev/null 2>&1 && id "${CREDENTIAL_USER}" >/dev/null 2>&1; then
            userdel "${CREDENTIAL_USER}" >/dev/null 2>&1 ||
                warn "安装失败后无法删除本次创建的 credential helper 用户: ${CREDENTIAL_USER}"
        fi
    fi
    CREDENTIAL_USER_CREATED_THIS_RUN=0

    if [[ "${SERVICE_USER_CREATED_THIS_RUN}" -eq 1 &&
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
    release_runtime_transaction_lock
}

commit_transaction() {
    TRANSACTION_COMMITTED=1
    TRANSACTION_MODE=""
    if [[ -n "${TRANSACTION_BACKUP_DIR}" && -d "${TRANSACTION_BACKUP_DIR}" ]]; then
        rm -rf -- "${TRANSACTION_BACKUP_DIR}"
    fi
    TRANSACTION_BACKUP_DIR=""
    release_runtime_transaction_lock
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
    local config_dir config_tmp expected_uid expected_gid
    config_dir="$(dirname -- "${config_path}")"
    assert_plain_directory "${PREFIX}/data" || fail '持久数据目录类型非法'
    assert_plain_directory "${config_dir}" || fail '持久配置目录类型非法'
    [[ -f "${config_path}" && ! -L "${config_path}" ]] || fail '持久配置文件缺失或类型非法'
    config_tmp="$(mktemp "${config_dir}/.${config_path##*/}.XXXXXX")" ||
        fail '无法创建持久配置 staging 文件'
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
    fsync_file_and_directory "${config_tmp}" "${config_dir}" || {
        rm -f -- "${config_tmp}"
        fail '无法持久化 release 版本 staging 文件'
    }
    [[ -f "${config_path}" && ! -L "${config_path}" ]] || {
        rm -f -- "${config_tmp}"
        fail '持久配置文件在更新期间发生类型变化'
    }
    mv -f -- "${config_tmp}" "${config_path}"
    fsync_file_and_directory "${config_path}" "${config_dir}" ||
        fail '持久配置 release 版本落盘失败'
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
    local manifest_schema
    manifest_schema="$(jq -r '.schema_version // empty' "${manifest}" 2>/dev/null || true)"
    [[ "${manifest_schema}" != "1" ]] || fail 'release manifest schema v1 已不受支持；请使用 schema v2 发布物'
    jq -e --arg repository "${REPOSITORY}" --arg version "${VERSION}" '
        def valid_asset:
            type == "object"
            and (.name | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]+$"))
            and (.sha256 | type == "string" and test("^[0-9a-f]{64}$"))
            and (.size_bytes | type == "number" and floor == . and . > 0)
            and (.max_size_bytes | type == "number" and floor == . and . >= 1)
            and (.size_bytes <= .max_size_bytes)
            and (.max_size_bytes <= 52428800);
        . as $release
        | type == "object"
        and .schema_version == 2
        and .repository == $repository
        and .version == $version
        and (.assets | type == "object")
        and (.assets.core | valid_asset)
        and (.assets.web | valid_asset)
        and (.assets.mcp_sdk | valid_asset)
        and (.assets.installer | valid_asset)
        and ([.assets[] | valid_asset] | all)
        and (.assets.installer.name == "linux-agent-install.sh")
        and .core_contents == {builtin_skill_index:true,builtin_skill_packages:false}
        and (.skills | type == "object")
        and ([.skills | to_entries[] | . as $skill | select(
            ($skill.key | test("^[a-z0-9][a-z0-9-]*$") | not)
            or (($skill.value | type) != "object")
            or (($skill.value.description | type) != "string" or ($skill.value.description | length) == 0)
            or (($skill.value.category | type) != "string" or ($skill.value.category | test("^[a-z0-9][a-z0-9-]{0,63}$") | not))
            or ($skill.value.risk | IN("low", "medium", "high", "critical") | not)
            or ($skill.value.asset | valid_asset | not)
            or (($skill.value.contract_digest | type) != "string" or ($skill.value.contract_digest | test("^[0-9a-f]{64}$") | not))
            or (($skill.value.index_section_digest | type) != "string" or ($skill.value.index_section_digest | test("^[0-9a-f]{64}$") | not))
            or (($skill.value.refs | type) != "array")
            or (($skill.value.components | type) != "object")
            or ([$skill.value.refs[] | select(
                ((.ref | type) != "string")
                or (.ref | startswith($skill.key + "/") | not)
                or (.ref | test("^[a-z0-9][a-z0-9-]*/[a-z0-9][a-z0-9-]*$") | not)
                or ((.description | type) != "string" or (.description | length) == 0)
                or (.risk | IN("low", "medium", "high", "critical") | not)
                or ((.execution_class | type) != "string")
                or ((.capability | type) != "string")
                or (.execution_class | IN("runner", "host_helper", "credential_helper") | not)
            )] | length > 0)
            or (($skill.value.refs | map(.ref) | length) != ($skill.value.refs | map(.ref) | unique | length))
        )] | length == 0)
        and ([.assets[].name, .skills[].asset.name] as $names
            | ($names | length) == ($names | unique | length))
    ' "${manifest}" >/dev/null ||
        fail 'release manifest schema v2 契约无效'
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
    local manifest base_url core_archive web_archive mcp_sdk_archive skill_name skill_archive selector
    local expected_contract actual_contract expected_index actual_index index_json validation
    local expected_components actual_components
    local -a skill_names=()
    assert_plain_directory "${PREFIX}/releases" ||
        fail "发布目录类型非法: ${PREFIX}/releases"
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
    mcp_sdk_archive="$(obtain_asset "${manifest}" '.assets.mcp_sdk' "${base_url}")"
    mkdir -p "${WORK_DIR}/release"
    extract_archive_safely "${core_archive}" "${WORK_DIR}/release" || fail 'core archive 安全解包失败'
    extract_archive_safely "${web_archive}" "${WORK_DIR}/release" || fail 'web archive 安全解包失败'
    extract_archive_safely "${mcp_sdk_archive}" "${WORK_DIR}/release" ||
        fail 'MCP SDK archive 安全解包失败'
    [[ -f "${WORK_DIR}/release/skills/INDEX.md" &&
        ! -L "${WORK_DIR}/release/skills/INDEX.md" ]] ||
        fail 'core archive 缺少 skills/INDEX.md'
    mkdir -p "${WORK_DIR}/builtin-root/skills"
    cp -- "${WORK_DIR}/release/skills/INDEX.md" "${WORK_DIR}/builtin-root/skills/INDEX.md"
    if [[ "${TRANSACTION_MODE}" == "install" || ! -d "${PREFIX}/skills" ]]; then
        mapfile -t skill_names < <(jq -r '.skills | keys[]' "${manifest}")
    else
        [[ ! -L "${PREFIX}/skills" &&
            -f "${PREFIX}/skills/INDEX.md" && ! -L "${PREFIX}/skills/INDEX.md" ]] ||
            fail '现有内置 Skill 根目录或 INDEX 类型非法'
        mapfile -t skill_names < <(
            find "${PREFIX}/skills" -mindepth 1 -maxdepth 1 -type d \
                ! -name '.*' -printf '%f\n' | LC_ALL=C sort
        )
        for skill_name in "${skill_names[@]}"; do
            [[ "${skill_name}" =~ ^[a-z0-9][a-z0-9-]*$ ]] ||
                fail "现有内置 Skill 名称非法: ${skill_name}"
            jq -e --arg skill "${skill_name}" '.skills[$skill] | type == "object"' \
                "${manifest}" >/dev/null ||
                fail "新 release catalog 缺少已安装 Skill: ${skill_name}"
        done
    fi
    index_json="$(python3 "${WORK_DIR}/release/lib/skill_package.py" index \
        "${WORK_DIR}/release/skills/INDEX.md")" ||
        fail 'core archive 的 skills/INDEX.md 无效'
    for skill_name in "${skill_names[@]}"; do
        [[ "${skill_name}" =~ ^[a-z0-9][a-z0-9-]*$ ]] ||
            fail "Skill 名称非法: ${skill_name}"
        selector=".skills[\"${skill_name}\"].asset"
        skill_archive="$(obtain_asset "${manifest}" "${selector}" "${base_url}")"
        extract_archive_safely "${skill_archive}" "${WORK_DIR}/builtin-root" ||
            fail "Skill archive 安全解包失败: ${skill_name}"
        [[ -d "${WORK_DIR}/builtin-root/skills/${skill_name}" &&
            ! -L "${WORK_DIR}/builtin-root/skills/${skill_name}" ]] ||
            fail "Skill archive 未生成预期包目录: ${skill_name}"
        expected_contract="$(jq -r --arg skill "${skill_name}" \
            '.skills[$skill].contract_digest' "${manifest}")"
        actual_contract="$(python3 "${WORK_DIR}/release/lib/skill_package.py" digest \
            "${WORK_DIR}/builtin-root/skills/${skill_name}" --origin builtin |
            jq -r '.contract_digest // empty')"
        [[ -n "${actual_contract}" && "${actual_contract}" == "${expected_contract}" ]] ||
            fail "Skill contract digest 不匹配: ${skill_name}"
        expected_components="$(jq -Sc --arg skill "${skill_name}" \
            '.skills[$skill].components // {}' "${manifest}")"
        actual_components="$(python3 "${WORK_DIR}/release/lib/skill_package.py" inspect \
            "${WORK_DIR}/builtin-root/skills/${skill_name}" --origin builtin |
            jq -Sc '.components // {}')"
        [[ "${actual_components}" == "${expected_components}" ]] ||
            fail "Skill components 与签名 manifest 不匹配: ${skill_name}"
        expected_index="$(jq -r --arg skill "${skill_name}" \
            '.skills[$skill].index_section_digest' "${manifest}")"
        actual_index="$(jq -r --arg skill "${skill_name}" \
            '.skills[] | select(.name == $skill) | .section_digest' <<<"${index_json}")"
        [[ -n "${actual_index}" && "${actual_index}" == "${expected_index}" ]] ||
            fail "Skill INDEX section digest 不匹配: ${skill_name}"
    done
    PREPARED_SKILLS_DIR="${WORK_DIR}/builtin-root/skills"
    PREPARED_SKILLS_MANIFEST="${manifest}"
    validation="$(python3 "${WORK_DIR}/release/lib/skill_package.py" validate-root \
        "${PREPARED_SKILLS_DIR}")" || fail '内置 Skill staging 校验失败'
    jq -e '.ok == true and all(.findings[]?; .code == "SKILL_PACKAGE_UNAVAILABLE")' \
        <<<"${validation}" >/dev/null || fail '内置 Skill staging 与 INDEX 不一致'
    [[ -x "${WORK_DIR}/release/bin/agent" && -x "${WORK_DIR}/release/bin/agent-web" ]] ||
        fail '发布物缺少可执行入口'
    [[ -f "${WORK_DIR}/release/config/config.example.json" &&
        -f "${WORK_DIR}/release/third_party/mcp-python-sdk/SHA256SUMS" &&
        -f "${WORK_DIR}/release/packaging/linux-agent-web.service" &&
        -f "${WORK_DIR}/release/packaging/linux-agent-observer-helper.service" &&
        -f "${WORK_DIR}/release/packaging/linux-agent-observer-helper.socket" &&
        -f "${WORK_DIR}/release/packaging/linux-agent-runner.service" &&
        -f "${WORK_DIR}/release/packaging/linux-agent-runner.socket" &&
        -f "${WORK_DIR}/release/packaging/linux-agent-mcp-stdio.service" &&
        -f "${WORK_DIR}/release/packaging/linux-agent-mcp-stdio.socket" &&
        -f "${WORK_DIR}/release/packaging/linux-agent-host-ops.service" &&
        -f "${WORK_DIR}/release/packaging/linux-agent-host-ops.socket" &&
        -f "${WORK_DIR}/release/packaging/linux-agent-policy-writer.service" &&
        -f "${WORK_DIR}/release/packaging/linux-agent-policy-writer.socket" ]] ||
        fail '发布物缺少配置或 systemd unit'
    LINUX_AGENT_ROOT="${WORK_DIR}/release" \
        LINUX_AGENT_MCP_SDK_ROOT="${WORK_DIR}/release/third_party/mcp-python-sdk" \
        LINUX_AGENT_MCP_VENV="${WORK_DIR}/release/.mcp-venv" \
        python3 "${WORK_DIR}/release/lib/mcp_runtime.py" ensure >/dev/null ||
        fail '无法从离线 wheelhouse 创建 release MCP SDK runtime'
    rm -rf -- "${WORK_DIR}/release/logs" "${WORK_DIR}/release/tmp"

    mkdir -p "${WORK_DIR}/persistent-config"
    cp -- "${WORK_DIR}/release/config/config.example.json" \
        "${WORK_DIR}/persistent-config/config.example.json"
    cp -- "${WORK_DIR}/release/config/ai-providers.json" \
        "${WORK_DIR}/persistent-config/ai-providers.json"

    rm -rf -- "${WORK_DIR}/release/config"
    ln -s ../../data/config "${WORK_DIR}/release/config"
    ln -s ../../data/logs "${WORK_DIR}/release/logs"
    ln -s ../../data/tmp "${WORK_DIR}/release/tmp"
    find "${WORK_DIR}/release" -type f -exec chmod a-w -- {} +
    find "${WORK_DIR}/release" -type d -exec chmod 0755 -- {} +
    mv -- "${WORK_DIR}/release" "${release_dir}"
    PREPARED_RELEASE_DIR="${release_dir}"
}

prepare_persistent_layout() {
    local config_source="${WORK_DIR}/persistent-config"
    local path name target
    [[ -f "${config_source}/config.example.json" &&
        ! -L "${config_source}/config.example.json" &&
        -f "${config_source}/ai-providers.json" &&
        ! -L "${config_source}/ai-providers.json" ]] ||
        fail '安装 staging 缺少持久配置模板'
    for path in data data/config data/logs data/tmp data/skills data/policies data/runner-tmp data/mcp data/mcp/credentials; do
        assert_plain_directory "${PREFIX}/${path}" ||
            fail "持久数据路径必须是普通目录且不能是符号链接: ${PREFIX}/${path}"
    done
    mkdir -p "${PREFIX}/data/config" "${PREFIX}/data/logs" "${PREFIX}/data/tmp" \
        "${PREFIX}/data/skills" "${PREFIX}/data/policies" "${PREFIX}/data/runner-tmp" \
        "${PREFIX}/data/mcp/credentials"
    target="${PREFIX}/data/.runtime.lock"
    assert_plain_file "${target}" || fail "runtime 事务锁必须是普通文件且不能是符号链接: ${target}"
    if [[ ! -e "${target}" ]]; then
        (umask 077 && : >"${target}") || fail '无法创建 runtime 事务锁'
    fi
    for name in config.example.json ai-providers.json; do
        target="${PREFIX}/data/config/${name}"
        assert_plain_file "${target}" ||
            fail "持久配置模板必须是普通文件且不能是符号链接: ${target}"
        atomic_copy_regular_file "${config_source}/${name}" "${target}" 0644 ||
            fail "无法原子更新持久配置模板: ${name}"
    done
    [[ ! -L "${PREFIX}/data/config/config.json" ]] ||
        fail 'config.json 不能是符号链接'
    if [[ ! -e "${PREFIX}/data/config/config.json" ]]; then
        atomic_copy_regular_file "${config_source}/config.example.json" \
            "${PREFIX}/data/config/config.json" 0600 ||
            fail '无法原子创建 config.json'
    fi
    [[ -f "${PREFIX}/data/config/config.json" && ! -L "${PREFIX}/data/config/config.json" ]] ||
        fail 'config.json 必须是普通文件'
    chmod 0600 "${PREFIX}/data/config/config.json"
    if [[ "${NO_SYSTEMD}" -eq 1 ]]; then
        chmod 0700 "${PREFIX}/data" "${PREFIX}/data/config" "${PREFIX}/data/logs" \
            "${PREFIX}/data/tmp" "${PREFIX}/data/skills" "${PREFIX}/data/policies" \
            "${PREFIX}/data/runner-tmp" "${PREFIX}/data/mcp" \
            "${PREFIX}/data/mcp/credentials"
        chmod 0600 "${PREFIX}/data/.runtime.lock"
    fi
}

migrate_managed_layout() {
    local old_version="${1:-}" legacy_root="" migration_tool migration_result
    local release_root="${2:-${PREPARED_RELEASE_DIR:-${PREFIX}/current}}"
    migration_tool="${3:-${PREPARED_RELEASE_DIR:-${PREFIX}/current}/lib/layout_migration.py}"
    [[ -f "${migration_tool}" && ! -L "${migration_tool}" ]] ||
        fail '当前版本缺少受管 overlay 迁移器'
    if [[ -n "${old_version}" ]]; then
        legacy_root="${PREFIX}/releases/${old_version}"
        [[ -d "${legacy_root}" && ! -L "${legacy_root}" ]] ||
            fail "旧 release 不存在或类型非法: ${legacy_root}"
    fi
    if ! migration_result="$(python3 "${migration_tool}" \
        --legacy-root "${legacy_root}" \
        --release-root "${release_root}" \
        --data-root "${PREFIX}/data" \
        --version "${TRANSACTION_TARGET_VERSION}")"; then
        printf '%s\n' "${migration_result}" >&2
        fail '受管 Skill/策略 overlay 迁移失败'
    fi
    jq -e '.ok == true and (.status == "migrated" or .status == "reconciled" or .status == "already_migrated")' \
        <<<"${migration_result}" >/dev/null || fail 'overlay 迁移器返回了无效结果'
    case "$(jq -r '.status' <<<"${migration_result}")" in
        migrated)
            info "首次 overlay 迁移完成: $(jq -r '.report // "report unavailable"' <<<"${migration_result}")"
            ;;
        reconciled)
            info "overlay 升级校验完成: $(jq -r '.report // "report unavailable"' <<<"${migration_result}")"
            ;;
    esac
}

validate_persistent_overlays() {
    local release_root="${1:-${PREPARED_RELEASE_DIR:-${PREFIX}/current}}"
    local validation policy_name payload
    if ! validation="$(LINUX_AGENT_RUNTIME_PARENT_LOCK_FD="${RUNTIME_LOCK_FD}" bash "${release_root}/bin/agent" api skills validate '{}')" ||
        ! jq -e '.ok == true and .validation.ok == true' <<<"${validation}" >/dev/null; then
        printf '%s\n' "${validation:-Skill validation produced no result}" >&2
        fail '迁移后的 Skill overlay 校验失败'
    fi
    while IFS= read -r policy_name; do
        [[ -f "${PREFIX}/data/policies/${policy_name}" &&
            ! -L "${PREFIX}/data/policies/${policy_name}" ]] || continue
        payload="$(jq -cn --arg path "${policy_name}" '{path:$path}')"
        if ! validation="$(LINUX_AGENT_RUNTIME_PARENT_LOCK_FD="${RUNTIME_LOCK_FD}" bash "${release_root}/bin/agent" api policy validate "${payload}")" ||
            ! jq -e '.ok == true and .validation.ok == true' <<<"${validation}" >/dev/null; then
            printf '%s\n' "${validation:-Policy validation produced no result}" >&2
            fail "迁移后的策略校验失败: ${policy_name}"
        fi
    done < <(find "${release_root}/policies" -maxdepth 1 -type f -name '*.json' -printf '%f\n' | sort)
}

ensure_service_identity() {
    local uid
    if [[ "${NO_SYSTEMD}" -eq 1 ]]; then
        if [[ -z "${INSTALL_STATE_SERVICE_USER}" && "${SERVICE_USER_EXPLICIT}" -eq 0 ]]; then
            if [[ "${EUID}" -eq 0 && "${SUDO_USER:-}" != "root" &&
                "${SUDO_USER:-}" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] &&
                id "${SUDO_USER}" >/dev/null 2>&1; then
                SERVICE_USER="${SUDO_USER}"
            else
                SERVICE_USER="$(id -un)" || fail '无法确定无 systemd 运行用户'
            fi
        fi
        validate_service_identity
        SERVICE_GROUP="$(id -gn "${SERVICE_USER}")" || fail "无法确定运行用户主组: ${SERVICE_USER}"
        [[ -n "${SERVICE_GROUP}" ]] || fail "无法确定运行用户主组: ${SERVICE_USER}"
        return 0
    fi
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
    ensure_runner_identity
    ensure_credential_identity
    configure_managed_data_permissions
    chown -R root:root "${PREFIX}/releases"
}

ensure_credential_identity() {
    local uid web_uid runner_uid
    [[ "${NO_SYSTEMD}" -eq 0 ]] || return 0
    if id "${CREDENTIAL_USER}" >/dev/null 2>&1; then
        uid="$(id -u "${CREDENTIAL_USER}")"
        [[ "${uid}" != "0" || "${LINUX_AGENT_ALLOW_ROOT_SERVICE_USER_FOR_TESTS:-0}" == "1" ]] ||
            fail 'Credential helper 用户不能映射到 UID 0'
        CREDENTIAL_GROUP="$(id -gn "${CREDENTIAL_USER}")"
    else
        command -v useradd >/dev/null 2>&1 || fail '缺少 useradd，无法创建 credential helper 用户'
        if command -v getent >/dev/null 2>&1 && getent group "${CREDENTIAL_GROUP}" >/dev/null 2>&1; then
            useradd --system --home-dir /var/lib/linux-agent-credential --shell /usr/sbin/nologin \
                --gid "${CREDENTIAL_GROUP}" "${CREDENTIAL_USER}"
        elif [[ "${CREDENTIAL_GROUP}" == "${CREDENTIAL_USER}" ]]; then
            useradd --system --home-dir /var/lib/linux-agent-credential --shell /usr/sbin/nologin \
                --user-group "${CREDENTIAL_USER}"
        else
            fail "自定义 credential helper 组不存在: ${CREDENTIAL_GROUP}"
        fi
        CREDENTIAL_USER_CREATED=1
        CREDENTIAL_USER_CREATED_THIS_RUN=1
        uid="$(id -u "${CREDENTIAL_USER}")"
    fi
    if [[ "${LINUX_AGENT_ALLOW_ROOT_SERVICE_USER_FOR_TESTS:-0}" != "1" ]]; then
        web_uid="$(id -u "${SERVICE_USER}")"
        runner_uid="$(id -u "${RUNNER_USER}")"
        [[ "${uid}" != "${web_uid}" && "${uid}" != "${runner_uid}" ]] ||
            fail 'Credential helper 必须使用独立 UID'
    fi
}

ensure_runner_identity() {
    local uid service_uid service_gid runner_group_id runner_groups
    [[ "${NO_SYSTEMD}" -eq 0 ]] || return 0
    if id "${RUNNER_USER}" >/dev/null 2>&1; then
        uid="$(id -u "${RUNNER_USER}")"
        [[ "${uid}" != "0" || "${LINUX_AGENT_ALLOW_ROOT_SERVICE_USER_FOR_TESTS:-0}" == "1" ]] ||
            fail 'Runner 用户不能映射到 UID 0'
        RUNNER_GROUP="$(id -gn "${RUNNER_USER}")"
    else
        command -v useradd >/dev/null 2>&1 || fail '缺少 useradd，无法创建 Runner 用户'
        if command -v getent >/dev/null 2>&1 && getent group "${RUNNER_GROUP}" >/dev/null 2>&1; then
            useradd --system --home-dir /var/lib/linux-agent-runner --shell /usr/sbin/nologin \
                --gid "${RUNNER_GROUP}" "${RUNNER_USER}"
        elif [[ "${RUNNER_GROUP}" == "${RUNNER_USER}" ]]; then
            useradd --system --home-dir /var/lib/linux-agent-runner --shell /usr/sbin/nologin \
                --user-group "${RUNNER_USER}"
        else
            fail "自定义 Runner 组不存在: ${RUNNER_GROUP}"
        fi
        RUNNER_USER_CREATED=1
        RUNNER_USER_CREATED_THIS_RUN=1
        uid="$(id -u "${RUNNER_USER}")"
    fi
    service_uid="$(id -u "${SERVICE_USER}")"
    if [[ "${uid}" == "${service_uid}" && "${LINUX_AGENT_ALLOW_ROOT_SERVICE_USER_FOR_TESTS:-0}" != "1" ]]; then
        fail 'Runner 与 Web 服务用户必须使用不同 UID'
    fi
    if [[ "${LINUX_AGENT_ALLOW_ROOT_SERVICE_USER_FOR_TESTS:-0}" != "1" ]]; then
        service_gid="$(id -g "${SERVICE_USER}")"
        runner_group_id="$(id -g "${RUNNER_USER}")"
        [[ -n "${runner_group_id}" ]] || fail "无法确定 Runner 用户组 GID: ${RUNNER_GROUP}"
        [[ "${runner_group_id}" != "${service_gid}" ]] ||
            fail 'Runner 用户组不能与 Web 服务用户主组相同'
        runner_groups=" $(id -G "${RUNNER_USER}") "
        [[ "${runner_groups}" != *" ${service_gid} "* ]] ||
            fail 'Runner 用户不能加入 Web 服务组，否则可访问特权 helper socket'
    fi
}

configure_managed_data_permissions() {
    [[ "${NO_SYSTEMD}" -eq 0 ]] || return 0
    mkdir -p -- "${PREFIX}/data/config" "${PREFIX}/data/logs" "${PREFIX}/data/tmp" \
        "${PREFIX}/data/skills" "${PREFIX}/data/policies" "${PREFIX}/data/runner-tmp" \
        "${PREFIX}/data/mcp/credentials" \
        "${PREFIX}/data/migration-reports" "${PREFIX}/data/migration-conflicts"
    chown root:root "${PREFIX}/data"
    chmod 0755 "${PREFIX}/data"
    chown -R "${SERVICE_USER}:${SERVICE_GROUP}" \
        "${PREFIX}/data/config" "${PREFIX}/data/logs" "${PREFIX}/data/tmp"
    chmod 0700 "${PREFIX}/data/config" "${PREFIX}/data/logs" "${PREFIX}/data/tmp"
    chown -R "${SERVICE_USER}:${RUNNER_GROUP}" \
        "${PREFIX}/data/skills" "${PREFIX}/data/runner-tmp"
    chown "${SERVICE_USER}:${RUNNER_GROUP}" "${PREFIX}/data/.runtime.lock"
    chmod 0640 "${PREFIX}/data/.runtime.lock"
    find "${PREFIX}/data/skills" "${PREFIX}/data/runner-tmp" -type d -exec chmod 2750 -- {} +
    find "${PREFIX}/data/skills" -type f -exec chmod 0640 -- {} +
    chown -R "${RUNNER_USER}:${RUNNER_GROUP}" "${PREFIX}/data/mcp"
    find "${PREFIX}/data/mcp" -type d -exec chmod 0700 -- {} +
    find "${PREFIX}/data/mcp/credentials" -type f -exec chmod 0600 -- {} +
    chown -R "root:${SERVICE_GROUP}" "${PREFIX}/data/policies"
    find "${PREFIX}/data/policies" -type d -exec chmod 0750 -- {} +
    find "${PREFIX}/data/policies" -type f -exec chmod 0640 -- {} +
    chown -R "root:${SERVICE_GROUP}" "${PREFIX}/data/migration-reports"
    find "${PREFIX}/data/migration-reports" -type d -exec chmod 0750 -- {} +
    find "${PREFIX}/data/migration-reports" -type f -exec chmod 0640 -- {} +
    chown -R root:root "${PREFIX}/data/migration-conflicts"
    chmod 0700 "${PREFIX}/data/migration-conflicts"
    find "${PREFIX}/data/migration-conflicts" -mindepth 1 -type d -exec chmod 0700 -- {} +
    find "${PREFIX}/data/migration-conflicts" -type f -exec chmod 0600 -- {} +
    if [[ -f "${PREFIX}/data/.overlay-layout-v1.json" &&
        ! -L "${PREFIX}/data/.overlay-layout-v1.json" ]]; then
        chown root:root "${PREFIX}/data/.overlay-layout-v1.json"
        chmod 0644 "${PREFIX}/data/.overlay-layout-v1.json"
    fi
    chmod 0600 "${PREFIX}/data/config/config.json"
}

finalize_no_systemd_ownership() {
    local expected_uid expected_gid path
    [[ "${NO_SYSTEMD}" -eq 1 && "${EUID}" -eq 0 ]] || return 0
    if [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" ]]; then
        case "${WORK_DIR}" in
            "${PREFIX}"/.install-staging.*) rm -rf -- "${WORK_DIR}" ;;
            *) fail "拒绝清理非预期 staging 目录: ${WORK_DIR}" ;;
        esac
        WORK_DIR=""
    fi
    command -v chown >/dev/null 2>&1 || fail '缺少 chown，无法设置无 systemd 安装所有权'
    validate_service_identity
    SERVICE_GROUP="$(id -gn "${SERVICE_USER}")" || fail "无法确定运行用户主组: ${SERVICE_USER}"
    chown "${SERVICE_USER}:${SERVICE_GROUP}" "${PREFIX}" ||
        fail "无法将无 systemd 安装归属到运行用户: ${SERVICE_USER}"
    chown -R "${SERVICE_USER}:${SERVICE_GROUP}" "${PREFIX}/data" ||
        fail "无法将无 systemd 安装归属到运行用户: ${SERVICE_USER}"
    if [[ -d "${PREFIX}/releases" && ! -L "${PREFIX}/releases" ]]; then
        chown -R "${SERVICE_USER}:${SERVICE_GROUP}" "${PREFIX}/releases" ||
            fail "无法将无 systemd 发布目录归属到运行用户: ${SERVICE_USER}"
    fi
    chown "${SERVICE_USER}:${SERVICE_GROUP}" "$(install_state_path)" ||
        fail "无法设置无 systemd 安装状态所有权: $(install_state_path)"
    if [[ -L "${PREFIX}/current" ]]; then
        chown -h "${SERVICE_USER}:${SERVICE_GROUP}" "${PREFIX}/current" ||
            fail '无法设置无 systemd current 链接所有权'
    fi
    expected_uid="$(id -u "${SERVICE_USER}")"
    expected_gid="$(id -g "${SERVICE_USER}")"
    for path in "${PREFIX}" "${PREFIX}/data" "${PREFIX}/data/config" \
        "${PREFIX}/data/logs" "${PREFIX}/data/tmp" "${PREFIX}/data/skills" \
        "${PREFIX}/data/policies" "${PREFIX}/data/runner-tmp" "$(install_state_path)"; do
        [[ -e "${path}" && ! -L "${path}" ]] || fail "无 systemd 运行路径缺失或类型非法: ${path}"
        [[ "$(stat -c '%u' "${path}")" == "${expected_uid}" &&
        "$(stat -c '%g' "${path}")" == "${expected_gid}" ]] ||
            fail "无 systemd 运行路径所有权不匹配 ${SERVICE_USER}:${SERVICE_GROUP}: ${path}"
    done
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

restore_selinux_paths() {
    local status path
    local -a existing_paths=()
    command -v getenforce >/dev/null 2>&1 || return 0
    status="$(getenforce 2>/dev/null || true)"
    [[ "${status}" != "Disabled" && -n "${status}" ]] || return 0
    for path in "$@"; do
        [[ -e "${path}" || -L "${path}" ]] && existing_paths+=("${path}")
    done
    [[ "${#existing_paths[@]}" -gt 0 ]] || return 0
    if ! command -v restorecon >/dev/null 2>&1; then
        if [[ "${status}" == "Enforcing" ]]; then
            fail 'SELinux Enforcing 已启用但缺少 restorecon；请安装 policycoreutils'
        fi
        warn 'SELinux 已启用但缺少 restorecon，跳过安全上下文恢复'
        return 0
    fi
    restorecon -RF "${existing_paths[@]}" ||
        fail "SELinux 安全上下文恢复失败: ${existing_paths[*]}"
}

verify_service_runtime_access() {
    local config_path="${PREFIX}/data/config/config.json"
    local -a command=(python3 - "${config_path}" "${PREFIX}/data/config"
        "${PREFIX}/data/logs" "${PREFIX}/data/tmp")
    [[ "${NO_SYSTEMD}" -eq 0 ]] || return 0
    if [[ "${EUID}" -eq 0 && "${SERVICE_USER}" != "root" ]]; then
        command -v runuser >/dev/null 2>&1 ||
            fail '缺少 runuser，无法验证 Web 服务用户的数据目录权限'
        command=(runuser -u "${SERVICE_USER}" -- "${command[@]}")
    fi
    "${command[@]}" <<'PY' ||
import os
import sys
from pathlib import Path

config = Path(sys.argv[1])
directories = [Path(value) for value in sys.argv[2:]]
if not config.is_file() or not os.access(config, os.R_OK):
    raise SystemExit(f"config is not readable: {config}")
for directory in directories:
    if not directory.is_dir() or not os.access(directory, os.R_OK | os.W_OK | os.X_OK):
        raise SystemExit(f"runtime directory is not accessible: {directory}")
    probe = directory / f".linux-agent-permission-probe-{os.getpid()}"
    descriptor = os.open(probe, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        os.write(descriptor, b"permission-probe\n")
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    probe.unlink()
PY
        fail "Web 服务用户 ${SERVICE_USER} 无法读取配置或写入 data/{config,logs,tmp}"
}

verify_runner_runtime_access() {
    local probe="${PREFIX}/data/runner-tmp/.runner-permission-probe.$$"
    local credential_probe="${PREFIX}/data/mcp/credentials/.runner-credential-probe.$$"
    local -a command=(python3 - "${probe}" "${PREFIX}/data/skills"
        "${PREFIX}/data/config/config.json" "${PREFIX}/data/logs"
        "${PREFIX}/data/policies" "${credential_probe}")
    [[ "${NO_SYSTEMD}" -eq 0 ]] || return 0
    printf 'runner-permission-probe\n' >"${probe}"
    chown "${SERVICE_USER}:${RUNNER_GROUP}" "${probe}"
    chmod 0640 "${probe}"
    if [[ "${EUID}" -eq 0 && "${RUNNER_USER}" != "root" ]]; then
        command -v runuser >/dev/null 2>&1 ||
            fail '缺少 runuser，无法验证 Runner 数据权限'
        command=(runuser -u "${RUNNER_USER}" -- "${command[@]}")
    fi
    if ! LINUX_AGENT_TEST_RUNNER_IS_ROOT="$([[ "${RUNNER_USER}" == "root" ]] && printf 1 || printf 0)" \
        "${command[@]}" <<'PY'; then
import os
import sys
from pathlib import Path

probe, skills, config, logs, policies, credential_probe = map(Path, sys.argv[1:])
if probe.read_text(encoding="utf-8") != "runner-permission-probe\n":
    raise SystemExit("runner cannot read shared execution staging")
if not skills.is_dir() or not os.access(skills, os.R_OK | os.X_OK):
    raise SystemExit("runner cannot read the user Skill overlay")
if os.environ.get("LINUX_AGENT_TEST_RUNNER_IS_ROOT") != "1":
    try:
        config.read_bytes()
    except PermissionError:
        pass
    else:
        raise SystemExit("runner can read the protected Agent configuration")
    for protected in (config.parent, logs, policies):
        if os.access(protected, os.R_OK | os.X_OK):
            raise SystemExit(f"runner can traverse protected Agent data: {protected}")
descriptor = os.open(
    credential_probe,
    os.O_WRONLY | os.O_CREAT | os.O_EXCL,
    0o600,
)
try:
    os.write(descriptor, b"credential-probe\n")
    os.fsync(descriptor)
finally:
    os.close(descriptor)
credential_probe.unlink()
PY
        rm -f -- "${probe}" "${credential_probe}"
        fail "Runner 用户 ${RUNNER_USER} 的隔离权限检查失败"
    fi
    rm -f -- "${probe}" "${credential_probe}"
}

verify_systemd_unit_files() {
    local output_file _package _component _client _socket_env _socket_path
    local service_asset socket_asset service_path socket_path _egress_dropin
    local -a verify_paths=(
        "${SYSTEMD_UNIT_PATH}" "${SYSTEMD_HELPER_SERVICE_PATH}"
        "${SYSTEMD_HELPER_SOCKET_PATH}"
        "${SYSTEMD_RUNNER_SERVICE_PATH}" "${SYSTEMD_RUNNER_SOCKET_PATH}"
        "${SYSTEMD_MCP_STDIO_SERVICE_PATH}" "${SYSTEMD_MCP_STDIO_SOCKET_PATH}"
        "${SYSTEMD_HOST_SERVICE_PATH}" "${SYSTEMD_HOST_SOCKET_PATH}"
        "${SYSTEMD_POLICY_SERVICE_PATH}" "${SYSTEMD_POLICY_SOCKET_PATH}"
    )
    [[ "${NO_SYSTEMD}" -eq 0 ]] || return 0
    command -v systemd-analyze >/dev/null 2>&1 ||
        fail '缺少 systemd-analyze，无法验证 systemd unit 兼容性'
    while IFS= read -r output_file; do
        [[ -n "${output_file}" ]] && verify_paths+=("${output_file}")
    done < <(installed_credential_file_paths | grep -E '[.](service|socket)$' || true)
    output_file="$(mktemp)"
    if ! LC_ALL=C systemd-analyze verify "${verify_paths[@]}" >"${output_file}" 2>&1; then
        sed -n '1,80p' "${output_file}" >&2
        rm -f -- "${output_file}"
        fail '当前 systemd 不支持安装包中的 unit 配置'
    fi
    rm -f -- "${output_file}"
    grep -Fxq "User=${RUNNER_USER}" "${SYSTEMD_RUNNER_SERVICE_PATH}" &&
        grep -Fxq "Group=${RUNNER_GROUP}" "${SYSTEMD_RUNNER_SERVICE_PATH}" &&
        grep -Fq "/run/linux-agent/runner.sock" "${SYSTEMD_RUNNER_SERVICE_PATH}" &&
        grep -Fxq "SocketUser=${SERVICE_USER}" "${SYSTEMD_RUNNER_SOCKET_PATH}" &&
        grep -Fxq "SocketGroup=${SERVICE_GROUP}" "${SYSTEMD_RUNNER_SOCKET_PATH}" &&
        grep -Fxq 'SocketMode=0600' "${SYSTEMD_RUNNER_SOCKET_PATH}" ||
        fail 'Runner unit 未落实独立 UID 或仅 Web 可连接的 socket 边界'
    grep -Fxq 'DynamicUser=yes' "${SYSTEMD_MCP_STDIO_SERVICE_PATH}" &&
        grep -Fxq "Environment=LINUX_AGENT_SERVICE_USER=${RUNNER_USER}" \
            "${SYSTEMD_MCP_STDIO_SERVICE_PATH}" &&
        grep -Fxq 'SocketUser=root' "${SYSTEMD_MCP_STDIO_SOCKET_PATH}" &&
        grep -Fxq "SocketGroup=${RUNNER_GROUP}" "${SYSTEMD_MCP_STDIO_SOCKET_PATH}" &&
        grep -Fxq 'SocketMode=0660' "${SYSTEMD_MCP_STDIO_SOCKET_PATH}" ||
        fail 'MCP stdio relay 未落实 DynamicUser 与仅 Runner 可连接的 socket 边界'
    for output_file in "${SYSTEMD_HELPER_SOCKET_PATH}" "${SYSTEMD_HOST_SOCKET_PATH}" \
        "${SYSTEMD_POLICY_SOCKET_PATH}"; do
        grep -Fxq 'SocketUser=root' "${output_file}" &&
            grep -Fxq "SocketGroup=${SERVICE_GROUP}" "${output_file}" &&
            grep -Fxq 'SocketMode=0660' "${output_file}" ||
            fail "特权 helper socket 权限边界无效: ${output_file}"
    done
    for output_file in "${SYSTEMD_HELPER_SERVICE_PATH}" "${SYSTEMD_RUNNER_SERVICE_PATH}" \
        "${SYSTEMD_HOST_SERVICE_PATH}" "${SYSTEMD_POLICY_SERVICE_PATH}"; do
        grep -Fxq "Environment=LINUX_AGENT_SERVICE_USER=${SERVICE_USER}" "${output_file}" ||
            fail "helper/Runner unit 未绑定实际 Web 服务用户: ${output_file}"
    done
    while IFS=$'\t' read -r _package _component _client _socket_env _socket_path \
        service_asset socket_asset _egress_dropin; do
        service_path="${SYSTEMD_UNIT_DIR}/$(basename -- "${service_asset}")"
        socket_path="${SYSTEMD_UNIT_DIR}/$(basename -- "${socket_asset}")"
        grep -Fxq 'SocketUser=root' "${socket_path}" &&
            grep -Fxq "SocketGroup=${SERVICE_GROUP}" "${socket_path}" &&
            grep -Fxq 'SocketMode=0660' "${socket_path}" ||
            fail "Credential helper socket 权限边界无效: ${socket_path}"
        grep -Fxq "Environment=LINUX_AGENT_SERVICE_USER=${SERVICE_USER}" "${service_path}" &&
            grep -Fxq "User=${CREDENTIAL_USER}" "${service_path}" &&
            grep -Fxq "Group=${CREDENTIAL_GROUP}" "${service_path}" ||
            fail "Credential helper unit 未落实服务用户与独立 UID/GID: ${service_path}"
    done < <(credential_component_rows)
}

verify_source_observer_systemd_unit_files() {
    local socket_dropin_path="$1"
    local service_dropin_path="$2"
    local output_file
    [[ "${NO_SYSTEMD}" -eq 0 ]] || return 0
    command -v systemd-analyze >/dev/null 2>&1 ||
        fail '缺少 systemd-analyze，无法验证 systemd unit 兼容性'
    output_file="$(mktemp)"
    if ! LC_ALL=C systemd-analyze verify \
        "${SYSTEMD_UNIT_PATH}" "${SYSTEMD_HELPER_SERVICE_PATH}" \
        "${SYSTEMD_HELPER_SOCKET_PATH}" >"${output_file}" 2>&1; then
        sed -n '1,80p' "${output_file}" >&2
        rm -f -- "${output_file}"
        fail '当前 systemd 不支持源码 observer helper unit 配置'
    fi
    rm -f -- "${output_file}"
    grep -Fxq 'SocketUser=root' "${SYSTEMD_HELPER_SOCKET_PATH}" &&
        grep -Fxq 'SocketMode=0660' "${SYSTEMD_HELPER_SOCKET_PATH}" &&
        grep -Fxq "SocketGroup=${SERVICE_GROUP}" "${socket_dropin_path}" ||
        fail '源码 observer helper socket 权限边界无效'
    grep -Fxq "Environment=LINUX_AGENT_SERVICE_USER=${SERVICE_USER}" \
        "${service_dropin_path}" &&
        grep -Fq 'ExecStart=/usr/bin/python3 ' "${service_dropin_path}" ||
        fail '源码 observer helper service 未绑定实际 Web 服务用户或隔离 runtime'
}

skill_component_registry_at() {
    local skills_root="$1"
    local parser="$2"
    local registry
    if [[ ! -d "${skills_root}" || -L "${skills_root}" ]]; then
        jq -cn '{ok:true,status:"unavailable",skills:[],findings:[]}'
        return 0
    fi
    [[ -f "${parser}" && ! -L "${parser}" ]] ||
        fail '当前版本缺少 Skill 包契约解析器'
    registry="$(python3 "${parser}" validate-root "${skills_root}")" ||
        fail '无法读取已安装 Skill 组件注册表'
    jq -e '.ok == true and (.skills | type == "array")' <<<"${registry}" >/dev/null ||
        fail '已安装 Skill 组件注册表无效'
    printf '%s\n' "${registry}"
}

skill_component_registry() {
    skill_component_registry_at "${PREFIX}/skills" "${PREFIX}/current/lib/skill_package.py"
}

credential_component_rows_at() {
    local skills_root="$1" parser="$2"
    skill_component_registry_at "${skills_root}" "${parser}" | jq -er '
        .skills[]
        | select(.state == "installed" and (.components.credential_helper | type) == "object")
        | .name as $package
        | .components.credential_helper
        | select(has("service_asset") and has("socket_asset"))
        | [
            $package,
            .name,
            .client,
            .socket_env,
            .default_socket,
            .service_asset,
            .socket_asset,
            (.egress_dropin // "")
        ]
        | @tsv
    '
}

credential_component_rows() {
    credential_component_rows_at "${PREFIX}/skills" "${PREFIX}/current/lib/skill_package.py"
}

transaction_credential_component_rows() {
    local current_parser="${PREFIX}/current/lib/skill_package.py"
    local prepared_parser="${PREPARED_RELEASE_DIR:-}/lib/skill_package.py"
    credential_component_rows_at "${PREFIX}/skills" "${current_parser}"
    if [[ -n "${PREPARED_SKILLS_DIR}" && -n "${WORK_DIR}" ]]; then
        credential_component_rows_at "${PREPARED_SKILLS_DIR}" "${prepared_parser}"
    fi
}

transaction_credential_file_rows() {
    local _package component _client _socket_env _socket_path service_asset socket_asset
    local egress_dropin path key
    local -A seen=()
    while IFS=$'\t' read -r _package component _client _socket_env _socket_path \
        service_asset socket_asset egress_dropin; do
        [[ -n "${component}" ]] || continue
        for path in \
            "${SYSTEMD_UNIT_DIR}/$(basename -- "${service_asset}")" \
            "${SYSTEMD_UNIT_DIR}/$(basename -- "${socket_asset}")"; do
            key="${path}"
            [[ -z "${seen["${key}"]:-}" ]] || continue
            seen["${key}"]=1
            printf '%s\tcredential-%s-%s\n' "${path}" "${component}" "$(basename -- "${path}")"
        done
        if [[ -n "${egress_dropin}" ]]; then
            path="${SYSTEMD_UNIT_DIR}/linux-agent-${component}.service.d/${egress_dropin}"
            key="${path}"
            if [[ -z "${seen["${key}"]:-}" ]]; then
                seen["${key}"]=1
                printf '%s\tcredential-%s-%s\n' "${path}" "${component}" "${egress_dropin}"
            fi
        fi
    done < <(transaction_credential_component_rows | sort -u)
}

installed_credential_unit_names() {
    local _package _component _client _socket_env _socket_path service_asset socket_asset
    local _egress_dropin
    while IFS=$'\t' read -r _package _component _client _socket_env _socket_path \
        service_asset socket_asset _egress_dropin; do
        [[ -n "${_package}" ]] || continue
        basename -- "${socket_asset}"
        basename -- "${service_asset}"
    done < <(credential_component_rows)
}

installed_credential_file_paths() {
    local _package component _client _socket_env _socket_path service_asset socket_asset
    local egress_dropin
    while IFS=$'\t' read -r _package component _client _socket_env _socket_path \
        service_asset socket_asset egress_dropin; do
        [[ -n "${component}" ]] || continue
        printf '%s\n' \
            "${SYSTEMD_UNIT_DIR}/$(basename -- "${service_asset}")" \
            "${SYSTEMD_UNIT_DIR}/$(basename -- "${socket_asset}")"
        if [[ -n "${egress_dropin}" ]]; then
            printf '%s\n' \
                "${SYSTEMD_UNIT_DIR}/linux-agent-${component}.service.d/${egress_dropin}"
        fi
    done < <(credential_component_rows)
}

remove_stale_credential_systemd_files() {
    local path current_files
    [[ -f "${TRANSACTION_BACKUP_DIR}/systemd-extra/credential-files.tsv" ]] || return 0
    current_files="$(installed_credential_file_paths | sort -u)"
    while IFS= read -r path; do
        [[ -n "${path}" ]] || continue
        grep -Fxq -- "${path}" <<<"${current_files}" && continue
        rm -f -- "${path}"
        case "${path}" in
            *.service.d/*.conf) rmdir -- "$(dirname -- "${path}")" 2>/dev/null || true ;;
        esac
    done <"${TRANSACTION_BACKUP_DIR}/systemd-extra/credential-files.tsv"
}

install_credential_component_state() {
    local registry package component egress_dropin command_json entrypoint
    local environment_name environment_value resolved_value
    local -a arguments=() command=()
    registry="$(skill_component_registry)"
    while IFS=$'\t' read -r package component egress_dropin command_json; do
        [[ -n "${package}" && -n "${command_json}" ]] || continue
        entrypoint="$(jq -er '.entrypoint' <<<"${command_json}")" ||
            fail "Skill ${package} 的 credential helper 安装命令无效"
        mapfile -t arguments < <(jq -er '.arguments[]' <<<"${command_json}")
        command=(env "PYTHONPATH=${PREFIX}/current/lib")
        while IFS=$'\t' read -r environment_name environment_value; do
            [[ -n "${environment_name}" ]] || continue
            case "${environment_value}" in
                credential_group) resolved_value="${CREDENTIAL_GROUP}" ;;
                component_egress_dropin)
                    [[ -n "${egress_dropin}" ]] ||
                        fail "Skill ${package} 缺少 credential helper egress drop-in 声明"
                    resolved_value="${SYSTEMD_UNIT_DIR}/linux-agent-${component}.service.d/${egress_dropin}"
                    ;;
                *) fail "Skill ${package} 声明了未知的 credential helper 安装环境" ;;
            esac
            command+=("${environment_name}=${resolved_value}")
        done < <(jq -er '.environment | to_entries[] | [.key, .value] | @tsv' \
            <<<"${command_json}")
        command+=(python3 "${PREFIX}/skills/${package}/${entrypoint}" "${arguments[@]}")
        "${command[@]}" >/dev/null ||
            fail "Skill ${package} 的 credential helper 安装命令失败"
    done < <(jq -er '
        .skills[]
        | select(.state == "installed")
        | .name as $package
        | .components.credential_helper as $component
        | $component.install.commands[]?
        | [$package, $component.name, ($component.egress_dropin // ""), tojson]
        | @tsv
    ' <<<"${registry}")
}

update_skill_component_ledger() {
    local ledger="${PREFIX}/data/skill-components.json"
    local registry package package_path contract_digest components credential host
    local environment default_path resolved_path record result
    local units='[]' unit_files='[]' host_policy_files='[]' owned_paths='[]'
    local component service_asset socket_asset egress_dropin
    [[ -d "${PREFIX}/data" && ! -L "${PREFIX}/data" ]] ||
        fail 'Skill component ownership ledger 目录不可用'
    [[ -f "${PREFIX}/current/lib/skill_component_ledger.py" &&
        ! -L "${PREFIX}/current/lib/skill_component_ledger.py" ]] ||
        fail '当前版本缺少 Skill component ownership ledger 实现'
    registry="$(skill_component_registry)"
    while IFS= read -r package; do
        [[ -n "${package}" ]] || continue
        package_path="${PREFIX}/skills/${package}"
        contract_digest="$(python3 "${PREFIX}/current/lib/skill_package.py" digest \
            "${package_path}" --origin builtin | jq -er '.contract_digest')" ||
            fail "无法记录 Skill ${package} 的 contract digest"
        components="$(jq -c --arg package "${package}" \
            '.skills[] | select(.name == $package) | .components' <<<"${registry}")"
        units='[]'
        unit_files='[]'
        host_policy_files='[]'
        owned_paths='[]'
        credential="$(jq -c '.credential_helper // {}' <<<"${components}")"
        if [[ "${NO_SYSTEMD}" -eq 0 && "$(jq -r 'length' <<<"${credential}")" -gt 0 ]]; then
            component="$(jq -er '.name' <<<"${credential}")"
            service_asset="$(jq -er '.service_asset' <<<"${credential}")"
            socket_asset="$(jq -er '.socket_asset' <<<"${credential}")"
            egress_dropin="$(jq -r '.egress_dropin // empty' <<<"${credential}")"
            units="$(jq -cn \
                --arg service "$(basename -- "${service_asset}")" \
                --arg socket "$(basename -- "${socket_asset}")" \
                '[$socket,$service]')"
            unit_files="$(jq -cn \
                --arg service "${SYSTEMD_UNIT_DIR}/$(basename -- "${service_asset}")" \
                --arg socket "${SYSTEMD_UNIT_DIR}/$(basename -- "${socket_asset}")" \
                --arg dropin "$([[ -n "${egress_dropin}" ]] && printf '%s' "${SYSTEMD_UNIT_DIR}/linux-agent-${component}.service.d/${egress_dropin}")" \
                '[$service,$socket] + (if $dropin == "" then [] else [$dropin] end)')"
            while IFS=$'\t' read -r environment default_path; do
                [[ -n "${environment}" ]] || continue
                resolved_path="${!environment-}"
                [[ -n "${resolved_path}" ]] || resolved_path="${default_path}"
                owned_paths="$(jq -cn --argjson prior "${owned_paths}" \
                    --arg path "${resolved_path}" --arg default "${default_path}" \
                    '$prior + [{kind:"directory",path:$path,default:$default}]')"
            done < <(jq -r '.owned_paths[]? | [.environment,.default] | @tsv' \
                <<<"${credential}")
        fi
        host="$(jq -c '.host_helper // {}' <<<"${components}")"
        if [[ "${NO_SYSTEMD}" -eq 0 && "$(jq -r 'has("policy_asset")' <<<"${host}")" == "true" ]]; then
            host_policy_files="$(jq -cn --arg path "${HOST_OPS_POLICY_PATH}" '[$path]')"
        fi
        record="$(jq -cn \
            --arg digest "${contract_digest}" \
            --argjson units "${units}" \
            --argjson unit_files "${unit_files}" \
            --argjson host_policy_files "${host_policy_files}" \
            --argjson owned_paths "${owned_paths}" \
            '{installed:true,contract_digest:$digest,units:$units,unit_files:$unit_files,host_policy_files:$host_policy_files,owned_paths:$owned_paths}')"
        result="$(python3 "${PREFIX}/current/lib/skill_component_ledger.py" upsert \
            "${ledger}" "${package}" --record "${record}")" ||
            fail "无法更新 Skill ${package} 的 component ownership ledger"
        jq -e '.ok == true' <<<"${result}" >/dev/null ||
            fail "Skill ${package} 的 component ownership ledger 返回无效结果"
    done < <(jq -r '.skills[] | select(.state == "installed") | .name' <<<"${registry}")
    if [[ "${NO_SYSTEMD}" -eq 0 ]]; then
        chown root:root "${ledger}"
        chmod 0600 "${ledger}"
    fi
}

render_systemd_unit() {
    local template="$1" rendered="$2"
    python3 - "${template}" "${rendered}" "${PREFIX}" \
        "${SERVICE_USER}" "${SERVICE_GROUP}" "${RUNNER_USER}" "${RUNNER_GROUP}" \
        "${CREDENTIAL_USER}" "${CREDENTIAL_GROUP}" "${HOST_OPS_POLICY_PATH}" <<'PY'
import sys
from pathlib import Path

(
    source,
    output,
    prefix,
    web_user,
    web_group,
    runner_user,
    runner_group,
    credential_user,
    credential_group,
    host_ops_policy,
) = sys.argv[1:]
text = Path(source).read_text(encoding="utf-8").replace("/opt/linux-agent", prefix)
replacements = {
    "User=linux-agent-runner": f"User={runner_user}",
    "Group=linux-agent-runner": f"Group={runner_group}",
    "SocketGroup=linux-agent-runner": f"SocketGroup={runner_group}",
    "User=linux-agent-credential": f"User={credential_user}",
    "Group=linux-agent-credential": f"Group={credential_group}",
    "User=linux-agent": f"User={web_user}",
    "Group=linux-agent": f"Group={web_group}",
    "SocketUser=linux-agent": f"SocketUser={web_user}",
    "SocketGroup=linux-agent": f"SocketGroup={web_group}",
    "Environment=LINUX_AGENT_SERVICE_USER=linux-agent": (
        f"Environment=LINUX_AGENT_SERVICE_USER={web_user}"
    ),
    "Environment=LINUX_AGENT_SERVICE_USER=linux-agent-runner": (
        f"Environment=LINUX_AGENT_SERVICE_USER={runner_user}"
    ),
    "Environment=LINUX_AGENT_HOST_OPS_POLICY_PATH=/etc/linux-agent/host-ops-policy.json": (
        f"Environment=LINUX_AGENT_HOST_OPS_POLICY_PATH={host_ops_policy}"
    ),
}
text = "".join(
    replacements.get(line.rstrip("\n"), line.rstrip("\n")) + "\n"
    for line in text.splitlines()
)
Path(output).write_text(text, encoding="utf-8")
PY
}

install_systemd_unit() {
    local render_root="${WORK_DIR:-${TRANSACTION_BACKUP_DIR:-${PREFIX}}}"
    local template target rendered package _component _client _socket_env _socket_path
    local service_asset socket_asset _egress_dropin
    local -a installed_units=()
    [[ "${NO_SYSTEMD}" -eq 0 ]] || return 0
    install_credential_component_state
    install_host_ops_policy
    command -v systemctl >/dev/null 2>&1 || fail '缺少 systemctl'
    mkdir -p -- "${SYSTEMD_UNIT_DIR}"
    while IFS=$'\t' read -r template target; do
        [[ -f "${template}" && ! -L "${template}" ]] ||
            fail "当前版本缺少 systemd unit: ${template}"
        rendered="${render_root}/.${target##*/}.$$"
        render_systemd_unit "${template}" "${rendered}"
        cp -- "${rendered}" "${target}"
        chmod 0644 "${target}"
        installed_units+=("${target}")
    done <<EOF
${PREFIX}/current/packaging/linux-agent-web.service	${SYSTEMD_UNIT_PATH}
${PREFIX}/current/packaging/linux-agent-observer-helper.service	${SYSTEMD_HELPER_SERVICE_PATH}
${PREFIX}/current/packaging/linux-agent-observer-helper.socket	${SYSTEMD_HELPER_SOCKET_PATH}
${PREFIX}/current/packaging/linux-agent-runner.service	${SYSTEMD_RUNNER_SERVICE_PATH}
${PREFIX}/current/packaging/linux-agent-runner.socket	${SYSTEMD_RUNNER_SOCKET_PATH}
${PREFIX}/current/packaging/linux-agent-mcp-stdio.service	${SYSTEMD_MCP_STDIO_SERVICE_PATH}
${PREFIX}/current/packaging/linux-agent-mcp-stdio.socket	${SYSTEMD_MCP_STDIO_SOCKET_PATH}
${PREFIX}/current/packaging/linux-agent-host-ops.service	${SYSTEMD_HOST_SERVICE_PATH}
${PREFIX}/current/packaging/linux-agent-host-ops.socket	${SYSTEMD_HOST_SOCKET_PATH}
${PREFIX}/current/packaging/linux-agent-policy-writer.service	${SYSTEMD_POLICY_SERVICE_PATH}
${PREFIX}/current/packaging/linux-agent-policy-writer.socket	${SYSTEMD_POLICY_SOCKET_PATH}
EOF
    while IFS=$'\t' read -r package _component _client _socket_env _socket_path \
        service_asset socket_asset _egress_dropin; do
        [[ -n "${package}" ]] || continue
        for template in "${PREFIX}/skills/${package}/${service_asset}" \
            "${PREFIX}/skills/${package}/${socket_asset}"; do
            target="${SYSTEMD_UNIT_DIR}/$(basename -- "${template}")"
            [[ -f "${template}" && ! -L "${template}" ]] ||
                fail "Skill ${package} 缺少声明的 credential helper unit: ${template}"
            rendered="${render_root}/.${target##*/}.$$"
            render_systemd_unit "${template}" "${rendered}"
            cp -- "${rendered}" "${target}"
            chmod 0644 "${target}"
            installed_units+=("${target}")
        done
    done < <(credential_component_rows)
    remove_stale_credential_systemd_files
    install_provider_egress_policy
    restore_selinux_paths "${PREFIX}" "${installed_units[@]}" "${SYSTEMD_EGRESS_DROPIN_PATH}"
    verify_service_runtime_access
    verify_runner_runtime_access
    verify_systemd_unit_files
    systemctl daemon-reload
}

install_host_ops_policy() {
    local registry template="" parent package asset
    local -a templates=()
    [[ "${NO_SYSTEMD}" -eq 0 ]] || return 0
    registry="$(skill_component_registry)"
    while IFS=$'\t' read -r package asset; do
        [[ -n "${package}" && -n "${asset}" ]] || continue
        templates+=("${PREFIX}/skills/${package}/${asset}")
    done < <(jq -er '
        .skills[]
        | select(.state == "installed" and (.components.host_helper.policy_asset | type) == "string")
        | [.name, .components.host_helper.policy_asset]
        | @tsv
    ' <<<"${registry}")
    if [[ "${#templates[@]}" -eq 0 ]]; then
        return 0
    fi
    [[ "${#templates[@]}" -eq 1 ]] ||
        fail '多个 host helper Skill 声明了互斥的全局 policy 资产'
    template="${templates[0]}"
    [[ -f "${template}" && ! -L "${template}" ]] ||
        fail 'Skill 组件注册表声明的 host operations policy 模板不可用'
    parent="$(dirname -- "${HOST_OPS_POLICY_PATH}")"
    if [[ -L "${parent}" || (-e "${parent}" && ! -d "${parent}") ]]; then
        fail "host operations policy 父目录类型非法: ${parent}"
    fi
    mkdir -p -- "${parent}"
    chown root:root "${parent}"
    chmod 0755 "${parent}"
    python3 - "${HOST_OPS_POLICY_PATH}" "${template}" <<'PY'
import json
import os
import re
import stat
import sys
from pathlib import Path

path = Path(sys.argv[1])
template = Path(sys.argv[2])
unit_pattern = re.compile(r"^[A-Za-z0-9][A-Za-z0-9:_.@-]{0,254}\.service$")


def reject_duplicates(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate key: {key}")
        result[key] = value
    return result


def load(raw):
    value = json.loads(
        raw,
        object_pairs_hook=reject_duplicates,
        parse_constant=lambda item: (_ for _ in ()).throw(ValueError(item)),
    )
    if not isinstance(value, dict) or set(value) != {
        "schema_version",
        "service_restart_units",
        "systemd_dropin_units",
    } or value.get("schema_version") != 1:
        raise ValueError("invalid policy schema")
    for name in ("service_restart_units", "systemd_dropin_units"):
        units = value.get(name)
        if not isinstance(units, list) or len(units) > 256 or len(units) != len(set(units)):
            raise ValueError(f"invalid {name}")
        if any(
            not isinstance(unit, str)
            or unit_pattern.fullmatch(unit) is None
            or unit == "systemd.service"
            or unit.startswith("linux-agent-")
            for unit in units
        ):
            raise ValueError(f"invalid {name} unit")
    return value


if path.exists() or path.is_symlink():
    metadata = path.lstat()
    if (
        not stat.S_ISREG(metadata.st_mode)
        or stat.S_ISLNK(metadata.st_mode)
        or metadata.st_uid != 0
        or metadata.st_gid != 0
        or stat.S_IMODE(metadata.st_mode) != 0o600
        or metadata.st_size > 65_536
    ):
        raise SystemExit("existing host operations policy metadata is invalid")
    load(path.read_text(encoding="utf-8"))
    raise SystemExit(0)

raw = template.read_text(encoding="utf-8")
load(raw)
flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
descriptor = os.open(path, flags, 0o600)
try:
    payload = raw.encode("utf-8")
    offset = 0
    while offset < len(payload):
        offset += os.write(descriptor, payload[offset:])
    os.fchmod(descriptor, 0o600)
    os.fchown(descriptor, 0, 0)
    os.fsync(descriptor)
finally:
    os.close(descriptor)
directory = os.open(path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
try:
    os.fsync(directory)
finally:
    os.close(directory)
PY
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

observer_helper_request() {
    local operation="$1"
    local helper="${2:-${PREFIX}/current/lib/observer_helper.py}"
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
            python3 "${helper}" request --socket "${socket_path}" "${operation}"
        return
    fi
    current_user="$(id -un)" || return 1
    if [[ "${current_user}" != "${SERVICE_USER}" ]]; then
        printf 'observer helper 健康检查必须由 root 或 Web 服务用户 %s 执行（当前用户: %s）\n' \
            "${SERVICE_USER}" "${current_user}" >&2
        return 1
    fi
    python3 "${helper}" request --socket "${socket_path}" "${operation}"
}

observer_helper_health_request() {
    observer_helper_request ping "${1:-${PREFIX}/current/lib/observer_helper.py}"
}

observer_helper_audit_preflight_request() {
    observer_helper_request status "${1:-${PREFIX}/current/lib/observer_helper.py}"
}

health_request() {
    local output credential_helpers
    output="$(web_health_request)" || return 1
    if [[ "${NO_SYSTEMD}" -eq 1 ]]; then
        printf '%s\n' "${output}"
        return 0
    fi
    observer_helper_health_request || return 1
    runner_health_request || return 1
    host_helper_health_request || return 1
    policy_helper_health_request || return 1
    credential_helpers="$(credential_helpers_health_request)" || return 1
    jq -c --argjson credential_helpers "${credential_helpers}" '
        . + {
            observer_helper:{ok:true,status:"ready"},
            execution_helpers:{
                runner:"ready",
                host_ops:"ready",
                policy_writer:"ready",
                credential_helpers:$credential_helpers
            }
        }
    ' <<<"${output}"
}

runner_health_request() {
    local client="${PREFIX}/current/lib/runner.py"
    local socket_path="${LINUX_AGENT_RUNNER_SOCKET:-/run/linux-agent/runner.sock}"
    [[ -f "${client}" && ! -L "${client}" ]] || return 1
    if [[ "${EUID}" -eq 0 && "${SERVICE_USER}" != "root" ]]; then
        runuser -u "${SERVICE_USER}" -- python3 "${client}" ping --socket "${socket_path}"
    else
        python3 "${client}" ping --socket "${socket_path}"
    fi
}

host_helper_health_request() {
    local client="${PREFIX}/current/lib/host_ops_helper.py"
    local socket_path="${LINUX_AGENT_HOST_HELPER_SOCKET:-/run/linux-agent/host-ops.sock}"
    [[ -f "${client}" && ! -L "${client}" ]] || return 1
    if [[ "${EUID}" -eq 0 && "${SERVICE_USER}" != "root" ]]; then
        runuser -u "${SERVICE_USER}" -- python3 "${client}" request \
            --socket "${socket_path}" ping --params '{}' --summary 'Check host helper readiness'
    else
        python3 "${client}" request --socket "${socket_path}" ping \
            --params '{}' --summary 'Check host helper readiness'
    fi
}

policy_helper_health_request() {
    local client="${PREFIX}/current/lib/policy_helper.py"
    local socket_path="${LINUX_AGENT_POLICY_HELPER_SOCKET:-/run/linux-agent/policy-writer.sock}"
    [[ -f "${client}" && ! -L "${client}" ]] || return 1
    if [[ "${EUID}" -eq 0 && "${SERVICE_USER}" != "root" ]]; then
        runuser -u "${SERVICE_USER}" -- python3 "${client}" request \
            --socket "${socket_path}" ping --params '{}' --summary 'Check policy helper readiness'
    else
        python3 "${client}" request --socket "${socket_path}" ping \
            --params '{}' --summary 'Check policy helper readiness'
    fi
}

credential_helpers_health_request() {
    local package component client socket_env socket_path _service_asset _socket_asset
    local _egress_dropin configured_socket status='{}'
    while IFS=$'\t' read -r package component client socket_env socket_path \
        _service_asset _socket_asset _egress_dropin; do
        [[ -n "${package}" ]] || continue
        client="${PREFIX}/skills/${package}/${client}"
        [[ -f "${client}" && ! -L "${client}" ]] || return 1
        configured_socket="${!socket_env:-${socket_path}}"
        if [[ "${EUID}" -eq 0 && "${SERVICE_USER}" != "root" ]]; then
            runuser -u "${SERVICE_USER}" -- env \
                "PYTHONPATH=${PREFIX}/current/lib" python3 "${client}" request \
                --socket "${configured_socket}" ping --params '{}' \
                --summary "Check ${component} helper readiness" >/dev/null || return 1
        else
            PYTHONPATH="${PREFIX}/current/lib" python3 "${client}" request \
                --socket "${configured_socket}" ping \
                --params '{}' --summary "Check ${component} helper readiness" >/dev/null || return 1
        fi
        status="$(jq -c --arg name "${component}" '. + {($name):"ready"}' <<<"${status}")" ||
            return 1
    done < <(credential_component_rows)
    printf '%s\n' "${status}"
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
    local -a credential_units=()
    local -a units=(
        linux-agent-observer-helper.socket linux-agent-runner.socket
        linux-agent-mcp-stdio.socket
        linux-agent-host-ops.socket linux-agent-policy-writer.socket
    )
    [[ "${NO_SYSTEMD}" -eq 0 ]] || return 0
    mapfile -t credential_units < <(installed_credential_unit_names | grep '[.]socket$' || true)
    units+=("${credential_units[@]}" linux-agent-web.service)
    systemctl restart "${units[@]}" || return 1
    wait_for_health >/dev/null || return 1
}

run_install_health_check() {
    local health_started_at health_ok=0 startup_ok=0 cleanup_ok=1 unit
    local -a units=(
        linux-agent-web.service
        linux-agent-observer-helper.service
        linux-agent-observer-helper.socket
        linux-agent-runner.service
        linux-agent-runner.socket
        linux-agent-mcp-stdio.service
        linux-agent-mcp-stdio.socket
        linux-agent-host-ops.service
        linux-agent-host-ops.socket
        linux-agent-policy-writer.service
        linux-agent-policy-writer.socket
    )
    local -a credential_units=()
    local -a start_units=(
        linux-agent-observer-helper.socket linux-agent-runner.socket
        linux-agent-mcp-stdio.socket
        linux-agent-host-ops.socket linux-agent-policy-writer.socket
    )
    mapfile -t credential_units < <(installed_credential_unit_names)
    units+=("${credential_units[@]}")

    health_started_at="$(date --iso-8601=seconds)"

    # systemctl start does not replace an already-running process. Stop any
    # pre-existing instance so the health request always reaches this release.
    for unit in "${units[@]}"; do
        systemctl stop "${unit}" || cleanup_ok=0
    done
    if [[ "${cleanup_ok}" -ne 1 ]]; then
        warn '无法停止安装前已存在的服务进程'
        report_install_health_failure "${health_started_at}"
    else
        mapfile -t credential_units < <(installed_credential_unit_names | grep '[.]socket$' || true)
        start_units+=("${credential_units[@]}" linux-agent-web.service)
        if systemctl start "${start_units[@]}"; then
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
        linux-agent-runner.service
        linux-agent-runner.socket
        linux-agent-mcp-stdio.service
        linux-agent-mcp-stdio.socket
        linux-agent-host-ops.service
        linux-agent-host-ops.socket
        linux-agent-policy-writer.service
        linux-agent-policy-writer.socket
    )
    local -a credential_units=()
    mapfile -t credential_units < <(installed_credential_unit_names)
    units+=("${credential_units[@]}")

    warn '以下为安装健康检查失败时的 systemd 状态：'
    systemctl status --no-pager --full "${units[@]}" >&2 || true
    if command -v journalctl >/dev/null 2>&1; then
        warn '以下为本次安装健康检查期间的 journal：'
        local -a journal_arguments=(
            --no-pager --since "${health_started_at}" -n 80
            -u linux-agent-web.service
            -u linux-agent-observer-helper.service
            -u linux-agent-observer-helper.socket
            -u linux-agent-runner.service
            -u linux-agent-mcp-stdio.service
            -u linux-agent-host-ops.service
            -u linux-agent-policy-writer.service
        )
        while IFS= read -r unit; do
            [[ "${unit}" == *.service ]] && journal_arguments+=(-u "${unit}")
        done < <(installed_credential_unit_names)
        journalctl "${journal_arguments[@]}" >&2 || true
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
        rm -rf -- "${PREFIX}/skill-releases/${version}"
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
    local -a enable_units=(
        linux-agent-observer-helper.socket linux-agent-runner.socket
        linux-agent-mcp-stdio.socket
        linux-agent-host-ops.socket linux-agent-policy-writer.socket
    )
    local -a credential_sockets=()
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
    capture_systemd_state
    stop_transaction_services
    capture_persistent_data_state
    prepare_persistent_layout
    acquire_runtime_transaction_lock
    capture_builtin_skills_state
    ensure_service_identity
    migrate_managed_layout ""
    configure_managed_data_permissions
    set_config_version "${VERSION}"
    validate_persistent_overlays
    install_prepared_builtin_skills
    atomic_switch "${VERSION}"
    if [[ "${NO_SYSTEMD}" -eq 0 ]]; then
        install_systemd_unit
        update_skill_component_ledger
        release_runtime_transaction_lock
        run_install_health_check || install_health_status=$?
        case "${install_health_status}" in
            0) ;;
            1) fail '安装后健康检查失败；临时服务已停止' ;;
            2) fail '安装后无法停止临时健康检查服务' ;;
            3) fail '安装后无法启动临时健康检查服务；临时单元已停止' ;;
            *) fail '安装后临时健康检查失败' ;;
        esac
    else
        update_skill_component_ledger
    fi
    write_install_state true
    finalize_no_systemd_ownership
    commit_transaction
    info "已安装 ${VERSION}: ${release_dir}"
    if [[ "${NO_SYSTEMD}" -eq 0 ]]; then
        mapfile -t credential_sockets < <(installed_credential_unit_names | grep '[.]socket$' || true)
        enable_units+=("${credential_sockets[@]}" linux-agent-web.service)
        info "安装后健康检查已通过，临时服务已停止；安装器未修改原有开机启用状态，需要长期运行时请显式执行 systemctl enable --now ${enable_units[*]}"
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
    capture_systemd_state
    stop_transaction_services
    acquire_runtime_transaction_lock
    capture_builtin_skills_state
    capture_persistent_data_state
    prepare_persistent_layout
    ensure_service_identity
    migrate_managed_layout "${old_version}"
    configure_managed_data_permissions
    set_config_version "${VERSION}"
    validate_persistent_overlays
    install_prepared_builtin_skills
    atomic_switch "${VERSION}"
    install_systemd_unit
    update_skill_component_ledger
    release_runtime_transaction_lock
    if ! restart_and_check; then
        warn "${VERSION} 健康检查失败，正在自动回滚到 ${old_version}"
        fail '升级失败，已恢复旧版本'
    fi
    append_history "${old_version}"
    write_install_state true
    finalize_no_systemd_ownership
    commit_transaction
    prune_releases
    info "已从 ${old_version} 升级到 ${VERSION}: ${release_dir}"
}

do_rollback() {
    local old_version target target_release migration_tool
    ensure_prefix
    load_existing_service_identity
    validate_service_identity
    old_version="$(current_version)" || fail '未检测到现有安装'
    target="$(rollback_target)" || fail '没有可回滚的历史版本'
    begin_transaction rollback "${old_version}" "${target}"
    capture_systemd_state
    stop_transaction_services
    acquire_runtime_transaction_lock
    capture_persistent_data_state
    ensure_service_identity
    target_release="${PREFIX}/releases/${target}"
    PREPARED_SKILLS_DIR="${PREFIX}/skill-releases/${target}/skills"
    PREPARED_SKILLS_MANIFEST="${PREFIX}/skill-releases/${target}/release-manifest.json"
    migration_tool="${PREFIX}/current/lib/layout_migration.py"
    [[ -d "${target_release}" && ! -L "${target_release}" ]] || fail '回滚目标 release 不可用'
    [[ -d "${PREPARED_SKILLS_DIR}" && ! -L "${PREPARED_SKILLS_DIR}" &&
        -f "${PREPARED_SKILLS_MANIFEST}" && ! -L "${PREPARED_SKILLS_MANIFEST}" ]] ||
        fail '回滚目标缺少内置 Skill 版本快照'
    capture_builtin_skills_state
    [[ -f "${migration_tool}" && ! -L "${migration_tool}" ]] || fail '当前版本缺少可逆 overlay 迁移器'
    migrate_managed_layout "${old_version}" "${target_release}" "${migration_tool}"
    configure_managed_data_permissions
    validate_persistent_overlays "${target_release}"
    set_config_version "${target}"
    install_prepared_builtin_skills
    atomic_switch "${target}"
    install_systemd_unit
    update_skill_component_ledger
    release_runtime_transaction_lock
    if ! restart_and_check; then
        fail '回滚目标健康检查失败，已恢复原版本'
    fi
    append_history "${old_version}"
    write_install_state true
    finalize_no_systemd_ownership
    commit_transaction
    info "已从 ${old_version} 回滚到 ${target}"
}

do_health() {
    ensure_prefix
    load_existing_service_identity
    validate_service_identity
    health_request || fail '健康检查失败'
}

validate_observer_repair_socket_path() {
    local socket_path="$1" socket_dir socket_name
    [[ "${socket_path}" == /* && "${socket_path}" != *$'\n'* ]] ||
        fail 'observer helper socket 路径非法'
    socket_dir="$(dirname -- "${socket_path}")"
    socket_name="$(basename -- "${socket_path}")"
    if [[ "${socket_dir}" == "/run/linux-agent" &&
        "${socket_name}" =~ ^[a-zA-Z0-9_.-]+[.]sock$ ]]; then
        return 0
    fi
    if [[ "${LINUX_AGENT_ALLOW_UNSAFE_SYSTEMD_TEST_PREFIX:-0}" == "1" &&
        "${SYSTEMD_UNIT_PATH}" == "${PREFIX}/"* &&
        "${socket_path}" == "${PREFIX}/"* ]]; then
        warn "仅测试：允许非 /run/linux-agent 的 observer socket ${socket_path}"
        return 0
    fi
    fail 'repair-observer 仅允许重建 /run/linux-agent 目录内的 .sock 文件'
}

restore_observer_repair_activity() {
    local web_was_active="$1" socket_was_active="$2" failed=0
    if [[ "${web_was_active}" -eq 1 ]]; then
        [[ "${socket_was_active}" -eq 1 ]] || return 1
        systemctl start linux-agent-observer-helper.socket linux-agent-web.service || failed=1
    else
        systemctl stop linux-agent-web.service || failed=1
        if [[ "${socket_was_active}" -eq 1 ]]; then
            systemctl start linux-agent-observer-helper.socket || failed=1
        else
            systemctl stop linux-agent-observer-helper.service || failed=1
            systemctl stop linux-agent-observer-helper.socket || failed=1
        fi
    fi
    return "${failed}"
}

write_source_observer_socket_dropin() {
    local dropin_dir="$1" dropin_path="$2" service_group="$3" work_dir="$4" target_tmp=""
    mkdir -p -- "${dropin_dir}" || return 1
    printf '%s\n%s\n%s\n' \
        '# Managed by linux-agent-install.sh repair-observer for a source checkout.' \
        '[Socket]' "SocketGroup=${service_group}" >"${work_dir}/socket-group.conf" || return 1
    target_tmp="$(mktemp "${dropin_dir}/.10-socket-group.conf.XXXXXX")" || return 1
    if ! cp -- "${work_dir}/socket-group.conf" "${target_tmp}" ||
        ! chmod 0644 "${target_tmp}" ||
        ! mv -f -- "${target_tmp}" "${dropin_path}"; then
        rm -f -- "${target_tmp}"
        return 1
    fi
}

install_source_observer_helper_runtime() {
    local source_prefix="$1" install_root="$2" digest runtime_dir staging_dir=""
    local resolved_root owner mode path helper_sha env_sha protocol_sha runtime_helper_sha runtime_env_sha runtime_protocol_sha
    local helper_source="${source_prefix}/lib/observer_helper.py"
    local env_source="${source_prefix}/lib/subprocess_env.py"
    local protocol_source="${source_prefix}/lib/helper_protocol.py"
    [[ -f "${helper_source}" && ! -L "${helper_source}" &&
        -f "${env_source}" && ! -L "${env_source}" &&
        -f "${protocol_source}" && ! -L "${protocol_source}" ]] || return 1
    helper_sha="$(sha256sum "${helper_source}" | awk '{print $1}')" || return 1
    env_sha="$(sha256sum "${env_source}" | awk '{print $1}')" || return 1
    protocol_sha="$(sha256sum "${protocol_source}" | awk '{print $1}')" || return 1
    digest="$(printf '%s\n%s\n%s\n' "${helper_sha}" "${env_sha}" "${protocol_sha}" | sha256sum | awk '{print $1}')" ||
        return 1
    [[ "${digest}" =~ ^[0-9a-f]{64}$ ]] || return 1
    if [[ -L "${install_root}" || (-e "${install_root}" && ! -d "${install_root}") ]]; then
        return 1
    fi
    mkdir -p -- "${install_root}" || return 1
    chown root:root "${install_root}" || return 1
    chmod 0755 "${install_root}" || return 1
    resolved_root="$(readlink -f -- "${install_root}")" || return 1
    [[ "${resolved_root}" == "${install_root}" ]] || return 1
    owner="$(stat -c '%u:%g' "${install_root}")" || return 1
    mode="$(stat -c '%a' "${install_root}")" || return 1
    [[ "${owner}" == "0:0" ]] || return 1
    (((8#${mode} & 0022) == 0)) || return 1
    runtime_dir="${install_root}/${digest}"
    if [[ -d "${runtime_dir}" && ! -L "${runtime_dir}" ]]; then
        [[ -f "${runtime_dir}/observer_helper.py" && ! -L "${runtime_dir}/observer_helper.py" &&
            -f "${runtime_dir}/subprocess_env.py" && ! -L "${runtime_dir}/subprocess_env.py" &&
            -f "${runtime_dir}/helper_protocol.py" && ! -L "${runtime_dir}/helper_protocol.py" ]] || return 1
        runtime_helper_sha="$(sha256sum "${runtime_dir}/observer_helper.py" | awk '{print $1}')" || return 1
        runtime_env_sha="$(sha256sum "${runtime_dir}/subprocess_env.py" | awk '{print $1}')" || return 1
        runtime_protocol_sha="$(sha256sum "${runtime_dir}/helper_protocol.py" | awk '{print $1}')" || return 1
        [[ "${runtime_helper_sha}" == "${helper_sha}" && "${runtime_env_sha}" == "${env_sha}" &&
            "${runtime_protocol_sha}" == "${protocol_sha}" ]] ||
            return 1
        for path in "${runtime_dir}" "${runtime_dir}/observer_helper.py" \
            "${runtime_dir}/subprocess_env.py" "${runtime_dir}/helper_protocol.py"; do
            [[ "$(stat -c '%u:%g' "${path}")" == "0:0" ]] || return 1
            mode="$(stat -c '%a' "${path}")" || return 1
            (((8#${mode} & 0022) == 0)) || return 1
        done
        printf '%s\n' "${runtime_dir}"
        return 0
    fi
    [[ ! -e "${runtime_dir}" ]] || return 1
    staging_dir="$(mktemp -d "${install_root}/.staging.XXXXXX")" || return 1
    if ! cp -- "${helper_source}" "${staging_dir}/observer_helper.py" ||
        ! cp -- "${env_source}" "${staging_dir}/subprocess_env.py" ||
        ! cp -- "${protocol_source}" "${staging_dir}/helper_protocol.py" ||
        ! chmod 0755 "${staging_dir}" "${staging_dir}/observer_helper.py" ||
        ! chmod 0644 "${staging_dir}/subprocess_env.py" "${staging_dir}/helper_protocol.py" ||
        ! chown -R root:root "${staging_dir}"; then
        rm -rf -- "${staging_dir}"
        return 1
    fi
    runtime_helper_sha="$(sha256sum "${staging_dir}/observer_helper.py" | awk '{print $1}')" || {
        rm -rf -- "${staging_dir}"
        return 1
    }
    runtime_env_sha="$(sha256sum "${staging_dir}/subprocess_env.py" | awk '{print $1}')" || {
        rm -rf -- "${staging_dir}"
        return 1
    }
    runtime_protocol_sha="$(sha256sum "${staging_dir}/helper_protocol.py" | awk '{print $1}')" || {
        rm -rf -- "${staging_dir}"
        return 1
    }
    if [[ "${runtime_helper_sha}" != "${helper_sha}" || "${runtime_env_sha}" != "${env_sha}" ||
        "${runtime_protocol_sha}" != "${protocol_sha}" ]] ||
        ! mv -- "${staging_dir}" "${runtime_dir}"; then
        rm -rf -- "${staging_dir}"
        return 1
    fi
    printf '%s\n' "${runtime_dir}"
}

write_source_observer_service_dropin() {
    local dropin_dir="$1" dropin_path="$2" runtime_dir="$3" service_user="$4" work_dir="$5" data_dir="$6" target_tmp=""
    [[ "${runtime_dir}" =~ ^/[a-zA-Z0-9_./-]+$ ]] || return 1
    [[ "${data_dir}" =~ ^/[a-zA-Z0-9_./-]+$ ]] || return 1
    mkdir -p -- "${dropin_dir}" || return 1
    printf '%s\n%s\n%s\n%s\n%s\n%s\n' \
        '# Managed by linux-agent-install.sh repair-observer for a source checkout.' \
        '[Service]' 'ExecStart=' \
        "ExecStart=/usr/bin/python3 ${runtime_dir}/observer_helper.py serve" \
        "Environment=LINUX_AGENT_SERVICE_USER=${service_user}" \
        "Environment=LINUX_AGENT_DATA_DIR=${data_dir}" \
        >"${work_dir}/source-helper-service.conf" || return 1
    target_tmp="$(mktemp "${dropin_dir}/.10-source-runtime.conf.XXXXXX")" || return 1
    if ! cp -- "${work_dir}/source-helper-service.conf" "${target_tmp}" ||
        ! chmod 0644 "${target_tmp}" ||
        ! mv -f -- "${target_tmp}" "${dropin_path}"; then
        rm -f -- "${target_tmp}"
        return 1
    fi
}

restore_source_observer_activity() {
    local socket_was_active="$1" helper_was_active="$2" failed=0
    if [[ "${socket_was_active}" -eq 1 ]]; then
        systemctl start linux-agent-observer-helper.socket || failed=1
        if [[ "${helper_was_active}" -eq 1 ]]; then
            systemctl start linux-agent-observer-helper.service || failed=1
        else
            systemctl stop linux-agent-observer-helper.service || failed=1
        fi
    else
        systemctl stop linux-agent-observer-helper.socket || failed=1
        if [[ "${helper_was_active}" -eq 1 ]]; then
            systemctl start linux-agent-observer-helper.service || failed=1
        else
            systemctl stop linux-agent-observer-helper.service || failed=1
        fi
    fi
    return "${failed}"
}

rollback_source_observer_repair() {
    local socket_dropin_dir="$1" socket_dropin_path="$2" socket_backup_path="$3"
    local socket_dropin_existed="$4" service_dropin_dir="$5" service_dropin_path="$6"
    local service_backup_path="$7" service_dropin_existed="$8"
    local socket_was_active="$9" helper_was_active="${10}" failed=0
    if [[ "${socket_dropin_existed}" -eq 1 ]]; then
        cp -p -- "${socket_backup_path}" "${socket_dropin_path}" || failed=1
    else
        rm -f -- "${socket_dropin_path}" || failed=1
        rmdir -- "${socket_dropin_dir}" 2>/dev/null || true
    fi
    if [[ "${service_dropin_existed}" -eq 1 ]]; then
        cp -p -- "${service_backup_path}" "${service_dropin_path}" || failed=1
    else
        rm -f -- "${service_dropin_path}" || failed=1
        rmdir -- "${service_dropin_dir}" 2>/dev/null || true
    fi
    restore_observer_helper_state || failed=1
    systemctl daemon-reload || failed=1
    restore_source_observer_activity "${socket_was_active}" "${helper_was_active}" || failed=1
    return "${failed}"
}

capture_observer_helper_state() {
    local backup_dir="$1"
    local state_path="${LINUX_AGENT_OBSERVER_HELPER_STATE:-/run/linux-agent/observer-capabilities.json}"
    if [[ "${state_path}" != "/run/linux-agent/observer-capabilities.json" ]]; then
        if [[ "${LINUX_AGENT_ALLOW_UNSAFE_SYSTEMD_TEST_PREFIX:-0}" != "1" ||
            "${state_path}" != "${PREFIX}/"* ]]; then
            return 1
        fi
    fi
    if [[ -L "${state_path}" || (-e "${state_path}" && ! -f "${state_path}") ]]; then
        return 1
    fi
    local backup_path="${backup_dir}/observer-capabilities.json"
    if [[ -f "${state_path}" ]]; then
        cp -p -- "${state_path}" "${backup_path}" || return 1
        OBSERVER_STATE_EXISTED=1
    else
        OBSERVER_STATE_EXISTED=0
    fi
    OBSERVER_STATE_PATH="${state_path}"
    OBSERVER_STATE_BACKUP_PATH="${backup_path}"
    OBSERVER_STATE_CAPTURED=1
}

reset_observer_helper_state() {
    [[ "${OBSERVER_STATE_CAPTURED}" -eq 1 && -n "${OBSERVER_STATE_PATH}" ]] || return 1
    local state_path="${OBSERVER_STATE_PATH}"
    rm -f -- "${state_path}"
}

restore_observer_helper_state() {
    local state_tmp
    [[ "${OBSERVER_STATE_CAPTURED}" -eq 1 && -n "${OBSERVER_STATE_PATH}" ]] || return 0
    if [[ "${OBSERVER_STATE_EXISTED}" -eq 1 ]]; then
        [[ -f "${OBSERVER_STATE_BACKUP_PATH}" && ! -L "${OBSERVER_STATE_BACKUP_PATH}" ]] || return 1
        mkdir -p -- "$(dirname -- "${OBSERVER_STATE_PATH}")" || return 1
        state_tmp="${OBSERVER_STATE_PATH}.repair.$$"
        cp -p -- "${OBSERVER_STATE_BACKUP_PATH}" "${state_tmp}" || return 1
        mv -f -- "${state_tmp}" "${OBSERVER_STATE_PATH}" || {
            rm -f -- "${state_tmp}"
            return 1
        }
    else
        rm -f -- "${OBSERVER_STATE_PATH}" || return 1
    fi
    OBSERVER_STATE_CAPTURED=0
}

do_repair_observer() {
    local socket_path="${LINUX_AGENT_OBSERVER_HELPER_SOCKET:-/run/linux-agent/observer.sock}"
    local installed_user="" managed_version="" socket_dropin_dir socket_dropin_path
    local service_dropin_dir="" service_dropin_path="" source_runtime_root="" source_runtime_dir=""
    local source_dropin_existed=0 source_service_dropin_existed=0 source_helper_was_active=0
    local web_was_active=0 socket_was_active=0
    ensure_prefix existing
    [[ "${NO_SYSTEMD}" -eq 0 ]] || fail 'repair-observer 需要 systemd observer helper'
    command -v systemctl >/dev/null 2>&1 || fail '缺少 systemctl'
    validate_observer_repair_socket_path "${socket_path}"
    if [[ -L "${socket_path}" || (-e "${socket_path}" && ! -S "${socket_path}") ]]; then
        fail "拒绝删除非普通 Unix socket: ${socket_path}"
    fi

    if [[ -L "${PREFIX}/current" ]]; then
        managed_version="$(current_version)"
        load_existing_service_identity
        validate_service_identity
        id "${SERVICE_USER}" >/dev/null 2>&1 || fail "Web 服务用户不存在: ${SERVICE_USER}"
        SERVICE_GROUP="$(id -gn "${SERVICE_USER}")" || fail "无法确定 Web 服务用户主组: ${SERVICE_USER}"
        ensure_service_identity

        # Re-render the units first so SocketGroup follows the actual Web
        # service primary group, then recreate the socket inode instead of
        # trusting a stale socket left by an older release or daemon-reload.
        if systemctl is-active --quiet linux-agent-web.service >/dev/null 2>&1; then
            web_was_active=1
        fi
        if systemctl is-active --quiet linux-agent-observer-helper.socket >/dev/null 2>&1; then
            socket_was_active=1
        fi
        if [[ "${web_was_active}" -eq 1 && "${socket_was_active}" -eq 0 ]]; then
            fail 'Web 正在运行但其必需的 observer helper socket 已停止；请先显式启动 socket 或停止 Web'
        fi
        begin_transaction repair "${managed_version}" "${managed_version}"
        capture_systemd_state
        WORK_DIR="$(mktemp -d "${PREFIX}/.install-staging.repair-observer.XXXXXX")"
        chmod 0700 "${WORK_DIR}"
        install_systemd_unit
        if ! systemctl stop linux-agent-web.service \
            linux-agent-observer-helper.service \
            linux-agent-observer-helper.socket; then
            fail '无法停止 observer repair 所需的 systemd unit'
        fi
        capture_observer_helper_state "${TRANSACTION_BACKUP_DIR}" ||
            fail 'observer helper state 路径或文件类型非法'
        reset_observer_helper_state || fail '无法重置 observer helper capability 状态'
        if [[ -L "${socket_path}" || (-e "${socket_path}" && ! -S "${socket_path}") ]]; then
            fail "拒绝删除非普通 Unix socket: ${socket_path}"
        fi
        if [[ -S "${socket_path}" ]]; then
            rm -f -- "${socket_path}"
        fi
        systemctl start linux-agent-observer-helper.socket linux-agent-web.service ||
            fail 'observer socket 修复后无法启动临时健康检查服务'
        wait_for_health >/dev/null || fail 'observer socket 修复后健康检查失败'
        observer_helper_audit_preflight_request >/dev/null ||
            fail 'observer helper 可连接，但 auditd/auditctl 预检失败'
        restore_observer_repair_activity "${web_was_active}" "${socket_was_active}" ||
            fail 'observer socket 修复后无法恢复原服务运行状态'
        commit_transaction
        info 'observer helper socket 已重建，Web 用户权限健康检查通过'
        return
    fi

    [[ -x "${PREFIX}/bin/agent-web" &&
        -f "${PREFIX}/lib/observer_helper.py" &&
        -f "${PREFIX}/lib/subprocess_env.py" &&
        -f "${PREFIX}/packaging/linux-agent-observer-helper.service" &&
        -f "${PREFIX}/packaging/linux-agent-observer-helper.socket" ]] ||
        fail '目标既不是受管安装，也不是有效的 Linux Agent 源码目录'
    if [[ "${SERVICE_USER_EXPLICIT}" -eq 0 ]]; then
        if [[ -f "${SYSTEMD_UNIT_PATH}" && ! -L "${SYSTEMD_UNIT_PATH}" ]]; then
            installed_user="$(sed -n 's/^User=//p' "${SYSTEMD_UNIT_PATH}" | head -n 1)"
        fi
        [[ -n "${installed_user}" ]] ||
            fail '源码运行无法确定 Web 用户；请传入 --service-user <实际运行 bin/agent-web 的用户>'
        SERVICE_USER="${installed_user}"
    fi
    validate_service_identity
    id "${SERVICE_USER}" >/dev/null 2>&1 || fail "Web 服务用户不存在: ${SERVICE_USER}"
    SERVICE_GROUP="$(id -gn "${SERVICE_USER}")" || fail "无法确定 Web 服务用户主组: ${SERVICE_USER}"
    [[ "${SERVICE_GROUP}" =~ ^[a-zA-Z_][a-zA-Z0-9_.-]*[$]?$ ]] ||
        fail "Web 服务用户主组名称不适合写入 systemd unit: ${SERVICE_GROUP}"
    [[ "${SYSTEMD_UNIT_DIR}" == /* && "${SYSTEMD_UNIT_DIR}" != *$'\n'* ]] ||
        fail 'systemd unit 目录必须是绝对路径'
    case "/${SYSTEMD_UNIT_DIR#/}/" in
        */../* | */./*) fail 'systemd unit 目录不能包含 . 或 .. 路径分量' ;;
    esac
    [[ -d "${SYSTEMD_UNIT_DIR}" && ! -L "${SYSTEMD_UNIT_DIR}" ]] ||
        fail "systemd unit 目录不存在或类型非法: ${SYSTEMD_UNIT_DIR}"
    [[ "${SYSTEMD_HELPER_SOCKET_PATH}" == "${SYSTEMD_UNIT_DIR}/linux-agent-observer-helper.socket" ]] ||
        fail 'observer helper socket unit 必须位于 Web unit 的同一 systemd 目录'
    [[ "${SYSTEMD_HELPER_SERVICE_PATH}" == "${SYSTEMD_UNIT_DIR}/linux-agent-observer-helper.service" ]] ||
        fail 'observer helper service unit 必须位于 Web unit 的同一 systemd 目录'
    systemctl cat linux-agent-observer-helper.socket >/dev/null 2>&1 ||
        fail '未安装 linux-agent-observer-helper.socket；源码快速运行本身不会安装 systemd helper'
    systemctl cat linux-agent-observer-helper.service >/dev/null 2>&1 ||
        fail '未安装 linux-agent-observer-helper.service；源码快速运行本身不会安装 systemd helper'

    source_runtime_root="${LINUX_AGENT_SOURCE_HELPER_INSTALL_ROOT:-/usr/local/libexec/linux-agent-observer-helper}"
    if [[ "${source_runtime_root}" != "/usr/local/libexec/linux-agent-observer-helper" ]]; then
        if [[ "${LINUX_AGENT_ALLOW_UNSAFE_SYSTEMD_TEST_PREFIX:-0}" != "1" ||
            "${source_runtime_root}" != "${PREFIX}/"* ]]; then
            fail '源码 observer helper runtime 只能安装到 /usr/local/libexec/linux-agent-observer-helper'
        fi
    fi
    [[ "${source_runtime_root}" == /* && "${source_runtime_root}" != *$'\n'* ]] ||
        fail '源码 observer helper runtime 路径非法'
    case "/${source_runtime_root#/}/" in
        */../* | */./*) fail '源码 observer helper runtime 路径不能包含 . 或 ..' ;;
    esac

    WORK_DIR="$(mktemp -d "${PREFIX}/.install-staging.repair-observer.XXXXXX")"
    chmod 0700 "${WORK_DIR}"
    socket_dropin_dir="${SYSTEMD_HELPER_SOCKET_PATH}.d"
    socket_dropin_path="${socket_dropin_dir}/10-socket-group.conf"
    service_dropin_dir="${SYSTEMD_HELPER_SERVICE_PATH}.d"
    service_dropin_path="${service_dropin_dir}/10-source-runtime.conf"
    if [[ -L "${socket_dropin_dir}" || (-e "${socket_dropin_dir}" && ! -d "${socket_dropin_dir}") ]]; then
        fail "observer socket drop-in 目录类型非法: ${socket_dropin_dir}"
    fi
    if [[ -L "${socket_dropin_path}" || (-e "${socket_dropin_path}" && ! -f "${socket_dropin_path}") ]]; then
        fail "observer socket drop-in 文件类型非法: ${socket_dropin_path}"
    fi
    if [[ -L "${service_dropin_dir}" || (-e "${service_dropin_dir}" && ! -d "${service_dropin_dir}") ]]; then
        fail "observer helper service drop-in 目录类型非法: ${service_dropin_dir}"
    fi
    if [[ -L "${service_dropin_path}" || (-e "${service_dropin_path}" && ! -f "${service_dropin_path}") ]]; then
        fail "observer helper service drop-in 文件类型非法: ${service_dropin_path}"
    fi
    if [[ -f "${socket_dropin_path}" ]]; then
        cp -p -- "${socket_dropin_path}" "${WORK_DIR}/original-socket-group.conf"
        source_dropin_existed=1
    fi
    if [[ -f "${service_dropin_path}" ]]; then
        cp -p -- "${service_dropin_path}" "${WORK_DIR}/original-source-runtime.conf"
        source_service_dropin_existed=1
    fi
    if systemctl is-active --quiet linux-agent-observer-helper.socket >/dev/null 2>&1; then
        socket_was_active=1
    fi
    if systemctl is-active --quiet linux-agent-observer-helper.service >/dev/null 2>&1; then
        source_helper_was_active=1
    fi
    if ! write_source_observer_socket_dropin \
        "${socket_dropin_dir}" "${socket_dropin_path}" "${SERVICE_GROUP}" "${WORK_DIR}"; then
        fail '无法写入 observer socket 的源码部署 drop-in'
    fi
    source_runtime_dir="$(install_source_observer_helper_runtime "${PREFIX}" "${source_runtime_root}")" ||
        fail '无法安装源码 observer helper runtime'
    if ! write_source_observer_service_dropin \
        "${service_dropin_dir}" "${service_dropin_path}" "${source_runtime_dir}" "${SERVICE_USER}" "${WORK_DIR}" "${PREFIX}/data"; then
        rollback_source_observer_repair \
            "${socket_dropin_dir}" "${socket_dropin_path}" \
            "${WORK_DIR}/original-socket-group.conf" "${source_dropin_existed}" \
            "${service_dropin_dir}" "${service_dropin_path}" \
            "${WORK_DIR}/original-source-runtime.conf" "${source_service_dropin_existed}" \
            "${socket_was_active}" "${source_helper_was_active}" || true
        fail '无法写入 observer helper service 的源码 runtime drop-in'
    fi
    restore_selinux_paths "${source_runtime_root}" "${socket_dropin_path}" \
        "${service_dropin_path}" "$(dirname -- "${socket_path}")"
    verify_source_observer_systemd_unit_files \
        "${socket_dropin_path}" "${service_dropin_path}"
    if ! systemctl daemon-reload ||
        ! systemctl stop linux-agent-observer-helper.service linux-agent-observer-helper.socket; then
        rollback_source_observer_repair \
            "${socket_dropin_dir}" "${socket_dropin_path}" \
            "${WORK_DIR}/original-socket-group.conf" "${source_dropin_existed}" \
            "${service_dropin_dir}" "${service_dropin_path}" \
            "${WORK_DIR}/original-source-runtime.conf" "${source_service_dropin_existed}" \
            "${socket_was_active}" "${source_helper_was_active}" || true
        fail '无法重新加载或停止 observer helper socket'
    fi
    if ! capture_observer_helper_state "${WORK_DIR}" || ! reset_observer_helper_state; then
        rollback_source_observer_repair \
            "${socket_dropin_dir}" "${socket_dropin_path}" \
            "${WORK_DIR}/original-socket-group.conf" "${source_dropin_existed}" \
            "${service_dropin_dir}" "${service_dropin_path}" \
            "${WORK_DIR}/original-source-runtime.conf" "${source_service_dropin_existed}" \
            "${socket_was_active}" "${source_helper_was_active}" || true
        fail 'observer helper state 路径、类型或重置操作失败'
    fi
    if [[ -L "${socket_path}" || (-e "${socket_path}" && ! -S "${socket_path}") ]]; then
        rollback_source_observer_repair \
            "${socket_dropin_dir}" "${socket_dropin_path}" \
            "${WORK_DIR}/original-socket-group.conf" "${source_dropin_existed}" \
            "${service_dropin_dir}" "${service_dropin_path}" \
            "${WORK_DIR}/original-source-runtime.conf" "${source_service_dropin_existed}" \
            "${socket_was_active}" "${source_helper_was_active}" || true
        fail "拒绝删除非普通 Unix socket: ${socket_path}"
    fi
    if [[ -S "${socket_path}" ]] && ! rm -f -- "${socket_path}"; then
        rollback_source_observer_repair \
            "${socket_dropin_dir}" "${socket_dropin_path}" \
            "${WORK_DIR}/original-socket-group.conf" "${source_dropin_existed}" \
            "${service_dropin_dir}" "${service_dropin_path}" \
            "${WORK_DIR}/original-source-runtime.conf" "${source_service_dropin_existed}" \
            "${socket_was_active}" "${source_helper_was_active}" || true
        fail "无法删除旧 observer helper socket: ${socket_path}"
    fi
    if ! systemctl start linux-agent-observer-helper.socket ||
        ! observer_helper_health_request "${PREFIX}/lib/observer_helper.py" >/dev/null ||
        ! observer_helper_audit_preflight_request "${PREFIX}/lib/observer_helper.py" >/dev/null; then
        rollback_source_observer_repair \
            "${socket_dropin_dir}" "${socket_dropin_path}" \
            "${WORK_DIR}/original-socket-group.conf" "${source_dropin_existed}" \
            "${service_dropin_dir}" "${service_dropin_path}" \
            "${WORK_DIR}/original-source-runtime.conf" "${source_service_dropin_existed}" \
            "${socket_was_active}" "${source_helper_was_active}" || true
        fail 'observer socket 修复后仍无法由源码 Web 用户访问；请检查 observer helper service journal'
    fi
    if ! restore_source_observer_activity "${socket_was_active}" "${source_helper_was_active}"; then
        rollback_source_observer_repair \
            "${socket_dropin_dir}" "${socket_dropin_path}" \
            "${WORK_DIR}/original-socket-group.conf" "${source_dropin_existed}" \
            "${service_dropin_dir}" "${service_dropin_path}" \
            "${WORK_DIR}/original-source-runtime.conf" "${source_service_dropin_existed}" \
            "${socket_was_active}" "${source_helper_was_active}" || true
        fail 'observer socket 修复后无法恢复原 helper 运行状态'
    fi
    info "observer helper socket 已按源码 Web 用户 ${SERVICE_USER}:${SERVICE_GROUP} 重建，权限健康检查通过"
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
        if [[ -n "${INSTALL_STATE_RUNNER_USER}" ]]; then
            RUNNER_USER="${INSTALL_STATE_RUNNER_USER}"
            RUNNER_USER_CREATED="${INSTALL_STATE_RUNNER_USER_CREATED}"
        fi
        if [[ -n "${INSTALL_STATE_CREDENTIAL_USER}" ]]; then
            CREDENTIAL_USER="${INSTALL_STATE_CREDENTIAL_USER}"
            CREDENTIAL_USER_CREATED="${INSTALL_STATE_CREDENTIAL_USER_CREATED}"
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
    local path unit skill result ledger="${PREFIX}/data/skill-components.json"
    local -a credential_files=() credential_units=()
    local -a ledger_skills=()
    validate_uninstall_target
    if [[ -f "${ledger}" && ! -L "${ledger}" &&
        -f "${PREFIX}/current/lib/skill_component_ledger.py" ]]; then
        mapfile -t ledger_skills < <(python3 \
            "${PREFIX}/current/lib/skill_component_ledger.py" list "${ledger}" |
            jq -er '.result.skills | keys[]')
    fi
    if [[ "${NO_SYSTEMD}" -eq 0 ]]; then
        command -v systemctl >/dev/null 2>&1 || fail '缺少 systemctl'
        if [[ -d "${PREFIX}/skills" && -x "${PREFIX}/current/bin/agent" ]]; then
            mapfile -t credential_units < <(installed_credential_unit_names)
            mapfile -t credential_files < <(installed_credential_file_paths)
        fi
        stop_and_disable_unit linux-agent-web.service
        stop_and_disable_unit linux-agent-observer-helper.socket
        stop_and_disable_unit linux-agent-observer-helper.service
        stop_and_disable_unit linux-agent-runner.socket
        stop_and_disable_unit linux-agent-runner.service
        stop_and_disable_unit linux-agent-mcp-stdio.socket
        stop_and_disable_unit linux-agent-mcp-stdio.service
        stop_and_disable_unit linux-agent-host-ops.socket
        stop_and_disable_unit linux-agent-host-ops.service
        stop_and_disable_unit linux-agent-policy-writer.socket
        stop_and_disable_unit linux-agent-policy-writer.service
        for unit in "${credential_units[@]}"; do
            stop_and_disable_unit "${unit}"
        done
        rm -f -- "${SYSTEMD_UNIT_PATH}" "${SYSTEMD_HELPER_SERVICE_PATH}" "${SYSTEMD_HELPER_SOCKET_PATH}" \
            "${SYSTEMD_RUNNER_SERVICE_PATH}" "${SYSTEMD_RUNNER_SOCKET_PATH}" \
            "${SYSTEMD_MCP_STDIO_SERVICE_PATH}" "${SYSTEMD_MCP_STDIO_SOCKET_PATH}" \
            "${SYSTEMD_HOST_SERVICE_PATH}" "${SYSTEMD_HOST_SOCKET_PATH}" \
            "${SYSTEMD_POLICY_SERVICE_PATH}" "${SYSTEMD_POLICY_SOCKET_PATH}" \
            "${SYSTEMD_EGRESS_DROPIN_PATH}" "${HOST_OPS_POLICY_PATH}"
        for path in "${credential_files[@]}"; do
            rm -f -- "${path}"
            case "${path}" in
                *.service.d/*.conf) rmdir -- "$(dirname -- "${path}")" 2>/dev/null || true ;;
            esac
        done
        rmdir -- "$(dirname -- "${SYSTEMD_EGRESS_DROPIN_PATH}")" 2>/dev/null || true
        rmdir -- "$(dirname -- "${HOST_OPS_POLICY_PATH}")" 2>/dev/null || true
        systemctl daemon-reload
    fi
    for skill in "${ledger_skills[@]}"; do
        if [[ "${PURGE_DATA}" -eq 1 ]]; then
            result="$(python3 "${PREFIX}/current/lib/skill_component_ledger.py" uninstall \
                "${ledger}" "${skill}" --purge --confirm PURGE_SKILL_DATA)" ||
                fail "无法清理 Skill ${skill} 明确登记的持久数据"
        else
            result="$(python3 "${PREFIX}/current/lib/skill_component_ledger.py" uninstall \
                "${ledger}" "${skill}")" ||
                fail "无法更新 Skill ${skill} 的卸载状态"
        fi
        jq -e '.ok == true' <<<"${result}" >/dev/null ||
            fail "Skill ${skill} ownership ledger 返回无效结果"
    done
    rm -f -- "${PREFIX}/current"
    rm -rf -- "${PREFIX}/releases" "${PREFIX}/skills" "${PREFIX}/skill-releases"
    rm -f -- "${PREFIX}/release-manifest.json"
    if [[ "${PURGE_DATA}" -eq 1 ]]; then
        rm -rf -- "${PREFIX}/data"
        rm -f -- "$(install_state_path)"
        if [[ "${SERVICE_USER_CREATED}" -eq 1 && "${SERVICE_USER}" != "root" &&
            -n "${SERVICE_USER}" ]] && id "${SERVICE_USER}" >/dev/null 2>&1; then
            command -v userdel >/dev/null 2>&1 || fail '缺少 userdel，无法删除安装器创建的服务用户'
            userdel "${SERVICE_USER}" || fail "无法删除安装器创建的服务用户: ${SERVICE_USER}"
        fi
        if [[ "${RUNNER_USER_CREATED}" -eq 1 && "${RUNNER_USER}" != "root" &&
            -n "${RUNNER_USER}" ]] && id "${RUNNER_USER}" >/dev/null 2>&1; then
            command -v userdel >/dev/null 2>&1 || fail '缺少 userdel，无法删除安装器创建的 Runner 用户'
            userdel "${RUNNER_USER}" || fail "无法删除安装器创建的 Runner 用户: ${RUNNER_USER}"
        fi
        if [[ "${CREDENTIAL_USER_CREATED}" -eq 1 && "${CREDENTIAL_USER}" != "root" &&
            -n "${CREDENTIAL_USER}" ]] && id "${CREDENTIAL_USER}" >/dev/null 2>&1; then
            command -v userdel >/dev/null 2>&1 || fail '缺少 userdel，无法删除 credential helper 用户'
            userdel "${CREDENTIAL_USER}" || fail "无法删除 credential helper 用户: ${CREDENTIAL_USER}"
        fi
    else
        if [[ "${NO_SYSTEMD}" -eq 1 ]]; then
            ensure_service_identity
        fi
        write_install_state false
        finalize_no_systemd_ownership
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
    repair-observer) do_repair_observer ;;
    status) do_status ;;
    uninstall) do_uninstall ;;
esac
