#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=helpers.sh
source "${ROOT_DIR}/tests/helpers.sh"

tmp_root="$(mktemp -d)"
server_pid=""
cleanup() {
    stop_fake_ai_server
    if [[ -n "${server_pid}" ]] && kill -0 "${server_pid}" >/dev/null 2>&1; then
        kill "${server_pid}" >/dev/null 2>&1 || true
        wait "${server_pid}" 2>/dev/null || true
    fi
    rm -rf "${tmp_root}"
}
trap cleanup EXIT
start_fake_ai_server "$((24000 + RANDOM % 1000))" "${tmp_root}"

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
configure_fake_ai "${project}"
port="$((19000 + RANDOM % 1000))"
token="test-web-token-12345"
tmp_config="$(mktemp)"
jq --arg token "${token}" --argjson port "${port}" \
    '.web = {enabled:true, host:"127.0.0.1", port:$port, token:$token, job_retention_hours:1}
    | .api_key = "test-web-initial-config-key"
    | del(.api_key_file)
    | .agent_loop.auto_execute_low_risk = false
    | .agent_loop.auto_execute_shell_low_risk = true' \
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
grep -q 'id="policyValidateBtn"' <<<"${index_html}"
grep -q 'id="auditRestoreTimelineBtn"' <<<"${index_html}"
grep -q 'id="sessionLeaveBtn"' <<<"${index_html}"
grep -q 'id="observerAuditDialog"' <<<"${index_html}"
grep -q 'on("workInput", "keydown"' "${project}/web/static/app.js"
grep -q 'event.shiftKey' "${project}/web/static/app.js"
grep -q 'userOutputBlocks(blocks)' "${project}/web/static/app.js"
grep -q 'state.terminalSubmitting' "${project}/web/static/app.js"
grep -q 'session-turn' "${project}/web/static/app.js"
grep -q 'renderSharedExecutionOutput' "${project}/web/static/app.js"
grep -q 'work-plan-preview' "${project}/web/static/app.js"

unauth_body="${tmp_root}/unauth.json"
unauth_code="$(curl --noproxy '*' -sS -o "${unauth_body}" -w '%{http_code}' "${base_url}/api/health" || true)"
[[ "${unauth_code}" == "401" ]]
grep -q 'unauthorized' "${unauth_body}"

health="$(curl --noproxy '*' -sS -H "Authorization: Bearer ${token}" "${base_url}/api/health")"
jq -e '.ok == true and .root != "" and .web_server.run_id != "" and .web_server.started_at != ""' <<<"${health}" >/dev/null

observer_bootstrap="$(curl --noproxy '*' -sS -H "Authorization: Bearer ${token}" "${base_url}/api/observer/bootstrap")"
jq -e '.ok == true and (.status | IN("pending","disabled","enabled","skipped","failed","unavailable")) and .requires_permission == true' <<<"${observer_bootstrap}" >/dev/null
observer_skip="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d '{"action":"skip"}' \
    "${base_url}/api/observer/bootstrap")"
jq -e '.ok == true and .status == "skipped" and .logged == true' <<<"${observer_skip}" >/dev/null
grep -R -q '"stage":"observer_bootstrap_skipped"' "${project}/logs"
if grep -R -q 'password\|test-web-token-12345' "${project}/logs"; then
    printf 'observer bootstrap log leaked sensitive auth material\n' >&2
    exit 1
fi
observer_enable_without_password="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d '{"action":"enable","password":""}' \
    "${base_url}/api/observer/bootstrap")"
jq -e 'if .ok then .status == "enabled" else (.status | IN("sudo_required","auditctl_not_found","ausearch_not_found","auditctl_failed","auditctl_permission_denied","auditctl_timeout","observer_disabled","sudo_not_found","sudo_timeout","sudo_denied")) end' <<<"${observer_enable_without_password}" >/dev/null

config_state="$(curl --noproxy '*' -sS -H "Authorization: Bearer ${token}" "${base_url}/api/config")"
jq -e '.ok == true and (.config.agent_loop.thinking_trace_enabled | type == "boolean") and .config.api_key_configured == true and .config.api_key_source == "config" and .config.api_key_configured_in_config == true and .config.web.token_configured == true and (.config | has("api_key") | not) and (.config | has("api_key_file") | not) and (.config | has("api_key_file_configured") | not) and (.config | has("api_key_migration_recommended") | not)
    and (.config.agent_loop | has("auto_execute_low_risk") | not)
    and (.config.agent_loop | has("auto_execute_shell_low_risk") | not)
    and .config.approvals.auto.skill_readonly == true
    and .config.approvals.auto.shell_readonly == false
    and .config.approvals.auto.file_patch == false' <<<"${config_state}" >/dev/null

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
jq -e '.ok == true and .status == "updated" and .updated.api_key == "configured" and .config.api_key_configured == true and .config.api_key_source == "config" and .config.api_key_configured_in_config == true and (.config | has("api_key") | not)' <<<"${api_key_update}" >/dev/null
if grep -q "${api_key_value}" <<<"${api_key_update}"; then
    printf 'api_key update response leaked the secret value\n' >&2
    exit 1
