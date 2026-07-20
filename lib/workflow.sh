#!/usr/bin/env bash

set -euo pipefail

if ! declare -F linux_agent_audit_require_event >/dev/null 2>&1; then
    # shellcheck source=audit.sh
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/audit.sh"
fi

# Prepare one new Work request through the shared sensing and AI boundary.
# The returned object is adapter-neutral: CLI and API callers remain responsible
# for rendering, terminal status events, protocol envelopes, and history writes.
linux_agent_prepare_work_request() {
    local user_input="$1"
    local mode="${2:-work}"
    local topic context_json request_context response_json safe_response audit_rc

    linux_agent_audit_require_event "received" "$(jq -cn \
        --arg input "${user_input}" \
        --arg mode "${mode}" \
        '{input:$input, mode:$mode}')" || {
        audit_rc=$?
        linux_agent_audit_failure_result "${audit_rc}" "received"
        return 0
    }

    topic="$(linux_agent_detect_topic "${user_input}")"
    context_json="$(linux_agent_sense_topic "${topic}")"
    context_json="$(linux_agent_redact_json "${context_json}")"
    linux_agent_audit_require_event "sensed" "${context_json}" || {
        audit_rc=$?
        linux_agent_audit_failure_result "${audit_rc}" "sensed"
        return 0
    }

    request_context="$(linux_agent_build_request_context "${user_input}" "${context_json}" "work")"
    request_context="$(linux_agent_add_agent_loop_context "${request_context}")"
    request_context="$(linux_agent_add_skill_context "${request_context}" "work")"
    request_context="$(linux_agent_add_mcp_context "${request_context}" "work")"
    linux_agent_audit_require_event "request_context_built" "${request_context}" || {
        audit_rc=$?
        linux_agent_audit_failure_result "${audit_rc}" "request_context_built"
        return 0
    }

    linux_agent_record_ai_request_files "${request_context}"
    response_json="$(linux_agent_call_ai_with_context \
        "${user_input}" \
        "${request_context}" \
        "work_plan" \
        "${context_json}")"
    response_json="$(linux_agent_normalize_model_response "${response_json}")"
    linux_agent_store_thinking_summary "${response_json}" "initial"
    response_json="$(linux_agent_response_without_thinking "${response_json}")"

    if linux_agent_ai_response_is_error "${response_json}"; then
        linux_agent_audit_require_event "ai_failed" "${response_json}" || {
            audit_rc=$?
            linux_agent_audit_failure_result "${audit_rc}" "ai_failed"
            return 0
        }
        jq -cn \
            --arg status "$(jq -r '.status // "ai_failed"' <<<"${response_json}")" \
            --arg error "$(linux_agent_ai_error_text "${response_json}")" \
            --argjson context "${context_json}" \
            --argjson response "${response_json}" \
            '{ok:false, status:$status, error:$error, context:$context, response:$response}'
        return 0
    fi

    if ! linux_agent_validate_work_response "${response_json}"; then
        linux_agent_audit_require_event "ai_invalid_response" "${response_json}" || {
            audit_rc=$?
            linux_agent_audit_failure_result "${audit_rc}" "ai_invalid_response"
            return 0
        }
        jq -cn \
            --argjson context "${context_json}" \
            --argjson response "${response_json}" \
            '{
                ok:false,
                status:"ai_invalid_response",
                error:"模型响应不符合 work schema。",
                context:$context,
                response:$response
            }'
        return 0
    fi

    safe_response="$(linux_agent_response_without_thinking "${response_json}")"
    linux_agent_audit_require_event "planned" "${safe_response}" || {
        audit_rc=$?
        linux_agent_audit_failure_result "${audit_rc}" "planned"
        return 0
    }
    jq -cn \
        --argjson context "${context_json}" \
        --argjson response "${response_json}" \
        '{ok:true, status:"prepared", context:$context, response:$response}'
}

# Capture preparation output without running the preparation function in a
# command-substitution subshell.  Preparation records the exact AI files used
# in the session-wide manifest; losing those variable updates would make the
# final audit stream incomplete even though file appends still succeeded.
linux_agent_capture_prepared_work_request() {
    local output_var="$1"
    local user_input="$2"
    local mode="${3:-work}"
    local capture_file captured rc=0

    capture_file="$(mktemp "${LINUX_AGENT_TMP_DIR:-/tmp}/work.prepare.XXXXXX")"
    linux_agent_prepare_work_request "${user_input}" "${mode}" >"${capture_file}" || rc=$?
    captured="$(<"${capture_file}")"
    rm -f "${capture_file}"
    printf -v "${output_var}" '%s' "${captured}"
    return "${rc}"
}

# Select the configured Work execution engine and retain the selection as data.
# Encoding used_agent_loop alongside the execution result avoids relying on a
# global variable that would be lost when callers use command substitution.
linux_agent_execute_prepared_work() {
    local user_input="$1"
    local mode="${2:-work}"
    local context_json="$3"
    local response_json="$4"
    local execution_state_json="${5:-}"
    local used_agent_loop execution_json

    if [[ -z "${execution_state_json}" ]] ||
        ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"${execution_state_json}"; then
        execution_state_json='{}'
    fi

    if [[ "$(linux_agent_agent_loop_enabled)" == "true" ]]; then
        used_agent_loop=true
        execution_json="$(linux_agent_run_agent_loop \
            "${user_input}" \
            "${mode}" \
            "${context_json}" \
            "${response_json}" \
            "${execution_state_json}")"
    else
        used_agent_loop=false
        execution_json="$(linux_agent_execute_work_plan \
            "${response_json}" \
            "${user_input}" \
            "${execution_state_json}")"
    fi

    printf '%s\n%s\n' "${used_agent_loop}" "${execution_json}" |
        jq -cs '{used_agent_loop:.[0], execution:.[1]}'
}
