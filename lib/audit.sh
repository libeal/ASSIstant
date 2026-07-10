#!/usr/bin/env bash

set -euo pipefail

LINUX_AGENT_SESSION_ID="${LINUX_AGENT_SESSION_ID:-}"
LINUX_AGENT_AUDIT_LOG="${LINUX_AGENT_AUDIT_LOG:-}"
LINUX_AGENT_SESSION_ACTIVE=0
LINUX_AGENT_SESSION_FINISHED=0
LINUX_AGENT_LAST_BUSINESS_STATUS=""

linux_agent_audit_boundaries_path() {
    printf '%s/policies/audit-boundaries.json\n' "${LINUX_AGENT_ROOT}"
}

linux_agent_audit_boundary_default_config() {
    cat <<'JSON'
{
  "observing": {
    "audit_payload_mode": "safe_summary",
    "audit_text_limit": 1000,
    "application_events": [
      "session_started",
      "session_finished",
      "command_started",
      "command_finished",
      "turn_started",
      "turn_finished",
      "control_event",
      "received",
      "sensed",
      "request_context_built",
      "ai_failed",
      "ai_invalid_response",
      "planned",
      "finished",
      "executed",
      "agent_loop_*",
      "agent_reflection_*",
      "agent_checkpoint_*",
      "work_revision_requested",
      "revision_planned",
      "repair_*",
      "step_*",
      "script_*",
      "script_manual_edit",
      "terminal_executed",
      "edit_*",
      "ai_files_manifest",
      "execution_started",
      "execution_finished",
      "observer_*"
    ],
    "observer_syscalls": [
      "execve",
      "execveat",
      "open",
      "openat",
      "creat",
      "truncate",
      "ftruncate",
      "rename",
      "renameat",
      "unlink",
      "unlinkat",
      "chmod",
      "fchmod",
      "chown",
      "fchown",
      "mkdir",
      "rmdir"
    ],
    "observer_result_fields": [
      "exec_count",
      "file_event_count",
      "processes",
      "file_events"
    ],
    "observer_max_events": 200
  },
  "allowed_to_observe": {
    "audit_payload_modes": [
      "safe_summary",
      "redacted_verbose"
    ],
    "audit_text_limit": {
      "min": 1,
      "max": 100000
    },
    "application_events": [
      "session_started",
      "session_finished",
      "command_started",
      "command_finished",
      "turn_started",
      "turn_finished",
      "control_event",
      "received",
      "sensed",
      "request_context_built",
      "ai_failed",
      "ai_invalid_response",
      "planned",
      "finished",
      "executed",
      "agent_loop_*",
      "agent_reflection_*",
      "agent_checkpoint_*",
      "work_revision_requested",
      "revision_planned",
      "repair_*",
      "step_*",
      "script_*",
      "terminal_executed",
      "edit_*",
      "script_manual_edit",
      "ai_files_manifest",
      "execution_started",
      "execution_finished",
      "observer_*"
    ],
    "observer_syscalls": [
      "execve",
      "execveat",
      "open",
      "openat",
      "openat2",
      "creat",
      "truncate",
      "ftruncate",
      "rename",
      "renameat",
      "renameat2",
      "unlink",
      "unlinkat",
      "chmod",
      "fchmod",
      "fchmodat",
      "chown",
      "fchown",
      "fchownat",
      "mkdir",
      "mkdirat",
      "rmdir",
      "symlink",
      "symlinkat",
      "link",
      "linkat"
    ],
    "observer_result_fields": [
      "exec_count",
      "file_event_count",
      "processes",
      "file_events"
    ],
    "observer_max_events": {
      "min": 1,
      "max": 1000
    }
  }
}
JSON
}

linux_agent_audit_boundary_config() {
    local path
    path="$(linux_agent_audit_boundaries_path)"
    if [[ -f "${path}" ]] && jq -e 'type == "object"' "${path}" >/dev/null 2>&1; then
        jq -c . "${path}"
        return 0
    fi
    linux_agent_audit_boundary_default_config | jq -c .
}

linux_agent_audit_boundary_values() {
    local jq_path="$1"
    linux_agent_audit_boundary_config | jq -r "${jq_path}[]? | strings" 2>/dev/null || true
}

