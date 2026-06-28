#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${ROOT_DIR}/config/config.json"
EXAMPLE_FILE="${ROOT_DIR}/config/config.example.json"
LIVE_CHECK="false"

usage() {
    cat <<'EOF'
用法:
  bash test_config.sh          只做本地配置校验
  bash test_config.sh --live   本地校验通过后，发送一次最小 API 请求

说明:
  - 默认不会访问网络，也不会打印 API key。
  - API key 读取顺序为 LINUX_AGENT_API_KEY、api_key_file、旧版 config.api_key。
  - --live 会调用 config.json 中的 api_url/model 和解析后的 API key。
EOF
}

print_ok() {
    printf '[OK] %s\n' "$*"
}

print_warn() {
    printf '[WARN] %s\n' "$*" >&2
}

print_error() {
    printf '[ERROR] %s\n' "$*" >&2
}

require_command() {
    local name="$1"
    if ! command -v "${name}" >/dev/null 2>&1; then
        print_error "缺少依赖命令: ${name}"
        return 1
    fi
}

json_get() {
    local query="$1"
    jq -r "${query} | if . == null then empty else . end" "${CONFIG_FILE}"
}

config_path_value() {
    local configured="$1"
    if [[ -z "${configured}" ]]; then
        return 1
    fi
    if [[ "${configured}" == /* ]]; then
        printf '%s\n' "${configured}"
    else
        printf '%s/%s\n' "${ROOT_DIR}" "${configured}"
    fi
}

api_key_placeholder() {
    local value="$1"
    [[ -z "${value}" || "${value}" == "please-set-your-api-key" ]]
}

api_key_value() {
    local env_value file_config file_path file_value legacy_value
    env_value="${LINUX_AGENT_API_KEY:-}"
    if ! api_key_placeholder "${env_value}"; then
        printf '%s\n' "${env_value}"
        return 0
    fi

    file_config="$(json_get '.api_key_file')"
    if [[ -n "${file_config}" ]]; then
        file_path="$(config_path_value "${file_config}")"
        if [[ -r "${file_path}" ]]; then
            IFS= read -r file_value < "${file_path}" || file_value=""
            if ! api_key_placeholder "${file_value}"; then
                printf '%s\n' "${file_value}"
                return 0
            fi
        fi
    fi

    legacy_value="$(json_get '.api_key')"
    if ! api_key_placeholder "${legacy_value}"; then
        printf '%s\n' "${legacy_value}"
        return 0
    fi
    return 0
}

api_key_source() {
    local env_value file_config file_path file_value legacy_value
    env_value="${LINUX_AGENT_API_KEY:-}"
    if ! api_key_placeholder "${env_value}"; then
        printf 'env\n'
        return 0
    fi
    file_config="$(json_get '.api_key_file')"
    if [[ -n "${file_config}" ]]; then
        file_path="$(config_path_value "${file_config}")"
        if [[ -r "${file_path}" ]]; then
            IFS= read -r file_value < "${file_path}" || file_value=""
            if ! api_key_placeholder "${file_value}"; then
                printf 'file\n'
                return 0
            fi
        fi
    fi
    legacy_value="$(json_get '.api_key')"
    if ! api_key_placeholder "${legacy_value}"; then
        printf 'config_legacy\n'
        return 0
    fi
    printf 'missing\n'
}

validate_non_empty() {
    local field="$1"
    local value="$2"
    if [[ -z "${value}" ]]; then
        print_error "config.json 缺少字段或字段为空: ${field}"
        return 1
    fi
    print_ok "${field} 已配置"
}

validate_config() {
    local failures=0

    require_command jq || failures=$((failures + 1))
    require_command python3 || failures=$((failures + 1))

    if [[ ! -f "${CONFIG_FILE}" ]]; then
        print_error "未找到 ${CONFIG_FILE}"
        if [[ -f "${EXAMPLE_FILE}" ]]; then
            print_warn "可先运行: cp config/config.example.json config/config.json"
        fi
        return 1
    fi
    print_ok "找到 config/config.json"

    if ! jq -e . "${CONFIG_FILE}" >/dev/null 2>&1; then
        print_error "config/config.json 不是合法 JSON"
        return 1
    fi
    print_ok "config/config.json JSON 格式合法"

    local api_url api_key api_key_src model timeout context_turns audit_mode audit_text_limit remote_policy skills_dir
    local web_enabled web_host web_port web_token web_retention
    local loop_enabled auto_low auto_shell observation_limit thinking_trace checkpoint_turns
    api_url="$(json_get '.api_url')"
    api_key="$(api_key_value)"
    api_key_src="$(api_key_source)"
    model="$(json_get '.model')"
    timeout="$(json_get '.request_timeout_sec')"
    context_turns="$(json_get '.context_turns')"
    audit_mode="$(json_get '.audit_mode')"
    audit_text_limit="$(json_get '.audit_text_limit')"
    remote_policy="$(json_get '.remote_script_policy')"
    skills_dir="$(json_get '.skills_dir')"
    web_enabled="$(json_get '.web.enabled')"
    web_host="$(json_get '.web.host')"
    web_port="$(json_get '.web.port')"
    web_token="$(json_get '.web.token')"
    web_retention="$(json_get '.web.job_retention_hours')"
    loop_enabled="$(json_get '.agent_loop.enabled_for_work')"
    auto_low="$(json_get '.agent_loop.auto_execute_low_risk')"
    auto_shell="$(json_get '.agent_loop.auto_execute_shell_low_risk')"
    observation_limit="$(json_get '.agent_loop.observation_text_limit')"
    thinking_trace="$(json_get '.agent_loop.thinking_trace_enabled')"
    checkpoint_turns="$(json_get '.agent_loop.checkpoint_turns')"

    validate_non_empty "api_url" "${api_url}" || failures=$((failures + 1))
    validate_non_empty "api_key" "${api_key}" || failures=$((failures + 1))
    validate_non_empty "model" "${model}" || failures=$((failures + 1))

    if [[ "${api_key_src}" == "missing" ]]; then
        print_error "API key 未配置；请设置 LINUX_AGENT_API_KEY 或 config.api_key_file"
        failures=$((failures + 1))
    elif [[ ${#api_key} -lt 8 ]]; then
        print_warn "api_key 长度较短，请确认是否正确"
    else
        print_ok "api_key 已通过 ${api_key_src} 配置（未打印密钥）"
        if [[ "${api_key_src}" == "config_legacy" ]]; then
            print_warn "检测到旧版 config.api_key，建议迁移到 LINUX_AGENT_API_KEY 或 api_key_file"
        fi
    fi

    if [[ ! "${api_url}" =~ ^https?:// ]]; then
        print_error "api_url 必须以 http:// 或 https:// 开头"
        failures=$((failures + 1))
    elif [[ ! "${api_url}" =~ /chat/completions/?$ ]]; then
        print_warn "api_url 看起来不是 Chat Completions 端点，请确认是否兼容"
    else
        print_ok "api_url 看起来是 Chat Completions 端点"
    fi

    if [[ -n "${timeout}" ]]; then
        if [[ "${timeout}" =~ ^[0-9]+$ && "${timeout}" -gt 0 ]]; then
            print_ok "request_timeout_sec 合法: ${timeout}"
        else
            print_error "request_timeout_sec 必须是正整数"
            failures=$((failures + 1))
        fi
    else
        print_warn "request_timeout_sec 未配置，将由程序默认值兜底"
    fi

    if [[ -n "${context_turns}" ]]; then
        if [[ "${context_turns}" =~ ^[0-9]+$ ]]; then
            print_ok "context_turns 合法: ${context_turns}"
        else
            print_error "context_turns 必须是非负整数"
            failures=$((failures + 1))
        fi
    else
        print_warn "context_turns 未配置，将由程序默认值兜底"
    fi

    if [[ -n "${audit_mode}" ]]; then
        if [[ "${audit_mode}" == "safe_summary" || "${audit_mode}" == "redacted_verbose" ]]; then
            print_ok "audit_mode 合法: ${audit_mode}"
        else
            print_error "audit_mode 仅支持 safe_summary 或 redacted_verbose"
            failures=$((failures + 1))
        fi
    else
        print_warn "audit_mode 未配置，将默认使用 safe_summary"
    fi

    if [[ -n "${audit_text_limit}" ]]; then
        if [[ "${audit_text_limit}" =~ ^[0-9]+$ && "${audit_text_limit}" -gt 0 ]]; then
            print_ok "audit_text_limit 合法: ${audit_text_limit}"
        else
            print_error "audit_text_limit 必须是正整数"
            failures=$((failures + 1))
        fi
    else
        print_warn "audit_text_limit 未配置，将默认使用 1000"
    fi

    if [[ -n "${remote_policy}" && "${remote_policy}" != "download_review" && "${remote_policy}" != "disabled" ]]; then
        print_error "remote_script_policy 仅支持 download_review 或 disabled"
        failures=$((failures + 1))
    elif [[ -n "${remote_policy}" ]]; then
        print_ok "remote_script_policy 合法: ${remote_policy}"
    else
        print_warn "remote_script_policy 未配置，将默认使用 download_review"
    fi

    for bool_field in \
        "agent_loop.enabled_for_work:${loop_enabled}" \
        "agent_loop.auto_execute_low_risk:${auto_low}" \
        "agent_loop.auto_execute_shell_low_risk:${auto_shell}" \
        "agent_loop.thinking_trace_enabled:${thinking_trace}"; do
        local field_name field_value
        field_name="${bool_field%%:*}"
        field_value="${bool_field#*:}"
        if [[ -z "${field_value}" ]]; then
            print_warn "${field_name} 未配置，将由程序默认值兜底"
        elif [[ "${field_value}" == "true" || "${field_value}" == "false" ]]; then
            print_ok "${field_name} 合法: ${field_value}"
        else
            print_error "${field_name} 必须是 true 或 false"
            failures=$((failures + 1))
        fi
    done

    if [[ -n "${observation_limit}" ]]; then
        if [[ "${observation_limit}" =~ ^[0-9]+$ && "${observation_limit}" -gt 0 ]]; then
            print_ok "agent_loop.observation_text_limit 合法: ${observation_limit}"
        else
            print_error "agent_loop.observation_text_limit 必须是正整数"
            failures=$((failures + 1))
        fi
    else
        print_warn "agent_loop.observation_text_limit 未配置，将默认使用 4000"
    fi

    if [[ -n "${checkpoint_turns}" ]]; then
        if [[ "${checkpoint_turns}" =~ ^[0-9]+$ ]]; then
            print_ok "agent_loop.checkpoint_turns 合法: ${checkpoint_turns}"
        else
            print_error "agent_loop.checkpoint_turns 必须是非负整数"
            failures=$((failures + 1))
        fi
    else
        print_warn "agent_loop.checkpoint_turns 未配置，将默认使用 context_turns"
    fi

    if [[ -n "${skills_dir}" ]]; then
        if [[ -d "${skills_dir}" ]]; then
            print_ok "skills_dir 存在: ${skills_dir}"
        else
            print_error "skills_dir 不存在: ${skills_dir}"
            failures=$((failures + 1))
        fi
    elif [[ -d "${ROOT_DIR}/skills" ]]; then
        print_ok "skills_dir 留空，将使用项目内 skills/"
    else
        print_error "skills_dir 留空，但项目内 skills/ 不存在"
        failures=$((failures + 1))
    fi

    if jq -e 'has("web")' "${CONFIG_FILE}" >/dev/null 2>&1; then
        if [[ -z "${web_enabled}" || "${web_enabled}" == "true" || "${web_enabled}" == "false" ]]; then
            print_ok "web.enabled 合法: ${web_enabled:-默认 true}"
        else
            print_error "web.enabled 必须是 true 或 false"
            failures=$((failures + 1))
        fi

        if [[ -z "${web_host}" ]]; then
            print_warn "web.host 未配置，将默认监听 127.0.0.1"
        elif [[ "${web_host}" =~ ^[A-Za-z0-9_.:-]+$ ]]; then
            print_ok "web.host 合法: ${web_host}"
        else
            print_error "web.host 含有不支持的字符"
            failures=$((failures + 1))
        fi

        if [[ -z "${web_port}" ]]; then
            print_warn "web.port 未配置，将默认使用 8765"
        elif [[ "${web_port}" =~ ^[0-9]+$ && "${web_port}" -gt 0 && "${web_port}" -le 65535 ]]; then
            print_ok "web.port 合法: ${web_port}"
        else
            print_error "web.port 必须是 1-65535 的整数"
            failures=$((failures + 1))
        fi

        if [[ -z "${web_token}" ]]; then
            print_warn "web.token 未配置，bin/agent-web 会生成本次运行的临时 token"
        elif [[ ${#web_token} -lt 12 ]]; then
            print_warn "web.token 较短，仅建议本机临时使用"
        else
            print_ok "web.token 已配置（未打印 token）"
        fi

        if [[ -z "${web_retention}" ]]; then
            print_warn "web.job_retention_hours 未配置，将默认使用 24"
        elif [[ "${web_retention}" =~ ^[0-9]+$ && "${web_retention}" -gt 0 ]]; then
            print_ok "web.job_retention_hours 合法: ${web_retention}"
        else
            print_error "web.job_retention_hours 必须是正整数"
            failures=$((failures + 1))
        fi
    else
        print_warn "web 配置段未配置；CLI 不受影响，bin/agent-web 会使用本机默认值和临时 token"
    fi

    return "${failures}"
}

live_check() {
    require_command curl

    local api_url api_key model timeout payload response_file body_file http_code
    api_url="$(json_get '.api_url')"
    api_key="$(api_key_value)"
    model="$(json_get '.model')"
    timeout="$(json_get '.request_timeout_sec')"
    [[ -z "${timeout}" ]] && timeout=90

    response_file="$(mktemp)"
    body_file="$(mktemp)"
    trap 'rm -f "${response_file}" "${body_file}"' RETURN

    payload="$(jq -cn \
        --arg model "${model}" \
        '{
            model:$model,
            temperature:0,
            max_tokens:1,
            messages:[{role:"user", content:"ping"}]
        }')"

    print_ok "开始 live API 检查（不会打印 api_key）"
    http_code="$(curl -sS --max-time "${timeout}" \
        -o "${body_file}" \
        -w '%{http_code}' \
        -H "Authorization: Bearer ${api_key}" \
        -H "Content-Type: application/json" \
        -d "${payload}" \
        "${api_url}" 2>"${response_file}" || true)"

    if [[ -s "${response_file}" ]]; then
        print_warn "curl 输出: $(cat "${response_file}")"
    fi

    if [[ "${http_code}" =~ ^2[0-9][0-9]$ ]] && jq -e '.choices[0].message.content? // .choices[0].text? // empty' "${body_file}" >/dev/null 2>&1; then
        print_ok "live API 检查成功，HTTP ${http_code}"
        return 0
    fi

    print_error "live API 检查失败，HTTP ${http_code}"
    if jq -e . "${body_file}" >/dev/null 2>&1; then
        jq '{error:(.error // .)}' "${body_file}" >&2
    else
        sed -n '1,20p' "${body_file}" >&2
    fi
    return 1
}

for arg in "$@"; do
    case "${arg}" in
        --live)
            LIVE_CHECK="true"
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            print_error "未知参数: ${arg}"
            usage
            exit 2
            ;;
    esac
done

if ! validate_config; then
    print_error "config.json 本地校验失败"
    exit 1
fi

print_ok "config.json 本地校验通过"

if [[ "${LIVE_CHECK}" == "true" ]]; then
    live_check
else
    print_warn "未执行 live API 检查；如需测试 API 连通性，请运行: bash test_config.sh --live"
fi
