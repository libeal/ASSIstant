#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
# shellcheck source=../../../lib/common.sh
source "${ROOT_DIR}/lib/common.sh"

arguments_json="${1:-}"
if ! arguments_json="$(linux_agent_normalize_json_object_argument "${arguments_json}")"; then
    jq -cn '{ok:false, tool:"system.journal.inspect", error:"arguments must be a JSON object"}'
    exit 0
fi

unit="$(jq -r '.unit // ""' <<<"${arguments_json}")"
priority="$(jq -r '.priority // ""' <<<"${arguments_json}")"
since="$(jq -r '.since // ""' <<<"${arguments_json}")"
until="$(jq -r '.until // ""' <<<"${arguments_json}")"
boot="$(jq -r '.boot // ""' <<<"${arguments_json}")"
lines="$(jq -r '.lines // 80' <<<"${arguments_json}")"
grep_keyword="$(jq -r '.grep // ""' <<<"${arguments_json}")"

[[ "${lines}" =~ ^[0-9]+$ ]] || lines=80
[[ "${lines}" -gt 0 ]] || lines=80
[[ "${lines}" -le 300 ]] || lines=300

if [[ -n "${unit}" && ! "${unit}" =~ ^[A-Za-z0-9_.@:-]+$ ]]; then
    jq -cn --arg unit "${unit}" '{ok:false, tool:"system.journal.inspect", unit:$unit, error:"unit contains unsupported characters"}'
    exit 0
fi
if [[ -n "${priority}" && ! "${priority}" =~ ^(emerg|alert|crit|err|warning|notice|info|debug|[0-7])$ ]]; then
    jq -cn --arg priority "${priority}" '{ok:false, tool:"system.journal.inspect", priority:$priority, error:"priority must be 0-7 or a journal priority name"}'
    exit 0
fi
if ! command -v journalctl >/dev/null 2>&1; then
    jq -cn '{ok:false, tool:"system.journal.inspect", error:"journalctl is unavailable"}'
    exit 0
fi

args=(--no-pager -n "${lines}")
[[ -n "${unit}" ]] && args+=(-u "${unit}")
[[ -n "${priority}" ]] && args+=(-p "${priority}")
[[ -n "${since}" ]] && args+=(--since "${since}")
[[ -n "${until}" ]] && args+=(--until "${until}")
if [[ "${boot}" == "true" ]]; then
    args+=(-b)
elif [[ "${boot}" =~ ^-?[0-9]+$ ]]; then
    args+=(-b "${boot}")
fi

if command -v timeout >/dev/null 2>&1; then
    journal_output="$(timeout 10s journalctl "${args[@]}" 2>&1 || true)"
else
    journal_output="$(journalctl "${args[@]}" 2>&1 || true)"
fi
if [[ -n "${grep_keyword}" ]]; then
    journal_output="$(printf '%s\n' "${journal_output}" | grep -i -- "${grep_keyword}" || true)"
fi
journal_output="$(printf '%s\n' "${journal_output}" | head -n "${lines}")"

jq -cn \
    --arg tool "system.journal.inspect" \
    --arg unit "${unit}" \
    --arg priority "${priority}" \
    --arg since "${since}" \
    --arg until "${until}" \
    --arg boot "${boot}" \
    --arg grep "${grep_keyword}" \
    --arg journal "$(linux_agent_sanitize_text "${journal_output}" 8000)" \
    --argjson lines "${lines}" \
    '{ok:true, tool:$tool, unit:$unit, priority:$priority, since:$since, until:$until, boot:$boot, grep:$grep, lines:$lines, journal:$journal}'
