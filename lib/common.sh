#!/usr/bin/env bash

set -euo pipefail

LINUX_AGENT_ROOT=""
LINUX_AGENT_LOG_DIR=""
LINUX_AGENT_SESSION_DIR=""
LINUX_AGENT_CONFIG_FILE=""
LINUX_AGENT_SKILLS_DIR=""
LINUX_AGENT_TMP_DIR=""

linux_agent_init_env() {
    local root_dir="$1"
    LINUX_AGENT_ROOT="${root_dir}"
    LINUX_AGENT_LOG_DIR="${root_dir}/logs"
    LINUX_AGENT_SESSION_DIR="${root_dir}/sessions"
    LINUX_AGENT_CONFIG_FILE="${root_dir}/config/config.json"
    LINUX_AGENT_SKILLS_DIR="${root_dir}/skills"
    LINUX_AGENT_TMP_DIR="${root_dir}/tmp"

    mkdir -p \
        "${LINUX_AGENT_LOG_DIR}" \
        "${LINUX_AGENT_SESSION_DIR}" \
        "${LINUX_AGENT_SKILLS_DIR}" \
        "${LINUX_AGENT_TMP_DIR}" \
        "${root_dir}/config"
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
            | gsub("(?i)(sk|tp|ghp|github_pat|xox[baprs]|akia)[A-Za-z0-9_./+=:-]{12,}"; "[REDACTED_TOKEN]");
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
                | gsub("(?i)(sk|tp|ghp|github_pat|xox[baprs]|akia)[A-Za-z0-9_./+=:-]{12,}"; "[REDACTED_TOKEN]");
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
