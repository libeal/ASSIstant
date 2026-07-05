#!/usr/bin/env bash

set -euo pipefail

linux_agent_api_payload() {
    local raw="${1:-}"
    if [[ -z "${raw}" && ! -t 0 ]]; then
        raw="$(cat)"
    fi
    [[ -n "${raw}" ]] || raw='{}'
    if ! jq -e . >/dev/null 2>&1 <<<"${raw}"; then
        jq -cn --arg raw "${raw}" '{ok:false, status:"invalid_json", error:"API payload must be valid JSON.", raw_preview:($raw[0:200])}'
        return 1
    fi
    jq -c . <<<"${raw}"
}

linux_agent_api_error() {
    local status="$1"
    local message="$2"
    jq -cn --arg status "${status}" --arg error "${message}" '{ok:false, status:$status, error:$error}'
}

linux_agent_api_web_config_json() {
    jq -cn \
        --argjson enabled "$(linux_agent_config_bool_default '.web.enabled' 'true')" \
        --arg host "$(linux_agent_config_get_default '.web.host' '127.0.0.1')" \
        --arg port "$(linux_agent_config_get_default '.web.port' '8765')" \
        --arg job_retention_hours "$(linux_agent_config_get_default '.web.job_retention_hours' '24')" \
        --arg token "$(linux_agent_config_get_default '.web.token' '')" \
        '{
            enabled:$enabled,
            host:(if $host == "" then "127.0.0.1" else $host end),
            port:($port | tonumber? // 8765),
            job_retention_hours:($job_retention_hours | tonumber? // 24),
            token_configured:($token != "")
        }'
}

linux_agent_api_health() {
    jq -cn \
        --arg root "${LINUX_AGENT_ROOT}" \
        --arg version "local" \
        --argjson web "$(linux_agent_api_web_config_json)" \
        '{ok:true, status:"ok", app:"linux-agent", version:$version, root:$root, web:$web}'
}

linux_agent_api_tools_list() {
    local index_text scripts line ref description
    index_text="$(linux_agent_skill_index_text 2>/dev/null || true)"
    scripts='[]'
    while IFS= read -r line; do
        ref="$(sed -n 's/^- `\([^`]*\)`: .*/\1/p' <<<"${line}")"
        [[ -n "${ref}" ]] || continue
        description="$(sed -n 's/^- `[^`]*`: \(.*\)$/\1/p' <<<"${line}")"
        ref="${ref%.sh}"
        scripts="$(jq -cn \
            --argjson prior "${scripts}" \
            --arg ref "${ref}" \
            --arg skill "${ref%%/*}" \
            --arg script "${ref#*/}" \
            --arg description "${description}" \
            '$prior + [{ref:$ref, skill:$skill, script:$script, description:$description}]')"
    done <<<"${index_text}"

    jq -cn --arg index_text "${index_text}" --argjson scripts "${scripts}" \
        '{ok:true, status:"listed", index_text:$index_text, scripts:$scripts}'
}

linux_agent_api_audit_list() {
    local payload="$1"
    local limit include_runtime query entries item path session_id size mtime count summary haystack
    limit="$(jq -r '.limit // 50' <<<"${payload}")"
    [[ "${limit}" =~ ^[0-9]+$ && "${limit}" -gt 0 ]] || limit=50
    include_runtime="$(jq -r '.include_runtime // false' <<<"${payload}")"
    query="$(jq -r '.query // .filter // .session_id // empty' <<<"${payload}")"
    entries='[]'
    count=0

    while IFS= read -r item; do
        [[ -n "${item}" ]] || continue
        path="${item#* }"
        session_id="$(basename "${path}" .jsonl)"
        if [[ "${include_runtime}" != "true" && "${session_id}" == web_* ]]; then
            continue
        fi
        size="$(stat -c '%s' "${path}" 2>/dev/null || printf '0')"
        mtime="$(stat -c '%Y' "${path}" 2>/dev/null || printf '0')"
        summary="$(jq -s -c \
            --arg session_id "${session_id}" \
            --arg path "${path}" \
            --argjson size_bytes "${size}" \
            --argjson mtime "${mtime}" '
            def stage: (.stage // .event // .type // .status // "event");
            def payload: (.payload // {});
            def mode_from_event:
                payload as $p
                | if (($p.mode // "") != "") then $p.mode
                  elif (stage | test("terminal")) then "terminal"
                  elif (stage | test("script")) then "script"
                  elif (stage | test("edit")) then "edit"
                  elif (stage | test("step_|planned|executed|agent_loop|agent_reflection|agent_checkpoint|work_revision|revision_")) then "work"
                  else empty end;
            def event_title:
                stage as $s
                | payload as $p
                | if $s == "received" then "收到" + (($p.mode // "请求") | tostring) + "请求"
                  elif $s == "planned" then "生成" + (($p.step_count // 0) | tostring) + "个步骤"
                  elif $s == "step_policy_checked" then "策略审查:" + (($p.step.title // $p.step.id // "步骤") | tostring)
                  elif $s == "step_auto_approved" then "自动批准:" + (($p.step.title // $p.step.id // "步骤") | tostring)
                  elif $s == "step_approval_required" then "等待审批:" + (($p.step.title // $p.step.id // "步骤") | tostring)
                  elif $s == "step_blocked" then "阻断:" + (($p.step.title // $p.step.id // "步骤") | tostring)
                  elif $s == "step_failed" then "失败:" + (($p.step.title // $p.step.id // "步骤") | tostring)
                  elif $s == "step_succeeded" then "完成:" + (($p.step.title // $p.step.id // "步骤") | tostring)
                  elif $s == "terminal_executed" then "终端执行:" + (($p.status // "unknown") | tostring)
                  elif $s == "script_executed" then "Skill执行:" + (($p.status // "unknown") | tostring)
                  elif ($s | startswith("observer_")) then "Observer:" + (($p.status // "event") | tostring)
                  elif $s == "finished" then "业务状态:" + (($p.status // "unknown") | tostring)
                  elif $s == "session_finished" then "会话结束:" + (($p.status // "unknown") | tostring)
                  else $s end;
            def event_detail:
                payload as $p
                | [
                    ($p.input_preview // empty),
                    ($p.command // empty),
                    ($p.ref // empty),
                    ($p.detail.output_preview // empty),
                    ($p.detail.action // empty),
                    ($p.diagnostic // empty)
                  ] | map(tostring | select(length > 0)) | first // "";
            . as $events
            | ($events | map(select(stage == "session_started")) | first) as $started
            | ($events | map(select(stage == "session_finished")) | last) as $finished
            | ([($events[] | mode_from_event)] | unique) as $modes
            | ([ $events[]
                  | select(stage | test("received|planned|step_policy_checked|step_auto_approved|step_approval_required|step_blocked|step_failed|step_succeeded|terminal_executed|script_executed|observer_|finished"))
                  | {stage:stage, title:event_title, detail:event_detail}
              ] | .[0:6]) as $highlights
            | ($started.payload.entrypoint // (if ($session_id | startswith("web_")) then "web" else "cli" end)) as $entrypoint
            | {
                session_id:$session_id,
                status:($finished.payload.status // ($events | map(select(stage == "finished")) | last | .payload.status) // "unknown"),
                started_at:($started.timestamp // ""),
                finished_at:($finished.timestamp // ""),
                updated_at:($events[-1].timestamp // ""),
                entrypoint:$entrypoint,
                entrypoint_label:(if $entrypoint == "web" then "Web" else "CLI" end),
                modes:$modes,
                mode_label:(if ($modes | length) == 0 then "未记录模式" else ($modes | join(" + ")) end),
                has_multiple_modes:(($modes | length) > 1),
                event_count:($events | length),
                command_count:([$events[] | select(stage | test("command_|terminal_executed|script_executed|execution_"))] | length),
                decision_count:([$events[] | select((stage | test("approval|rejected|skipped|terminated|control_event")) or ((payload.event // "") | test("approve|reject|skip|terminate")))] | length),
                observer_count:([$events[] | select(stage | startswith("observer_"))] | length),
                policy_count:([$events[] | select(stage | test("policy|step_policy_checked"))] | length),
                important_events:($highlights | map(.stage)),
                event_summary:(if ($highlights | length) == 0 then "无关键事件" else ($highlights | map(.title) | join("；")) end),
                highlights:$highlights,
                headline:((($events | length) | tostring) + " 个事件 · " + (if $entrypoint == "web" then "Web" else "CLI" end) + " · " + (if ($modes | length) == 0 then "未记录模式" else ($modes | join(" + ")) end)),
                path:$path,
                size_bytes:$size_bytes,
                mtime:$mtime
              }
        ' "${path}" 2>/dev/null || jq -cn \
            --arg session_id "${session_id}" \
            --arg path "${path}" \
            --argjson size_bytes "${size}" \
            --argjson mtime "${mtime}" \
            '{session_id:$session_id,status:"unreadable",started_at:"",finished_at:"",updated_at:"",entrypoint:"cli",entrypoint_label:"CLI",modes:[],mode_label:"未记录模式",has_multiple_modes:false,event_count:0,command_count:0,decision_count:0,observer_count:0,policy_count:0,important_events:[],event_summary:"审计文件无法读取",highlights:[],headline:"审计文件无法读取",path:$path,size_bytes:$size_bytes,mtime:$mtime}')"
        if [[ -n "${query}" ]]; then
            haystack="$(jq -r '[.session_id, .status, .started_at, .finished_at, .updated_at, .entrypoint, .entrypoint_label, .mode_label, .event_summary, .headline, .path, ((.modes // []) | join(" "))] | map(tostring) | join(" ")' <<<"${summary}")"
            if ! grep -Fqi -- "${query}" <<<"${haystack}"; then
                continue
            fi
        fi
        if [[ "${count}" -ge "${limit}" ]]; then
            break
        fi
        count=$((count + 1))
        entries="$(jq -cn \
            --argjson prior "${entries}" \
            --argjson summary "${summary}" \
            '$prior + [$summary]')"
    done < <(find "${LINUX_AGENT_LOG_DIR}" -maxdepth 1 -type f -name '*.jsonl' -printf '%T@ %p\n' 2>/dev/null | sort -rn)

    jq -cn --argjson entries "${entries}" '{ok:true, status:"listed", sessions:$entries}'
}

linux_agent_api_audit_read() {
    local payload="$1"
    local session_id log_file report_file tmp_root
    session_id="$(jq -r '.session_id // empty' <<<"${payload}")"
    if [[ -z "${session_id}" || ! "${session_id}" =~ ^[A-Za-z0-9_.-]+$ ]]; then
        linux_agent_api_error "invalid_session_id" "session_id is required and must be a safe file name."
        return 0
    fi
    log_file="${LINUX_AGENT_LOG_DIR}/${session_id}.jsonl"
    if [[ ! -f "${log_file}" ]]; then
        linux_agent_api_error "not_found" "Audit session not found."
        return 0
    fi

    tmp_root="${LINUX_AGENT_TMP_DIR:-/tmp}"
    report_file="$(mktemp "${tmp_root%/}/audit-report.XXXXXX")"
    if ! linux_agent_show_audit "${session_id}" > "${report_file}"; then
        rm -f "${report_file}"
        linux_agent_api_error "read_failed" "Audit session could not be rendered."
        return 0
    fi
    jq -n --arg session_id "${session_id}" --rawfile report "${report_file}" --slurpfile events "${log_file}" \
        '{ok:true, status:"read", session_id:$session_id, report:$report, events:$events}'
    rm -f "${report_file}"
}

linux_agent_api_work_prepare_response() {
    local user_input="$1"
    local mode="${2:-work}"
    local topic context_json request_context response_json safe_response

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
        jq -cn \
            --arg status "$(jq -r '.status' <<<"${response_json}")" \
            --arg error "$(linux_agent_ai_error_text "${response_json}")" \
            --argjson context "${context_json}" \
            --argjson response "${response_json}" \
            '{ok:false, status:$status, error:$error, context:$context, response:$response}'
        return 0
    fi
    if ! linux_agent_validate_work_response "${response_json}"; then
        linux_agent_log_event "ai_invalid_response" "${response_json}"
        jq -cn \
            --argjson context "${context_json}" \
            --argjson response "${response_json}" \
            '{ok:false, status:"ai_invalid_response", error:"模型响应不符合 work schema。", context:$context, response:$response}'
        return 0
    fi

    safe_response="$(linux_agent_response_without_thinking "${response_json}")"
    linux_agent_log_event "planned" "${safe_response}"
    jq -cn --argjson context "${context_json}" --argjson response "${response_json}" \
        '{ok:true, context:$context, response:$response}'
}

linux_agent_api_work_run() {
    local payload="$1"
    local user_input prepared response_json context_json response_type execution_json final_status compact answer used_agent_loop execution_state_json
    user_input="$(jq -r '.input // .request // empty' <<<"${payload}")"
    if [[ -z "${user_input}" ]]; then
        linux_agent_api_error "missing_input" "input is required."
        return 0
    fi

    LINUX_AGENT_OUTPUT_JSON=1
    linux_agent_api_set_decision_lines "${payload}"
    execution_state_json="$(jq -c '.execution_state // {} | if type == "object" then . else {} end' <<<"${payload}")"

    if jq -e '(.response? // .plan?) | type == "object"' <<<"${payload}" >/dev/null; then
        response_json="$(jq -c '.response // .plan' <<<"${payload}")"
        if linux_agent_ai_response_is_error "${response_json}"; then
            jq -cn \
                --arg status "$(jq -r '.status' <<<"${response_json}")" \
                --arg error "$(linux_agent_ai_error_text "${response_json}")" \
                --argjson response "${response_json}" \
                '{ok:false, status:$status, error:$error, response:$response}'
            return 0
        fi
        if ! linux_agent_validate_work_response "${response_json}"; then
            jq -cn --argjson response "${response_json}" \
                '{ok:false, status:"ai_invalid_response", error:"response/plan 不符合 work schema。", response:$response}'
            return 0
        fi
        if jq -e '(.context? | type == "object")' <<<"${payload}" >/dev/null; then
            context_json="$(jq -c '.context' <<<"${payload}")"
        else
            local topic
            topic="$(linux_agent_detect_topic "${user_input}")"
            context_json="$(linux_agent_sense_topic "${topic}")"
            context_json="$(linux_agent_redact_json "${context_json}")"
        fi
        linux_agent_log_event "received" "$(jq -cn --arg input "${user_input}" '{input:$input, mode:"work"}')"
        linux_agent_log_event "planned" "$(linux_agent_response_without_thinking "${response_json}")"
    else
        prepared="$(linux_agent_api_work_prepare_response "${user_input}" "work")"
        if [[ "$(jq -r '.ok // false' <<<"${prepared}")" != "true" ]]; then
            final_status="$(jq -r '.status // "ai_failed"' <<<"${prepared}")"
            linux_agent_log_event "finished" "$(jq -cn --arg status "${final_status}" '{status:$status}')"
            printf '%s\n' "${prepared}"
            return 0
        fi
        response_json="$(jq -c '.response' <<<"${prepared}")"
        context_json="$(jq -c '.context' <<<"${prepared}")"
    fi
    response_type="$(jq -r '.response_type' <<<"${response_json}")"

    if [[ "${response_type}" == "answer" ]]; then
        answer="$(jq -r '.answer // empty' <<<"${response_json}")"
        linux_agent_log_event "finished" "$(jq -cn '{status:"answered"}')"
        linux_agent_record_conversation_turn "work" "${user_input}" "${answer}" "answered" "request"
        jq -cn --arg answer "${answer}" --argjson context "${context_json}" --argjson response "${response_json}" --argjson timeline "$(linux_agent_timeline_plan_items "${response_json}")" \
            '{
                ok:true,
                status:"answered",
                context:$context,
                response:$response,
                timeline:$timeline,
                approval_card:null,
                output_blocks:[{kind:"markdown", title:"回答", text:$answer, truncated_bytes:0}]
            }'
        return 0
    fi

    if [[ "$(linux_agent_agent_loop_enabled)" == "true" ]]; then
        used_agent_loop=true
        execution_json="$(linux_agent_run_agent_loop "${user_input}" "work" "${context_json}" "${response_json}" "${execution_state_json}")"
    else
        used_agent_loop=false
        execution_json="$(linux_agent_execute_work_plan "${response_json}" "${user_input}" "${execution_state_json}")"
    fi
    linux_agent_log_event "executed" "${execution_json}"
    final_status="$(jq -r '.status // "unknown"' <<<"${execution_json}")"
    linux_agent_log_event "finished" "$(jq -cn --arg status "${final_status}" '{status:$status}')"
    if [[ "${used_agent_loop}" != "true" ]]; then
        linux_agent_record_conversation_turn "work" "${user_input}" "$(jq -c '{status:.status, results:(.results | length)}' <<<"${execution_json}")" "${final_status}" "request"
    fi
    execution_state_json="$(jq -c '
        {
            next_step_index:((.results // []) | length),
            approval_step_id:(.approval_step.id // null),
            status:(.status // null),
            results:(.results // [])
        }
    ' <<<"${execution_json}")"
    jq -cn --arg status "${final_status}" --argjson context "${context_json}" --argjson response "${response_json}" --argjson protocol "$(linux_agent_protocol_for_work "${final_status}" "${response_json}" "${execution_json}")" --argjson execution_state "${execution_state_json}" \
        '{
            ok:($status == "executed" or $status == "answered"),
            status:$status,
            context:$context,
            response:$response,
            timeline:$protocol.timeline,
            approval_card:$protocol.approval_card,
            output_blocks:$protocol.output_blocks,
            execution_state:$execution_state
        }'
}

linux_agent_api_script_review() {
    local payload="$1"
    local ref args material review
    ref="$(jq -r '.ref // empty' <<<"${payload}")"
    args="$(jq -c '.arguments // {}' <<<"${payload}")"
    if ! args="$(linux_agent_normalize_json_object_argument "${args}")"; then
        jq -cn --arg ref "${ref}" '{ok:false, status:"blocked", error:"脚本参数必须是 JSON 对象。", ref:$ref}'
        return 0
    fi
    if ! linux_agent_skill_is_registered "${ref}"; then
        jq -cn --arg ref "${ref}" '{ok:false, status:"blocked", error:"脚本未登记或不在 skills 目录中。", ref:$ref}'
        return 0
    fi
    material="$(printf 'skill_script=%s\narguments=%s\n%s\n' "${ref}" "${args}" "$(linux_agent_skill_script_content "${ref}")")"
    review="$(linux_agent_policy_review_text "script:${ref}" "${material}")"
    jq -cn --arg ref "${ref}" --argjson arguments "${args}" --argjson review "${review}" --argjson output_blocks "$(linux_agent_output_blocks_from_review "${review}")" \
        '{
            ok:(($review.approved // false) == true),
            status:(if (($review.approved // false) == true) then (if (($review.approval_required // false) == true) then "approval_required" else "approved" end) else "blocked" end),
            ref:$ref,
            arguments:$arguments,
            review:$review,
            output_blocks:$output_blocks,
            timeline:[{id:"script-review", kind:"review", status:(if (($review.approved // false) != true) then "blocked" elif (($review.approval_required // false) == true) then "approval_required" else "approved" end), title:"Skill 审查", summary:($review.risk_level // "low"), review:$review, output_blocks:$output_blocks}]
        }'
}

linux_agent_api_script_run() {
    local payload="$1"
    local review_json ref args result final_status script_path subject
    review_json="$(linux_agent_api_script_review "${payload}")"
    ref="$(jq -r '.ref // empty' <<<"${review_json}")"
    args="$(jq -c '.arguments // {}' <<<"${review_json}")"
    linux_agent_log_event "received" "$(jq -cn --arg ref "${ref}" --argjson args "${args}" '{mode:"script", ref:$ref, arguments:$args}')"
    linux_agent_log_event "script_policy_checked" "$(jq -c '.review // {}' <<<"${review_json}")"

    if [[ "$(jq -r '.ok // false' <<<"${review_json}")" != "true" ]]; then
        linux_agent_log_event "script_blocked" "${review_json}"
        linux_agent_log_event "finished" "$(jq -cn '{status:"blocked"}')"
        jq -cn --argjson review_response "${review_json}" '{
            ok:false,
            status:"blocked",
            timeline:($review_response.timeline // []),
            approval_card:null,
            output_blocks:($review_response.output_blocks // [])
        }'
        return 0
    fi
    if [[ "$(jq -r '.approve // false' <<<"${payload}")" != "true" ]]; then
        result="$(jq -cn --arg ref "${ref}" '{ok:false, status:"rejected", ref:$ref}')"
        linux_agent_log_event "script_rejected" "${result}"
        linux_agent_log_event "finished" "$(jq -cn '{status:"rejected"}')"
        jq -cn --argjson review_response "${review_json}" --argjson blocks "$(linux_agent_output_blocks_from_result "${result}")" \
            '{ok:false, status:"rejected", timeline:($review_response.timeline // []), approval_card:null, output_blocks:$blocks}'
        return 0
    fi

    script_path="$(linux_agent_skill_script_path "${ref}")"
    subject="$(jq -cn --arg ref "${ref}" --argjson arguments "${args}" '{kind:"script_command", ref:$ref, arguments:$arguments}')"
    result="$(
        LINUX_AGENT_EXECUTION_PRIVILEGE="$(linux_agent_execution_privilege_from_review "$(jq -c '.review // {}' <<<"${review_json}")")" \
            linux_agent_execute_observed_command_output "script" "${subject}" -- bash "${script_path}" "${args}"
    )"
    linux_agent_log_event "script_executed" "${result}"
    if [[ "$(jq -r '.ok // false' <<<"${result}")" == "true" ]]; then
        final_status="executed"
    else
        final_status="failed"
    fi
    linux_agent_log_event "finished" "$(jq -cn --arg status "${final_status}" '{status:$status}')"
    jq -cn --arg status "${final_status}" --argjson review_response "${review_json}" --argjson protocol "$(linux_agent_protocol_for_single_execution "Skill 输出" "${result}")" \
        '{
            ok:($status == "executed"),
            status:$status,
            timeline:(($review_response.timeline // []) + $protocol.timeline),
            approval_card:null,
            output_blocks:$protocol.output_blocks
        }'
}

linux_agent_api_terminal_review() {
    local payload="$1"
    local command_text review
    command_text="$(jq -r '.command // empty' <<<"${payload}")"
    if [[ -z "${command_text}" ]]; then
        linux_agent_api_error "missing_command" "command is required."
        return 0
    fi
    review="$(linux_agent_terminal_review "${command_text}")"
    jq -cn --arg command "${command_text}" --argjson review "${review}" --argjson output_blocks "$(linux_agent_output_blocks_from_review "${review}")" --argjson approval_card "$(linux_agent_approval_card_for_terminal "${command_text}" "${review}")" \
        '{
            ok:(($review.approved // false) == true),
            status:(if (($review.approved // false) == true) then (if (($review.approval_required // false) == true) then "approval_required" else "approved" end) else "blocked" end),
            command:$command,
            review:$review,
            approval_card:$approval_card,
            output_blocks:$output_blocks,
            timeline:[{id:"terminal-review", kind:"review", status:(if (($review.approved // false) != true) then "blocked" elif (($review.approval_required // false) == true) then "approval_required" else "approved" end), title:"终端审查", summary:($review.risk_level // "low"), review:$review, output_blocks:$output_blocks}]
        }'
}

linux_agent_api_terminal_run() {
    local payload="$1"
    local command_text stdout
    command_text="$(jq -r '.command // empty' <<<"${payload}")"
    if [[ -z "${command_text}" ]]; then
        linux_agent_api_error "missing_command" "command is required."
        return 0
    fi
    LINUX_AGENT_OUTPUT_JSON=1
    LINUX_AGENT_API_MODE=1
    stdout="$(linux_agent_process_terminal_request "${command_text}" "$(jq -r '.approve // false' <<<"${payload}")")"
    if jq -e . >/dev/null 2>&1 <<<"${stdout}"; then
        jq -cn --argjson result "${stdout}" --argjson protocol "$(linux_agent_protocol_for_single_execution "终端输出" "${stdout}")" --argjson approval_card "$(linux_agent_approval_card_for_terminal "${command_text}" "$(jq -c '.review // {}' <<<"${stdout}")")" '{
            ok:($result.ok // false),
            status:($result.status // "unknown"),
            timeline:$protocol.timeline,
            approval_card:(if ($result.status // "") == "approval_required" then $approval_card else null end),
            output_blocks:$protocol.output_blocks
        }'
    else
        jq -cn --arg raw "${stdout}" '{ok:false, status:"invalid_output", timeline:[], approval_card:null, output_blocks:[{kind:"stdout", title:"原始输出", text:$raw, truncated_bytes:0}]}'
    fi
}

linux_agent_api_edit_plan() {
    local payload="$1"
    local user_input context_json request_context edit_json
    user_input="$(jq -r '.input // .request // empty' <<<"${payload}")"
    if [[ -z "${user_input}" ]]; then
        linux_agent_api_error "missing_input" "input is required."
        return 0
    fi
    linux_agent_log_event "received" "$(jq -cn --arg input "${user_input}" '{input:$input, mode:"edit"}')"
    context_json="$(jq -cn '{edit_mode:true}')"
    request_context="$(linux_agent_build_request_context "${user_input}" "${context_json}" "edit")"
    linux_agent_record_ai_request_files "${request_context}"
    edit_json="$(linux_agent_call_ai_with_context "${user_input}" "${request_context}" "edit" "${context_json}")"
    if linux_agent_ai_response_is_error "${edit_json}"; then
        linux_agent_log_event "ai_failed" "${edit_json}"
        linux_agent_log_event "finished" "$(jq -cn '{status:"ai_failed"}')"
        jq -cn \
            --arg status "$(jq -r '.status' <<<"${edit_json}")" \
            --arg error "$(linux_agent_ai_error_text "${edit_json}")" \
            --argjson response "${edit_json}" \
            '{ok:false, status:$status, error:$error, response:$response}'
        return 0
    fi
    if ! linux_agent_validate_edit_response "${edit_json}"; then
        linux_agent_log_event "ai_invalid_response" "${edit_json}"
        linux_agent_log_event "finished" "$(jq -cn '{status:"ai_invalid_response"}')"
        jq -cn --argjson response "${edit_json}" \
            '{ok:false, status:"ai_invalid_response", error:"模型响应不符合 skill_edit schema。", response:$response}'
        return 0
    fi
    linux_agent_log_event "edit_planned" "${edit_json}"
    linux_agent_log_event "finished" "$(jq -cn '{status:"planned"}')"
    linux_agent_record_conversation_turn "edit" "${user_input}" "$(jq -c '.skill // {}' <<<"${edit_json}")" "planned" "request"
    jq -cn --argjson edit "${edit_json}" '{ok:true, status:"planned", edit:$edit}'
}

linux_agent_api_edit_review() {
    local payload="$1"
    local edit_json
    edit_json="$(jq -c '.edit // .' <<<"${payload}")"
    linux_agent_review_edit_package "${edit_json}"
}

linux_agent_api_edit_apply() {
    local payload="$1"
    local edit_json result final_status
    edit_json="$(jq -c '.edit // .' <<<"${payload}")"
    if [[ "$(jq -r '.approve // false' <<<"${payload}")" != "true" ]]; then
        jq -cn '{ok:false, status:"rejected", error:"approve=true is required to save a skill edit package."}'
        return 0
    fi
    result="$(linux_agent_apply_skill_edit_package_direct "${edit_json}")"
    linux_agent_log_event "edit_applied" "${result}"
    if [[ "$(jq -r '.ok // false' <<<"${result}")" == "true" ]]; then
        final_status="edited"
    else
        final_status="$(jq -r '.status // "failed"' <<<"${result}")"
    fi
    linux_agent_log_event "finished" "$(jq -cn --arg status "${final_status}" '{status:$status}')"
    jq -cn --arg status "${final_status}" --argjson result "${result}" \
        '{ok:($result.ok // false), status:$status, result:$result}'
}

linux_agent_api_policy_validate() {
    local payload="$1"
    local path content
    path="$(jq -r '.path // empty' <<<"${payload}")"
    if jq -e 'has("content")' <<<"${payload}" >/dev/null 2>&1; then
        content="$(jq -r '.content // ""' <<<"${payload}")"
        linux_agent_validate_policy_content "${path}" "${content}"
        return 0
    fi
    linux_agent_validate_policy_file "${path}"
}

linux_agent_api_needs_session() {
    local resource="${1:-}"
    local action="${2:-}"
    case "${resource}:${action}" in
        work:run|script:run|terminal:run|edit:plan|edit:apply)
            printf 'true\n'
            ;;
        *)
            printf 'false\n'
            ;;
    esac
}

linux_agent_api_dispatch() {
    local resource="${1:-health}"
    local action="${2:-}"
    local raw_payload="${3:-}"
    local payload

    payload="$(linux_agent_api_payload "${raw_payload}")" || {
        printf '%s\n' "${payload}"
        return 0
    }

    case "${resource}:${action}" in
        health:|"health:get")
            linux_agent_api_health
            ;;
        config:web)
            jq -cn --argjson web "$(linux_agent_api_web_config_json)" '{ok:true, status:"ok", web:$web}'
            ;;
        doctor:|doctor:run)
            jq -cn --argjson doctor "$(linux_agent_doctor)" '{ok:($doctor.ok // false), status:"checked", doctor:$doctor}'
            ;;
        sense:|sense:get)
            local topic sensed
            topic="$(jq -r '.topic // "all"' <<<"${payload}")"
            sensed="$(linux_agent_sense_topic "${topic}")"
            jq -cn --arg topic "${topic}" --argjson sense "${sensed}" '{ok:true, status:"sensed", topic:$topic, sense:$sense}'
            ;;
        tools:list)
            linux_agent_api_tools_list
            ;;
        skills:validate)
            jq -cn --argjson validation "$(linux_agent_validate_skills)" '{ok:($validation.ok // false), status:"validated", validation:$validation}'
            ;;
        policy:validate)
            jq -cn --argjson validation "$(linux_agent_api_policy_validate "${payload}")" '{ok:($validation.ok // false), status:($validation.status // "invalid"), validation:$validation}'
            ;;
        audit:list)
            linux_agent_api_audit_list "${payload}"
            ;;
        audit:read)
            linux_agent_api_audit_read "${payload}"
            ;;
        work:run)
            linux_agent_api_work_run "${payload}"
            ;;
        script:review)
            linux_agent_api_script_review "${payload}"
            ;;
        script:run)
            linux_agent_api_script_run "${payload}"
            ;;
        terminal:review)
            linux_agent_api_terminal_review "${payload}"
            ;;
        terminal:run)
            linux_agent_api_terminal_run "${payload}"
            ;;
        edit:plan)
            linux_agent_api_edit_plan "${payload}"
            ;;
        edit:review)
            linux_agent_api_edit_review "${payload}"
            ;;
        edit:apply)
            linux_agent_api_edit_apply "${payload}"
            ;;
        *)
            linux_agent_api_error "unknown_api_route" "Unsupported API route."
            ;;
    esac
}
