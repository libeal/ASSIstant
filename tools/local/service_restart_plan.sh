#!/usr/bin/env bash

set -euo pipefail

arguments_json="${1:-}"
[[ -z "${arguments_json}" ]] && arguments_json='{}'
service="$(jq -r '.service // empty' <<<"${arguments_json}")"

if [[ -z "${service}" ]]; then
    jq -cn '{ok:false, tool:"system.service.restart_plan", error:"缺少 service 参数。"}'
    exit 0
fi

if [[ "${service}" =~ ^(sshd|systemd|containerd|docker|kubelet|mysqld|mysql|mariadb|postgresql)$ ]]; then
    jq -cn \
        --arg service "${service}" \
        '{ok:false, tool:"system.service.restart_plan", service:$service, risk:"high", error:"关键服务需要人工维护窗口，拒绝自动重启。"}'
    exit 0
fi

status_output=""
deps_output=""
if command -v systemctl >/dev/null 2>&1; then
    status_output="$(systemctl status "${service}" --no-pager 2>/dev/null | head -n 40 || true)"
    deps_output="$(systemctl list-dependencies --reverse "${service}" --no-pager 2>/dev/null | head -n 40 || true)"
fi

jq -cn \
    --arg tool "system.service.restart_plan" \
    --arg service "${service}" \
    --arg status "${status_output}" \
    --arg reverse_dependencies "${deps_output}" \
    '{ok:true, tool:$tool, service:$service, action:"plan_only", status:$status, reverse_dependencies:$reverse_dependencies, next_step:"如确认维护窗口和依赖影响，可新增受控 restart Tool 执行。"}'
