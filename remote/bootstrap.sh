#!/usr/bin/env bash

set -euo pipefail

REPOSITORY="libeal/ASSIstant"
ENTRYPOINT="${LINUX_AGENT_REMOTE_ENTRYPOINT:-}"
VERSION="${LINUX_AGENT_VERSION:-latest}"
RUNTIME_ROOT=""

fail() {
    printf '[remote:error] %s\n' "$*" >&2
    exit 1
}

for command_name in bash curl python3 jq tar sha256sum stat mktemp; do
    command -v "${command_name}" >/dev/null 2>&1 || fail "缺少依赖命令: ${command_name}"
done

case "${ENTRYPOINT}" in cli | web) ;; *) fail 'remote entrypoint must be cli or web' ;; esac
if [[ "${VERSION}" != "latest" && ! "${VERSION}" =~ ^v[0-9A-Za-z][0-9A-Za-z._-]*$ ]]; then
    fail 'LINUX_AGENT_VERSION 格式非法'
fi

if [[ -n "${LINUX_AGENT_RELEASE_BASE_URL:-}" ]]; then
    [[ "${LINUX_AGENT_ALLOW_INSECURE_TEST_URL:-0}" == "1" ]] || fail '自定义 release URL 仅供测试'
    RELEASE_BASE="${LINUX_AGENT_RELEASE_BASE_URL%/}"
elif [[ "${VERSION}" == "latest" ]]; then
    RELEASE_BASE="https://github.com/${REPOSITORY}/releases/latest/download"
else
    RELEASE_BASE="https://github.com/${REPOSITORY}/releases/download/${VERSION}"
fi

cleanup() {
    local path="${RUNTIME_ROOT:-}"
    [[ -n "${path}" && -d "${path}" ]] || return 0
    case "${path}" in
        */linux-agent-remote.*) rm -rf -- "${path}" ;;
        *) printf '[remote:warn] 拒绝清理非预期目录: %s\n' "${path}" >&2 ;;
    esac
}
on_signal() {
    local exit_code="$1"
    trap - INT TERM HUP
    exit "${exit_code}"
}
trap cleanup EXIT
trap 'on_signal 130' INT
trap 'on_signal 143' TERM HUP

choose_runtime_root() {
    local candidate owner
    for candidate in "${XDG_RUNTIME_DIR:-}" /dev/shm /tmp; do
        [[ -n "${candidate}" && -d "${candidate}" && -w "${candidate}" && ! -L "${candidate}" ]] || continue
        owner="$(stat -c '%u' "${candidate}" 2>/dev/null || true)"
        if [[ "${candidate}" != "/tmp" && "${owner}" != "$(id -u)" && "${owner}" != "0" ]]; then
            continue
        fi
        RUNTIME_ROOT="$(mktemp -d "${candidate%/}/linux-agent-remote.XXXXXX")"
        chmod 0700 "${RUNTIME_ROOT}"
        [[ ! -L "${RUNTIME_ROOT}" &&
            "$(stat -c '%u' "${RUNTIME_ROOT}")" == "$(id -u)" &&
            "$(stat -c '%a' "${RUNTIME_ROOT}")" == "700" ]] || {
            rm -rf -- "${RUNTIME_ROOT}"
            RUNTIME_ROOT=""
            continue
        }
        if [[ "${candidate}" == "${XDG_RUNTIME_DIR:-__none__}" ]]; then
            STORAGE_BACKEND=xdg_runtime
        elif [[ "${candidate}" == "/dev/shm" ]]; then
            STORAGE_BACKEND=dev_shm
        else
            STORAGE_BACKEND=tmp
        fi
        return 0
    done
    return 1
}

choose_runtime_root || fail '无法创建安全的临时运行目录'
download_dir="${RUNTIME_ROOT}/downloads"
agent_root="${RUNTIME_ROOT}/agent"
mkdir -p "${download_dir}" "${agent_root}"

manifest_path="${download_dir}/release-manifest.json"
if [[ "${LINUX_AGENT_ALLOW_INSECURE_TEST_URL:-0}" == "1" ]]; then
    curl -fsSL --max-time 60 --max-filesize 1048576 "${RELEASE_BASE}/release-manifest.json" -o "${manifest_path}" || fail 'release manifest 下载失败'
else
    curl -fsSL --proto '=https' --tlsv1.2 --max-time 60 --max-filesize 1048576 "${RELEASE_BASE}/release-manifest.json" -o "${manifest_path}" || fail 'release manifest 下载失败'
