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
start_fake_ai_server "$((22000 + RANDOM % 1000))" "${tmp_root}"

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

run_agent_cmd() {
    local name="$1"
    shift
    local project="${tmp_root}/${name}"
    copy_project "${project}"
    (cd "${project}" && "$@")
}

context_project="${tmp_root}/context-turns"
copy_project "${context_project}"
context_history_file="${context_project}/tmp/conversation-history.json"
(
    cd "${context_project}"
    # shellcheck source=/dev/null
    source lib/common.sh
    # shellcheck source=/dev/null
    source lib/config.sh
    # shellcheck source=/dev/null
    source lib/context.sh
    linux_agent_init_env "${context_project}"
    linux_agent_load_config
    LINUX_AGENT_CONVERSATION_HISTORY_FILE="${context_history_file}"
    LINUX_AGENT_CONFIG_JSON="$(jq '.context_turns=2' <<<"${LINUX_AGENT_CONFIG_JSON}")"
    linux_agent_record_conversation_turn "work" "第一轮请求" "第一轮完成" "executed" "request"
    linux_agent_record_conversation_turn "work" "第二轮请求" "第二轮完成" "executed" "request"
    linux_agent_record_conversation_turn "work" "第三轮请求" "第三轮完成" "executed" "request"
    linux_agent_history_window
) >"${tmp_root}/context-window.json"
jq -e 'length == 2
    and .[0].request.content == "第二轮请求"
    and .[1].request.content == "第三轮请求"
    and all(.[]; .type == "request" and (.request | type) == "object" and (.response | type) == "object")' \
    "${tmp_root}/context-window.json" >/dev/null

legacy_history_file="${tmp_root}/legacy-history.json"
jq -cn '[
    {role:"user", content:"旧用户请求", status:"work", timestamp:"t1"},
    {role:"assistant", content:"旧助手响应", status:"executed", timestamp:"t2"}
]' >"${legacy_history_file}"
legacy_window="$(
    cd "${context_project}"
    # shellcheck source=/dev/null
    source lib/common.sh
    # shellcheck source=/dev/null
    source lib/config.sh
    # shellcheck source=/dev/null
    source lib/context.sh
    linux_agent_init_env "${context_project}"
    linux_agent_load_config
    # Consumed by linux_agent_history_window from the sourced context module.
    # shellcheck disable=SC2034
    LINUX_AGENT_CONVERSATION_HISTORY_FILE="${legacy_history_file}"
    LINUX_AGENT_CONFIG_JSON="$(jq '.context_turns=1' <<<"${LINUX_AGENT_CONFIG_JSON}")"
    linux_agent_history_window
)"
jq -e 'length == 1
    and .[0].type == "request"
    and .[0].request.content == "旧用户请求"
    and .[0].response.content == "旧助手响应"
    and .[0].status == "executed"' <<<"${legacy_window}" >/dev/null

failure_output="$(run_agent_cmd failure bash bin/agent work "请演示失败中断" <<<$'y\n' 2>&1)"
grep -q '工作流执行完成: status=failed' <<<"${failure_output}"
grep -q '步骤执行结果: 失败' <<<"${failure_output}"
grep -q '回滚或修复建议' <<<"${failure_output}"

blocked_output="$(run_agent_cmd blocked bash bin/agent work "帮我检查磁盘空间是否异常" <<<$'n\n' 2>&1)"
grep -q '工作流执行完成: status=rejected' <<<"${blocked_output}"

skip_empty_output="$(run_agent_cmd skip-empty bash bin/agent work "帮我检查磁盘空间是否异常" <<<$'s\n\ny\n' 2>&1)"
grep -q '已跳过当前步骤' <<<"${skip_empty_output}"
grep -q '工作流执行完成: status=executed' <<<"${skip_empty_output}"

skip_json_output="$(run_agent_cmd skip-json env LINUX_AGENT_OUTPUT_JSON=1 bash bin/agent work "帮我检查磁盘空间是否异常" <<<$'s\n\ny\n' 2>/dev/null)"
grep -q '"status": "executed"' <<<"${skip_json_output}"
grep -q '"status": "skipped"' <<<"${skip_json_output}"
grep -q '"action": "skipped_by_user"' <<<"${skip_json_output}"

revision_output="$(run_agent_cmd revision bash bin/agent work "帮我检查磁盘空间是否异常" <<<$'s\n查看cpu占用\ny\n' 2>&1)"
grep -q '根据修改需求生成续写计划' <<<"${revision_output}"
grep -q '系统负载' <<<"${revision_output}"
grep -q '工作流执行完成: status=executed' <<<"${revision_output}"

terminated_output="$(run_agent_cmd terminated bash bin/agent work "请演示失败中断" <<<$'t\n' 2>&1)"
grep -q '工作流执行完成: status=terminated' <<<"${terminated_output}"
! grep -q '步骤输出' <<<"${terminated_output}"

