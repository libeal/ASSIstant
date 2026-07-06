#!/usr/bin/env bash

set -euo pipefail

linux_agent_mcp_dir() {
    printf '%s\n' "${LINUX_AGENT_MCP_DIR:-${LINUX_AGENT_ROOT}/mcp}"
}

linux_agent_mcp_client_path() {
    local path="${LINUX_AGENT_ROOT}/lib/mcp_client.py"
    if [[ -f "${path}" ]]; then
        printf '%s\n' "${path}"
        return 0
    fi
    path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/mcp_client.py"
    [[ -f "${path}" ]] || return 1
    printf '%s\n' "${path}"
}

linux_agent_mcp_manifest_paths() {
    local mcp_dir
    mcp_dir="$(linux_agent_mcp_dir)"
    mkdir -p "${mcp_dir}"
    find "${mcp_dir}" -mindepth 2 -maxdepth 2 -type f -name 'mcp.json' 2>/dev/null | sort
}

linux_agent_mcp_manifest_path_by_id() {
    local server_id="$1"
    local path manifest_id

    [[ "${server_id}" =~ ^[a-z0-9][a-z0-9_.-]*$ ]] || return 1
    while IFS= read -r path; do
        [[ -n "${path}" ]] || continue
        manifest_id="$(jq -r 'if type == "object" and (.id | type) == "string" then .id else "" end' "${path}" 2>/dev/null || true)"
        if [[ "${manifest_id}" == "${server_id}" ]]; then
            printf '%s\n' "${path}"
            return 0
        fi
    done < <(linux_agent_mcp_manifest_paths)
    return 1
}

linux_agent_mcp_append_finding() {
    local prior="$1"
    local severity="$2"
    local code="$3"
    local path="$4"
    local message="$5"
    local server_id="${6:-}"

    jq -cn \
        --argjson prior "${prior}" \
        --arg severity "${severity}" \
        --arg code "${code}" \
        --arg path "${path}" \
        --arg message "${message}" \
        --arg server_id "${server_id}" \
        '$prior + [{severity:$severity, code:$code, path:$path, server_id:$server_id, message:$message} | with_entries(select(.value != ""))]'
}

linux_agent_mcp_public_manifest() {
    local manifest_json="$1"
    jq -c '
        def secret_key:
            test("(?i)(authorization|cookie|token|secret|password|passwd|api[_-]?key|credential|private[_-]?key)");
        def redact:
            if type == "object" then
                with_entries(.value = (if (.key | secret_key) then "[REDACTED]" else (.value | redact) end))
            elif type == "array" then
                map(redact)
            else
                .
            end;
        redact
    ' <<<"${manifest_json}"
}

