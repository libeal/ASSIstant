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

linux_agent_mcp_public_tool_data() {
    local tool_json="$1"
    jq -c '
        def secret_key:
            test("(?i)(authorization|cookie|token|secret|password|passwd|api[_-]?key|credential|private[_-]?key)");
        def redact_schema($sensitive_field):
            if type == "object" then
                (if $sensitive_field then del(.default, .examples, .enum, .const) else . end)
                | with_entries(
                    .value = (
                        if ((.key == "properties") or (.key == "patternProperties") or (.key == "dependentSchemas"))
                            and (.value | type) == "object"
                        then
                            .value
                            | with_entries(
                                .key as $property_name
                                | .value = (.value | redact_schema($sensitive_field or ($property_name | secret_key)))
                            )
                        elif ((.key == "$defs") or (.key == "definitions")) and (.value | type) == "object" then
                            .value
                            | with_entries(
                                .key as $definition_name
                                | .value = (.value | redact_schema($sensitive_field or ($definition_name | secret_key)))
                            )
                        elif (.key == "dependentRequired") and (.value | type) == "object" then
                            .value
                        elif (.key | secret_key) then
                            "[REDACTED]"
                        else
                            (.value | redact_schema($sensitive_field))
                        end
                    )
                )
            elif type == "array" then
                map(redact_schema($sensitive_field))
            else
                .
            end;
        def redact:
            if type == "object" then
                with_entries(
                    .value = (
                        if (.key == "inputSchema") or (.key == "outputSchema") then
                            (.value | redact_schema(false))
                        elif (.key | secret_key) then
                            "[REDACTED]"
                        else
                            (.value | redact)
                        end
                    )
                )
            elif type == "array" then
                map(redact)
            else
                .
            end;
        redact
    ' <<<"${tool_json}"
}

linux_agent_mcp_validate_manifest_path() {
    local path="$1"
    local mcp_dir rel validator schema output
    mcp_dir="$(linux_agent_mcp_dir)"
    rel="${path#${mcp_dir%/}/}"
    validator="${LINUX_AGENT_ROOT}/lib/mcp_manifest.py"
    schema="${LINUX_AGENT_ROOT}/schema/mcp-manifest.json"
    if [[ ! -f "${validator}" ]]; then
        validator="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/mcp_manifest.py"
    fi
    if [[ ! -f "${schema}" ]]; then
        schema="$(cd "$(dirname "${validator}")/.." && pwd)/schema/mcp-manifest.json"
    fi
    output="$(python3 "${validator}" "${path}" --schema "${schema}" 2>/dev/null || true)"
    if ! jq -e 'type == "object" and (.findings | type) == "array"' >/dev/null 2>&1 <<<"${output}"; then
        jq -cn \
            --arg path "${rel}" \
            '{
                ok:false,
                path:$path,
                id:"",
                transport:"",
                findings:[{
                    severity:"critical",
                    code:"MCP_MANIFEST_VALIDATOR_FAILED",
                    path:$path,
                    message:"MCP manifest validator failed."
                }]
            }'
        return 0
    fi
    jq -c \
        --arg path "${rel}" \
        '.path = $path | .findings = [.findings[] | .path = $path]' \
        <<<"${output}"
}

linux_agent_mcp_server_summary() {
    local path="$1"
    local mcp_dir rel payload payload_type validation public server_id transport name description enabled manifest_meta
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
        enabled="$(jq -r 'if (.enabled | type) == "boolean" then .enabled else true end' <<<"${payload}")"
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

    # Manifest v2 declarations that the UI needs in order to explain what a
    # server is allowed to negotiate. Projected only from a manifest that
    # passed schema validation, and only as a read-only summary: the
    # credential profile is reported as an id plus a bound/not-bound flag —
    # the profile file itself belongs to Runner and is never read here.
    # This deliberately does not go through linux_agent_mcp_public_manifest,
    # whose redactor blanks any key matching /credential/ wholesale.
    manifest_meta='{"manifest_version":null,"protocol":null,"credential_profile_id":"","credential_bound":false}'
    if [[ "$(jq -r '.ok // false' <<<"${validation}")" == "true" && "${payload_type}" == "object" ]]; then
        manifest_meta="$(jq -c '{
            manifest_version:(if (.manifest_version | type) == "number" then .manifest_version else 1 end),
            protocol:{
                mode:(if (.protocol.mode | type) == "string" then .protocol.mode else "modern_then_legacy" end),
                require_modern:(.protocol.require_modern == true),
                allow_legacy_sse:(.compatibility.allow_legacy_sse == true)
            },
            credential_profile_id:(if (.credential_profile | type) == "string" then .credential_profile else "" end),
            credential_bound:(((.credential_profile | type) == "string") and ((.credential_profile | length) > 0))
        }' <<<"${payload}")"
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
        --argjson manifest_meta "${manifest_meta}" \
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
        } + $manifest_meta'
}

