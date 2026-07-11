#!/usr/bin/env bash

set -euo pipefail

linux_agent_doctor_check_command() {
    local name="$1"
    if command -v "${name}" >/dev/null 2>&1; then
        jq -cn --arg name "${name}" '{name:$name, ok:true}'
    else
        jq -cn --arg name "${name}" '{name:$name, ok:false, error:"命令不存在"}'
    fi
}

linux_agent_doctor() {
    local required_commands='["bash","python3","jq","curl","find","du","df","ps","grep","tar","timeout"]'
    local optional_commands='["systemctl","journalctl","ss","ip","lsof","sudo","auditctl","ausearch","auditd"]'
    local required_results='[]'
    local optional_available='[]'
    local optional_missing='[]'
    local config_ok="false"
    local skills_ok="false"
    local command_result remote_json

    while IFS= read -r command_name; do
        required_results="$(jq -cn \
            --argjson prior "${required_results}" \
            --argjson item "$(linux_agent_doctor_check_command "${command_name}")" \
            '$prior + [$item]')"
    done < <(jq -r '.[]' <<<"${required_commands}")

    while IFS= read -r command_name; do
        command_result="$(linux_agent_doctor_check_command "${command_name}")"
        if [[ "$(jq -r '.ok' <<<"${command_result}")" == "true" ]]; then
            optional_available="$(jq -cn \
                --argjson prior "${optional_available}" \
                --arg name "${command_name}" \
                '$prior + [$name]')"
        else
            optional_missing="$(jq -cn \
                --argjson prior "${optional_missing}" \
                --arg name "${command_name}" \
                '$prior + [$name]')"
        fi
    done < <(jq -r '.[]' <<<"${optional_commands}")

    if jq -e . "${LINUX_AGENT_CONFIG_FILE}" >/dev/null 2>&1; then
        config_ok="true"
    fi
    if [[ "$(linux_agent_validate_skills | jq -r '.ok')" == "true" ]]; then
        skills_ok="true"
    fi

    remote_json="$(linux_agent_remote_state_json)"

    jq -cn \
        --argjson required "${required_results}" \
        --argjson optional_available "${optional_available}" \
        --argjson optional_missing "${optional_missing}" \
        --argjson config_ok "${config_ok}" \
        --argjson skills_ok "${skills_ok}" \
        --argjson remote "${remote_json}" \
        --arg root "${LINUX_AGENT_ROOT}" \
        '{
            ok:(($required | map(.ok) | all) and $config_ok and $skills_ok),
            root:$root,
            remote:$remote,
            required_commands:$required,
            optional_available:$optional_available,
            optional_missing:$optional_missing,
            config_ok:$config_ok,
            skills_ok:$skills_ok
        }'
}