fi
[[ "$(stat -c '%s' "${manifest_path}")" -le 1048576 ]] || fail 'release manifest 超过 1MiB'
jq -e --arg repository "${REPOSITORY}" '
    def valid_asset:
        type == "object"
        and (.name | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]+$"))
        and (.sha256 | type == "string" and test("^[0-9a-f]{64}$"))
        and (.size_bytes | type == "number" and floor == . and . > 0)
        and (.max_size_bytes | type == "number" and floor == . and . >= 1)
        and (.size_bytes <= .max_size_bytes);
    def valid_risk: IN("low", "medium", "high", "critical");
    def valid_ref:
        type == "object"
        and (.ref | type == "string" and test("^[a-z0-9][a-z0-9-]*/[a-z0-9][a-z0-9-]*$"))
        and (.description | type == "string" and length > 0)
        and (.risk | valid_risk);
    type == "object"
    and .schema_version == 1
    and .repository == $repository
    and (.version | type == "string" and test("^v[0-9A-Za-z][0-9A-Za-z._-]*$"))
    and (.assets.bootstrap_cli | type == "object")
    and (.assets.bootstrap_web | type == "object")
    and (.assets.core | type == "object")
    and (.assets.web | type == "object")
    and (.skills | type == "object")
    and ([.assets[] | valid_asset] | all)
    and ([.skills | to_entries[] |
        (.key | test("^[a-z0-9][a-z0-9-]*$"))
        and (.value.description | type == "string" and length > 0)
        and (.value.risk | valid_risk)
        and (.value.asset | valid_asset)
        and (.value.refs | type == "array" and length > 0 and all(valid_ref))
    ] | all)
' "${manifest_path}" >/dev/null || fail 'release manifest 校验失败'

RELEASE_VERSION="$(jq -r '.version' "${manifest_path}")"
if [[ "${VERSION}" != "latest" && "${RELEASE_VERSION}" != "${VERSION}" ]]; then
    fail '固定版本与 release manifest version 不一致'
fi

