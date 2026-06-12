#!/usr/bin/env bash

set -euo pipefail

linux_agent_process_work_request() {
    local user_input="$1"
    local mode="${2:-work}"
    local topic context_json request_context response_json execution_json final_status response_type

    linux_agent_start_session "${user_input}"
    linux_agent_log_event "received" "$(jq -cn --arg input "${user_input}" --arg mode "${mode}" '{input:$input, mode:$mode}')"

    topic="$(linux_agent_detect_topic "${user_input}")"
    context_json="$(linux_agent_sense_topic "${topic}")"
    context_json="$(linux_agent_redact_json "${context_json}")"
    linux_agent_log_event "sensed" "${context_json}"
    linux_agent_append_session_note "环境感知（已脱敏）" "$(jq . <<<"${context_json}")"

    request_context="$(linux_agent_build_request_context "${user_input}" "${context_json}" "work")"
    linux_agent_log_event "request_context_built" "${request_context}"

    response_json="$(linux_agent_call_ai_with_context "${user_input}" "${request_context}" "work_plan")"
    response_json="$(linux_agent_normalize_model_response "${response_json}")"
    if ! linux_agent_validate_work_response "${response_json}"; then
        linux_agent_print_warn "模型响应不符合 work_plan schema，改用 Mock 响应兜底。"
        response_json="$(linux_agent_mock_work_plan "${user_input}")"
    fi

    if [[ "${LINUX_AGENT_FORCE_PLAN:-0}" == "1" && "$(jq -r '.response_type' <<<"${response_json}")" == "work_plan" ]]; then
        linux_agent_log_event "planned" "${response_json}"
        linux_agent_append_session_note "模型规划" "$(jq . <<<"${response_json}")"
        linux_agent_print_work_plan "${response_json}"
        final_status="planned"
        linux_agent_log_event "finished" "$(jq -cn --arg status "${final_status}" '{status:$status}')"
        linux_agent_finish_session "${final_status}"
        linux_agent_record_turn "user" "${user_input}" "${mode}"
        linux_agent_record_turn "assistant" "$(jq -r '.summary' <<<"${response_json}")" "${final_status}"
        return 0
    fi

    linux_agent_log_event "planned" "${response_json}"
    linux_agent_append_session_note "模型规划" "$(jq . <<<"${response_json}")"

    response_type="$(jq -r '.response_type' <<<"${response_json}")"
    if [[ "${response_type}" == "answer" ]]; then
        printf '%s\n' "$(jq -r '.answer' <<<"${response_json}")"
        final_status="answered"
        linux_agent_log_event "finished" "$(jq -cn --arg status "${final_status}" '{status:$status}')"
        linux_agent_finish_session "${final_status}"
        linux_agent_record_turn "user" "${user_input}" "${mode}"
        linux_agent_record_turn "assistant" "$(jq -r '.answer' <<<"${response_json}")" "${final_status}"
        return 0
    fi

    execution_json="$(linux_agent_execute_work_plan "${response_json}" "${user_input}")"
    linux_agent_log_event "executed" "${execution_json}"
    linux_agent_append_session_note "执行结果" "$(jq . <<<"${execution_json}")"
    if linux_agent_output_json_enabled; then
        printf '%s\n' "$(linux_agent_compact_execution_result "${execution_json}" | jq .)"
    else
        linux_agent_print_work_execution_status "${execution_json}"
    fi

    final_status="$(jq -r '.status' <<<"${execution_json}")"
    linux_agent_log_event "finished" "$(jq -cn --arg status "${final_status}" '{status:$status}')"
    linux_agent_finish_session "${final_status}"
    linux_agent_record_turn "user" "${user_input}" "${mode}"
    linux_agent_record_turn "assistant" "$(jq -c '{status:.status, results:(.results | length)}' <<<"${execution_json}")" "${final_status}"
}

