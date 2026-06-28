#!/usr/bin/env bash

set -euo pipefail

LINUX_AGENT_LAST_AI_PAYLOAD=""
LINUX_AGENT_AI_FILE_MANIFEST='[]'

linux_agent_ai_file_metadata() {
    local path="$1"
    local purpose="$2"
    local included_as="$3"
    local resolved exists readable size sha rel_path

    resolved="$(readlink -f "${path}" 2>/dev/null || printf '%s' "${path}")"
    exists=false
    readable=false
    size=""
    sha=""
    rel_path="${resolved}"

    if [[ -n "${LINUX_AGENT_ROOT:-}" && "${resolved}" == "${LINUX_AGENT_ROOT}/"* ]]; then
        rel_path="${resolved#${LINUX_AGENT_ROOT}/}"
    fi
    if [[ -f "${resolved}" ]]; then
        exists=true
        size="$(stat -c '%s' "${resolved}" 2>/dev/null || printf '')"
        if [[ -r "${resolved}" ]]; then
            readable=true
            sha="$(sha256sum "${resolved}" 2>/dev/null | awk '{print $1}' || true)"
        fi
    fi

    jq -cn \
        --arg path "${resolved}" \
        --arg relative_path "${rel_path}" \
        --arg purpose "${purpose}" \
        --arg included_as "${included_as}" \
        --arg sha256 "${sha}" \
        --arg size_bytes "${size}" \
        --argjson exists "${exists}" \
        --argjson readable "${readable}" \
        '{
            path:$path,
            relative_path:$relative_path,
            purpose:$purpose,
            included_as:$included_as,
            exists:$exists,
            readable:$readable,
            size_bytes:($size_bytes | tonumber?),
            sha256:(if $sha256 == "" then null else $sha256 end)
        }'
}

linux_agent_record_ai_file() {
    local path="$1"
    local purpose="$2"
    local included_as="$3"
    local entry

    entry="$(linux_agent_ai_file_metadata "${path}" "${purpose}" "${included_as}")"
    LINUX_AGENT_AI_FILE_MANIFEST="$(jq -cn \
        --argjson prior "${LINUX_AGENT_AI_FILE_MANIFEST:-[]}" \
        --argjson entry "${entry}" \
        '
        ($prior + [$entry])
        | group_by(.path + "\u0000" + .purpose + "\u0000" + .included_as)
        | map(.[0])
        ')"
}

linux_agent_log_ai_files_manifest() {
    local manifest="${LINUX_AGENT_AI_FILE_MANIFEST:-[]}"
    if [[ "$(jq 'length' <<<"${manifest}")" -eq 0 ]]; then
        return 0
    fi
    if declare -F linux_agent_log_event >/dev/null 2>&1; then
        linux_agent_log_event "ai_files_manifest" "$(jq -cn --argjson files "${manifest}" '{files:$files, file_count:($files | length)}')"
    fi
}

linux_agent_build_system_prompt() {
    local prompt_file="${LINUX_AGENT_ROOT}/prompts/system.txt"
    local skill_index skill_index_path
    linux_agent_record_ai_file "${prompt_file}" "system_prompt" "system_message"
    skill_index_path="$(linux_agent_skill_index_path 2>/dev/null || true)"
    [[ -n "${skill_index_path}" ]] && linux_agent_record_ai_file "${skill_index_path}" "skill_index" "system_prompt_appendix"
    skill_index="$(linux_agent_skill_index_text 2>/dev/null || true)"

    jq -Rs --arg skill_index "${skill_index}" '
        . + "\n\n当前 skill 索引：\n" + $skill_index
    ' < "${prompt_file}"
}

linux_agent_record_ai_request_files() {
    local request_context="$1"
    local prompt_file="${LINUX_AGENT_ROOT}/prompts/system.txt"
    local skill_index_path

    linux_agent_record_ai_file "${prompt_file}" "system_prompt" "system_message"
    skill_index_path="$(linux_agent_skill_index_path 2>/dev/null || true)"
    [[ -n "${skill_index_path}" ]] && linux_agent_record_ai_file "${skill_index_path}" "skill_index" "system_prompt_appendix"
}

linux_agent_ai_error() {
    local status="$1"
    local message="$2"
    local detail="${3:-}"
    jq -cn \
        --arg status "${status}" \
        --arg error "${message}" \
        --arg detail "$(linux_agent_sanitize_text "${detail}" 1000)" \
        '{
            ok:false,
            response_type:"error",
            status:$status,
            error:$error
        } + (if $detail == "" then {} else {detail:$detail} end)'
}

linux_agent_ai_response_is_error() {
    local response_json="$1"
    jq -e '(.ok == false) and (.status | type == "string") and (.error | type == "string")' <<<"${response_json}" >/dev/null 2>&1
}

linux_agent_ai_error_text() {
    local response_json="$1"
    jq -r '.error // .status // "AI 调用失败。"' <<<"${response_json}" 2>/dev/null || printf 'AI 调用失败。\n'
}

