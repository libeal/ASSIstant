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
printf 'test-web-initial-key\n' > "${project}/config/test-api-key.secret"
tmp_config="$(mktemp)"
jq --arg token "${token}" --argjson port "${port}" \
    '.web = {enabled:true, host:"127.0.0.1", port:$port, token:$token, job_retention_hours:1}
    | .api_key_file = "config/test-api-key.secret"
    | del(.api_key)' \
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
grep -q '结束进程' <<<"${index_html}"
grep -q 'id="senseTopicSelect"' <<<"${index_html}"
grep -q 'id="skillsValidateBtn"' <<<"${index_html}"

unauth_body="${tmp_root}/unauth.json"
unauth_code="$(curl --noproxy '*' -sS -o "${unauth_body}" -w '%{http_code}' "${base_url}/api/health" || true)"
[[ "${unauth_code}" == "401" ]]
grep -q 'unauthorized' "${unauth_body}"

health="$(curl --noproxy '*' -sS -H "Authorization: Bearer ${token}" "${base_url}/api/health")"
jq -e '.ok == true and .root != "" and .web_server.run_id != "" and .web_server.started_at != ""' <<<"${health}" >/dev/null

config_state="$(curl --noproxy '*' -sS -H "Authorization: Bearer ${token}" "${base_url}/api/config")"
jq -e '.ok == true and (.config.agent_loop.thinking_trace_enabled | type == "boolean") and .config.api_key_configured == true and .config.api_key_source == "file" and .config.web.token_configured == true and (.config | has("api_key") | not)' <<<"${config_state}" >/dev/null

config_update_payload="$(jq -cn '{key:"agent_loop.thinking_trace_enabled", value:true}')"
config_update="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${config_update_payload}" \
    "${base_url}/api/config/update")"
jq -e '.ok == true and .status == "updated" and .config.agent_loop.thinking_trace_enabled == true' <<<"${config_update}" >/dev/null

api_key_value="test-web-updated-key-12345"
api_key_payload="$(jq -cn --arg value "${api_key_value}" '{key:"api_key", value:$value}')"
api_key_update="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${api_key_payload}" \
    "${base_url}/api/config/update")"
jq -e '.ok == true and .status == "updated" and .updated.api_key == "configured" and .config.api_key_configured == true and .config.api_key_source == "file" and (.config | has("api_key") | not)' <<<"${api_key_update}" >/dev/null
if grep -q "${api_key_value}" <<<"${api_key_update}"; then
    printf 'api_key update response leaked the secret value\n' >&2
    exit 1
fi
jq -e '(.api_key_file | type == "string") and (.api_key | not)' "${project}/config/config.json" >/dev/null
secret_path="$(jq -r '.api_key_file' "${project}/config/config.json")"
grep -qx "${api_key_value}" "${project}/${secret_path}"

audit_limit_payload="$(jq -cn '{key:"audit_text_limit", value:1234}')"
audit_limit_update="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${audit_limit_payload}" \
    "${base_url}/api/config/update")"
jq -e '.ok == true and .status == "updated" and .updated.audit_text_limit == 1234 and .config.audit_text_limit == 1234' <<<"${audit_limit_update}" >/dev/null

skill_tree="$(curl --noproxy '*' -sS -H "Authorization: Bearer ${token}" "${base_url}/api/skills/tree")"
jq -e '.ok == true and (.markdown_files | index("INDEX.md")) and (.script_files | index("ops-basic/scripts/resource-inspect.sh"))' <<<"${skill_tree}" >/dev/null

skills_validate="$(curl --noproxy '*' -sS -H "Authorization: Bearer ${token}" "${base_url}/api/skills/validate")"
jq -e '.ok == true and .status == "validated" and .validation.ok == true' <<<"${skills_validate}" >/dev/null

skill_read_payload="$(jq -cn '{path:"ops-basic/scripts/resource-inspect.sh"}')"
skill_read="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${skill_read_payload}" \
    "${base_url}/api/skills/read")"
jq -e '.ok == true and .kind == "script" and (.content | contains("system.resource.inspect"))' <<<"${skill_read}" >/dev/null

conflict_err="${tmp_root}/conflict.err"
conflict_out="${tmp_root}/conflict.out"
if (cd "${project}" && bash bin/agent-web >"${conflict_out}" 2>"${conflict_err}"); then
    printf 'expected second agent-web on same port to fail\n' >&2
    exit 1
fi
grep -q '端口已被占用' "${conflict_err}"

doctor="$(curl --noproxy '*' -sS -H "Authorization: Bearer ${token}" "${base_url}/api/doctor")"
jq -e '.status == "checked"' <<<"${doctor}" >/dev/null

sense_payload="$(jq -cn '{topic:"resource"}')"
sense_resource="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${sense_payload}" \
    "${base_url}/api/sense")"
jq -e '.ok == true and .topic == "resource" and .sense.topic == "resource"' <<<"${sense_resource}" >/dev/null

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
jq -e '.result_status == "executed" and .result_ok == true
    and ([.result.output_blocks[]? | select(.kind == "stdout") | .text] | first) == "web-job-ok"
    and ([.result.output_blocks[]? | select(.kind == "meta" and .title == "Agent runtime") | .json.exit_code] | first) == 0' <<<"${job_result}" >/dev/null

cancel_payload="$(jq -cn '{resource:"terminal", action:"run", payload:{command:"sleep 5"}}')"
cancel_job="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${cancel_payload}" \
    "${base_url}/api/jobs")"
cancel_job_id="$(jq -r '.job_id' <<<"${cancel_job}")"
[[ "${cancel_job_id}" =~ ^[0-9a-f]+$ ]]
sleep 0.3
cancel_result="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d '{}' \
    "${base_url}/api/jobs/${cancel_job_id}/cancel")"
jq -e '.ok == true and .status == "cancelled"' <<<"${cancel_result}" >/dev/null

shutdown_result="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d '{}' \
    "${base_url}/api/server/shutdown")"
jq -e '.ok == true and .status == "shutting_down"' <<<"${shutdown_result}" >/dev/null
timeout 5 tail --pid="${server_pid}" -f /dev/null >/dev/null 2>&1 || {
    printf 'agent-web did not stop after shutdown request\n' >&2
    exit 1
}
wait "${server_pid}" 2>/dev/null || true
server_pid=""

printf 'web_server: ok\n'
