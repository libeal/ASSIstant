#!/usr/bin/env bash

set -euo pipefail

arguments_json="${1:-}"
[[ -z "${arguments_json}" ]] && arguments_json='{}'
path="$(jq -r '.path // empty' <<<"${arguments_json}")"
max_size_mb="$(jq -r '.max_size_mb // 100' <<<"${arguments_json}")"
dry_run="$(jq -r 'if has("dry_run") then (.dry_run | tostring) else "true" end' <<<"${arguments_json}")"
backup_archive="$(jq -r '.backup_archive // empty' <<<"${arguments_json}")"
backup_sha256="$(jq -r '.backup_sha256 // empty' <<<"${arguments_json}")"
resolved_path=""

if [[ -z "${path}" ]]; then
    jq -cn '{ok:false, tool:"system.logs.safe_cleanup", error:"缺少 path 参数。"}'
    exit 0
fi

if [[ ! "${max_size_mb}" =~ ^[0-9]+$ ]]; then
    jq -cn \
        --arg max_size_mb "${max_size_mb}" \
        '{ok:false, tool:"system.logs.safe_cleanup", max_size_mb:$max_size_mb, error:"max_size_mb 必须是非负整数。"}'
    exit 0
fi

if [[ "${dry_run}" != "true" && "${dry_run}" != "false" ]]; then
    jq -cn \
        --arg dry_run "${dry_run}" \
        '{ok:false, tool:"system.logs.safe_cleanup", dry_run:$dry_run, error:"dry_run 必须是 true 或 false。"}'
    exit 0
fi

if [[ -L "${path}" ]]; then
    jq -cn \
        --arg path "${path}" \
        '{ok:false, tool:"system.logs.safe_cleanup", path:$path, error:"拒绝清理符号链接。"}'
    exit 0
fi

if ! resolved_path="$(realpath -e "${path}" 2>/dev/null)"; then
    jq -cn \
        --arg path "${path}" \
        '{ok:false, tool:"system.logs.safe_cleanup", path:$path, error:"目标不存在或不可解析。"}'
    exit 0
fi

case "${resolved_path}" in
    /var/log | /var/log/* | /tmp | /tmp/*) ;;
    *)
        jq -cn \
            --arg path "${path}" \
            --arg resolved_path "${resolved_path}" \
            '{ok:false, tool:"system.logs.safe_cleanup", path:$path, resolved_path:$resolved_path, error:"仅允许清理 /var/log 或 /tmp 下的日志文件。"}'
        exit 0
        ;;
esac

if [[ ! -f "${resolved_path}" ]]; then
    jq -cn \
        --arg path "${path}" \
        --arg resolved_path "${resolved_path}" \
        '{ok:false, tool:"system.logs.safe_cleanup", path:$path, resolved_path:$resolved_path, error:"目标不是普通文件。"}'
    exit 0
fi

if [[ "${resolved_path}" =~ (mysql|mariadb|postgres|pgsql|journal|audit|wtmp|btmp|secure|auth) ]]; then
    jq -cn \
        --arg path "${path}" \
        --arg resolved_path "${resolved_path}" \
        '{ok:false, tool:"system.logs.safe_cleanup", path:$path, resolved_path:$resolved_path, error:"疑似关键日志或数据库日志，拒绝自动清理。"}'
    exit 0
fi

size_bytes="$(stat -c '%s' "${resolved_path}" 2>/dev/null || printf '0')"
threshold_bytes=$((max_size_mb * 1024 * 1024))

if ((size_bytes < threshold_bytes)); then
    jq -cn \
        --arg path "${resolved_path}" \
        --argjson size_bytes "${size_bytes}" \
        --argjson threshold_bytes "${threshold_bytes}" \
        '{ok:true, tool:"system.logs.safe_cleanup", path:$path, action:"skip", reason:"文件未超过清理阈值。", size_bytes:$size_bytes, threshold_bytes:$threshold_bytes}'
    exit 0
fi

if [[ "${dry_run}" == "true" ]]; then
    jq -cn \
        --arg path "${resolved_path}" \
        --argjson size_bytes "${size_bytes}" \
        '{ok:true, tool:"system.logs.safe_cleanup", path:$path, action:"dry_run", message:"满足清理条件，但 dry_run=true，未修改文件。", size_bytes:$size_bytes}'
    exit 0
fi

if [[ -z "${backup_archive}" || -z "${backup_sha256}" || ! "${backup_sha256}" =~ ^[0-9a-f]{64}$ ]]; then
    jq -cn \
        --arg path "${resolved_path}" \
        '{ok:false, tool:"system.logs.safe_cleanup", path:$path, status:"backup_required", error:"真实截断必须提供有效的备份归档和源文件 SHA-256。"}'
    exit 0
fi
if [[ -L "${backup_archive}" || ! -f "${backup_archive}" ]]; then
    jq -cn \
        --arg archive "${backup_archive}" \
        '{ok:false, tool:"system.logs.safe_cleanup", status:"backup_invalid", error:"备份归档必须是普通文件。", backup_archive:$archive}'
    exit 0
fi
archive_size="$(stat -c '%s' -- "${backup_archive}" 2>/dev/null || printf '0')"
if [[ ! "${archive_size}" =~ ^[0-9]+$ || "${archive_size}" -gt $((512 * 1024 * 1024)) ]]; then
    jq -cn '{ok:false, tool:"system.logs.safe_cleanup", status:"backup_invalid", error:"备份归档大小非法。"}'
    exit 0
fi
current_sha256="$(sha256sum -- "${resolved_path}" | awk '{print $1}')"
if [[ "${current_sha256}" != "${backup_sha256}" ]]; then
    jq -cn \
        --arg path "${resolved_path}" \
        '{ok:false, tool:"system.logs.safe_cleanup", path:$path, status:"backup_stale", error:"目标文件已不同于备份快照，拒绝截断。"}'
    exit 0
fi
archive_entry="${resolved_path#/}"
entry_count="$(tar -tzf "${backup_archive}" -- "${archive_entry}" 2>/dev/null | awk -v entry="${archive_entry}" '$0 == entry {count++} END {print count + 0}')"
if [[ "${entry_count}" != "1" ]]; then
    jq -cn \
        --arg archive "${backup_archive}" \
        '{ok:false, tool:"system.logs.safe_cleanup", status:"backup_invalid", error:"备份归档不包含唯一的目标文件。", backup_archive:$archive}'
    exit 0
fi
archived_sha256="$(tar -xOzf "${backup_archive}" -- "${archive_entry}" 2>/dev/null | sha256sum | awk '{print $1}')"
if [[ "${archived_sha256}" != "${backup_sha256}" ]]; then
    jq -cn \
        --arg archive "${backup_archive}" \
        '{ok:false, tool:"system.logs.safe_cleanup", status:"backup_invalid", error:"备份归档内容校验失败。", backup_archive:$archive}'
    exit 0
fi

: >"${resolved_path}"

jq -cn \
    --arg path "${resolved_path}" \
    --argjson previous_size_bytes "${size_bytes}" \
    --arg backup_archive "${backup_archive}" \
    '{ok:true, tool:"system.logs.safe_cleanup", path:$path, action:"truncate", previous_size_bytes:$previous_size_bytes, backup_archive:$backup_archive}'
