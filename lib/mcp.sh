#!/usr/bin/env bash

set -euo pipefail

linux_agent_mcp_dir() {
    printf '%s\n' "${LINUX_AGENT_MCP_DIR:-${LINUX_AGENT_ROOT}/mcp}"
}

linux_agent_mcp_manifest_paths() {
    local mcp_dir
    mcp_dir="$(linux_agent_mcp_dir)"
    mkdir -p "${mcp_dir}"
    find "${mcp_dir}" -mindepth 2 -maxdepth 2 -type f -name 'mcp.json' 2>/dev/null | sort
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