linux_agent_mcp_http_url_valid() {
    local value="$1"
    [[ "${value}" =~ ^https?://[^[:space:]/?#]+([^[:space:]]*)?$ ]]
}

linux_agent_mcp_validate_manifest_path() {
    local path="$1"
    local mcp_dir rel payload payload_type findings server_id transport enabled url message_url
    mcp_dir="$(linux_agent_mcp_dir)"
    rel="${path#${mcp_dir%/}/}"
    findings='[]'

    if ! payload="$(jq -c . "${path}" 2>/dev/null)"; then
        findings="$(linux_agent_mcp_append_finding "${findings}" "critical" "MCP_MANIFEST_INVALID_JSON" "${rel}" "mcp.json 不是合法 JSON。")"
        jq -cn --arg path "${rel}" --argjson ok false --argjson findings "${findings}" '{ok:$ok, path:$path, findings:$findings}'
        return 0
    fi

    payload_type="$(jq -r 'type' <<<"${payload}")"
    if [[ "${payload_type}" != "object" ]]; then
        findings="$(linux_agent_mcp_append_finding "${findings}" "critical" "MCP_MANIFEST_NOT_OBJECT" "${rel}" "mcp.json 必须是 JSON object。")"
        jq -cn \
            --arg path "${rel}" \
            --arg id "" \
            --arg transport "" \
            --argjson findings "${findings}" \
            '{ok:false, path:$path, id:$id, transport:$transport, findings:$findings}'
        return 0
    fi

    server_id="$(jq -r 'if (.id | type) == "string" then .id else "" end' <<<"${payload}")"
    if ! jq -e '(.id | type) == "string"' <<<"${payload}" >/dev/null || [[ ! "${server_id}" =~ ^[a-z0-9][a-z0-9_.-]*$ ]]; then
        findings="$(linux_agent_mcp_append_finding "${findings}" "critical" "MCP_ID_INVALID" "${rel}" "MCP server id 必须是字符串，且匹配 ^[a-z0-9][a-z0-9_.-]*$。" "${server_id}")"
    fi

    transport="$(jq -r 'if (.transport | type) == "string" then .transport else "" end' <<<"${payload}")"
    case "${transport}" in
        stdio|sse|streamable_http)
            ;;
        *)
            findings="$(linux_agent_mcp_append_finding "${findings}" "critical" "MCP_TRANSPORT_INVALID" "${rel}" "transport 必须是字符串 stdio、sse 或 streamable_http。" "${server_id}")"
            ;;
    esac

    enabled="$(jq -r 'if has("enabled") then (.enabled | type) else "missing" end' <<<"${payload}")"
    if [[ "${enabled}" != "missing" && "${enabled}" != "boolean" ]]; then
        findings="$(linux_agent_mcp_append_finding "${findings}" "critical" "MCP_ENABLED_INVALID" "${rel}" "enabled 必须是 boolean。" "${server_id}")"
    fi

    case "${transport}" in
        stdio)
            if ! jq -e '(.command | type) == "string" and (.command | length) > 0' <<<"${payload}" >/dev/null; then
                findings="$(linux_agent_mcp_append_finding "${findings}" "critical" "MCP_STDIO_COMMAND_MISSING" "${rel}" "stdio transport 必须配置非空字符串 command。" "${server_id}")"
            fi
            if ! jq -e '(.args == null) or ((.args | type) == "array" and all(.args[]; type == "string"))' <<<"${payload}" >/dev/null; then
                findings="$(linux_agent_mcp_append_finding "${findings}" "critical" "MCP_STDIO_ARGS_INVALID" "${rel}" "stdio args 必须是字符串数组。" "${server_id}")"
            fi
            if ! jq -e '(.env == null) or ((.env | type) == "object" and all(.env[]; type == "string"))' <<<"${payload}" >/dev/null; then
                findings="$(linux_agent_mcp_append_finding "${findings}" "critical" "MCP_STDIO_ENV_INVALID" "${rel}" "stdio env 必须是字符串值 object。" "${server_id}")"
            fi
            ;;
        sse)
            url="$(jq -r '.url // empty' <<<"${payload}")"
            if ! linux_agent_mcp_http_url_valid "${url}"; then
                findings="$(linux_agent_mcp_append_finding "${findings}" "critical" "MCP_SSE_URL_INVALID" "${rel}" "sse transport 必须配置 http(s) url。" "${server_id}")"
            fi
            message_url="$(jq -r '.message_url // empty' <<<"${payload}")"
            if [[ -n "${message_url}" ]] && ! linux_agent_mcp_http_url_valid "${message_url}"; then
                findings="$(linux_agent_mcp_append_finding "${findings}" "critical" "MCP_SSE_MESSAGE_URL_INVALID" "${rel}" "sse message_url 必须是 http(s) URL。" "${server_id}")"
            fi
            if ! jq -e '(.headers == null) or ((.headers | type) == "object" and all(.headers[]; type == "string"))' <<<"${payload}" >/dev/null; then
                findings="$(linux_agent_mcp_append_finding "${findings}" "critical" "MCP_HTTP_HEADERS_INVALID" "${rel}" "headers 必须是字符串值 object。" "${server_id}")"
            fi
            ;;
        streamable_http)
            url="$(jq -r '.url // empty' <<<"${payload}")"
            if ! linux_agent_mcp_http_url_valid "${url}"; then
                findings="$(linux_agent_mcp_append_finding "${findings}" "critical" "MCP_STREAMABLE_HTTP_URL_INVALID" "${rel}" "streamable_http transport 必须配置单一 http(s) MCP endpoint。" "${server_id}")"
            fi
            if ! jq -e '(.headers == null) or ((.headers | type) == "object" and all(.headers[]; type == "string"))' <<<"${payload}" >/dev/null; then
                findings="$(linux_agent_mcp_append_finding "${findings}" "critical" "MCP_HTTP_HEADERS_INVALID" "${rel}" "headers 必须是字符串值 object。" "${server_id}")"
            fi
            ;;
    esac

    jq -cn \
        --arg path "${rel}" \
        --arg id "${server_id}" \
        --arg transport "${transport}" \
        --argjson findings "${findings}" \
        '{
            ok:(($findings | length) == 0),
            path:$path,
            id:$id,
            transport:$transport,
            findings:$findings
        }'
}

