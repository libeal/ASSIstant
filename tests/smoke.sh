#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=helpers.sh
source "${ROOT_DIR}/tests/helpers.sh"
linux_agent_test_install_failure_trap "smoke"

tmp_root="$(mktemp -d)"
cleanup() {
    stop_fake_ai_server
    rm -rf -- "${tmp_root}"
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

permission_project="${tmp_root}/runtime-permission"
permission_stdout="${tmp_root}/runtime-permission.stdout"
permission_stderr="${tmp_root}/runtime-permission.stderr"
copy_project "${permission_project}"
mkdir -p "${permission_project}/tmp"
chmod 0500 "${permission_project}/tmp"
permission_timeout="$(linux_agent_test_timeout_seconds 30)"
linux_agent_test_log "start: runtime permission failure (timeout=${permission_timeout}s)"
if (cd "${permission_project}" && timeout -k 5s "${permission_timeout}s" \
    bash bin/agent doctor >"${permission_stdout}" 2>"${permission_stderr}"); then
    permission_status=0
else
    permission_status=$?
fi
linux_agent_test_log_command_result "runtime permission failure" "${permission_timeout}" "${permission_status}"
chmod 0700 "${permission_project}/tmp"
[[ "${permission_status}" -ne 0 ]]
grep -q '运行目录不可写' "${permission_stderr}"

assert_single_run_session() {
    local name="$1"
    shift
    local project="${tmp_root}/${name}"
    local log_file
    copy_project "${project}"
    linux_agent_test_run "single session: ${name}" 60 "${project}" discard "$@"
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
    linux_agent_test_run "AI file manifest" 90 "${project}" discard \
        bash bin/agent work "查看cpu占用,内存环境"
    log_file="$(find "${project}/logs" -name '*.jsonl' -print -quit)"
    grep -q '"stage":"ai_files_manifest"' "${log_file}"
    grep -q '"relative_path":"skills/INDEX.md"' "${log_file}"
    grep -q '"relative_path":"skills/ops-basic/SKILL.md"' "${log_file}"
    ! grep -q '"relative_path":"skills/network-ops-tools/SKILL.md"' "${log_file}"
    jq -e '
        select(.stage == "request_context_built")
        | .payload.skills
        | .candidate_count == 1
            and ([.candidates[].name] == ["ops-basic"])
            and .loaded_count == 0
    ' "${log_file}" >/dev/null
    jq -se --arg request '查看cpu占用,内存环境' '
        [.[] | select((.payload | tostring) | contains($request)) | .stage]
        | sort == (["received", "request_context_built"] | sort)
    ' "${log_file}" >/dev/null
    grep -q '"sha256":"' "${log_file}"
    ai_files_line="$(jq -r '.stage' "${log_file}" | awk '$0=="ai_files_manifest" {print NR; exit}')"
    session_finished_line="$(jq -r '.stage' "${log_file}" | awk '$0=="session_finished" {print NR; exit}')"
    [[ -n "${ai_files_line}" && -n "${session_finished_line}" && "${ai_files_line}" -lt "${session_finished_line}" ]]
}

assert_thinking_trace() {
    local project="${tmp_root}/thinking-trace"
    local log_file session_id thinking_file thinking_root tmp_config
    local -a thinking_files=()
    thinking_root="${tmp_root}/thinking-traces"
    copy_project "${project}"
    tmp_config="$(mktemp)"
    jq '.agent_loop.thinking_trace_enabled=true' "${project}/config/config.json" >"${tmp_config}"
    mv "${tmp_config}" "${project}/config/config.json"
    linux_agent_test_run "thinking trace" 120 "${project}" discard \
        env LINUX_AGENT_THINKING_TRACE_DIR="${thinking_root}" \
        bash bin/agent work "查看cpu继续深入"
    log_file="$(find "${project}/logs" -name '*.jsonl' -print -quit)"
    session_id="$(basename "${log_file}" .jsonl)"
    mapfile -t thinking_files < <(
        grep -rl --fixed-strings \
            '第一轮结果不足以完成测试场景' \
            "${thinking_root}/${session_id}/thinking" || true
    )
    [[ "${#thinking_files[@]}" -eq 1 ]]
    thinking_file="${thinking_files[0]}"
    [[ -f "${thinking_file}" ]]
    ! grep -R -q '第一轮结果不足以完成测试场景' "${project}/logs"
}

assert_simple_plan_skips_reflection() {
    local project="${tmp_root}/simple-no-reflect"
    local log_file
    copy_project "${project}"
    linux_agent_test_run "simple plan without reflection" 90 "${project}" discard \
        bash bin/agent work "查看cpu占用,内存环境"
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
    linux_agent_test_run "default thinking trace disabled" 90 "${project}" discard \
        env LINUX_AGENT_THINKING_TRACE_DIR="${thinking_root}" \
        bash bin/agent work "查看cpu占用,内存环境"
    log_file="$(find "${project}/logs" -name '*.jsonl' -print -quit)"
    session_id="$(basename "${log_file}" .jsonl)"
    [[ ! -e "${thinking_root}/${session_id}/thinking" ]]
}

assert_checkpoint_stop() {
    local project="${tmp_root}/checkpoint-stop"
    local output tmp_config
    copy_project "${project}"
    tmp_config="$(mktemp)"
    jq '.agent_loop.checkpoint_turns=1' "${project}/config/config.json" >"${tmp_config}"
    mv "${tmp_config}" "${project}/config/config.json"
    output="$(
        linux_agent_test_capture "checkpoint stop" 120 "${project}" merge \
            bash bin/agent work "查看cpu继续深入" <<<$'n\n'
    )"
    grep -q '允许继续深入' <<<"${output}"
    grep -q '工作流执行完成: status=checkpoint_stopped' <<<"${output}"
}