linux_agent_validate_mcp() {
    local path findings validation ok mcp_dir
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

linux_agent_mcp_runner_path() {
    local path="${LINUX_AGENT_ROOT}/lib/runner.py"
    if [[ -f "${path}" && ! -L "${path}" ]]; then
        printf '%s\n' "${path}"
        return 0
    fi
    path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/runner.py"
    [[ -f "${path}" && ! -L "${path}" ]] || return 1
    printf '%s\n' "${path}"
}

linux_agent_mcp_run_fixed_client() {
    local output_var="$1"
    shift
    local -n output_ref="${output_var}"
    local runner socket_path status=0 name value
    local -a scrub_env runner_command
    runner="$(linux_agent_mcp_runner_path)" || return 125
    scrub_env=(env -i --)
    for name in \
        PATH HOME USER LOGNAME LANG LC_ALL TZ \
        LINUX_AGENT_ROOT LINUX_AGENT_DATA_DIR LINUX_AGENT_MCP_DIR \
        LINUX_AGENT_TMP_ROOT LINUX_AGENT_TMP_DIR \
        LINUX_AGENT_USER_SKILLS_DIR LINUX_AGENT_BUILTIN_SKILLS_DIR \
        LINUX_AGENT_MCP_SELECTION_CACHE_DIR \
        LINUX_AGENT_EXECUTION_TIMEOUT_SEC LINUX_AGENT_EXECUTION_MAX_OUTPUT_BYTES; do
        [[ -v "${name}" ]] || continue
        value="${!name}"
        [[ -n "${value}" ]] || continue
        scrub_env+=("${name}=${value}")
    done
    if linux_agent_managed_execution_enabled 2>/dev/null; then
        socket_path="${LINUX_AGENT_RUNNER_SOCKET:-/run/linux-agent/runner.sock}"
        [[ -S "${socket_path}" ]] || return 125
        runner_command=(
            "${scrub_env[@]}"
            python3 "${runner}" request
            --socket "${socket_path}"
            --kind mcp
            -- "$@"
        )
    else
        runner_command=(
            "${scrub_env[@]}"
            python3 "${runner}" local-mcp -- "$@"
        )
    fi
    # The nameref assignment populates the caller's output variable.
    # shellcheck disable=SC2034
    output_ref="$("${runner_command[@]}" 2>&1)" || status=$?
    return "${status}"
}

linux_agent_mcp_server_tools_from_path() {
    local path="$1"
    local refresh="${2:-false}"
    local validation output client
    local -a client_command

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
    client_command=(python3 "${client}" list-tools "${path}")
    if [[ "${refresh}" == "true" ]]; then
        client_command+=(--refresh)
    fi
    if linux_agent_mcp_run_fixed_client output "${client_command[@]}"; then
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

# shellcheck disable=SC2120 # refresh is passed by bin/agent and lib/api.sh.
linux_agent_mcp_tool_catalog() {
    local refresh="${1:-false}"
    local mcp_dir servers tools findings path server enabled valid tools_result server_tools server_info error protocol_meta
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
        enabled="$(jq -r 'if (.enabled | type) == "boolean" then .enabled else true end' <<<"${server}")"
        valid="$(jq -r '.valid // false' <<<"${server}")"
        server_tools='[]'
        server_info='{}'
        # Negotiated protocol truth. Without this the UI cannot tell a modern
        # MCP session apart from a legacy fallback, which is precisely what
        # manifest v2's protocol.mode / require_modern exist to control.
        protocol_meta='{"protocol_version":null,"protocol_family":null,"server_capabilities":{},"fallback_used":false,"fallback_reason":"","contacted":false}'

        if [[ "${enabled}" == "true" && "${valid}" == "true" ]]; then
            tools_result="$(linux_agent_mcp_server_tools_from_path "${path}" "${refresh}")"
            protocol_meta="$(jq -c \
                --arg protocol_mode "$(jq -r '.protocol.mode // ""' <<<"${server}")" \
                --arg transport "$(jq -r '.transport // ""' <<<"${server}")" \
                '{
                protocol_version:(if (.protocol_version | type) == "string" then .protocol_version else null end),
                protocol_family:(
                    if (.ok == true) and ((.fallback_used == true) or ($protocol_mode == "legacy_only") or ($transport == "sse")) then "legacy"
                    elif (.ok == true) and ((.protocol_version | type) == "string") then "modern"
                    else null
                    end
                ),
                server_capabilities:(if (.server_capabilities | type) == "object" then .server_capabilities else {} end),
                fallback_used:(.fallback_used == true),
                fallback_reason:(if (.fallback_reason | type) == "string" then .fallback_reason else "" end),
                contacted:true
            }' <<<"${tools_result}")"
            if [[ "$(jq -r '.ok // false' <<<"${tools_result}")" == "true" ]]; then
                server_tools="$(jq -c '.tools // [] | if type == "array" then . else [] end' <<<"${tools_result}")"
                server_tools="$(linux_agent_mcp_public_tool_data "${server_tools}")"
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
            --argjson protocol_meta "${protocol_meta}" \
            '. + {tools:$tool_list, tool_count:($tool_list | length), server_info:$server_info} + $protocol_meta' \
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
    tools="$(jq -c 'sort_by([(.server_id // ""), (.name // "")])' <<<"${tools}")"
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
            {
                ok:true,
                status:"found",
                server_id:$server_id,
                tool:$tool,
                transport:($result.transport // ""),
                metadata:$found
            }
          end'
}

# Redacted snapshot of the tool metadata this approval is actually about.
# Captured at policy-review time so the approval card never has to depend on
# the console's own /api/mcp/tools cache, which may be empty or already
# drifted. Everything in here is the server's self-description — it is data to
# display, never an instruction and never a safety guarantee.
linux_agent_mcp_tool_approval_metadata() {
    local server_id="$1"
    local tool_name="$2"
    local metadata="${3:-}"

    [[ -n "${metadata}" ]] || metadata="$(linux_agent_mcp_tool_metadata "${server_id}" "${tool_name}")"
    metadata="$(linux_agent_mcp_public_tool_data "${metadata}")"
    jq -c \
        --arg server_id "${server_id}" \
        --arg tool "${tool_name}" \
        '{
            server_id:$server_id,
            tool:$tool,
            available:(.ok // false),
            status:(.status // "unknown"),
            transport:(.transport // ""),
            description:(.metadata.description // ""),
            input_schema:(if (.metadata.inputSchema | type) == "object" then .metadata.inputSchema else null end),
            output_schema:(if (.metadata.outputSchema | type) == "object" then .metadata.outputSchema else null end),
            annotations:(if (.metadata.annotations | type) == "object" then .metadata.annotations else {} end)
        }' <<<"${metadata}"
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
    args_file="$(mktemp --suffix=.json "${tmp_dir}/mcp.args.XXXXXX")"
    chmod 600 "${args_file}" 2>/dev/null || true
    printf '%s\n' "${args}" >"${args_file}"
    status=0
    linux_agent_mcp_run_fixed_client \
        output \
        python3 "${client}" call-tool "${path}" "${tool_name}" "${args_file}" || status=$?
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
    local metadata="${2:-}"
    local server_id tool_name args
    server_id="$(jq -r '.mcp_server // empty' <<<"${step_json}")"
    tool_name="$(jq -r '.mcp_tool // empty' <<<"${step_json}")"
    args="$(linux_agent_step_arguments_json "${step_json}")"
    [[ -n "${metadata}" ]] || metadata="$(linux_agent_mcp_tool_metadata "${server_id}" "${tool_name}")"
    jq -nr \
        --arg server_id "${server_id}" \
        --arg tool "${tool_name}" \
        --argjson arguments "${args}" \
        --argjson metadata "${metadata}" \
        '
        def derived_headers($schema; $value; $path):
            [
                ($schema.properties // {} | to_entries[]) as $property
                | ($path + [$property.key]) as $next_path
                | (if ($value | type) == "object" then $value[$property.key] else null end) as $argument
                | (
                    if (($property.value["x-mcp-header"] // null) | type) == "string"
                        and $argument != null
                    then
                        ($property.value["x-mcp-header"]) as $header
                        | {
                            name:("Mcp-Param-" + $header),
                            source:($next_path | join(".")),
                            value:(
                                if (($header + " " + ($next_path | join(".")))
                                    | test("(?i)(authorization|cookie|token|secret|password|passwd|api[_-]?key|credential|private[_-]?key)"))
                                then "[REDACTED]"
                                else $argument
                                end
                            )
                        }
                    else empty
                    end
                ),
                derived_headers($property.value; $argument; $next_path)[]
            ];
        (if ($metadata.transport // "") == "streamable_http"
         then ($metadata.metadata.inputSchema // {})
         else {}
         end) as $schema
        | derived_headers($schema; $arguments; []) as $headers
        | "mcp_tool=\($server_id)/\($tool)\narguments=\($arguments | tojson)\nderived_headers=\($headers | tojson)\nmetadata=\($metadata | tojson)"'
}

linux_agent_mcp_context_json() {
    local mode="${1:-work}"
    local catalog

    case "${mode}" in
        work | work_revision | work_reflect | edit | edit_revision) ;;
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
