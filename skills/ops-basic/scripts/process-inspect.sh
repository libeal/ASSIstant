#!/usr/bin/env bash

set -euo pipefail

arguments_json="${1:-}"
[[ -z "${arguments_json}" ]] && arguments_json='{}'
pattern="$(jq -r '.pattern // ""' <<<"${arguments_json}")"

if [[ -n "${pattern}" ]]; then
    ps_output="$(ps -ef 2>/dev/null | grep -i -- "${pattern}" | grep -v grep | head -n 20 || true)"
else
    ps_output="$(ps -eo pid,ppid,user,%cpu,%mem,stat,comm --sort=-%cpu 2>/dev/null | head -n 20)"
fi

jq -cn \
    --arg tool "system.process.inspect" \
    --arg pattern "${pattern}" \
    --arg processes "${ps_output}" \
    --arg zombies "$(ps -eo pid,ppid,stat,comm 2>/dev/null | awk '$3 ~ /Z/ {print}' | head -n 20)" \
    '{ok:true, tool:$tool, pattern:$pattern, processes:$processes, zombies:$zombies}'
