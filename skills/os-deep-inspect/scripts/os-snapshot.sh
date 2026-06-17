#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
# shellcheck source=../../../lib/common.sh
source "${ROOT_DIR}/lib/common.sh"

arguments_json="${1:-}"
if ! arguments_json="$(linux_agent_normalize_json_object_argument "${arguments_json}")"; then
    jq -cn '{ok:false, tool:"system.os.snapshot", error:"arguments must be a JSON object"}'
    exit 0
fi

top_n="$(jq -r '.top_n // 10' <<<"${arguments_json}")"
journal_lines="$(jq -r '.journal_lines // 30' <<<"${arguments_json}")"
[[ "${top_n}" =~ ^[0-9]+$ ]] || top_n=10
[[ "${journal_lines}" =~ ^[0-9]+$ ]] || journal_lines=30
[[ "${top_n}" -gt 0 ]] || top_n=10
[[ "${top_n}" -le 50 ]] || top_n=50
[[ "${journal_lines}" -gt 0 ]] || journal_lines=30
[[ "${journal_lines}" -le 100 ]] || journal_lines=100

run_text() {
    "$@" 2>&1 || true
}

network_interfaces=""
routes=""
open_ports=""
recent_warnings=""

if command -v ip >/dev/null 2>&1; then
    network_interfaces="$(run_text ip -brief address)"
    routes="$(run_text ip route)"
fi

if command -v ss >/dev/null 2>&1; then
    open_ports="$(run_text ss -H -tuln | head -n "${top_n}" || true)"
elif command -v netstat >/dev/null 2>&1; then
    open_ports="$(run_text netstat -tuln | head -n $((top_n + 2)) || true)"
fi

if command -v journalctl >/dev/null 2>&1; then
    recent_warnings="$(run_text journalctl -p warning -n "${journal_lines}" --no-pager)"
fi

jq -cn \
    --arg tool "system.os.snapshot" \
    --arg hostname "$(run_text hostname)" \
    --arg kernel "$(run_text uname -a)" \
    --arg uptime "$(run_text uptime)" \
    --arg memory "$(run_text free -h)" \
    --arg disks "$(run_text df -hT)" \
    --arg mounts "$(linux_agent_sanitize_text "$(run_text findmnt -rno TARGET,SOURCE,FSTYPE,OPTIONS | head -n 80)" 5000)" \
    --arg network_interfaces "$(linux_agent_sanitize_text "${network_interfaces}" 2500)" \
    --arg routes "$(linux_agent_sanitize_text "${routes}" 2500)" \
    --arg open_ports "$(linux_agent_sanitize_text "${open_ports}" 2500)" \
    --arg failed_units "$(linux_agent_sanitize_text "$(run_text systemctl --failed --no-pager)" 2500)" \
    --arg recent_warnings "$(linux_agent_sanitize_text "${recent_warnings}" 4000)" \
    --arg top_processes "$(linux_agent_sanitize_text "$(run_text ps -eo pid,ppid,user,%cpu,%mem,stat,etime,comm --sort=-%cpu | head -n $((top_n + 1)))" 3000)" \
    --argjson top_n "${top_n}" \
    --argjson journal_lines "${journal_lines}" \
    '{ok:true, tool:$tool, top_n:$top_n, journal_lines:$journal_lines, hostname:$hostname, kernel:$kernel, uptime:$uptime, memory:$memory, disks:$disks, mounts:$mounts, network_interfaces:$network_interfaces, routes:$routes, open_ports:$open_ports, failed_units:$failed_units, recent_warnings:$recent_warnings, top_processes:$top_processes}'
