#!/usr/bin/env bash

set -euo pipefail

linux_agent_agent_loop_enabled() {
    linux_agent_config_bool_default '.agent_loop.enabled_for_work' 'true'
}

linux_agent_thinking_trace_enabled() {
    linux_agent_config_bool_default '.agent_loop.thinking_trace_enabled' 'false'
}

linux_agent_agent_observation_limit() {
    linux_agent_config_positive_int_default '.agent_loop.observation_text_limit' '4000'
}

linux_agent_agent_checkpoint_turns() {
    local checkpoint context_turns

    checkpoint="$(linux_agent_config_get_default '.agent_loop.checkpoint_turns' '')"
    if [[ "${checkpoint}" =~ ^[0-9]+$ && "${checkpoint}" -gt 0 ]]; then
        printf '%s\n' "${checkpoint}"
        return 0
    fi

    context_turns="$(linux_agent_context_turns)"
    if [[ "${context_turns}" =~ ^[0-9]+$ && "${context_turns}" -gt 0 ]]; then
        printf '%s\n' "${context_turns}"
    else
        printf '6\n'
    fi
}

linux_agent_agent_loop_context_json() {
    jq -cn \
        --argjson thinking_trace_enabled "$(linux_agent_thinking_trace_enabled)" \
        --argjson auto_approval "$(linux_agent_auto_approval_config_json)" \
        '{
            thinking_trace_enabled:$thinking_trace_enabled,
            auto_approval:$auto_approval
        }'
}

linux_agent_add_agent_loop_context() {
    local request_context="$1"
    jq -c --argjson agent_loop "$(linux_agent_agent_loop_context_json)" \
        '. + {agent_loop:$agent_loop}' <<<"${request_context}"
}

linux_agent_response_without_thinking() {
    local response_json="$1"
    jq -c 'del(.thinking_summary)' <<<"${response_json}"
}

linux_agent_store_thinking_summary() {
    local response_json="$1"
    local iteration="$2"
    local summary safe_session dir path limit

    [[ "$(linux_agent_thinking_trace_enabled)" == "true" ]] || return 0
    summary="$(jq -r '.thinking_summary // empty' <<<"${response_json}")"
    [[ -n "${summary}" ]] || return 0

    limit="$(linux_agent_agent_observation_limit)"
    safe_session="$(printf '%s' "${LINUX_AGENT_SESSION_ID:-session}" | tr -c 'A-Za-z0-9_.-' '_' | cut -c 1-80)"
    [[ -n "${safe_session}" ]] || safe_session="session"
    dir="/tmp/${safe_session}/thinking"
    mkdir -p "${dir}"
    path="${dir}/iteration-${iteration}.txt"
    {
        printf 'session_id=%s\n' "${LINUX_AGENT_SESSION_ID:-}"
        printf 'iteration=%s\n' "${iteration}"
        printf 'timestamp=%s\n\n' "$(linux_agent_now_iso)"
        linux_agent_sanitize_text "${summary}" "${limit}"
        printf '\n'
    } > "${path}"
}

