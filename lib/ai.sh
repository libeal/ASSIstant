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

linux_agent_mock_work_plan() {
    local user_input="$1"
    if [[ "${user_input}" == *"失败"* ]]; then
        jq -cn '
            {
              response_type:"work_plan",
              summary:"演示失败中断：先执行一个会失败的命令，随后计划中的步骤应被标记为未执行。",
              steps:[
                {
                  id:"step-1",
                  title:"执行失败演示命令",
                  executor_type:"shell",
                  command:"false",
                  arguments:{},
                  reason:"用于验证失败后中断和修复计划请求。",
                  expected_effect:"命令返回非 0，当前计划中断。",
                  risk_level:"low",
                  rollback_hint:"无需回滚。"
                },
                {
                  id:"step-2",
                  title:"不应执行的后续步骤",
                  executor_type:"skill_script",
                  skill_script:"ops-basic/process-inspect",
                  arguments:{pattern:"systemd"},
                  reason:"验证未执行步骤状态。",
                  expected_effect:"该步骤不应展示执行。",
                  risk_level:"low",
                  rollback_hint:"无需回滚。"
                }
              ]
            }
        '
    elif [[ "${user_input}" == *"cpu"* || "${user_input}" == *"CPU"* || "${user_input}" == *"内存"* || "${user_input}" == *"memory"* || "${user_input}" == *"资源"* || "${user_input}" == *"负载"* ]]; then
        jq -cn '
            {
              response_type:"work_plan",
              summary:"使用受控资源检查 skill 查看 CPU、内存与高占用进程。",
              steps:[
                {
                  id:"step-1",
                  title:"查看 CPU 与内存资源概况",
                  executor_type:"skill_script",
                  skill_script:"ops-basic/resource-inspect",
                  arguments:{top_n:10},
                  reason:"通过受控只读 skill 采集 CPU 负载、内存使用和高占用进程，避免自由拼接 shell。",
                  expected_effect:"返回 CPU/内存概况和资源占用最高的进程列表。",
                  risk_level:"low",
                  rollback_hint:"只读操作，无需回滚。"
                }
              ]
            }
        '
    elif [[ "${user_input}" == *"磁盘"* || "${user_input}" == *"垃圾"* || "${user_input}" == *"日志"* ]]; then
        jq -cn '
            {
              response_type:"work_plan",
              summary:"先只读检查磁盘热点和日志候选，再由用户决定是否继续清理。",
              steps:[
                {
                  id:"step-1",
                  title:"检查磁盘热点",
                  executor_type:"skill_script",
                  skill_script:"ops-basic/disk-hotspots",
                  arguments:{path:"/var", top_n:10},
                  reason:"定位大目录和大文件，避免盲目清理。",
                  expected_effect:"返回 /var 下磁盘占用和日志热点摘要。",
                  risk_level:"low",
                  rollback_hint:"只读操作，无需回滚。"
                },
                {
                  id:"step-2",
                  title:"生成日志清理候选",
                  executor_type:"skill_script",
                  skill_script:"ops-basic/log-cleanup-plan",
                  arguments:{root_path:"/var/log", min_size_mb:100, max_depth:2, limit:20},
                  reason:"识别可清理日志并排除关键日志。",
                  expected_effect:"返回候选文件、排除原因和建议清理方式。",
                  risk_level:"medium",
                  rollback_hint:"只读扫描，无需回滚。"
                }
              ]
            }
        '
    else
        jq -cn --arg input "${user_input}" '
            {
              response_type:"answer",
              summary:"测试模式下直接返回问答响应。",
              answer:("已收到请求：" + $input),
              steps:[]
            }
        '
    fi
}

linux_agent_mock_edit_package() {
    local user_input="$1"
    jq -cn --arg request "${user_input}" '
        {
          response_type:"skill_edit",
          skill:{
            name:"custom-generated",
            description:"根据用户需求生成的本地运维辅助 skill。"
          },
          scripts:[
            {
              name:"generated.sh",
              description:"输出当前请求摘要，作为可审批脚本模板。",
              content:"#/usr/bin/env bash\nset -euo pipefail\nargs=\"${1:-}\"\n[[ -z \"${args}\" ]] && args='\''{}'\''\nprintf '\''{\"ok\":true,\"tool\":\"custom-generated/generated\",\"args\":%s,\"note\":\"generated skill placeholder\"}\\n'\'' \"${args}\"\n"
            }
          ],
          notes:("mock edit package for: " + $request)
        }
    ' | sed 's/#\/usr/#!\/usr/'
}

