#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tmp_root="$(mktemp -d)"
server_pid=""
cleanup() {
    if [[ -n "${server_pid}" ]] && kill -0 "${server_pid}" >/dev/null 2>&1; then
        kill "${server_pid}" >/dev/null 2>&1 || true
        wait "${server_pid}" 2>/dev/null || true
    fi
    rm -rf "${tmp_root}"
}
trap cleanup EXIT

copy_project() {
    local target="$1"
    mkdir -p "${target}"
    cp -a \
        "${ROOT_DIR}/bin" \
        "${ROOT_DIR}/config" \
        "${ROOT_DIR}/lib" \
        "${ROOT_DIR}/policies" \
        "${ROOT_DIR}/prompts" \
        "${ROOT_DIR}/skills" \
        "${ROOT_DIR}/web" \
        "${target}/"
}

project="${tmp_root}/project-web"
copy_project "${project}"
port="$((19000 + RANDOM % 1000))"
token="test-web-token-12345"
tmp_config="$(mktemp)"
jq --arg token "${token}" --argjson port "${port}" \
    '.web = {enabled:true, host:"127.0.0.1", port:$port, token:$token, job_retention_hours:1}' \
    "${project}/config/config.json" > "${tmp_config}"
mv "${tmp_config}" "${project}/config/config.json"

(cd "${project}" && bash bin/agent-web >"${tmp_root}/server.out" 2>"${tmp_root}/server.err") &
server_pid="$!"

base_url="http://127.0.0.1:${port}"
for _ in $(seq 1 60); do
    if curl --noproxy '*' -sS -H "Authorization: Bearer ${token}" "${base_url}/api/health" >/dev/null 2>&1; then
        break
    fi
    sleep 0.2
done

index_html="$(curl --noproxy '*' -sS "${base_url}/")"
grep -q 'ASSIstant 前端外壳' <<<"${index_html}"

unauth_body="${tmp_root}/unauth.json"
unauth_code="$(curl --noproxy '*' -sS -o "${unauth_body}" -w '%{http_code}' "${base_url}/api/health" || true)"
[[ "${unauth_code}" == "401" ]]
grep -q 'unauthorized' "${unauth_body}"

health="$(curl --noproxy '*' -sS -H "Authorization: Bearer ${token}" "${base_url}/api/health")"
jq -e '.ok == true and .root != ""' <<<"${health}" >/dev/null

conflict_err="${tmp_root}/conflict.err"
conflict_out="${tmp_root}/conflict.out"
if (cd "${project}" && bash bin/agent-web >"${conflict_out}" 2>"${conflict_err}"); then
    printf 'expected second agent-web on same port to fail\n' >&2
    exit 1
fi
grep -q '端口已被占用' "${conflict_err}"

doctor="$(curl --noproxy '*' -sS -H "Authorization: Bearer ${token}" "${base_url}/api/doctor")"
jq -e '.status == "checked"' <<<"${doctor}" >/dev/null

policies="$(curl --noproxy '*' -sS -H "Authorization: Bearer ${token}" "${base_url}/api/policies")"
jq -e '.ok == true and .requires_sudo_to_edit == true and any(.files[]?.path; . == "audit-boundaries.json")' <<<"${policies}" >/dev/null

boundary_payload="$(jq -cn '{path:"audit-boundaries.json"}')"
boundary="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${boundary_payload}" \
    "${base_url}/api/policies/read")"
jq -e '.ok == true and .json.observing.audit_payload_mode == "safe_summary" and (.json.allowed_to_observe.observer_syscalls | index("openat"))' <<<"${boundary}" >/dev/null

policy_write_payload="$(jq -cn --rawfile content "${project}/policies/audit-boundaries.json" '{path:"audit-boundaries.json", content:$content, password:""}')"
policy_write="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${policy_write_payload}" \
    "${base_url}/api/policies/write")"
jq -e 'if .ok then .status == "saved" and (.method == "root" or .method == "sudo") else .status == "sudo_required" end' <<<"${policy_write}" >/dev/null

job_payload="$(jq -cn '{resource:"terminal", action:"run", payload:{command:"printf web-job-ok"}}')"
job="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${job_payload}" \
    "${base_url}/api/jobs")"
job_id="$(jq -r '.job_id' <<<"${job}")"
[[ "${job_id}" =~ ^[0-9a-f]+$ ]]

job_status=""
job_result=""
for _ in $(seq 1 80); do
    job_result="$(curl --noproxy '*' -sS -H "Authorization: Bearer ${token}" "${base_url}/api/jobs/${job_id}")"
    job_status="$(jq -r '.status' <<<"${job_result}")"
    if [[ "${job_status}" != "queued" && "${job_status}" != "running" ]]; then
        break
    fi
    sleep 0.2
done

[[ "${job_status}" == "succeeded" ]]
jq -e '.result.result.stdout_preview == "web-job-ok"' <<<"${job_result}" >/dev/null

printf 'web_server: ok\n'