linux_agent_validate_work_response() {
    local response_json="$1"
    jq -e '
        def valid_continue:
          (.continue_decision | type == "object") and
          (.continue_decision.should_continue | type == "boolean") and
          (.continue_decision.reason | type == "string");
        def valid_thinking:
          ((has("thinking_summary") | not) or (.thinking_summary | type == "string"));
        def valid_step:
          (.id | type == "string") and
          (.title | type == "string") and
          ((.executor_type == "skill_script") or (.executor_type == "shell") or (.executor_type == "remote_script")) and
          (.arguments | type == "object") and
          (.reason | type == "string") and
          (.expected_effect | type == "string") and
          ((.risk_level == "low") or (.risk_level == "medium") or (.risk_level == "high") or (.risk_level == "critical")) and
          (.rollback_hint | type == "string");
        (
          (
            .response_type == "answer" and
            (.summary | type == "string") and
            (.answer | type == "string") and
            valid_continue and
            (.continue_decision.should_continue == false) and
            valid_thinking
          ) or
          (
            .response_type == "work_plan" and
            (.summary | type == "string") and
            (.steps | type == "array") and
            (.steps | length > 0) and
            all(.steps[]?; valid_step) and
            valid_continue and
            valid_thinking
          )
        )
    ' <<<"${response_json}" >/dev/null
}

linux_agent_validate_edit_response() {
    local response_json="$1"
    jq -e '
        .response_type == "skill_edit" and
        (.skill.name | test("^[a-z0-9][a-z0-9-]*$")) and
        (.skill.description | type == "string") and
        (.scripts | type == "array") and
        (.scripts | length > 0) and
        all(.scripts[]; (.name | test("^[a-z0-9][a-z0-9-]*\\.sh$")) and (.content | type == "string") and (.description | type == "string"))
    ' <<<"${response_json}" >/dev/null
}

linux_agent_normalize_model_response() {
    local response_json="$1"
    local response_type
    response_type="$(jq -r '.response_type // empty' <<<"${response_json}")"
    if [[ "${response_type}" == "work_plan" || "${response_type}" == "answer" || "${response_type}" == "skill_edit" ]]; then
        if [[ "${response_type}" == "work_plan" ]]; then
            jq -c '
                .steps = ((.steps // []) | map(
                    if ((has("arguments") | not) or .arguments == null) then
                        .arguments = {}
                    elif (.arguments | type) == "string" then
                        .arguments = ((.arguments | fromjson? | select(type == "object")) // .arguments)
                    else
                        .
                    end
                ))
            ' <<<"${response_json}"
        else
            printf '%s\n' "${response_json}"
        fi
        return 0
    fi

    printf '%s\n' "${response_json}"
}

linux_agent_call_ai_with_context() {
    local current_request="$1"
    local request_context="$2"
    local purpose="${3:-work_plan}"
    local runtime_context
    local safe_current_request safe_request_context payload_context

    if [[ $# -gt 3 && -n "${4:-}" ]]; then
        runtime_context="$4"
    else
        runtime_context='{}'
    fi

    safe_current_request="$(linux_agent_sanitize_text "${current_request}")"
    safe_request_context="$(linux_agent_sanitize_json "${request_context}")"
    payload_context="$(linux_agent_build_ai_payload_context "${safe_request_context}" "${runtime_context}")"

    local api_url api_key model timeout_sec system_prompt payload response content
    api_url="$(linux_agent_config_get '.api_url')"
    api_key="$(linux_agent_config_api_key)"
    model="$(linux_agent_config_get '.model')"
    timeout_sec="$(linux_agent_config_get_default '.request_timeout_sec' '90')"
    system_prompt="$(linux_agent_build_system_prompt | jq -r '.')"

    if [[ -z "${api_url}" || -z "${api_key}" || -z "${model}" || "${api_key}" == "please-set-your-api-key" ]]; then
        linux_agent_ai_error "ai_config_missing" "AI 配置不完整，请配置 api_url、api_key 和 model。"
        return 0
    fi

    payload="$(jq -cn \
        --arg model "${model}" \
        --arg system_prompt "${system_prompt}" \
        --arg purpose "${purpose}" \
        --argjson request_context "${payload_context}" \
        '{
            model:$model,
            temperature:0.2,
            response_format:{type:"json_object"},
            messages:[
                {role:"system", content:$system_prompt},
                {role:"system", content:("purpose=" + $purpose)},
                {role:"system", content:("request_context=" + ($request_context | tostring))},
                {role:"user", content:$request_context.current_request}
            ]
        }')"
    LINUX_AGENT_LAST_AI_PAYLOAD="${payload}"

    if ! response="$(curl -sS --max-time "${timeout_sec:-90}" \
        -H "Authorization: Bearer ${api_key}" \
        -H "Content-Type: application/json" \
        -d "${payload}" \
        "${api_url}" 2>&1)"; then
        linux_agent_ai_error "ai_request_failed" "模型请求失败。" "${response}"
        return 0
    fi

    if ! content="$(jq -r '.choices[0].message.content // empty' <<<"${response}" 2>/dev/null)"; then
        linux_agent_ai_error "ai_invalid_response" "模型接口返回的响应不是合法 JSON。" "${response}"
        return 0
    fi
    if [[ -z "${content}" ]]; then
        local api_error
        api_error="$(jq -r '.error.message // empty' <<<"${response}" 2>/dev/null || true)"
        if [[ -n "${api_error}" ]]; then
            linux_agent_ai_error "ai_empty_response" "模型返回为空。" "${api_error}"
        else
            linux_agent_ai_error "ai_empty_response" "模型返回为空。" "${response}"
        fi
        return 0
    fi

    if ! jq -e . <<<"${content}" >/dev/null 2>&1; then
        linux_agent_ai_error "ai_invalid_json" "模型返回的 content 不是合法 JSON。" "${content}"
        return 0
    fi

    jq -c . <<<"${content}"
}
