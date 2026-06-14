#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export LINUX_AGENT_MOCK=1

tmp_root="$(mktemp -d)"
cleanup() {
    rm -rf "${tmp_root}"
}
trap cleanup EXIT

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
    (cd "${project}" && LINUX_AGENT_MOCK=1 bash bin/agent plan "帮我检查磁盘空间是否异常" >/dev/null 2>&1)
    log_file="$(find "${project}/logs" -name '*.jsonl' -print -quit)"
    grep -q '"stage":"ai_files_manifest"' "${log_file}"
    grep -q '"relative_path":"skills/INDEX.md"' "${log_file}"
    grep -q '"sha256":"' "${log_file}"
    ai_files_line="$(jq -r '.stage' "${log_file}" | awk '$0=="ai_files_manifest" {print NR; exit}')"
    session_finished_line="$(jq -r '.stage' "${log_file}" | awk '$0=="session_finished" {print NR; exit}')"
    [[ -n "${ai_files_line}" && -n "${session_finished_line}" && "${ai_files_line}" -lt "${session_finished_line}" ]]
}

output="$(bash "${ROOT_DIR}/bin/agent" work "帮我检查磁盘空间是否异常" <<< $'y\ny\n' 2>&1)"
plan_output="$(bash "${ROOT_DIR}/bin/agent" plan "帮我检查磁盘空间是否异常")"
script_output="$(bash "${ROOT_DIR}/bin/agent" script ops-basic/resource-inspect '{"top_n":1}' <<< $'y\n' 2>&1)"
json_output="$(LINUX_AGENT_OUTPUT_JSON=1 bash "${ROOT_DIR}/bin/agent" work "查看cpu占用,内存环境" <<< $'y\n' 2>/dev/null)"
script_json_output="$(LINUX_AGENT_OUTPUT_JSON=1 bash "${ROOT_DIR}/bin/agent" script ops-basic/resource-inspect '{"top_n":1}' <<< $'y\n' 2>/dev/null)"
tools_output="$(bash "${ROOT_DIR}/bin/agent" tools list)"

grep -q '工作流执行完成: status=executed' <<<"${output}"
grep -q '步骤输出' <<<"${output}"
grep -q '# 工作计划' <<<"${plan_output}"
grep -q '脚本执行结果: 成功' <<<"${script_output}"
grep -q '系统负载' <<<"${script_output}"
grep -q '"status": "executed"' <<<"${json_output}"
grep -q '"tool": "system.resource.inspect"' <<<"${script_json_output}"
grep -q 'ops-basic/process-inspect' <<<"${tools_output}"
grep -q 'ops-basic/resource-inspect' <<<"${tools_output}"

assert_single_run_session "session-terminal" bash bin/agent terminal "printf ok"
assert_single_run_session "session-doctor" bash bin/agent doctor
assert_single_run_session "session-sense" bash bin/agent sense disk
assert_single_run_session "session-tools" bash bin/agent tools list
assert_single_run_session "session-skills" bash bin/agent skills validate
assert_ai_file_manifest

printf 'smoke: ok\n'
