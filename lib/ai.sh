#!/usr/bin/env bash

set -euo pipefail

LINUX_AGENT_LAST_AI_PAYLOAD=""
LINUX_AGENT_AI_FILE_MANIFEST='[]'
LINUX_AGENT_AI_RESPONSE_MAX_BYTES=1048576

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
    ' <"${prompt_file}"
}

linux_agent_record_ai_request_files() {
    local request_context="$1"
    local prompt_file="${LINUX_AGENT_ROOT}/prompts/system.txt"
    local skill_index_path relative_path

    linux_agent_record_ai_file "${prompt_file}" "system_prompt" "system_message"
    skill_index_path="$(linux_agent_skill_index_path 2>/dev/null || true)"
    [[ -n "${skill_index_path}" ]] && linux_agent_record_ai_file "${skill_index_path}" "skill_index" "system_prompt_appendix"
    while IFS= read -r relative_path; do
        [[ -n "${relative_path}" ]] || continue
        linux_agent_record_ai_file "${LINUX_AGENT_ROOT}/${relative_path}" "skill_instructions" "request_context.skills.disclosed"
    done < <(jq -r '.skills.disclosed[]?.relative_path // empty' <<<"${request_context}" 2>/dev/null || true)
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
          (
            (
              .executor_type == "skill_script" and
              (.skill_script | type == "string")
            ) or
            (
              .executor_type == "shell" and
              (.command | type == "string")
            ) or
            (
              .executor_type == "remote_script" and
              (((.url | type) == "string") or ((.command | type) == "string"))
            ) or
            (
              .executor_type == "mcp_tool" and
              (.mcp_server | type == "string") and
              (.mcp_tool | type == "string")
            )
          ) and
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
            (([.steps[].id] | length) == ([.steps[].id] | unique | length)) and
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

linux_agent_ai_normalize_provider_id() {
    local provider="$1"
    local normalized schema_file result
    normalized="$(printf '%s' "${provider,,}" | sed -E 's#[-[:space:]/]+#_#g')"

    schema_file="${LINUX_AGENT_ROOT}/schema/domain.json"
    if [[ -f "${schema_file}" ]]; then
        result="$(jq -r --arg id "${normalized}" '
            (.provider_normalization // {}) as $rules
            | ([($rules.prefix_rules // [])[] | . as $rule | select(($rule.prefix // "") != "" and ($id | startswith($rule.prefix))) | .canonical] | first) as $prefix_hit
            | ($rules.aliases // {}) as $aliases
            | if $prefix_hit != null then $prefix_hit
              elif ($aliases[$id] != null) then $aliases[$id]
              elif ($id == "") then ($aliases[""] // "openai_compatible")
              else $id end
        ' "${schema_file}" 2>/dev/null || true)"
        if [[ -n "${result}" ]]; then
            printf '%s\n' "${result}"
            return 0
        fi
    fi

    # Fallback (schema unavailable): inline equivalent of schema/domain.json.
    case "${normalized}" in
        "" | openai_compatible*)
            printf 'openai_compatible\n'
            ;;
        zhipu | zhipuai | zhipu_ai)
            printf 'zhipu_ai\n'
            ;;
        sarvam | sarvam_ai)
            printf 'sarvam_ai\n'
            ;;
        moonshot | moonshot_ai)
            printf 'moonshot_ai\n'
            ;;
        xai | x_ai)
            printf 'x_ai\n'
            ;;
        *)
            printf '%s\n' "${normalized}"
            ;;
    esac
}

linux_agent_ai_provider_id() {
    linux_agent_ai_normalize_provider_id "$(linux_agent_config_get '.provider')"
}

linux_agent_ai_validate_provider_url() {
    local api_url="$1"
    local policy_json result
    local security_script="${LINUX_AGENT_ROOT}/lib/provider_security.py"

    if [[ "${LINUX_AGENT_REMOTE_MODE:-0}" == "1" ]]; then
        policy_json="$(jq -c '(.providers_security // {}) + {require_https:true}' <<<"${LINUX_AGENT_CONFIG_JSON}")"
    else
        policy_json="$(jq -c '.providers_security // {}' <<<"${LINUX_AGENT_CONFIG_JSON}")"
    fi
    if [[ ! -f "${security_script}" ]] || ! result="$(python3 "${security_script}" validate "${api_url}" "${policy_json}" 2>/dev/null)"; then
        jq -cn '{ok:false, status:"provider_security_unavailable", error:"Provider URL security validation is unavailable."}'
        return 0
    fi
    printf '%s\n' "${result}"
}

linux_agent_ai_provider_json() {
    local provider_id="$1"
    local providers_file="${LINUX_AGENT_ROOT}/config/ai-providers.json"

    if [[ -f "${providers_file}" ]]; then
        jq -c --arg provider_id "${provider_id}" '
            (.providers // [])
            | map(select(.id == $provider_id))
            | first
            // ((.providers // []) | map(select(.id == "openai_compatible")) | first)
            // {id:"openai_compatible", auth:"bearer", request_format:"openai_chat"}
        ' "${providers_file}" 2>/dev/null && return 0
    fi

    jq -cn '{id:"openai_compatible", auth:"bearer", request_format:"openai_chat"}'
}

linux_agent_ai_build_payload() {
    local request_format="$1"
    local model="$2"
    local system_prompt="$3"
    local purpose="$4"
    local payload_context="$5"

    case "${request_format}" in
        anthropic_messages)
            jq -cn \
                --arg model "${model}" \
                --arg system_prompt "${system_prompt}" \
                --arg purpose "${purpose}" \
                --argjson request_context "${payload_context}" \
                '{
                    model:$model,
                    max_tokens:4096,
                    temperature:0.2,
                    system:($system_prompt + "\n\npurpose=" + $purpose + "\nReturn exactly one valid JSON object."),
                    messages:[
                        {
                            role:"user",
                            content:("request_context=" + ($request_context | tostring) + "\n\ncurrent_request=" + $request_context.current_request)
                        }
                    ]
                }'
            ;;
        openai_chat_no_json_mode)
            jq -cn \
                --arg model "${model}" \
                --arg system_prompt "${system_prompt}" \
                --arg purpose "${purpose}" \
                --argjson request_context "${payload_context}" \
                '{
                    model:$model,
                    temperature:0.2,
                    messages:[
                        {role:"system", content:($system_prompt + "\n\nReturn exactly one valid JSON object.")},
                        {role:"system", content:("purpose=" + $purpose)},
                        {role:"system", content:("request_context=" + ($request_context | tostring))},
                        {role:"user", content:$request_context.current_request}
                    ]
                }'
            ;;
        *)
            jq -cn \
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
                }'
            ;;
    esac
}