linux_agent_mcp_server_summary() {
    local path="$1"
    local mcp_dir rel payload payload_type validation public server_id transport name description enabled
    mcp_dir="$(linux_agent_mcp_dir)"
    rel="${path#${mcp_dir%/}/}"
    validation="$(linux_agent_mcp_validate_manifest_path "${path}")"

    if ! payload="$(jq -c . "${path}" 2>/dev/null)"; then
        payload='{}'
    fi
    public="$(linux_agent_mcp_public_manifest "${payload}")"
    payload_type="$(jq -r 'type' <<<"${payload}")"
    if [[ "${payload_type}" == "object" ]]; then
        server_id="$(jq -r 'if (.id | type) == "string" then .id else "" end' <<<"${payload}")"
        transport="$(jq -r 'if (.transport | type) == "string" then .transport else "" end' <<<"${payload}")"
        name="$(jq -r 'if (.name | type) == "string" then .name elif (.id | type) == "string" then .id else "" end' <<<"${payload}")"
        description="$(jq -r 'if (.description | type) == "string" then .description else "" end' <<<"${payload}")"
        enabled="$(jq -r '.enabled // true' <<<"${payload}")"
    else
        server_id="${rel%/mcp.json}"
        transport=""
        name="${server_id}"
        description=""
        enabled="true"
    fi
    if [[ "${enabled}" != "false" ]]; then
        enabled="true"
    fi

    jq -cn \
        --arg id "${server_id}" \
        --arg name "${name}" \
        --arg description "${description}" \
        --arg transport "${transport}" \
        --arg path "${rel}" \
        --argjson enabled "${enabled}" \
        --argjson config "${public}" \
        --argjson validation "${validation}" \
        '{
            id:$id,
            name:$name,
            description:$description,
            transport:$transport,
            enabled:$enabled,
            path:$path,
            valid:($validation.ok // false),
            config:$config,
            findings:($validation.findings // [])
        }'
}

linux_agent_validate_mcp() {
    local paths path findings validation ok mcp_dir
    mcp_dir="$(linux_agent_mcp_dir)"
    mkdir -p "${mcp_dir}"
    findings='[]'
    ok=true

    while IFS= read -r path; do
        [[ -n "${path}" ]] || continue
        validation="$(linux_agent_mcp_validate_manifest_path "${path}")"
        if [[ "$(jq -r '.ok // false' <<<"${validation}")" != "true" ]]; then
            ok=false
        fi
        findings="$(jq -cn --argjson prior "${findings}" --argjson next "$(jq -c '.findings // []' <<<"${validation}")" '$prior + $next')"
    done < <(linux_agent_mcp_manifest_paths)

    jq -cn \
        --argjson ok "${ok}" \
        --arg root "${mcp_dir}" \
        --argjson findings "${findings}" \
        '{ok:$ok, root:$root, findings:$findings}'
}

linux_agent_mcp_list() {
    local mcp_dir servers path server validation
    mcp_dir="$(linux_agent_mcp_dir)"
    mkdir -p "${mcp_dir}"
    servers='[]'

    while IFS= read -r path; do
        [[ -n "${path}" ]] || continue
        server="$(linux_agent_mcp_server_summary "${path}")"
        servers="$(jq -cn --argjson prior "${servers}" --argjson server "${server}" '$prior + [$server]')"
    done < <(linux_agent_mcp_manifest_paths)

    validation="$(linux_agent_validate_mcp)"
    jq -cn \
        --arg root "${mcp_dir}" \
        --argjson servers "${servers}" \
        --argjson validation "${validation}" \
        '{
            ok:true,
            status:"listed",
            root:$root,
            servers:$servers,
            findings:($validation.findings // [])
        }'
}

linux_agent_mcp_python_client_error() {
    local status="$1"
    local raw="$2"
    jq -cn \
        --arg status "${status}" \
        --arg raw "$(linux_agent_sanitize_text "${raw}" 2000)" \
        '{ok:false, status:$status, error:$raw}'
}

linux_agent_mcp_server_tools_from_path() {
    local path="$1"
    local validation output client

    validation="$(linux_agent_mcp_validate_manifest_path "${path}")"
    if [[ "$(jq -r '.ok // false' <<<"${validation}")" != "true" ]]; then
        jq -cn --argjson validation "${validation}" \
            '{ok:false, status:"invalid_manifest", validation:$validation, tools:[]}'
        return 0
    fi
    if ! client="$(linux_agent_mcp_client_path)"; then
        jq -cn '{ok:false, status:"mcp_client_unavailable", error:"lib/mcp_client.py 不存在。", tools:[]}'
        return 0
    fi
    if output="$(python3 "${client}" list-tools "${path}" 2>&1)"; then
        if jq -e 'type == "object"' >/dev/null 2>&1 <<<"${output}"; then
            printf '%s\n' "${output}"
        else
            linux_agent_mcp_python_client_error "mcp_client_invalid_output" "${output}"
        fi
    else
        if jq -e 'type == "object"' >/dev/null 2>&1 <<<"${output}"; then
            printf '%s\n' "${output}"
        else
            linux_agent_mcp_python_client_error "mcp_client_failed" "${output}"
        fi
    fi
}

linux_agent_mcp_tool_list_finding() {
    local findings="$1"
    local server_id="$2"
    local path="$3"
    local error="$4"
    linux_agent_mcp_append_finding \
        "${findings}" \
        "medium" \
        "MCP_TOOL_LIST_FAILED" \
        "${path}" \
        "MCP server tools/list 失败：${error}" \
        "${server_id}"
}

linux_agent_mcp_tool_catalog() {
    local mcp_dir servers tools findings path server enabled valid tools_result server_tools server_info error
    mcp_dir="$(linux_agent_mcp_dir)"
    mkdir -p "${mcp_dir}"
    servers='[]'
    tools='[]'
    findings='[]'

    while IFS= read -r path; do
        [[ -n "${path}" ]] || continue
        server="$(linux_agent_mcp_server_summary "${path}")"
        findings="$(jq -cn \
            --argjson prior "${findings}" \
            --argjson next "$(jq -c '.findings // []' <<<"${server}")" \
            '$prior + $next')"
        enabled="$(jq -r '.enabled // true' <<<"${server}")"
        valid="$(jq -r '.valid // false' <<<"${server}")"
        server_tools='[]'
        server_info='{}'

        if [[ "${enabled}" == "true" && "${valid}" == "true" ]]; then
            tools_result="$(linux_agent_mcp_server_tools_from_path "${path}")"
            if [[ "$(jq -r '.ok // false' <<<"${tools_result}")" == "true" ]]; then
                server_tools="$(jq -c '.tools // [] | if type == "array" then . else [] end' <<<"${tools_result}")"
                server_tools="$(linux_agent_mcp_public_manifest "${server_tools}")"
                server_info="$(jq -c '.server_info // {} | if type == "object" then . else {} end' <<<"${tools_result}")"
            else
                error="$(jq -r '.error // .status // "unknown"' <<<"${tools_result}")"
                findings="$(linux_agent_mcp_tool_list_finding \
                    "${findings}" \
                    "$(jq -r '.id // ""' <<<"${server}")" \
                    "$(jq -r '.path // ""' <<<"${server}")" \
                    "${error}")"
            fi
        fi

        server="$(jq -c \
            --argjson tool_list "${server_tools}" \
            --argjson server_info "${server_info}" \
            '. + {tools:$tool_list, tool_count:($tool_list | length), server_info:$server_info}' \
            <<<"${server}")"
        tools="$(jq -cn \
            --argjson prior "${tools}" \
            --argjson server "${server}" \
            --argjson tool_list "${server_tools}" \
            '
            $prior + [
              $tool_list[]?
              | {
                  server_id:($server.id // ""),
                  server_name:($server.name // ""),
                  transport:($server.transport // ""),
                  name:(.name // ""),
                  ref:(($server.id // "") + "/" + (.name // "")),
                  description:(.description // ""),
                  inputSchema:(.inputSchema // {}),
                  annotations:(.annotations // {}),
                  outputSchema:(.outputSchema // null)
                }
              | with_entries(select(.value != null))
            ]')"
        servers="$(jq -cn --argjson prior "${servers}" --argjson server "${server}" '$prior + [$server]')"
    done < <(linux_agent_mcp_manifest_paths)

    findings="$(jq -c 'unique_by([.code, (.server_id // ""), (.path // ""), (.message // "")])' <<<"${findings}")"
    jq -cn \
        --arg root "${mcp_dir}" \
        --argjson servers "${servers}" \
        --argjson tools "${tools}" \
        --argjson findings "${findings}" \
        '{
            ok:true,
            status:"listed",
            root:$root,
            server_count:($servers | length),
            tool_count:($tools | length),
            servers:$servers,
            tools:$tools,
            findings:$findings
        }'
}

linux_agent_mcp_tool_metadata() {
    local server_id="$1"
    local tool_name="$2"
    local path result

    if ! path="$(linux_agent_mcp_manifest_path_by_id "${server_id}")"; then
        jq -cn --arg server_id "${server_id}" --arg tool "${tool_name}" \
            '{ok:false, status:"server_not_found", server_id:$server_id, tool:$tool}'
        return 0
    fi
    result="$(linux_agent_mcp_server_tools_from_path "${path}")"
    if [[ "$(jq -r '.ok // false' <<<"${result}")" != "true" ]]; then
        jq -c --arg server_id "${server_id}" --arg tool "${tool_name}" \
            '. + {server_id:$server_id, tool:$tool}' <<<"${result}"
        return 0
    fi
    jq -cn \
        --arg server_id "${server_id}" \
        --arg tool "${tool_name}" \
        --argjson result "${result}" \
        '
        ($result.tools // [])
        | map(select(.name == $tool))
        | first as $found
        | if $found == null then
            {ok:false, status:"tool_not_found", server_id:$server_id, tool:$tool}
          else
            {ok:true, status:"found", server_id:$server_id, tool:$tool, metadata:$found}
          end'
}

linux_agent_mcp_tool_is_available() {
    local server_id="$1"
    local tool_name="$2"
    local metadata

    metadata="$(linux_agent_mcp_tool_metadata "${server_id}" "${tool_name}")"
    [[ "$(jq -r '.ok // false' <<<"${metadata}")" == "true" ]]
}

linux_agent_mcp_call_tool() {
    local server_id="$1"
    local tool_name="$2"
    local args_json="${3:-}"
    local path args client tmp_dir args_file output status
    [[ -n "${args_json}" ]] || args_json='{}'

    if ! path="$(linux_agent_mcp_manifest_path_by_id "${server_id}")"; then
        jq -cn --arg server_id "${server_id}" --arg tool "${tool_name}" \
            '{ok:false, status:"server_not_found", error:"MCP server 未安装或未启用。", server_id:$server_id, tool:$tool}'
        return 0
    fi
    if ! linux_agent_mcp_tool_is_available "${server_id}" "${tool_name}"; then
        jq -cn --arg server_id "${server_id}" --arg tool "${tool_name}" \
            '{ok:false, status:"tool_not_found", error:"MCP tool 未在该 server tools/list 中声明。", server_id:$server_id, tool:$tool}'
        return 0
    fi
    if ! args="$(linux_agent_normalize_json_object_argument "${args_json}")"; then
        jq -cn --arg server_id "${server_id}" --arg tool "${tool_name}" \
            '{ok:false, status:"invalid_arguments", error:"MCP tool arguments 必须是 JSON object。", server_id:$server_id, tool:$tool}'
        return 0
    fi
    if ! client="$(linux_agent_mcp_client_path)"; then
        jq -cn '{ok:false, status:"mcp_client_unavailable", error:"lib/mcp_client.py 不存在。"}'
        return 0
    fi

    tmp_dir="${LINUX_AGENT_TMP_DIR:-/tmp}"
    mkdir -p "${tmp_dir}"
    args_file="$(mktemp "${tmp_dir}/mcp.args.XXXXXX")"
    chmod 600 "${args_file}" 2>/dev/null || true
    printf '%s\n' "${args}" > "${args_file}"
    status=0
    output="$(python3 "${client}" call-tool "${path}" "${tool_name}" "${args_file}" 2>&1)" || status=$?
    rm -f "${args_file}"
    if [[ "${status}" -eq 0 || "$(jq -r '.ok // false' <<<"${output}" 2>/dev/null || printf false)" == "false" ]]; then
        if jq -e 'type == "object"' >/dev/null 2>&1 <<<"${output}"; then
            printf '%s\n' "${output}"
        else
            linux_agent_mcp_python_client_error "mcp_client_invalid_output" "${output}"
        fi
    else
        linux_agent_mcp_python_client_error "mcp_client_failed" "${output}"
    fi
    return 0
}

linux_agent_mcp_step_review_material() {
    local step_json="$1"
    local server_id tool_name args metadata
    server_id="$(jq -r '.mcp_server // empty' <<<"${step_json}")"
    tool_name="$(jq -r '.mcp_tool // empty' <<<"${step_json}")"
    args="$(linux_agent_step_arguments_json "${step_json}")"
    metadata="$(linux_agent_mcp_tool_metadata "${server_id}" "${tool_name}")"
    jq -nr \
        --arg server_id "${server_id}" \
        --arg tool "${tool_name}" \
        --argjson arguments "${args}" \
        --argjson metadata "${metadata}" \
        '"mcp_tool=\($server_id)/\($tool)\narguments=\($arguments | tojson)\nmetadata=\($metadata | tojson)"'
}

linux_agent_mcp_context_json() {
    local mode="${1:-work}"
    local catalog

    case "${mode}" in
        work|work_revision|work_reflect|edit|edit_revision)
            ;;
        *)
            jq -cn '{enabled:false, reason:"mcp is exposed only in work/edit modes", tools:[], findings:[]}'
            return 0
            ;;
    esac

    catalog="$(linux_agent_mcp_tool_catalog)"
    jq -c '
        {
            enabled:true,
            root:(.root // ""),
            server_count:(.server_count // 0),
            tool_count:(.tool_count // 0),
            servers:[(.servers // [])[] | {
                id:(.id // ""),
                name:(.name // ""),
                description:(.description // ""),
                transport:(.transport // ""),
                enabled:(.enabled // true),
                valid:(.valid // false),
                tool_count:(.tool_count // 0),
                findings:(.findings // [])
            }],
            tools:[(.tools // [])[] | {
                ref:(.ref // ""),
                server_id:(.server_id // ""),
                server_name:(.server_name // ""),
                transport:(.transport // ""),
                name:(.name // ""),
                description:(.description // ""),
                inputSchema:(.inputSchema // {}),
                annotations:(.annotations // {})
            }],
            findings:(.findings // [])
        }' <<<"${catalog}"
}

linux_agent_add_mcp_context() {
    local request_context="$1"
    local mode="${2:-work}"
    jq -c --argjson mcp "$(linux_agent_mcp_context_json "${mode}")" \
        '. + {mcp:$mcp}' <<<"${request_context}"
}
