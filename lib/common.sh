#!/usr/bin/env bash

set -euo pipefail

LINUX_AGENT_ROOT=""
LINUX_AGENT_LOG_DIR=""
LINUX_AGENT_CONFIG_FILE=""
LINUX_AGENT_SKILLS_DIR=""
LINUX_AGENT_BUILTIN_SKILLS_DIR=""
LINUX_AGENT_USER_SKILLS_DIR=""
LINUX_AGENT_MCP_DIR=""
LINUX_AGENT_BUILTIN_POLICIES_DIR=""
LINUX_AGENT_USER_POLICIES_DIR=""
LINUX_AGENT_DATA_DIR=""
LINUX_AGENT_INSTALL_PREFIX=""
LINUX_AGENT_MANAGED_MODE=0
LINUX_AGENT_TMP_ROOT=""
LINUX_AGENT_TMP_DIR=""
LINUX_AGENT_RUNNER_TMP_ROOT=""
LINUX_AGENT_RUNNER_TMP_DIR=""
LINUX_AGENT_RUNTIME_LOCK_FD=""
LINUX_AGENT_RUNTIME_LOCK_DEPTH=0
LINUX_AGENT_RUNTIME_LOCK_INHERITED=0

# These globals are consumed by modules sourced after common.sh.
# shellcheck disable=SC2034
linux_agent_detect_runtime_layout() {
    local root_dir="$1"
    local resolved_root releases_dir prefix

    resolved_root="$(readlink -f -- "${root_dir}" 2>/dev/null || true)"
    releases_dir="$(dirname -- "${resolved_root:-${root_dir}}")"
    prefix="$(dirname -- "${releases_dir}")"
    if [[ -n "${resolved_root}" && "$(basename -- "${releases_dir}")" == "releases" &&
    -d "${prefix}/data" && ! -L "${prefix}/data" ]]; then
        LINUX_AGENT_MANAGED_MODE=1
        LINUX_AGENT_INSTALL_PREFIX="${prefix}"
        LINUX_AGENT_DATA_DIR="${prefix}/data"
    else
        LINUX_AGENT_MANAGED_MODE=0
        LINUX_AGENT_INSTALL_PREFIX=""
        LINUX_AGENT_DATA_DIR="${root_dir}/data"
    fi

    if [[ "${LINUX_AGENT_MANAGED_MODE}" == "1" ]]; then
        LINUX_AGENT_BUILTIN_SKILLS_DIR="${prefix}/skills"
    else
        LINUX_AGENT_BUILTIN_SKILLS_DIR="${root_dir}/skills"
    fi
    LINUX_AGENT_USER_SKILLS_DIR="${LINUX_AGENT_DATA_DIR}/skills"
    LINUX_AGENT_BUILTIN_POLICIES_DIR="${root_dir}/policies"
    LINUX_AGENT_USER_POLICIES_DIR="${LINUX_AGENT_DATA_DIR}/policies"
}

linux_agent_managed_mode_enabled() {
    [[ "${LINUX_AGENT_MANAGED_MODE:-0}" == "1" ]]
}

