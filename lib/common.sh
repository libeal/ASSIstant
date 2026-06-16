#!/usr/bin/env bash

set -euo pipefail

LINUX_AGENT_ROOT=""
LINUX_AGENT_LOG_DIR=""
LINUX_AGENT_CONFIG_FILE=""
LINUX_AGENT_SKILLS_DIR=""
LINUX_AGENT_TMP_ROOT=""
LINUX_AGENT_TMP_DIR=""

linux_agent_init_env() {
    local root_dir="$1"
    LINUX_AGENT_ROOT="${root_dir}"
    LINUX_AGENT_LOG_DIR="${root_dir}/logs"
    LINUX_AGENT_CONFIG_FILE="${root_dir}/config/config.json"
    LINUX_AGENT_SKILLS_DIR="${root_dir}/skills"
    LINUX_AGENT_TMP_ROOT="${root_dir}/tmp"
    LINUX_AGENT_TMP_DIR="${LINUX_AGENT_TMP_ROOT}"

    mkdir -p \
        "${LINUX_AGENT_LOG_DIR}" \
        "${LINUX_AGENT_SKILLS_DIR}" \
        "${LINUX_AGENT_TMP_ROOT}" \
        "${root_dir}/config"
}

linux_agent_use_session_tmp_dir() {
    local scope="$1"
    local safe_scope

    [[ -n "${LINUX_AGENT_TMP_ROOT:-}" ]] || return 0
    safe_scope="$(printf '%s' "${scope}" | tr -c 'A-Za-z0-9_.-' '_' | cut -c 1-80)"
    [[ -n "${safe_scope}" ]] || safe_scope="process_$$"
    LINUX_AGENT_TMP_DIR="${LINUX_AGENT_TMP_ROOT}/${safe_scope}"
    mkdir -p "${LINUX_AGENT_TMP_DIR}"
}

linux_agent_cleanup_tmp_dir() {
    local tmp_dir="${LINUX_AGENT_TMP_DIR:-}"
    local tmp_root="${LINUX_AGENT_TMP_ROOT:-${LINUX_AGENT_ROOT:-}/tmp}"
    local resolved_tmp resolved_root

    [[ -n "${tmp_dir}" && -n "${tmp_root}" ]] || return 0

    resolved_tmp="$(readlink -f "${tmp_dir}" 2>/dev/null || true)"
    resolved_root="$(readlink -f "${tmp_root}" 2>/dev/null || true)"
    [[ -n "${resolved_tmp}" && -n "${resolved_root}" ]] || return 0

    if [[ "${resolved_tmp}" == "/" || ( "${resolved_tmp}" != "${resolved_root}" && "${resolved_tmp}" != "${resolved_root}/"* ) ]]; then
        linux_agent_print_warn "跳过临时目录清理，路径不在项目 tmp 内: ${tmp_dir}"
        return 0
    fi

    if [[ "${resolved_tmp}" == "${resolved_root}" ]]; then
        mkdir -p "${resolved_tmp}"
        find "${resolved_tmp}" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null || true
    else
        rm -rf -- "${resolved_tmp}" 2>/dev/null || true
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
        safe_summary|redacted_verbose)
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
    printf '%s\n' "${limit}"
}

linux_agent_sanitize_text() {
    local input="$1"
    local limit="${2:-$(linux_agent_audit_text_limit)}"
    [[ "${limit}" =~ ^[0-9]+$ && "${limit}" -gt 0 ]] || limit=1000

    printf '%s' "${input}" | jq -R -r -s --argjson limit "${limit}" '
        def trim:
            if length > $limit then .[0:$limit] + "[TRUNCATED]" else . end;
        def redact_string:
            gsub("-----BEGIN [^-]+ PRIVATE KEY-----[\\s\\S]*?-----END [^-]+ PRIVATE KEY-----"; "[REDACTED_PRIVATE_KEY]")
            | gsub("(?i)Bearer[[:space:]]+[A-Za-z0-9._~+/=:-]+"; "Bearer [REDACTED]")
            | gsub("(?i)(authorization|cookie)[[:space:]]*:[[:space:]]*[^\\n\\r;]+"; "[REDACTED_SECRET]")
            | gsub("(?i)(api[_-]?key|token|password|passwd|secret|credential|private[_-]?key)[[:space:]]*[:=][[:space:]]*\"[^\"\\n\\r]*\"";
                   "[REDACTED_SECRET]")
            | gsub("(?i)(api[_-]?key|token|password|passwd|secret|credential|private[_-]?key)[[:space:]]*[:=][[:space:]]*'\''[^'\''\\n\\r]*'\''";
                   "[REDACTED_SECRET]")
            | gsub("(?i)(api[_-]?key|token|password|passwd|secret|credential|private[_-]?key)[[:space:]]*[:=][[:space:]]*[^\\n\\r;,}]+";
                   "[REDACTED_SECRET]")
            | gsub("(?i)((sk|tp)[_-][A-Za-z0-9_./+=:-]{12,}|(ghp|github_pat|xox[baprs]|akia)[A-Za-z0-9_./+=:-]{12,})"; "[REDACTED_TOKEN]");
        redact_string | trim
    '
}

linux_agent_sanitize_json() {
    local input="$1"
    local limit="${2:-$(linux_agent_audit_text_limit)}"
    [[ "${limit}" =~ ^[0-9]+$ && "${limit}" -gt 0 ]] || limit=1000

    if printf '%s' "${input}" | jq -e . >/dev/null 2>&1; then
        jq -c --argjson limit "${limit}" '
            def trim:
                if length > $limit then .[0:$limit] + "[TRUNCATED]" else . end;
            def sensitive_key:
                test("(?i)(api[_-]?key|token|password|passwd|secret|authorization|cookie|credential|private[_-]?key)");
            def redact_string:
                gsub("-----BEGIN [^-]+ PRIVATE KEY-----[\\s\\S]*?-----END [^-]+ PRIVATE KEY-----"; "[REDACTED_PRIVATE_KEY]")
                | gsub("(?i)Bearer[[:space:]]+[A-Za-z0-9._~+/=:-]+"; "Bearer [REDACTED]")
                | gsub("(?i)(authorization|cookie)[[:space:]]*:[[:space:]]*[^\\n\\r;]+"; "[REDACTED_SECRET]")
                | gsub("(?i)(api[_-]?key|token|password|passwd|secret|credential|private[_-]?key)[[:space:]]*[:=][[:space:]]*\"[^\"\\n\\r]*\"";
                       "[REDACTED_SECRET]")
                | gsub("(?i)(api[_-]?key|token|password|passwd|secret|credential|private[_-]?key)[[:space:]]*[:=][[:space:]]*'\''[^'\''\\n\\r]*'\''";
                       "[REDACTED_SECRET]")
                | gsub("(?i)(api[_-]?key|token|password|passwd|secret|credential|private[_-]?key)[[:space:]]*[:=][[:space:]]*[^\\n\\r;,}]+";
                       "[REDACTED_SECRET]")
                | gsub("(?i)((sk|tp)[_-][A-Za-z0-9_./+=:-]{12,}|(ghp|github_pat|xox[baprs]|akia)[A-Za-z0-9_./+=:-]{12,})"; "[REDACTED_TOKEN]");
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
