#!/usr/bin/env bash

set -euo pipefail

LINUX_AGENT_CONFIG_JSON=""

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
