#!/usr/bin/env bash

set -euo pipefail

LINUX_AGENT_API_INPUT_JSON='[]'
LINUX_AGENT_EXECUTION_ISOLATION_STATE="degraded_same_uid"
LINUX_AGENT_EXECUTION_PREPARE_ERROR_CODE=""
LINUX_AGENT_RUNNER_AUDIT_SNAPSHOT=""
LINUX_AGENT_RUNNER_AUDIT_SNAPSHOT_SESSION=""
LINUX_AGENT_EXECUTION_STAGING_PATHS=()

linux_agent_api_read_input_line() {
    local result_var="$1"
    local line remaining

    [[ "${LINUX_AGENT_API_MODE:-0}" == "1" ]] || return 1
    if ! jq -e 'type == "array" and length > 0' <<<"${LINUX_AGENT_API_INPUT_JSON:-[]}" >/dev/null 2>&1; then
        printf -v "${result_var}" '%s' ""
        return 0
    fi

    line="$(jq -r '.[0] // ""' <<<"${LINUX_AGENT_API_INPUT_JSON}")"
    remaining="$(jq -c '.[1:]' <<<"${LINUX_AGENT_API_INPUT_JSON}")"
    LINUX_AGENT_API_INPUT_JSON="${remaining}"
    printf -v "${result_var}" '%s' "${line}"
    return 0
}

linux_agent_api_has_pending_decision_lines() {
    [[ "${LINUX_AGENT_API_MODE:-0}" == "1" ]] || return 1
    jq -e 'type == "array" and length > 0' <<<"${LINUX_AGENT_API_INPUT_JSON:-[]}" >/dev/null 2>&1
}

linux_agent_api_set_decision_lines() {
    local payload="$1"
    LINUX_AGENT_API_MODE=1
    LINUX_AGENT_API_INPUT_JSON="$(jq -c '
        if (.decisions | type) == "array" then .decisions
        elif (.stdin | type) == "array" then .stdin
        else [] end
        | map(tostring)
    ' <<<"${payload}")"
}

linux_agent_probe_sudo() {
    if ! command -v sudo >/dev/null 2>&1; then
        printf 'unavailable\n'
        return 0
    fi

    if sudo -n true >/dev/null 2>&1; then
        printf 'passwordless\n'
    elif sudo -n -l >/dev/null 2>&1; then
        printf 'interactive\n'
    else
        printf 'denied\n'
    fi
}

linux_agent_min_privilege_proxy_enabled() {
    linux_agent_config_bool_default '.execution.min_privilege_proxy' 'true'
}

linux_agent_least_privilege_user() {
    local configured candidate
    configured="$(linux_agent_config_get_default '.execution.least_privilege_user' 'nobody' 2>/dev/null || printf 'nobody')"
    for candidate in "${configured}" nobody nfsnobody daemon; do
        [[ -n "${candidate}" && "${candidate}" =~ ^[A-Za-z_][A-Za-z0-9_.-]*[$]?$ ]] || continue
        if id -u "${candidate}" >/dev/null 2>&1; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done
    return 1
}

linux_agent_execution_privilege_from_review() {
    # Policy findings control approval only.  They must never be allowed to
    # turn an ordinary command into a root/current-UID execution path.
    # Privileged operations use an explicit host-helper contract instead.
    printf 'least\n'
}

# output_command_ref is a nameref used to populate the caller's command array.
# shellcheck disable=SC2034
linux_agent_runner_socket() {
    printf '%s\n' "${LINUX_AGENT_RUNNER_SOCKET:-/run/linux-agent/runner.sock}"
}