assert_iteration_limit_stop() {
    local project="${tmp_root}/iteration-limit-stop"
    local output tmp_config log_file
    copy_project "${project}"
    tmp_config="$(mktemp)"
    jq '.agent_loop.max_iterations=1 | .agent_loop.checkpoint_turns=10' \
        "${project}/config/config.json" >"${tmp_config}"
    mv "${tmp_config}" "${project}/config/config.json"
    output="$(
        linux_agent_test_capture "iteration limit stop" 120 "${project}" merge \
            bash bin/agent work "查看cpu继续深入"
    )"
    grep -q '工作流执行完成: status=iteration_limit_stopped' <<<"${output}"
    log_file="$(find "${project}/logs" -name '*.jsonl' -print -quit)"
    grep -q '"stopped_reason":"max_iterations_reached"' "${log_file}"
}

project_main="${tmp_root}/main-work"
copy_project "${project_main}"
output="$(
    linux_agent_test_capture "main work approval" 120 "${project_main}" merge \
        bash bin/agent work "帮我检查磁盘空间是否异常" <<<$'y\ny\n'
)"
plan_removed_output="$(
    linux_agent_test_capture "removed plan command" 30 "${ROOT_DIR}" merge \
        bash bin/agent plan "帮我检查磁盘空间是否异常" || true
)"
script_output="$(
    linux_agent_test_capture "resource inspect script" 60 "${ROOT_DIR}" merge \
        bash bin/agent script ops-basic/resource-inspect '{"top_n":1}' <<<$'y\n'
)"
project_json="${tmp_root}/json-work"
copy_project "${project_json}"
json_output="$(
    linux_agent_test_capture "work JSON output" 90 "${project_json}" discard \
        env LINUX_AGENT_OUTPUT_JSON=1 bash bin/agent work "查看cpu占用,内存环境"
)"
script_json_output="$(
    linux_agent_test_capture "script JSON output" 60 "${ROOT_DIR}" discard \
        env LINUX_AGENT_OUTPUT_JSON=1 bash bin/agent script ops-basic/resource-inspect '{"top_n":1}' \
        <<<$'y\n'
)"
tools_output="$(
    linux_agent_test_capture "tools list" 30 "${ROOT_DIR}" inherit \
        bash bin/agent tools list
)"

grep -q '工作流执行完成: status=executed' <<<"${output}"
grep -q '步骤输出' <<<"${output}"
grep -q '# 工作计划' <<<"${output}"
grep -q '未知命令: plan' <<<"${plan_removed_output}"
grep -q '脚本执行结果: 成功' <<<"${script_output}"
grep -q '系统负载' <<<"${script_output}"
grep -q '"status": "executed"' <<<"${json_output}"
grep -q '"auto_executed_count": 2' <<<"${json_output}"
jq -e 'any(.results[]?;
    .step.executor_type == "skill_load"
    and .step.skill == "ops-basic")' <<<"${json_output}" >/dev/null
jq -e 'any(.output_blocks[]?; .kind == "json" and .json.tool == "system.resource.inspect")' \
    <<<"${script_json_output}" >/dev/null
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
