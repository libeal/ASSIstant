#!/usr/bin/env bash

set -euo pipefail

LINUX_AGENT_CONVERSATION_HISTORY='[]'

linux_agent_context_turns() {
    linux_agent_config_get_default '.context_turns' '6'
}

linux_agent_redact_json() {
    local input="$1"
    linux_agent_sanitize_json "${input}"
}

linux_agent_history_window() {
    local turns
    turns="$(linux_agent_context_turns)"
    if [[ ! "${turns}" =~ ^[0-9]+$ ]]; then
        turns=6
    fi
    jq -c --argjson turns "${turns}" 'if $turns == 0 then [] else .[-$turns:] end' <<<"${LINUX_AGENT_CONVERSATION_HISTORY}"
}

linux_agent_record_turn() {
    local role="$1"
    local content="$2"
    local status="${3:-}"
    content="$(linux_agent_sanitize_text "${content}")"
    LINUX_AGENT_CONVERSATION_HISTORY="$(jq -cn \
        --argjson prior "${LINUX_AGENT_CONVERSATION_HISTORY}" \
        --arg role "${role}" \
        --arg content "${content}" \
        --arg status "${status}" \
        --arg ts "$(linux_agent_now_iso)" \
        '$prior + [{role:$role, content:$content, status:$status, timestamp:$ts}]')"
}

linux_agent_build_request_context() {
    local current_request="$1"
    local _environment_context="$2"
    local mode="${3:-work}"

    current_request="$(linux_agent_sanitize_text "${current_request}")"

    jq -cn \
        --arg mode "${mode}" \
        --arg current_request "${current_request}" \
        --argjson conversation_context "$(linux_agent_history_window)" \
        '{
            mode:$mode,
            conversation_context:$conversation_context,
            current_request:$current_request
        }'
}

linux_agent_context_json_value() {
    local input
    local sanitized

    if [[ $# -gt 0 && -n "${1:-}" ]]; then
        input="$1"
    else
        input='{}'
    fi

    sanitized="$(linux_agent_sanitize_json "${input}")"
    if printf '%s' "${sanitized}" | jq -e . >/dev/null 2>&1; then
        printf '%s\n' "${sanitized}"
    else
        jq -cn --arg raw "$(linux_agent_sanitize_text "${input}")" '{raw:$raw}'
    fi
}

linux_agent_build_ai_payload_context() {
    local request_context="$1"
    local runtime_context
    local safe_request_context safe_runtime_context

    if [[ $# -gt 1 && -n "${2:-}" ]]; then
        runtime_context="$2"
    else
        runtime_context='{}'
    fi

    safe_request_context="$(linux_agent_context_json_value "${request_context}")"
    safe_runtime_context="$(linux_agent_context_json_value "${runtime_context}")"

    jq -cn \
        --argjson request_context "${safe_request_context}" \
        --argjson runtime_context "${safe_runtime_context}" \
        '
        def empty_runtime:
            . == null or (type == "object" and length == 0) or (type == "string" and length == 0);
        (if ($request_context | type) == "object" then ($request_context | del(.environment_context)) else {value:$request_context} end)
        + (if ($runtime_context | empty_runtime) then {} else {environment_context:$runtime_context} end)
        '
}