# A release layout is also used by ``install --no-systemd`` so persistent
# data and upgrades keep working without a service manager.  That layout must
# not by itself force the Runner/host helper protocol: no-systemd installs do
# not install those sockets and intentionally execute as their current user.
# Missing or invalid install state remains fail-closed as managed execution.
linux_agent_managed_execution_enabled() {
    local state_path

    linux_agent_managed_mode_enabled || return 1
    [[ -n "${LINUX_AGENT_INSTALL_PREFIX:-}" ]] || return 0
    state_path="${LINUX_AGENT_INSTALL_PREFIX}/.install-state.json"
    [[ -f "${state_path}" && ! -L "${state_path}" ]] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    if jq -e --arg prefix "${LINUX_AGENT_INSTALL_PREFIX}" '
        type == "object"
        and .schema_version == 1
        and .prefix == $prefix
        and .installed == true
        and .no_systemd == true
    ' "${state_path}" >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

linux_agent_runtime_lock_path() {
    printf '%s\n' "${LINUX_AGENT_DATA_DIR}/.runtime.lock"
}

linux_agent_runtime_lock_shared() {
    local lock_path
    if [[ "${LINUX_AGENT_RUNTIME_LOCK_DEPTH:-0}" -gt 0 ]]; then
        LINUX_AGENT_RUNTIME_LOCK_DEPTH=$((LINUX_AGENT_RUNTIME_LOCK_DEPTH + 1))
        return 0
    fi
    command -v flock >/dev/null 2>&1 || return 1
    lock_path="$(linux_agent_runtime_lock_path)"
    [[ -f "${lock_path}" && ! -L "${lock_path}" ]] || return 1
    if [[ "${LINUX_AGENT_RUNTIME_PARENT_LOCK_FD:-}" =~ ^[0-9]+$ ]] &&
        [[ -e "/proc/$$/fd/${LINUX_AGENT_RUNTIME_PARENT_LOCK_FD}" ]] &&
        [[ "/proc/$$/fd/${LINUX_AGENT_RUNTIME_PARENT_LOCK_FD}" -ef "${lock_path}" ]]; then
        LINUX_AGENT_RUNTIME_LOCK_FD="${LINUX_AGENT_RUNTIME_PARENT_LOCK_FD}"
        LINUX_AGENT_RUNTIME_LOCK_DEPTH=1
        LINUX_AGENT_RUNTIME_LOCK_INHERITED=1
        return 0
    fi
    exec {LINUX_AGENT_RUNTIME_LOCK_FD}<>"${lock_path}" || return 1
    if ! flock -s "${LINUX_AGENT_RUNTIME_LOCK_FD}"; then
        exec {LINUX_AGENT_RUNTIME_LOCK_FD}>&-
        LINUX_AGENT_RUNTIME_LOCK_FD=""
        return 1
    fi
    LINUX_AGENT_RUNTIME_LOCK_DEPTH=1
}

linux_agent_runtime_lock_exclusive_nonblocking() {
    local lock_path
    [[ "${LINUX_AGENT_RUNTIME_LOCK_DEPTH:-0}" -eq 0 ]] || return 1
    command -v flock >/dev/null 2>&1 || return 1
    lock_path="$(linux_agent_runtime_lock_path)"
    [[ -f "${lock_path}" && ! -L "${lock_path}" ]] || return 1
    exec {LINUX_AGENT_RUNTIME_LOCK_FD}<>"${lock_path}" || return 1
    if ! flock -xn "${LINUX_AGENT_RUNTIME_LOCK_FD}"; then
        exec {LINUX_AGENT_RUNTIME_LOCK_FD}>&-
        LINUX_AGENT_RUNTIME_LOCK_FD=""
        return 1
    fi
    LINUX_AGENT_RUNTIME_LOCK_DEPTH=1
}

linux_agent_runtime_lock_upgrade_exclusive_nonblocking() {
    [[ "${LINUX_AGENT_RUNTIME_LOCK_DEPTH:-0}" -eq 1 ]] || return 1
    [[ "${LINUX_AGENT_RUNTIME_LOCK_INHERITED:-0}" != "1" ]] || return 1
    [[ -n "${LINUX_AGENT_RUNTIME_LOCK_FD:-}" ]] || return 1
    flock -xn "${LINUX_AGENT_RUNTIME_LOCK_FD}"
}

linux_agent_runtime_lock_downgrade_shared() {
    [[ "${LINUX_AGENT_RUNTIME_LOCK_DEPTH:-0}" -eq 1 ]] || return 1
    [[ "${LINUX_AGENT_RUNTIME_LOCK_INHERITED:-0}" != "1" ]] || return 1
    [[ -n "${LINUX_AGENT_RUNTIME_LOCK_FD:-}" ]] || return 1
    flock -s "${LINUX_AGENT_RUNTIME_LOCK_FD}"
}

linux_agent_runtime_lock_release() {
    local depth="${LINUX_AGENT_RUNTIME_LOCK_DEPTH:-0}"
    ((depth > 0)) || return 0
    depth=$((depth - 1))
    LINUX_AGENT_RUNTIME_LOCK_DEPTH="${depth}"
    ((depth == 0)) || return 0
    if [[ "${LINUX_AGENT_RUNTIME_LOCK_INHERITED:-0}" == "1" ]]; then
        LINUX_AGENT_RUNTIME_LOCK_FD=""
        LINUX_AGENT_RUNTIME_LOCK_INHERITED=0
        return 0
    fi
    if [[ -n "${LINUX_AGENT_RUNTIME_LOCK_FD:-}" ]]; then
        flock -u "${LINUX_AGENT_RUNTIME_LOCK_FD}" 2>/dev/null || true
        exec {LINUX_AGENT_RUNTIME_LOCK_FD}>&-
    fi
    LINUX_AGENT_RUNTIME_LOCK_FD=""
}

linux_agent_policy_path() {
    local name="$1"
    local default_path overlay_path

    [[ "${name}" =~ ^[a-z0-9][a-z0-9-]*\.json$ ]] || return 1
    default_path="${LINUX_AGENT_BUILTIN_POLICIES_DIR:-${LINUX_AGENT_ROOT}/policies}/${name}"
    overlay_path="${LINUX_AGENT_USER_POLICIES_DIR:-${LINUX_AGENT_ROOT}/data/policies}/${name}"
    [[ -f "${default_path}" && ! -L "${default_path}" ]] || return 1
    if [[ -e "${overlay_path}" || -L "${overlay_path}" ]]; then
        [[ -f "${overlay_path}" && ! -L "${overlay_path}" ]] || return 1
        printf '%s\n' "${overlay_path}"
    else
        printf '%s\n' "${default_path}"
    fi
}

# Other sourced modules consume the initialized path globals.
# shellcheck disable=SC2034
linux_agent_init_env() {
    local root_dir="$1" runtime_dir runtime_meta runtime_label current_user selinux_status
    local resolved_log_dir resolved_root releases_dir install_prefix expected_log_dir
    LINUX_AGENT_ROOT="${root_dir}"
    linux_agent_detect_runtime_layout "${root_dir}"
    LINUX_AGENT_LOG_DIR="${root_dir}/logs"
    LINUX_AGENT_CONFIG_FILE="${root_dir}/config/config.json"
    LINUX_AGENT_SKILLS_DIR="${LINUX_AGENT_BUILTIN_SKILLS_DIR}"
    LINUX_AGENT_MCP_DIR="${root_dir}/mcp"
    LINUX_AGENT_TMP_ROOT="${root_dir}/tmp"
    LINUX_AGENT_TMP_DIR="${LINUX_AGENT_TMP_ROOT}"
    if linux_agent_managed_mode_enabled; then
        LINUX_AGENT_RUNNER_TMP_ROOT="${LINUX_AGENT_DATA_DIR}/runner-tmp"
    else
        LINUX_AGENT_RUNNER_TMP_ROOT="${LINUX_AGENT_TMP_ROOT}"
    fi
    LINUX_AGENT_RUNNER_TMP_DIR="${LINUX_AGENT_RUNNER_TMP_ROOT}"

    if ! mkdir -p \
        "${LINUX_AGENT_DATA_DIR}" \
        "${LINUX_AGENT_LOG_DIR}" \
        "${LINUX_AGENT_SKILLS_DIR}" \
        "${LINUX_AGENT_MCP_DIR}" \
        "${LINUX_AGENT_TMP_ROOT}" \
        "${root_dir}/config"; then
        linux_agent_print_error "无法创建运行目录；检查 ${root_dir} 及 config/logs/tmp 的所有权和权限。"
        return 1
    fi
    local runtime_lock
    runtime_lock="$(linux_agent_runtime_lock_path)"
    if [[ ! -e "${runtime_lock}" && ! -L "${runtime_lock}" ]]; then
        (umask 077 && set -C && : >"${runtime_lock}") 2>/dev/null || true
    fi
    if [[ ! -f "${runtime_lock}" || -L "${runtime_lock}" ]]; then
        linux_agent_print_error "runtime 事务锁不是普通文件: ${runtime_lock}"
        return 1
    fi
    current_user="$(id -un 2>/dev/null || printf unknown)"
    for runtime_dir in "${root_dir}/config" "${LINUX_AGENT_LOG_DIR}" "${LINUX_AGENT_TMP_ROOT}"; do
        if [[ ! -d "${runtime_dir}" || ! -w "${runtime_dir}" || ! -x "${runtime_dir}" ]]; then
            runtime_meta="$(stat -c '%U:%G %a' "${runtime_dir}" 2>/dev/null || printf unknown)"
            selinux_status="$(getenforce 2>/dev/null || true)"
            if [[ -n "${selinux_status}" && "${selinux_status}" != "Disabled" ]]; then
                runtime_label="$(ls -Zd "${runtime_dir}" 2>/dev/null | awk '{print $1}' || true)"
                [[ -n "${runtime_label}" ]] && runtime_meta+=" SELinux=${runtime_label}(${selinux_status})"
            fi
            linux_agent_print_error \
                "运行目录不可写: ${runtime_dir}（当前用户 ${current_user}，目录 ${runtime_meta}）。源码/无 systemd 运行应归属当前用户；受管安装应归属 Web 服务用户。"
            return 1
        fi
    done
    # Production installs intentionally expose releases/<version>/logs as a
    # root-owned symlink to the persistent data directory. Resolve that trusted
    # directory once so audit_chain.py can retain O_NOFOLLOW on log/lock files.
    resolved_log_dir="$(readlink -f -- "${root_dir}/logs" 2>/dev/null || true)"
    if [[ -z "${resolved_log_dir}" || ! -d "${resolved_log_dir}" ]]; then
        linux_agent_print_error "无法解析审计日志目录: ${root_dir}/logs"
        return 1
    fi
    if [[ -L "${root_dir}/logs" ]]; then
        resolved_root="$(readlink -f -- "${root_dir}" 2>/dev/null || true)"
        releases_dir="$(dirname -- "${resolved_root}")"
        install_prefix="$(dirname -- "${releases_dir}")"
        expected_log_dir="$(readlink -f -- "${install_prefix}/data/logs" 2>/dev/null || true)"
        if [[ "$(basename -- "${releases_dir}")" != "releases" ||
        -z "${expected_log_dir}" || "${resolved_log_dir}" != "${expected_log_dir}" ]]; then
            linux_agent_print_error "审计日志符号链接不符合受管安装布局: ${root_dir}/logs"
            return 1
        fi
    fi
    LINUX_AGENT_LOG_DIR="${resolved_log_dir}"
}

linux_agent_use_session_tmp_dir() {
    local scope="$1"
    local safe_scope

    [[ -n "${LINUX_AGENT_TMP_ROOT:-}" ]] || return 0
    safe_scope="$(printf '%s' "${scope}" | tr -c 'A-Za-z0-9_.-' '_' | cut -c 1-80)"
    [[ -n "${safe_scope}" ]] || safe_scope="process_$$"
    LINUX_AGENT_TMP_DIR="${LINUX_AGENT_TMP_ROOT}/${safe_scope}"
    mkdir -p "${LINUX_AGENT_TMP_DIR}"
    if linux_agent_managed_mode_enabled; then
        LINUX_AGENT_RUNNER_TMP_DIR="${LINUX_AGENT_RUNNER_TMP_ROOT}/${safe_scope}"
        mkdir -p "${LINUX_AGENT_RUNNER_TMP_DIR}"
        # Keep the installer's Runner group on files staged by the Web user.
        chmod 2750 "${LINUX_AGENT_RUNNER_TMP_DIR}" 2>/dev/null || true
    else
        LINUX_AGENT_RUNNER_TMP_DIR="${LINUX_AGENT_TMP_DIR}"
    fi
}

linux_agent_cleanup_tmp_dir() {
    local tmp_dir="${LINUX_AGENT_TMP_DIR:-}"
    local tmp_root="${LINUX_AGENT_TMP_ROOT:-${LINUX_AGENT_ROOT:-}/tmp}"
    local resolved_tmp resolved_root

    [[ -n "${tmp_dir}" && -n "${tmp_root}" ]] || return 0

    resolved_tmp="$(readlink -f "${tmp_dir}" 2>/dev/null || true)"
    resolved_root="$(readlink -f "${tmp_root}" 2>/dev/null || true)"
    [[ -n "${resolved_tmp}" && -n "${resolved_root}" ]] || return 0

    if [[ "${resolved_tmp}" == "/" || ("${resolved_tmp}" != "${resolved_root}" && "${resolved_tmp}" != "${resolved_root}/"*) ]]; then
        linux_agent_print_warn "跳过临时目录清理，路径不在项目 tmp 内: ${tmp_dir}"
        return 0
    fi

    if [[ "${resolved_tmp}" == "${resolved_root}" ]]; then
        mkdir -p "${resolved_tmp}"
        find "${resolved_tmp}" -mindepth 1 -maxdepth 1 ! -name '.shared' -exec rm -rf -- {} + 2>/dev/null || true
    else
        rm -rf -- "${resolved_tmp}" 2>/dev/null || true
    fi

    local runner_tmp_dir="${LINUX_AGENT_RUNNER_TMP_DIR:-}"
    local runner_tmp_root="${LINUX_AGENT_RUNNER_TMP_ROOT:-}"
    local resolved_runner_tmp resolved_runner_root
    if [[ -n "${runner_tmp_dir}" && -n "${runner_tmp_root}" &&
        "${runner_tmp_dir}" != "${tmp_dir}" ]]; then
        resolved_runner_tmp="$(readlink -f "${runner_tmp_dir}" 2>/dev/null || true)"
        resolved_runner_root="$(readlink -f "${runner_tmp_root}" 2>/dev/null || true)"
        if [[ -n "${resolved_runner_tmp}" && -n "${resolved_runner_root}" &&
            "${resolved_runner_tmp}" != "${resolved_runner_root}" &&
            "${resolved_runner_tmp}" == "${resolved_runner_root}/"* ]]; then
            rm -rf -- "${resolved_runner_tmp}" 2>/dev/null || true
        fi
    fi
}

linux_agent_print_info() {
    printf '[信息] %s\n' "$*"
}

linux_agent_print_warn() {
    printf '[警告] %s\n' "$*" >&2
}

linux_agent_print_error() {
    printf '[错误] %s\n' "$*" >&2
}

linux_agent_require_command() {
    local name="$1"
    if ! command -v "${name}" >/dev/null 2>&1; then
        linux_agent_print_error "缺少依赖命令: ${name}"
        return 1
    fi
}

linux_agent_require_python_runtime() {
    local current_version

    linux_agent_require_command python3 || return 1
    if ! python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)'; then
        current_version="$(python3 -V 2>&1 || printf unknown)"
        linux_agent_print_error "Python 版本过低: ${current_version}；需要 Python 3.10+"
        return 1
    fi
}

