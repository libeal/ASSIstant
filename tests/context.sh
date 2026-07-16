#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/common.sh
source "${ROOT_DIR}/lib/common.sh"
# shellcheck source=../lib/config.sh
source "${ROOT_DIR}/lib/config.sh"
# shellcheck source=../lib/context.sh
source "${ROOT_DIR}/lib/context.sh"
# shellcheck source=../lib/orchestrator.sh
source "${ROOT_DIR}/lib/orchestrator.sh"

tmp_root="$(mktemp -d)"
cleanup() {
    rm -rf "${tmp_root}"
}
trap cleanup EXIT

LINUX_AGENT_CONFIG_JSON='{"context_turns":2,"agent_loop":{"checkpoint_turns":10,"thinking_trace_enabled":false,"observation_text_limit":1000}}'

history_file="${tmp_root}/conversation-history.json"
LINUX_AGENT_CONVERSATION_HISTORY_FILE="${history_file}"
linux_agent_record_conversation_turn "work" "第一轮请求" "第一轮完成" "executed" "request"
linux_agent_record_conversation_turn "work" "第二轮请求" "第二轮完成" "executed" "request"
linux_agent_record_conversation_turn "work" "第三轮请求" "第三轮完成" "executed" "request"
[[ "$(stat -c '%a' "${history_file}")" == "600" ]]
linux_agent_history_window | jq -e 'length == 2
    and .[0].request.content == "第二轮请求"
    and .[1].request.content == "第三轮请求"
    and all(.[]; .type == "request" and (.request | type) == "object" and (.response | type) == "object")' >/dev/null

legacy_history_file="${tmp_root}/legacy-history.json"
jq -cn '[
    {role:"user", content:"旧用户请求", status:"work", timestamp:"t1"},
    {role:"assistant", content:"旧助手响应", status:"executed", timestamp:"t2"}
]' >"${legacy_history_file}"
LINUX_AGENT_CONVERSATION_HISTORY_FILE="${legacy_history_file}"
LINUX_AGENT_CONFIG_JSON='{"context_turns":1,"agent_loop":{"checkpoint_turns":10,"thinking_trace_enabled":false,"observation_text_limit":1000}}'
linux_agent_history_window | jq -e 'length == 1
    and .[0].type == "request"
    and .[0].request.content == "旧用户请求"
    and .[0].response.content == "旧助手响应"
    and .[0].status == "executed"' >/dev/null

loop_history_file="${tmp_root}/loop-history.json"
# Consumed by functions sourced from lib/context.sh.
# shellcheck disable=SC2034
LINUX_AGENT_CONVERSATION_HISTORY_FILE="${loop_history_file}"
# Consumed by functions sourced from lib/config.sh and lib/orchestrator.sh.
# shellcheck disable=SC2034
LINUX_AGENT_CONFIG_JSON='{"context_turns":6,"agent_loop":{"checkpoint_turns":10,"thinking_trace_enabled":false,"observation_text_limit":1000}}'

linux_agent_auto_approval_config_json() {
    printf '{"skill_readonly":true,"shell_readonly":false,"file_patch":false}\n'
}

linux_agent_log_event() { :; }
linux_agent_record_ai_request_files() { :; }
linux_agent_store_thinking_summary() { :; }
linux_agent_output_json_enabled() { return 0; }

linux_agent_execute_work_plan() {
    jq -cn '{status:"executed", results:[{step:{id:"step-1", title:"stub"}, result:{ok:true, status:"executed", output:{summary:"ok"}}}], review:null, approval_step:null}'
}

linux_agent_build_agent_observation() {
    local input="$1"
    local iteration="$2"
    local _plan="$3"
    local execution="$4"
    jq -cn --arg original_request "${input}" --argjson iteration "${iteration}" --argjson execution "${execution}" \
        '{agent_observation:{original_request:$original_request, iteration:$iteration, execution:{status:($execution.status // "executed"), result_count:(($execution.results // []) | length)}}}'
}

linux_agent_request_agent_reflection() {
    local _input="$1"
    local iteration="$2"
    local _observation="$3"
    if [[ "${iteration}" == "1" ]]; then
        jq -cn '{response_type:"work_plan", summary:"second", continue_decision:{should_continue:false, reason:"done"}, steps:[{id:"step-2", title:"second", executor_type:"skill_script", skill_script:"ops-basic/resource-inspect", arguments:{}, reason:"r", expected_effect:"e", risk_level:"low"}]}'
    else
        jq -cn '{response_type:"answer", summary:"done", continue_decision:{should_continue:false, reason:"done"}, answer:"done"}'
    fi
}

initial_plan='{"response_type":"work_plan","summary":"first","continue_decision":{"should_continue":true,"reason":"continue"},"steps":[{"id":"step-1","title":"first","executor_type":"skill_script","skill_script":"ops-basic/resource-inspect","arguments":{},"reason":"r","expected_effect":"e","risk_level":"low"}]}'
linux_agent_run_agent_loop "测试循环" "work" '{}' "${initial_plan}" >/dev/null
jq -e 'length == 2
    and all(.[]; .type == "agent_loop_iteration")
    and .[0].iteration == 1
    and .[1].iteration == 2
    and .[0].metadata.plan_summary == "first"
    and .[1].metadata.plan_summary == "second"
    and all(.[]; (.request.content == "测试循环") and (.response | type) == "object")' "${loop_history_file}" >/dev/null

printf 'context: ok\n'
