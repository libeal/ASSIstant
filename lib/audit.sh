#!/usr/bin/env bash

set -euo pipefail

LINUX_AGENT_SESSION_ID=""
LINUX_AGENT_AUDIT_LOG=""
LINUX_AGENT_SESSION_MD=""

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

        if $stage == "received" then
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
                skill_index_chars:(.skill_index // "" | length)
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
    local request_summary

    LINUX_AGENT_SESSION_ID="$(linux_agent_new_session_id)"
    LINUX_AGENT_AUDIT_LOG="${LINUX_AGENT_LOG_DIR}/${LINUX_AGENT_SESSION_ID}.jsonl"
    LINUX_AGENT_SESSION_MD="${LINUX_AGENT_SESSION_DIR}/${LINUX_AGENT_SESSION_ID}.md"
    request_summary="$(linux_agent_sanitize_text "${user_input}")"

    : > "${LINUX_AGENT_AUDIT_LOG}"
    cat > "${LINUX_AGENT_SESSION_MD}" <<EOF
# Linux 运维 Agent 会话

- 会话 ID: ${LINUX_AGENT_SESSION_ID}
- 开始时间: $(linux_agent_now_iso)
- 请求摘要: ${request_summary}
- 审计模式: $(linux_agent_audit_mode)

## 事件摘要

EOF
}

linux_agent_log_event() {
    local stage="$1"
    local payload="${2:-}"
    local safe_payload
    [[ -z "${payload}" ]] && payload='{}'
    safe_payload="$(linux_agent_audit_payload "${stage}" "${payload}")"
    jq -cn \
        --arg ts "$(linux_agent_now_iso)" \
        --arg session_id "${LINUX_AGENT_SESSION_ID}" \
        --arg stage "${stage}" \
        --argjson payload "${safe_payload}" \
        '{timestamp:$ts, session_id:$session_id, stage:$stage, payload:$payload}' >> "${LINUX_AGENT_AUDIT_LOG}"
}

linux_agent_append_session_note() {
    local title="$1"
    local body="$2"
    local safe_body stage
    stage="${title}"
    case "${title}" in
        "环境感知（已脱敏）") stage="sensed" ;;
        "模型规划") stage="planned" ;;
        "执行结果") stage="executed" ;;
        "脚本执行结果") stage="script_executed" ;;
        "终端模式执行结果") stage="terminal_executed" ;;
        "失败后的回滚或修复建议") stage="repair_planned" ;;
        "工作计划修改需求") stage="work_revision_requested" ;;
        "修改后的工作计划") stage="revision_planned" ;;
        "Skill 编辑计划") stage="edit_planned" ;;
        "Skill 修改需求") stage="edit_revision_requested" ;;
        "Skill 保存结果") stage="edit_applied" ;;
        Step\ *) stage="step_${title#Step }" ;;
    esac

    if [[ "$(linux_agent_audit_mode)" == "redacted_verbose" ]]; then
        if printf '%s' "${body}" | jq -e . >/dev/null 2>&1; then
            safe_body="$(linux_agent_sanitize_json "${body}")"
        else
            safe_body="$(linux_agent_sanitize_text "${body}")"
        fi
    else
        if printf '%s' "${body}" | jq -e . >/dev/null 2>&1; then
            safe_body="$(linux_agent_audit_safe_summary "${stage}" "$(linux_agent_sanitize_json "${body}")")"
        else
            safe_body="$(jq -cn --arg note "safe_summary 模式已省略自由文本内容。" --arg title "${title}" --arg preview "$(linux_agent_sanitize_text "${body}" 200)" '{title:$title, note:$note, preview:$preview}')"
        fi
    fi
    {
        printf '### %s\n\n' "${title}"
        printf '```\n%s\n```\n\n' "${safe_body}"
    } >> "${LINUX_AGENT_SESSION_MD}"
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

    linux_agent_append_session_note "Step ${status}" "${event_payload}"
}

linux_agent_finish_session() {
    local final_status="$1"
    {
        printf '## 会话结果\n\n'
        printf -- '- 结束时间: %s\n' "$(linux_agent_now_iso)"
        printf -- '- 最终状态: %s\n' "${final_status}"
    } >> "${LINUX_AGENT_SESSION_MD}"
}

linux_agent_show_audit() {
    local session_id="$1"
    local md_file="${LINUX_AGENT_SESSION_DIR}/${session_id}.md"
    local log_file="${LINUX_AGENT_LOG_DIR}/${session_id}.jsonl"

    [[ -f "${md_file}" ]] && linux_agent_sanitize_text "$(cat "${md_file}")"
    if [[ -f "${log_file}" ]]; then
        printf '\n# JSONL 审计流\n\n'
        linux_agent_sanitize_text "$(cat "${log_file}")"
    fi
}
