#!/usr/bin/env bash

set -euo pipefail

arguments_json="${1:-}"
[[ -z "${arguments_json}" ]] && arguments_json='{}'
service="$(jq -r '.service // ""' <<<"${arguments_json}")"

if [[ -n "${service}" ]]; then
    status_output="$(systemctl status "${service}" --no-pager 2>/dev/null | head -n 40 || true)"
else
    status_output="$(systemctl list-units --type=service --no-pager 2>/dev/null | head -n 30 || true)"
fi

jq -cn \
    --arg tool "system.service.inspect" \
    --arg service "${service}" \
    --arg status "${status_output}" \
    --arg failed "$(systemctl --failed --no-pager 2>/dev/null || true)" \
    '{ok:true, tool:$tool, service:$service, status:$status, failed:$failed}'
