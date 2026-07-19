#!/usr/bin/env bash

set -euo pipefail

if ! declare -F linux_agent_prepare_work_request >/dev/null 2>&1; then
    # shellcheck source=workflow.sh
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/workflow.sh"
fi

linux_agent_api_payload() {
    local raw="${1:-}"
    if [[ -z "${raw}" && ! -t 0 ]]; then
        raw="$(cat)"
    fi
    [[ -n "${raw}" ]] || raw='{}'
    if ! jq -e . >/dev/null 2>&1 <<<"${raw}"; then
        jq -cn \
            --arg raw "${raw}" \
            --arg request_id "${LINUX_AGENT_REQUEST_ID:-}" '
            {
                ok:false,
                status:"invalid_json",
                error:"API payload must be valid JSON.",
                code:"invalid_json",
                message:"API payload must be valid JSON.",
                retryable:false,
                request_id:$request_id,
                details:{raw_preview:($raw[0:200])}
            }'
        return 1
    fi
    jq -c . <<<"${raw}"
}

linux_agent_api_error() {
    local status="$1"
    local message="$2"
    local retryable=false schema_file="${LINUX_AGENT_ROOT}/schema/domain.json"
    if [[ -f "${schema_file}" ]]; then
        retryable="$(jq -r --arg code "${status}" '.error_codes[$code].retryable // false' "${schema_file}" 2>/dev/null || printf 'false')"
    fi
    jq -cn \
        --arg status "${status}" \
        --arg message "${message}" \
        --arg request_id "${LINUX_AGENT_REQUEST_ID:-}" \
        --argjson retryable "${retryable}" '
        {
            ok:false,
            status:$status,
            error:$message,
            code:$status,
            message:$message,
            retryable:$retryable,
            request_id:$request_id,
            details:{}
        }'
}

linux_agent_api_execution_error() {
    local status="$1"
    local code="$2"
    local message="$3"
    local source="${4:-}"
    [[ -n "${source}" ]] || source='{}'
    jq -cn \
        --arg status "${status}" \
        --arg code "${code}" \
        --arg message "${message}" \
        --argjson source "${source}" '
        $source + {
            ok:false,
            status:$status,
            error:$message,
            code:$code,
            error_code:$code,
            message:$message,
            timeline:[],
            approval_card:null,
            output_blocks:[]
        }'
}

