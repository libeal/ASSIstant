#!/usr/bin/env bash

set -euo pipefail

LINUX_AGENT_SESSION_ID=""
LINUX_AGENT_AUDIT_LOG=""
LINUX_AGENT_SESSION_ACTIVE=0
LINUX_AGENT_SESSION_FINISHED=0
LINUX_AGENT_LAST_BUSINESS_STATUS=""

linux_agent_audit_safe_summary() {
    local stage="$1"
    local payload="$2"
    local limit
    limit="$(linux_agent_audit_text_limit)"

    if ! printf '%s' "${payload}" | jq -e . >/dev/null 2>&1; then
        jq -cn --arg raw "$(linux_agent_sanitize_text "${payload}" "${limit}")" '{raw_preview:$raw}'
        return 0
    fi

    jq -c --arg stage "${stage}" --argjson limit "${limit}" '
        def preview:
            if type == "string" then
                if length > $limit then .[0:$limit] + "[TRUNCATED]" else . end
            else . end;
        def step_summary($s):
            if ($s | type) == "object" then {
                id:($s.id // null),
                title:($s.title // null),
                executor_type:($s.executor_type // null),
                skill_script:($s.skill_script // null),
                risk_level:($s.risk_level // null),
                has_command:($s | has("command")),
                url:($s.url // $s.command // null | if type == "string" and test("^https://") then . else null end),
                sha256:($s.sha256 // null),
                size_bytes:($s.size_bytes // null),
                line_count:($s.line_count // null)
            } else null end;
        def result_summary($r):
            if ($r | type) == "object" then {
                ok:($r.ok // null),
                status:($r.status // null),
                exit_code:($r.exit_code // null),
                tool:($r.output.tool // $r.tool // null),
                action:($r.output.action // $r.action // null),
                result_count:(if ($r.results? | type) == "array" then ($r.results | length) else null end),
                output_keys:(if ($r.output? | type) == "object" then ($r.output | keys) else null end),
                finding_count:(if ($r.findings? | type) == "array" then ($r.findings | length) else null end)
            } else null end;
        def fallback:
            if type == "object" then
                with_entries(
                    if (.value | type) == "string" then .value |= preview
                    elif (.value | type) == "array" then .value = {type:"array", length:(.value | length)}
                    elif (.value | type) == "object" then .value = {type:"object", keys:(.value | keys)}
                    else . end
                )
            else
                {value:(. | tostring | preview)}
            end;

        if ($stage == "command_started" or $stage == "command_finished") then
            {
                command:(.command // null),
                args_preview:(.args // "" | preview),
                status:(.status // null),
                exit_code:(.exit_code // null)
            }
        elif ($stage == "turn_started" or $stage == "turn_finished") then
            {
                mode:(.mode // null),
                input_preview:(.input // "" | preview),
                status:(.status // null)
            }
        elif $stage == "control_event" then
            {
                event:(.event // null),
                mode:(.mode // null),
                value_preview:(.value // "" | preview),
                status:(.status // null)
            }
        elif $stage == "ai_files_manifest" then
            {
                file_count:(.file_count // ((.files // []) | length)),
                files:[(.files // [])[] | {
                    relative_path:(.relative_path // null),
                    path:(.path // null),
                    purpose:(.purpose // null),
                    included_as:(.included_as // null),
                    exists:(.exists // null),
                    readable:(.readable // null),
                    size_bytes:(.size_bytes // null),
                    sha256:(.sha256 // null)
                }]
            }
        elif $stage == "received" then
            {
                mode:(.mode // null),
                input_preview:(.input // .command // .ref // "" | preview),
                ref:(.ref // null),
                argument_keys:(if (.arguments? | type) == "object" then (.arguments | keys) else null end)
            }
        elif $stage == "sensed" then
            {
                topic:(.topic // null),
                context_keys:(if type == "object" then keys else [] end)
            }
        elif $stage == "request_context_built" then
            {
                mode:(.mode // null),
                current_request_preview:(.current_request // "" | preview),
                conversation_turns:(if (.conversation_context? | type) == "array" then (.conversation_context | length) else 0 end),
                environment_keys:(if (.environment_context? | type) == "object" then (.environment_context | keys) else [] end),
                skill_index_chars:(.skill_index // "" | length),
                fixed_context_excluded:(has("skill_index") | not),
                runtime_context_excluded:(has("environment_context") | not)
            }
        elif ($stage == "planned" or $stage == "repair_planned" or $stage == "revision_planned") then
            {
                response_type:(.response_type // null),
                summary_preview:(.summary // "" | preview),
                step_count:(if (.steps? | type) == "array" then (.steps | length) else 0 end),
                steps:[.steps[]? | step_summary(.)]
            }
        elif $stage == "work_revision_requested" then
            {
                original_request_preview:(.original_request // "" | preview),
                revision_request_preview:(.revision_request // "" | preview),
                original_step_count:(if (.plan.steps? | type) == "array" then (.plan.steps | length) else 0 end),
                executed_count:(if (.executed_steps? | type) == "array" then (.executed_steps | length) else 0 end),
                skipped_step:step_summary(.skipped_step),
                remaining_step_count:(if (.remaining_steps? | type) == "array" then (.remaining_steps | length) else 0 end)
            }
        elif $stage == "edit_planned" then
            {
                response_type:(.response_type // null),
                skill:(.skill.name // null),
                script_count:(if (.scripts? | type) == "array" then (.scripts | length) else 0 end),
                notes_preview:(.notes // "" | preview)
            }
        elif $stage == "edit_revision_requested" then
            {
                skill:(.original_edit.skill.name // null),
                cancelled_script:(.cancelled_script // null),
                revision_request_preview:(.revision_request // "" | preview),
                script_count:(if (.original_edit.scripts? | type) == "array" then (.original_edit.scripts | length) else 0 end)
            }
        elif $stage == "script_manual_edit" then
            {
                skill:(.skill // null),
                script:(.script // null),
                diff_lines:(if (.diff? | type) == "string" then (.diff | split("\n") | length) else 0 end)
            }
        elif $stage == "step_revision_requested" then
            {
                status:(.status // "revision_requested"),
                step:step_summary(.step),
                revision_request_preview:(.detail.revision_request // "" | preview),
                remaining_step_count:(.detail.remaining_step_count // null)
            }
        elif ($stage | startswith("step_")) then
            {
                status:(.status // ($stage | sub("^step_"; ""))),
                step:step_summary(.step),
                detail:result_summary(.detail),
                findings:(.detail.findings // [])
            }
        elif $stage == "step_policy_checked" then
            {
                step:step_summary(.step),
                review:{
                    approved:(.review.approved // null),
                    approval_required:(.review.approval_required // null),
                    risk_level:(.review.risk_level // null),
                    finding_count:(if (.review.findings? | type) == "array" then (.review.findings | length) else 0 end)
                }
            }
        elif ($stage | startswith("observer_")) then
            {
                status:(.status // null),
                backend:(.backend // "auditd"),
                scope:(.scope // null),
                audit_key:(.audit_key // null),
                root_pid:(.root_pid // null),
                start_time:(.start_time // null),
                end_time:(.end_time // null),
                exec_count:(.exec_count // null),
                file_event_count:(.file_event_count // null),
                process_count:(if (.processes? | type) == "array" then (.processes | length) else 0 end),
                file_event_sample_count:(if (.file_events? | type) == "array" then (.file_events | length) else 0 end),
                sudo_available:(.sudo_available // null),
                sudo_authenticated:(.sudo_authenticated // null),
                sudo_exit_code:(.sudo_exit_code // null),
                auditctl_exit_code:(.auditctl_exit_code // null),
                reason_code:(.reason_code // null),
                reason:(.reason // null),
                diagnostic:(.diagnostic // null),
                notes:(.notes // [])
            }
        elif ($stage == "executed" or $stage == "script_executed" or $stage == "terminal_executed" or $stage == "edit_applied") then
            result_summary(.)
            + {
                results:[.results[]? | {step:step_summary(.step), result:result_summary(.result)}],
                command_present:(has("command")),
                stdout_present:(has("stdout_preview")),
                stderr_present:(has("stderr_preview"))
            }
        else
            fallback
        end
    ' <<<"${payload}"
}

linux_agent_audit_payload() {
    local stage="$1"
    local payload="$2"
    local sanitized

    sanitized="$(linux_agent_sanitize_json "${payload}")"
    if [[ "$(linux_agent_audit_mode)" == "redacted_verbose" ]]; then
        if printf '%s' "${sanitized}" | jq -e . >/dev/null 2>&1; then
            printf '%s\n' "${sanitized}"
        else
            jq -cn --arg raw "${sanitized}" '{raw_preview:$raw}'
        fi
    else
        linux_agent_audit_safe_summary "${stage}" "${sanitized}"
    fi
}

linux_agent_start_session() {
    local user_input="$1"

    if [[ "${LINUX_AGENT_SESSION_ACTIVE:-0}" -eq 1 && "${LINUX_AGENT_SESSION_FINISHED:-0}" -eq 0 ]]; then
        return 0
    fi

    LINUX_AGENT_SESSION_ID="$(linux_agent_new_session_id)"
    if declare -F linux_agent_use_session_tmp_dir >/dev/null 2>&1; then
        linux_agent_use_session_tmp_dir "${LINUX_AGENT_SESSION_ID}"
    fi
    LINUX_AGENT_AUDIT_LOG="${LINUX_AGENT_LOG_DIR}/${LINUX_AGENT_SESSION_ID}.jsonl"
    LINUX_AGENT_SESSION_ACTIVE=1
    LINUX_AGENT_SESSION_FINISHED=0

    : > "${LINUX_AGENT_AUDIT_LOG}"
    linux_agent_log_event "session_started" "$(jq -cn --arg request "${user_input}" --arg audit_mode "$(linux_agent_audit_mode)" '{request:$request, audit_mode:$audit_mode}')"
    if declare -F linux_agent_observer_session_start >/dev/null 2>&1; then
        linux_agent_observer_session_start "session" "$(jq -cn --arg request "${user_input}" '{request:$request}')"
    fi
}

linux_agent_log_event() {
    local stage="$1"
    local payload="${2:-}"
    local safe_payload
    [[ -n "${LINUX_AGENT_AUDIT_LOG:-}" ]] || return 0
    [[ -z "${payload}" ]] && payload='{}'
    if [[ "${stage}" == "finished" ]] && printf '%s' "${payload}" | jq -e . >/dev/null 2>&1; then
        LINUX_AGENT_LAST_BUSINESS_STATUS="$(jq -r '.status // empty' <<<"${payload}")"
    fi
    safe_payload="$(linux_agent_audit_payload "${stage}" "${payload}")"
    jq -cn \
        --arg ts "$(linux_agent_now_iso)" \
        --arg session_id "${LINUX_AGENT_SESSION_ID}" \
        --arg stage "${stage}" \
        --argjson payload "${safe_payload}" \
        '{timestamp:$ts, session_id:$session_id, stage:$stage, payload:$payload}' >> "${LINUX_AGENT_AUDIT_LOG}"
}

linux_agent_log_step_status() {
    local step_json="$1"
    local status="$2"
    local detail="${3:-}"
    [[ -z "${detail}" ]] && detail='{}'

    local event_payload
    event_payload="$(jq -cn \
        --arg status "${status}" \
        --argjson step "${step_json}" \
        --argjson detail "${detail}" \
        '{status:$status, step:$step, detail:$detail}')"
    linux_agent_log_event "step_${status}" "${event_payload}"
}

linux_agent_finish_session() {
    local final_status="$1"
    if [[ "${LINUX_AGENT_SESSION_ACTIVE:-0}" -ne 1 || "${LINUX_AGENT_SESSION_FINISHED:-0}" -eq 1 ]]; then
        return 0
    fi
    LINUX_AGENT_SESSION_FINISHED=1
    if declare -F linux_agent_log_ai_files_manifest >/dev/null 2>&1; then
        linux_agent_log_ai_files_manifest
    fi
    if declare -F linux_agent_observer_session_finish >/dev/null 2>&1; then
        linux_agent_observer_session_finish "${final_status}"
    fi
    linux_agent_log_event "session_finished" "$(jq -cn --arg status "${final_status}" '{status:$status}')"
    LINUX_AGENT_SESSION_ACTIVE=0
}

linux_agent_log_command_started() {
    local command="$1"
    local args="${2:-}"
    linux_agent_log_event "command_started" "$(jq -cn --arg command "${command}" --arg args "${args}" '{command:$command, args:$args}')"
}

linux_agent_log_command_finished() {
    local command="$1"
    local status="$2"
    local exit_code="${3:-0}"
    linux_agent_log_event "command_finished" "$(jq -cn --arg command "${command}" --arg status "${status}" --argjson exit_code "${exit_code}" '{command:$command, status:$status, exit_code:$exit_code}')"
}

linux_agent_log_turn_started() {
    local mode="$1"
    local input="$2"
    linux_agent_log_event "turn_started" "$(jq -cn --arg mode "${mode}" --arg input "${input}" '{mode:$mode, input:$input}')"
}

linux_agent_log_turn_finished() {
    local mode="$1"
    local status="$2"
    linux_agent_log_event "turn_finished" "$(jq -cn --arg mode "${mode}" --arg status "${status}" '{mode:$mode, status:$status}')"
}

linux_agent_log_control_event() {
    local event="$1"
    local mode="${2:-}"
    local value="${3:-}"
    local status="${4:-}"
    linux_agent_log_event "control_event" "$(jq -cn --arg event "${event}" --arg mode "${mode}" --arg value "${value}" --arg status "${status}" '{event:$event, mode:$mode, value:$value, status:$status}')"
}

linux_agent_show_audit() {
    local session_id="$1"
    local log_file="${LINUX_AGENT_LOG_DIR}/${session_id}.jsonl"
    local report

    if [[ ! -f "${log_file}" ]]; then
        linux_agent_print_error "未找到审计日志: ${session_id}"
        return 1
    fi

    report="$(jq -s -r '
        def count_stage($s): map(select(.stage == $s)) | length;
        . as $events
        | ($events | map(select(.stage == "session_started")) | first) as $started
        | ($events | map(select(.stage == "session_finished")) | last) as $finished
        | ($events | map(select(.stage == "observer_session_finished")) | last) as $observer
        | "- 会话 ID: " + (($started.session_id // $finished.session_id // "unknown") | tostring),
          "- 开始时间: " + (($started.timestamp // "unknown") | tostring),
          "- 最终状态: " + (($finished.payload.status // $observer.payload.final_status // "unknown") | tostring),
          "- Observer 状态: " + (($observer.payload.status // "unknown") | tostring),
          "- Observer backend: " + (($observer.payload.backend // "auditd") | tostring),
          "- audit_key: " + (($observer.payload.audit_key // "null") | tostring),
          "- Observer reason_code: " + (($observer.payload.reason_code // "null") | tostring),
          "- Observer diagnostic: " + (($observer.payload.diagnostic // "null") | tostring),
          "- exec_count: " + (($observer.payload.exec_count // 0) | tostring),
          "- file_event_count: " + (($observer.payload.file_event_count // 0) | tostring),
          "- execution_finished: " + (($events | count_stage("execution_finished")) | tostring),
          "- observer_unavailable: " + (($events | count_stage("observer_unavailable")) | tostring),
          "- observer_failed: " + (($events | count_stage("observer_failed")) | tostring)
    ' "${log_file}")"
    printf '# 审计报告\n\n'
    linux_agent_sanitize_text "${report}"

    printf '\n# JSONL 审计流\n\n'
    while IFS= read -r line; do
        linux_agent_sanitize_text "${line}"
    done < "${log_file}"
}