linux_agent_runner_kind_for_command() {
    local first="${1:-}" second="${2:-}" resolved builtin user tmp
    if [[ "${first}" == "bash" && "${second}" == "-lc" && $# -eq 3 ]]; then
        printf 'terminal\n'
        return 0
    fi
    if [[ "${first}" == "bash" && $# -eq 3 ]]; then
        resolved="$(readlink -f -- "${second}" 2>/dev/null || true)"
        [[ -n "${resolved}" ]] || return 1
        builtin="$(readlink -f -- "${LINUX_AGENT_BUILTIN_SKILLS_DIR:-${LINUX_AGENT_ROOT}/skills}" 2>/dev/null || true)"
        user="$(readlink -f -- "${LINUX_AGENT_USER_SKILLS_DIR:-${LINUX_AGENT_ROOT}/data/skills}" 2>/dev/null || true)"
        tmp="$(readlink -f -- "${LINUX_AGENT_RUNNER_TMP_ROOT:-${LINUX_AGENT_TMP_ROOT:-${LINUX_AGENT_ROOT}/tmp}}" 2>/dev/null || true)"
        if [[ -n "${builtin}" && "${resolved}" == "${builtin}/"* ]] ||
            [[ -n "${user}" && "${resolved}" == "${user}/"* ]]; then
            printf 'skill\n'
            return 0
        fi
        if [[ -n "${tmp}" && "${resolved}" == "${tmp}/"* ]]; then
            printf 'remote_script\n'
            return 0
        fi
        return 1
    fi
    if [[ "${first}" == "python3" && "${second}" == "${LINUX_AGENT_ROOT}/lib/mcp_client.py" && $# -eq 6 ]]; then
        printf 'mcp\n'
        return 0
    fi
    return 1
}

linux_agent_cleanup_execution_staging() {
    local path resolved root
    root="$(readlink -f -- "${LINUX_AGENT_RUNNER_TMP_ROOT:-}" 2>/dev/null || true)"
    for path in "${LINUX_AGENT_EXECUTION_STAGING_PATHS[@]:-}"; do
        [[ -n "${path}" && -n "${root}" ]] || continue
        resolved="$(readlink -f -- "${path}" 2>/dev/null || true)"
        if [[ -n "${resolved}" && "${resolved}" != "${root}" && "${resolved}" == "${root}/"* &&
            -f "${resolved}" && ! -L "${path}" ]]; then
            rm -f -- "${resolved}"
        fi
    done
    if [[ -n "${LINUX_AGENT_RUNNER_RESULT_FILE:-}" &&
        "${LINUX_AGENT_RUNNER_RESULT_FILE}" == "${LINUX_AGENT_TMP_DIR}"/runner-result.*.json ]]; then
        rm -f -- "${LINUX_AGENT_RUNNER_RESULT_FILE}"
    fi
    LINUX_AGENT_EXECUTION_STAGING_PATHS=()
    LINUX_AGENT_RUNNER_AUDIT_SNAPSHOT=""
    LINUX_AGENT_RUNNER_AUDIT_SNAPSHOT_SESSION=""
    LINUX_AGENT_RUNNER_RESULT_FILE=""
}

linux_agent_runner_result_metadata() {
    local path="${LINUX_AGENT_RUNNER_RESULT_FILE:-}" owner mode
    [[ -n "${path}" && "${path}" == "${LINUX_AGENT_TMP_DIR}"/runner-result.*.json &&
        -f "${path}" && ! -L "${path}" ]] || return 1
    owner="$(stat -c '%u' -- "${path}" 2>/dev/null || true)"
    mode="$(stat -c '%a' -- "${path}" 2>/dev/null || true)"
    [[ "${owner}" == "$(id -u)" && "${mode}" == "600" ]] || return 1
    jq -e -c '
        type == "object"
        and .protocol_version == "1.2.0"
        and (.request_id | type == "string" and test("^[0-9a-f]{32}$"))
        and (.ok | type == "boolean")
        and (.status | type == "string" and length > 0)
        and (.exit_code | type == "number" and floor == . and . >= 0 and . <= 255)
        and ((.timed_out // false) | type == "boolean")
        and ((.cancelled // false) | type == "boolean")
        and ((.output_capped // false) | type == "boolean")
        and ((.output_integrity_unknown // false) | type == "boolean")
        and ((.stdout_truncated_bytes // 0) | type == "number" and floor == . and . >= 0)
        and ((.stderr_truncated_bytes // 0) | type == "number" and floor == . and . >= 0)
    ' "${path}" 2>/dev/null
}

linux_agent_prepare_session_history_snapshot() {
    local runner_kind="$1"
    shift
    local script_path builtin_root relative skill_name entrypoint metadata_path arguments session_id latest_log
    local private_stage snapshot_path segment line staged_file verify_report

    LINUX_AGENT_RUNNER_AUDIT_SNAPSHOT=""
    LINUX_AGENT_RUNNER_AUDIT_SNAPSHOT_SESSION=""
    [[ "${runner_kind}" == "skill" && $# -eq 3 && "${1:-}" == "bash" ]] || return 0
    script_path="$(readlink -f -- "${2:-}" 2>/dev/null || true)"
    builtin_root="$(readlink -f -- "${LINUX_AGENT_BUILTIN_SKILLS_DIR:-${LINUX_AGENT_ROOT}/skills}" 2>/dev/null || true)"
    [[ -n "${script_path}" && -n "${builtin_root}" && "${script_path}" == "${builtin_root}/"* ]] || return 0
    relative="${script_path#"${builtin_root}/"}"
    skill_name="${relative%%/*}"
    entrypoint="${relative#*/}"
    [[ "${entrypoint}" == scripts/* ]] || return 0
    metadata_path="${builtin_root}/${skill_name}/linux-agent.json"
    [[ -f "${metadata_path}" && ! -L "${metadata_path}" ]] || return 0
    jq -e --arg entrypoint "${entrypoint}" '
        any(.tools[]?; .entrypoint == $entrypoint and (.runtime_inputs | index("audit_snapshot")) != null)
    ' "${metadata_path}" >/dev/null 2>&1 || return 0

    arguments="${3:-}"
    jq -e 'type == "object"' <<<"${arguments}" >/dev/null 2>&1 || return 0
    session_id="$(jq -r '.session_id // empty' <<<"${arguments}")"
    [[ -n "${session_id}" ]] || session_id="${LINUX_AGENT_SESSION_ID:-}"
    if [[ -z "${session_id}" ]]; then
        latest_log="$(find "${LINUX_AGENT_LOG_DIR}" -maxdepth 1 -type f -name 'session*.jsonl' \
            -printf '%T@ %f\n' 2>/dev/null | sort -rn | head -n 1 | awk '{print $2}')"
        session_id="${latest_log%.jsonl}"
    fi
    [[ -n "${session_id}" && "${session_id}" =~ ^[A-Za-z0-9_.-]+$ ]] || return 0
    [[ -f "${LINUX_AGENT_LOG_DIR}/${session_id}.jsonl" &&
        ! -L "${LINUX_AGENT_LOG_DIR}/${session_id}.jsonl" ]] || return 0

    private_stage="$(mktemp -d "${LINUX_AGENT_TMP_DIR}/runner-audit-stage.XXXXXX")" || {
        LINUX_AGENT_EXECUTION_PREPARE_ERROR_CODE="runner_unavailable"
        return 1
    }
    chmod 0700 "${private_stage}"
    if ! snapshot_path="$(linux_agent_audit_snapshot "${session_id}" "${private_stage}" 2>/dev/null)"; then
        rm -rf -- "${private_stage}"
        LINUX_AGENT_EXECUTION_PREPARE_ERROR_CODE="audit_integrity_broken"
        return 1
    fi
    if ! verify_report="$(linux_agent_audit_verify_chain "${session_id}" "${snapshot_path}" 2>/dev/null)" ||
        [[ "$(jq -r '.ok // false' <<<"${verify_report}" 2>/dev/null || printf false)" != "true" ]]; then
        rm -rf -- "${private_stage}"
        LINUX_AGENT_EXECUTION_PREPARE_ERROR_CODE="audit_integrity_broken"
        return 1
    fi

    staged_file="$(mktemp "${LINUX_AGENT_RUNNER_TMP_DIR}/audit-snapshot.XXXXXX.jsonl")" || {
        rm -rf -- "${private_stage}"
        LINUX_AGENT_EXECUTION_PREPARE_ERROR_CODE="runner_unavailable"
        return 1
    }
    chmod 0600 "${staged_file}"
    while IFS= read -r segment; do
        while IFS= read -r line || [[ -n "${line}" ]]; do
            if ! linux_agent_sanitize_json "${line}" 200000 >>"${staged_file}"; then
                rm -f -- "${staged_file}"
                rm -rf -- "${private_stage}"
                LINUX_AGENT_EXECUTION_PREPARE_ERROR_CODE="audit_integrity_broken"
                return 1
            fi
        done <"${segment}"
    done < <(linux_agent_audit_segment_paths "${snapshot_path}")
    rm -rf -- "${private_stage}"
    chmod 0640 "${staged_file}" || {
        rm -f -- "${staged_file}"
        LINUX_AGENT_EXECUTION_PREPARE_ERROR_CODE="runner_unavailable"
        return 1
    }
    LINUX_AGENT_EXECUTION_STAGING_PATHS+=("${staged_file}")
    LINUX_AGENT_RUNNER_AUDIT_SNAPSHOT="${staged_file}"
    LINUX_AGENT_RUNNER_AUDIT_SNAPSHOT_SESSION="${session_id}"
}

linux_agent_prepare_managed_runner_command() {
    local output_var="$1"
    shift
    local -n output_ref="${output_var}"
    local socket_path runner_path runner_kind metadata_file
    local -a scrub_env runner_options=()
    socket_path="$(linux_agent_runner_socket)"
    runner_path="${LINUX_AGENT_ROOT}/lib/runner.py"
    if [[ ! -f "${runner_path}" || -L "${runner_path}" ]]; then
        LINUX_AGENT_EXECUTION_PREPARE_ERROR_CODE="runner_unavailable"
        return 1
    fi
    if [[ ! -S "${socket_path}" ]]; then
        LINUX_AGENT_EXECUTION_PREPARE_ERROR_CODE="runner_unavailable"
        return 1
    fi
    if ! runner_kind="$(linux_agent_runner_kind_for_command "$@")"; then
        LINUX_AGENT_EXECUTION_PREPARE_ERROR_CODE="runner_rejected"
        return 1
    fi
    if ! linux_agent_prepare_session_history_snapshot "${runner_kind}" "$@"; then
        return 1
    fi
    metadata_file="$(mktemp "${LINUX_AGENT_TMP_DIR}/runner-result.XXXXXX.json")" || {
        LINUX_AGENT_EXECUTION_PREPARE_ERROR_CODE="runner_unavailable"
        return 1
    }
    chmod 0600 "${metadata_file}" || {
        rm -f -- "${metadata_file}"
        LINUX_AGENT_EXECUTION_PREPARE_ERROR_CODE="runner_unavailable"
        return 1
    }
    LINUX_AGENT_RUNNER_RESULT_FILE="${metadata_file}"
    if [[ -n "${LINUX_AGENT_RUNNER_AUDIT_SNAPSHOT}" ]]; then
        runner_options=(
            --audit-snapshot "${LINUX_AGENT_RUNNER_AUDIT_SNAPSHOT}"
            --audit-snapshot-session "${LINUX_AGENT_RUNNER_AUDIT_SNAPSHOT_SESSION}"
        )
    fi
    linux_agent_build_execution_environment scrub_env
    # The nameref assignment populates the caller's prepared command array.
    # shellcheck disable=SC2034
    output_ref=(
        "${scrub_env[@]}"
        python3 "${runner_path}" request
        --socket "${socket_path}"
        --kind "${runner_kind}"
        --metadata-file "${metadata_file}"
        "${runner_options[@]}"
        -- "$@"
    )
    LINUX_AGENT_EXECUTION_ISOLATION_STATE="runner_uid"
    return 0
}

# shellcheck disable=SC2034
linux_agent_build_execution_environment() {
    local output_var="$1"
    local target_user="${2:-}"
    local -n output_env_ref="${output_var}"
    local name value
    local -a safe_names=(
        PATH HOME USER LOGNAME SHELL PWD TMPDIR TMP TEMP TERM LANG LANGUAGE TZ
        XDG_CONFIG_HOME XDG_CACHE_HOME XDG_DATA_HOME XDG_STATE_HOME
        LC_ALL LC_COLLATE LC_CTYPE LC_MESSAGES LC_MONETARY LC_NUMERIC LC_TIME
        LINUX_AGENT_ROOT LINUX_AGENT_LOG_DIR LINUX_AGENT_SKILLS_DIR
        LINUX_AGENT_MCP_DIR LINUX_AGENT_TMP_ROOT LINUX_AGENT_TMP_DIR
        LINUX_AGENT_REMOTE_MODE LINUX_AGENT_REMOTE_RELEASE_VERSION
        LINUX_AGENT_REMOTE_STORAGE_BACKEND LINUX_AGENT_SESSION_ID
        LINUX_AGENT_REQUEST_ID LINUX_AGENT_JOB_ID
        LINUX_AGENT_EXECUTION_TIMEOUT_SEC LINUX_AGENT_EXECUTION_MAX_OUTPUT_BYTES
    )

    output_env_ref=(env -i --)
    for name in "${safe_names[@]}"; do
        [[ -v "${name}" ]] || continue
        value="${!name}"
        [[ -n "${value}" ]] || continue
        output_env_ref+=("${name}=${value}")
    done
    if [[ -n "${target_user}" ]] && command -v getent >/dev/null 2>&1; then
        value="$(getent passwd "${target_user}" 2>/dev/null | awk -F: 'NR == 1 {print $6}')"
        output_env_ref+=("HOME=${value:-/tmp}" "USER=${target_user}" "LOGNAME=${target_user}")
    fi
}

# shellcheck disable=SC2034
linux_agent_prepare_execution_command() {
    local requested_privilege="$1"
    local output_var="$2"
    shift 2
    local -n output_command_ref="${output_var}"
    output_command_ref=()
    linux_agent_cleanup_execution_staging
    LINUX_AGENT_EXECUTION_PREPARE_ERROR_CODE=""
    LINUX_AGENT_EXECUTION_ISOLATION_STATE="degraded_same_uid"

    if linux_agent_managed_execution_enabled 2>/dev/null; then
        LINUX_AGENT_EXECUTION_TIMEOUT_SEC="$(linux_agent_execution_timeout_sec)"
        LINUX_AGENT_EXECUTION_MAX_OUTPUT_BYTES="$(linux_agent_execution_max_output_bytes)"
        if ! linux_agent_prepare_managed_runner_command "${output_var}" "$@"; then
            return 1
        fi
        return 0
    fi

    local -a scrub_env

    if [[ "${requested_privilege}" != "least" ]] || [[ "$(linux_agent_min_privilege_proxy_enabled)" != "true" ]]; then
        linux_agent_build_execution_environment scrub_env
        output_command_ref=("${scrub_env[@]}" "$@")
        return 0
    fi

    if [[ "$(id -u)" -ne 0 ]]; then
        linux_agent_build_execution_environment scrub_env
        output_command_ref=("${scrub_env[@]}" "$@")
        return 0
    fi

    local target_user target_uid target_gid
    if ! target_user="$(linux_agent_least_privilege_user)"; then
        return 1
    fi
    linux_agent_build_execution_environment scrub_env "${target_user}"

    if command -v runuser >/dev/null 2>&1; then
        output_command_ref=(runuser -u "${target_user}" -- "${scrub_env[@]}" "$@")
        return 0
    fi

    if command -v setpriv >/dev/null 2>&1; then
        target_uid="$(id -u "${target_user}")"
        target_gid="$(id -g "${target_user}")"
        output_command_ref=(setpriv --reuid "${target_uid}" --regid "${target_gid}" --init-groups "${scrub_env[@]}" "$@")
        return 0
    fi

    return 1
}

linux_agent_execution_proxy_metadata() {
    local requested_privilege="$1"
    local prepared_root="$2"
    local error_message="${3:-}"
    local target_user=""
    if [[ "${LINUX_AGENT_EXECUTION_ISOLATION_STATE:-}" == "runner_uid" ]]; then
        target_user="${LINUX_AGENT_RUNNER_USER:-linux-agent-runner}"
    elif [[ "${requested_privilege}" == "least" && "$(id -u)" -eq 0 ]]; then
        target_user="$(linux_agent_least_privilege_user 2>/dev/null || true)"
    fi

    jq -cn \
        --arg requested_privilege "${requested_privilege}" \
        --arg execution_user "$(id -un 2>/dev/null || printf 'unknown')" \
        --arg target_user "${target_user}" \
        --arg prepared_root "${prepared_root}" \
        --arg error "${error_message}" \
        --arg isolation "${LINUX_AGENT_EXECUTION_ISOLATION_STATE:-degraded_same_uid}" \
        --argjson enabled "$(linux_agent_min_privilege_proxy_enabled)" \
        '{
            enabled:$enabled,
            requested_privilege:$requested_privilege,
            execution_user:$execution_user,
            target_user:(if $target_user == "" then null else $target_user end),
            prepared_root:(($prepared_root == "true") and $isolation != "runner_uid"),
            isolation:$isolation,
            error:(if $error == "" then null else $error end)
        }'
}

linux_agent_host_helper_socket() {
    printf '%s\n' "${LINUX_AGENT_HOST_HELPER_SOCKET:-/run/linux-agent/host-ops.sock}"
}

linux_agent_host_helper_result() {
    local ref="$1" operation="$2" params="$3" response stdout_text
    local helper_client="${LINUX_AGENT_ROOT}/lib/host_ops_helper.py"
    local socket_path summary
    local -a scrub_env
    socket_path="$(linux_agent_host_helper_socket)"
    summary="Apply reviewed ${operation} operation for ${ref}"
    if [[ ! -f "${helper_client}" || -L "${helper_client}" || ! -S "${socket_path}" ]]; then
        jq -cn --arg ref "${ref}" '{
            ok:false,
            status:"helper_unavailable",
            code:"helper_unavailable",
            error_code:"helper_unavailable",
            exit_code:126,
            output:{ok:false, status:"helper_unavailable", tool:$ref, error:"Required host helper is unavailable."},
            execution_proxy:{isolation:"host_helper", helper:"host-ops", available:false}
        }'
        return 0
    fi
    linux_agent_build_execution_environment scrub_env
    response="$(
        "${scrub_env[@]}" python3 "${helper_client}" request \
            --socket "${socket_path}" \
            "${operation}" \
            --params "${params}" \
            --summary "${summary}" 2>&1
    )" || true
    if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"${response}"; then
        jq -cn --arg ref "${ref}" --arg error "${response}" '{
            ok:false,
            status:"helper_unavailable",
            code:"helper_unavailable",
            error_code:"helper_unavailable",
            exit_code:126,
            output:{ok:false, status:"helper_unavailable", tool:$ref, error:$error},
            execution_proxy:{isolation:"host_helper", helper:"host-ops", available:false}
        }'
        return 0
    fi
    stdout_text="$(jq -c --arg ref "${ref}" '. + {tool:$ref}' <<<"${response}")"
    jq -cn \
        --argjson helper "${stdout_text}" \
        '{
            ok:($helper.ok == true),
            status:($helper.status // (if $helper.ok == true then "executed" else "helper_failed" end)),
            code:($helper.code // null),
            error_code:($helper.code // null),
            exit_code:(if $helper.ok == true then 0 else 1 end),
            output:$helper,
            execution_proxy:{isolation:"host_helper", helper:"host-ops", available:true}
        }'
}

linux_agent_skill_adapter_result() {
    local ref="$1" args="$2" contract origin adapter tool_name response
    local -a scrub_env
    contract="$(linux_agent_skill_tool_contract_json "${ref}")"
    origin="$(jq -r '.origin // empty' <<<"${contract}")"
    adapter="$(linux_agent_skill_adapter_path "${ref}" 2>/dev/null || true)"
    tool_name="$(jq -r '.tool.name // empty' <<<"${contract}")"
    if [[ "${origin}" != "builtin" || -z "${adapter}" || -L "${adapter}" || ! -f "${adapter}" || -z "${tool_name}" ]]; then
        jq -cn '{ok:false,status:"helper_rejected",error:"Signed builtin helper adapter is unavailable"}'
        return 0
    fi
    linux_agent_build_execution_environment scrub_env
    response="$("${scrub_env[@]}" timeout 10s python3 "${adapter}" "${tool_name}" "${args}" 2>&1)" || true
    if ! jq -e 'type == "object" and (.ok | type == "boolean")' <<<"${response}" >/dev/null 2>&1; then
        jq -cn --arg error "${response}" '{ok:false,status:"helper_rejected",error:("Skill helper adapter returned invalid output: " + $error)}'
        return 0
    fi
    printf '%s\n' "${response}"
}

linux_agent_maybe_execute_host_helper_skill() {
    local scope="$1" subject_json="$2"
    shift 2
    local ref args contract capability adapter_result dispatch operation params error
    [[ "${scope}" == "script" || "${scope}" == "step_skill_script" ]] || return 1
    [[ "${1:-}" == "bash" && $# -eq 3 ]] || return 1
    ref="$(jq -r '.ref // .step.skill_script // empty' <<<"${subject_json}")"
    [[ -n "${ref}" ]] || return 1
    contract="$(linux_agent_skill_tool_contract_json "${ref}")"
    [[ "$(jq -r '.tool.execution.class // empty' <<<"${contract}")" == "host_helper" ]] || return 1
    args="${3:-}"
    adapter_result="$(linux_agent_skill_adapter_result "${ref}" "${args}")"
    if [[ "$(jq -r '.ok // false' <<<"${adapter_result}")" != "true" ]]; then
        error="$(jq -r '.error // "host helper adapter rejected the request"' <<<"${adapter_result}")"
        jq -cn --arg ref "${ref}" --arg error "${error}" '{
            ok:false,status:"helper_rejected",code:"helper_rejected",error_code:"helper_rejected",exit_code:126,
            output:{ok:false,status:"helper_rejected",tool:$ref,error:$error},
            execution_proxy:{isolation:"host_helper",helper:"host-ops",available:false}
        }'
        return 0
    fi
    dispatch="$(jq -r '.dispatch // empty' <<<"${adapter_result}")"
    if [[ "${dispatch}" == "runner" ]]; then
        return 1
    fi
    capability="$(jq -r '.tool.execution.capability // empty' <<<"${contract}")"
    operation="$(jq -r '.operation // empty' <<<"${adapter_result}")"
    if [[ "${dispatch}" != "helper" || -z "${capability}" || "${operation}" != "${capability}" ]] ||
        ! params="$(jq -c '.params | select(type == "object")' <<<"${adapter_result}")" || [[ -z "${params}" ]]; then
        jq -cn --arg ref "${ref}" '{
            ok:false,status:"helper_rejected",code:"helper_rejected",error_code:"helper_rejected",exit_code:126,
            output:{ok:false,status:"helper_rejected",tool:$ref,error:"Skill helper adapter violated its declared capability contract."},
            execution_proxy:{isolation:"host_helper",helper:"host-ops",available:false}
        }'
        return 0
    fi
    if ! linux_agent_managed_execution_enabled 2>/dev/null; then
        return 1
    fi
    linux_agent_host_helper_result "${ref}" "${operation}" "${params}"
    return 0
}

linux_agent_maybe_execute_credential_helper_skill() {
    local scope="$1" subject_json="$2"
    shift 2
    local ref args contract origin capability adapter_result dispatch operation params summary
    local component helper_name helper_client_rel helper_client socket_env default_socket socket_path response
    [[ "${scope}" == "script" || "${scope}" == "step_skill_script" ]] || return 1
    [[ "${1:-}" == "bash" && $# -eq 3 ]] || return 1
    ref="$(jq -r '.ref // .step.skill_script // empty' <<<"${subject_json}")"
    [[ -n "${ref}" ]] || return 1
    contract="$(linux_agent_skill_tool_contract_json "${ref}")"
    [[ "$(jq -r '.tool.execution.class // empty' <<<"${contract}")" == "credential_helper" ]] || return 1
    args="${3:-}"
    origin="$(jq -r '.origin // empty' <<<"${contract}")"
    capability="$(jq -r '.tool.execution.capability // empty' <<<"${contract}")"
    adapter_result="$(linux_agent_skill_adapter_result "${ref}" "${args}")"
    dispatch="$(jq -r '.dispatch // empty' <<<"${adapter_result}")"
    operation="$(jq -r '.operation // empty' <<<"${adapter_result}")"
    if [[ "${origin}" != "builtin" || "${dispatch}" != "helper" || -z "${capability}" ||
        "${operation}" != "${capability}" || "$(jq -r '.ok // false' <<<"${adapter_result}")" != "true" ]] ||
        ! params="$(jq -c '.params | select(type == "object")' <<<"${adapter_result}")" || [[ -z "${params}" ]]; then
        jq -cn --arg ref "${ref}" --arg error "$(jq -r '.error // "Credential helper adapter violated its declared capability contract."' <<<"${adapter_result}")" '{
            ok:false, status:"failed", code:"helper_rejected",
            error_code:"helper_rejected", exit_code:126,
            output:{ok:false,status:"failed",code:"helper_rejected",tool:$ref,error:$error},
            execution_proxy:{isolation:"credential_helper",helper:null,available:false}
        }'
        return 0
    fi
    component="$(jq -c '.components.credential_helper | select(type == "object")' <<<"${contract}" 2>/dev/null || true)"
    helper_name="$(jq -r '.name // empty' <<<"${component}")"
    helper_client_rel="$(jq -r '.client // empty' <<<"${component}")"
    socket_env="$(jq -r '.socket_env // empty' <<<"${component}")"
    default_socket="$(jq -r '.default_socket // empty' <<<"${component}")"
    helper_client="$(jq -r --arg client "${helper_client_rel}" '(.package // "") + "/" + $client' <<<"${contract}")"
    if [[ ! "${socket_env}" =~ ^[A-Z][A-Z0-9_]{0,127}$ || -z "${default_socket}" ]]; then
        socket_path=""
    else
        socket_path="${!socket_env:-${default_socket}}"
    fi
    if ! linux_agent_managed_execution_enabled 2>/dev/null; then
        jq -cn --arg ref "${ref}" --arg helper "${helper_name}" '{
            ok:false, status:"failed", code:"credential_unavailable",
            error_code:"credential_unavailable", exit_code:126,
            output:{ok:false,status:"failed",code:"credential_unavailable",tool:$ref,error:"This operation requires a managed credential helper."},
            execution_proxy:{isolation:"credential_helper",helper:$helper,available:false}
        }'
        return 0
    fi
    if [[ -z "${helper_name}" || -z "${helper_client_rel}" || ! -f "${helper_client}" ||
        -L "${helper_client}" || -z "${socket_path}" || ! -S "${socket_path}" ]]; then
        jq -cn --arg ref "${ref}" --arg helper "${helper_name}" '{
            ok:false, status:"failed", code:"credential_unavailable",
            error_code:"credential_unavailable", exit_code:126,
            output:{ok:false,status:"failed",code:"credential_unavailable",tool:$ref,error:"Credential helper is unavailable."},
            execution_proxy:{isolation:"credential_helper",helper:$helper,available:false}
        }'
        return 0
    fi
    summary="$(jq -r '.summary // "Run credential helper operation"' <<<"${adapter_result}")"
    response="$(python3 "${helper_client}" request --socket "${socket_path}" "${operation}" \
        --params "${params}" --summary "${summary}" 2>&1)" || true
    if ! jq -e 'type == "object"' <<<"${response}" >/dev/null 2>&1; then
        jq -cn --arg ref "${ref}" --arg helper "${helper_name}" --arg error "${response}" '{
            ok:false,status:"failed",code:"credential_unavailable",
            error_code:"credential_unavailable",exit_code:126,
            output:{ok:false,status:"failed",code:"credential_unavailable",tool:$ref,error:$error},
            execution_proxy:{isolation:"credential_helper",helper:$helper,available:false}
        }'
        return 0
    fi
    jq -cn --arg ref "${ref}" --arg helper_name "${helper_name}" --argjson helper "${response}" '{
        ok:($helper.ok == true),
        status:(if $helper.ok then ($helper.status // "checked") else "failed" end),
        code:($helper.code // null),
        error_code:($helper.code // null),
        exit_code:(if $helper.ok then 0 else 1 end),
        output:($helper + {tool:$ref, status:(if $helper.ok then ($helper.status // "checked") else "failed" end)}),
        execution_proxy:{isolation:"credential_helper",helper:$helper_name,available:true}
    }'
    return 0
}

linux_agent_confirm_execution() {
    local prompt="$1"
    local api_answer=""
    if linux_agent_api_read_input_line api_answer; then
        [[ "${api_answer}" =~ ^[Yy]$ ]]
        return $?
    fi
    printf '%s [y/N]: ' "${prompt}" >&2
    local answer=""
    IFS= read -r answer || true
    [[ "${answer}" =~ ^[Yy]$ ]]
}

linux_agent_auto_approval_enabled() {
    local capability="$1"
    [[ "${capability}" =~ ^[a-z][a-z0-9_]{0,63}$ ]] || {
        printf 'false\n'
        return 0
    }
    jq -r --arg capability "${capability}" '
        .approvals.auto as $auto
        | if ($auto | type) == "object" and ($auto[$capability] | type) == "boolean"
          then $auto[$capability]
          else false end
    ' <<<"${LINUX_AGENT_CONFIG_JSON}" 2>/dev/null || printf 'false\n'
}

linux_agent_auto_approval_config_json() {
    jq -c '
        (.approvals.auto // {})
        | if type == "object" then . else {} end
        | with_entries(select(
            (.key | test("^[a-z][a-z0-9_]{0,63}$"))
            and (.value | type) == "boolean"
        ))
    ' <<<"${LINUX_AGENT_CONFIG_JSON}" 2>/dev/null || printf '{}\n'
}

linux_agent_step_auto_approval_capability() {
    local step_json="$1"
    local executor_type ref
    executor_type="$(jq -r '.executor_type' <<<"${step_json}")"
    case "${executor_type}" in
        skill_load | skill_read)
            printf 'skill_readonly\n'
            ;;
        skill_script)
            ref="$(jq -r '.skill_script // empty' <<<"${step_json}")"
            linux_agent_skill_extension_field "${ref}" approval_scope unknown
            ;;
        shell)
            printf 'shell_readonly\n'
            ;;
        remote_script)
            printf 'remote_script\n'
            ;;
        mcp_tool)
            printf 'mcp_tool\n'
            ;;
        *)
            printf 'unknown\n'
            ;;
    esac
}

linux_agent_should_auto_execute_step() {
    local step_json="$1"
    local review_json="$2"
    local executor_type ref capability

    [[ "$(jq -r '.approved // false' <<<"${review_json}")" == "true" ]] || return 1
    [[ "$(jq -r '.approval_required == false' <<<"${review_json}")" == "true" ]] || return 1
    [[ "$(jq -r '.risk_level // "unknown"' <<<"${review_json}")" == "low" ]] || return 1

    executor_type="$(jq -r '.executor_type' <<<"${step_json}")"
    capability="$(linux_agent_step_auto_approval_capability "${step_json}")"
    [[ "$(linux_agent_auto_approval_enabled "${capability}")" == "true" ]] || return 1
    case "${executor_type}" in
        skill_load | skill_read)
            [[ "$(jq -r '.skill // empty' <<<"${step_json}")" =~ ^[a-z0-9][a-z0-9-]*$ ]]
            ;;
        skill_script)
            ref="$(jq -r '.skill_script // empty' <<<"${step_json}")"
            [[ -n "${ref}" ]] && linux_agent_skill_is_registered "${ref}"
            ;;
        shell)
            return 0
            ;;
        remote_script)
            return 0
            ;;
        mcp_tool)
            linux_agent_mcp_tool_is_available \
                "$(jq -r '.mcp_server // empty' <<<"${step_json}")" \
                "$(jq -r '.mcp_tool // empty' <<<"${step_json}")"
            ;;
        *)
            return 1
            ;;
    esac
}

linux_agent_step_arguments_json() {
    local step_json="$1"
    local raw_args

    raw_args="$(jq -c 'if has("arguments") then .arguments else {} end' <<<"${step_json}")"
    linux_agent_normalize_json_object_argument "${raw_args}" || printf '{}\n'
}

linux_agent_skill_guard_condition_matches() {
    local guard_json="$1" args_json="$2"
    jq -e -n --argjson guard "${guard_json}" --argjson args "${args_json}" '
        ($guard.condition.field) as $field
        | (if ($args | has($field)) then $args[$field]
           else $guard.condition.default end) == $guard.condition.equals
    ' >/dev/null
}

linux_agent_backup_policy_review() {
    local ref="$1" args_json="$2" review_json="$3"
    local guard proof_valid finding message

    guard="$(linux_agent_skill_guard_json "${ref}" backup_proof 2>/dev/null || true)"
    if ! jq -e 'type == "object"' <<<"${guard}" >/dev/null 2>&1 ||
        ! linux_agent_skill_guard_condition_matches "${guard}" "${args_json}"; then
        printf '%s\n' "${review_json}"
        return 0
    fi

    proof_valid="$(jq -r -n --argjson guard "${guard}" --argjson args "${args_json}" '
        def proof_value($proof):
            if ($args | has($proof.argument)) then $args[$proof.argument]
            elif ($proof | has("default")) then $proof.default
            else null end;
        all($guard.proofs[];
            . as $proof
            | proof_value($proof) as $value
            | if $proof.validation == "boolean_true" then $value == true
              elif $proof.validation == "nonempty_string" then
                  ($value | type) == "string" and ($value | length) > 0
              elif $proof.validation == "sha256" then
                  ($value | type) == "string"
                  and ($value | test("^[0-9a-f]{64}$"))
              else false end)
    ')"
    if [[ "${proof_valid}" == "true" ]]; then
        printf '%s\n' "${review_json}"
        return 0
    fi

    message="$(jq -r '.message' <<<"${guard}")"
    finding="$(jq -cn --arg message "${message}" \
        '{severity:"critical",code:"BACKUP_REQUIRED",category:"backup",action:"block",message:$message}')"
    jq -c --argjson finding "${finding}" '
        .findings = ((.findings // []) + [$finding])
        | .approval_required = true
        | .approved = false
        | .risk_level = "critical"
    ' <<<"${review_json}"
}

linux_agent_prepare_backup_protected_step() {
    local step_json="$1"
    local prior_results="${2:-[]}"
    local current_results="${3:-[]}"
    local ref args guard source target_argument normalization target resolved
    local all_results backup_result prepared mapping argument output value

    ref="$(jq -r '.skill_script // empty' <<<"${step_json}")"
    guard="$(linux_agent_skill_guard_json "${ref}" backup_proof 2>/dev/null || true)"
    if ! jq -e '.source | type == "object"' <<<"${guard}" >/dev/null 2>&1; then
        printf '%s\n' "${step_json}"
        return 0
    fi
    args="$(linux_agent_step_arguments_json "${step_json}")"
    if ! linux_agent_skill_guard_condition_matches "${guard}" "${args}"; then
        printf '%s\n' "${step_json}"
        return 0
    fi

    source="$(jq -c '.source' <<<"${guard}")"
    target_argument="$(jq -r '.target_argument' <<<"${source}")"
    normalization="$(jq -r '.target_normalization' <<<"${source}")"
    target="$(jq -r --arg field "${target_argument}" '.[$field] // empty' <<<"${args}")"
    [[ -n "${target}" ]] || {
        printf '%s\n' "${step_json}"
        return 0
    }
    if [[ "${normalization}" == "realpath_existing" ]]; then
        [[ ! -L "${target}" ]] || {
            printf '%s\n' "${step_json}"
            return 0
        }
        resolved="$(realpath -e -- "${target}" 2>/dev/null || true)"
        [[ -n "${resolved}" ]] || {
            printf '%s\n' "${step_json}"
            return 0
        }
        target="${resolved}"
    fi

    all_results="$(printf '%s\n%s\n' "${prior_results}" "${current_results}" |
        jq -cs '.[0] + .[1]' 2>/dev/null || printf '[]')"
    backup_result="$(jq -c \
        --argjson source "${source}" \
        --arg target "${target}" '
        [.[]
         | select((.result.ok // false) == true)
         | . as $result
         | (.result.output // {}) as $output
         | select(($output.tool // "") == $source.tool)
         | select(($output[$source.target_output] // "") == $target)
         | select(all($source.values[];
             . as $mapping
             | ($output[$mapping.output] // null) as $value
             | if $mapping.validation == "nonempty_string" then
                   ($value | type) == "string" and ($value | length) > 0
               elif $mapping.validation == "sha256" then
                   ($value | type) == "string"
                   and ($value | test("^[0-9a-f]{64}$"))
               else false end))
         | $result
        ] | last // empty
    ' <<<"${all_results}" 2>/dev/null || true)"
    [[ -n "${backup_result}" ]] || {
        printf '%s\n' "${step_json}"
        return 0
    }

    prepared="${step_json}"
    while IFS= read -r mapping; do
        [[ -n "${mapping}" ]] || continue
        argument="$(jq -r '.argument' <<<"${mapping}")"
        output="$(jq -r '.output' <<<"${mapping}")"
        value="$(jq -r --arg field "${output}" '.result.output[$field]' <<<"${backup_result}")"
        prepared="$(jq -c --arg field "${argument}" --arg value "${value}" \
            '.arguments = ((.arguments // {}) + {($field):$value})' <<<"${prepared}")"
    done < <(jq -c '.values[]' <<<"${source}")
    printf '%s\n' "${prepared}"
}

linux_agent_prompt_step_decision() {
    local prompt="$1"
    local result_var="$2"
    local answer=""

    while true; do
        if [[ "${LINUX_AGENT_API_MODE:-0}" == "1" ]] && ! linux_agent_api_has_pending_decision_lines; then
            printf -v "${result_var}" '%s' "approval_required"
            return 0
        fi
        if linux_agent_api_read_input_line answer; then
            :
        else
            printf '%s [y/n/s/t]: ' "${prompt}" >&2
            IFS= read -r answer || true
        fi
        case "${answer,,}" in
            y | yes)
                printf -v "${result_var}" '%s' "approve"
                return 0
                ;;
            n | no | "")
                printf -v "${result_var}" '%s' "reject"
                return 0
                ;;
            s | skip)
                printf -v "${result_var}" '%s' "skip"
                return 0
                ;;
            t | terminate)
                printf -v "${result_var}" '%s' "terminate"
                return 0
                ;;
            approval_required)
                printf -v "${result_var}" '%s' "approval_required"
                return 0
                ;;
            *)
                if [[ "${LINUX_AGENT_API_MODE:-0}" == "1" ]]; then
                    printf -v "${result_var}" '%s' "reject"
                    return 0
                fi
                printf '请输入 y 执行、n 拒绝、s 跳过/修改、t 终止。\n' >&2
                ;;
        esac
    done
}

linux_agent_prompt_revision_request() {
    local prompt="$1"
    local result_var="$2"
    local request=""

    if linux_agent_api_read_input_line request; then
        printf -v "${result_var}" '%s' "${request}"
        return 0
    fi
    printf '%s' "${prompt}" >&2
    IFS= read -r request || true
    printf -v "${result_var}" '%s' "${request}"
}

linux_agent_print_work_plan() {
    local plan_json="$1"
    printf '\n# 工作计划\n\n'
    printf '%s\n\n' "$(jq -r '.summary' <<<"${plan_json}")"
    jq -r '.steps[]? | "- \(.id): \(.title) [\(.executor_type), risk=\(.risk_level)]\n  预测: \(.expected_effect)"' <<<"${plan_json}"
    printf '\n'
}

linux_agent_print_step_for_approval() {
    local step_json="$1"
    printf '\n## 当前步骤: %s\n' "$(jq -r '.title' <<<"${step_json}")"
    printf 'ID: %s\n' "$(jq -r '.id' <<<"${step_json}")"
    printf '执行器: %s\n' "$(jq -r '.executor_type' <<<"${step_json}")"
    printf '风险: %s\n' "$(jq -r '.risk_level' <<<"${step_json}")"
    printf '理由: %s\n' "$(jq -r '.reason' <<<"${step_json}")"
    printf '预测效果: %s\n' "$(jq -r '.expected_effect' <<<"${step_json}")"
    case "$(jq -r '.executor_type' <<<"${step_json}")" in
        skill_load)
            printf 'Skill: %s\n' "$(jq -r '.skill' <<<"${step_json}")"
            printf '文件: SKILL.md\n'
            ;;
        skill_read)
            printf 'Skill: %s\n' "$(jq -r '.skill' <<<"${step_json}")"
            printf '文件: %s\n' "$(jq -r '.path' <<<"${step_json}")"
            ;;
        skill_script)
            printf '脚本: %s\n' "$(jq -r '.skill_script' <<<"${step_json}")"
            printf '参数: %s\n' "$(linux_agent_step_arguments_json "${step_json}")"
            ;;
        shell)
            printf '命令: %s\n' "$(jq -r '.command' <<<"${step_json}")"
            ;;
        remote_script)
            printf '远程脚本: %s\n' "$(jq -r '.url // .command // empty' <<<"${step_json}")"
            printf '参数: %s\n' "$(linux_agent_step_arguments_json "${step_json}")"
            if [[ "$(jq -r 'has("sha256")' <<<"${step_json}")" == "true" ]]; then
                printf 'sha256: %s\n' "$(jq -r '.sha256' <<<"${step_json}")"
                printf '大小: %s bytes\n' "$(jq -r '.size_bytes' <<<"${step_json}")"
                printf '行数: %s\n' "$(jq -r '.line_count' <<<"${step_json}")"
                printf '脚本预览（前 40 行，已脱敏）:\n%s\n' "$(jq -r '.preview // ""' <<<"${step_json}")"
            fi
            ;;
        mcp_tool)
            printf 'MCP server: %s\n' "$(jq -r '.mcp_server // empty' <<<"${step_json}")"
            printf 'MCP tool: %s\n' "$(jq -r '.mcp_tool // empty' <<<"${step_json}")"
            printf '参数: %s\n' "$(linux_agent_step_arguments_json "${step_json}")"
            ;;
    esac
}

linux_agent_print_execution_result_summary() {
    local result_json="$1"
    local title="${2:-执行结果}"
    jq -r --arg title "${title}" '
        $title + ": "
        + (if (.ok // false) then "成功" else "失败" end)
        + "，exit_code="
        + ((.exit_code // "unknown") | tostring)
    ' <<<"${result_json}" >&2
}

linux_agent_print_step_result_summary() {
    linux_agent_print_execution_result_summary "$1" "步骤执行结果"
}

linux_agent_output_json_enabled() {
    [[ "${LINUX_AGENT_OUTPUT_JSON:-0}" == "1" ]]
}

linux_agent_user_output_label() {
    local key="$1"
    case "${key}" in
        status) printf '服务状态' ;;
        failed) printf '失败服务' ;;
        load) printf '系统负载' ;;
        memory) printf '内存' ;;
        top_processes) printf '高占用进程' ;;
        disk_usage) printf '磁盘使用' ;;
        top_dirs) printf '目录占用' ;;
        top_files) printf '大文件' ;;
        processes) printf '进程列表' ;;
        zombies) printf '僵尸进程' ;;
        error) printf '错误' ;;
        path | root_path | resolved_path) printf '路径' ;;
        service) printf '服务' ;;
        pattern) printf '匹配条件' ;;
        keyword) printf '关键字' ;;
        matches) printf '匹配结果' ;;
        journal_sample) printf 'Journal 样本' ;;
        candidates) printf '候选项' ;;
        rejected) printf '已排除项' ;;
        summary) printf '摘要' ;;
        archive) printf '备份文件' ;;
        stat) printf '文件状态' ;;
        action) printf '动作' ;;
        reason) printf '原因' ;;
        message) printf '消息' ;;
        reverse_dependencies) printf '反向依赖' ;;
        next_step) printf '下一步' ;;
        cpu_count) printf 'CPU 核心数' ;;
        cpu_model) printf 'CPU 型号' ;;
        min_size_mb) printf '最小大小 MB' ;;
        include_journal) printf '包含 Journal' ;;
        size_bytes) printf '大小 bytes' ;;
        threshold_bytes) printf '阈值 bytes' ;;
        previous_size_bytes) printf '清理前大小 bytes' ;;
        *)
            printf '%s' "${key//_/ }"
            ;;
    esac
}

linux_agent_print_user_output() {
    local result_json="$1"
    local title="${2:-步骤输出}"
    local output_fd="${LINUX_AGENT_USER_OUTPUT_FD:-2}"
    local payload payload_type raw entry key value_type label printed

    if ! printf '%s' "${result_json}" | jq -e . >/dev/null 2>&1; then
        [[ -n "${result_json}" ]] || return 0
        printf '%s:\n%s\n' "${title}" "${result_json}" >&"${output_fd}"
        return 0
    fi

    if [[ "$(jq -r 'if type == "object" and has("output") then "yes" else "no" end' <<<"${result_json}")" == "yes" ]]; then
        payload="$(jq -c '.output' <<<"${result_json}")"
    else
        payload="$(jq -c '.' <<<"${result_json}")"
    fi

    payload_type="$(jq -r 'type' <<<"${payload}")"
    if [[ "${payload_type}" == "null" ]]; then
        return 0
    fi

    if [[ "${payload_type}" == "object" && "$(jq -r 'has("raw")' <<<"${payload}")" == "true" ]]; then
        raw="$(jq -r '.raw // empty' <<<"${payload}")"
        [[ -n "${raw}" ]] || return 0
        printf '%s:\n%s\n' "${title}" "${raw}" >&"${output_fd}"
        return 0
    fi

    if [[ "${payload_type}" == "string" ]]; then
        raw="$(jq -r '.' <<<"${payload}")"
        [[ -n "${raw}" ]] || return 0
        printf '%s:\n%s\n' "${title}" "${raw}" >&"${output_fd}"
        return 0
    fi

    if [[ "${payload_type}" != "object" ]]; then
        printf '%s:\n' "${title}" >&"${output_fd}"
        jq . <<<"${payload}" >&"${output_fd}"
        return 0
    fi

    printed=0
    while IFS= read -r entry; do
        key="$(jq -r '.key' <<<"${entry}")"
        value_type="$(jq -r '.value | type' <<<"${entry}")"
        label="$(linux_agent_user_output_label "${key}")"
        if [[ "${printed}" -eq 0 ]]; then
            printf '%s:\n' "${title}" >&"${output_fd}"
            printed=1
        else
            printf '\n' >&"${output_fd}"
        fi

        if [[ "${value_type}" == "string" ]]; then
            printf '%s:\n' "${label}" >&"${output_fd}"
            jq -r '.value' <<<"${entry}" >&"${output_fd}"
        elif [[ "${value_type}" == "number" || "${value_type}" == "boolean" ]]; then
            printf '%s: %s\n' "${label}" "$(jq -r '.value | tostring' <<<"${entry}")" >&"${output_fd}"
        else
            printf '%s:\n' "${label}" >&"${output_fd}"
            jq '.value' <<<"${entry}" >&"${output_fd}"
        fi
    done < <(jq -c '
        def visible:
            if . == null then false
            elif type == "string" then length > 0
            elif type == "array" then length > 0
            elif type == "object" then length > 0
            else true end;
        with_entries(select((.key != "ok" and .key != "tool") and (.value | visible)))
        | to_entries[]
    ' <<<"${payload}")
}

linux_agent_print_step_output_preview() {
    linux_agent_print_user_output "$1" "步骤输出"
}

linux_agent_print_script_result() {
    local result_json="$1"
    local status_label render_json

    if [[ "$(jq -r '.ok // false' <<<"${result_json}")" == "true" ]]; then
        status_label="成功"
    else
        status_label="失败"
    fi

    if jq -e 'has("status")' <<<"${result_json}" >/dev/null 2>&1; then
        printf '脚本状态: %s\n' "$(jq -r '.status' <<<"${result_json}")"
    else
        printf '脚本执行结果: %s\n' "${status_label}"
    fi
    render_json="$(jq -c 'if type == "object" then del(.status) else . end' <<<"${result_json}")"
    LINUX_AGENT_USER_OUTPUT_FD=1 linux_agent_print_user_output "${render_json}" "脚本输出"
}

linux_agent_print_terminal_stream() {
    local title="$1"
    local text="$2"
    local render_json
    [[ -n "${text}" ]] || return 0

    if printf '%s' "${text}" | jq -e . >/dev/null 2>&1; then
        render_json="$(jq -c . <<<"${text}")"
    else
        render_json="$(jq -cn --arg raw "${text}" '{output:{raw:$raw}}')"
    fi
    LINUX_AGENT_USER_OUTPUT_FD=1 linux_agent_print_user_output "${render_json}" "${title}"
}

linux_agent_print_terminal_result() {
    local result_json="$1"
    local stdout_text stderr_text

    linux_agent_print_execution_result_summary "${result_json}" "终端执行结果"
    stdout_text="$(jq -r '.stdout // empty' <<<"${result_json}")"
    stderr_text="$(jq -r '.stderr // empty' <<<"${result_json}")"
    linux_agent_print_terminal_stream "终端输出" "${stdout_text}"
    linux_agent_print_terminal_stream "终端错误" "${stderr_text}"
}

linux_agent_terminal_review() {
    local command_text="$1"
    local review

    review="$(linux_agent_policy_review_text "terminal" "${command_text}" "local" "terminal")"
    if [[ "$(jq -r '(.approved // false) == true and (.approval_required // false) == false and (.risk_level // "unknown") == "low"' <<<"${review}")" == "true" ]] &&
        [[ "$(linux_agent_auto_approval_enabled shell_readonly)" != "true" ]]; then
        jq -c '
            .approval_required = true
            | .findings = ((.findings // []) + [{
                severity:"low",
                code:"SHELL_AUTO_APPROVAL_DISABLED",
                source:"config",
                message:"低风险 Shell 自动运行开关已关闭，低风险 shell 需要人工确认。"
            }])
        ' <<<"${review}"
        return 0
    fi

    printf '%s\n' "${review}"
}

linux_agent_noninteractive_unknown_command() {
    local review="$1"
    [[ "${LINUX_AGENT_API_MODE:-0}" == "1" ]] || return 1
    jq -e '[.findings[]? | select(.code == "AST_UNKNOWN_COMMAND")] | length > 0' \
        <<<"${review}" >/dev/null 2>&1
}

linux_agent_block_noninteractive_unknown_command_review() {
    local review="$1"
    if ! linux_agent_noninteractive_unknown_command "${review}"; then
        printf '%s\n' "${review}"
        return 0
    fi
    jq -c '
        .approved = false
        | .approval_required = true
        | .risk_level = "critical"
        | .findings = ((.findings // []) + [{
            severity:"critical",
            code:"NONINTERACTIVE_UNKNOWN_COMMAND_BLOCKED",
            source:"policy",
            category:"unknown_command",
            action:"block",
            message:"Unknown commands are blocked in non-interactive execution."
        }])
    ' <<<"${review}"
}

linux_agent_print_work_execution_status() {
    local execution_json="$1"
    jq -r '
        "工作流执行完成: status=" + (.status // "unknown")
        + "，steps=" + ((.results // []) | length | tostring)
    ' <<<"${execution_json}"
}

linux_agent_compact_execution_result() {
    local execution_json="$1"
    jq -c '
        {
            status,
            execution_user,
            sudo_probe,
            findings,
            review,
            approval_step,
            iterations,
            auto_executed_count,
            final_answer,
            checkpoint_required,
            stopped_reason,
            results:[
                .results[]? | {
                    step:{
                        id:.step.id,
                        title:.step.title,
                        executor_type:.step.executor_type,
                        risk_level:(.step.risk_level // null),
                        skill:(.step.skill // null),
                        path:(.step.path // null),
                        skill_script:(.step.skill_script // null),
                        command:(.step.command // null)
                    },
                    result:{
                        ok:(.result.ok // false),
                        status:(.result.status // null),
                        exit_code:(.result.exit_code // null),
                        tool:(.result.output.tool // null),
                        action:(.result.output.action // null),
                        output:(.result.output // null),
                        auto_approved:(.result.auto_approved // false),
                        execution_proxy:(.result.execution_proxy // null),
                        observer:(.result.observer // null)
                    }
                }
            ]
        }
    ' <<<"${execution_json}"
}

linux_agent_download_remote_script() {
    local url="$1"
    local output_path="$2"
    local check resolve_entry
    local -a resolve_args=()
    check="$(python3 "${LINUX_AGENT_ROOT}/lib/provider_security.py" validate \
        "${url}" \
        '{"require_https":true,"block_internal_addresses":true,"allowed_hosts":[]}')" || return 1
    [[ "$(jq -r '.ok // false' <<<"${check}")" == "true" ]] || return 1
    while IFS= read -r resolve_entry; do
        [[ -n "${resolve_entry}" ]] || continue
        resolve_args+=(--resolve "${resolve_entry}")
    done < <(jq -r '.curl_resolve[]? // empty' <<<"${check}")
    [[ "${#resolve_args[@]}" -gt 0 ]] || return 1
    curl -q -fsS --noproxy '*' --proto '=https' --proto-redir '=https' \
        --max-time 30 --max-filesize 262144 \
        "${resolve_args[@]}" \
        "${url}" -o "${output_path}"
}

linux_agent_remote_script_policy() {
    local policy
    policy="$(linux_agent_config_get_default '.remote_script_policy' 'download_review')"
    case "${policy}" in
        download_review | disabled)
            printf '%s\n' "${policy}"
            ;;
        *)
            printf 'download_review\n'
            ;;
    esac
}

linux_agent_step_review_material() {
    local step_json="$1"
    local executor_type
    executor_type="$(jq -r '.executor_type' <<<"${step_json}")"

    case "${executor_type}" in
        skill_load | skill_read)
            printf ''
            ;;
        skill_script)
            local ref args content
            ref="$(jq -r '.skill_script' <<<"${step_json}")"
            args="$(linux_agent_step_arguments_json "${step_json}")"
            content="$(linux_agent_skill_script_content "${ref}" 2>/dev/null || true)"
            printf 'skill_script=%s\narguments=%s\n%s\n' "${ref}" "${args}" "${content}"
            ;;
        shell)
            jq -r '.command // empty' <<<"${step_json}"
            ;;
        remote_script)
            jq -r '.downloaded_path // empty' <<<"${step_json}" | while IFS= read -r downloaded_path; do
                if [[ -n "${downloaded_path}" && -f "${downloaded_path}" ]]; then
                    cat "${downloaded_path}"
                fi
            done
            ;;
        mcp_tool)
            linux_agent_mcp_step_review_material "${step_json}"
            ;;
        *)
            printf ''
            ;;
    esac
}

linux_agent_prepare_remote_step() {
    local step_json="$1"
    local url tmp_path sha size line_count preview raw_preview policy
    policy="$(linux_agent_remote_script_policy)"
    if [[ "${policy}" == "disabled" ]]; then
        jq -cn --arg error "远程脚本策略已禁用。" '{ok:false, error:$error}'
        return 1
    fi

    url="$(jq -r '.url // .command // empty' <<<"${step_json}")"
    if [[ -z "${url}" || ! "${url}" =~ ^https:// ]]; then
        jq -cn --arg error "远程脚本必须提供 https URL。" --arg url "${url}" '{ok:false, error:$error, url:$url}'
        return 1
    fi

    tmp_path="${LINUX_AGENT_RUNNER_TMP_DIR:-${LINUX_AGENT_TMP_DIR}}/remote_$(date +%Y%m%d_%H%M%S)_${RANDOM}.sh"
    if ! linux_agent_download_remote_script "${url}" "${tmp_path}"; then
        rm -f -- "${tmp_path}"
        jq -cn --arg error "远程脚本下载失败。" --arg url "${url}" '{ok:false, error:$error, url:$url}'
        return 1
    fi
    sha="$(sha256sum "${tmp_path}" | awk '{print $1}')"
    size="$(wc -c <"${tmp_path}" | tr -d ' ')"
    if [[ ! "${size}" =~ ^[0-9]+$ || "${size}" -eq 0 ]]; then
        rm -f -- "${tmp_path}"
        jq -cn --arg error "远程脚本为空。" --arg url "${url}" --arg sha256 "${sha}" '{ok:false, error:$error, url:$url, sha256:$sha256}'
        return 1
    fi
    if [[ "${size}" -gt 262144 ]]; then
        rm -f -- "${tmp_path}"
        jq -cn --arg error "远程脚本超过 256KB 限制。" --arg url "${url}" --arg sha256 "${sha}" --argjson size "${size}" \
            '{ok:false, error:$error, url:$url, sha256:$sha256, size_bytes:$size}'
        return 1
    fi
    if ! grep -Iq . "${tmp_path}"; then
        rm -f -- "${tmp_path}"
        jq -cn --arg error "远程脚本不是文本内容。" --arg url "${url}" --arg sha256 "${sha}" --argjson size "${size}" \
            '{ok:false, error:$error, url:$url, sha256:$sha256, size_bytes:$size}'
        return 1
    fi
    if linux_agent_managed_mode_enabled 2>/dev/null; then
        chmod 0640 "${tmp_path}" || {
            rm -f -- "${tmp_path}"
            jq -cn --arg error "无法设置 Runner 脚本读取权限。" '{ok:false, error:$error}'
            return 1
        }
    fi

    line_count="$(awk 'END {print NR + 0}' "${tmp_path}")"
    raw_preview="$(head -n 40 "${tmp_path}")"
    preview="$(linux_agent_sanitize_text "${raw_preview}" 4000)"
    jq -c \
        --arg path "${tmp_path}" \
        --arg sha256 "${sha}" \
        --arg preview "${preview}" \
        --argjson size "${size}" \
        --argjson line_count "${line_count:-0}" \
        '. + {
            downloaded_path:$path,
            sha256:$sha256,
            size_bytes:$size,
            line_count:$line_count,
            preview:$preview,
            risk_level:(if .risk_level == "critical" then "critical" else "high" end)
        }' <<<"${step_json}"
}

linux_agent_normalize_skill_execution_result() {
    local result_json="$1"

    jq -c '
        if (.output_integrity_unknown // false) == true then
            .ok = false
            | .status = (.status // "invalid_output")
            | .code = (.code // "invalid_output")
            | .error_code = (.error_code // .code)
            | .error = (.error // "Skill output integrity could not be established.")
        elif (.output_capped // false) == true then
            .ok = false
            | .status = (.status // "output_limit_exceeded")
            | .code = (.code // "output_limit_exceeded")
            | .error_code = (.error_code // .code)
            | .error = (.error // "Skill output exceeded the configured limit.")
        elif (.timed_out // false) == true then
            .ok = false
            | .status = (.status // "timed_out")
            | .code = (.code // "timed_out")
            | .error_code = (.error_code // .code)
        elif (.exit_code | type) != "number" or .exit_code != 0 then
            .ok = false
            | .status = (.status // "skill_exit_failed")
            | .code = (.code // "skill_exit_failed")
            | .error_code = (.error_code // .code)
        elif (.output | type) != "object" then
            .ok = false
            | .status = "invalid_skill_output"
            | .code = "invalid_skill_output"
            | .error_code = "invalid_skill_output"
            | .error = "Skill stdout must be one JSON object with ok=true."
        elif (.output | has("ok") | not) or ((.output.ok | type) != "boolean") then
            .ok = false
            | .status = "invalid_skill_output"
            | .code = "invalid_skill_output"
            | .error_code = "invalid_skill_output"
            | .error = "Skill JSON output must contain a boolean ok field."
        elif .output.ok != true then
            .ok = false
            | .status = (.output.status // "skill_reported_failure")
            | .code = (.output.code // "skill_reported_failure")
            | .error_code = (.output.error_code // .code)
            | .error = (.output.error // "Skill reported ok=false.")
        else
            .ok = true
            | (if (.output.status // null) != null then .status = .output.status else . end)
        end
    ' <<<"${result_json}"
}

linux_agent_execute_observed_command_output() {
    local scope="$1"
    local subject_json="$2"
    local gate_result
    shift 2
    [[ "${1:-}" == "--" ]] && shift

    # Defense-in-depth gate for direct script/MCP/step dispatch. Work-plan and
    # terminal callers also check before publishing a running state.
    if declare -F linux_agent_observer_execution_gate >/dev/null 2>&1 &&
        ! gate_result="$(linux_agent_observer_execution_gate "${scope}" "${subject_json}")"; then
        printf '%s\n' "${gate_result}"
        return 0
    fi

    if linux_agent_maybe_execute_host_helper_skill "${scope}" "${subject_json}" "$@"; then
        return 0
    fi
    if linux_agent_maybe_execute_credential_helper_skill "${scope}" "${subject_json}" "$@"; then
        return 0
    fi

    local stdout_file stderr_file run_meta exit_code observer stdout_text stderr_text combined timed_out
    local is_skill_scope=false parsed_output="" parsed_output_is_json=false
    local result_json
    local requested_privilege proxy_meta proxy_error
    local -a prepared_command

    requested_privilege="${LINUX_AGENT_EXECUTION_PRIVILEGE:-least}"
    if ! linux_agent_prepare_execution_command "${requested_privilege}" prepared_command "$@"; then
        if [[ "${LINUX_AGENT_EXECUTION_PREPARE_ERROR_CODE:-}" == "runner_unavailable" ]]; then
            proxy_error="managed execution runner is unavailable; refusing same-UID fallback"
        elif [[ "${LINUX_AGENT_EXECUTION_PREPARE_ERROR_CODE:-}" == "runner_rejected" ]]; then
            proxy_error="managed execution request is outside the runner contract"
        else
            proxy_error="least privilege proxy is unavailable; refusing to run as root without an explicit privileged path"
        fi
        proxy_meta="$(linux_agent_execution_proxy_metadata "${requested_privilege}" "false" "${proxy_error}")"
        jq -cn \
            --arg output "${proxy_error}" \
            --arg code "${LINUX_AGENT_EXECUTION_PREPARE_ERROR_CODE:-execution_proxy_unavailable}" \
            --argjson proxy "${proxy_meta}" \
            '{ok:false, status:$code, code:$code, error_code:$code, exit_code:126, output:{raw:$output}, execution_proxy:$proxy}'
        linux_agent_cleanup_execution_staging
        return 0
    fi
    if [[ "${requested_privilege}" == "least" && "$(id -u)" -eq 0 ]]; then
        proxy_meta="$(linux_agent_execution_proxy_metadata "${requested_privilege}" "true")"
    else
        proxy_meta="$(linux_agent_execution_proxy_metadata "${requested_privilege}" "false")"
    fi

    stdout_file="$(mktemp "${LINUX_AGENT_TMP_DIR}/observer.stdout.XXXXXX")"
    stderr_file="$(mktemp "${LINUX_AGENT_TMP_DIR}/observer.stderr.XXXXXX")"

    run_meta="$(linux_agent_run_observed_process "${scope}" "${subject_json}" "${stdout_file}" "${stderr_file}" -- "${prepared_command[@]}")"
    linux_agent_cleanup_execution_staging
    if jq -e '.blocked_result | type == "object"' >/dev/null 2>&1 <<<"${run_meta}"; then
        rm -f "${stdout_file}" "${stderr_file}"
        jq -c '.blocked_result' <<<"${run_meta}"
        return 0
    fi
    exit_code="$(jq -r '.exit_code' <<<"${run_meta}")"
    timed_out="$(jq -r '.timed_out // false' <<<"${run_meta}")"
    observer="$(jq -c '.observer' <<<"${run_meta}")"
    local max_output_bytes output_truncated output_integrity_unknown
    local stdout_truncated_bytes stderr_truncated_bytes
    max_output_bytes="$(linux_agent_execution_max_output_bytes)"
    output_truncated="$(jq -r '.output_capped // false' <<<"${run_meta}")"
    output_integrity_unknown="$(jq -r '.output_integrity_unknown // false' <<<"${run_meta}")"
    stdout_truncated_bytes="$(jq -r '.stdout_truncated_bytes // 0' <<<"${run_meta}")"
    stderr_truncated_bytes="$(jq -r '.stderr_truncated_bytes // 0' <<<"${run_meta}")"
    stdout_text="$(head -c "${max_output_bytes}" "${stdout_file}" 2>/dev/null || true)"
    stderr_text="$(head -c "${max_output_bytes}" "${stderr_file}" 2>/dev/null || true)"
    rm -f "${stdout_file}" "${stderr_file}"

    if [[ "${scope}" == "script" || "${scope}" == "step_skill_script" ]]; then
        is_skill_scope=true
        # Skill protocol is stdout-only. Keep stderr as diagnostics instead
        # of allowing it to corrupt the machine-readable business result.
        # Slurping also rejects concatenated JSON documents.
        if parsed_output="$(printf '%s' "${stdout_text}" | jq -cs 'if length == 1 then .[0] else error("expected exactly one JSON value") end' 2>/dev/null)"; then
            parsed_output_is_json=true
            combined="${parsed_output}"
        else
            combined="${stdout_text}"
        fi
    else
        combined="${stdout_text}"
        if [[ -n "${stderr_text}" ]]; then
            if [[ -n "${combined}" ]]; then
                combined="${combined}"$'\n'"${stderr_text}"
            else
                combined="${stderr_text}"
            fi
        fi

        if [[ "${output_truncated}" == "true" ]]; then
            if [[ -n "${combined}" ]]; then
                combined="${combined}"$'\n'"[output capped at ${max_output_bytes} bytes per stream]"
            else
                combined="[output capped at ${max_output_bytes} bytes per stream]"
            fi
        fi
    fi

    if [[ "${is_skill_scope}" == "true" && "${parsed_output_is_json}" == "true" ]]; then
        result_json="$(
            jq -cn \
                --argjson output "${parsed_output}" \
                --arg stderr "${stderr_text}" \
                --argjson exit_code "${exit_code}" \
                --argjson timed_out "${timed_out}" \
                --argjson observer "${observer}" \
                --argjson proxy "${proxy_meta}" \
                --argjson output_capped "${output_truncated}" \
                --argjson output_integrity_unknown "${output_integrity_unknown}" \
                --argjson stdout_truncated_bytes "${stdout_truncated_bytes}" \
                --argjson stderr_truncated_bytes "${stderr_truncated_bytes}" \
                '{ok:($exit_code == 0), exit_code:$exit_code, timed_out:$timed_out, output:$output, stderr:$stderr, observer:$observer, execution_proxy:$proxy, output_capped:$output_capped, output_integrity_unknown:$output_integrity_unknown, stdout_truncated_bytes:$stdout_truncated_bytes, stderr_truncated_bytes:$stderr_truncated_bytes} + (if $output_integrity_unknown then {status:"invalid_output", code:"invalid_output", error_code:"invalid_output"} elif $output_capped then {status:"output_limit_exceeded", code:"output_limit_exceeded", error_code:"output_limit_exceeded"} elif $timed_out then {status:"timed_out", code:"timed_out", error_code:"timed_out"} else {} end)'
        )"
    elif [[ "${is_skill_scope}" == "true" ]]; then
        result_json="$(
            jq -cn \
                --arg output "${combined}" \
                --arg stderr "${stderr_text}" \
                --argjson exit_code "${exit_code}" \
                --argjson timed_out "${timed_out}" \
                --argjson observer "${observer}" \
                --argjson proxy "${proxy_meta}" \
                --argjson output_capped "${output_truncated}" \
                --argjson output_integrity_unknown "${output_integrity_unknown}" \
                --argjson stdout_truncated_bytes "${stdout_truncated_bytes}" \
                --argjson stderr_truncated_bytes "${stderr_truncated_bytes}" \
                '{ok:($exit_code == 0), exit_code:$exit_code, timed_out:$timed_out, output:{raw:(if $timed_out and $output == "" then "执行超过配置的 execution.timeout_sec，已终止。" else $output end)}, stderr:$stderr, observer:$observer, execution_proxy:$proxy, output_capped:$output_capped, output_integrity_unknown:$output_integrity_unknown, stdout_truncated_bytes:$stdout_truncated_bytes, stderr_truncated_bytes:$stderr_truncated_bytes} + (if $output_integrity_unknown then {status:"invalid_output", code:"invalid_output", error_code:"invalid_output"} elif $output_capped then {status:"output_limit_exceeded", code:"output_limit_exceeded", error_code:"output_limit_exceeded"} elif $timed_out then {status:"timed_out", code:"timed_out", error_code:"timed_out"} else {} end)'
        )"
    elif printf '%s' "${combined}" | jq -e . >/dev/null 2>&1; then
        result_json="$(
            jq -cn \
                --argjson output "$(printf '%s' "${combined}" | jq -c .)" \
                --argjson exit_code "${exit_code}" \
                --argjson timed_out "${timed_out}" \
                --argjson observer "${observer}" \
                --argjson proxy "${proxy_meta}" \
                --argjson output_capped "${output_truncated}" \
                --argjson output_integrity_unknown "${output_integrity_unknown}" \
                --argjson stdout_truncated_bytes "${stdout_truncated_bytes}" \
                --argjson stderr_truncated_bytes "${stderr_truncated_bytes}" \
                '{ok:($exit_code == 0), exit_code:$exit_code, timed_out:$timed_out, output:$output, observer:$observer, execution_proxy:$proxy, output_capped:$output_capped, output_integrity_unknown:$output_integrity_unknown, stdout_truncated_bytes:$stdout_truncated_bytes, stderr_truncated_bytes:$stderr_truncated_bytes} + (if $output_integrity_unknown then {status:"invalid_output", code:"invalid_output", error_code:"invalid_output"} elif $output_capped then {status:"output_limit_exceeded", code:"output_limit_exceeded", error_code:"output_limit_exceeded"} elif $timed_out then {status:"timed_out"} else {} end)'
        )"
    else
        result_json="$(
            jq -cn \
                --arg output "${combined}" \
                --argjson exit_code "${exit_code}" \
                --argjson timed_out "${timed_out}" \
                --argjson observer "${observer}" \
                --argjson proxy "${proxy_meta}" \
                --argjson output_capped "${output_truncated}" \
                --argjson output_integrity_unknown "${output_integrity_unknown}" \
                --argjson stdout_truncated_bytes "${stdout_truncated_bytes}" \
                --argjson stderr_truncated_bytes "${stderr_truncated_bytes}" \
                '{ok:($exit_code == 0), exit_code:$exit_code, timed_out:$timed_out, output:{raw:(if $timed_out and $output == "" then "执行超过配置的 execution.timeout_sec，已终止。" else $output end)}, observer:$observer, execution_proxy:$proxy, output_capped:$output_capped, output_integrity_unknown:$output_integrity_unknown, stdout_truncated_bytes:$stdout_truncated_bytes, stderr_truncated_bytes:$stderr_truncated_bytes} + (if $output_integrity_unknown then {status:"invalid_output", code:"invalid_output", error_code:"invalid_output"} elif $output_capped then {status:"output_limit_exceeded", code:"output_limit_exceeded", error_code:"output_limit_exceeded"} elif $timed_out then {status:"timed_out"} else {} end)'
        )"
    fi

    if [[ "${scope}" == "script" || "${scope}" == "step_skill_script" ]]; then
        result_json="$(linux_agent_normalize_skill_execution_result "${result_json}")"
    fi
    printf '%s\n' "${result_json}"
}

linux_agent_execute_skill_file_step() {
    local step_json="$1" executor_type skill_name relative_path read_result source_path relative_source
    executor_type="$(jq -r '.executor_type' <<<"${step_json}")"
    skill_name="$(jq -r '.skill // empty' <<<"${step_json}")"
    if [[ "${executor_type}" == "skill_load" ]]; then
        relative_path="SKILL.md"
    else
        relative_path="$(jq -r '.path // empty' <<<"${step_json}")"
    fi

    read_result="$(linux_agent_skill_read "${skill_name}" "${relative_path}")"
    if ! jq -e 'type == "object" and (.ok | type == "boolean")' <<<"${read_result}" >/dev/null 2>&1; then
        jq -cn --arg executor_type "${executor_type}" '{
            ok:false,
            status:"invalid_output",
            code:"invalid_output",
            error_code:"invalid_output",
            exit_code:1,
            output:{raw:("invalid " + $executor_type + " result")}
        }'
        return 0
    fi
    if [[ "$(jq -r '.ok' <<<"${read_result}")" != "true" ]]; then
        jq -cn --argjson read "${read_result}" '{
            ok:false,
            status:($read.status // "failed"),
            code:($read.code // "skill_operation_failed"),
            error_code:($read.code // "skill_operation_failed"),
            exit_code:1,
            output:$read
        }'
        return 0
    fi

    source_path="$(jq -r '.source_path // empty' <<<"${read_result}")"
    if [[ -z "${source_path}" || ! -f "${source_path}" || -L "${source_path}" ]]; then
        jq -cn --arg skill "${skill_name}" --arg path "${relative_path}" '{
            ok:false,
            status:"skill_operation_failed",
            code:"skill_operation_failed",
            error_code:"skill_operation_failed",
            exit_code:1,
            output:{skill:$skill,path:$path,error:"Skill disclosure source changed during read"}
        }'
        return 0
    fi
    relative_source="${source_path}"
    if [[ "${source_path}" == "${LINUX_AGENT_ROOT}/"* ]]; then
        relative_source="${source_path#${LINUX_AGENT_ROOT}/}"
    fi
    jq -cn \
        --argjson read "${read_result}" \
        --arg source_path "${source_path}" \
        --arg relative_path "${relative_source}" \
        '{
            ok:true,
            status:"read",
            exit_code:0,
            output:($read + {
                source_path:$source_path,
                relative_path:$relative_path
            })
        }'
}

linux_agent_execute_step_command() {
    local step_json="$1"
    local review_json="${2:-}"
    local executor_type subject
    local -a command_args
    executor_type="$(jq -r '.executor_type' <<<"${step_json}")"

    case "${executor_type}" in
        skill_load | skill_read)
            linux_agent_execute_skill_file_step "${step_json}"
            return 0
            ;;
        mcp_tool)
            linux_agent_execute_mcp_tool_step "${step_json}" "${review_json}"
            return 0
            ;;
        skill_script)
            local ref script_path args
            ref="$(jq -r '.skill_script' <<<"${step_json}")"
            script_path="$(linux_agent_skill_script_path "${ref}")"
            args="$(linux_agent_step_arguments_json "${step_json}")"
            command_args=(bash "${script_path}" "${args}")
            ;;
        shell)
            command_args=(bash -lc "$(jq -r '.command // empty' <<<"${step_json}")")
            ;;
        remote_script)
            command_args=(bash "$(jq -r '.downloaded_path' <<<"${step_json}")" "$(linux_agent_step_arguments_json "${step_json}")")
            ;;
        *)
            jq -cn --arg executor_type "${executor_type}" \
                '{ok:false, exit_code:2, output:{raw:("unsupported executor_type: " + $executor_type)}}'
            return 0
            ;;
    esac

    subject="$(jq -cn --argjson step "${step_json}" '{kind:"work_step", step:$step}')"
    if [[ -z "${review_json}" ]]; then
        review_json='{}'
    fi
    LINUX_AGENT_EXECUTION_PRIVILEGE="$(linux_agent_execution_privilege_from_review "${review_json}")" \
        linux_agent_execute_observed_command_output "step_${executor_type}" "${subject}" -- "${command_args[@]}"
}

linux_agent_prepare_mcp_arguments_file() {
    local args_json="$1"
    local args_file target_user

    args_file="$(mktemp "${LINUX_AGENT_RUNNER_TMP_DIR:-${LINUX_AGENT_TMP_DIR}}/mcp.args.XXXXXX")"
    if linux_agent_managed_mode_enabled 2>/dev/null; then
        chmod 0640 "${args_file}" 2>/dev/null || true
    else
        chmod 0600 "${args_file}" 2>/dev/null || true
    fi
    printf '%s\n' "${args_json}" >"${args_file}"
    if [[ "$(id -u)" -eq 0 && "$(linux_agent_min_privilege_proxy_enabled)" == "true" ]]; then
        target_user="$(linux_agent_least_privilege_user 2>/dev/null || true)"
        if [[ -n "${target_user}" ]]; then
            chown "${target_user}" "${args_file}" 2>/dev/null || chmod 644 "${args_file}" 2>/dev/null || true
        fi
    fi
    printf '%s\n' "${args_file}"
}

linux_agent_execute_mcp_tool_step() {
    local step_json="$1"
    local review_json="${2:-}"
    local server_id tool_name args manifest_path client subject args_file observed
    [[ -n "${review_json}" ]] || review_json='{}'

    server_id="$(jq -r '.mcp_server // empty' <<<"${step_json}")"
    tool_name="$(jq -r '.mcp_tool // empty' <<<"${step_json}")"
    args="$(linux_agent_step_arguments_json "${step_json}")"
    if ! manifest_path="$(linux_agent_mcp_manifest_path_by_id "${server_id}")"; then
        jq -cn --arg server_id "${server_id}" --arg tool "${tool_name}" \
            '{ok:false, status:"server_not_found", exit_code:2, output:{tool:("mcp." + $server_id + "." + $tool), error:"MCP server 未安装。"}}'
        return 0
    fi
    if ! client="$(linux_agent_mcp_client_path)"; then
        jq -cn --arg server_id "${server_id}" --arg tool "${tool_name}" \
            '{ok:false, status:"mcp_client_unavailable", exit_code:2, output:{tool:("mcp." + $server_id + "." + $tool), error:"lib/mcp_client.py 不存在。"}}'
        return 0
    fi

    args_file="$(linux_agent_prepare_mcp_arguments_file "${args}")"
    subject="$(jq -cn --argjson step "${step_json}" '{kind:"work_step", external:"mcp", step:$step}')"
    observed="$(
        LINUX_AGENT_EXECUTION_PRIVILEGE="$(linux_agent_execution_privilege_from_review "${review_json}")" \
            linux_agent_execute_observed_command_output "step_mcp_tool" "${subject}" -- python3 "${client}" call-tool "${manifest_path}" "${tool_name}" "${args_file}"
    )"
    rm -f "${args_file}"

    # The observer gate is an execution-layer result, not an MCP helper payload.
    # Preserve its status/error code verbatim so the work-plan caller can mark
    # the step blocked instead of treating it as a failed MCP invocation.
    if [[ "$(jq -r '.status // ""' <<<"${observed}")" == "blocked" ]]; then
        printf '%s\n' "${observed}"
        return 0
    fi

    jq -cn \
        --argjson observed "${observed}" \
        --arg server_id "${server_id}" \
        --arg tool "${tool_name}" \
        '
        ($observed.output // {}) as $helper
        | {
            ok:(($observed.ok // false) and (($helper.ok // false) == true)),
            status:(
                if (($observed.ok // false) and (($helper.ok // false) == true)) then ($helper.status // "executed")
                else ($helper.status // "failed") end
            ),
            exit_code:($observed.exit_code // null),
            output:(
                if ($helper.output | type) == "object" then $helper.output
                else {
                    tool:("mcp." + $server_id + "." + $tool),
                    server_id:$server_id,
                    mcp_tool:$tool,
                    error:($helper.error // $observed.output.raw // "MCP tool 执行失败。")
                } end
            ),
            mcp:{
                server_id:$server_id,
                tool:$tool,
                transport:($helper.transport // null),
                result:($helper.result // null),
                status:($helper.status // null)
            },
            observer:($observed.observer // null),
            execution_proxy:($observed.execution_proxy // null)
        }'
}

linux_agent_skipped_steps_after() {
    local plan_json="$1"
    local index="$2"
    jq -c --argjson index "${index}" '.steps[($index + 1):] // []' <<<"${plan_json}"
}

linux_agent_request_repair_plan() {
    local user_input="$1"
    local plan_json="$2"
    local executed_steps="$3"
    local failed_step="$4"
    local failed_result="$5"
    local skipped_steps="$6"
    local failure_context repair

    failure_context="$(jq -cn \
        --arg input "${user_input}" \
        --argjson plan "${plan_json}" \
        --argjson executed_steps "${executed_steps}" \
        --argjson failed_step "${failed_step}" \
        --argjson failed_result "${failed_result}" \
        --argjson skipped_steps "${skipped_steps}" \
        '
        def step_summary($s): {
            id:($s.id // null),
            title:($s.title // null),
            executor_type:($s.executor_type // null),
            skill:($s.skill // null),
            path:($s.path // null),
            skill_script:($s.skill_script // null),
            mcp_server:($s.mcp_server // null),
            mcp_tool:($s.mcp_tool // null),
            risk_level:($s.risk_level // null),
            has_command:($s | has("command")),
            url:($s.url // null),
            sha256:($s.sha256 // null),
            size_bytes:($s.size_bytes // null)
        };
        def result_summary($r): {
            ok:($r.ok // null),
            exit_code:($r.exit_code // null),
            tool:($r.output.tool // null),
            action:($r.output.action // null),
            output_keys:(if ($r.output? | type) == "object" then ($r.output | keys) else [] end)
        };
        {
            current_request:$input,
            plan:{summary:($plan.summary // ""), step_count:(($plan.steps // []) | length), steps:[($plan.steps // [])[] | step_summary(.)]},
            executed_steps:[($executed_steps // [])[] | {step:step_summary(.step), result:result_summary(.result)}],
            failed_step:step_summary($failed_step),
            failed_result:result_summary($failed_result),
            skipped_steps:[($skipped_steps // [])[] | step_summary(.)]
        }')"
    failure_context="$(linux_agent_sanitize_json "${failure_context}")"

    linux_agent_record_ai_request_files "${failure_context}"
    repair="$(linux_agent_call_ai_with_context "生成回滚或报错解决方案" "${failure_context}" "repair")"
    repair="$(linux_agent_normalize_model_response "${repair}")"
    if linux_agent_ai_response_is_error "${repair}"; then
        linux_agent_log_event "repair_failed" "${repair}"
        printf '\n# 回滚或修复建议\n' >&2
        printf '无法生成修复建议: %s\n' "$(linux_agent_ai_error_text "${repair}")" >&2
        return 0
    fi
    if ! linux_agent_validate_work_response "${repair}" || [[ "$(jq -r '.response_type // empty' <<<"${repair}")" != "work_plan" ]]; then
        linux_agent_log_event "repair_invalid_response" "${repair}"
        printf '\n# 回滚或修复建议\n' >&2
        printf '无法生成修复建议: 模型响应不符合 work_plan schema。\n' >&2
        return 0
    fi
    linux_agent_log_event "repair_planned" "${repair}"
    printf '\n# 回滚或修复建议（不会自动执行）\n' >&2
    printf '%s\n' "$(jq . <<<"${repair}")" >&2
}

linux_agent_request_revised_work_plan() {
    local user_input="$1"
    local plan_json="$2"
    local executed_steps="$3"
    local current_step="$4"
    local revision_request="$5"
    local remaining_steps="$6"
    local skill_disclosures="${7:-[]}"
    local revision_context request_context revised_plan

    revision_context="$(jq -cn \
        --arg input "${user_input}" \
        --arg revision_request "${revision_request}" \
        --argjson plan "${plan_json}" \
        --argjson executed_steps "${executed_steps}" \
        --argjson current_step "${current_step}" \
        --argjson remaining_steps "${remaining_steps}" \
        '{
            work_revision:true,
            original_request:$input,
            revision_request:$revision_request,
            plan:{summary:($plan.summary // ""), step_count:(($plan.steps // []) | length), steps:($plan.steps // [])},
            executed_steps:($executed_steps // []),
            skipped_step:$current_step,
            remaining_steps:($remaining_steps // [])
        }')"
    request_context="$(jq -cn \
        --arg mode "work_revision" \
        --arg current_request "${revision_request}" \
        --argjson conversation_context "$(linux_agent_history_window)" \
        '{
            mode:$mode,
            conversation_context:$conversation_context,
            current_request:$current_request
        }')"
    request_context="$(linux_agent_add_skill_context "${request_context}" "work_revision")"
    request_context="$(linux_agent_add_loaded_skill_context "${request_context}" "${skill_disclosures}")"
    request_context="$(linux_agent_add_mcp_context "${request_context}" "work_revision")"

    linux_agent_log_event "work_revision_requested" "${revision_context}"
    linux_agent_record_ai_request_files "${request_context}"
    revised_plan="$(linux_agent_call_ai_with_context "${revision_request}" "${request_context}" "work_plan" "${revision_context}")"
    revised_plan="$(linux_agent_normalize_model_response "${revised_plan}")"
    if ! linux_agent_validate_work_response "${revised_plan}" || [[ "$(jq -r '.response_type // empty' <<<"${revised_plan}")" != "work_plan" ]]; then
        jq -cn --arg error "模型未返回可执行的续写工作计划。" --argjson raw "${revised_plan}" \
            '{ok:false, error:$error, raw:$raw}'
        return 1
    fi

    linux_agent_log_event "revision_planned" "${revised_plan}"
    printf '\n# 根据修改需求生成续写计划\n' >&2
    printf '%s\n' "$(jq . <<<"${revised_plan}")" >&2
    printf '%s\n' "${revised_plan}"
}

linux_agent_plan_step_states() {
    local plan_json="$1"
    local iteration="${2:-0}"
    local scope="${3:-plan}"
    jq -c \
        --arg scope "${scope}" \
        --argjson iteration "${iteration}" '
        [(.steps // []) | to_entries[] | {
            key:($scope + ":" + (.key | tostring) + ":" + (.value.id // ("step-" + (.key | tostring)))),
            step_id:(.value.id // ("step-" + (.key | tostring))),
            step_index:.key,
            iteration:(if $iteration > 0 then $iteration else null end),
            scope:$scope,
            step:.value,
            status:"pending",
            result:null
        }]
    ' <<<"${plan_json}"
}

linux_agent_update_step_state() {
    local states="$1"
    local index="$2"
    local status="$3"
    local detail="${4:-null}"
    printf '%s\n%s\n' "${states}" "${detail}" | jq -cs \
        --argjson index "${index}" \
        --arg status "${status}" '
        def compact_detail:
            if . == null or type != "object" then null
            else {
                ok:(.ok // null),
                approved:(.approved // null),
                status:(.status // null),
                exit_code:(.exit_code // null),
                auto_approved:(.auto_approved // null),
                risk_level:(.risk_level // null),
                findings:(.findings // null),
                output:(
                    if (.output | type) == "object" then {
                        action:(.output.action // null),
                        summary:(.output.summary // null),
                        message:(.output.message // null),
                        raw:(if (.output.raw | type) == "string" then .output.raw[0:2000] else null end)
                    } | with_entries(select(.value != null))
                    else null end
                )
            } | with_entries(select(.value != null))
            end;
        .[0] as $states
        | .[1] as $detail
        | $states
        | map(
            if .step_index == $index then
                .status = $status
                | .result = ($detail | compact_detail)
            else . end
        )
    '
}

linux_agent_skip_remaining_step_states() {
    local states="$1"
    local index="$2"
    jq -c --argjson index "${index}" '
        map(
            if .step_index > $index and .status == "pending" then
                .status = "skipped_unexecuted"
            else . end
        )
    ' <<<"${states}"
}

linux_agent_restore_step_states_from_results() {
    local states="$1"
    local results="$2"
    printf '%s\n%s\n' "${states}" "${results}" | jq -cs '
        def result_status($result):
            if (($result.output.action // "") == "skipped_by_user") or (($result.status // "") == "skipped_user") then "skipped_user"
            elif ($result.ok // false) then "succeeded"
            elif (["blocked", "rejected", "terminated", "approval_required"] | index($result.status // "")) != null then $result.status
            else "failed" end;
        .[0] as $states
        | .[1] as $results
        | reduce ($results | to_entries[]) as $entry ($states;
            if $entry.key < length then
                .[$entry.key].status = result_status($entry.value.result // {})
                | .[$entry.key].result = ($entry.value.result // null)
            else . end
        )
    '
}

linux_agent_finalize_work_plan_execution() {
    local execution_json="$1"
    local plan_json="$2"
    local step_states="$3"
    local iteration="$4"
    local scope="$5"
    local next_step_index="$6"
    local prior_results="${7:-[]}"
    local prior_step_states="${8:-[]}"
    printf '%s\n%s\n%s\n%s\n%s\n' \
        "${execution_json}" \
        "${plan_json}" \
        "${step_states}" \
        "${prior_results}" \
        "${prior_step_states}" |
        jq -cs \
            --argjson iteration "${iteration}" \
            --arg scope "${scope}" \
            --argjson next_step_index "${next_step_index}" '
        .[0] as $execution
        | .[1] as $plan
        | .[2] as $current_step_states
        | .[3] as $prior_results
        | .[4] as $prior_step_states
        |
        ($execution.results // []) as $current_results
        | $execution + {
            current_plan:$plan,
            iteration:(if $iteration > 0 then $iteration else null end),
            step_scope:$scope,
            next_step_index:$next_step_index,
            resume_results:$current_results,
            current_step_states:$current_step_states,
            results:($prior_results + $current_results),
            step_states:($prior_step_states + $current_step_states),
            resume_state:{
                current_plan:$plan,
                iteration:$iteration,
                step_scope:$scope,
                next_step_index:$next_step_index,
                results:$current_results,
                step_states:$current_step_states,
                prior_results:$prior_results,
                prior_step_states:$prior_step_states
            }
        }
    '
}

linux_agent_finalize_work_precondition_block() {
    local result_json="$1"
    local step_json="$2"
    local plan_json="$3"
    local step_states="$4"
    local step_index="$5"
    local iteration="$6"
    local step_scope="$7"
    local results="$8"
    local prior_results="$9"
    local prior_step_states="${10}"
    local execution_user="${11}"
    local sudo_probe="${12}"
    local blocked_states blocked_results execution_result

    blocked_states="$(linux_agent_update_step_state "${step_states}" "${step_index}" "blocked" "${result_json}")"
    blocked_states="$(linux_agent_skip_remaining_step_states "${blocked_states}" "${step_index}")"
    blocked_results="$(jq -cn \
        --argjson prior "${results}" \
        --arg step_key "$(jq -r --argjson index "${step_index}" '.[$index].key' <<<"${blocked_states}")" \
        --argjson step_index "${step_index}" \
        --argjson iteration "${iteration}" \
        --arg scope "${step_scope}" \
        --argjson step "${step_json}" \
        --argjson result "${result_json}" \
        '$prior + [{step_key:$step_key, step_index:$step_index, iteration:$iteration, scope:$scope, step:$step, result:$result}]')"
    execution_result="$(jq -cn \
        --arg execution_user "${execution_user}" \
        --arg sudo_probe "${sudo_probe}" \
        --argjson results "${blocked_results}" \
        '{status:"blocked", execution_user:$execution_user, sudo_probe:$sudo_probe, results:$results}')"
    linux_agent_finalize_work_plan_execution \
        "${execution_result}" \
        "${plan_json}" \
        "${blocked_states}" \
        "${iteration}" \
        "${step_scope}" \
        "${step_index}" \
        "${prior_results}" \
        "${prior_step_states}"
}

linux_agent_audit_precondition_failure_result() {
    local audit_rc="${1:-4}"
    local stage="${2:-audit}"

    if declare -F linux_agent_audit_failure_result >/dev/null 2>&1; then
        linux_agent_audit_failure_result "${audit_rc}" "${stage}"
    else
        jq -cn --arg stage "${stage}" --argjson exit_code "${audit_rc}" '
            {
                ok:false,
                status:"blocked",
                code:"audit_integrity_broken",
                error_code:"audit_integrity_broken",
                error:"审计事件无法持久写入，操作未执行。",
                exit_code:$exit_code,
                details:{audit_stage:$stage}
            }'
    fi
}

linux_agent_require_audit_event_result() {
    local stage="$1"
    local payload="${2:-}"
    local audit_rc=0
    [[ -n "${payload}" ]] || payload='{}'

    if ! declare -F linux_agent_audit_require_event >/dev/null 2>&1; then
        return 0
    fi
    linux_agent_audit_require_event "${stage}" "${payload}" || audit_rc=$?
    if ((audit_rc == 0)); then
        return 0
    fi
    linux_agent_audit_precondition_failure_result "${audit_rc}" "${stage}"
    return 1
}

linux_agent_require_step_status_event() {
    local step_json="$1"
    local status="$2"
    local detail="${3:-}"
    local payload
    [[ -n "${detail}" ]] || detail='{}'
    if ! payload="$(jq -cn \
        --arg status "${status}" \
        --argjson step "${step_json}" \
        --argjson detail "${detail}" \
        '{status:$status, step:$step, detail:$detail}' 2>/dev/null)"; then
        linux_agent_audit_precondition_failure_result 4 "step_${status}"
        return 1
    fi
    linux_agent_require_audit_event_result "step_${status}" "${payload}"
}

linux_agent_step_disclosure_block() {
    local step_json="$1" disclosures="${2:-[]}"
    local executor_type skill_name ref
    executor_type="$(jq -r '.executor_type // empty' <<<"${step_json}")"
    case "${executor_type}" in
        skill_load)
            return 1
            ;;
        skill_read)
            skill_name="$(jq -r '.skill // empty' <<<"${step_json}")"
            ;;
        skill_script)
            ref="$(jq -r '.skill_script // empty' <<<"${step_json}")"
            skill_name="${ref%%/*}"
            ;;
        *)
            return 1
            ;;
    esac
    if linux_agent_skill_is_loaded "${skill_name}" "${disclosures}"; then
        return 1
    fi
    jq -cn --arg skill "${skill_name}" --arg executor_type "${executor_type}" '{
        ok:false,
        status:"blocked",
        code:"skill_not_loaded",
        error_code:"skill_not_loaded",
        exit_code:126,
        error:("Skill " + $skill + " must be loaded through skill_load before " + $executor_type),
        findings:[{
            severity:"critical",
            code:"SKILL_NOT_LOADED",
            skill:$skill,
            message:"Work plan attempted to use Skill instructions before controlled disclosure."
        }]
    }'
}

linux_agent_execute_work_plan() {
    local plan_json="$1"
    local user_input="$2"
    local resume_state="${3:-}"
    local iteration="${4:-0}"
    local step_scope="${5:-}"
    local skill_disclosures="${6:-[]}"
    local execution_user sudo_probe step_count results executed_steps status step_states
    local prior_results prior_step_states resume_index restored_result_count execution_result
    [[ -n "${resume_state}" ]] || resume_state='{}'
    if ! jq -e 'type == "array"' <<<"${skill_disclosures}" >/dev/null 2>&1; then
        skill_disclosures='[]'
    fi
    [[ "${iteration}" =~ ^[0-9]+$ ]] || iteration=0
    if [[ -z "${step_scope}" ]]; then
        if ((iteration > 0)); then
            step_scope="iteration-${iteration}"
        else
            step_scope="plan"
        fi
    fi

    execution_user="$(id -un 2>/dev/null || printf 'unknown')"
    sudo_probe="$(linux_agent_probe_sudo)"
    step_count="$(jq '.steps | length' <<<"${plan_json}")"
    results='[]'
    executed_steps='[]'
    status="executed"
    step_states="$(linux_agent_plan_step_states "${plan_json}" "${iteration}" "${step_scope}")"

    if ! jq -e 'type == "object"' <<<"${resume_state}" >/dev/null 2>&1; then
        resume_state='{}'
    fi
    prior_results="$(jq -c '.prior_results // [] | if type == "array" then . else [] end' <<<"${resume_state}")"
    prior_step_states="$(jq -c '.prior_step_states // [] | if type == "array" then . else [] end' <<<"${resume_state}")"
    results="$(jq -c '.results // [] | if type == "array" then . else [] end' <<<"${resume_state}")"
    if jq -e --argjson count "${step_count}" '.step_states | type == "array" and length == $count' <<<"${resume_state}" >/dev/null 2>&1; then
        step_states="$(jq -c '.step_states' <<<"${resume_state}")"
    elif [[ "$(jq 'length' <<<"${results}")" -gt 0 ]]; then
        step_states="$(linux_agent_restore_step_states_from_results "${step_states}" "${results}")"
    fi

    resume_index="$(jq -r '.next_step_index // .start_index // 0' <<<"${resume_state}")"
    if [[ ! "${resume_index}" =~ ^[0-9]+$ ]]; then
        resume_index=0
    fi
    if [[ "${resume_index}" -gt "${step_count}" ]]; then
        resume_index="${step_count}"
    fi
    restored_result_count="$(jq 'length' <<<"${results}")"
    if [[ "${restored_result_count}" -lt "${resume_index}" ]]; then
        resume_index="${restored_result_count}"
    fi
    if [[ "${resume_index}" -gt 0 ]]; then
        executed_steps="$(jq -c '[.[] | select(.result.ok == true)]' <<<"${results}")"
        linux_agent_log_event "execution_resumed" "$(jq -cn \
            --argjson next_step_index "${resume_index}" \
            --argjson restored_result_count "${restored_result_count}" \
            --arg scope "${step_scope}" \
            '{next_step_index:$next_step_index, restored_result_count:$restored_result_count, scope:$scope}')"
    fi

    linux_agent_print_work_plan "${plan_json}" >&2

    local i="${resume_index}"
    while [[ "${i}" -lt "${step_count}" ]]; do
        local step step_review_text review result skipped prepared step_decision revision_request auto_approved disclosure_block
        step="$(jq -c --argjson index "${i}" '.steps[$index]' <<<"${plan_json}")"
        auto_approved=0
        step_states="$(linux_agent_update_step_state "${step_states}" "${i}" "pending" 'null')"
        if ! result="$(linux_agent_require_step_status_event "${step}" "pending")"; then
            linux_agent_finalize_work_precondition_block \
                "${result}" "${step}" "${plan_json}" "${step_states}" "${i}" \
                "${iteration}" "${step_scope}" "${results}" "${prior_results}" \
                "${prior_step_states}" "${execution_user}" "${sudo_probe}"
            return 0
        fi

        if [[ "$(jq -r '.executor_type' <<<"${step}")" == "remote_script" ]]; then
            local prepare_observer_subject
            prepare_observer_subject="$(jq -cn --argjson step "${step}" '{kind:"work_step_prepare", step:$step}')"
            if declare -F linux_agent_observer_execution_gate >/dev/null 2>&1 &&
                ! result="$(linux_agent_observer_execution_gate "step_remote_script_prepare" "${prepare_observer_subject}")"; then
                linux_agent_log_step_status "${step}" "blocked" "${result}" || true
                linux_agent_finalize_work_precondition_block \
                    "${result}" "${step}" "${plan_json}" "${step_states}" "${i}" \
                    "${iteration}" "${step_scope}" "${results}" "${prior_results}" \
                    "${prior_step_states}" "${execution_user}" "${sudo_probe}"
                return 0
            fi
            prepared="$(linux_agent_prepare_remote_step "${step}" 2>&1)" || {
                local failed_detail skipped_steps
                failed_detail="$(jq -cn --arg raw "${prepared}" '{ok:false, status:"failed", output:{raw:$raw}}')"
                step_states="$(linux_agent_update_step_state "${step_states}" "${i}" "failed" "${failed_detail}")"
                step_states="$(linux_agent_skip_remaining_step_states "${step_states}" "${i}")"
                linux_agent_log_step_status "${step}" "failed" "${failed_detail}"
                skipped_steps="$(linux_agent_skipped_steps_after "${plan_json}" "${i}")"
                while IFS= read -r skipped; do
                    [[ -n "${skipped}" ]] && linux_agent_log_step_status "${skipped}" "skipped_unexecuted"
                done < <(jq -c '.[]' <<<"${skipped_steps}")
                linux_agent_request_repair_plan "${user_input}" "${plan_json}" "${executed_steps}" "${step}" "${failed_detail}" "${skipped_steps}"
                execution_result="$(jq -cn --arg execution_user "${execution_user}" --arg sudo_probe "${sudo_probe}" --argjson results "${results}" \
                    '{status:"failed", execution_user:$execution_user, sudo_probe:$sudo_probe, results:$results}')"
                linux_agent_finalize_work_plan_execution "${execution_result}" "${plan_json}" "${step_states}" "${iteration}" "${step_scope}" "${i}" "${prior_results}" "${prior_step_states}"
                return 0
            }
            step="${prepared}"
            printf '远程脚本已下载: %s\nsha256: %s\nsize: %s bytes\n' \
                "$(jq -r '.downloaded_path' <<<"${step}")" \
                "$(jq -r '.sha256' <<<"${step}")" \
                "$(jq -r '.size_bytes' <<<"${step}")" >&2
        fi

        step="$(linux_agent_prepare_backup_protected_step "${step}" "${prior_results}" "${results}")"
        linux_agent_print_step_for_approval "${step}" >&2
        if disclosure_block="$(linux_agent_step_disclosure_block "${step}" "${skill_disclosures}")"; then
            step_states="$(linux_agent_update_step_state "${step_states}" "${i}" "blocked" "${disclosure_block}")"
            step_states="$(linux_agent_skip_remaining_step_states "${step_states}" "${i}")"
            linux_agent_log_step_status "${step}" "blocked" "${disclosure_block}"
            skipped="$(linux_agent_skipped_steps_after "${plan_json}" "${i}")"
            while IFS= read -r skipped_step; do
                [[ -n "${skipped_step}" ]] && linux_agent_log_step_status "${skipped_step}" "skipped_unexecuted"
            done < <(jq -c '.[]' <<<"${skipped}")
            results="$(jq -cn \
                --argjson prior "${results}" \
                --arg step_key "$(jq -r --argjson index "${i}" '.[$index].key' <<<"${step_states}")" \
                --argjson step_index "${i}" \
                --argjson iteration "${iteration}" \
                --arg scope "${step_scope}" \
                --argjson step "${step}" \
                --argjson result "${disclosure_block}" \
                '$prior + [{step_key:$step_key, step_index:$step_index, iteration:$iteration, scope:$scope, step:$step, result:$result}]')"
            execution_result="$(jq -cn --arg execution_user "${execution_user}" --arg sudo_probe "${sudo_probe}" --argjson findings "$(jq '.findings' <<<"${disclosure_block}")" --argjson results "${results}" \
                '{status:"blocked", execution_user:$execution_user, sudo_probe:$sudo_probe, findings:$findings, results:$results}')"
            linux_agent_finalize_work_plan_execution "${execution_result}" "${plan_json}" "${step_states}" "${iteration}" "${step_scope}" "${i}" "${prior_results}" "${prior_step_states}"
            return 0
        fi
        if [[ "$(jq -r '.executor_type' <<<"${step}")" == "skill_script" ]] && ! linux_agent_skill_is_registered "$(jq -r '.skill_script' <<<"${step}")"; then
            local blocked_detail skipped_steps
            blocked_detail="$(jq -cn --arg ref "$(jq -r '.skill_script' <<<"${step}")" '{approved:false, risk_level:"critical", findings:[{severity:"critical", code:"SKILL_SCRIPT_UNREGISTERED", ref:$ref, message:"AI 提出的 skill 脚本未登记。"}]}')"
            step_states="$(linux_agent_update_step_state "${step_states}" "${i}" "blocked" "${blocked_detail}")"
            step_states="$(linux_agent_skip_remaining_step_states "${step_states}" "${i}")"
            linux_agent_log_step_status "${step}" "blocked" "${blocked_detail}"
            skipped_steps="$(linux_agent_skipped_steps_after "${plan_json}" "${i}")"
            while IFS= read -r skipped_step; do
                [[ -n "${skipped_step}" ]] && linux_agent_log_step_status "${skipped_step}" "skipped_unexecuted"
            done < <(jq -c '.[]' <<<"${skipped_steps}")
            execution_result="$(jq -cn --arg execution_user "${execution_user}" --arg sudo_probe "${sudo_probe}" --argjson findings "$(jq '.findings' <<<"${blocked_detail}")" --argjson results "${results}" \
                '{status:"blocked", execution_user:$execution_user, sudo_probe:$sudo_probe, findings:$findings, results:$results}')"
            linux_agent_finalize_work_plan_execution "${execution_result}" "${plan_json}" "${step_states}" "${iteration}" "${step_scope}" "${i}" "${prior_results}" "${prior_step_states}"
            return 0
        fi
        if [[ "$(jq -r '.executor_type' <<<"${step}")" == "mcp_tool" ]] && ! linux_agent_mcp_tool_is_available "$(jq -r '.mcp_server // empty' <<<"${step}")" "$(jq -r '.mcp_tool // empty' <<<"${step}")"; then
            local blocked_detail skipped_steps
            blocked_detail="$(jq -cn \
                --arg server_id "$(jq -r '.mcp_server // empty' <<<"${step}")" \
                --arg tool "$(jq -r '.mcp_tool // empty' <<<"${step}")" \
                '{approved:false, risk_level:"critical", findings:[{severity:"critical", code:"MCP_TOOL_UNAVAILABLE", server_id:$server_id, tool:$tool, message:"AI 提出的 MCP tool 未安装、未启用或未在 tools/list 中声明。"}]}')"
            step_states="$(linux_agent_update_step_state "${step_states}" "${i}" "blocked" "${blocked_detail}")"
            step_states="$(linux_agent_skip_remaining_step_states "${step_states}" "${i}")"
            linux_agent_log_step_status "${step}" "blocked" "${blocked_detail}"
            skipped_steps="$(linux_agent_skipped_steps_after "${plan_json}" "${i}")"
            while IFS= read -r skipped_step; do
                [[ -n "${skipped_step}" ]] && linux_agent_log_step_status "${skipped_step}" "skipped_unexecuted"
            done < <(jq -c '.[]' <<<"${skipped_steps}")
            execution_result="$(jq -cn --arg execution_user "${execution_user}" --arg sudo_probe "${sudo_probe}" --argjson findings "$(jq '.findings' <<<"${blocked_detail}")" --argjson results "${results}" \
                '{status:"blocked", execution_user:$execution_user, sudo_probe:$sudo_probe, findings:$findings, results:$results}')"
            linux_agent_finalize_work_plan_execution "${execution_result}" "${plan_json}" "${step_states}" "${iteration}" "${step_scope}" "${i}" "${prior_results}" "${prior_step_states}"
            return 0
        fi
        step_review_text="$(linux_agent_step_review_material "${step}")"
        review="$(linux_agent_policy_review_step "${step}" "${step_review_text}" "$(case "$(jq -r '.executor_type' <<<"${step}")" in remote_script) printf 'remote' ;; mcp_tool) printf 'mcp' ;; *) printf 'local' ;; esac)")"
        case "$(jq -r '.executor_type' <<<"${step}")" in
            shell | skill_script | remote_script)
                # These step types all execute shell source. Unknown static
                # command heads must remain fail-closed in API/work-plan mode.
                review="$(linux_agent_block_noninteractive_unknown_command_review "${review}")"
                ;;
        esac
        if [[ "$(jq -r '.executor_type' <<<"${step}")" == "skill_script" ]]; then
            review="$(linux_agent_backup_policy_review "$(jq -r '.skill_script // empty' <<<"${step}")" "$(linux_agent_step_arguments_json "${step}")" "${review}")"
        fi
        if ! result="$(linux_agent_require_step_status_event "${step}" "policy_checked" "${review}")"; then
            linux_agent_finalize_work_precondition_block \
                "${result}" "${step}" "${plan_json}" "${step_states}" "${i}" \
                "${iteration}" "${step_scope}" "${results}" "${prior_results}" \
                "${prior_step_states}" "${execution_user}" "${sudo_probe}"
            return 0
        fi

        if [[ "$(jq -r '.approved' <<<"${review}")" != "true" ]]; then
            step_states="$(linux_agent_update_step_state "${step_states}" "${i}" "blocked" "${review}")"
            step_states="$(linux_agent_skip_remaining_step_states "${step_states}" "${i}")"
            linux_agent_log_step_status "${step}" "blocked" "${review}"
            skipped="$(linux_agent_skipped_steps_after "${plan_json}" "${i}")"
            while IFS= read -r skipped_step; do
                [[ -n "${skipped_step}" ]] && linux_agent_log_step_status "${skipped_step}" "skipped_unexecuted"
            done < <(jq -c '.[]' <<<"${skipped}")
            execution_result="$(jq -cn --arg execution_user "${execution_user}" --arg sudo_probe "${sudo_probe}" --argjson findings "$(jq '.findings' <<<"${review}")" --argjson results "${results}" \
                '{status:"blocked", execution_user:$execution_user, sudo_probe:$sudo_probe, findings:$findings, results:$results}')"
            linux_agent_finalize_work_plan_execution "${execution_result}" "${plan_json}" "${step_states}" "${iteration}" "${step_scope}" "${i}" "${prior_results}" "${prior_step_states}"
            return 0
        fi

        if [[ "$(jq -r '.approval_required' <<<"${review}")" == "true" ]]; then
            printf '审查风险: %s，发现项: %s\n' "$(jq -r '.risk_level' <<<"${review}")" "$(jq '.findings | length' <<<"${review}")" >&2
        fi
        if linux_agent_should_auto_execute_step "${step}" "${review}"; then
            step_decision="approve"
            auto_approved=1
            linux_agent_log_step_status "${step}" "auto_approved" "${review}"
            printf '低风险步骤已自动批准执行: %s\n' "$(jq -r '.title' <<<"${step}")" >&2
        else
            linux_agent_prompt_step_decision "批准执行该步骤？" step_decision
        fi
        case "${step_decision}" in
            approval_required)
                step_states="$(linux_agent_update_step_state "${step_states}" "${i}" "approval_required" "${review}")"
                linux_agent_log_step_status "${step}" "approval_required" "${review}"
                execution_result="$(jq -cn \
                    --arg execution_user "${execution_user}" \
                    --arg sudo_probe "${sudo_probe}" \
                    --arg approval_step_key "$(jq -r --argjson index "${i}" '.[$index].key' <<<"${step_states}")" \
                    --argjson approval_step "${step}" \
                    --argjson review "${review}" \
                    --argjson results "${results}" \
                    '{status:"approval_required", execution_user:$execution_user, sudo_probe:$sudo_probe, approval_step:$approval_step, approval_step_key:$approval_step_key, review:$review, results:$results}')"
                linux_agent_finalize_work_plan_execution "${execution_result}" "${plan_json}" "${step_states}" "${iteration}" "${step_scope}" "${i}" "${prior_results}" "${prior_step_states}"
                return 0
                ;;
            reject)
                step_states="$(linux_agent_update_step_state "${step_states}" "${i}" "rejected" 'null')"
                step_states="$(linux_agent_skip_remaining_step_states "${step_states}" "${i}")"
                linux_agent_log_step_status "${step}" "rejected"
                skipped="$(linux_agent_skipped_steps_after "${plan_json}" "${i}")"
                while IFS= read -r skipped_step; do
                    [[ -n "${skipped_step}" ]] && linux_agent_log_step_status "${skipped_step}" "skipped_unexecuted"
                done < <(jq -c '.[]' <<<"${skipped}")
                execution_result="$(jq -cn --arg execution_user "${execution_user}" --arg sudo_probe "${sudo_probe}" --argjson results "${results}" \
                    '{status:"rejected", execution_user:$execution_user, sudo_probe:$sudo_probe, results:$results}')"
                linux_agent_finalize_work_plan_execution "${execution_result}" "${plan_json}" "${step_states}" "${iteration}" "${step_scope}" "${i}" "${prior_results}" "${prior_step_states}"
                return 0
                ;;
            terminate)
                step_states="$(linux_agent_update_step_state "${step_states}" "${i}" "terminated" 'null')"
                step_states="$(linux_agent_skip_remaining_step_states "${step_states}" "${i}")"
                linux_agent_log_step_status "${step}" "terminated"
                skipped="$(linux_agent_skipped_steps_after "${plan_json}" "${i}")"
                while IFS= read -r skipped_step; do
                    [[ -n "${skipped_step}" ]] && linux_agent_log_step_status "${skipped_step}" "skipped_unexecuted"
                done < <(jq -c '.[]' <<<"${skipped}")
                execution_result="$(jq -cn --arg execution_user "${execution_user}" --arg sudo_probe "${sudo_probe}" --argjson results "${results}" \
                    '{status:"terminated", execution_user:$execution_user, sudo_probe:$sudo_probe, results:$results}')"
                linux_agent_finalize_work_plan_execution "${execution_result}" "${plan_json}" "${step_states}" "${iteration}" "${step_scope}" "${i}" "${prior_results}" "${prior_step_states}"
                return 0
                ;;
            skip)
                linux_agent_prompt_revision_request "请输入修改需求（直接回车则跳过当前步骤并继续）: " revision_request
                skipped="$(linux_agent_skipped_steps_after "${plan_json}" "${i}")"
                if [[ -z "${revision_request}" ]]; then
                    result="$(jq -cn '{ok:true, status:"skipped", exit_code:null, output:{action:"skipped_by_user", message:"用户跳过当前步骤。"}}')"
                    step_states="$(linux_agent_update_step_state "${step_states}" "${i}" "skipped_user" "${result}")"
                    linux_agent_log_step_status "${step}" "skipped_user" "${result}"
                    results="$(jq -cn \
                        --argjson prior "${results}" \
                        --arg step_key "$(jq -r --argjson index "${i}" '.[$index].key' <<<"${step_states}")" \
                        --argjson step_index "${i}" \
                        --argjson iteration "${iteration}" \
                        --arg scope "${step_scope}" \
                        --argjson step "${step}" \
                        --argjson result "${result}" \
                        '$prior + [{step_key:$step_key, step_index:$step_index, iteration:$iteration, scope:$scope, step:$step, result:$result}]')"
                    printf '已跳过当前步骤，继续执行后续步骤。\n' >&2
                    i=$((i + 1))
                    continue
                fi

                local revision_detail revised_plan revised_execution revision_resume_state
                revision_detail="$(jq -cn \
                    --arg revision_request "${revision_request}" \
                    --argjson remaining_steps "${skipped}" \
                    '{ok:true, status:"revision_requested", revision_request:$revision_request, remaining_step_count:($remaining_steps | length)}')"
                step_states="$(linux_agent_update_step_state "${step_states}" "${i}" "revision_requested" "${revision_detail}")"
                step_states="$(linux_agent_skip_remaining_step_states "${step_states}" "${i}")"
                linux_agent_log_step_status "${step}" "revision_requested" "${revision_detail}"
                while IFS= read -r skipped_step; do
                    [[ -n "${skipped_step}" ]] && linux_agent_log_step_status "${skipped_step}" "skipped_unexecuted"
                done < <(jq -c '.[]' <<<"${skipped}")

                if ! revised_plan="$(linux_agent_request_revised_work_plan "${user_input}" "${plan_json}" "${executed_steps}" "${step}" "${revision_request}" "${skipped}" "${skill_disclosures}")"; then
                    result="$(jq -cn --arg error "${revised_plan}" '{ok:false, status:"revision_failed", output:{raw:$error}}')"
                    step_states="$(linux_agent_update_step_state "${step_states}" "${i}" "failed" "${result}")"
                    linux_agent_log_step_status "${step}" "failed" "${result}"
                    execution_result="$(jq -cn --arg execution_user "${execution_user}" --arg sudo_probe "${sudo_probe}" --argjson results "${results}" \
                        '{status:"revision_failed", execution_user:$execution_user, sudo_probe:$sudo_probe, results:$results}')"
                    linux_agent_finalize_work_plan_execution "${execution_result}" "${plan_json}" "${step_states}" "${iteration}" "${step_scope}" "${i}" "${prior_results}" "${prior_step_states}"
                    return 0
                fi
                revision_resume_state="$(jq -cn \
                    --argjson prior_results "${prior_results}" \
                    --argjson results "${results}" \
                    --argjson prior_step_states "${prior_step_states}" \
                    --argjson step_states "${step_states}" '
                    {
                        prior_results:($prior_results + $results),
                        prior_step_states:($prior_step_states + $step_states)
                    }
                ')"
                revised_execution="$(linux_agent_execute_work_plan \
                    "${revised_plan}" \
                    "${user_input}" \
                    "${revision_resume_state}" \
                    "${iteration}" \
                    "${step_scope}.revision-${i}" \
                    "${skill_disclosures}")"
                printf '%s\n' "${revised_execution}"
                return 0
                ;;
        esac

        if ! result="$(linux_agent_require_step_status_event "${step}" "approved" "${review}")"; then
            linux_agent_finalize_work_precondition_block \
                "${result}" "${step}" "${plan_json}" "${step_states}" "${i}" \
                "${iteration}" "${step_scope}" "${results}" "${prior_results}" \
                "${prior_step_states}" "${execution_user}" "${sudo_probe}"
            return 0
        fi
        local observer_scope observer_subject
        observer_scope="step_$(jq -r '.executor_type' <<<"${step}")"
        observer_subject="$(jq -cn --argjson step "${step}" '{kind:"work_step", step:$step}')"
        if declare -F linux_agent_observer_execution_gate >/dev/null 2>&1 &&
            ! result="$(linux_agent_observer_execution_gate "${observer_scope}" "${observer_subject}")"; then
            :
        else
            if ! result="$(linux_agent_require_step_status_event "${step}" "running" "${review}")"; then
                linux_agent_finalize_work_precondition_block \
                    "${result}" "${step}" "${plan_json}" "${step_states}" "${i}" \
                    "${iteration}" "${step_scope}" "${results}" "${prior_results}" \
                    "${prior_step_states}" "${execution_user}" "${sudo_probe}"
                return 0
            fi
            result="$(linux_agent_execute_step_command "${step}" "${review}")"
        fi
        if [[ "${auto_approved}" -eq 1 ]]; then
            result="$(jq -c '. + {auto_approved:true}' <<<"${result}")"
        fi
        results="$(jq -cn \
            --argjson prior "${results}" \
            --arg step_key "$(jq -r --argjson index "${i}" '.[$index].key' <<<"${step_states}")" \
            --argjson step_index "${i}" \
            --argjson iteration "${iteration}" \
            --arg scope "${step_scope}" \
            --argjson step "${step}" \
            --argjson result "${result}" \
            '$prior + [{step_key:$step_key, step_index:$step_index, iteration:$iteration, scope:$scope, step:$step, result:$result}]')"

        if [[ "$(jq -r '.ok' <<<"${result}")" == "true" ]]; then
            step_states="$(linux_agent_update_step_state "${step_states}" "${i}" "succeeded" "${result}")"
            linux_agent_log_step_status "${step}" "succeeded" "${result}"
            executed_steps="$(jq -cn --argjson prior "${executed_steps}" --argjson step "${step}" --argjson result "${result}" '$prior + [{step:$step, result:$result}]')"
            linux_agent_print_step_result_summary "${result}"
            linux_agent_print_step_output_preview "${result}"
        else
            if [[ "$(jq -r '.status // ""' <<<"${result}")" == "blocked" ]]; then
                status="blocked"
                step_states="$(linux_agent_update_step_state "${step_states}" "${i}" "blocked" "${result}")"
                step_states="$(linux_agent_skip_remaining_step_states "${step_states}" "${i}")"
                linux_agent_log_step_status "${step}" "blocked" "${result}"
                linux_agent_print_step_result_summary "${result}"
                linux_agent_print_step_output_preview "${result}"
                skipped="$(linux_agent_skipped_steps_after "${plan_json}" "${i}")"
                while IFS= read -r skipped_step; do
                    [[ -n "${skipped_step}" ]] && linux_agent_log_step_status "${skipped_step}" "skipped_unexecuted"
                done < <(jq -c '.[]' <<<"${skipped}")
                execution_result="$(jq -cn --arg status "${status}" --arg execution_user "${execution_user}" --arg sudo_probe "${sudo_probe}" --argjson results "${results}" \
                    '{status:$status, execution_user:$execution_user, sudo_probe:$sudo_probe, results:$results}')"
                linux_agent_finalize_work_plan_execution "${execution_result}" "${plan_json}" "${step_states}" "${iteration}" "${step_scope}" "${i}" "${prior_results}" "${prior_step_states}"
                return 0
            fi
            status="failed"
            step_states="$(linux_agent_update_step_state "${step_states}" "${i}" "failed" "${result}")"
            step_states="$(linux_agent_skip_remaining_step_states "${step_states}" "${i}")"
            linux_agent_log_step_status "${step}" "failed" "${result}"
            linux_agent_print_step_result_summary "${result}"
            linux_agent_print_step_output_preview "${result}"
            skipped="$(linux_agent_skipped_steps_after "${plan_json}" "${i}")"
            while IFS= read -r skipped_step; do
                [[ -n "${skipped_step}" ]] && linux_agent_log_step_status "${skipped_step}" "skipped_unexecuted"
            done < <(jq -c '.[]' <<<"${skipped}")
            linux_agent_request_repair_plan "${user_input}" "${plan_json}" "${executed_steps}" "${step}" "${result}" "${skipped}"
            execution_result="$(jq -cn --arg status "${status}" --arg execution_user "${execution_user}" --arg sudo_probe "${sudo_probe}" --argjson results "${results}" \
                '{status:$status, execution_user:$execution_user, sudo_probe:$sudo_probe, results:$results}')"
            linux_agent_finalize_work_plan_execution "${execution_result}" "${plan_json}" "${step_states}" "${iteration}" "${step_scope}" "${i}" "${prior_results}" "${prior_step_states}"
            return 0
        fi

        i=$((i + 1))
    done

    execution_result="$(jq -cn --arg status "${status}" --arg execution_user "${execution_user}" --arg sudo_probe "${sudo_probe}" --argjson results "${results}" \
        '{status:$status, execution_user:$execution_user, sudo_probe:$sudo_probe, results:$results}')"
    linux_agent_finalize_work_plan_execution "${execution_result}" "${plan_json}" "${step_states}" "${iteration}" "${step_scope}" "${step_count}" "${prior_results}" "${prior_step_states}"
}
