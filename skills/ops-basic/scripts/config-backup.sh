#!/usr/bin/env bash

set -euo pipefail
umask 077

arguments_json="${1:-}"
[[ -z "${arguments_json}" ]] && arguments_json='{}'
target_path="$(jq -r '.path // empty' <<<"${arguments_json}")"
backup_root="$(jq -r '.backup_root // "/tmp/linux-agent-backups"' <<<"${arguments_json}")"

if [[ -z "${target_path}" ]]; then
    jq -cn '{ok:false, tool:"system.config.backup", error:"缺少 path 参数。"}'
    exit 0
fi

if [[ -L "${target_path}" ]]; then
    jq -cn \
        --arg path "${target_path}" \
        '{ok:false, tool:"system.config.backup", path:$path, error:"拒绝为符号链接生成备份。"}'
    exit 0
fi

if [[ ! -e "${target_path}" ]]; then
    jq -cn \
        --arg path "${target_path}" \
        '{ok:false, tool:"system.config.backup", path:$path, error:"目标路径不存在。"}'
    exit 0
fi

resolved_path="$(realpath -e -- "${target_path}" 2>/dev/null || true)"
if [[ -z "${resolved_path}" || -L "${resolved_path}" ]]; then
    jq -cn \
        --arg path "${target_path}" \
        '{ok:false, tool:"system.config.backup", path:$path, error:"目标路径不可安全解析。"}'
    exit 0
fi
resolved_backup_root="$(realpath -m -- "${backup_root}" 2>/dev/null || true)"
case "${resolved_backup_root}" in
    "${resolved_path}" | "${resolved_path}"/*)
        jq -cn \
            --arg path "${resolved_path}" \
            '{ok:false, tool:"system.config.backup", path:$path, error:"备份目录不能位于目标路径内。"}'
        exit 0
        ;;
esac
mkdir -p -- "${resolved_backup_root}"
chmod 0700 -- "${resolved_backup_root}"
safe_name="$(printf '%s' "${resolved_path}" | sed 's#^/##; s#[/[:space:]]#_#g')"
archive_path="$(mktemp "${resolved_backup_root}/${safe_name}.XXXXXX.tar.gz")"
chmod 0600 -- "${archive_path}"
if ! tar -czf "${archive_path}" -C / "${resolved_path#/}" 2>/dev/null; then
    rm -f -- "${archive_path}"
    jq -cn --arg path "${resolved_path}" \
        '{ok:false, tool:"system.config.backup", path:$path, error:"备份归档创建失败。"}'
    exit 0
fi

source_sha256=""
source_size_bytes=""
source_mtime_ns=""
source_inode=""
if [[ -f "${resolved_path}" ]]; then
    source_sha256="$(sha256sum -- "${resolved_path}" | awk '{print $1}')"
    source_size_bytes="$(stat -c '%s' -- "${resolved_path}")"
    source_mtime_ns="$(stat -c '%Y%N' -- "${resolved_path}" | sed -n 's/^\([0-9]*\)ns.*/\1/p')"
    [[ -n "${source_mtime_ns}" ]] || source_mtime_ns="$(stat -c '%Y' -- "${resolved_path}")000000000"
    source_inode="$(stat -c '%i' -- "${resolved_path}")"
fi
archive_size_bytes="$(stat -c '%s' -- "${archive_path}")"
archive_sha256="$(sha256sum -- "${archive_path}" | awk '{print $1}')"

jq -cn \
    --arg tool "system.config.backup" \
    --arg path "${resolved_path}" \
    --arg archive "${archive_path}" \
    --arg stat "$(stat -c '%U:%G %a %n' -- "${resolved_path}" 2>/dev/null || true)" \
    --arg source_sha256 "${source_sha256}" \
    --arg source_size_bytes "${source_size_bytes}" \
    --arg source_mtime_ns "${source_mtime_ns}" \
    --arg source_inode "${source_inode}" \
    --arg archive_sha256 "${archive_sha256}" \
    --argjson archive_size_bytes "${archive_size_bytes}" \
    '{ok:true, tool:$tool, path:$path, archive:$archive, stat:$stat,
      source_sha256:(if $source_sha256 == "" then null else $source_sha256 end),
      source_size_bytes:(if $source_size_bytes == "" then null else ($source_size_bytes | tonumber) end),
      source_mtime_ns:(if $source_mtime_ns == "" then null else ($source_mtime_ns | tonumber) end),
      source_inode:(if $source_inode == "" then null else ($source_inode | tonumber) end),
      archive_sha256:$archive_sha256, archive_size_bytes:$archive_size_bytes}'