linux_agent_now_iso() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

linux_agent_new_session_id() {
    printf 'session_%s_%s\n' "$(date +"%Y%m%d_%H%M%S")" "$RANDOM"
}

linux_agent_audit_mode() {
    local mode="safe_summary"
    if declare -F linux_agent_config_get_default >/dev/null 2>&1 && [[ -n "${LINUX_AGENT_CONFIG_JSON:-}" ]]; then
        mode="$(linux_agent_config_get_default '.audit_mode' 'safe_summary')"
    fi

    case "${mode}" in
        safe_summary | redacted_verbose)
            if declare -F linux_agent_audit_boundary_entry_allowed >/dev/null 2>&1; then
                if linux_agent_audit_boundary_entry_allowed \
                    "${mode}" '.allowed_to_observe.audit_payload_modes'; then
                    printf '%s\n' "${mode}"
                    return 0
                fi
                if declare -F linux_agent_audit_boundary_payload_mode >/dev/null 2>&1; then
                    mode="$(linux_agent_audit_boundary_payload_mode "${mode}")"
                else
                    mode="safe_summary"
                fi
            elif declare -F linux_agent_audit_boundary_payload_mode >/dev/null 2>&1; then
                mode="$(linux_agent_audit_boundary_payload_mode "${mode}")"
            fi
            printf '%s\n' "${mode}"
            ;;
        *)
            printf 'safe_summary\n'
            ;;
    esac
}

