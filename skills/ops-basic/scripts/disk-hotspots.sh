#!/usr/bin/env bash

set -euo pipefail

arguments_json="${1:-}"
[[ -z "${arguments_json}" ]] && arguments_json='{}'
path="$(jq -r '.path // "/var"' <<<"${arguments_json}")"
top_n="$(jq -r '.top_n // 10' <<<"${arguments_json}")"

df_output="$(df -h "${path}" 2>/dev/null || true)"
du_output="$(du -xhd 1 "${path}" 2>/dev/null | sort -h 2>/dev/null | tail -n "${top_n}" || true)"
file_output="$(find "${path}" -type f -printf '%s %p\n' 2>/dev/null | sort -nr 2>/dev/null | head -n "${top_n}" || true)"

jq -cn \
    --arg tool "system.disk.hotspots" \
    --arg path "${path}" \
    --arg df_output "${df_output}" \
    --arg du_output "${du_output}" \
    --arg file_output "${file_output}" \
    '{
        ok:true,
        tool:$tool,
        path:$path,
        disk_usage:$df_output,
        top_dirs:$du_output,
        top_files:$file_output
    }'