linux_agent_api_web_config_json() {
    jq -cn \
        --argjson enabled "$(linux_agent_config_bool_default '.web.enabled' 'true')" \
        --arg host "$(linux_agent_config_get_default '.web.host' '127.0.0.1')" \
        --arg port "$(linux_agent_config_get_default '.web.port' '8765')" \
        --arg job_retention_hours "$(linux_agent_config_get_default '.web.job_retention_hours' '24')" \
        --arg max_active_jobs "$(linux_agent_config_get_default '.web.max_active_jobs' '4')" \
        --arg job_timeout_sec "$(linux_agent_config_get_default '.web.job_timeout_sec' '900')" \
        --arg max_job_attempts "$(linux_agent_config_get_default '.web.max_job_attempts' '3')" \
        --arg cancel_grace_sec "$(linux_agent_config_get_default '.web.cancel_grace_sec' '2')" \
        --arg token "$(linux_agent_config_get_default '.web.token' '')" \
        '{
            enabled:$enabled,
            host:(if $host == "" then "127.0.0.1" else $host end),
            port:($port | tonumber? // 8765),
            job_retention_hours:($job_retention_hours | tonumber? // 24),
            max_active_jobs:($max_active_jobs | tonumber? // 4),
            job_timeout_sec:($job_timeout_sec | tonumber? // 900),
            max_job_attempts:($max_job_attempts | tonumber? // 3),
            cancel_grace_sec:($cancel_grace_sec | tonumber? // 2),
            token_configured:($token != "")
        }'
}

linux_agent_api_health() {
    jq -cn \
        --arg root "${LINUX_AGENT_ROOT}" \
        --arg version "$(linux_agent_config_get_default '.remote.release_version' 'local')" \
        --argjson web "$(linux_agent_api_web_config_json)" \
        --argjson remote "$(linux_agent_remote_state_json)" \
        '{ok:true, status:"ok", app:"linux-agent", version:(if $version == "" then "local" else $version end), root:$root, web:$web, remote:$remote}'
}

linux_agent_api_tools_list() {
    local index_text scripts line ref description risk materialization
    index_text="$(linux_agent_skill_index_text 2>/dev/null || true)"
    scripts='[]'
    while IFS= read -r line; do
        ref="$(sed -n 's/^- `\([^`]*\)`: .*/\1/p' <<<"${line}")"
        [[ -n "${ref}" ]] || continue
        description="$(sed -n 's/^- `[^`]*`: \(.*\)$/\1/p' <<<"${line}")"
        ref="${ref%.sh}"
        risk="$(linux_agent_skill_declared_risk "${ref}")"
        materialization="local"
        if linux_agent_remote_mode_enabled; then
            if linux_agent_remote_skill_ready "${ref%%/*}"; then
                materialization="ready"
            else
                materialization="available"
            fi
        fi
        scripts="$(jq -cn \
            --argjson prior "${scripts}" \
            --arg ref "${ref}" \
            --arg skill "${ref%%/*}" \
            --arg script "${ref#*/}" \
            --arg description "${description}" \
            --arg risk "${risk}" \
            --arg materialization "${materialization}" \
            '$prior + [{ref:$ref, skill:$skill, script:$script, description:$description, risk:$risk, materialization:$materialization}]')"
    done <<<"${index_text}"

    jq -cn --arg index_text "${index_text}" --argjson scripts "${scripts}" --argjson remote "$(linux_agent_remote_state_json)" \
        '{ok:true, status:"listed", index_text:$index_text, scripts:$scripts, remote:$remote}'
}

linux_agent_api_audit_list() {
    local payload="$1"
    local limit include_runtime query entries item path session_id size mtime count summary haystack
    local segment_path segment_size segment_mtime
    local -a segment_files=()
    limit="$(jq -r '.limit // 50' <<<"${payload}")"
    [[ "${limit}" =~ ^[0-9]+$ && "${limit}" -gt 0 ]] || limit=50
    include_runtime="$(jq -r '.include_runtime // false' <<<"${payload}")"
    query="$(jq -r '.query // .filter // .session_id // empty' <<<"${payload}")"
    entries='[]'
    count=0

    while IFS= read -r -d '' item; do
        [[ -n "${item}" ]] || continue
        path="${item#*$'\t'}"
        session_id="$(basename "${path}" .jsonl)"
        [[ "${session_id}" =~ ^[A-Za-z0-9._-]+$ ]] || continue
        if [[ "${include_runtime}" != "true" && "${session_id}" == web_* ]]; then
            continue
        fi
        mapfile -t segment_files < <(linux_agent_audit_segment_files "${session_id}" || true)
        ((${#segment_files[@]} > 0)) || continue
        size=0
        mtime=0
        for segment_path in "${segment_files[@]}"; do
            segment_size="$(stat -c '%s' "${segment_path}" 2>/dev/null || printf '0')"
            segment_mtime="$(stat -c '%Y' "${segment_path}" 2>/dev/null || printf '0')"
            size=$((size + segment_size))
            if ((segment_mtime > mtime)); then
                mtime="${segment_mtime}"
            fi
        done
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
        ' "${segment_files[@]}" 2>/dev/null || jq -cn \
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
    done < <(find "${LINUX_AGENT_LOG_DIR}" -maxdepth 1 -type f -name '*.jsonl' -printf '%T@\t%p\0' 2>/dev/null | sort -z -nr)

    jq -cn --argjson entries "${entries}" '{ok:true, status:"listed", sessions:$entries}'
}

linux_agent_api_audit_read() {
    local payload="$1"
    local session_id log_file report_file tmp_root integrity_report read_rc=0
    local snapshot_dir="" snapshot_log=""
    local -a log_segments=()
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
    if ! snapshot_dir="$(mktemp -d "${tmp_root%/}/audit-read.XXXXXX")"; then
        linux_agent_api_error "read_failed" "Audit snapshot directory could not be created."
        return 0
    fi
    if ! snapshot_log="$(linux_agent_audit_snapshot "${session_id}" "${snapshot_dir}" 2>/dev/null)"; then
        rmdir "${snapshot_dir}" 2>/dev/null || true
        linux_agent_api_error "read_failed" "Audit session could not be snapshotted."
        return 0
    fi
    mapfile -t log_segments < <(linux_agent_audit_segment_paths "${snapshot_log}" || true)
    if ((${#log_segments[@]} == 0)); then
        rm -f -- "${snapshot_log}"
        rmdir "${snapshot_dir}" 2>/dev/null || true
        linux_agent_api_error "read_failed" "Audit snapshot did not contain a live segment."
        return 0
    fi

    report_file="${snapshot_dir}/report.txt"
    if ! linux_agent_show_audit "${session_id}" "${snapshot_log}" >"${report_file}"; then
        rm -f -- "${report_file}" "${snapshot_log}.lock" "${log_segments[@]}"
        rmdir "${snapshot_dir}" 2>/dev/null || true
        linux_agent_api_error "read_failed" "Audit session could not be rendered."
        return 0
    fi
    integrity_report="$(linux_agent_audit_verify_chain "${session_id}" "${snapshot_log}" 2>/dev/null || true)"
    if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"${integrity_report}"; then
        integrity_report='{"ok":false,"status":"verify_failed","breaks":[]}'
    fi
    jq -s \
        --arg session_id "${session_id}" \
        --rawfile report "${report_file}" \
        --argjson integrity "${integrity_report}" \
        '{
            ok:true,
            status:"read",
            session_id:$session_id,
            report:$report,
            integrity:$integrity,
            integrity_ok:($integrity.ok // false),
            events:.
        }' \
        "${log_segments[@]}" || read_rc=$?
    rm -f -- "${report_file}" "${snapshot_log}.lock" "${log_segments[@]}"
    rmdir "${snapshot_dir}" 2>/dev/null || true
    if ((read_rc != 0)); then
        linux_agent_api_error "read_failed" "Audit session events could not be parsed."
    fi
}

linux_agent_api_work_prepare_response() {
    linux_agent_prepare_work_request "$@"
}

linux_agent_api_work_run() {
    local payload="$1"
    local user_input prepared response_json execution_plan_json context_json response_type execution_json final_status answer used_agent_loop execution_state_json execution_selection error_code error_source
    user_input="$(jq -r '.input // .request // empty' <<<"${payload}")"
    if [[ -z "${user_input}" ]]; then
        linux_agent_api_execution_error "invalid" "missing_input" "input is required."
        return 0
    fi

    LINUX_AGENT_OUTPUT_JSON=1
    linux_agent_api_set_decision_lines "${payload}"
    execution_state_json="$(jq -c '.execution_state // {} | if type == "object" then . else {} end' <<<"${payload}")"

    if jq -e '(.response? // .plan?) | type == "object"' <<<"${payload}" >/dev/null; then
        response_json="$(jq -c '.response // .plan' <<<"${payload}")"
        if linux_agent_ai_response_is_error "${response_json}"; then
            error_code="$(jq -r '.status // "ai_request_failed"' <<<"${response_json}")"
            if [[ "${error_code}" == "ai_invalid_response" ]]; then
                final_status="ai_invalid_response"
            else
                final_status="ai_failed"
            fi
            error_source="$(jq -cn --argjson response "${response_json}" '{response:$response}')"
            linux_agent_api_execution_error \
                "${final_status}" \
                "${error_code}" \
                "$(linux_agent_ai_error_text "${response_json}")" \
                "${error_source}"
            return 0
        fi
        if ! linux_agent_validate_work_response "${response_json}"; then
            error_source="$(jq -cn --argjson response "${response_json}" '{response:$response}')"
            linux_agent_api_execution_error \
                "ai_invalid_response" \
                "ai_invalid_response" \
                "response/plan 不符合 work schema。" \
                "${error_source}"
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
        linux_agent_capture_prepared_work_request prepared "${user_input}" "work"
        if [[ "$(jq -r '.ok // false' <<<"${prepared}")" != "true" ]]; then
            error_code="$(jq -r '.code // .error_code // .status // "ai_request_failed"' <<<"${prepared}")"
            case "$(jq -r '.status // empty' <<<"${prepared}")" in
                blocked) final_status="blocked" ;;
                ai_invalid_response) final_status="ai_invalid_response" ;;
                *) final_status="ai_failed" ;;
            esac
            linux_agent_log_event "finished" "$(jq -cn --arg status "${final_status}" '{status:$status}')"
            linux_agent_api_execution_error \
                "${final_status}" \
                "${error_code}" \
                "$(jq -r '.error // .message // "AI request failed."' <<<"${prepared}")" \
                "${prepared}"
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

    execution_plan_json="${response_json}"
    if [[ "$(jq -r '.agent_loop // false' <<<"${execution_state_json}")" != "true" ]] &&
        jq -e '.current_plan | type == "object"' >/dev/null 2>&1 <<<"${execution_state_json}"; then
        execution_plan_json="$(jq -c '.current_plan' <<<"${execution_state_json}")"
    fi
    execution_selection="$(linux_agent_execute_prepared_work \
        "${user_input}" \
        "work" \
        "${context_json}" \
        "${execution_plan_json}" \
        "${execution_state_json}")"
    used_agent_loop="$(jq -r '.used_agent_loop' <<<"${execution_selection}")"
    execution_json="$(jq -c '.execution' <<<"${execution_selection}")"
    linux_agent_log_event "executed" "${execution_json}"
    final_status="$(jq -r '.status // "unknown"' <<<"${execution_json}")"
    linux_agent_log_event "finished" "$(jq -cn --arg status "${final_status}" '{status:$status}')"
    if [[ "${used_agent_loop}" != "true" ]]; then
        linux_agent_record_conversation_turn "work" "${user_input}" "$(jq -c '{status:.status, results:(.results | length)}' <<<"${execution_json}")" "${final_status}" "request"
    fi
    execution_state_json="$(jq -c \
        --argjson used_agent_loop "${used_agent_loop}" '
        if (.resume_state | type) == "object" then
            .resume_state + {
                agent_loop:$used_agent_loop,
                approval_step_id:(.approval_step.id // null),
                status:(.status // null)
            }
        else
            {
                agent_loop:$used_agent_loop,
                current_plan:(.current_plan // null),
                next_step_index:(.next_step_index // ((.results // []) | length)),
                approval_step_id:(.approval_step.id // null),
                status:(.status // null),
                results:(.resume_results // .results // []),
                step_states:(.current_step_states // [])
            }
        end
    ' <<<"${execution_json}")"
    printf '%s\n%s\n%s\n%s\n' \
        "${context_json}" \
        "${response_json}" \
        "$(linux_agent_protocol_for_work "${final_status}" "${response_json}" "${execution_json}")" \
        "${execution_state_json}" |
        jq -cs --arg status "${final_status}" \
            '{
            context:.[0],
            response:.[1],
            protocol:.[2],
            execution_state:.[3]
        } as $input
        | {
            ok:($status == "executed" or $status == "answered"),
            status:$status,
            context:$input.context,
            response:$input.response,
            timeline:$input.protocol.timeline,
            approval_card:$input.protocol.approval_card,
            output_blocks:$input.protocol.output_blocks,
            execution_state:$input.execution_state
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
    review="$(linux_agent_review_with_declared_skill_risk "${ref}" "${review}")"
    review="$(linux_agent_backup_policy_review "${ref}" "${args}" "${review}")"
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
    local review_json ref args result final_status script_path subject envelope
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
    envelope="$(linux_agent_protocol_envelope_for_single_execution "Skill 输出" "${result}")"
    jq -cn --argjson envelope "${envelope}" --argjson review_response "${review_json}" '
        $envelope + {
            timeline:(($review_response.timeline // []) + $envelope.timeline)
        }
    '
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

# These mode flags are consumed by functions from executor.sh and
# orchestrator.sh after the modules are sourced into the same shell.
# shellcheck disable=SC2034
linux_agent_api_terminal_run() {
    local payload="$1"
    local command_text stdout approval_card
    command_text="$(jq -r '.command // empty' <<<"${payload}")"
    if [[ -z "${command_text}" ]]; then
        linux_agent_api_error "missing_command" "command is required."
        return 0
    fi
    LINUX_AGENT_OUTPUT_JSON=1
    LINUX_AGENT_API_MODE=1
    stdout="$(linux_agent_process_terminal_request "${command_text}" "$(jq -r '.approve // false' <<<"${payload}")")"
    if jq -e . >/dev/null 2>&1 <<<"${stdout}"; then
        approval_card="$(linux_agent_approval_card_for_terminal "${command_text}" "$(jq -c '.review // {}' <<<"${stdout}")")"
        if [[ "$(jq -r '.status // ""' <<<"${stdout}")" != "approval_required" ]]; then
            approval_card='null'
        fi
        linux_agent_protocol_envelope_for_single_execution \
            "终端输出" \
            "${stdout}" \
            "${approval_card}"
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
    request_context="$(linux_agent_add_skill_context "${request_context}" "edit")"
    request_context="$(linux_agent_add_mcp_context "${request_context}" "edit")"
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
        work:run | script:run | terminal:run | edit:plan | edit:apply | skills:materialize)
            printf 'true\n'
            ;;
        *)
            printf 'false\n'
            ;;
    esac
}

linux_agent_api_dispatch_raw() {
    local resource="${1:-health}"
    local action="${2:-}"
    local raw_payload="${3:-}"
    local payload

    payload="$(linux_agent_api_payload "${raw_payload}")" || {
        printf '%s\n' "${payload}"
        return 0
    }

    case "${resource}:${action}" in
        health: | "health:get")
            linux_agent_api_health
            ;;
        config:web)
            jq -cn --argjson web "$(linux_agent_api_web_config_json)" '{ok:true, status:"ok", web:$web}'
            ;;
        doctor: | doctor:run)
            jq -cn --argjson doctor "$(linux_agent_doctor)" '{ok:($doctor.ok // false), status:"checked", doctor:$doctor}'
            ;;
        sense: | sense:get)
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
        skills:materialize)
            local skill_name
            skill_name="$(jq -r '.skill // empty' <<<"${payload}")"
            linux_agent_materialize_skill "${skill_name}"
            ;;
        mcp: | mcp:list)
            linux_agent_mcp_list
            ;;
        mcp:validate)
            jq -cn --argjson validation "$(linux_agent_validate_mcp)" '{ok:($validation.ok // false), status:"validated", validation:$validation}'
            ;;
        mcp:tools)
            linux_agent_mcp_tool_catalog
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
        audit:verify)
            local verify_session verify_report
            verify_session="$(jq -r '.session_id // empty' <<<"${payload}")"
            verify_report="$(linux_agent_audit_verify_chain "${verify_session}")" || true
            jq -cn --argjson report "${verify_report}" '
                {ok:($report.ok // false),
                 status:(if ($report.status // "") != "" then $report.status
                         elif ($report.ok // false) then "verified"
                         else "integrity_broken" end),
                 report:$report}'
            ;;
        audit:export)
            local export_selector export_output
            if [[ "$(jq -r '.all // false' <<<"${payload}")" == "true" ]]; then
                export_selector="--all"
            else
                export_selector="$(jq -r '.session_id // empty' <<<"${payload}")"
            fi
            export_output="$(jq -r '.output // empty' <<<"${payload}")"
            if [[ -n "${export_output}" ]]; then
                linux_agent_audit_export "${export_selector}" --output "${export_output}"
            else
                linux_agent_audit_export "${export_selector}"
            fi
            ;;
        work:run)
            if ! linux_agent_remote_api_key_transmission_allowed; then
                linux_agent_api_execution_error \
                    "blocked" \
                    "secret_transmission_disabled" \
                    "Remote runtime 未允许向 AI Provider 传输 API key。"
            else
                linux_agent_api_work_run "${payload}"
            fi
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
            if ! linux_agent_remote_api_key_transmission_allowed; then
                linux_agent_api_error "secret_transmission_disabled" "Remote runtime 未允许向 AI Provider 传输 API key。"
            else
                linux_agent_api_edit_plan "${payload}"
            fi
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

linux_agent_api_normalize_envelope() {
    local schema_file="${LINUX_AGENT_ROOT}/schema/domain.json"
    local schema='{"schema_version":1,"protocol_version":"1.0.0","error_codes":{}}'
    if [[ -f "${schema_file}" ]] && jq -e 'type == "object"' "${schema_file}" >/dev/null 2>&1; then
        schema="$(jq -c . "${schema_file}")"
    fi
    jq -c \
        --argjson schema "${schema}" \
        --arg request_id "${LINUX_AGENT_REQUEST_ID:-}" '
        if type != "object" then .
        else
            . + {
                schema_version:($schema.schema_version // 1),
                protocol_version:($schema.protocol_version // "1.0.0")
            }
            | (
                has("timeline")
                and has("approval_card")
                and has("output_blocks")
              ) as $is_execution_result
            | if has("timeline") then
                . + {timeline_semantics:(.timeline_semantics // "step_projection")}
              else . end
            | if .ok == false then
                (.code // .error_code // .status // "internal_error") as $code
                | (.message // .error // $code | tostring) as $message
                | . + {
                    status:(if $is_execution_result then (.status // "failed") else $code end),
                    error:$message,
                    code:$code,
                    message:$message,
                    retryable:(
                        if has("retryable") and (.retryable | type) == "boolean" then
                            .retryable
                        else
                            ($schema.error_codes[$code].retryable // false)
                        end
                    ),
                    request_id:(.request_id // $request_id),
                    details:(if (.details | type) == "object" then .details else {} end)
                }
              else . end
        end
    '
}

linux_agent_api_dispatch() {
    local output_file dispatch_rc=0 render_rc=0
    if ! output_file="$(mktemp "${LINUX_AGENT_TMP_DIR:-/tmp}/api-dispatch.XXXXXX")"; then
        linux_agent_api_error "internal_error" "Could not allocate the API response buffer."
        return 1
    fi

    # Run the adapter in the current shell so session-wide audit state (for
    # example AI file manifests and the final business status) survives until
    # linux_agent_finish_run performs session teardown.
    linux_agent_api_dispatch_raw "$@" >"${output_file}" || dispatch_rc=$?
    if jq -e 'type == "object"' "${output_file}" >/dev/null 2>&1; then
        linux_agent_api_normalize_envelope <"${output_file}" || render_rc=$?
    else
        cat "${output_file}" || render_rc=$?
    fi
    rm -f "${output_file}"

    if ((dispatch_rc != 0)); then
        return "${dispatch_rc}"
    fi
    if ((render_rc != 0)); then
        return "${render_rc}"
    fi
    return "${dispatch_rc}"
}