linux_agent_mock_repair_plan() {
    local failure_context="$1"
    jq -cn --arg context "${failure_context}" '
        {
          response_type:"work_plan",
          summary:"当前计划执行失败。建议先保留现场日志，检查失败输出，再重新生成更保守的诊断步骤；该修复计划不会自动执行。",
          steps:[
            {
              id:"repair-1",
              title:"检查失败输出",
              executor_type:"shell",
              command:"printf %s \"$FAILURE_CONTEXT\"",
              arguments:{},
              reason:"让用户根据失败上下文做人工判断。",
              expected_effect:"展示失败上下文摘要。",
              risk_level:"low",
              rollback_hint:"无需回滚。"
            }
          ],
          failure_context:$context
        }
    '
}

linux_agent_validate_work_response() {
    local response_json="$1"
    jq -e '
        (
          (.response_type == "answer" and (.summary | type == "string") and (.answer | type == "string")) or
          (
            .response_type == "work_plan" and
            (.summary | type == "string") and
            (.steps | type == "array") and
            all(.steps[]?;
              (.id | type == "string") and
              (.title | type == "string") and
              ((.executor_type == "skill_script") or (.executor_type == "shell") or (.executor_type == "remote_script")) and
              (.reason | type == "string") and
              (.expected_effect | type == "string") and
              ((.risk_level == "low") or (.risk_level == "medium") or (.risk_level == "high") or (.risk_level == "critical")) and
              (.rollback_hint | type == "string")
            )
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
        printf '%s\n' "${response_json}"
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

    if [[ "${LINUX_AGENT_MOCK:-0}" == "1" ]]; then
        case "${purpose}" in
            edit)
                linux_agent_mock_edit_package "${safe_current_request}"
                ;;
            repair)
                linux_agent_mock_repair_plan "${payload_context}"
                ;;
            *)
                linux_agent_mock_work_plan "${safe_current_request}"
                ;;
        esac
        return 0
    fi

    local api_url api_key model timeout_sec system_prompt payload response content
    api_url="$(linux_agent_config_get '.api_url')"
    api_key="$(linux_agent_config_get '.api_key')"
    model="$(linux_agent_config_get '.model')"
    timeout_sec="$(linux_agent_config_get_default '.request_timeout_sec' '90')"
    system_prompt="$(linux_agent_build_system_prompt | jq -r '.')"

    if [[ -z "${api_url}" || -z "${api_key}" || -z "${model}" || "${api_key}" == "please-set-your-api-key" ]]; then
        linux_agent_print_warn "配置不完整，自动进入 Mock 模式。"
        case "${purpose}" in
            edit) linux_agent_mock_edit_package "${safe_current_request}" ;;
            repair) linux_agent_mock_repair_plan "${payload_context}" ;;
            *) linux_agent_mock_work_plan "${safe_current_request}" ;;
        esac
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
        "${api_url}")"; then
        linux_agent_print_warn "模型请求失败，改用 Mock 响应兜底。"
        case "${purpose}" in
            edit) linux_agent_mock_edit_package "${safe_current_request}" ;;
            repair) linux_agent_mock_repair_plan "${payload_context}" ;;
            *) linux_agent_mock_work_plan "${safe_current_request}" ;;
        esac
        return 0
    fi

    content="$(jq -r '.choices[0].message.content // empty' <<<"${response}")"
    if [[ -z "${content}" ]]; then
        linux_agent_print_warn "模型返回为空，改用 Mock 响应兜底。"
        case "${purpose}" in
            edit) linux_agent_mock_edit_package "${safe_current_request}" ;;
            repair) linux_agent_mock_repair_plan "${payload_context}" ;;
            *) linux_agent_mock_work_plan "${safe_current_request}" ;;
        esac
        return 0
    fi

    if ! jq -e . <<<"${content}" >/dev/null 2>&1; then
        linux_agent_print_warn "模型 JSON 内容无效，改用 Mock 响应兜底。"
        case "${purpose}" in
            edit) linux_agent_mock_edit_package "${safe_current_request}" ;;
            repair) linux_agent_mock_repair_plan "${payload_context}" ;;
            *) linux_agent_mock_work_plan "${safe_current_request}" ;;
        esac
        return 0
    fi

    jq -c . <<<"${content}"
}