linux_agent_process_script_request() {
    local ref="$1"
    local arguments_json="${2:-}"
    local review material result final_status
    [[ -z "${arguments_json}" ]] && arguments_json='{}'

    linux_agent_start_session "script ${ref}"
    linux_agent_log_event "received" "$(jq -cn --arg ref "${ref}" --argjson args "${arguments_json}" '{mode:"script", ref:$ref, arguments:$args}')"

    if ! linux_agent_skill_is_registered "${ref}"; then
        result="$(jq -cn --arg ref "${ref}" '{ok:false, status:"blocked", error:"脚本未登记或不在 skills 目录中。", ref:$ref}')"
        linux_agent_log_event "script_blocked" "${result}"
        if linux_agent_output_json_enabled; then
            printf '%s\n' "$(jq . <<<"${result}")"
        else
            linux_agent_print_script_result "${result}"
        fi
        linux_agent_finish_session "blocked"
        return 0
    fi

    material="$(printf 'skill_script=%s\narguments=%s\n%s\n' "${ref}" "${arguments_json}" "$(linux_agent_skill_script_content "${ref}")")"
    review="$(linux_agent_policy_review_text "script:${ref}" "${material}")"
    linux_agent_log_event "script_policy_checked" "${review}"
    printf '脚本: %s\n参数: %s\n审查: %s\n' "${ref}" "${arguments_json}" "$(jq -c '.risk_level' <<<"${review}")"
    if [[ "$(jq -r '.approved' <<<"${review}")" != "true" ]]; then
        result="$(jq -cn --arg ref "${ref}" --argjson review "${review}" '{ok:false, status:"blocked", ref:$ref, review:$review}')"
        linux_agent_log_event "script_blocked" "${result}"
        if linux_agent_output_json_enabled; then
            printf '%s\n' "$(jq . <<<"${result}")"
        else
            linux_agent_print_script_result "${result}"
        fi
        linux_agent_finish_session "blocked"
        return 0
    fi

    if ! linux_agent_confirm_execution "批准执行该 skill 脚本？"; then
        result="$(jq -cn --arg ref "${ref}" '{ok:false, status:"rejected", ref:$ref}')"
        linux_agent_log_event "script_rejected" "${result}"
        if linux_agent_output_json_enabled; then
            printf '%s\n' "$(jq . <<<"${result}")"
        else
            linux_agent_print_script_result "${result}"
        fi
        linux_agent_finish_session "rejected"
        return 0
    fi

    result="$(linux_agent_run_skill_script "${ref}" "${arguments_json}" 2>&1 || true)"
    if printf '%s' "${result}" | jq -e . >/dev/null 2>&1; then
        result="$(jq -c . <<<"${result}")"
    else
        result="$(jq -cn --arg raw "${result}" '{ok:false, output:{raw:$raw}}')"
    fi
    linux_agent_log_event "script_executed" "${result}"
    linux_agent_append_session_note "脚本执行结果" "$(jq . <<<"${result}")"
    if linux_agent_output_json_enabled; then
        printf '%s\n' "$(jq . <<<"${result}")"
    else
        linux_agent_print_script_result "${result}"
    fi

    if [[ "$(jq -r '.ok // false' <<<"${result}")" == "true" ]]; then
        final_status="executed"
    else
        final_status="failed"
    fi
    linux_agent_log_event "finished" "$(jq -cn --arg status "${final_status}" '{status:$status}')"
    linux_agent_finish_session "${final_status}"
}

linux_agent_process_terminal_request() {
    local command_text="$1"
    local stdout_file stderr_file stdout_preview stderr_preview exit_code final_status result

    linux_agent_start_session "terminal ${command_text}"
    linux_agent_log_event "received" "$(jq -cn --arg command "${command_text}" '{mode:"terminal", command:$command}')"

    stdout_file="$(mktemp "${LINUX_AGENT_TMP_DIR}/terminal.stdout.XXXXXX")"
    stderr_file="$(mktemp "${LINUX_AGENT_TMP_DIR}/terminal.stderr.XXXXXX")"

    set +e
    bash -lc "${command_text}" >"${stdout_file}" 2>"${stderr_file}"
    exit_code=$?
    set -e

    stdout_preview="$(head -c 4000 "${stdout_file}" || true)"
    stderr_preview="$(head -c 4000 "${stderr_file}" || true)"
    if [[ "${exit_code}" -eq 0 ]]; then
        final_status="executed"
    else
        final_status="failed"
    fi

    result="$(jq -cn \
        --arg command "${command_text}" \
        --arg stdout_preview "${stdout_preview}" \
        --arg stderr_preview "${stderr_preview}" \
        --arg status "${final_status}" \
        --argjson exit_code "${exit_code}" \
        '{ok:($exit_code == 0), status:$status, command:$command, exit_code:$exit_code, stdout_preview:$stdout_preview, stderr_preview:$stderr_preview}')"

    linux_agent_log_event "terminal_executed" "${result}"
    linux_agent_append_session_note "终端模式执行结果" "$(jq . <<<"${result}")"
    if linux_agent_output_json_enabled; then
        printf '%s\n' "$(jq . <<<"${result}")"
    else
        linux_agent_print_terminal_result "${result}"
    fi
    linux_agent_log_event "finished" "$(jq -cn --arg status "${final_status}" '{status:$status}')"
    linux_agent_finish_session "${final_status}"

    rm -f "${stdout_file}" "${stderr_file}"
    return 0
}

linux_agent_process_request() {
    local user_input="$1"
    local mode="${2:-work}"
    case "${mode}" in
        edit)
            linux_agent_process_edit_request "${user_input}" "${mode}"
            ;;
        script)
            local ref args
            ref="${user_input%% *}"
            args="${user_input#${ref}}"
            args="${args# }"
            [[ -z "${args}" || "${args}" == "${user_input}" ]] && args='{}'
            linux_agent_process_script_request "${ref}" "${args}"
            ;;
        terminal)
            linux_agent_process_terminal_request "${user_input}"
            ;;
        work|interactive|oneshot|plan|*)
            linux_agent_process_work_request "${user_input}" "${mode}"
            ;;
    esac
}
