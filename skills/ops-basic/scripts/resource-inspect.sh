#!/usr/bin/env bash

set -euo pipefail

arguments_json="${1:-}"
[[ -z "${arguments_json}" ]] && arguments_json='{}'
top_n="$(jq -r '.top_n // 10' <<<"${arguments_json}")"
[[ "${top_n}" =~ ^[0-9]+$ ]] || top_n=10
[[ "${top_n}" -gt 0 ]] || top_n=10
[[ "${top_n}" -le 50 ]] || top_n=50

memory_output="$(free -h 2>/dev/null || true)"
load_output="$(uptime 2>/dev/null || true)"
cpu_count="$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || printf '0')"
cpu_model="$(awk -F: '/model name/ {gsub(/^[ \t]+/, "", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"
top_processes="$(ps -eo pid,user,%cpu,%mem,stat,comm --sort=-%cpu 2>/dev/null | head -n $((top_n + 1)) || true)"

jq -cn \
    --arg tool "system.resource.inspect" \
    --arg load "${load_output}" \
    --arg memory "${memory_output}" \
    --arg cpu_count "${cpu_count}" \
    --arg cpu_model "${cpu_model}" \
    --arg top_processes "${top_processes}" \
    '{ok:true, tool:$tool, load:$load, cpu_count:($cpu_count | tonumber? // 0), cpu_model:$cpu_model, memory:$memory, top_processes:$top_processes}'
