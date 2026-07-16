#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
# shellcheck source=../../../lib/common.sh
source "${ROOT_DIR}/lib/common.sh"

arguments_json="${1:-}"
[[ -z "${arguments_json}" ]] && arguments_json='{}'
path="$(jq -r '.path // "/var/log"' <<<"${arguments_json}")"
keyword="$(jq -r '.keyword // "error"' <<<"${arguments_json}")"
lines="$(jq -r '.lines // 20' <<<"${arguments_json}")"
include_journal="$(jq -r '.include_journal // false' <<<"${arguments_json}")"
if [[ "${include_journal}" != "true" ]]; then
    include_journal="false"
fi

if [[ ! "${lines}" =~ ^[0-9]+$ || "${lines}" -le 0 ]]; then
    lines=20
elif [[ "${lines}" -gt 200 ]]; then
    lines=200
fi

if ! resolved_path="$(realpath -e "${path}" 2>/dev/null)"; then
    jq -cn \
        --arg tool "system.logs.search" \
        --arg path "${path}" \
        '{ok:false, tool:$tool, path:$path, error:"日志路径不存在或不可解析。"}'
    exit 0
fi

case "${resolved_path}" in
    /var/log | /var/log/*) ;;
    *)
        jq -cn \
            --arg tool "system.logs.search" \
            --arg path "${path}" \
            --arg resolved_path "${resolved_path}" \
            '{ok:false, tool:$tool, path:$path, resolved_path:$resolved_path, error:"仅允许检索 /var/log 下的日志路径。"}'
        exit 0
        ;;
esac

matches=""
journal_output=""
if [[ -d "${resolved_path}" ]]; then
    matches="$(grep -Rin -- "${keyword}" "${resolved_path}" 2>/dev/null | head -n "${lines}" || true)"
elif [[ -f "${resolved_path}" ]]; then
    matches="$(grep -in -- "${keyword}" "${resolved_path}" 2>/dev/null | head -n "${lines}" || true)"
fi
matches="$(linux_agent_sanitize_text "${matches}")"

if [[ "${include_journal}" == "true" ]] && command -v journalctl >/dev/null 2>&1; then
    journal_output="$(journalctl -n "${lines}" --no-pager 2>/dev/null | head -n "${lines}" || true)"
    journal_output="$(linux_agent_sanitize_text "${journal_output}")"
fi

jq -cn \
    --arg tool "system.logs.search" \
    --arg path "${resolved_path}" \
    --arg keyword "${keyword}" \
    --arg matches "${matches}" \
    --arg journal "${journal_output}" \
    --argjson include_journal "${include_journal}" \
    '{ok:true, tool:$tool, path:$path, keyword:$keyword, include_journal:$include_journal, matches:$matches, journal_sample:$journal}'
