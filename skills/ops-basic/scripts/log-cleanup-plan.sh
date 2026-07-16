#!/usr/bin/env bash

set -euo pipefail

arguments_json="${1:-}"
[[ -z "${arguments_json}" ]] && arguments_json='{}'
root_path="$(jq -r '.root_path // "/var/log"' <<<"${arguments_json}")"
min_size_mb="$(jq -r '.min_size_mb // 100' <<<"${arguments_json}")"
max_depth="$(jq -r '.max_depth // 2' <<<"${arguments_json}")"
limit="$(jq -r '.limit // 20' <<<"${arguments_json}")"
resolved_root=""

if [[ ! "${min_size_mb}" =~ ^[0-9]+$ || "${min_size_mb}" -le 0 ]]; then
    jq -cn \
        --arg min_size_mb "${min_size_mb}" \
        '{ok:false, tool:"system.logs.cleanup_plan", min_size_mb:$min_size_mb, error:"min_size_mb 必须是正整数。"}'
    exit 0
fi
if [[ ! "${max_depth}" =~ ^[0-9]+$ || "${max_depth}" -le 0 ]]; then
    jq -cn \
        --arg max_depth "${max_depth}" \
        '{ok:false, tool:"system.logs.cleanup_plan", max_depth:$max_depth, error:"max_depth 必须是正整数。"}'
    exit 0
fi
if [[ ! "${limit}" =~ ^[0-9]+$ || "${limit}" -le 0 ]]; then
    jq -cn \
        --arg limit "${limit}" \
        '{ok:false, tool:"system.logs.cleanup_plan", limit:$limit, error:"limit 必须是正整数。"}'
    exit 0
fi

if ! resolved_root="$(realpath -e "${root_path}" 2>/dev/null)"; then
    jq -cn \
        --arg root_path "${root_path}" \
        '{ok:false, tool:"system.logs.cleanup_plan", root_path:$root_path, error:"扫描根路径不存在或不可解析。"}'
    exit 0
fi

case "${resolved_root}" in
    /var/log | /var/log/* | /tmp | /tmp/*) ;;
    *)
        jq -cn \
            --arg root_path "${root_path}" \
            --arg resolved_path "${resolved_root}" \
            '{ok:false, tool:"system.logs.cleanup_plan", root_path:$root_path, resolved_path:$resolved_path, error:"仅允许扫描 /var/log 或 /tmp。"}'
        exit 0
        ;;
esac

if [[ ! -d "${resolved_root}" ]]; then
    jq -cn \
        --arg root_path "${root_path}" \
        --arg resolved_path "${resolved_root}" \
        '{ok:false, tool:"system.logs.cleanup_plan", root_path:$root_path, resolved_path:$resolved_path, error:"扫描根路径不是目录。"}'
    exit 0
fi

candidate_file="$(mktemp)"
rejected_file="$(mktemp)"
trap 'rm -f "${candidate_file}" "${rejected_file}"' EXIT

count=0
while IFS= read -r file_path; do
    [[ -z "${file_path}" ]] && continue
    size_bytes="$(stat -c '%s' "${file_path}" 2>/dev/null || printf '0')"
    owner="$(stat -c '%U:%G' "${file_path}" 2>/dev/null || printf 'unknown:unknown')"
    mode="$(stat -c '%a' "${file_path}" 2>/dev/null || printf 'unknown')"

    if [[ "${file_path}" =~ (mysql|mariadb|postgres|pgsql|journal|audit|wtmp|btmp|secure|auth) ]]; then
        jq -cn \
            --arg path "${file_path}" \
            --arg reason "疑似关键日志或数据库日志" \
            --argjson size_bytes "${size_bytes}" \
            '{path:$path, size_bytes:$size_bytes, reason:$reason}' >>"${rejected_file}"
        continue
    fi

    jq -cn \
        --arg path "${file_path}" \
        --arg owner "${owner}" \
        --arg mode "${mode}" \
        --argjson size_bytes "${size_bytes}" \
        --argjson min_size_mb "${min_size_mb}" \
        '{
            path:$path,
            size_bytes:$size_bytes,
            owner:$owner,
            mode:$mode,
            risk_level:"medium",
            recommended_steps:[
                {
                    executor_type:"skill_script",
                    skill_script:"ops-basic/config-backup",
                    arguments:{path:$path},
                    reason:"清理前生成可回滚备份",
                    expected_effect:"生成 tar.gz 备份",
                    risk_level:"medium"
                },
                {
                    executor_type:"skill_script",
                    skill_script:"ops-basic/safe-log-cleanup",
                    arguments:{path:$path, max_size_mb:$min_size_mb, dry_run:false},
                    reason:"备份后截断非关键大日志",
                    expected_effect:"释放日志占用空间",
                    risk_level:"high"
                }
            ]
        }' >>"${candidate_file}"

    count=$((count + 1))
    if ((count >= limit)); then
        break
    fi
done < <(find "${resolved_root}" -maxdepth "${max_depth}" -type f -size +"${min_size_mb}"M 2>/dev/null | sort)

candidates="$(jq -s . "${candidate_file}")"
rejected="$(jq -s . "${rejected_file}")"

jq -cn \
    --arg tool "system.logs.cleanup_plan" \
    --arg root_path "${resolved_root}" \
    --argjson min_size_mb "${min_size_mb}" \
    --argjson candidates "${candidates}" \
    --argjson rejected "${rejected}" \
    '{
        ok:true,
        tool:$tool,
        root_path:$root_path,
        min_size_mb:$min_size_mb,
        candidates:$candidates,
        rejected:$rejected,
        summary:{
            candidate_count:($candidates | length),
            rejected_count:($rejected | length)
        }
    }'