fi
jq -e --arg api_key_value "${api_key_value}" '.api_key == $api_key_value' "${project}/config/config.json" >/dev/null

audit_limit_payload="$(jq -cn '{key:"audit_text_limit", value:1234}')"
audit_limit_update="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${audit_limit_payload}" \
    "${base_url}/api/config/update")"
jq -e '.ok == true and .status == "updated" and .updated.audit_text_limit == 1234 and .config.audit_text_limit == 1234' <<<"${audit_limit_update}" >/dev/null

approval_update_payload="$(jq -cn '{key:"approvals.auto.file_patch", value:true}')"
approval_update="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${approval_update_payload}" \
    "${base_url}/api/config/update")"
jq -e '.ok == true and .status == "updated" and .updated["approvals.auto.file_patch"] == true and .config.approvals.auto.file_patch == true' <<<"${approval_update}" >/dev/null

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
policy_validate="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${policy_write_payload}" \
    "${base_url}/api/policies/validate")"
jq -e '.ok == true and .status == "valid" and .validation.ok == true' <<<"${policy_validate}" >/dev/null

invalid_policy_payload="$(jq -cn '{path:"redaction-rules.json", content:"{\"rules\":[{\"id\":\"bad\",\"pattern\":\".*\",\"replacement\":\"x\"}],\"sensitive_key_pattern\":\"(?i)token\"}"}')"
invalid_policy_validate="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${invalid_policy_payload}" \
    "${base_url}/api/policies/validate")"
jq -e '.ok == false and .validation.ok == false and ([.validation.findings[]?.code] | index("POLICY_REGEX_ZERO_WIDTH"))' <<<"${invalid_policy_validate}" >/dev/null

policy_write="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${policy_write_payload}" \
    "${base_url}/api/policies/write")"
jq -e 'if .ok then .status == "saved" and (.method == "root" or .method == "sudo") else .status == "sudo_required" end' <<<"${policy_write}" >/dev/null

work_payload="$(jq -cn '{resource:"work", action:"run", payload:{input:"查看cpu占用"}}')"
work_job_one="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${work_payload}" \
    "${base_url}/api/jobs")"
work_job_one_id="$(jq -r '.job_id' <<<"${work_job_one}")"
[[ "${work_job_one_id}" =~ ^[0-9a-f]+$ ]]
work_result_one=""
for _ in $(seq 1 100); do
    work_result_one="$(curl --noproxy '*' -sS -H "Authorization: Bearer ${token}" "${base_url}/api/jobs/${work_job_one_id}")"
    work_status_one="$(jq -r '.status' <<<"${work_result_one}")"
    if [[ "${work_status_one}" != "queued" && "${work_status_one}" != "running" ]]; then
        break
    fi
    sleep 0.2
done
[[ "${work_status_one}" == "succeeded" ]]
jq -e '.result_status == "executed" and .result_ok == true
    and ([.result.timeline[]? | select(.kind == "execution") | .output_blocks[]? | select(.kind == "json") | .json | select(.tool == "system.resource.inspect")] | length) > 0
    and ([.result.output_blocks[]? | select(.title == "执行流程") | .text | contains("# 工作计划") and contains("步骤输出")] | any)' <<<"${work_result_one}" >/dev/null

work_job_two="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${work_payload}" \
    "${base_url}/api/jobs")"
work_job_two_id="$(jq -r '.job_id' <<<"${work_job_two}")"
[[ "${work_job_two_id}" =~ ^[0-9a-f]+$ ]]
work_result_two=""
for _ in $(seq 1 100); do
    work_result_two="$(curl --noproxy '*' -sS -H "Authorization: Bearer ${token}" "${base_url}/api/jobs/${work_job_two_id}")"
    work_status_two="$(jq -r '.status' <<<"${work_result_two}")"
    if [[ "${work_status_two}" != "queued" && "${work_status_two}" != "running" ]]; then
        break
    fi
    sleep 0.2
done
[[ "${work_status_two}" == "succeeded" ]]

audit_after_work="$(curl --noproxy '*' -sS -H "Authorization: Bearer ${token}" "${base_url}/api/audit/list")"
jq -e '.ok == true and ([.sessions[]? | select(.entrypoint == "web")] | length) == 1' <<<"${audit_after_work}" >/dev/null
web_work_session_id="$(jq -r '.sessions[]? | select(.entrypoint == "web") | .session_id' <<<"${audit_after_work}")"
[[ -n "${web_work_session_id}" ]]
web_work_audit_payload="$(jq -cn --arg session_id "${web_work_session_id}" '{session_id:$session_id}')"
web_work_audit="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${web_work_audit_payload}" \
    "${base_url}/api/audit/read")"