linux_agent_audit_text_limit() {
    local limit="1000"
    if declare -F linux_agent_config_get_default >/dev/null 2>&1 && [[ -n "${LINUX_AGENT_CONFIG_JSON:-}" ]]; then
        limit="$(linux_agent_config_get_default '.audit_text_limit' '1000')"
    fi
    if [[ ! "${limit}" =~ ^[0-9]+$ || "${limit}" -le 0 ]]; then
        limit=1000
    fi
    if declare -F linux_agent_audit_boundary_text_limit >/dev/null 2>&1; then
        limit="$(linux_agent_audit_boundary_text_limit "${limit}")"
    fi
    printf '%s\n' "${limit}"
}

linux_agent_redaction_rules_path() {
    linux_agent_policy_path redaction-rules.json
}

linux_agent_redaction_rules_default_config() {
    cat <<'JSON'
{
  "rules": [
    {"id":"private_key","pattern":"-----BEGIN [^-]+ PRIVATE KEY-----[\\s\\S]*?-----END [^-]+ PRIVATE KEY-----","replacement":"[REDACTED_PRIVATE_KEY]"},
    {"id":"bearer_token","pattern":"(?i)Bearer[[:space:]]+[A-Za-z0-9._~+/=:-]+","replacement":"Bearer [REDACTED]"},
    {"id":"authorization_header","pattern":"(?i)(authorization|cookie)[[:space:]]*:[[:space:]]*[^\\n\\r;]+","replacement":"[REDACTED_SECRET]"},
    {"id":"quoted_secret_double","pattern":"(?i)(api[_-]?key|token|password|passwd|secret|credential|private[_-]?key)[[:space:]]*[:=][[:space:]]*\"[^\"\\n\\r]*\"","replacement":"[REDACTED_SECRET]"},
    {"id":"quoted_secret_single","pattern":"(?i)(api[_-]?key|token|password|passwd|secret|credential|private[_-]?key)[[:space:]]*[:=][[:space:]]*'[^'\\n\\r]*'","replacement":"[REDACTED_SECRET]"},
    {"id":"unquoted_secret","pattern":"(?i)(api[_-]?key|token|password|passwd|secret|credential|private[_-]?key)[[:space:]]*[:=][[:space:]]*[^\\n\\r;,}]+","replacement":"[REDACTED_SECRET]"},
    {"id":"known_token_prefixes","pattern":"(?i)((sk|tp)[_-][A-Za-z0-9_./+=:-]{12,}|(ghp|github_pat|xox[baprs]|akia)[A-Za-z0-9_./+=:-]{12,})","replacement":"[REDACTED_TOKEN]"},
    {"id":"jwt","pattern":"eyJ[A-Za-z0-9_-]{20,}\\.[A-Za-z0-9_-]{20,}\\.[A-Za-z0-9_-]+","replacement":"[REDACTED_JWT]"},
    {"id":"long_hex","pattern":"\\b[0-9a-fA-F]{32,}\\b","replacement":"[REDACTED_HEX]"},
    {"id":"private_ip_10","pattern":"\\b10\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\b","replacement":"[REDACTED_IP]"},
    {"id":"private_ip_172","pattern":"\\b172\\.(1[6-9]|2\\d|3[01])\\.\\d{1,3}\\.\\d{1,3}\\b","replacement":"[REDACTED_IP]"},
    {"id":"private_ip_192","pattern":"\\b192\\.168\\.\\d{1,3}\\.\\d{1,3}\\b","replacement":"[REDACTED_IP]"}
  ],
  "sensitive_key_pattern": "(?i)(api[_-]?key|token|password|passwd|secret|authorization|cookie|credential|private[_-]?key)"
}
JSON
}

