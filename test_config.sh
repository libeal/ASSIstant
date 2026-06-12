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
  - 默认不会访问网络，也不会打印 api_key。
  - --live 会调用 config.json 中的 api_url/model/api_key。
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
    jq -r "${query} // empty" "${CONFIG_FILE}"
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

    local api_url api_key model timeout context_turns audit_mode audit_text_limit remote_policy skills_dir
    api_url="$(json_get '.api_url')"
    api_key="$(json_get '.api_key')"
    model="$(json_get '.model')"
    timeout="$(json_get '.request_timeout_sec')"
    context_turns="$(json_get '.context_turns')"
    audit_mode="$(json_get '.audit_mode')"
    audit_text_limit="$(json_get '.audit_text_limit')"
    remote_policy="$(json_get '.remote_script_policy')"
    skills_dir="$(json_get '.skills_dir')"

    validate_non_empty "api_url" "${api_url}" || failures=$((failures + 1))
    validate_non_empty "api_key" "${api_key}" || failures=$((failures + 1))
    validate_non_empty "model" "${model}" || failures=$((failures + 1))

    if [[ "${api_key}" == "please-set-your-api-key" ]]; then
        print_error "api_key 仍是示例占位值"
        failures=$((failures + 1))
    elif [[ ${#api_key} -lt 8 ]]; then
        print_warn "api_key 长度较短，请确认是否正确"
    else
        print_ok "api_key 看起来已替换为真实值（未打印密钥）"
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

    return "${failures}"
}

live_check() {
    require_command curl

    local api_url api_key model timeout payload response_file body_file http_code
    api_url="$(json_get '.api_url')"
    api_key="$(json_get '.api_key')"
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
