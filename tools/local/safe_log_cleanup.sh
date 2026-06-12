#!/usr/bin/env bash

set -euo pipefail

arguments_json="${1:-}"
[[ -z "${arguments_json}" ]] && arguments_json='{}'
path="$(jq -r '.path // empty' <<<"${arguments_json}")"
max_size_mb="$(jq -r '.max_size_mb // 100' <<<"${arguments_json}")"
dry_run="$(jq -r '.dry_run // true' <<<"${arguments_json}")"

if [[ -z "${path}" ]]; then
    jq -cn '{ok:false, tool:"system.logs.safe_cleanup", error:"缺少 path 参数。"}'
    exit 0
fi

if [[ "${path}" != /var/log* && "${path}" != /tmp/* ]]; then
    jq -cn \
        --arg path "${path}" \
        '{ok:false, tool:"system.logs.safe_cleanup", path:$path, error:"仅允许清理 /var/log 或 /tmp 下的日志文件。"}'
    exit 0
fi

if [[ ! -f "${path}" ]]; then
    jq -cn \
        --arg path "${path}" \
        '{ok:false, tool:"system.logs.safe_cleanup", path:$path, error:"目标不是普通文件。"}'
    exit 0
fi

if [[ "${path}" =~ (mysql|mariadb|postgres|pgsql|journal|audit|wtmp|btmp|secure|auth) ]]; then
    jq -cn \
        --arg path "${path}" \
        '{ok:false, tool:"system.logs.safe_cleanup", path:$path, error:"疑似关键日志或数据库日志，拒绝自动清理。"}'
    exit 0
fi

size_bytes="$(stat -c '%s' "${path}" 2>/dev/null || printf '0')"
threshold_bytes=$((max_size_mb * 1024 * 1024))

if (( size_bytes < threshold_bytes )); then
    jq -cn \
        --arg path "${path}" \
        --argjson size_bytes "${size_bytes}" \
        --argjson threshold_bytes "${threshold_bytes}" \
        '{ok:true, tool:"system.logs.safe_cleanup", path:$path, action:"skip", reason:"文件未超过清理阈值。", size_bytes:$size_bytes, threshold_bytes:$threshold_bytes}'
    exit 0
fi

if [[ "${dry_run}" == "true" ]]; then
    jq -cn \
        --arg path "${path}" \
        --argjson size_bytes "${size_bytes}" \
        '{ok:true, tool:"system.logs.safe_cleanup", path:$path, action:"dry_run", message:"满足清理条件，但 dry_run=true，未修改文件。", size_bytes:$size_bytes}'
    exit 0
fi

: > "${path}"

jq -cn \
    --arg path "${path}" \
    --argjson previous_size_bytes "${size_bytes}" \
    '{ok:true, tool:"system.logs.safe_cleanup", path:$path, action:"truncate", previous_size_bytes:$previous_size_bytes}'
