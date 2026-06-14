#!/usr/bin/env bash

set -euo pipefail

LINUX_AGENT_CONVERSATION_HISTORY='[]'

linux_agent_context_turns() {
    linux_agent_config_get_default '.context_turns' '6'
}

linux_agent_redact_text() {
    linux_agent_sanitize_text "$(cat)"
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
    local environment_context="$2"
    local mode="${3:-work}"

    current_request="$(linux_agent_sanitize_text "${current_request}")"
    environment_context="$(linux_agent_sanitize_json "${environment_context}")"

    jq -cn \
        --arg mode "${mode}" \
        --arg current_request "${current_request}" \
        --argjson conversation_context "$(linux_agent_history_window)" \
        --argjson environment_context "${environment_context}" \
        '{
            mode:$mode,
            conversation_context:$conversation_context,
            current_request:$current_request,
            environment_context:$environment_context
        }'
}
