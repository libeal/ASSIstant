#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
# shellcheck source=../../../lib/common.sh
source "${ROOT_DIR}/lib/common.sh"

arguments_json="${1:-}"
if ! arguments_json="$(linux_agent_normalize_json_object_argument "${arguments_json}")"; then
    jq -cn '{ok:false, tool:"system.net.inspect", error:"arguments must be a JSON object"}'
    exit 0
fi

port="$(jq -r '.port // ""' <<<"${arguments_json}")"
protocol="$(jq -r '.protocol // "all"' <<<"${arguments_json}")"
state="$(jq -r '.state // ""' <<<"${arguments_json}")"
limit="$(jq -r '.limit // 80' <<<"${arguments_json}")"
include_process="$(jq -r '.include_process // false' <<<"${arguments_json}")"

[[ "${limit}" =~ ^[0-9]+$ ]] || limit=80
[[ "${limit}" -gt 0 ]] || limit=80
[[ "${limit}" -le 300 ]] || limit=300
[[ "${include_process}" == "true" ]] || include_process="false"

if [[ -n "${port}" && ! "${port}" =~ ^[0-9]{1,5}$ ]]; then
    jq -cn --arg port "${port}" '{ok:false, tool:"system.net.inspect", port:$port, error:"port must be a number"}'
    exit 0
fi
if [[ -n "${port}" && ( "${port}" -lt 1 || "${port}" -gt 65535 ) ]]; then
    jq -cn --arg port "${port}" '{ok:false, tool:"system.net.inspect", port:$port, error:"port must be between 1 and 65535"}'
    exit 0
fi
case "${protocol}" in
    all|tcp|udp) ;;
    *)
        jq -cn --arg protocol "${protocol}" '{ok:false, tool:"system.net.inspect", protocol:$protocol, error:"protocol must be all, tcp, or udp"}'
        exit 0
        ;;
esac

run_text() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 8s "$@" 2>&1 || true
    else
        "$@" 2>&1 || true
    fi
}

filter_output() {
    local text="$1"
    local filtered="${text}"
    if [[ -n "${port}" ]]; then
        filtered="$(printf '%s\n' "${filtered}" | grep -E "[:.]${port}([[:space:]]|$)" || true)"
    fi
    if [[ -n "${state}" ]]; then
        filtered="$(printf '%s\n' "${filtered}" | grep -i -- "${state}" || true)"
    fi
    printf '%s\n' "${filtered}" | head -n "${limit}"
}

tool_used=""
listeners=""
connections=""

if command -v ss >/dev/null 2>&1; then
    tool_used="ss"
    ss_listen_args=(-H)
    ss_conn_args=(-H)
    case "${protocol}" in
        tcp)
            ss_listen_args+=(-tln)
            ss_conn_args+=(-tan)
            ;;
        udp)
            ss_listen_args+=(-uln)
            ss_conn_args+=(-uan)
            ;;
        all)
            ss_listen_args+=(-tuln)
            ss_conn_args+=(-tun)
            ;;
    esac
    if [[ "${include_process}" == "true" ]]; then
        ss_listen_args+=(-p)
        ss_conn_args+=(-p)
    fi
    listeners="$(filter_output "$(run_text ss "${ss_listen_args[@]}")")"
    connections="$(filter_output "$(run_text ss "${ss_conn_args[@]}")")"
elif command -v netstat >/dev/null 2>&1; then
    tool_used="netstat"
    netstat_args=(-n)
    case "${protocol}" in
        tcp) netstat_args+=(-t) ;;
        udp) netstat_args+=(-u) ;;
        all) netstat_args+=(-t -u) ;;
    esac
    if [[ "${include_process}" == "true" ]]; then
        netstat_args+=(-p)
    fi
    listeners="$(filter_output "$(run_text netstat "${netstat_args[@]}" -l)")"
    connections="$(filter_output "$(run_text netstat "${netstat_args[@]}" -a)")"
else
    jq -cn '{ok:false, tool:"system.net.inspect", error:"neither ss nor netstat is available"}'
    exit 0
fi

jq -cn \
    --arg tool "system.net.inspect" \
    --arg tool_used "${tool_used}" \
    --arg port "${port}" \
    --arg protocol "${protocol}" \
    --arg state "${state}" \
    --arg listeners "$(linux_agent_sanitize_text "${listeners}" 5000)" \
    --arg connections "$(linux_agent_sanitize_text "${connections}" 5000)" \
    --argjson limit "${limit}" \
    --argjson include_process "${include_process}" \
    '{ok:true, tool:$tool, command_family:$tool_used, port:$port, protocol:$protocol, state:$state, include_process:$include_process, limit:$limit, listeners:$listeners, connections:$connections}'