linux_agent_ai_response_content() {
    local request_format="$1"
    local response="$2"

    case "${request_format}" in
        anthropic_messages)
            jq -r '[.content[]? | select((.type // "text") == "text") | .text] | join("\n") // empty' <<<"${response}" 2>/dev/null
            ;;
        *)
            jq -r '.choices[0].message.content // empty' <<<"${response}" 2>/dev/null
            ;;
    esac
}

linux_agent_ai_candidates() {
    local provider_id provider_json api_url model entry key_source key_env

    provider_id="$(linux_agent_ai_provider_id)"
    provider_json="$(linux_agent_ai_provider_json "${provider_id}")"
    api_url="$(linux_agent_config_get '.api_url')"
    [[ -n "${api_url}" ]] || api_url="$(jq -r '.api_url // empty' <<<"${provider_json}")"
    model="$(linux_agent_config_get '.model')"
    [[ -n "${model}" ]] || model="$(jq -r '.default_model // empty' <<<"${provider_json}")"
    jq -cn \
        --arg role primary \
        --arg provider_id "${provider_id}" \
        --arg api_url "${api_url}" \
        --arg model "${model}" \
        --arg auth "$(jq -r '.auth // "bearer"' <<<"${provider_json}")" \
        --arg request_format "$(jq -r '.request_format // "openai_chat"' <<<"${provider_json}")" \
        '{role:$role,provider_id:$provider_id,api_url:$api_url,model:$model,auth:$auth,request_format:$request_format,key_source:"primary",api_key_env:""}'

    [[ "$(linux_agent_provider_resilience_enabled)" == "true" ]] || return 0
    while IFS= read -r entry; do
        [[ -n "${entry}" ]] || continue
        provider_id="$(linux_agent_ai_normalize_provider_id "$(jq -r '.provider' <<<"${entry}")")"
        provider_json="$(linux_agent_ai_provider_json "${provider_id}")"
        api_url="$(jq -r '.api_url // empty' <<<"${entry}")"
        [[ -n "${api_url}" ]] || api_url="$(jq -r '.api_url // empty' <<<"${provider_json}")"
        model="$(jq -r '.model // empty' <<<"${entry}")"
        [[ -n "${model}" ]] || model="$(jq -r '.default_model // empty' <<<"${provider_json}")"
        if [[ "$(jq -r '.reuse_primary_api_key // false' <<<"${entry}")" == "true" ]]; then
            key_source="primary"
            key_env=""
        else
            key_source="env"
            key_env="$(jq -r '.api_key_env // empty' <<<"${entry}")"
        fi
        jq -cn \
            --arg role failover \
            --arg provider_id "${provider_id}" \
            --arg api_url "${api_url}" \
            --arg model "${model}" \
            --arg auth "$(jq -r '.auth // "bearer"' <<<"${provider_json}")" \
            --arg request_format "$(jq -r '.request_format // "openai_chat"' <<<"${provider_json}")" \
            --arg key_source "${key_source}" \
            --arg api_key_env "${key_env}" \
            '{role:$role,provider_id:$provider_id,api_url:$api_url,model:$model,auth:$auth,request_format:$request_format,key_source:$key_source,api_key_env:$api_key_env}'
    done < <(jq -c '.provider_resilience.failover[]? // empty' <<<"${LINUX_AGENT_CONFIG_JSON}")
}

