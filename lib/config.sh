#!/usr/bin/env bash

set -euo pipefail

LINUX_AGENT_CONFIG_JSON=""
LINUX_AGENT_API_KEY_SOURCE=""
LINUX_AGENT_JSON_SAFE_INTEGER_MAX=9007199254740991

linux_agent_load_config() {
    local config_json

    linux_agent_require_command jq

    if [[ ! -f "${LINUX_AGENT_CONFIG_FILE}" ]]; then
        cp "${LINUX_AGENT_ROOT}/config/config.example.json" "${LINUX_AGENT_CONFIG_FILE}"
        linux_agent_print_warn "未找到 config/config.json，已根据示例生成，请补充真实配置。"
    fi
    if ! chmod 600 "${LINUX_AGENT_CONFIG_FILE}" 2>/dev/null; then
        linux_agent_print_error "无法将 config/config.json 权限收紧为 0600。"
        return 1
    fi

    config_json="$(cat "${LINUX_AGENT_CONFIG_FILE}")"
    if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"${config_json}"; then
        linux_agent_print_error "config/config.json 必须是合法的 JSON 对象。"
        return 1
    fi
    if ! linux_agent_config_validate_observer_require "${config_json}"; then
        linux_agent_print_error "observer.require 必须是 JSON boolean（true 或 false）。"
        return 1
    fi
    if ! linux_agent_config_validate_web_metrics "${config_json}"; then
        linux_agent_print_error "web.metrics_enabled 必须是 JSON boolean（true 或 false）。"
        return 1
    fi
    if ! linux_agent_config_validate_audit "${config_json}"; then
        linux_agent_print_error "audit 配置非法：fsync 必须是 boolean，max_bytes/min_free_bytes 必须是 0-${LINUX_AGENT_JSON_SAFE_INTEGER_MAX} 的整数，on_full 仅支持 degrade 或 block。"
        return 1
    fi
    if linux_agent_config_has_removed_integrity_chain "${config_json}"; then
        linux_agent_print_error "audit.integrity_chain 已移除；审计 hash chain 现在是强制不变量。"
        return 1
    fi

    LINUX_AGENT_CONFIG_JSON="${config_json}"
}

linux_agent_config_validate_web_metrics() {
    local config_json="${1:-${LINUX_AGENT_CONFIG_JSON:-}}"

    jq -e '
        type == "object"
        and (
            if (.web? == null) then true
            elif (.web | type) != "object" then false
            elif (.web | has("metrics_enabled") | not) then true
            else (.web.metrics_enabled | type) == "boolean"
            end
        )
    ' >/dev/null 2>&1 <<<"${config_json}"
}

linux_agent_config_has_removed_integrity_chain() {
    local config_json="${1:-${LINUX_AGENT_CONFIG_JSON:-}}"

    jq -e '
        (.audit? | type) == "object"
        and (.audit | has("integrity_chain"))
    ' >/dev/null 2>&1 <<<"${config_json}"
}

# observer.require is a compliance boundary, so unlike permissive feature flags
# it must never accept strings/numbers or silently coerce an invalid value.
# Missing observer/require remains valid and preserves the default false mode.
linux_agent_config_validate_observer_require() {
    local config_json="${1:-${LINUX_AGENT_CONFIG_JSON:-}}"

    jq -e '
        type == "object"
        and (
            if (.observer? == null) then true
            elif (.observer | type) != "object" then false
            elif (.observer | has("require") | not) then true
            else (.observer.require | type) == "boolean"
            end
        )
    ' >/dev/null 2>&1 <<<"${config_json}"
}

# Audit durability settings are a compliance boundary.  Explicit values must
# retain the same type and value in Bash and Python; strings, fractional
# numbers, negative numbers, and integers outside JSON's interoperable exact
# range are rejected instead of being coerced or silently defaulted.
linux_agent_config_validate_audit() {
    local config_json="${1:-${LINUX_AGENT_CONFIG_JSON:-}}"

    jq -e --argjson max "${LINUX_AGENT_JSON_SAFE_INTEGER_MAX}" '
        type == "object"
        and (
            if has("audit") | not then true
            elif (.audit | type) != "object" then false
            else
                ((.audit | has("fsync") | not) or ((.audit.fsync | type) == "boolean"))
                and (
                    (.audit | has("max_bytes") | not)
                    or (
                        (.audit.max_bytes | type) == "number"
                        and .audit.max_bytes == (.audit.max_bytes | floor)
                        and .audit.max_bytes >= 0
                        and .audit.max_bytes <= $max
                    )
                )
                and (
                    (.audit | has("min_free_bytes") | not)
                    or (
                        (.audit.min_free_bytes | type) == "number"
                        and .audit.min_free_bytes == (.audit.min_free_bytes | floor)
                        and .audit.min_free_bytes >= 0
                        and .audit.min_free_bytes <= $max
                    )
                )
                and (
                    (.audit | has("on_full") | not)
                    or (.audit.on_full == "degrade" or .audit.on_full == "block")
                )
            end
        )
    ' >/dev/null 2>&1 <<<"${config_json}"
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
        true | 1 | yes | on)
            printf 'true\n'
            ;;
        *)
            printf 'false\n'
            ;;
    esac
}

# False-safe boolean read. jq's `//` treats an explicit `false` like a missing
# value (`false // "true"` yields "true"), so bind the value and test it
# directly for booleans whose default is true (for example audit.fsync).
linux_agent_config_bool_strict() {
    local key="$1"
    local default_value="${2:-false}"
    local value

    value="$(jq -er --argjson d "${default_value}" "
        (${key}) as \$v
        | if \$v == null then \$d
          elif (\$v | type) == \"boolean\" then \$v
          else error(\"configuration value must be a boolean\")
          end
    " <<<"${LINUX_AGENT_CONFIG_JSON}")" || return 1
    printf '%s\n' "${value}"
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

# Like positive_int_default but permits 0 (e.g. audit.max_bytes / audit.min_free_bytes
# use 0 to disable rotation / disk-space protection). Non-integers fall back to the default.
linux_agent_config_nonneg_int_default() {
    local key="$1"
    local default_value="$2"
    local value

    value="$(jq -er --argjson d "${default_value}" --argjson max "${LINUX_AGENT_JSON_SAFE_INTEGER_MAX}" "
        (${key}) as \$v
        | if \$v == null then \$d
          elif (\$v | type) == \"number\"
               and \$v == (\$v | floor)
               and \$v >= 0
               and \$v <= \$max then \$v
          else error(\"configuration value must be a non-negative interoperable JSON integer\")
          end
    " <<<"${LINUX_AGENT_CONFIG_JSON}")" || return 1
    printf '%s\n' "${value}"
}

linux_agent_execution_timeout_sec() {
    local value
    value="$(linux_agent_config_positive_int_default '.execution.timeout_sec' '300')"
    if [[ "${value}" -gt 3600 ]]; then
        value=3600
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

# The source marker is part of the shared sourced-module environment and is
# explicitly scrubbed before launching child processes.
# shellcheck disable=SC2034
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
