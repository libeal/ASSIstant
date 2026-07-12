#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=helpers.sh
source "${ROOT_DIR}/tests/helpers.sh"

tmp_root="$(mktemp -d)"
cleanup() {
    stop_fake_ai_server
    rm -rf "${tmp_root}"
}
trap cleanup EXIT
start_fake_ai_server "$((21000 + RANDOM % 1000))" "${tmp_root}"

copy_project() {
    local target="$1"
    mkdir -p "${target}"
    cp -a \
        "${ROOT_DIR}/bin" \
        "${ROOT_DIR}/config" \
        "${ROOT_DIR}/lib" \
        "${ROOT_DIR}/policies" \
        "${ROOT_DIR}/prompts" \
        "${ROOT_DIR}/skills" \
        "${target}/"
    configure_fake_ai "${target}"
}

assert_single_run_session() {
    local name="$1"
    shift
    local project="${tmp_root}/${name}"
    local log_file
    copy_project "${project}"
    (cd "${project}" && "$@" >/dev/null 2>&1)
    [[ "$(find "${project}/logs" -name '*.jsonl' | wc -l | tr -d ' ')" -eq 1 ]]
    log_file="$(find "${project}/logs" -name '*.jsonl' -print -quit)"
    [[ "$(jq -r 'select(.stage=="session_started") | .stage' "${log_file}" | wc -l | tr -d ' ')" -eq 1 ]]
    [[ "$(jq -r 'select(.stage=="session_finished") | .stage' "${log_file}" | wc -l | tr -d ' ')" -eq 1 ]]
    [[ "$(jq -r 'select(.stage=="command_started") | .stage' "${log_file}" | wc -l | tr -d ' ')" -eq 1 ]]
    [[ "$(jq -r 'select(.stage=="command_finished") | .stage' "${log_file}" | wc -l | tr -d ' ')" -eq 1 ]]
}

assert_ai_file_manifest() {
    local project="${tmp_root}/session-ai-files"
    local log_file
    copy_project "${project}"
    (cd "${project}" && bash bin/agent work "查看cpu占用,内存环境" >/dev/null 2>&1)
    log_file="$(find "${project}/logs" -name '*.jsonl' -print -quit)"
    grep -q '"stage":"ai_files_manifest"' "${log_file}"
    grep -q '"relative_path":"skills/INDEX.md"' "${log_file}"
    grep -q '"relative_path":"skills/ops-basic/SKILL.md"' "${log_file}"
    ! grep -q '"relative_path":"skills/network-ops-tools/SKILL.md"' "${log_file}"
    grep -q '"disclosed_skill_count":1' "${log_file}"
    grep -q '"disclosed_skills":\["ops-basic"\]' "${log_file}"
    [[ "$(grep -o '查看cpu占用,内存环境' "${log_file}" | wc -l | tr -d ' ')" -eq 1 ]]
    grep -q '"sha256":"' "${log_file}"
    ai_files_line="$(jq -r '.stage' "${log_file}" | awk '$0=="ai_files_manifest" {print NR; exit}')"
    session_finished_line="$(jq -r '.stage' "${log_file}" | awk '$0=="session_finished" {print NR; exit}')"
    [[ -n "${ai_files_line}" && -n "${session_finished_line}" && "${ai_files_line}" -lt "${session_finished_line}" ]]
}

assert_thinking_trace() {
    local project="${tmp_root}/thinking-trace"
    local log_file session_id thinking_file thinking_root
    thinking_root="${tmp_root}/thinking-traces"
    copy_project "${project}"
    (
        cd "${project}"
        tmp_config="$(mktemp)"
        jq '.agent_loop.thinking_trace_enabled=true' config/config.json > "${tmp_config}"
        mv "${tmp_config}" config/config.json
        LINUX_AGENT_THINKING_TRACE_DIR="${thinking_root}" \
            bash bin/agent work "查看cpu继续深入" >/dev/null 2>&1
    )
    log_file="$(find "${project}/logs" -name '*.jsonl' -print -quit)"
    session_id="$(basename "${log_file}" .jsonl)"
    thinking_file="${thinking_root}/${session_id}/thinking/iteration-1.txt"
    [[ -f "${thinking_file}" ]]
    grep -q '第一轮结果不足以完成测试场景' "${thinking_file}"
    ! grep -R -q '第一轮结果不足以完成测试场景' "${project}/logs"
}

assert_simple_plan_skips_reflection() {
    local project="${tmp_root}/simple-no-reflect"
    local log_file
    copy_project "${project}"
    (cd "${project}" && bash bin/agent work "查看cpu占用,内存环境" >/dev/null 2>&1)
    log_file="$(find "${project}/logs" -name '*.jsonl' -print -quit)"
    ! grep -q '"stage":"agent_reflection_requested"' "${log_file}"
    ! grep -q '"stage":"agent_reflection_planned"' "${log_file}"
    grep -q '"stage":"agent_loop_finished"' "${log_file}"
}