linux_agent_ai_candidate_error() {
    local provider_id="$1" status="$2" message="$3" detail="$4"
    local retryable="$5" allow_failover="$6" attempts="$7"
    jq -cn \
        --arg provider_id "${provider_id}" \
        --arg status "${status}" \
        --arg error "${message}" \
        --arg detail "$(linux_agent_sanitize_text "${detail}" 1000)" \
        --argjson retryable "${retryable}" \
        --argjson allow_failover "${allow_failover}" \
        --argjson attempts "${attempts}" \
        '{
            ok:false,
            provider_id:$provider_id,
            status:$status,
            error:$error,
            retryable:$retryable,
            allow_failover:$allow_failover,
            attempts:$attempts
        } + (if $detail == "" then {} else {detail:$detail} end)'
}

linux_agent_ai_call_candidate() {
    local candidate="$1" api_key="$2" payload="$3" timeout_sec="$4" max_attempts="$5" resilience_enabled="$6"
    local provider_id api_url auth_type request_format provider_url_check resolve_entry circuit_key allow_result
    local attempt curl_status http_status response curl_detail content api_error
    local failure_status failure_error failure_detail failure_retryable success=false
    local response_file error_file header_file failure_result
    local -a provider_url_resolve_args

    provider_id="$(jq -r '.provider_id' <<<"${candidate}")"
    api_url="$(jq -r '.api_url' <<<"${candidate}")"
    auth_type="$(jq -r '.auth' <<<"${candidate}")"
    request_format="$(jq -r '.request_format' <<<"${candidate}")"

    provider_url_check="$(linux_agent_ai_validate_provider_url "${api_url}")"
    if [[ "$(jq -r '.ok // false' <<<"${provider_url_check}")" != "true" ]]; then
        linux_agent_ai_candidate_error \
            "${provider_id}" \
            "$(jq -r '.status // "provider_security_unavailable"' <<<"${provider_url_check}")" \
            "$(jq -r '.error // "Provider URL is not allowed."' <<<"${provider_url_check}")" \
            "" false false 0
        return 0
    fi
    api_url="$(jq -r '.url' <<<"${provider_url_check}")"
    provider_url_resolve_args=()
    while IFS= read -r resolve_entry; do
        [[ -n "${resolve_entry}" ]] || continue
        provider_url_resolve_args+=(--resolve "${resolve_entry}")
    done < <(jq -r '.curl_resolve[]? // empty' <<<"${provider_url_check}")

    circuit_key="$(linux_agent_provider_circuit_key "${provider_id}" "${api_url}")"
    if [[ "${resilience_enabled}" == "true" ]]; then
        allow_result="$(linux_agent_provider_circuit_action allow "${circuit_key}")"
        if [[ "$(jq -r '.allowed // false' <<<"${allow_result}" 2>/dev/null)" != "true" ]]; then
            linux_agent_provider_resilience_event "ai_provider_circuit_open" "$(jq -cn \
                --arg provider_id "${provider_id}" \
                --arg state "$(jq -r '.state // "open"' <<<"${allow_result}" 2>/dev/null)" \
                --argjson retry_after_sec "$(jq -r '.retry_after_sec // 0' <<<"${allow_result}" 2>/dev/null)" \
                '{provider_id:$provider_id,state:$state,retry_after_sec:$retry_after_sec}')"
            linux_agent_ai_candidate_error "${provider_id}" "ai_circuit_open" \
                "AI Provider 熔断器处于开启状态。" \
                "retry_after_sec=$(jq -r '.retry_after_sec // 0' <<<"${allow_result}" 2>/dev/null)" true true 0
            return 0
        fi
        if [[ "$(jq -r '.state // "closed"' <<<"${allow_result}" 2>/dev/null)" == "half_open" ]]; then
            linux_agent_provider_resilience_event "ai_provider_circuit_probe" \
                "$(jq -cn --arg provider_id "${provider_id}" '{provider_id:$provider_id,state:"half_open"}')"
        fi
    fi

    header_file="$(mktemp "${LINUX_AGENT_TMP_DIR:-${TMPDIR:-/tmp}}/ai-headers.XXXXXX")"
    chmod 600 "${header_file}" 2>/dev/null || true
    printf '%s\n' 'Content-Type: application/json' >"${header_file}"
    case "${auth_type}" in
        anthropic)
            printf 'x-api-key: %s\nanthropic-version: 2023-06-01\n' "${api_key}" >>"${header_file}"
            ;;
        api_subscription_key)
            printf 'api-subscription-key: %s\n' "${api_key}" >>"${header_file}"
            ;;
        *)
            printf 'Authorization: Bearer %s\n' "${api_key}" >>"${header_file}"
            ;;
    esac

    for ((attempt = 1; attempt <= max_attempts; attempt++)); do
        response_file="$(mktemp "${LINUX_AGENT_TMP_DIR:-${TMPDIR:-/tmp}}/ai-response.XXXXXX")"
        error_file="$(mktemp "${LINUX_AGENT_TMP_DIR:-${TMPDIR:-/tmp}}/ai-error.XXXXXX")"
        chmod 600 "${response_file}" "${error_file}" 2>/dev/null || true
        curl_status=0
        set +e
        http_status="$(curl -q -sS --noproxy '*' --max-time "${timeout_sec:-90}" \
            --max-filesize "${LINUX_AGENT_AI_RESPONSE_MAX_BYTES}" \
            --header "@${header_file}" \
            "${provider_url_resolve_args[@]}" \
            --data-binary @- \
            --output "${response_file}" \
            --write-out '%{http_code}' \
            "${api_url}" 2>"${error_file}" <<<"${payload}")"
        curl_status=$?
        set -e
        response="$(<"${response_file}")"
        curl_detail="$(<"${error_file}")"
        rm -f "${response_file}" "${error_file}"

        success=false
        failure_status="ai_request_failed"
        failure_error="模型请求失败。"
        failure_detail="${curl_detail}"
        failure_retryable=false

        if [[ "${curl_status}" -ne 0 ]]; then
            if [[ "${curl_status}" -eq 63 ]]; then
                failure_status="ai_response_too_large"
                failure_error="模型响应超过 ${LINUX_AGENT_AI_RESPONSE_MAX_BYTES} 字节上限，已中止接收。"
            elif linux_agent_provider_curl_retryable "${curl_status}"; then
                failure_retryable=true
            fi
        elif [[ ! "${http_status}" =~ ^2[0-9]{2}$ ]]; then
            api_error="$(jq -r '.error.message // empty' <<<"${response}" 2>/dev/null || true)"
            failure_detail="${api_error:-${response}}"
            if [[ "${http_status}" == "401" || "${http_status}" == "403" ]]; then
                failure_status="ai_auth_failed"
                failure_error="AI Provider 拒绝了认证凭据。"
            else
                failure_status="ai_http_error"
                failure_error="AI Provider 返回 HTTP ${http_status:-unknown}。"
                if linux_agent_provider_http_retryable "${http_status}"; then
                    failure_retryable=true
                fi
            fi
        elif ! content="$(linux_agent_ai_response_content "${request_format}" "${response}")"; then
            failure_status="ai_invalid_response"
            failure_error="模型接口返回的响应不是合法 JSON。"
            failure_detail="${response}"
            failure_retryable=true
        elif [[ -z "${content}" ]]; then
            api_error="$(jq -r '.error.message // empty' <<<"${response}" 2>/dev/null || true)"
            failure_status="ai_empty_response"
            failure_error="模型返回为空。"
            failure_detail="${api_error:-${response}}"
            failure_retryable=true
        elif ! jq -e . <<<"${content}" >/dev/null 2>&1; then
            failure_status="ai_invalid_json"
            failure_error="模型返回的 content 不是合法 JSON。"
            failure_detail="${content}"
            failure_retryable=true
        else
            success=true
        fi

        if [[ "${success}" == "true" ]]; then
            if [[ "${resilience_enabled}" == "true" ]]; then
                linux_agent_provider_circuit_action success "${circuit_key}" >/dev/null || true
            fi
            jq -cn \
                --arg provider_id "${provider_id}" \
                --argjson attempts "${attempt}" \
                --argjson content "${content}" \
                '{ok:true,provider_id:$provider_id,attempts:$attempts,content:$content}'
            rm -f "${header_file}"
            return 0
        fi

        if [[ "${failure_retryable}" == "true" && "${resilience_enabled}" == "true" ]]; then
            failure_result="$(linux_agent_provider_circuit_action failure "${circuit_key}")"
            if [[ "$(jq -r '.state // "closed"' <<<"${failure_result}" 2>/dev/null)" == "open" ]]; then
                linux_agent_provider_resilience_event "ai_provider_circuit_opened" "$(jq -cn \
                    --arg provider_id "${provider_id}" \
                    --argjson failures "$(jq -r '.failures // 0' <<<"${failure_result}" 2>/dev/null)" \
                    '{provider_id:$provider_id,failures:$failures}')"
            fi
        fi
        if [[ "${failure_retryable}" == "true" && "${attempt}" -lt "${max_attempts}" ]]; then
            linux_agent_provider_resilience_event "ai_provider_retry" "$(jq -cn \
                --arg provider_id "${provider_id}" \
                --arg status "${failure_status}" \
                --arg http_status "${http_status:-}" \
                --argjson attempt "${attempt}" \
                --argjson next_attempt "$((attempt + 1))" \
                '{provider_id:$provider_id,status:$status,http_status:(if $http_status == "" then null else $http_status end),attempt:$attempt,next_attempt:$next_attempt}')"
            linux_agent_provider_backoff_sleep "${attempt}"
            continue
        fi

        linux_agent_ai_candidate_error "${provider_id}" "${failure_status}" "${failure_error}" \
            "${failure_detail}" "${failure_retryable}" "${failure_retryable}" "${attempt}"
        rm -f "${header_file}"
        return 0
    done
}