linux_agent_redaction_rules_config() {
    local path
    path="$(linux_agent_redaction_rules_path)"
    if [[ -f "${path}" ]] && jq -e 'type == "object" and (.rules | type == "array")' "${path}" >/dev/null 2>&1; then
        jq -c . "${path}"
        return 0
    fi
    linux_agent_redaction_rules_default_config | jq -c .
}

linux_agent_sanitize_text() {
    local input="$1"
    local limit="${2:-$(linux_agent_audit_text_limit)}"
    local redaction
    [[ "${limit}" =~ ^[0-9]+$ && "${limit}" -gt 0 ]] || limit=1000
    redaction="$(linux_agent_redaction_rules_config)"

    printf '%s' "${input}" | jq -R -r -s --argjson limit "${limit}" --argjson redaction "${redaction}" '
        def trim:
            if length > $limit then .[0:$limit] + "[TRUNCATED]" else . end;
        def redact_string:
            reduce ($redaction.rules // [])[] as $rule
                (.;
                 if (($rule.pattern // "") != "") then
                    gsub($rule.pattern; ($rule.replacement // "[REDACTED]"))
                 else . end);
        redact_string | trim
    '
}

linux_agent_sanitize_json() {
    local input="$1"
    local limit="${2:-$(linux_agent_audit_text_limit)}"
    local redaction
    [[ "${limit}" =~ ^[0-9]+$ && "${limit}" -gt 0 ]] || limit=1000
    redaction="$(linux_agent_redaction_rules_config)"

    if printf '%s' "${input}" | jq -e . >/dev/null 2>&1; then
        jq -c --argjson limit "${limit}" --argjson redaction "${redaction}" '
            def trim:
                if length > $limit then .[0:$limit] + "[TRUNCATED]" else . end;
            def sensitive_key:
                test($redaction.sensitive_key_pattern // "(?i)(api[_-]?key|token|password|passwd|secret|authorization|cookie|credential|private[_-]?key)");
            def redact_string:
                reduce ($redaction.rules // [])[] as $rule
                    (.;
                     if (($rule.pattern // "") != "") then
                        gsub($rule.pattern; ($rule.replacement // "[REDACTED]"))
                     else . end);
            def sanitize:
                if type == "object" then
                    with_entries(
                        if (.key | sensitive_key) then
                            .value = "[REDACTED]"
                        else
                            .value |= sanitize
                        end
                    )
                elif type == "array" then
                    map(sanitize)
                elif type == "string" then
                    redact_string | trim
                else
                    .
                end;
            sanitize
        ' <<<"${input}"
    else
        linux_agent_sanitize_text "${input}" "${limit}"
    fi
}

# Audit verbose mode needs the complete redacted value, while the general
# sanitizer intentionally caps strings for model prompts and summaries. Keep
# this separate so changing the audit view does not weaken those other limits.
linux_agent_redact_json_full() {
    local input="$1"
    local redaction
    redaction="$(linux_agent_redaction_rules_config)"

    if printf '%s' "${input}" | jq -e . >/dev/null 2>&1; then
        jq -c --argjson redaction "${redaction}" '
            def sensitive_key:
                test($redaction.sensitive_key_pattern // "(?i)(api[_-]?key|token|password|passwd|secret|authorization|cookie|credential|private[_-]?key)");
            def redact_string:
                reduce ($redaction.rules // [])[] as $rule
                    (.;
                     if (($rule.pattern // "") != "") then
                        gsub($rule.pattern; ($rule.replacement // "[REDACTED]"))
                     else . end);
            def redact:
                if type == "object" then
                    with_entries(
                        if (.key | sensitive_key) then
                            .value = "[REDACTED]"
                        else
                            .value |= redact
                        end
                    )
                elif type == "array" then
                    map(redact)
                elif type == "string" then
                    redact_string
                else
                    .
                end;
            redact
        ' <<<"${input}"
    else
        printf '%s' "${input}" |
            jq -R -r -s --argjson redaction "${redaction}" '
                reduce ($redaction.rules // [])[] as $rule
                    (.;
                     if (($rule.pattern // "") != "") then
                        gsub($rule.pattern; ($rule.replacement // "[REDACTED]"))
                     else . end)
            '
    fi
}

linux_agent_normalize_json_object_argument() {
    local input="${1:-}"
    [[ -z "${input}" ]] && input='{}'

    if ! printf '%s' "${input}" | jq -e . >/dev/null 2>&1; then
        return 1
    fi

    if printf '%s' "${input}" | jq -e 'type == "object"' >/dev/null 2>&1; then
        jq -c . <<<"${input}"
        return 0
    fi

    if printf '%s' "${input}" | jq -e 'type == "string" and ((fromjson? | type) == "object")' >/dev/null 2>&1; then
        jq -r 'fromjson | tojson' <<<"${input}"
        return 0
    fi

    return 1
}