jq -e '[.events[]? | select(.stage == "request_context_built") | .payload.conversation_turns] as $turns
    | ($turns | length) >= 2 and $turns[0] == 0 and $turns[1] == 1' <<<"${web_work_audit}" >/dev/null
jq -e '.ok == true
    and .web_timeline.source == "audit"
    and (.web_timeline.turns | length) >= 2
    and all(.web_timeline.turns[]; (.result.timeline | type) == "array")' <<<"${web_work_audit}" >/dev/null

restore_result="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${web_work_audit_payload}" \
    "${base_url}/api/session/restore")"
restored_session_id="$(jq -r '.session.session_id // empty' <<<"${restore_result}")"
jq -e --arg session_id "${web_work_session_id}" '.ok == true
    and .status == "restored"
    and .session.restored_from == $session_id
    and (.session.session_id | startswith("session_web_"))
    and .history_count >= 2
    and .session.history_count == .history_count' <<<"${restore_result}" >/dev/null
[[ -n "${restored_session_id}" ]]

session_state="$(curl --noproxy '*' -sS -H "Authorization: Bearer ${token}" "${base_url}/api/session/state")"
jq -e --arg session_id "${web_work_session_id}" --arg restored_session_id "${restored_session_id}" '.ok == true
    and .session_id == $restored_session_id
    and .restored_from == $session_id
    and .history_count >= 2
    and .context_window_count > 0' <<<"${session_state}" >/dev/null

leave_result="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d '{}' \
    "${base_url}/api/session/leave")"
left_session_id="$(jq -r '.session.session_id // empty' <<<"${leave_result}")"
jq -e --arg session_id "${web_work_session_id}" --arg restored_session_id "${restored_session_id}" '.ok == true
    and .status == "left_restored"
    and .left_restored_from == $session_id
    and .session.restored_from == ""
    and .session.history_count == 0
    and .session.context_window_count == 0
    and .session.session_id != $restored_session_id
    and (.session.session_id | startswith("session_web_"))' <<<"${leave_result}" >/dev/null
[[ -n "${left_session_id}" ]]

work_job_after_leave="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${work_payload}" \
    "${base_url}/api/jobs")"
work_job_after_leave_id="$(jq -r '.job_id' <<<"${work_job_after_leave}")"
[[ "${work_job_after_leave_id}" =~ ^[0-9a-f]+$ ]]
work_result_after_leave=""
for _ in $(seq 1 100); do
    work_result_after_leave="$(curl --noproxy '*' -sS -H "Authorization: Bearer ${token}" "${base_url}/api/jobs/${work_job_after_leave_id}")"
    work_status_after_leave="$(jq -r '.status' <<<"${work_result_after_leave}")"
    if [[ "${work_status_after_leave}" != "queued" && "${work_status_after_leave}" != "running" ]]; then
        break
    fi
    sleep 0.2
done
[[ "${work_status_after_leave}" == "succeeded" ]]

left_work_audit_payload="$(jq -cn --arg session_id "${left_session_id}" '{session_id:$session_id}')"
left_work_audit="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${left_work_audit_payload}" \
    "${base_url}/api/audit/read")"
jq -e '[.events[]? | select(.stage == "request_context_built") | .payload.conversation_turns] as $turns
    | ($turns | length) >= 1 and $turns[0] == 0' <<<"${left_work_audit}" >/dev/null

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

audit_after_job="$(curl --noproxy '*' -sS -H "Authorization: Bearer ${token}" "${base_url}/api/audit/list")"
jq -e '.ok == true
    and .sessions[0].entrypoint == "web"
    and (.sessions[0].modes | index("terminal"))
    and (.sessions[0].event_count >= 1)
    and (.sessions[0].event_summary | length > 0)
    and (.sessions[0].headline | contains("Web"))
    and ([.sessions[]?.session_id | startswith("web_")] | any | not)' <<<"${audit_after_job}" >/dev/null
job_session_id="$(jq -r '.sessions[0].session_id // empty' <<<"${audit_after_job}")"
[[ -n "${job_session_id}" ]]
audit_read_payload="$(jq -cn --arg session_id "${job_session_id}" '{session_id:$session_id}')"
audit_read="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${audit_read_payload}" \
    "${base_url}/api/audit/read")"
jq -e '.ok == true and .web_timeline.source == "audit" and (.web_timeline.timeline | length) >= 1 and ([.web_timeline.timeline[]?.kind] | index("execution"))' <<<"${audit_read}" >/dev/null

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
