#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export LINUX_AGENT_MOCK=1

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

printf 'smoke: ok\n'