linux_agent_audit_boundary_pattern_matches() {
    local pattern="$1"
    local value="$2"
    local prefix
    if [[ "${pattern}" == "all" ]]; then
        return 0
    fi
    if [[ "${pattern}" == *"*" ]]; then
        prefix="${pattern%\*}"
        [[ "${value}" == "${prefix}"* ]]
        return $?
    fi
    [[ "${value}" == "${pattern}" ]]
}

linux_agent_audit_boundary_entry_allowed() {
    local entry="$1"
    local allowed_path="$2"
    local allowed
    while IFS= read -r allowed; do
        [[ -z "${allowed}" ]] && continue
        if [[ "${entry}" == *"*" ]]; then
            if [[ "${allowed}" == "all" || "${allowed}" == "${entry}" ]]; then
                return 0
            fi
        elif linux_agent_audit_boundary_pattern_matches "${allowed}" "${entry}"; then
            return 0
        fi
    done < <(linux_agent_audit_boundary_values "${allowed_path}")
    return 1
}

linux_agent_audit_boundary_selected_patterns() {
    local selected_path="$1"
    local allowed_path="$2"
    local entry
    while IFS= read -r entry; do
        [[ -z "${entry}" ]] && continue
        if linux_agent_audit_boundary_entry_allowed "${entry}" "${allowed_path}"; then
            printf '%s\n' "${entry}"
        fi
    done < <(linux_agent_audit_boundary_values "${selected_path}")
}

linux_agent_audit_boundary_selected_exact_values() {
    local selected_path="$1"
    local allowed_path="$2"
    local entry
    while IFS= read -r entry; do
        [[ -z "${entry}" || "${entry}" == *"*"* ]] && continue
        if linux_agent_audit_boundary_entry_allowed "${entry}" "${allowed_path}"; then
            printf '%s\n' "${entry}"
        fi
    done < <(linux_agent_audit_boundary_values "${selected_path}") | awk '!seen[$0]++'
}

linux_agent_audit_boundary_observes_value() {
    local value="$1"
    local selected_path="$2"
    local allowed_path="$3"
    local entry matched=1
    while IFS= read -r entry; do
        [[ -z "${entry}" ]] && continue
        if linux_agent_audit_boundary_pattern_matches "${entry}" "${value}"; then
            matched=0
        fi
    done < <(linux_agent_audit_boundary_selected_patterns "${selected_path}" "${allowed_path}")
    return "${matched}"
}

linux_agent_audit_boundary_should_log_stage() {
    local stage="$1"
    linux_agent_audit_boundary_observes_value \
        "${stage}" \
        '.observing.application_events' \
        '.allowed_to_observe.application_events'
}

linux_agent_audit_boundary_payload_mode() {
    local fallback="${1:-safe_summary}"
    local mode
    mode="$(linux_agent_audit_boundary_config | jq -r '.observing.audit_payload_mode // empty' 2>/dev/null || true)"
    if [[ -n "${mode}" ]] && linux_agent_audit_boundary_entry_allowed "${mode}" '.allowed_to_observe.audit_payload_modes'; then
        printf '%s\n' "${mode}"
        return 0
    fi
    printf '%s\n' "${fallback}"
}

linux_agent_audit_boundary_number() {
    local value_path="$1"
    local min_path="$2"
    local max_path="$3"
    local fallback="$4"
    local config value min max
    config="$(linux_agent_audit_boundary_config)"
    value="$(jq -r "${value_path} // empty" <<<"${config}" 2>/dev/null || true)"
    min="$(jq -r "${min_path} // 1" <<<"${config}" 2>/dev/null || true)"
    max="$(jq -r "${max_path} // empty" <<<"${config}" 2>/dev/null || true)"

    if [[ ! "${value}" =~ ^[0-9]+$ || "${value}" -le 0 ]]; then
        value="${fallback}"
    fi
    if [[ "${min}" =~ ^[0-9]+$ && "${value}" -lt "${min}" ]]; then
        value="${min}"
    fi
    if [[ "${max}" =~ ^[0-9]+$ && "${max}" -gt 0 && "${value}" -gt "${max}" ]]; then
        value="${max}"
    fi
    printf '%s\n' "${value}"
}