invalid_script="$(bash "${ROOT_DIR}/bin/agent" script /tmp/not-allowed.sh '{}' 2>&1 || true)"
grep -q '脚本状态: blocked' <<<"${invalid_script}"

quiet_output="$(run_agent_cmd quiet bash bin/agent work "帮我检查磁盘空间是否异常" <<<$'y\ny\n' 2>&1)"
grep -q '工作流执行完成: status=executed' <<<"${quiet_output}"
grep -q '步骤输出' <<<"${quiet_output}"
! grep -q '输出摘要（已脱敏' <<<"${quiet_output}"

resource_output="$(run_agent_cmd resource bash bin/agent work "查看cpu占用,内存环境" 2>&1)"
grep -q '工作流执行完成: status=executed' <<<"${resource_output}"
grep -q '系统负载' <<<"${resource_output}"
grep -q '内存' <<<"${resource_output}"
grep -q '低风险步骤已自动批准执行' <<<"${resource_output}"
! grep -q 'invalid JSON text passed to --argjson' <<<"${resource_output}"
! grep -q '"ok": true' <<<"${resource_output}"
! grep -q '"tool"' <<<"${resource_output}"
resource_audit_log="$(find "${tmp_root}/resource/logs" -maxdepth 1 -type f -name '*.jsonl' -print -quit)"
[[ -n "${resource_audit_log}" ]]
for required_stage in step_pending step_policy_checked step_approved step_running; do
    jq -e --arg stage "${required_stage}" '
        select(.stage == $stage and .payload.step.executor_type == "skill_script")
    ' "${resource_audit_log}" >/dev/null
done
jq -e '
    select(
        .stage == "step_policy_checked"
        and .payload.review.approved == true
        and .payload.review.risk_level == "low"
        and .payload.review.finding_count == 0
    )
' "${resource_audit_log}" >/dev/null

json_output="$(run_agent_cmd json env LINUX_AGENT_OUTPUT_JSON=1 bash bin/agent work "查看cpu占用,内存环境" 2>/dev/null)"
grep -q '"status": "executed"' <<<"${json_output}"
grep -q '"tool": "system.resource.inspect"' <<<"${json_output}"
grep -q '"auto_executed_count": 1' <<<"${json_output}"
grep -q '"final_answer": ""' <<<"${json_output}"
grep -q '"stopped_reason": "资源检查 skill 的预期输出已经满足当前请求，执行成功后无需再次反思。"' <<<"${json_output}"

continue_output="$(run_agent_cmd continue bash bin/agent work "查看cpu继续深入" 2>&1)"
grep -q '工作流执行完成: status=executed' <<<"${continue_output}"
grep -q '补充查看 CPU 与内存资源概况' <<<"${continue_output}"
[[ "$(grep -c '低风险步骤已自动批准执行' <<<"${continue_output}")" -ge 2 ]]
! grep -q 'invalid JSON text passed to --argjson' <<<"${continue_output}"

loop_history_project="${tmp_root}/loop-history"
copy_project "${loop_history_project}"
loop_history_file="${loop_history_project}/tmp/loop-history.json"
(
    cd "${loop_history_project}"
    LINUX_AGENT_CONVERSATION_HISTORY_FILE="${loop_history_file}" bash bin/agent work "查看cpu继续深入" >/dev/null
)
jq -e 'length == 2
    and all(.[]; .type == "agent_loop_iteration")
    and .[0].iteration == 1
    and .[1].iteration == 2
    and all(.[]; (.request.content | contains("查看cpu继续深入")) and (.response | type) == "object")' \
    "${loop_history_file}" >/dev/null

invalid_reflect_output="$(run_agent_cmd invalid-reflect bash bin/agent work "查看cpu 非法继续决策" 2>&1)"
grep -q '模型反思响应缺少合法 continue_decision' <<<"${invalid_reflect_output}"
grep -q '工作流执行完成: status=executed' <<<"${invalid_reflect_output}"

render_input="$(jq -cn --arg table $'COL1\tCOL2\nA\tB' '{ok:true, exit_code:0, output:{ok:true, tool:"demo.render", table:$table, empty:"", count:2}}')"
render_output="$(
    {
        source "${ROOT_DIR}/lib/executor.sh"
        linux_agent_print_user_output "${render_input}" "步骤输出"
    } 2>&1
)"
grep -q '步骤输出' <<<"${render_output}"
grep -q $'COL1\tCOL2' <<<"${render_output}"
grep -q $'A\tB' <<<"${render_output}"
grep -q 'count: 2' <<<"${render_output}"
! grep -q '"ok": true' <<<"${render_output}"
! grep -q '"tool"' <<<"${render_output}"
! grep -q '\\n' <<<"${render_output}"
! grep -q '\\t' <<<"${render_output}"

printf 'workflow: ok\n'
