#!/usr/bin/env bash

set -euo pipefail

LINUX_AGENT_CONFIG_JSON=""
LINUX_AGENT_API_KEY_SOURCE=""

linux_agent_load_config() {
    linux_agent_require_command jq

    if [[ ! -f "${LINUX_AGENT_CONFIG_FILE}" ]]; then
        cp "${LINUX_AGENT_ROOT}/config/config.example.json" "${LINUX_AGENT_CONFIG_FILE}"
        linux_agent_print_warn "未找到 config/config.json，已根据示例生成，请补充真实配置。"
    fi

    LINUX_AGENT_CONFIG_JSON="$(cat "${LINUX_AGENT_CONFIG_FILE}")"
}

linux_agent_config_get() {
    local key="$1"
    jq -r "${key} // empty" <<<"${LINUX_AGENT_CONFIG_JSON}"
}

linux_agent_config_get_default() {
    local key="$1"
    local default_value="$2"
    jq -r --arg default_value "${default_value}" "${key} // \$default_value" <<<"${LINUX_AGENT_CONFIG_JSON}"
}

linux_agent_config_bool_default() {
    local key="$1"
    local default_value="${2:-false}"
    local value

    value="$(linux_agent_config_get_default "${key}" "${default_value}")"
    case "${value,,}" in
        true|1|yes|on)
            printf 'true\n'
            ;;
        *)
            printf 'false\n'
            ;;
    esac
}

linux_agent_config_positive_int_default() {
    local key="$1"
    local default_value="$2"
    local value

    value="$(linux_agent_config_get_default "${key}" "${default_value}")"
    if [[ ! "${value}" =~ ^[0-9]+$ || "${value}" -le 0 ]]; then
        value="${default_value}"
    fi
    if [[ ! "${value}" =~ ^[0-9]+$ || "${value}" -le 0 ]]; then
        value=1
    fi
    printf '%s\n' "${value}"
}

linux_agent_remote_mode() {
    [[ "${LINUX_AGENT_REMOTE_MODE:-0}" == "1" ]]
}

linux_agent_remote_api_key_transmission_allowed() {
    if ! linux_agent_remote_mode; then
        return 0
    fi
    [[ "$(linux_agent_config_bool_default '.remote.allow_api_key_transmission' 'false')" == "true" ]]
}

linux_agent_remote_state_json() {
    local enabled=false
    linux_agent_remote_mode && enabled=true
    jq -cn \
        --argjson enabled "${enabled}" \
        --arg release_version "$(linux_agent_config_get_default '.remote.release_version' '')" \
        --arg storage_backend "$(linux_agent_config_get_default '.remote.storage_backend' 'local')" \
        --argjson allow_api_key_transmission "$(linux_agent_config_bool_default '.remote.allow_api_key_transmission' 'false')" \
        '{
            enabled:$enabled,
            release_version:$release_version,
            storage_backend:$storage_backend,
            allow_api_key_transmission:$allow_api_key_transmission
        }'
}

linux_agent_config_api_key_placeholder() {
    local value="$1"
    [[ -z "${value}" || "${value}" == "please-set-your-api-key" ]]
}

linux_agent_config_api_key() {
    local env_value config_value

    LINUX_AGENT_API_KEY_SOURCE="missing"

    env_value="${LINUX_AGENT_API_KEY:-}"
    if ! linux_agent_config_api_key_placeholder "${env_value}"; then
        LINUX_AGENT_API_KEY_SOURCE="env"
        printf '%s\n' "${env_value}"
        return 0
    fi

    config_value="$(linux_agent_config_get '.api_key')"
    if ! linux_agent_config_api_key_placeholder "${config_value}"; then
        LINUX_AGENT_API_KEY_SOURCE="config"
        printf '%s\n' "${config_value}"
        return 0
    fi

    return 0
}

linux_agent_api_key_state_json() {
    local env_value config_value config_configured configured source
    env_value="${LINUX_AGENT_API_KEY:-}"
    source="missing"
    configured=false
    config_configured=false

    if ! linux_agent_config_api_key_placeholder "${env_value}"; then
        source="env"
        configured=true
    fi

    config_value="$(linux_agent_config_get '.api_key')"
    if ! linux_agent_config_api_key_placeholder "${config_value}"; then
        config_configured=true
        if [[ "${configured}" != "true" ]]; then
            source="config"
            configured=true
        fi
    fi

    jq -cn \
        --argjson configured "${configured}" \
        --arg source "${source}" \
        --argjson config_configured "${config_configured}" \
        '{
            configured:$configured,
            source:$source,
            config_configured:$config_configured
        }'
}
