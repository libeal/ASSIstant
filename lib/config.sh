#!/usr/bin/env bash

set -euo pipefail

LINUX_AGENT_CONFIG_JSON=""
LINUX_AGENT_API_KEY_SOURCE=""
LINUX_AGENT_API_KEY_MIGRATION_RECOMMENDED="false"

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

linux_agent_config_path_value() {
    local configured="$1"
    if [[ -z "${configured}" ]]; then
        return 1
    fi
    if [[ "${configured}" == /* ]]; then
        printf '%s\n' "${configured}"
    else
        printf '%s/%s\n' "${LINUX_AGENT_ROOT}" "${configured}"
    fi
}

linux_agent_config_api_key_placeholder() {
    local value="$1"
    [[ -z "${value}" || "${value}" == "please-set-your-api-key" ]]
}

linux_agent_config_api_key() {
    local env_value file_config file_path file_value legacy_value

    LINUX_AGENT_API_KEY_SOURCE="missing"
    LINUX_AGENT_API_KEY_MIGRATION_RECOMMENDED="false"

    env_value="${LINUX_AGENT_API_KEY:-}"
    if ! linux_agent_config_api_key_placeholder "${env_value}"; then
        LINUX_AGENT_API_KEY_SOURCE="env"
        printf '%s\n' "${env_value}"
        return 0
    fi

    file_config="$(linux_agent_config_get '.api_key_file')"
    if [[ -n "${file_config}" ]]; then
        file_path="$(linux_agent_config_path_value "${file_config}")"
        if [[ -r "${file_path}" ]]; then
            IFS= read -r file_value < "${file_path}" || file_value=""
            if ! linux_agent_config_api_key_placeholder "${file_value}"; then
                LINUX_AGENT_API_KEY_SOURCE="file"
                printf '%s\n' "${file_value}"
                return 0
            fi
        fi
    fi

    legacy_value="$(linux_agent_config_get '.api_key')"
    if ! linux_agent_config_api_key_placeholder "${legacy_value}"; then
        LINUX_AGENT_API_KEY_SOURCE="config_legacy"
        LINUX_AGENT_API_KEY_MIGRATION_RECOMMENDED="true"
        printf '%s\n' "${legacy_value}"
        return 0
    fi

    return 0
}

linux_agent_api_key_state_json() {
    local env_value file_config file_path file_value file_configured legacy_value configured source migration_recommended
    env_value="${LINUX_AGENT_API_KEY:-}"
    source="missing"
    configured=false
    migration_recommended=false

    if ! linux_agent_config_api_key_placeholder "${env_value}"; then
        source="env"
        configured=true
    fi

    file_config="$(linux_agent_config_get '.api_key_file')"
    file_configured=false
    if [[ -n "${file_config}" ]]; then
        file_path="$(linux_agent_config_path_value "${file_config}")"
        if [[ -r "${file_path}" ]]; then
            IFS= read -r file_value < "${file_path}" || file_value=""
            if ! linux_agent_config_api_key_placeholder "${file_value}"; then
                file_configured=true
                if [[ "${configured}" != "true" ]]; then
                    source="file"
                    configured=true
                fi
            fi
        fi
    fi

    legacy_value="$(linux_agent_config_get '.api_key')"
    if ! linux_agent_config_api_key_placeholder "${legacy_value}"; then
        migration_recommended=true
    fi
    if [[ "${configured}" != "true" ]] && ! linux_agent_config_api_key_placeholder "${legacy_value}"; then
        source="config_legacy"
        configured=true
    fi

    jq -cn \
        --argjson configured "${configured}" \
        --arg source "${source}" \
        --argjson migration_recommended "${migration_recommended}" \
        --argjson file_configured "${file_configured}" \
        --argjson legacy_configured "$(if ! linux_agent_config_api_key_placeholder "${legacy_value}"; then printf 'true'; else printf 'false'; fi)" \
        '{
            configured:$configured,
            source:$source,
            migration_recommended:$migration_recommended,
            file_configured:$file_configured,
            legacy_configured:$legacy_configured
        }'
}