linux_agent_audit_boundary_text_limit() {
    linux_agent_audit_boundary_number \
        '.observing.audit_text_limit' \
        '.allowed_to_observe.audit_text_limit.min' \
        '.allowed_to_observe.audit_text_limit.max' \
        "${1:-1000}"
}

linux_agent_audit_boundary_observer_max_events() {
    linux_agent_audit_boundary_number \
        '.observing.observer_max_events' \
        '.allowed_to_observe.observer_max_events.min' \
        '.allowed_to_observe.observer_max_events.max' \
        "${1:-200}"
}

linux_agent_audit_boundary_observer_syscalls() {
    linux_agent_audit_boundary_selected_exact_values \
        '.observing.observer_syscalls' \
        '.allowed_to_observe.observer_syscalls'
}

linux_agent_audit_boundary_observer_field_enabled() {
    local field="$1"
    linux_agent_audit_boundary_observes_value \
        "${field}" \
        '.observing.observer_result_fields' \
        '.allowed_to_observe.observer_result_fields'
}

linux_agent_audit_boundary_runtime_summary() {
    local events syscalls fields payload_mode text_limit max_events
    events="$(linux_agent_audit_boundary_selected_patterns '.observing.application_events' '.allowed_to_observe.application_events' | jq -R -s 'split("\n") | map(select(length > 0))')"
    syscalls="$(linux_agent_audit_boundary_observer_syscalls | jq -R -s 'split("\n") | map(select(length > 0))')"
    fields="$(linux_agent_audit_boundary_selected_exact_values '.observing.observer_result_fields' '.allowed_to_observe.observer_result_fields' | jq -R -s 'split("\n") | map(select(length > 0))')"
    payload_mode="$(linux_agent_audit_boundary_payload_mode "$(linux_agent_audit_mode)")"
    text_limit="$(linux_agent_audit_boundary_text_limit "$(linux_agent_audit_text_limit)")"
    max_events="$(linux_agent_audit_boundary_observer_max_events "$(linux_agent_observer_max_events 2>/dev/null || printf '200')")"
    jq -cn \
        --arg payload_mode "${payload_mode}" \
        --argjson text_limit "${text_limit}" \
        --argjson application_events "${events}" \
        --argjson observer_syscalls "${syscalls}" \
        --argjson observer_result_fields "${fields}" \
        --argjson observer_max_events "${max_events}" \
        '{audit_payload_mode:$payload_mode, audit_text_limit:$text_limit, application_events:$application_events, observer_syscalls:$observer_syscalls, observer_result_fields:$observer_result_fields, observer_max_events:$observer_max_events}'
}

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
                mcp_server:($s.mcp_server // null),
                mcp_tool:($s.mcp_tool // null),
                risk_level:($s.risk_level // null),
                has_command:($s | has("command")),
                command_preview:(.command // "" | preview),
                argument_keys:(if (.arguments? | type) == "object" then (.arguments | keys) else null end),
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
                output_preview:(
                    if ($r.output.raw? | type) == "string" then ($r.output.raw | preview)
                    elif ($r.stdout? | type) == "string" then ($r.stdout | preview)
                    elif ($r.output.summary? | type) == "string" then ($r.output.summary | preview)
                    elif ($r.output.message? | type) == "string" then ($r.output.message | preview)
                    elif ($r.output.error? | type) == "string" then ($r.output.error | preview)
                    elif ($r.output.action? | type) == "string" then ($r.output.action | preview)
                    else null end
                ),
                stderr_preview:(if ($r.stderr? | type) == "string" then ($r.stderr | preview) else null end),
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
        elif ($stage == "planned" or $stage == "repair_planned" or $stage == "revision_planned" or $stage == "agent_reflection_planned") then
            {
                response_type:(.response_type // null),
                summary_preview:(.summary // "" | preview),
                continue_decision:(.continue_decision // null),
                step_count:(if (.steps? | type) == "array" then (.steps | length) else 0 end),
                steps:[.steps[]? | step_summary(.)]
            }
        elif $stage == "agent_reflection_requested" then
            {
                iteration:(.iteration // null),
                execution_status:(.execution_status // null),
                result_count:(.result_count // null)
            }
        elif ($stage == "agent_loop_started" or $stage == "agent_loop_iteration_started" or $stage == "agent_checkpoint_requested" or $stage == "agent_checkpoint_decision" or $stage == "agent_loop_finished") then
            {
                mode:(.mode // null),
                iteration:(.iteration // null),
                iterations:(.iterations // null),
                checkpoint_turns:(.checkpoint_turns // null),
                approved:(.approved // null),
                status:(.status // null),
                stopped_reason:(.stopped_reason // null),
                auto_executed_count:(.auto_executed_count // null),
                plan_step_count:(if (.plan.steps? | type) == "array" then (.plan.steps | length) else null end)
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
        elif ($stage | startswith("observer_")) then
            {
                status:(.status // null),
                backend:(.backend // "auditd"),
                scope:(.scope // null),
                audit_key:(.audit_key // null),
                uid:(.uid // null),
                audit_uid:(.audit_uid // null),
                identity_filter:(.identity_filter // null),
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
                stdout_present:(has("stdout")),
                stderr_present:(has("stderr"))
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
    local boundary_summary entrypoint

    if [[ "${LINUX_AGENT_SESSION_ACTIVE:-0}" -eq 1 && "${LINUX_AGENT_SESSION_FINISHED:-0}" -eq 0 ]]; then
        return 0
    fi

    if [[ "${LINUX_AGENT_SESSION_MANAGED_EXTERNALLY:-0}" == "1" && -n "${LINUX_AGENT_SESSION_ID:-}" ]]; then
        LINUX_AGENT_AUDIT_LOG="${LINUX_AGENT_AUDIT_LOG:-${LINUX_AGENT_LOG_DIR}/${LINUX_AGENT_SESSION_ID}.jsonl}"
        mkdir -p "$(dirname "${LINUX_AGENT_AUDIT_LOG}")"
        touch "${LINUX_AGENT_AUDIT_LOG}"
        if declare -F linux_agent_use_session_tmp_dir >/dev/null 2>&1; then
            linux_agent_use_session_tmp_dir "${LINUX_AGENT_SESSION_ID}"
        fi
        LINUX_AGENT_SESSION_ACTIVE=1
        LINUX_AGENT_SESSION_FINISHED=0
        if declare -F linux_agent_observer_session_start >/dev/null 2>&1; then
            linux_agent_observer_session_start "session" "$(jq -cn --arg request "${user_input}" '{request:$request}')"
        fi
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
    boundary_summary="$(linux_agent_audit_boundary_runtime_summary)"
    if [[ "${LINUX_AGENT_WEB:-0}" == "1" ]]; then
        entrypoint="web"
    else
        entrypoint="cli"
    fi
    linux_agent_log_event "session_started" "$(jq -cn \
        --arg request "${user_input}" \
        --arg entrypoint "${entrypoint}" \
        --arg audit_mode "$(linux_agent_audit_mode)" \
        --argjson audit_boundary "${boundary_summary}" \
        '{request:$request, entrypoint:$entrypoint, audit_mode:$audit_mode, audit_boundary:$audit_boundary}')"
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
    if ! linux_agent_audit_boundary_should_log_stage "${stage}"; then
        return 0
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
    if [[ "${LINUX_AGENT_SESSION_MANAGED_EXTERNALLY:-0}" == "1" ]]; then
        LINUX_AGENT_SESSION_ACTIVE=0
        return 0
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

    printf '\n# 事件时间线\n\n'
    jq -s -r '
        def stage_label($s):
            if $s == "session_started" then "会话开始"
            elif $s == "session_finished" then "会话结束"
            elif $s == "command_started" then "命令入口开始"
            elif $s == "command_finished" then "命令入口结束"
            elif $s == "received" then "收到请求"
            elif $s == "sensed" then "采集环境"
            elif $s == "request_context_built" then "构建模型上下文"
            elif $s == "planned" then "生成执行计划"
            elif $s == "step_policy_checked" then "策略审查"
            elif $s == "step_auto_approved" then "自动批准步骤"
            elif $s == "step_approval_required" then "等待人工审批"
            elif $s == "step_approved" then "批准步骤"
            elif $s == "step_running" then "开始执行步骤"
            elif $s == "step_succeeded" then "步骤执行成功"
            elif $s == "step_failed" then "步骤执行失败"
            elif $s == "step_blocked" then "步骤被阻断"
            elif $s == "step_rejected" then "步骤被拒绝"
            elif $s == "step_skipped_user" then "用户跳过步骤"
            elif $s == "step_skipped_unexecuted" then "后续步骤未执行"
            elif $s == "executed" then "工作流执行结果"
            elif $s == "terminal_executed" then "终端执行结果"
            elif $s == "script_executed" then "Skill 执行结果"
            elif $s == "finished" then "业务状态完成"
            elif ($s | startswith("observer_")) then "Observer 事件"
            elif ($s | startswith("agent_")) then "Agent 循环"
            else $s end;
        def step_name($p):
            ($p.step.title
             // $p.step.id
             // $p.step.skill_script
             // (if (($p.step.mcp_server // "") != "" and ($p.step.mcp_tool // "") != "") then ($p.step.mcp_server + "/" + $p.step.mcp_tool) else null end)
             // $p.step.command_preview
             // "");
        def result_text($d):
            [
                (if ($d.status // "") != "" then "状态=" + ($d.status | tostring) else empty end),
                (if ($d.exit_code // null) != null then "退出码=" + ($d.exit_code | tostring) else empty end),
                (if ($d.tool // "") != "" then "工具=" + ($d.tool | tostring) else empty end),
                (if ($d.action // "") != "" then "动作=" + ($d.action | tostring) else empty end),
                (if ($d.output_preview // "") != "" then "输出=" + ($d.output_preview | tostring) else empty end),
                (if ($d.stderr_preview // "") != "" then "错误=" + ($d.stderr_preview | tostring) else empty end)
            ] | join("；");
        def describe:
            .stage as $s
            | (.payload // {}) as $p
            | if $s == "session_started" then
                "入口=" + (($p.entrypoint // "cli") | tostring) + "；请求=" + (($p.request // "") | tostring)
              elif $s == "session_finished" or $s == "finished" or $s == "command_finished" then
                "状态=" + (($p.status // "unknown") | tostring)
              elif $s == "command_started" then
                "调用=" + (($p.command // "") | tostring) + "；参数=" + (($p.args_preview // $p.args // "") | tostring)
              elif $s == "received" then
                "模式=" + (($p.mode // "unknown") | tostring) + "；输入=" + (($p.input_preview // $p.command // $p.ref // "") | tostring)
              elif $s == "sensed" then
                "主题=" + (($p.topic // "unknown") | tostring) + "；上下文字段=" + ((($p.context_keys // []) | join(",")) | tostring)
              elif $s == "request_context_built" then
                "模式=" + (($p.mode // "unknown") | tostring) + "；当前请求=" + (($p.current_request_preview // "") | tostring)
              elif $s == "planned" or $s == "revision_planned" or $s == "repair_planned" then
                "摘要=" + (($p.summary_preview // "") | tostring) + "；步骤数=" + (($p.step_count // 0) | tostring)
              elif $s == "step_policy_checked" then
                "步骤=" + (step_name($p) | tostring) + "；风险=" + (($p.review.risk_level // "unknown") | tostring) + "；发现项=" + (($p.review.finding_count // 0) | tostring)
              elif ($s | startswith("step_")) then
                "步骤=" + (step_name($p) | tostring) + "；" + (result_text($p.detail // {}))
              elif $s == "executed" then
                "状态=" + (($p.status // "unknown") | tostring) + "；结果数=" + (($p.result_count // (($p.results // []) | length)) | tostring)
              elif $s == "terminal_executed" or $s == "script_executed" then
                result_text($p)
              elif ($s | startswith("observer_")) then
                "状态=" + (($p.status // "unknown") | tostring) + "；后端=" + (($p.backend // "auditd") | tostring) + "；exec=" + (($p.exec_count // 0) | tostring) + "；file=" + (($p.file_event_count // 0) | tostring)
              else
                ($p.message // $p.status // $p.event // ($p | tostring))
              end;
        .[] | "- " + ((.timestamp // "--") | tostring) + " · " + stage_label(.stage // "event") + "： " + describe
    ' "${log_file}" | while IFS= read -r line; do
        linux_agent_sanitize_text "${line}"
    done

    printf '\n# JSONL 审计流\n\n'
    while IFS= read -r line; do
        linux_agent_sanitize_text "${line}"
    done < "${log_file}"
}
