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

    if ! config_json="$(cat "${LINUX_AGENT_CONFIG_FILE}")"; then
        linux_agent_print_error "无法读取 config/config.json；请检查当前用户与文件所有权。"
        return 1
    fi
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
    if ! linux_agent_config_validate_execution "${config_json}"; then
        linux_agent_print_error "execution 配置非法：timeout_sec 必须为 1-3600，max_output_bytes 必须为 4096-104857600，min_privilege_proxy 必须为 boolean。"
        return 1
    fi
    if ! linux_agent_config_validate_provider_resilience "${config_json}"; then
        linux_agent_print_error "provider_resilience 配置非法：检查重试、退避、熔断和 failover 条目。"
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

linux_agent_config_validate_execution() {
    local config_json="${1:-${LINUX_AGENT_CONFIG_JSON:-}}"

    jq -e '
        type == "object"
        and (
            if (.execution? == null) then true
            elif (.execution | type) != "object" then false
            else
                ((.execution | has("timeout_sec") | not) or (
                    (.execution.timeout_sec | type) == "number"
                    and .execution.timeout_sec == (.execution.timeout_sec | floor)
                    and .execution.timeout_sec >= 1
                    and .execution.timeout_sec <= 3600
                ))
                and ((.execution | has("max_output_bytes") | not) or (
                    (.execution.max_output_bytes | type) == "number"
                    and .execution.max_output_bytes == (.execution.max_output_bytes | floor)
                    and .execution.max_output_bytes >= 4096
                    and .execution.max_output_bytes <= 104857600
                ))
                and ((.execution | has("min_privilege_proxy") | not)
                    or ((.execution.min_privilege_proxy | type) == "boolean"))
                and ((.execution | has("least_privilege_user") | not)
                    or ((.execution.least_privilege_user | type) == "string"
                        and (.execution.least_privilege_user | test("^[A-Za-z_][A-Za-z0-9_.-]*[$]?$"))))
            end
        )
    ' >/dev/null 2>&1 <<<"${config_json}"
}

linux_agent_config_validate_provider_resilience() {
    local config_json="${1:-${LINUX_AGENT_CONFIG_JSON:-}}"

    jq -e '
        def bounded_integer($minimum; $maximum):
            type == "number" and . == floor and . >= $minimum and . <= $maximum;
        def optional_bounded_integer($object; $key; $minimum; $maximum):
            ($object | has($key) | not) or ($object[$key] | bounded_integer($minimum; $maximum));
        type == "object"
        and (
            if (.provider_resilience? == null) then true
            elif (.provider_resilience | type) != "object" then false
            else
                .provider_resilience as $r
                | (($r | keys) - ["enabled", "max_attempts", "backoff_initial_ms", "backoff_max_ms", "circuit_failure_threshold", "circuit_open_sec", "failover"] | length) == 0
                and (($r | has("enabled") | not) or (($r.enabled | type) == "boolean"))
                and optional_bounded_integer($r; "max_attempts"; 1; 5)
                and optional_bounded_integer($r; "backoff_initial_ms"; 0; 60000)
                and optional_bounded_integer($r; "backoff_max_ms"; 0; 60000)
                and optional_bounded_integer($r; "circuit_failure_threshold"; 1; 100)
                and optional_bounded_integer($r; "circuit_open_sec"; 1; 86400)
                and (($r | has("backoff_initial_ms") | not) or ($r | has("backoff_max_ms") | not) or ($r.backoff_max_ms >= $r.backoff_initial_ms))
                and (
                    ($r | has("failover") | not)
                    or (
                        ($r.failover | type) == "array"
                        and ($r.failover | length) <= 8
                        and all($r.failover[];
                            type == "object"
                            and ((keys - ["provider", "api_url", "model", "api_key_env", "reuse_primary_api_key"]) | length) == 0
                            and ((.provider | type) == "string" and (.provider | length) > 0)
                            and ((has("api_url") | not) or ((.api_url | type) == "string" and (.api_url | length) > 0))
                            and ((has("model") | not) or ((.model | type) == "string" and (.model | length) > 0))
                            and ((has("api_key_env") | not) or (
                                (.api_key_env | type) == "string"
                                and (.api_key_env | test("^[A-Z_][A-Z0-9_]*_API_KEY$"))
                                and .api_key_env != "LINUX_AGENT_API_KEY"
                            ))
                            and ((has("reuse_primary_api_key") | not) or ((.reuse_primary_api_key | type) == "boolean"))
                            and (((.api_key_env // "") != "") or ((.reuse_primary_api_key // false) == true))
                        )
                    )
                )
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

linux_agent_execution_max_output_bytes() {
    local value
    value="$(linux_agent_config_positive_int_default '.execution.max_output_bytes' '1048576')"
    if [[ "${value}" -lt 4096 ]]; then
        value=4096
    fi
    if [[ "${value}" -gt 104857600 ]]; then
        value=104857600
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