linux_agent_build_agent_observation() {
    local user_input="$1"
    local iteration="$2"
    local plan_json="$3"
    local execution_json="$4"
    local environment_context="$5"
    local limit observation

    limit="$(linux_agent_agent_observation_limit)"
    observation="$(jq -cn \
        --arg input "${user_input}" \
        --argjson iteration "${iteration}" \
        --argjson plan "${plan_json}" \
        --argjson execution "${execution_json}" \
        --argjson environment_context "${environment_context}" \
        --argjson limit "${limit}" \
        '
        def preview:
            tostring | if length > $limit then .[0:$limit] + "[TRUNCATED]" else . end;
        def step_summary($s): {
            id:($s.id // null),
            title:($s.title // null),
            executor_type:($s.executor_type // null),
            skill_script:($s.skill_script // null),
            risk_level:($s.risk_level // null),
            has_command:($s | has("command")),
            url:($s.url // null)
        };
        def output_preview($o):
            if $o == null then null
            elif ($o | type) == "object" and ($o | has("raw")) then ($o.raw | preview)
            else ($o | tojson | preview) end;
        def result_summary($r): {
            ok:($r.ok // false),
            status:($r.status // null),
            exit_code:($r.exit_code // null),
            tool:($r.output.tool // null),
            action:($r.output.action // null),
            auto_approved:($r.auto_approved // false),
            execution_proxy:($r.execution_proxy // null),
            output_keys:(if ($r.output? | type) == "object" then ($r.output | keys) else [] end),
            output_preview:output_preview($r.output)
        };
        {
            agent_observation:{
                original_request:$input,
                iteration:$iteration,
                environment_context:$environment_context,
                plan:{
                    summary:($plan.summary // ""),
                    step_count:(($plan.steps // []) | length),
                    steps:[($plan.steps // [])[] | step_summary(.)]
                },
                execution:{
                    status:($execution.status // "unknown"),
                    result_count:(($execution.results // []) | length),
                    auto_executed_count:([($execution.results // [])[] | select(.result.auto_approved == true)] | length),
                    failed_count:([($execution.results // [])[] | select((.result.ok // false) == false)] | length),
                    findings:($execution.findings // []),
                    results:[($execution.results // [])[] | {step:step_summary(.step), result:result_summary(.result)}]
                }
            }
        }')"
    linux_agent_sanitize_json "${observation}" "${limit}"
}

linux_agent_fallback_reflection_response() {
    local reason="$1"
    jq -cn --arg reason "${reason}" '
        {
            response_type:"answer",
            summary:"反思响应无效，停止自动深入。",
            continue_decision:{should_continue:false, reason:$reason},
            answer:$reason
        }'
}

linux_agent_plan_should_reflect_after_execution() {
    local plan_json="$1"
    [[ "$(jq -r '.continue_decision.should_continue == true' <<<"${plan_json}" 2>/dev/null || printf 'false')" == "true" ]]
}

linux_agent_plan_stop_reason() {
    local plan_json="$1"
    jq -r '.continue_decision.reason // "plan_completed"' <<<"${plan_json}" 2>/dev/null || printf 'plan_completed\n'
}

linux_agent_request_agent_reflection() {
    local user_input="$1"
    local iteration="$2"
    local observation_json="$3"
    local reflection_context response_json safe_response status result_count

    reflection_context="$(jq -cn \
        --arg mode "work_reflect" \
        --arg current_request "${user_input}" \
        --argjson conversation_context "$(linux_agent_history_window)" \
        --argjson agent_loop "$(linux_agent_agent_loop_context_json)" \
        '{
            mode:$mode,
            conversation_context:$conversation_context,
            current_request:$current_request,
            agent_loop:$agent_loop
        }')"

    status="$(jq -r '.agent_observation.execution.status // "unknown"' <<<"${observation_json}")"
    result_count="$(jq -r '.agent_observation.execution.result_count // 0' <<<"${observation_json}")"
    linux_agent_log_event "agent_reflection_requested" "$(jq -cn \
        --argjson iteration "${iteration}" \
        --arg status "${status}" \
        --argjson result_count "${result_count}" \
        '{iteration:$iteration, execution_status:$status, result_count:$result_count}')"

    linux_agent_record_ai_request_files "${reflection_context}"
    response_json="$(linux_agent_call_ai_with_context "${user_input}" "${reflection_context}" "work_reflect" "${observation_json}")"
    response_json="$(linux_agent_normalize_model_response "${response_json}")"
    linux_agent_store_thinking_summary "${response_json}" "${iteration}"

    if linux_agent_ai_response_is_error "${response_json}"; then
        linux_agent_print_warn "$(linux_agent_ai_error_text "${response_json}")"
        response_json="$(linux_agent_fallback_reflection_response "$(linux_agent_ai_error_text "${response_json}")")"
    fi

    if ! linux_agent_validate_work_response "${response_json}"; then
        linux_agent_print_warn "模型反思响应缺少合法 continue_decision，停止自动深入。"
        response_json="$(linux_agent_fallback_reflection_response "模型反思响应无效，已停止自动深入。")"
    fi

    safe_response="$(linux_agent_response_without_thinking "${response_json}")"
    linux_agent_log_event "agent_reflection_planned" "${safe_response}"
    printf '%s\n' "${response_json}"
}

linux_agent_record_agent_loop_iteration_turn() {
    local user_input="$1"
    local mode="$2"
    local iteration="$3"
    local plan_json="$4"
    local execution_json="$5"
    local reflection_json="${6:-null}"
    local stopped_reason="${7:-}"
    local status_override="${8:-}"
    local status result_count plan_summary reflection_summary response_content metadata

    if ! jq -e . <<<"${reflection_json}" >/dev/null 2>&1; then
        reflection_json='null'
    fi
    status="$(jq -r '.status // "unknown"' <<<"${execution_json}" 2>/dev/null || printf 'unknown\n')"
    if [[ -n "${status_override}" ]]; then
        status="${status_override}"
    fi
    result_count="$(jq -r '(.results // []) | length' <<<"${execution_json}" 2>/dev/null || printf '0\n')"
    plan_summary="$(jq -r '.summary // ""' <<<"${plan_json}" 2>/dev/null || true)"
    reflection_summary="$(jq -r '.summary // .answer // ""' <<<"${reflection_json}" 2>/dev/null || true)"
    response_content="$(jq -cn \
        --arg status "${status}" \
        --argjson iteration "${iteration}" \
        --argjson result_count "${result_count}" \
        --arg stopped_reason "${stopped_reason}" \
        --arg reflection_summary "${reflection_summary}" \
        '{iteration:$iteration, status:$status, result_count:$result_count, stopped_reason:$stopped_reason, reflection_summary:$reflection_summary}')"
    metadata="$(jq -cn \
        --argjson iteration "${iteration}" \
        --argjson result_count "${result_count}" \
        --arg plan_summary "${plan_summary}" \
        --arg reflection_summary "${reflection_summary}" \
        --arg stopped_reason "${stopped_reason}" \
        '{iteration:$iteration, result_count:$result_count, plan_summary:$plan_summary, reflection_summary:$reflection_summary, stopped_reason:$stopped_reason}')"
    linux_agent_record_conversation_turn "${mode}" "${user_input}" "${response_content}" "${status}" "agent_loop_iteration" "${metadata}"
}

linux_agent_run_agent_loop() {
    local user_input="$1"
    local mode="$2"
    local environment_context="$3"
    local initial_plan="$4"
    local resume_state="${5:-{}}"
    local current_plan execution_json all_results iteration status final_status final_answer stopped_reason
    local observation_json reflection_json checkpoint_turns auto_executed_count checkpoint_required final_review final_approval_step
    local execution_user sudo_probe

    current_plan="${initial_plan}"
    all_results='[]'
    iteration=0
    final_status="executed"
    final_answer=""
    stopped_reason=""
    checkpoint_required=false
    final_review='null'
    final_approval_step='null'
    auto_executed_count=0
    execution_user=""
    sudo_probe=""
    checkpoint_turns="$(linux_agent_agent_checkpoint_turns)"

    linux_agent_log_event "agent_loop_started" "$(jq -cn \
        --arg mode "${mode}" \
        --argjson checkpoint_turns "${checkpoint_turns}" \
        --argjson agent_loop "$(linux_agent_agent_loop_context_json)" \
        '{mode:$mode, checkpoint_turns:$checkpoint_turns, agent_loop:$agent_loop}')"

    while true; do
        iteration=$((iteration + 1))
        reflection_json='null'
        linux_agent_log_event "agent_loop_iteration_started" "$(jq -cn \
            --argjson iteration "${iteration}" \
            --argjson plan "$(linux_agent_response_without_thinking "${current_plan}")" \
            '{iteration:$iteration, plan:$plan}')"

        execution_json="$(linux_agent_execute_work_plan "${current_plan}" "${user_input}" "${resume_state}")"
        resume_state='{}'
        execution_user="$(jq -r '.execution_user // empty' <<<"${execution_json}" 2>/dev/null || true)"
        sudo_probe="$(jq -r '.sudo_probe // empty' <<<"${execution_json}" 2>/dev/null || true)"
        all_results="$(jq -cn --argjson prior "${all_results}" --argjson next "$(jq '.results // []' <<<"${execution_json}")" '$prior + $next')"
        status="$(jq -r '.status // "unknown"' <<<"${execution_json}")"
        final_status="${status}"
        final_review="$(jq -c '.review // null' <<<"${execution_json}")"
        final_approval_step="$(jq -c '.approval_step // null' <<<"${execution_json}")"
        auto_executed_count="$(jq '[.[] | select(.result.auto_approved == true)] | length' <<<"${all_results}")"

        if [[ "${status}" != "executed" && "${status}" != "failed" ]]; then
            stopped_reason="${status}"
            linux_agent_record_agent_loop_iteration_turn "${user_input}" "${mode}" "${iteration}" "${current_plan}" "${execution_json}" "${reflection_json}" "${stopped_reason}" "${final_status}"
            break
        fi

        if [[ "${status}" == "executed" ]] && ! linux_agent_plan_should_reflect_after_execution "${current_plan}"; then
            stopped_reason="$(linux_agent_plan_stop_reason "${current_plan}")"
            linux_agent_record_agent_loop_iteration_turn "${user_input}" "${mode}" "${iteration}" "${current_plan}" "${execution_json}" "${reflection_json}" "${stopped_reason}" "${final_status}"
            break
        fi

        observation_json="$(linux_agent_build_agent_observation "${user_input}" "${iteration}" "${current_plan}" "${execution_json}" "${environment_context}")"
        reflection_json="$(linux_agent_request_agent_reflection "${user_input}" "${iteration}" "${observation_json}")"

        if [[ "$(jq -r '.response_type' <<<"${reflection_json}")" == "answer" ]]; then
            final_answer="$(jq -r '.answer // empty' <<<"${reflection_json}")"
            if [[ -n "${final_answer}" ]] && ! linux_agent_output_json_enabled; then
                printf '%s\n' "${final_answer}" >&2
            fi
            stopped_reason="$(jq -r '.continue_decision.reason // "model_stopped"' <<<"${reflection_json}")"
            linux_agent_record_agent_loop_iteration_turn "${user_input}" "${mode}" "${iteration}" "${current_plan}" "${execution_json}" "${reflection_json}" "${stopped_reason}" "${final_status}"
            break
        fi

        if [[ "$(jq -r '.response_type' <<<"${reflection_json}")" != "work_plan" ]]; then
            stopped_reason="continue_without_work_plan"
            linux_agent_record_agent_loop_iteration_turn "${user_input}" "${mode}" "${iteration}" "${current_plan}" "${execution_json}" "${reflection_json}" "${stopped_reason}" "${final_status}"
            break
        fi

        if (( iteration % checkpoint_turns == 0 )); then
            checkpoint_required=true
            linux_agent_log_event "agent_checkpoint_requested" "$(jq -cn \
                --argjson iteration "${iteration}" \
                --argjson checkpoint_turns "${checkpoint_turns}" \
                '{iteration:$iteration, checkpoint_turns:$checkpoint_turns}')"
            if linux_agent_confirm_execution "已连续迭代 ${iteration} 轮，允许继续深入？"; then
                linux_agent_log_event "agent_checkpoint_decision" "$(jq -cn \
                    --argjson iteration "${iteration}" \
                    '{iteration:$iteration, approved:true}')"
            else
                linux_agent_log_event "agent_checkpoint_decision" "$(jq -cn \
                    --argjson iteration "${iteration}" \
                    '{iteration:$iteration, approved:false}')"
                final_status="checkpoint_stopped"
                stopped_reason="checkpoint_rejected"
                linux_agent_record_agent_loop_iteration_turn "${user_input}" "${mode}" "${iteration}" "${current_plan}" "${execution_json}" "${reflection_json}" "${stopped_reason}" "${final_status}"
                break
            fi
        fi

        linux_agent_record_agent_loop_iteration_turn "${user_input}" "${mode}" "${iteration}" "${current_plan}" "${execution_json}" "${reflection_json}" "continue" "${final_status}"
        current_plan="${reflection_json}"
    done

    linux_agent_log_event "agent_loop_finished" "$(jq -cn \
        --arg status "${final_status}" \
        --arg stopped_reason "${stopped_reason}" \
        --argjson iterations "${iteration}" \
        --argjson auto_executed_count "${auto_executed_count}" \
        '{status:$status, stopped_reason:$stopped_reason, iterations:$iterations, auto_executed_count:$auto_executed_count}')"

    jq -cn \
        --arg status "${final_status}" \
        --arg execution_user "${execution_user}" \
        --arg sudo_probe "${sudo_probe}" \
        --arg final_answer "${final_answer}" \
        --arg stopped_reason "${stopped_reason}" \
        --argjson iterations "${iteration}" \
        --argjson auto_executed_count "${auto_executed_count}" \
        --argjson checkpoint_required "${checkpoint_required}" \
        --argjson review "${final_review}" \
        --argjson approval_step "${final_approval_step}" \
        --argjson results "${all_results}" \
        '{status:$status, execution_user:$execution_user, sudo_probe:$sudo_probe, review:$review, approval_step:$approval_step, iterations:$iterations, auto_executed_count:$auto_executed_count, final_answer:$final_answer, checkpoint_required:$checkpoint_required, stopped_reason:$stopped_reason, results:$results}'
}

linux_agent_process_work_request() {
    local user_input="$1"
    local mode="${2:-work}"
    local topic context_json request_context response_json execution_json final_status response_type safe_response used_agent_loop

    linux_agent_log_event "received" "$(jq -cn --arg input "${user_input}" --arg mode "${mode}" '{input:$input, mode:$mode}')"

    topic="$(linux_agent_detect_topic "${user_input}")"
    context_json="$(linux_agent_sense_topic "${topic}")"
    context_json="$(linux_agent_redact_json "${context_json}")"
    linux_agent_log_event "sensed" "${context_json}"

    request_context="$(linux_agent_build_request_context "${user_input}" "${context_json}" "work")"
    request_context="$(linux_agent_add_agent_loop_context "${request_context}")"
    linux_agent_log_event "request_context_built" "${request_context}"

    linux_agent_record_ai_request_files "${request_context}"
    response_json="$(linux_agent_call_ai_with_context "${user_input}" "${request_context}" "work_plan" "${context_json}")"
    response_json="$(linux_agent_normalize_model_response "${response_json}")"
    linux_agent_store_thinking_summary "${response_json}" "initial"
    if linux_agent_ai_response_is_error "${response_json}"; then
        linux_agent_log_event "ai_failed" "${response_json}"
        linux_agent_print_error "$(linux_agent_ai_error_text "${response_json}")"
        linux_agent_log_event "finished" "$(jq -cn '{status:"ai_failed"}')"
        return 1
    fi
    if ! linux_agent_validate_work_response "${response_json}"; then
        linux_agent_log_event "ai_invalid_response" "${response_json}"
        linux_agent_print_error "模型响应不符合 work schema。"
        linux_agent_log_event "finished" "$(jq -cn '{status:"ai_invalid_response"}')"
        return 1
    fi

    safe_response="$(linux_agent_response_without_thinking "${response_json}")"
    linux_agent_log_event "planned" "${safe_response}"

    response_type="$(jq -r '.response_type' <<<"${response_json}")"
    if [[ "${response_type}" == "answer" ]]; then
        printf '%s\n' "$(jq -r '.answer' <<<"${response_json}")"
        final_status="answered"
        linux_agent_log_event "finished" "$(jq -cn --arg status "${final_status}" '{status:$status}')"
        linux_agent_record_conversation_turn "${mode}" "${user_input}" "$(jq -r '.answer' <<<"${response_json}")" "${final_status}" "request"
        return 0
    fi

    if [[ "$(linux_agent_agent_loop_enabled)" == "true" ]]; then
        used_agent_loop=true
        execution_json="$(linux_agent_run_agent_loop "${user_input}" "${mode}" "${context_json}" "${response_json}")"
    else
        used_agent_loop=false
        execution_json="$(linux_agent_execute_work_plan "${response_json}" "${user_input}")"
    fi
    linux_agent_log_event "executed" "${execution_json}"
    if linux_agent_output_json_enabled; then
        printf '%s\n' "$(linux_agent_compact_execution_result "${execution_json}" | jq .)"
    else
        linux_agent_print_work_execution_status "${execution_json}"
    fi

    final_status="$(jq -r '.status' <<<"${execution_json}")"
    linux_agent_log_event "finished" "$(jq -cn --arg status "${final_status}" '{status:$status}')"
    if [[ "${used_agent_loop}" != "true" ]]; then
        linux_agent_record_conversation_turn "${mode}" "${user_input}" "$(jq -c '{status:.status, results:(.results | length)}' <<<"${execution_json}")" "${final_status}" "request"
    fi
}

linux_agent_print_execution_protocol_json() {
    local title="$1"
    local result_json="$2"
    local approval_card="${3:-null}"
    local protocol

    if [[ "${LINUX_AGENT_API_MODE:-0}" == "1" ]]; then
        printf '%s\n' "$(jq . <<<"${result_json}")"
        return 0
    fi

    protocol="$(linux_agent_protocol_for_single_execution "${title}" "${result_json}")"
    jq --argjson protocol "${protocol}" --argjson approval_card "${approval_card}" '
        {
            ok:(.ok // false),
            status:(.status // $protocol.timeline[0].status // (if (.ok // false) then "executed" else "failed" end)),
            timeline:$protocol.timeline,
            approval_card:$approval_card,
            output_blocks:$protocol.output_blocks
        }
    ' <<<"${result_json}"
}

linux_agent_process_script_request() {
    local ref="$1"
    local arguments_json="${2:-}"
    local review material result final_status
    [[ -z "${arguments_json}" ]] && arguments_json='{}'

    if ! arguments_json="$(linux_agent_normalize_json_object_argument "${arguments_json}")"; then
        result="$(jq -cn --arg ref "${ref}" '{ok:false, status:"blocked", error:"脚本参数必须是 JSON 对象。", ref:$ref}')"
        linux_agent_log_event "script_blocked" "${result}"
        if linux_agent_output_json_enabled; then
            linux_agent_print_execution_protocol_json "Skill 输出" "${result}"
        else
            linux_agent_print_script_result "${result}"
        fi
        linux_agent_log_event "finished" "$(jq -cn '{status:"blocked"}')"
        return 0
    fi

    linux_agent_log_event "received" "$(jq -cn --arg ref "${ref}" --argjson args "${arguments_json}" '{mode:"script", ref:$ref, arguments:$args}')"

    if ! linux_agent_skill_is_registered "${ref}"; then
        result="$(jq -cn --arg ref "${ref}" '{ok:false, status:"blocked", error:"脚本未登记或不在 skills 目录中。", ref:$ref}')"
        linux_agent_log_event "script_blocked" "${result}"
        if linux_agent_output_json_enabled; then
            linux_agent_print_execution_protocol_json "Skill 输出" "${result}"
        else
            linux_agent_print_script_result "${result}"
        fi
        linux_agent_log_event "finished" "$(jq -cn '{status:"blocked"}')"
        return 0
    fi

    material="$(printf 'skill_script=%s\narguments=%s\n%s\n' "${ref}" "${arguments_json}" "$(linux_agent_skill_script_content "${ref}")")"
    review="$(linux_agent_policy_review_text "script:${ref}" "${material}")"
    linux_agent_log_event "script_policy_checked" "${review}"
    if ! linux_agent_output_json_enabled; then
        printf '脚本: %s\n参数: %s\n审查: %s\n' "${ref}" "${arguments_json}" "$(jq -c '.risk_level' <<<"${review}")"
    fi
    if [[ "$(jq -r '.approved' <<<"${review}")" != "true" ]]; then
        result="$(jq -cn --arg ref "${ref}" --argjson review "${review}" '{ok:false, status:"blocked", ref:$ref, review:$review}')"
        linux_agent_log_event "script_blocked" "${result}"
        if linux_agent_output_json_enabled; then
            linux_agent_print_execution_protocol_json "Skill 输出" "${result}"
        else
            linux_agent_print_script_result "${result}"
        fi
        linux_agent_log_event "finished" "$(jq -cn '{status:"blocked"}')"
        return 0
    fi

    if ! linux_agent_confirm_execution "批准执行该 skill 脚本？"; then
        result="$(jq -cn --arg ref "${ref}" '{ok:false, status:"rejected", ref:$ref}')"
        linux_agent_log_event "script_rejected" "${result}"
        if linux_agent_output_json_enabled; then
            linux_agent_print_execution_protocol_json "Skill 输出" "${result}"
        else
            linux_agent_print_script_result "${result}"
        fi
        linux_agent_log_event "finished" "$(jq -cn '{status:"rejected"}')"
        return 0
    fi

    local script_path subject
    script_path="$(linux_agent_skill_script_path "${ref}")"
    subject="$(jq -cn --arg ref "${ref}" --argjson arguments "${arguments_json}" '{kind:"script_command", ref:$ref, arguments:$arguments}')"
    result="$(
        LINUX_AGENT_EXECUTION_PRIVILEGE="$(linux_agent_execution_privilege_from_review "${review}")" \
            linux_agent_execute_observed_command_output "script" "${subject}" -- bash "${script_path}" "${arguments_json}"
    )"
    linux_agent_log_event "script_executed" "${result}"
    if linux_agent_output_json_enabled; then
        linux_agent_print_execution_protocol_json "Skill 输出" "${result}"
    else
        linux_agent_print_script_result "${result}"
    fi

    if [[ "$(jq -r '.ok // false' <<<"${result}")" == "true" ]]; then
        final_status="executed"
    else
        final_status="failed"
    fi
    linux_agent_log_event "finished" "$(jq -cn --arg status "${final_status}" '{status:$status}')"
}

linux_agent_process_terminal_request() {
    local command_text="$1"
    local approve="${2:-false}"
    local stdout_file stderr_file stdout_text stderr_text exit_code final_status result run_meta observer subject
    local review proxy_meta proxy_error
    local -a command_args prepared_command

    linux_agent_log_event "received" "$(jq -cn --arg command "${command_text}" '{mode:"terminal", command:$command}')"
    review="$(linux_agent_terminal_review "${command_text}")"
    linux_agent_log_event "terminal_policy_checked" "${review}"

    if [[ "$(jq -r '.approved' <<<"${review}")" != "true" ]]; then
        result="$(jq -cn --arg command "${command_text}" --argjson review "${review}" \
            '{ok:false, status:"blocked", command:$command, review:$review}')"
        linux_agent_log_event "terminal_blocked" "${result}"
        if linux_agent_output_json_enabled; then
            linux_agent_print_execution_protocol_json "终端输出" "${result}"
        else
            linux_agent_print_terminal_result "$(jq -c '. + {exit_code:126, stdout:"", stderr:(.review.findings | tostring)}' <<<"${result}")"
        fi
        linux_agent_log_event "finished" "$(jq -cn '{status:"blocked"}')"
        return 0
    fi

    if [[ "$(jq -r '.approval_required' <<<"${review}")" == "true" && "${approve}" != "true" ]]; then
        printf '终端命令审查风险: %s，发现项: %s\n' "$(jq -r '.risk_level' <<<"${review}")" "$(jq '.findings | length' <<<"${review}")" >&2
        if [[ "${LINUX_AGENT_API_MODE:-0}" == "1" ]]; then
            result="$(jq -cn --arg command "${command_text}" --argjson review "${review}" \
                '{ok:false, status:"approval_required", command:$command, review:$review}')"
            linux_agent_log_event "terminal_approval_required" "${result}"
            printf '%s\n' "$(jq . <<<"${result}")"
            linux_agent_log_event "finished" "$(jq -cn '{status:"approval_required"}')"
            return 0
        fi
        if ! linux_agent_confirm_execution "批准执行该终端命令？"; then
            result="$(jq -cn --arg command "${command_text}" --argjson review "${review}" \
                '{ok:false, status:"rejected", command:$command, review:$review}')"
            linux_agent_log_event "terminal_rejected" "${result}"
            if linux_agent_output_json_enabled; then
                linux_agent_print_execution_protocol_json "终端输出" "${result}"
            else
                linux_agent_print_terminal_result "$(jq -c '. + {exit_code:null, stdout:"", stderr:"用户拒绝执行。"}' <<<"${result}")"
            fi
            linux_agent_log_event "finished" "$(jq -cn '{status:"rejected"}')"
            return 0
        fi
    fi

    stdout_file="$(mktemp "${LINUX_AGENT_TMP_DIR}/terminal.stdout.XXXXXX")"
    stderr_file="$(mktemp "${LINUX_AGENT_TMP_DIR}/terminal.stderr.XXXXXX")"

    subject="$(jq -cn --arg command "${command_text}" '{kind:"terminal_command", command:$command}')"
    command_args=(bash -lc "${command_text}")
    if ! linux_agent_prepare_execution_command "$(linux_agent_execution_privilege_from_review "${review}")" prepared_command "${command_args[@]}"; then
        proxy_error="least privilege proxy is unavailable; refusing to run as root without an explicit privileged path"
        proxy_meta="$(linux_agent_execution_proxy_metadata "$(linux_agent_execution_privilege_from_review "${review}")" "false" "${proxy_error}")"
        result="$(jq -cn \
            --arg command "${command_text}" \
            --arg status "failed" \
            --arg stderr_text "${proxy_error}" \
            --argjson proxy "${proxy_meta}" \
            '{ok:false, status:$status, command:$command, exit_code:126, stdout:"", stderr:$stderr_text, execution_proxy:$proxy}')"
        linux_agent_log_event "terminal_executed" "${result}"
        if linux_agent_output_json_enabled; then
            linux_agent_print_execution_protocol_json "终端输出" "${result}"
        else
            linux_agent_print_terminal_result "${result}"
        fi
        linux_agent_log_event "finished" "$(jq -cn '{status:"failed"}')"
        rm -f "${stdout_file}" "${stderr_file}"
        return 0
    fi
    if [[ "$(linux_agent_execution_privilege_from_review "${review}")" == "least" && "$(id -u)" -eq 0 ]]; then
        proxy_meta="$(linux_agent_execution_proxy_metadata "least" "true")"
    else
        proxy_meta="$(linux_agent_execution_proxy_metadata "$(linux_agent_execution_privilege_from_review "${review}")" "false")"
    fi
    run_meta="$(linux_agent_run_observed_process "terminal" "${subject}" "${stdout_file}" "${stderr_file}" -- "${prepared_command[@]}")"
    exit_code="$(jq -r '.exit_code' <<<"${run_meta}")"
    observer="$(jq -c '.observer' <<<"${run_meta}")"

    stdout_text="$(head -c 4000 "${stdout_file}" || true)"
    stderr_text="$(head -c 4000 "${stderr_file}" || true)"
    if [[ "${exit_code}" -eq 0 ]]; then
        final_status="executed"
    else
        final_status="failed"
    fi

    result="$(jq -cn \
        --arg command "${command_text}" \
        --arg stdout_text "${stdout_text}" \
        --arg stderr_text "${stderr_text}" \
        --arg status "${final_status}" \
        --argjson exit_code "${exit_code}" \
        --argjson observer "${observer}" \
        --argjson review "${review}" \
        --argjson proxy "${proxy_meta}" \
        '{ok:($exit_code == 0), status:$status, command:$command, exit_code:$exit_code, stdout:$stdout_text, stderr:$stderr_text, review:$review, observer:$observer, execution_proxy:$proxy}')"

    linux_agent_log_event "terminal_executed" "${result}"
    if linux_agent_output_json_enabled; then
        linux_agent_print_execution_protocol_json "终端输出" "${result}"
    else
        linux_agent_print_terminal_result "${result}"
    fi
    linux_agent_log_event "finished" "$(jq -cn --arg status "${final_status}" '{status:$status}')"

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
        work|interactive|oneshot|*)
            linux_agent_process_work_request "${user_input}" "${mode}"
            ;;
    esac
}