assert_no_default_thinking_trace() {
    local project="${tmp_root}/thinking-default-off"
    local log_file session_id thinking_root
    thinking_root="${tmp_root}/thinking-traces"
    copy_project "${project}"
    (cd "${project}" && \
        LINUX_AGENT_THINKING_TRACE_DIR="${thinking_root}" \
            bash bin/agent work "查看cpu占用,内存环境" >/dev/null 2>&1)
    log_file="$(find "${project}/logs" -name '*.jsonl' -print -quit)"
    session_id="$(basename "${log_file}" .jsonl)"
    [[ ! -e "${thinking_root}/${session_id}/thinking" ]]
}

assert_checkpoint_stop() {
    local project="${tmp_root}/checkpoint-stop"
    local output
    copy_project "${project}"
    output="$(
        cd "${project}"
        tmp_config="$(mktemp)"
        jq '.agent_loop.checkpoint_turns=1' config/config.json > "${tmp_config}"
        mv "${tmp_config}" config/config.json
        bash bin/agent work "查看cpu继续深入" <<< $'n\n' 2>&1
    )"
    grep -q '允许继续深入' <<<"${output}"
    grep -q '工作流执行完成: status=checkpoint_stopped' <<<"${output}"
}

assert_iteration_limit_stop() {
    local project="${tmp_root}/iteration-limit-stop"
    local output
    copy_project "${project}"
    output="$(
        cd "${project}"
        tmp_config="$(mktemp)"
        jq '.agent_loop.max_iterations=1 | .agent_loop.checkpoint_turns=10' config/config.json > "${tmp_config}"
        mv "${tmp_config}" config/config.json
        bash bin/agent work "查看cpu继续深入" 2>&1
    )"
    grep -q '工作流执行完成: status=iteration_limit_stopped' <<<"${output}"
    log_file="$(find "${project}/logs" -name '*.jsonl' -print -quit)"
    grep -q '"stopped_reason":"max_iterations_reached"' "${log_file}"
}

project_main="${tmp_root}/main-work"
copy_project "${project_main}"
output="$(cd "${project_main}" && bash bin/agent work "帮我检查磁盘空间是否异常" <<< $'y\ny\n' 2>&1)"
plan_removed_output="$(bash "${ROOT_DIR}/bin/agent" plan "帮我检查磁盘空间是否异常" 2>&1 || true)"
script_output="$(bash "${ROOT_DIR}/bin/agent" script ops-basic/resource-inspect '{"top_n":1}' <<< $'y\n' 2>&1)"
project_json="${tmp_root}/json-work"
copy_project "${project_json}"
json_output="$(cd "${project_json}" && LINUX_AGENT_OUTPUT_JSON=1 bash bin/agent work "查看cpu占用,内存环境" 2>/dev/null)"
script_json_output="$(LINUX_AGENT_OUTPUT_JSON=1 bash "${ROOT_DIR}/bin/agent" script ops-basic/resource-inspect '{"top_n":1}' <<< $'y\n' 2>/dev/null)"
tools_output="$(bash "${ROOT_DIR}/bin/agent" tools list)"

grep -q '工作流执行完成: status=executed' <<<"${output}"
grep -q '步骤输出' <<<"${output}"
grep -q '# 工作计划' <<<"${output}"
grep -q '未知命令: plan' <<<"${plan_removed_output}"
grep -q '脚本执行结果: 成功' <<<"${script_output}"
grep -q '系统负载' <<<"${script_output}"
grep -q '"status": "executed"' <<<"${json_output}"
grep -q '"auto_executed_count": 1' <<<"${json_output}"
grep -q '"tool": "system.resource.inspect"' <<<"${script_json_output}"
grep -q 'ops-basic/process-inspect' <<<"${tools_output}"
grep -q 'ops-basic/resource-inspect' <<<"${tools_output}"

assert_single_run_session "session-terminal" bash bin/agent terminal "printf ok"
assert_single_run_session "session-doctor" bash bin/agent doctor
assert_single_run_session "session-sense" bash bin/agent sense disk
assert_single_run_session "session-tools" bash bin/agent tools list
assert_single_run_session "session-skills" bash bin/agent skills validate
assert_ai_file_manifest
assert_simple_plan_skips_reflection
assert_no_default_thinking_trace
assert_thinking_trace
assert_checkpoint_stop
assert_iteration_limit_stop

printf 'smoke: ok\n'
