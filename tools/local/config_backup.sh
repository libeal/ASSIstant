#!/usr/bin/env bash

set -euo pipefail

arguments_json="${1:-}"
[[ -z "${arguments_json}" ]] && arguments_json='{}'
target_path="$(jq -r '.path // empty' <<<"${arguments_json}")"
backup_root="$(jq -r '.backup_root // "/tmp/linux-agent-backups"' <<<"${arguments_json}")"

if [[ -z "${target_path}" ]]; then
    jq -cn '{ok:false, tool:"system.config.backup", error:"缺少 path 参数。"}'
    exit 0
fi

if [[ ! -e "${target_path}" ]]; then
    jq -cn \
        --arg path "${target_path}" \
        '{ok:false, tool:"system.config.backup", path:$path, error:"目标路径不存在。"}'
    exit 0
fi

timestamp="$(date -u +"%Y%m%d_%H%M%S")"
safe_name="$(printf '%s' "${target_path}" | sed 's#^/##; s#[/[:space:]]#_#g')"
mkdir -p "${backup_root}"
archive_path="${backup_root}/${safe_name}_${timestamp}.tar.gz"

tar -czf "${archive_path}" -C / "${target_path#/}" 2>/dev/null

jq -cn \
    --arg tool "system.config.backup" \
    --arg path "${target_path}" \
    --arg archive "${archive_path}" \
    --arg stat "$(stat -c '%U:%G %a %n' "${target_path}" 2>/dev/null || true)" \
    '{ok:true, tool:$tool, path:$path, archive:$archive, stat:$stat}'
