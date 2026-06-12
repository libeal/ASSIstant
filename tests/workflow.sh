#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export LINUX_AGENT_MOCK=1

failure_output="$(bash "${ROOT_DIR}/bin/agent" work "请演示失败中断" <<< $'y\n' 2>&1)"
grep -q '工作流执行完成: status=failed' <<<"${failure_output}"
grep -q '步骤执行结果: 失败' <<<"${failure_output}"
grep -q '回滚或修复建议' <<<"${failure_output}"

blocked_output="$(bash "${ROOT_DIR}/bin/agent" work "帮我检查磁盘空间是否异常" <<< $'n\n' 2>&1)"
grep -q '工作流执行完成: status=rejected' <<<"${blocked_output}"

skip_empty_output="$(bash "${ROOT_DIR}/bin/agent" work "帮我检查磁盘空间是否异常" <<< $'s\n\ny\n' 2>&1)"
grep -q '已跳过当前步骤' <<<"${skip_empty_output}"
grep -q '工作流执行完成: status=executed' <<<"${skip_empty_output}"

skip_json_output="$(LINUX_AGENT_OUTPUT_JSON=1 bash "${ROOT_DIR}/bin/agent" work "帮我检查磁盘空间是否异常" <<< $'s\n\ny\n' 2>/dev/null)"
grep -q '"status": "executed"' <<<"${skip_json_output}"
grep -q '"status": "skipped"' <<<"${skip_json_output}"
grep -q '"action": "skipped_by_user"' <<<"${skip_json_output}"

revision_output="$(bash "${ROOT_DIR}/bin/agent" work "帮我检查磁盘空间是否异常" <<< $'s\n查看cpu占用\ny\n' 2>&1)"
grep -q '根据修改需求生成续写计划' <<<"${revision_output}"
grep -q '系统负载' <<<"${revision_output}"
grep -q '工作流执行完成: status=executed' <<<"${revision_output}"

terminated_output="$(bash "${ROOT_DIR}/bin/agent" work "帮我检查磁盘空间是否异常" <<< $'t\n' 2>&1)"
grep -q '工作流执行完成: status=terminated' <<<"${terminated_output}"
! grep -q '步骤输出' <<<"${terminated_output}"

invalid_script="$(bash "${ROOT_DIR}/bin/agent" script /tmp/not-allowed.sh '{}' 2>&1 || true)"
grep -q '脚本状态: blocked' <<<"${invalid_script}"

quiet_output="$(bash "${ROOT_DIR}/bin/agent" work "帮我检查磁盘空间是否异常" <<< $'y\ny\n' 2>&1)"
grep -q '工作流执行完成: status=executed' <<<"${quiet_output}"
grep -q '步骤输出' <<<"${quiet_output}"
! grep -q '输出摘要（已脱敏' <<<"${quiet_output}"

resource_output="$(bash "${ROOT_DIR}/bin/agent" work "查看cpu占用,内存环境" <<< $'y\n' 2>&1)"
grep -q '工作流执行完成: status=executed' <<<"${resource_output}"
grep -q '系统负载' <<<"${resource_output}"
grep -q '内存' <<<"${resource_output}"
! grep -q '"ok": true' <<<"${resource_output}"
! grep -q '"tool"' <<<"${resource_output}"

json_output="$(LINUX_AGENT_OUTPUT_JSON=1 bash "${ROOT_DIR}/bin/agent" work "查看cpu占用,内存环境" <<< $'y\n' 2>/dev/null)"
grep -q '"status": "executed"' <<<"${json_output}"
grep -q '"tool": "system.resource.inspect"' <<<"${json_output}"

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
