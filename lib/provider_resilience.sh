#!/usr/bin/env bash

set -euo pipefail

linux_agent_provider_resilience_enabled() {
    linux_agent_config_bool_default '.provider_resilience.enabled' 'true'
}

linux_agent_provider_resilience_int() {
    local key="$1" default_value="$2" minimum="$3" maximum="$4"
    local value
    value="$(linux_agent_config_get_default ".provider_resilience.${key}" "${default_value}")"
    if [[ ! "${value}" =~ ^[0-9]+$ || "${value}" -lt "${minimum}" || "${value}" -gt "${maximum}" ]]; then
        value="${default_value}"
    fi
    printf '%s\n' "${value}"
}

linux_agent_provider_circuit_state_path() {
    local resolved_tmp_root
    if [[ -n "${LINUX_AGENT_PROVIDER_CIRCUIT_STATE:-}" ]]; then
        printf '%s\n' "${LINUX_AGENT_PROVIDER_CIRCUIT_STATE}"
    else
        resolved_tmp_root="$(readlink -f -- "${LINUX_AGENT_TMP_ROOT:-${LINUX_AGENT_ROOT}/tmp}" 2>/dev/null || true)"
        [[ -n "${resolved_tmp_root}" ]] || resolved_tmp_root="${LINUX_AGENT_TMP_ROOT:-${LINUX_AGENT_ROOT}/tmp}"
        printf '%s/.shared/provider-circuits.json\n' "${resolved_tmp_root}"
    fi
}

linux_agent_provider_circuit_key() {
    local provider_id="$1" api_url="$2"
    printf '%s\0%s' "${provider_id}" "${api_url}" | sha256sum | awk '{print $1}'
}

linux_agent_provider_circuit_action() {
    local action="$1" key="$2"
    local threshold open_seconds helper state_path
    threshold="$(linux_agent_provider_resilience_int circuit_failure_threshold 5 1 100)"
    open_seconds="$(linux_agent_provider_resilience_int circuit_open_sec 60 1 86400)"
    helper="${LINUX_AGENT_ROOT}/lib/provider_resilience.py"
    state_path="$(linux_agent_provider_circuit_state_path)"
    if [[ ! -f "${helper}" ]]; then
        [[ "${action}" == "allow" ]] && printf '{"allowed":true,"state":"unavailable","retry_after_sec":0}\n'
        return 0
    fi
    python3 "${helper}" "${action}" "${state_path}" "${key}" "${threshold}" "${open_seconds}" 2>/dev/null || {
        [[ "${action}" == "allow" ]] && printf '{"allowed":true,"state":"unavailable","retry_after_sec":0}\n'
        return 0
    }
}

linux_agent_provider_backoff_sleep() {
    local retry_index="$1" initial_ms max_ms delay_ms seconds milliseconds
    initial_ms="$(linux_agent_provider_resilience_int backoff_initial_ms 250 0 60000)"
    max_ms="$(linux_agent_provider_resilience_int backoff_max_ms 2000 0 60000)"
    delay_ms="${initial_ms}"
    while [[ "${retry_index}" -gt 1 && "${delay_ms}" -lt "${max_ms}" ]]; do
        delay_ms=$((delay_ms * 2))
        retry_index=$((retry_index - 1))
    done
    [[ "${delay_ms}" -le "${max_ms}" ]] || delay_ms="${max_ms}"
    [[ "${delay_ms}" -gt 0 ]] || return 0
    seconds=$((delay_ms / 1000))
    milliseconds=$((delay_ms % 1000))
    sleep "${seconds}.$(printf '%03d' "${milliseconds}")"
}

linux_agent_provider_http_retryable() {
    local status="$1"
    [[ "${status}" =~ ^[0-9]{3}$ ]] || return 1
    [[ "${status}" == "408" || "${status}" == "425" || "${status}" == "429" || "${status}" -ge 500 ]]
}

linux_agent_provider_curl_retryable() {
    local status="$1"
    case "${status}" in
        5 | 6 | 7 | 18 | 28 | 35 | 47 | 52 | 55 | 56 | 92) return 0 ;;
        *) return 1 ;;
    esac
}

linux_agent_provider_resilience_event() {
    local stage="$1" payload="$2"
    if declare -F linux_agent_log_event >/dev/null 2>&1; then
        linux_agent_log_event "${stage}" "${payload}"
    fi
}