linux_agent_call_ai_with_context() {
    local current_request="$1"
    local request_context="$2"
    local purpose="${3:-work_plan}"
    local runtime_context
    local safe_current_request safe_request_context payload_context

    if ! linux_agent_remote_api_key_transmission_allowed; then
        linux_agent_ai_error "secret_transmission_disabled" "Remote runtime 未允许向 AI Provider 传输 API key。"
        return 0
    fi

    if [[ $# -gt 3 && -n "${4:-}" ]]; then
        runtime_context="$4"
    else
        runtime_context='{}'
    fi

    safe_current_request="$(linux_agent_sanitize_text "${current_request}")"
    safe_request_context="$(linux_agent_sanitize_json "${request_context}")"
    payload_context="$(linux_agent_build_ai_payload_context "${safe_request_context}" "${runtime_context}")"
    payload_context="$(jq -c --arg current_request "${safe_current_request}" '.current_request = $current_request' <<<"${payload_context}")"

    local primary_api_key timeout_sec system_prompt resilience_enabled max_attempts
    local candidate candidate_result api_key key_source key_env api_url model request_format payload
    local last_result='' attempted=0 candidate_index=0
    local -a candidates

    primary_api_key="$(linux_agent_config_api_key)"
    timeout_sec="$(linux_agent_config_get_default '.request_timeout_sec' '90')"
    system_prompt="$(linux_agent_build_system_prompt | jq -r '.')"
    resilience_enabled="$(linux_agent_provider_resilience_enabled)"
    if [[ "${resilience_enabled}" == "true" ]]; then
        max_attempts="$(linux_agent_provider_resilience_int max_attempts 3 1 5)"
    else
        max_attempts=1
    fi
    mapfile -t candidates < <(linux_agent_ai_candidates)

    for candidate in "${candidates[@]}"; do
        key_source="$(jq -r '.key_source' <<<"${candidate}")"
        key_env="$(jq -r '.api_key_env' <<<"${candidate}")"
        api_url="$(jq -r '.api_url' <<<"${candidate}")"
        model="$(jq -r '.model' <<<"${candidate}")"
        request_format="$(jq -r '.request_format' <<<"${candidate}")"
        if [[ "${key_source}" == "env" ]]; then
            api_key="${!key_env-}"
        else
            api_key="${primary_api_key}"
        fi

        if [[ -z "${api_url}" || -z "${api_key}" || -z "${model}" ||
            "${api_key}" == *$'\n'* || "${api_key}" == *$'\r'* ]] ||
            linux_agent_config_api_key_placeholder "${api_key}"; then
            if [[ "$(jq -r '.role' <<<"${candidate}")" == "primary" ]]; then
                linux_agent_ai_error "ai_config_missing" "AI 配置不完整，请配置 api_url、api_key 和 model。"
                return 0
            fi
            linux_agent_provider_resilience_event "ai_provider_failover_skipped" "$(jq -cn \
                --arg provider_id "$(jq -r '.provider_id' <<<"${candidate}")" \
                --arg reason "candidate_config_missing" \
                '{provider_id:$provider_id,reason:$reason}')"
            candidate_index=$((candidate_index + 1))
            continue
        fi

        payload="$(linux_agent_ai_build_payload "${request_format}" "${model}" "${system_prompt}" "${purpose}" "${payload_context}")"
        # Sourced callers inspect this for secret-leakage assertions. It contains
        # request data but never authentication material.
        # shellcheck disable=SC2034
        LINUX_AGENT_LAST_AI_PAYLOAD="${payload}"
        attempted=$((attempted + 1))
        candidate_result="$(linux_agent_ai_call_candidate \
            "${candidate}" "${api_key}" "${payload}" "${timeout_sec}" "${max_attempts}" "${resilience_enabled}")"
        if [[ "$(jq -r '.ok // false' <<<"${candidate_result}")" == "true" ]]; then
            jq -c '.content' <<<"${candidate_result}"
            return 0
        fi
        last_result="${candidate_result}"

        if [[ "$(jq -r '.allow_failover // false' <<<"${candidate_result}")" != "true" ]]; then
            linux_agent_ai_error \
                "$(jq -r '.status // "ai_request_failed"' <<<"${candidate_result}")" \
                "$(jq -r '.error // "模型请求失败。"' <<<"${candidate_result}")" \
                "$(jq -r '.detail // empty' <<<"${candidate_result}")"
            return 0
        fi
        if [[ "${candidate_index}" -lt "$((${#candidates[@]} - 1))" ]]; then
            linux_agent_provider_resilience_event "ai_provider_failover" "$(jq -cn \
                --arg from_provider "$(jq -r '.provider_id' <<<"${candidate}")" \
                --arg status "$(jq -r '.status' <<<"${candidate_result}")" \
                --argjson attempts "$(jq -r '.attempts // 0' <<<"${candidate_result}")" \
                '{from_provider:$from_provider,status:$status,attempts:$attempts}')"
        fi
        candidate_index=$((candidate_index + 1))
    done

    if [[ -n "${last_result}" && "${#candidates[@]}" -le 1 ]]; then
        linux_agent_ai_error \
            "$(jq -r '.status // "ai_request_failed"' <<<"${last_result}")" \
            "$(jq -r '.error // "模型请求失败。"' <<<"${last_result}")" \
            "$(jq -r '.detail // empty' <<<"${last_result}")"
    elif [[ -n "${last_result}" ]]; then
        linux_agent_ai_error "ai_failover_exhausted" "所有已配置的 AI Provider 均调用失败。" \
            "last_provider=$(jq -r '.provider_id // "unknown"' <<<"${last_result}"); last_status=$(jq -r '.status // "ai_request_failed"' <<<"${last_result}"); attempted=${attempted}"
    else
        linux_agent_ai_error "ai_config_missing" "没有可用的 AI Provider 配置。"
    fi
}