download_asset() {
    local selector="$1"
    local name sha expected_size max_size output actual_size actual_sha
    name="$(jq -r "${selector}.name // empty" "${manifest_path}")"
    sha="$(jq -r "${selector}.sha256 // empty" "${manifest_path}")"
    expected_size="$(jq -r "${selector}.size_bytes // 0" "${manifest_path}")"
    max_size="$(jq -r "${selector}.max_size_bytes // 0" "${manifest_path}")"
    [[ "${name}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]+$ ]] || fail 'release asset 文件名非法'
    [[ "${sha}" =~ ^[0-9a-f]{64}$ ]] || fail "release asset 摘要非法: ${name}"
    [[ "${expected_size}" =~ ^[0-9]+$ && "${max_size}" =~ ^[0-9]+$ && "${expected_size}" -gt 0 && "${expected_size}" -le "${max_size}" ]] || fail "release asset 大小非法: ${name}"
    output="${download_dir}/${name}"
    if [[ "${LINUX_AGENT_ALLOW_INSECURE_TEST_URL:-0}" == "1" ]]; then
        curl -fsSL --max-time 120 --max-filesize "${max_size}" "${RELEASE_BASE}/${name}" -o "${output}" || fail "asset 下载失败: ${name}"
    else
        curl -fsSL --proto '=https' --tlsv1.2 --max-time 120 --max-filesize "${max_size}" "${RELEASE_BASE}/${name}" -o "${output}" || fail "asset 下载失败: ${name}"
    fi
    actual_size="$(stat -c '%s' "${output}")"
    [[ "${actual_size}" == "${expected_size}" ]] || fail "asset 大小不匹配: ${name}"
    actual_sha="$(sha256sum "${output}" | awk '{print $1}')"
    [[ "${actual_sha}" == "${sha}" ]] || fail "asset SHA256 不匹配: ${name}"
    printf '%s\n' "${output}"
}

validate_archive() {
    python3 - "$1" <<'PY'
import pathlib
import sys
import tarfile

path = pathlib.Path(sys.argv[1])
with tarfile.open(path, "r:gz") as archive:
    members = archive.getmembers()
    if not members or len(members) > 10000:
        raise SystemExit("archive member count is invalid")
    seen = set()
    total_size = 0
    for member in members:
        member_path = pathlib.PurePosixPath(member.name)
        if member_path.is_absolute() or ".." in member_path.parts:
            raise SystemExit("archive contains an unsafe path")
        normalized = "/".join(part for part in member_path.parts if part not in ("", "."))
        if not normalized or normalized in seen:
            raise SystemExit("archive contains an empty or duplicate path")
        seen.add(normalized)
        if not (member.isfile() or member.isdir()):
            raise SystemExit("archive contains an unsafe member type")
        if member.isfile():
            total_size += member.size
            if member.size > 64 * 1024 * 1024 or total_size > 256 * 1024 * 1024:
                raise SystemExit("archive expands beyond the allowed size")
PY
}

core_archive="$(download_asset '.assets.core')"
validate_archive "${core_archive}" || fail 'core archive 安全校验失败'
tar --no-same-owner --no-same-permissions -xzf "${core_archive}" -C "${agent_root}"

if [[ "${ENTRYPOINT}" == "web" ]]; then
    web_archive="$(download_asset '.assets.web')"
    validate_archive "${web_archive}" || fail 'web archive 安全校验失败'
    tar --no-same-owner --no-same-permissions -xzf "${web_archive}" -C "${agent_root}"
fi

validated_assets="$(jq -cn --arg core "$(basename "${core_archive}")" '[$core]')"
if [[ "${ENTRYPOINT}" == "web" ]]; then
    validated_assets="$(jq -cn --argjson prior "${validated_assets}" --arg web "$(basename "${web_archive}")" '$prior + [$web]')"
fi

mkdir -p "${agent_root}/remote" "${agent_root}/config"
cp "${manifest_path}" "${agent_root}/remote/release-manifest.json"
cp "${agent_root}/config/config.example.json" "${agent_root}/config/config.json"
config_tmp="${agent_root}/config/config.json.tmp"
jq --arg version "${RELEASE_VERSION}" --arg storage "${STORAGE_BACKEND}" --arg allow "${LINUX_AGENT_REMOTE_ALLOW_API_KEY_TRANSMISSION:-false}" '
    .remote = ((.remote // {}) + {
        enabled:true,
        release_version:$version,
        storage_backend:$storage,
        allow_api_key_transmission:($allow | ascii_downcase | IN("true", "1", "yes", "on"))
    })
    | .providers_security = ((.providers_security // {}) + {require_https:true})
' "${agent_root}/config/config.json" >"${config_tmp}"
mv "${config_tmp}" "${agent_root}/config/config.json"

export LINUX_AGENT_REMOTE_MODE=1
export LINUX_AGENT_REMOTE_RELEASE_BASE="${RELEASE_BASE}"
export LINUX_AGENT_REMOTE_MANIFEST="${agent_root}/remote/release-manifest.json"
export LINUX_AGENT_REMOTE_RELEASE_VERSION="${RELEASE_VERSION}"
export LINUX_AGENT_REMOTE_STORAGE_BACKEND="${STORAGE_BACKEND}"
LINUX_AGENT_REMOTE_PREFLIGHT="$(jq -cn \
    --arg release_version "${RELEASE_VERSION}" \
    --arg entrypoint "${ENTRYPOINT}" \
    --arg storage_backend "${STORAGE_BACKEND}" \
    --argjson assets "${validated_assets}" \
    '{status:"verified", release_version:$release_version, entrypoint:$entrypoint, storage_backend:$storage_backend, assets:$assets}')"
export LINUX_AGENT_REMOTE_PREFLIGHT

if [[ "${ENTRYPOINT}" == "cli" ]]; then
    HAS_TTY=0
    if [[ -e /dev/tty ]] && (: </dev/tty) 2>/dev/null; then
        HAS_TTY=1
    fi
    if [[ $# -eq 0 && "${HAS_TTY}" == "1" ]]; then
        printf '[remote] 版本 %s，运行目录将在退出时清理。\n' "${RELEASE_VERSION}" >&2
        exec_args=()
    elif [[ $# -eq 0 ]]; then
        exec_args=(doctor)
    else
        exec_args=("$@")
    fi
    NEEDS_AI=0
    if [[ ${#exec_args[@]} -eq 0 || "${exec_args[0]:-}" == "work" || "${exec_args[0]:-}" == "edit" ]]; then
        NEEDS_AI=1
    fi
    if [[ "${HAS_TTY}" == "1" && "${NEEDS_AI}" == "1" && "$(jq -r '.remote.allow_api_key_transmission // false' "${agent_root}/config/config.json")" != "true" ]]; then
        printf '是否允许当前 remote runtime 向已配置的 AI Provider 传输 API Key？[y/N] ' >/dev/tty
        IFS= read -r allow_answer </dev/tty || allow_answer=""
        if [[ "${allow_answer,,}" == "y" || "${allow_answer,,}" == "yes" ]]; then
            allow_tmp="${agent_root}/config/config.json.allow.tmp"
            jq '.remote.allow_api_key_transmission = true' "${agent_root}/config/config.json" >"${allow_tmp}"
            mv "${allow_tmp}" "${agent_root}/config/config.json"
            if [[ -z "${LINUX_AGENT_API_KEY:-}" ]]; then
                printf 'API Key（仅保存在当前进程内存）: ' >/dev/tty
                IFS= read -r -s LINUX_AGENT_API_KEY </dev/tty || LINUX_AGENT_API_KEY=""
                printf '\n' >/dev/tty
                export LINUX_AGENT_API_KEY
            fi
        fi
    fi
    if [[ "${HAS_TTY}" == "1" ]]; then
        bash "${agent_root}/bin/agent" "${exec_args[@]}" </dev/tty
    else
        bash "${agent_root}/bin/agent" "${exec_args[@]}"
    fi
else
    export LINUX_AGENT_WEB_HOST=127.0.0.1
    printf '[remote] Web 仅监听 127.0.0.1；远程访问请使用 SSH 端口转发。\n' >&2
    WEB_PID=""
    stop_web() {
        local exit_code="${1:-143}"
        if [[ -n "${WEB_PID}" ]] && kill -0 "${WEB_PID}" >/dev/null 2>&1; then
            kill -TERM "${WEB_PID}" >/dev/null 2>&1 || true
            wait "${WEB_PID}" 2>/dev/null || true
        fi
        exit "${exit_code}"
    }
    trap 'stop_web 130' INT
    trap 'stop_web 143' TERM HUP
    bash "${agent_root}/bin/agent-web" &
    WEB_PID="$!"
    wait "${WEB_PID}"
fi
