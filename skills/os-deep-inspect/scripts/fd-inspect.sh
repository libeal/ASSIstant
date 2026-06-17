#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
# shellcheck source=../../../lib/common.sh
source "${ROOT_DIR}/lib/common.sh"

arguments_json="${1:-}"
if ! arguments_json="$(linux_agent_normalize_json_object_argument "${arguments_json}")"; then
    jq -cn '{ok:false, tool:"system.fd.inspect", error:"arguments must be a JSON object"}'
    exit 0
fi

pid="$(jq -r '.pid // ""' <<<"${arguments_json}")"
pattern="$(jq -r '.pattern // ""' <<<"${arguments_json}")"
limit="$(jq -r '.limit // 80' <<<"${arguments_json}")"

[[ "${limit}" =~ ^[0-9]+$ ]] || limit=80
[[ "${limit}" -gt 0 ]] || limit=80
[[ "${limit}" -le 300 ]] || limit=300

if [[ -n "${pid}" && ! "${pid}" =~ ^[0-9]+$ ]]; then
    jq -cn --arg pid "${pid}" '{ok:false, tool:"system.fd.inspect", pid:$pid, error:"pid must be numeric"}'
    exit 0
fi

run_text() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 10s "$@" 2>&1 || true
    else
        "$@" 2>&1 || true
    fi
}

proc_fd_sample() {
    local target_pid="$1"
    local count=0
    local fd_path target
    [[ -d "/proc/${target_pid}/fd" ]] || return 0
    for fd_path in "/proc/${target_pid}/fd/"*; do
        [[ -e "${fd_path}" ]] || continue
        target="$(readlink "${fd_path}" 2>/dev/null || true)"
        printf '%s -> %s\n' "${fd_path}" "${target}"
        count=$((count + 1))
        [[ "${count}" -ge "${limit}" ]] && break
    done
    return 0
}

tool_used=""
output=""

if command -v lsof >/dev/null 2>&1; then
    tool_used="lsof"
    if [[ -n "${pid}" ]]; then
        output="$(run_text lsof -nP -p "${pid}")"
    else
        output="$(run_text lsof -nP)"
        if [[ -n "${pattern}" ]]; then
            output="$(printf '%s\n' "${output}" | grep -i -- "${pattern}" || true)"
        fi
    fi
    output="$(printf '%s\n' "${output}" | head -n "${limit}")"
elif [[ -n "${pid}" ]]; then
    tool_used="procfs"
    output="$(proc_fd_sample "${pid}")"
else
    jq -cn '{ok:false, tool:"system.fd.inspect", error:"lsof is unavailable; provide pid to use /proc/<pid>/fd fallback"}'
    exit 0
fi

jq -cn \
    --arg tool "system.fd.inspect" \
    --arg tool_used "${tool_used}" \
    --arg pid "${pid}" \
    --arg pattern "${pattern}" \
    --arg open_files "$(linux_agent_sanitize_text "${output}" 6000)" \
    --argjson limit "${limit}" \
    '{ok:true, tool:$tool, command_family:$tool_used, pid:$pid, pattern:$pattern, limit:$limit, open_files:$open_files}'
