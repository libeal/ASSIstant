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
REQUIRE_SIGNATURE=0
NO_SYSTEMD=0
KEEP=2
PURGE_DATA=0
WORK_DIR=""
PREPARED_RELEASE_DIR=""
SYSTEMD_UNIT_PATH="${LINUX_AGENT_SYSTEMD_UNIT_PATH:-/etc/systemd/system/linux-agent-web.service}"
TRANSACTION_MODE=""
TRANSACTION_OLD_VERSION=""
TRANSACTION_TARGET_VERSION=""
TRANSACTION_BACKUP_DIR=""
TRANSACTION_COMMITTED=0
CONFIG_STATE_CAPTURED=0
SYSTEMD_STATE_CAPTURED=0
SYSTEMD_UNIT_EXISTED=0
SYSTEMD_WAS_ENABLED=0
SYSTEMD_WAS_ACTIVE=0

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

ensure_prefix() {
    if [[ -L "${PREFIX}" || (-e "${PREFIX}" && ! -d "${PREFIX}") ]]; then
        fail "安装前缀必须是普通目录且不能是符号链接: ${PREFIX}"
    fi
    mkdir -p -- "${PREFIX}"
    PREFIX="$(readlink -f -- "${PREFIX}")"
    [[ "${PREFIX}" != "/" ]] || fail '拒绝使用根目录作为安装前缀'
    if [[ "${NO_SYSTEMD}" -eq 0 ]]; then
        case "${PREFIX}/" in
            /home/* | /root/* | /run/user/* | /tmp/* | /var/tmp/*)
                if [[ "${LINUX_AGENT_ALLOW_UNSAFE_SYSTEMD_TEST_PREFIX:-0}" == "1" &&
                    "${SYSTEMD_UNIT_PATH}" == "${PREFIX}/"* ]]; then
                    warn "仅测试：允许 systemd 沙箱不可见的安装前缀 ${PREFIX}"
                else
                    fail 'systemd 模式的 --prefix 不能位于 /home、/root、/run/user、/tmp 或 /var/tmp；请使用 /opt、/srv 等系统服务目录，或显式使用 --no-systemd'
                fi
                ;;
        esac
    fi
}

begin_transaction() {
    local mode="$1"
    local old_version="$2"
    local target_version="$3"
    local name source backup

    TRANSACTION_MODE="${mode}"
    TRANSACTION_OLD_VERSION="${old_version}"
    TRANSACTION_TARGET_VERSION="${target_version}"
    TRANSACTION_COMMITTED=0
    CONFIG_STATE_CAPTURED=0
    SYSTEMD_STATE_CAPTURED=0
    SYSTEMD_UNIT_EXISTED=0
    SYSTEMD_WAS_ENABLED=0
    SYSTEMD_WAS_ACTIVE=0
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
}

capture_systemd_state() {
    [[ "${NO_SYSTEMD}" -eq 0 ]] || return 0
    command -v systemctl >/dev/null 2>&1 || fail '缺少 systemctl'

    if [[ -L "${SYSTEMD_UNIT_PATH}" || (-e "${SYSTEMD_UNIT_PATH}" && ! -f "${SYSTEMD_UNIT_PATH}") ]]; then
        fail "现有 systemd unit 类型非法: ${SYSTEMD_UNIT_PATH}"
    fi
    if [[ -f "${SYSTEMD_UNIT_PATH}" ]]; then
        cp -p -- "${SYSTEMD_UNIT_PATH}" "${TRANSACTION_BACKUP_DIR}/linux-agent-web.service"
        SYSTEMD_UNIT_EXISTED=1
    fi
    if systemctl is-enabled --quiet linux-agent-web.service >/dev/null 2>&1; then
        SYSTEMD_WAS_ENABLED=1
    fi
    if systemctl is-active --quiet linux-agent-web.service >/dev/null 2>&1; then
        SYSTEMD_WAS_ACTIVE=1
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

restore_systemd_state() {
    [[ "${NO_SYSTEMD}" -eq 0 && "${SYSTEMD_STATE_CAPTURED}" -eq 1 ]] || return 0
    if [[ "${SYSTEMD_UNIT_EXISTED}" -eq 1 ]]; then
        cp -p -- "${TRANSACTION_BACKUP_DIR}/linux-agent-web.service" "${SYSTEMD_UNIT_PATH}"
    else
        rm -f -- "${SYSTEMD_UNIT_PATH}"
    fi
    systemctl daemon-reload >/dev/null 2>&1 || warn '回滚后 systemd daemon-reload 失败'
    if [[ "${SYSTEMD_WAS_ENABLED}" -eq 1 ]]; then
        systemctl enable linux-agent-web.service >/dev/null 2>&1 || warn '无法恢复 systemd enabled 状态'
    else
        systemctl disable linux-agent-web.service >/dev/null 2>&1 || true
    fi
    if [[ "${SYSTEMD_WAS_ACTIVE}" -eq 1 ]]; then
        systemctl restart linux-agent-web.service >/dev/null 2>&1 || warn '无法恢复升级前的服务进程'
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
    restore_systemd_state || warn '无法完整恢复 systemd unit 状态'

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

archive_path = Path(sys.argv[1])
root = Path(sys.argv[2]).resolve()
root.mkdir(parents=True, exist_ok=True)

with tarfile.open(archive_path, "r:gz") as archive:
    members = archive.getmembers()
    if not members:
        raise SystemExit("archive is empty")
    seen = set()
    for member in members:
        path = PurePosixPath(member.name)
        if path.is_absolute() or not path.parts or any(part in ("", ".", "..") for part in path.parts):
            raise SystemExit(f"unsafe archive path: {member.name}")
        if not (member.isdir() or member.isfile()):
            raise SystemExit(f"unsupported archive member: {member.name}")
        normalized = path.as_posix().rstrip("/")
        if normalized in seen and member.isfile():
            raise SystemExit(f"duplicate archive file: {member.name}")
        seen.add(normalized)
        target = root.joinpath(*path.parts)
        if os.path.commonpath((root, target.resolve(strict=False))) != str(root):
            raise SystemExit(f"archive path escapes destination: {member.name}")
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
            shutil.copyfileobj(source, output)
        os.chmod(target, member.mode & 0o755)
PY
}

prepare_release() {
    local release_dir="${PREFIX}/releases/${VERSION}"
    local manifest base_url core_archive web_archive
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

    core_archive="$(obtain_asset "${manifest}" '.assets.core' "${base_url}")"
    web_archive="$(obtain_asset "${manifest}" '.assets.web' "${base_url}")"
    mkdir -p "${WORK_DIR}/release"
    extract_archive_safely "${core_archive}" "${WORK_DIR}/release" || fail 'core archive 安全解包失败'
    extract_archive_safely "${web_archive}" "${WORK_DIR}/release" || fail 'web archive 安全解包失败'
    [[ -x "${WORK_DIR}/release/bin/agent" && -x "${WORK_DIR}/release/bin/agent-web" ]] ||
        fail '发布物缺少可执行入口'
    [[ -f "${WORK_DIR}/release/config/config.example.json" &&
        -f "${WORK_DIR}/release/packaging/linux-agent-web.service" ]] ||
        fail '发布物缺少配置或 systemd unit'

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
    [[ "${NO_SYSTEMD}" -eq 0 ]] || return 0
    command -v chown >/dev/null 2>&1 || fail '缺少 chown，无法设置服务数据所有权'
    if ! id "${SERVICE_USER}" >/dev/null 2>&1; then
        command -v useradd >/dev/null 2>&1 || fail '缺少 useradd，无法创建 systemd 服务用户'
        useradd --system --home-dir "${PREFIX}" --shell /usr/sbin/nologin "${SERVICE_USER}"
    fi
    SERVICE_GROUP="$(id -gn "${SERVICE_USER}")"
    [[ -n "${SERVICE_GROUP}" ]] || fail "无法确定服务用户主组: ${SERVICE_USER}"
    chown -R "${SERVICE_USER}:${SERVICE_GROUP}" "${PREFIX}/data"
    chown -R root:root "${PREFIX}/releases"
}

install_systemd_unit() {
    local source="${PREFIX}/current/packaging/linux-agent-web.service"
    local render_root="${WORK_DIR:-${TRANSACTION_BACKUP_DIR:-${PREFIX}}}"
    local rendered="${render_root}/.linux-agent-web.service.$$"
    [[ "${NO_SYSTEMD}" -eq 0 ]] || return 0
    command -v systemctl >/dev/null 2>&1 || fail '缺少 systemctl'
    [[ -f "${source}" ]] || fail '当前版本缺少 systemd unit'
    python3 - "${source}" "${rendered}" "/opt/linux-agent" "${PREFIX}" \
        "linux-agent" "${SERVICE_USER}" "${SERVICE_GROUP}" <<'PY'
import sys
from pathlib import Path

source, output, old_prefix, prefix, old_user, user, group = sys.argv[1:]
text = Path(source).read_text(encoding="utf-8")
text = text.replace(old_prefix, prefix)
text = text.replace(f"User={old_user}", f"User={user}")
text = text.replace(f"Group={old_user}", f"Group={group}")
Path(output).write_text(text, encoding="utf-8")
PY
    cp -- "${rendered}" "${SYSTEMD_UNIT_PATH}"
    chmod 0644 "${SYSTEMD_UNIT_PATH}"
    systemctl daemon-reload
}

health_request() {
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

wait_for_health() {
    local output
    for _ in $(seq 1 60); do
        if output="$(health_request 2>/dev/null)" && jq -e '.ok == true and .status == "ok"' >/dev/null <<<"${output}"; then
            printf '%s\n' "${output}"
            return 0
        fi
        sleep 0.5
    done
    return 1
}

restart_and_check() {
    [[ "${NO_SYSTEMD}" -eq 0 ]] || return 0
    systemctl restart linux-agent-web.service || return 1
    wait_for_health >/dev/null || return 1
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
    local release_dir
    ensure_prefix
    if [[ -e "${PREFIX}/current" || -L "${PREFIX}/current" ]]; then
        fail '检测到已有安装，请使用 upgrade'
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
        systemctl enable --now linux-agent-web.service
        if ! wait_for_health >/dev/null; then
            fail '安装后健康检查失败'
        fi
    fi
    commit_transaction
    info "已安装 ${VERSION}: ${release_dir}"
}

do_upgrade() {
    local old_version release_dir
    ensure_prefix
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
    commit_transaction
    prune_releases
    info "已从 ${old_version} 升级到 ${VERSION}: ${release_dir}"
}

do_rollback() {
    local old_version target
    ensure_prefix
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
    commit_transaction
    info "已从 ${old_version} 回滚到 ${target}"
}

do_health() {
    ensure_prefix
    health_request || fail '健康检查失败'
}

do_status() {
    local current="" service_status="not-managed" releases='[]'
    ensure_prefix
    current="$(current_version 2>/dev/null || true)"
    if [[ -d "${PREFIX}/releases" ]]; then
        releases="$(find "${PREFIX}/releases" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' |
            sort | jq -Rsc 'split("\n") | map(select(length > 0))')"
    fi
    if [[ "${NO_SYSTEMD}" -eq 0 ]] && command -v systemctl >/dev/null 2>&1; then
        service_status="$(systemctl is-active linux-agent-web.service 2>/dev/null || true)"
        [[ -n "${service_status}" ]] || service_status="inactive"
    fi
    jq -n --arg prefix "${PREFIX}" --arg current "${current}" \
        --arg service_status "${service_status}" --argjson releases "${releases}" \
        '{ok:true,status:"installed_status",prefix:$prefix,current_version:$current,releases:$releases,service_status:$service_status}'
}

do_uninstall() {
    ensure_prefix
    if [[ "${NO_SYSTEMD}" -eq 0 ]]; then
        command -v systemctl >/dev/null 2>&1 || fail '缺少 systemctl'
        systemctl disable --now linux-agent-web.service >/dev/null 2>&1 || true
        rm -f -- "${SYSTEMD_UNIT_PATH}"
        systemctl daemon-reload
    fi
    rm -f -- "${PREFIX}/current"
    rm -rf -- "${PREFIX}/releases"
    if [[ "${PURGE_DATA}" -eq 1 ]]; then
        rm -rf -- "${PREFIX}/data"
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
