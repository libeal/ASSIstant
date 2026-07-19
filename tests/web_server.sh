#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=helpers.sh
source "${ROOT_DIR}/tests/helpers.sh"

# The integration test is headless; keep the desktop convenience launcher out
# of the service lifecycle while still exercising the normal server path.
export LINUX_AGENT_WEB_AUTO_OPEN=0

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
    local tmp_manifest
    mkdir -p "${target}"
    cp -a \
        "${ROOT_DIR}/bin" \
        "${ROOT_DIR}/config" \
        "${ROOT_DIR}/lib" \
        "${ROOT_DIR}/policies" \
        "${ROOT_DIR}/prompts" \
        "${ROOT_DIR}/skills" \
        "${ROOT_DIR}/mcp" \
        "${ROOT_DIR}/schema" \
        "${ROOT_DIR}/web" \
        "${target}/"
    if [[ -f "${target}/mcp/context7/mcp.json" ]]; then
        tmp_manifest="$(mktemp)"
        jq '.enabled = false' "${target}/mcp/context7/mcp.json" >"${tmp_manifest}"
        mv "${tmp_manifest}" "${target}/mcp/context7/mcp.json"
    fi
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
    | del(.observer.privilege)
    | .agent_loop.auto_execute_low_risk = false
    | .agent_loop.auto_execute_shell_low_risk = true' \
    "${project}/config/config.json" >"${tmp_config}"
mv "${tmp_config}" "${project}/config/config.json"

# Removed audit.integrity_chain must fail at the Web entrypoint, before the
# server starts and before a later CLI API subprocess encounters the setting.
removed_chain_out="${tmp_root}/removed-chain.out"
removed_chain_err="${tmp_root}/removed-chain.err"
tmp_config="$(mktemp)"
jq '.audit.integrity_chain = false' "${project}/config/config.json" >"${tmp_config}"
mv "${tmp_config}" "${project}/config/config.json"
set +e
(cd "${project}" && timeout 5 bash bin/agent-web >"${removed_chain_out}" 2>"${removed_chain_err}")
removed_chain_rc=$?
set -e
[[ "${removed_chain_rc}" -eq 1 ]]
grep -q 'audit.integrity_chain 已移除' "${removed_chain_err}"
tmp_config="$(mktemp)"
jq 'del(.audit.integrity_chain)' "${project}/config/config.json" >"${tmp_config}"
mv "${tmp_config}" "${project}/config/config.json"

report_failure() {
    local status=$?
    local line="${1:-unknown}"
    trap - ERR
    printf 'web_server: failed at line %s (exit=%s)\n' "${line}" "${status}" >&2
    return "${status}"
}
trap 'report_failure "${LINENO}"' ERR

mkdir -p "${project}/mcp/stdio-web" "${project}/mcp/http-web" "${project}/mcp/sse-web"
cat >"${project}/mcp/stdio-web/mcp.json" <<JSON
{
  "id": "stdio-web",
  "name": "Web stdio server",
  "description": "Stdio transport fixture",
  "transport": "stdio",
  "command": "python3",
  "args": ["${ROOT_DIR}/tests/fake_mcp_server.py", "stdio"],
  "env": {"WEB_TOKEN": "web-secret-value"}
}
JSON
cat >"${project}/mcp/http-web/mcp.json" <<'JSON'
{
  "id": "http-web",
  "name": "Web streamable server",
  "enabled": false,
  "transport": "streamable_http",
  "url": "https://example.com/mcp",
  "headers": {"Authorization": "Bearer web-secret-value"}
}
JSON
cat >"${project}/mcp/sse-web/mcp.json" <<'JSON'
{
  "id": "sse-web",
  "name": "Web SSE server",
  "enabled": false,
  "transport": "sse",
  "url": "https://example.com/sse",
  "message_url": "https://example.com/messages"
}
JSON

# Real pre-SQLite file-per-Job record. Startup must import it transactionally,
# archive the source, and run the normal interrupted-active recovery path.
legacy_job_id="facefeed01"
mkdir -p "${project}/tmp/web/jobs"
jq -cn --arg job_id "${legacy_job_id}" '{
    ok:true,
    job_id:$job_id,
    resource:"terminal",
    action:"run",
    status:"running",
    version:3,
    created_at:"2026-07-15T00:00:00Z",
    updated_at:"2026-07-15T00:01:00Z",
    result:null,
    result_ok:null,
    result_status:null
}' >"${project}/tmp/web/jobs/${legacy_job_id}.json"

(cd "${project}" && bash bin/agent-web >"${tmp_root}/server.out" 2>"${tmp_root}/server.err") &
server_pid="$!"

base_url="http://127.0.0.1:${port}"
for _ in $(seq 1 60); do
    if curl --noproxy '*' -sS -H "Authorization: Bearer ${token}" "${base_url}/api/health" >/dev/null 2>&1; then
        break
    fi
    sleep 0.2
done

# Successful-looking CLI responses that violate the domain contract must stop
# at the Web boundary instead of reaching the browser as usable data.
mv "${project}/bin/agent" "${project}/bin/agent.real"
cat >"${project}/bin/agent" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${1:-}" == "api" && "${2:-}" == "doctor" && "${3:-}" == "run" ]]; then
    printf '%s\n' '{"ok":true,"status":"not_in_domain_schema","schema_version":1,"protocol_version":"1.0.0","doctor":{}}'
    exit 0
fi
if [[ "${1:-}" == "api" && "${2:-}" == "terminal" && "${3:-}" == "run" ]]; then
    printf '%s\n' '{"ok":true,"status":"executed","schema_version":1,"protocol_version":"1.0.0"}'
    exit 0
fi
exec bash "${script_dir}/agent.real" "$@"
SH
chmod 0755 "${project}/bin/agent"

invalid_doctor_code="$(curl --noproxy '*' -sS \
    -o "${tmp_root}/invalid-doctor-output.json" -w '%{http_code}' \
    -H "Authorization: Bearer ${token}" "${base_url}/api/doctor")"
[[ "${invalid_doctor_code}" == "502" ]]
jq -e '.ok == false and .status == "invalid_agent_output" and .code == "invalid_agent_output"' \
    "${tmp_root}/invalid-doctor-output.json" >/dev/null

invalid_terminal_code="$(curl --noproxy '*' -sS \
    -o "${tmp_root}/invalid-terminal-output.json" -w '%{http_code}' \
    -H "Authorization: Bearer ${token}" -H 'Content-Type: application/json' \
    -d '{"command":"printf ok","approve":true}' "${base_url}/api/terminal/run")"
[[ "${invalid_terminal_code}" == "502" ]]
jq -e '.ok == false and .status == "invalid_agent_output" and .code == "invalid_agent_output"' \
    "${tmp_root}/invalid-terminal-output.json" >/dev/null

mv "${project}/bin/agent.real" "${project}/bin/agent"

legacy_job="$(curl --noproxy '*' -sS -H "Authorization: Bearer ${token}" "${base_url}/api/jobs/${legacy_job_id}")"
jq -e '
    .status == "failed"
    and .version == 4
    and .result.status == "server_restarted"
    and .request_id == "legacy-facefeed01"
    and .session_id == "legacy_job_facefeed01"
    and .payload == {}
    and .legacy_source_file == "facefeed01.json"
' <<<"${legacy_job}" >/dev/null
[[ ! -e "${project}/tmp/web/jobs/${legacy_job_id}.json" ]]
[[ -f "${project}/tmp/web/jobs/${legacy_job_id}.json.migrated" ]]

index_html="$(curl --noproxy '*' -sS "${base_url}/")"
grep -q 'ASSIstant 前端外壳' <<<"${index_html}"
grep -q '结束进程' <<<"${index_html}"
grep -q 'id="senseTopicSelect"' <<<"${index_html}"
grep -q 'id="skillsValidateBtn"' <<<"${index_html}"
grep -q 'id="runtimeBackupBtn"' <<<"${index_html}"
grep -q 'id="workRemoteTransmissionNotice"' <<<"${index_html}"
grep -q 'id="editRemoteTransmissionNotice"' <<<"${index_html}"
grep -q 'id="mcpValidateBtn"' <<<"${index_html}"
grep -q 'id="mcpToolsBtn"' <<<"${index_html}"
grep -q 'id="mcpToolCount"' <<<"${index_html}"
grep -q 'id="policyValidateBtn"' <<<"${index_html}"
grep -q 'id="auditRestoreTimelineBtn"' <<<"${index_html}"
grep -q 'id="sessionLeaveBtn"' <<<"${index_html}"
grep -q 'id="observerAuditDialog"' <<<"${index_html}"
grep -q 'aria-current="page"' <<<"${index_html}"
grep -q 'id="mainContent"' <<<"${index_html}"
grep -q '<h1 id="screenTitle"' <<<"${index_html}"
[[ "$(grep -o '<h1' <<<"${index_html}" | wc -l)" -eq 1 ]]
grep -q 'on("workInput", "keydown"' "${project}/web/static/modules/app-bindings.js"
grep -q 'event.shiftKey' "${project}/web/static/modules/app-bindings.js"
grep -q 'scrollActiveNavigationIntoView' "${project}/web/static/app.js"
grep -q 'overscroll-behavior-inline: contain' "${project}/web/static/styles.css"
grep -q 'grid-template-columns: 180px minmax(0, 1fr)' "${project}/web/static/styles.css"
grep -q '"Noto Sans CJK SC"' "${project}/web/static/styles.css"
grep -q 'flex: 0 0 44px' "${project}/web/static/styles.css"
grep -q 'env(safe-area-inset-bottom)' "${project}/web/static/styles.css"
grep -q '@media (prefers-reduced-motion: reduce)' "${project}/web/static/styles.css"
grep -q 'userOutputBlocks(blocks)' "${project}/web/static/modules/render-output.js"
grep -q '低风险 Skill 自动运行' "${project}/web/static/modules/policy-config.js"
grep -q '低风险 Shell 自动运行' "${project}/web/static/modules/policy-config.js"
grep -q 'Work 自动续写' "${project}/web/static/modules/policy-config.js"
grep -q '文件匹配自动运行' "${project}/web/static/modules/policy-config.js"
grep -q '最小权限代理' "${project}/web/static/modules/policy-config.js"
grep -q '允许远程传输 API Key' "${project}/web/static/modules/policy-config.js"
grep -q 'materializeSkill' "${project}/web/static/modules/view-skills.js"
grep -q 'downloadRuntimeBackup' "${project}/web/static/modules/view-audit.js"
grep -q '开：' "${project}/web/static/modules/view-config.js"
grep -q '关：' "${project}/web/static/modules/view-config.js"
grep -q 'state.terminalSubmitting' "${project}/web/static/modules/view-workbench.js"
grep -q 'session-turn' "${project}/web/static/modules/view-workbench.js"
grep -q 'renderSharedExecutionOutput' "${project}/web/static/modules/render-output.js"
grep -q 'work-plan-preview' "${project}/web/static/modules/view-workbench.js"
grep -q 'prepareNewWorkRun' "${project}/web/static/modules/view-workbench.js"
grep -q 'execution_state' "${project}/web/static/modules/view-workbench.js"
grep -q 'data-config-model-fetch' "${project}/web/static/modules/app-bindings.js"
grep -q 'loadMcpRegistry' "${project}/web/static/app.js"
grep -q 'type: "provider"' "${project}/web/static/modules/policy-config.js"
grep -q 'type: "model"' "${project}/web/static/modules/policy-config.js"
grep -q 'agent_loop_iteration_started' "${project}/web/static/modules/audit.js"
grep -q 'Agent 循环迭代开始' "${project}/web/static/modules/audit.js"
node "${ROOT_DIR}/tests/web_markdown.mjs"
node "${ROOT_DIR}/tests/web_api_client.mjs"
node "${ROOT_DIR}/tests/web_timeline.mjs"
mcp_nav_line="$(grep -n 'data-screen="mcp"' "${project}/web/static/index.html" | cut -d: -f1)"
skills_nav_line="$(grep -n 'data-screen="skills"' "${project}/web/static/index.html" | cut -d: -f1)"
policy_nav_line="$(grep -n 'data-screen="policy"' "${project}/web/static/index.html" | cut -d: -f1)"
[[ "${skills_nav_line}" -lt "${mcp_nav_line}" && "${mcp_nav_line}" -lt "${policy_nav_line}" ]]

unauth_body="${tmp_root}/unauth.json"
unauth_code="$(curl --noproxy '*' -sS -o "${unauth_body}" -w '%{http_code}' "${base_url}/api/health" || true)"
[[ "${unauth_code}" == "401" ]]
grep -q 'unauthorized' "${unauth_body}"

legacy_header_body="${tmp_root}/legacy-header.json"
legacy_header_code="$(curl --noproxy '*' -sS -o "${legacy_header_body}" -w '%{http_code}' \
    -H "X-Agent-Token: ${token}" "${base_url}/api/health" || true)"
[[ "${legacy_header_code}" == "401" ]]
grep -q 'unauthorized' "${legacy_header_body}"

oversized_body="${tmp_root}/oversized-body.json"
python3 -c 'import sys; sys.stdout.write("{\"command\":\"" + "a"*1100000 + "\"}")' >"${oversized_body}"
oversized_code="$(curl --noproxy '*' -sS -o "${tmp_root}/oversized-resp.json" -w '%{http_code}' \
    -X POST -H "Authorization: Bearer ${token}" -H "Content-Type: application/json" \
    --data-binary "@${oversized_body}" "${base_url}/api/terminal/review" || true)"
[[ "${oversized_code}" == "413" ]]
jq -e '.status == "request_too_large"' "${tmp_root}/oversized-resp.json" >/dev/null

negative_length_code="$(curl --noproxy '*' -sS -o "${tmp_root}/negative-length.json" -w '%{http_code}' \
    -X POST -H "Authorization: Bearer ${token}" -H "Content-Type: application/json" \
    -H 'Content-Length: -1' --data-binary '{}' "${base_url}/api/terminal/review" || true)"
[[ "${negative_length_code}" == "400" ]]
jq -e '.status == "invalid_json"' "${tmp_root}/negative-length.json" >/dev/null

bootstrap_code="$(curl --noproxy '*' -sS -o "${tmp_root}/bootstrap.json" -w '%{http_code}' \
    -X POST -H "Content-Type: application/json" -d '{"bootstrap":"invalid"}' \
    "${base_url}/api/auth/bootstrap" || true)"
[[ "${bootstrap_code}" == "401" ]]
jq -e '.status == "unauthorized"' "${tmp_root}/bootstrap.json" >/dev/null

chunked_code="$(curl --noproxy '*' -sS -o "${tmp_root}/chunked.json" -w '%{http_code}' \
    -X POST -H "Authorization: Bearer ${token}" -H "Content-Type: application/json" \
    -H 'Transfer-Encoding: chunked' --data-binary '{}' "${base_url}/api/terminal/review" || true)"
[[ "${chunked_code}" == "400" ]]
jq -e '.status == "invalid_json"' "${tmp_root}/chunked.json" >/dev/null

health="$(curl --noproxy '*' -sS -H "Authorization: Bearer ${token}" "${base_url}/api/health")"

metrics="$(curl --noproxy '*' -sS -H "Authorization: Bearer ${token}" "${base_url}/api/metrics")"
printf '%s\n' "${metrics}" | grep -Eq 'linux_agent_build_info\{version='
printf '%s\n' "${metrics}" | grep -Eq 'linux_agent_process_start_time_seconds'
printf '%s\n' "${metrics}" | grep -Eq 'linux_agent_http_requests_total\{.*route="health"'
printf '%s\n' "${metrics}" | grep -Eq 'linux_agent_http_requests_total\{.*route="static".*status="200"'
printf '%s\n' "${metrics}" | grep -Eq 'linux_agent_jobs\{status='
printf '%s\n' "${metrics}" | grep -Eq 'linux_agent_jobs_active '
printf '%s\n' "${metrics}" | grep -Eq 'linux_agent_web_audit_events_total [1-9][0-9]*'

metrics_unauth_code="$(curl --noproxy '*' -sS -o "${tmp_root}/metrics-unauth.body" -w '%{http_code}' "${base_url}/api/metrics" || true)"
[[ "${metrics_unauth_code}" == "401" ]]

jq '.web.metrics_enabled = false' "${project}/config/config.json" >"${project}/config/config.metrics-off.json"
mv "${project}/config/config.metrics-off.json" "${project}/config/config.json"
metrics_disabled_body="${tmp_root}/metrics-disabled.body"
metrics_disabled_code="$(curl --noproxy '*' -sS -o "${metrics_disabled_body}" -w '%{http_code}' -H "Authorization: Bearer ${token}" "${base_url}/api/metrics" || true)"
[[ "${metrics_disabled_code}" == "404" ]]
jq -e '.ok == false and .code == "metrics_disabled"' <"${metrics_disabled_body}" >/dev/null
jq '.web.metrics_enabled = "false"' "${project}/config/config.json" >"${project}/config/config.metrics-invalid.json"
mv "${project}/config/config.metrics-invalid.json" "${project}/config/config.json"
metrics_invalid_code="$(curl --noproxy '*' -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${token}" "${base_url}/api/metrics" || true)"
[[ "${metrics_invalid_code}" == "404" ]]
invalid_metrics_config="$(curl --noproxy '*' -sS -H "Authorization: Bearer ${token}" "${base_url}/api/config")"
jq -e '.config.web.metrics_enabled == false' <<<"${invalid_metrics_config}" >/dev/null
jq '.web.metrics_enabled = true' "${project}/config/config.json" >"${project}/config/config.metrics-on.json"
mv "${project}/config/config.metrics-on.json" "${project}/config/config.json"

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
    and .config.command_guard.enabled == true
    and .config.observer.privilege == "sudo_interactive"
    and .config.observer.require == false
    and .config.approvals.auto.skill_readonly == true
    and .config.approvals.auto.shell_readonly == false
    and .config.approvals.auto.file_patch == false
    and .config.agent_loop.max_iterations == 12
    and .config.execution.timeout_sec == 300
    and .config.remote.allow_api_key_transmission == false' <<<"${config_state}" >/dev/null

providers_state="$(curl --noproxy '*' -sS -H "Authorization: Bearer ${token}" "${base_url}/api/config/providers")"
jq -e '.ok == true and .status == "listed"
    and ([.providers[].id] | index("openai"))
    and ([.providers[].id] | index("openai_compatible"))
    and ([.providers[].id] | index("anthropic"))
    and ([.providers[] | select(.id == "openai_compatible") | .custom_url] | first) == true
    and ([.providers[] | select(.id == "openai") | .api_url] | first | endswith("/v1/chat/completions"))' <<<"${providers_state}" >/dev/null

unsupported_models="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d '{"provider":"missing-provider"}' \
    "${base_url}/api/config/models")"
jq -e '.ok == false and .status == "unsupported_provider" and .code == "unsupported_provider"' <<<"${unsupported_models}" >/dev/null

blocked_terminal_review="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d '{"command":"rm -rf /"}' \
    "${base_url}/api/terminal/review")"
jq -e '.ok == false and .status == "blocked" and .code == "blocked"' <<<"${blocked_terminal_review}" >/dev/null

model_key_value="test-model-fetch-key-12345"
models_payload="$(jq -cn \
    --arg provider "openai_compatible" \
    --arg api_url "${FAKE_AI_URL}" \
    --arg api_key "${model_key_value}" \
    '{provider:$provider, api_url:$api_url, api_key:$api_key}')"
blocked_model_policy_payload="$(jq -cn '{key:"providers_security.allowed_hosts", value:[]}')"
curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${blocked_model_policy_payload}" \
    "${base_url}/api/config/update" >/dev/null
models_state="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${models_payload}" \
    "${base_url}/api/config/models")"
jq -e '.ok == false and .status == "blocked_internal_address"' <<<"${models_state}" >/dev/null

allow_payload="$(jq -cn '{key:"providers_security.allowed_hosts", value:["127.0.0.1"]}')"
curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${allow_payload}" \
    "${base_url}/api/config/update" >/dev/null

models_state="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${models_payload}" \
    "${base_url}/api/config/models")"
jq -e '.ok == true and .status == "listed" and .provider == "openai_compatible"
    and ([.models[].id] | index("fake-chat-completions"))
    and ([.models[].id] | index("fake-chat-completions-2"))
    and (.models | length) == 2
    and (.api_key | not)' <<<"${models_state}" >/dev/null
if grep -q "${model_key_value}" <<<"${models_state}"; then
    printf 'model fetch response leaked the transient api_key\n' >&2
    exit 1
fi

metadata_payload="$(jq -cn \
    --arg provider "openai_compatible" \
    --arg api_url "http://169.254.169.254/latest/meta-data/" \
    --arg api_key "${model_key_value}" \
    '{provider:$provider, api_url:$api_url, api_key:$api_key}')"
metadata_state="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${metadata_payload}" \
    "${base_url}/api/config/models")"
jq -e '.ok == false and .status == "blocked_internal_address"' <<<"${metadata_state}" >/dev/null

config_update_payload="$(jq -cn '{key:"agent_loop.thinking_trace_enabled", value:true}')"
config_update="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${config_update_payload}" \
    "${base_url}/api/config/update")"
jq -e '.ok == true and .status == "updated" and .config.agent_loop.thinking_trace_enabled == true' <<<"${config_update}" >/dev/null

iteration_limit_payload="$(jq -cn '{key:"agent_loop.max_iterations", value:20}')"
iteration_limit_update="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${iteration_limit_payload}" \
    "${base_url}/api/config/update")"
jq -e '.ok == true and .updated["agent_loop.max_iterations"] == 20 and .config.agent_loop.max_iterations == 20' <<<"${iteration_limit_update}" >/dev/null

execution_timeout_payload="$(jq -cn '{key:"execution.timeout_sec", value:120}')"
execution_timeout_update="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${execution_timeout_payload}" \
    "${base_url}/api/config/update")"
jq -e '.ok == true and .updated["execution.timeout_sec"] == 120 and .config.execution.timeout_sec == 120' <<<"${execution_timeout_update}" >/dev/null

resilience_batch_payload="$(jq -cn '{changes:{
    "provider_resilience.max_attempts":4,
    "provider_resilience.backoff_initial_ms":100,
    "provider_resilience.backoff_max_ms":500
}}')"
resilience_batch_update="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${resilience_batch_payload}" \
    "${base_url}/api/config/update")"
jq -e '.ok == true
    and .updated["provider_resilience.max_attempts"] == 4
    and .config.provider_resilience.max_attempts == 4
    and .config.provider_resilience.backoff_initial_ms == 100
    and .config.provider_resilience.backoff_max_ms == 500' <<<"${resilience_batch_update}" >/dev/null

invalid_resilience_payload="$(jq -cn '{changes:{
    "provider_resilience.backoff_initial_ms":900,
    "provider_resilience.backoff_max_ms":100
}}')"
invalid_resilience_update="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${invalid_resilience_payload}" \
    "${base_url}/api/config/update")"
jq -e '.ok == false and .status == "invalid_config_value"' <<<"${invalid_resilience_update}" >/dev/null
jq -e '.provider_resilience.backoff_initial_ms == 100 and .provider_resilience.backoff_max_ms == 500' \
    "${project}/config/config.json" >/dev/null

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

mcp_state="$(curl --noproxy '*' -sS -H "Authorization: Bearer ${token}" "${base_url}/api/mcp")"
jq -e '.ok == true and .status == "listed"
    and ([.servers[].id] | index("stdio-web"))
    and ([.servers[].transport] | unique | sort) == ["sse","stdio","streamable_http"]
    and ([.servers[] | select(.id == "context7") | .enabled] | first) == false
    and ([.servers[] | select(.id == "http-web") | .enabled] | first) == false
    and ([.servers[] | select(.id == "stdio-web") | .config.env.WEB_TOKEN] | first) == "[REDACTED]"' <<<"${mcp_state}" >/dev/null
if grep -q 'web-secret-value' <<<"${mcp_state}"; then
    printf 'web mcp response leaked secret material\n' >&2
    exit 1
fi
mcp_validate="$(curl --noproxy '*' -sS -H "Authorization: Bearer ${token}" "${base_url}/api/mcp/validate")"
jq -e '.ok == true and .status == "validated" and .validation.ok == true' <<<"${mcp_validate}" >/dev/null
mcp_tools="$(curl --noproxy '*' -sS -H "Authorization: Bearer ${token}" "${base_url}/api/mcp/tools")"
jq -e '.ok == true and .status == "listed"
    and .tool_count == 1
    and ([.tools[] | select(.server_id == "stdio-web" and .name == "echo") | .ref] | first) == "stdio-web/echo"
    and ([.servers[] | select(.id == "stdio-web") | .tool_count] | first) == 1' <<<"${mcp_tools}" >/dev/null
if grep -q 'web-secret-value' <<<"${mcp_tools}"; then
    printf 'web mcp tools response leaked secret material\n' >&2
    exit 1
fi

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
jq -e '.ok == true and .requires_sudo_to_edit == true
    and any(.files[]?.path; . == "audit-boundaries.json")
    and any(.files[]?.path; . == "file-vault.json")' <<<"${policies}" >/dev/null

# Domain failures use schema-defined HTTP codes while retaining their JSON
# envelope. Invalid identifiers must not be mislabeled as persisted-data
# corruption.
invalid_session_file="${tmp_root}/invalid-session.json"
invalid_session_code="$(curl --noproxy '*' -sS -o "${invalid_session_file}" -w '%{http_code}' \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d '{"session_id":"../unsafe"}' \
    "${base_url}/api/session/restore")"
[[ "${invalid_session_code}" == "400" ]] || {
    printf 'invalid session returned HTTP %s: ' "${invalid_session_code}" >&2
    cat "${invalid_session_file}" >&2
    exit 1
}
jq -e '.ok == false and .code == "invalid_session_id"' "${invalid_session_file}" >/dev/null

invalid_policy_file="${tmp_root}/invalid-policy-path.json"
invalid_policy_code="$(curl --noproxy '*' -sS -o "${invalid_policy_file}" -w '%{http_code}' \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d '{"path":"../unsafe.json"}' \
    "${base_url}/api/policies/read")"
[[ "${invalid_policy_code}" == "400" ]] || {
    printf 'invalid policy path returned HTTP %s: ' "${invalid_policy_code}" >&2
    cat "${invalid_policy_file}" >&2
    exit 1
}
jq -e '.ok == false and .code == "invalid_path"' "${invalid_policy_file}" >/dev/null

# A Web audit event that cannot be persisted returns a structured 507 instead
# of dropping the handler connection. PolicyService unit tests separately prove
# that required mutation intents fail before changing durable configuration.
audit_block_config="${tmp_root}/audit-block-config.json"
cp "${project}/config/config.json" "${audit_block_config}"
tmp_config="$(mktemp)"
jq '.audit.min_free_bytes = 999999999999999 | .audit.on_full = "block"' \
    "${project}/config/config.json" >"${tmp_config}"
mv "${tmp_config}" "${project}/config/config.json"
audit_block_file="${tmp_root}/audit-block-web-event.json"
audit_block_code="$(curl --noproxy '*' -sS -o "${audit_block_file}" -w '%{http_code}' \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d '{"action":"skip"}' \
    "${base_url}/api/observer/bootstrap")"
[[ "${audit_block_code}" == "507" ]] || {
    printf 'blocked Web audit returned HTTP %s: ' "${audit_block_code}" >&2
    cat "${audit_block_file}" >&2
    exit 1
}
jq -e '.ok == false and .code == "audit_write_blocked"' "${audit_block_file}" >/dev/null
cp "${audit_block_config}" "${project}/config/config.json"

boundary_payload="$(jq -cn '{path:"audit-boundaries.json"}')"
boundary="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${boundary_payload}" \
    "${base_url}/api/policies/read")"
jq -e '.ok == true and .json.observing.audit_payload_mode == "safe_summary" and (.json.allowed_to_observe.observer_syscalls | index("openat"))' <<<"${boundary}" >/dev/null

vault_policy_payload="$(jq -cn '{path:"file-vault.json"}')"
vault_policy_read="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${vault_policy_payload}" \
    "${base_url}/api/policies/read")"
jq -e '.ok == true and .json.paths == []' <<<"${vault_policy_read}" >/dev/null

vault_policy_content='{"paths":["/tmp/web-file-vault-test"]}'
vault_policy_validate_payload="$(jq -cn --arg content "${vault_policy_content}" '{path:"file-vault.json",content:$content}')"
vault_policy_validate="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${vault_policy_validate_payload}" \
    "${base_url}/api/policies/validate")"
jq -e '.ok == true and .status == "valid" and .validation.ok == true' <<<"${vault_policy_validate}" >/dev/null

vault_policy_write_payload="$(jq -cn --arg content "${vault_policy_content}" '{path:"file-vault.json",content:$content,password:""}')"
vault_policy_write="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${vault_policy_write_payload}" \
    "${base_url}/api/policies/write")"
jq -e 'if .ok then .status == "saved" and (.method == "root" or .method == "sudo") else .status == "sudo_required" end' <<<"${vault_policy_write}" >/dev/null

grep -q 'id="policyEditVaultBtn"' "${project}/web/static/index.html"
grep -q 'id="policyInspectBtn"' "${project}/web/static/index.html"
grep -q 'id="policyFileDialog"' "${project}/web/static/index.html"
grep -q 'id="policyGuardToggleBtn"' "${project}/web/static/index.html"
grep -q 'file-vault.json' "${project}/web/static/modules/view-policy.js"

command_guard_state="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H 'Content-Type: application/json' \
    -d '{"enabled":true,"password":""}' \
    "${base_url}/api/policies/command-guard")"
jq -e 'if .ok then .status == "updated" and .command_guard.enabled == true else (.status | IN("sudo_required","sudo_not_found","sudo_timeout","sudo_denied")) end' <<<"${command_guard_state}" >/dev/null

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

job_poll_attempts=300
work_payload="$(jq -cn '{resource:"work", action:"run", payload:{input:"查看cpu占用"}}')"
work_job_one="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${work_payload}" \
    "${base_url}/api/jobs")"
work_job_one_id="$(jq -r '.job_id' <<<"${work_job_one}")"
[[ "${work_job_one_id}" =~ ^[0-9a-f]+$ ]]
# Submit a second Work Job before polling the first. Both must snapshot the
# same empty workspace context and then run in private sessions.
work_job_two="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${work_payload}" \
    "${base_url}/api/jobs")"
work_job_two_id="$(jq -r '.job_id' <<<"${work_job_two}")"
[[ "${work_job_two_id}" =~ ^[0-9a-f]+$ ]]
[[ "${work_job_two_id}" != "${work_job_one_id}" ]]
work_result_one=""
for _ in $(seq 1 "${job_poll_attempts}"); do
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
completed_metrics="$(curl --noproxy '*' -sS -H "Authorization: Bearer ${token}" "${base_url}/api/metrics")"
printf '%s\n' "${completed_metrics}" | grep -Eq 'linux_agent_jobs\{status="succeeded"\} [1-9][0-9]*'
printf '%s\n' "${completed_metrics}" | grep -Eq 'linux_agent_jobs_completed_total\{result="succeeded"\} [1-9][0-9]*'
printf '%s\n' "${completed_metrics}" | grep -Eq 'linux_agent_job_duration_seconds_count [1-9][0-9]*'

slow_work_payload="$(jq -cn '{resource:"work", action:"run", payload:{input:"慢速实时输出检查"}}')"
slow_work_job="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${slow_work_payload}" \
    "${base_url}/api/jobs")"
slow_work_job_id="$(jq -r '.job_id' <<<"${slow_work_job}")"
[[ "${slow_work_job_id}" =~ ^[0-9a-f]+$ ]]
slow_partial_seen=0
slow_work_state=""
for _ in $(seq 1 "${job_poll_attempts}"); do
    slow_work_state="$(curl --noproxy '*' -sS -H "Authorization: Bearer ${token}" "${base_url}/api/jobs/${slow_work_job_id}")"
    if jq -e '.status == "running"
        and .result.status == "running"
        and ([.result.output_blocks[]? | select(.title == "执行流程") | .text | contains("# 工作计划")] | any)' <<<"${slow_work_state}" >/dev/null; then
        slow_partial_seen=1
        break
    fi
    slow_status="$(jq -r '.status' <<<"${slow_work_state}")"
    if [[ "${slow_status}" != "queued" && "${slow_status}" != "running" ]]; then
        break
    fi
    sleep 0.1
done
if [[ "${slow_partial_seen}" != "1" ]]; then
    printf 'slow work did not expose partial output (job_status=%s, result_status=%s)\n' \
        "$(jq -r '.status // "unknown"' <<<"${slow_work_state}")" \
        "$(jq -r '.result.status // "unknown"' <<<"${slow_work_state}")" >&2
    exit 1
fi
for _ in $(seq 1 "${job_poll_attempts}"); do
    slow_work_result="$(curl --noproxy '*' -sS -H "Authorization: Bearer ${token}" "${base_url}/api/jobs/${slow_work_job_id}")"
    slow_work_status="$(jq -r '.status' <<<"${slow_work_result}")"
    if [[ "${slow_work_status}" != "queued" && "${slow_work_status}" != "running" ]]; then
        break
    fi
    sleep 0.1
done
[[ "${slow_work_status}" == "succeeded" ]]
jq -e '.result_status == "executed" and .result_ok == true
    and ([.result.output_blocks[]? | select(.kind == "markdown" and .title == "最终回答") | .text | contains("慢速实时检查已完成")] | any)
    and ([.result.output_blocks[]? | select(.title == "执行流程") | .text | contains("# 工作计划") and contains("步骤输出")] | any)' <<<"${slow_work_result}" >/dev/null

work_result_two=""
for _ in $(seq 1 "${job_poll_attempts}"); do
    work_result_two="$(curl --noproxy '*' -sS -H "Authorization: Bearer ${token}" "${base_url}/api/jobs/${work_job_two_id}")"
    work_status_two="$(jq -r '.status' <<<"${work_result_two}")"
    if [[ "${work_status_two}" != "queued" && "${work_status_two}" != "running" ]]; then
        break
    fi
    sleep 0.2
done
[[ "${work_status_two}" == "succeeded" ]]

read_audit_session() {
    local session_id="$1"
    local body
    body="$(jq -cn --arg session_id "${session_id}" '{session_id:$session_id}')"
    curl --noproxy '*' -sS \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d "${body}" \
        "${base_url}/api/audit/read"
}

workspace_state="$(curl --noproxy '*' -sS -H "Authorization: Bearer ${token}" "${base_url}/api/session/state")"
workspace_session_id="$(jq -r '.session_id' <<<"${workspace_state}")"
work_one_session_id="$(jq -r '.session_id' <<<"${work_result_one}")"
work_two_session_id="$(jq -r '.session_id' <<<"${work_result_two}")"
slow_work_session_id="$(jq -r '.session_id' <<<"${slow_work_result}")"
[[ "${workspace_session_id}" == session_web_* ]]
[[ "${work_one_session_id}" == job_* ]]
[[ "${work_two_session_id}" == job_* ]]
[[ "${slow_work_session_id}" == job_* ]]
[[ "${work_one_session_id}" != "${work_two_session_id}" ]]
[[ "${work_one_session_id}" != "${slow_work_session_id}" ]]
[[ "${work_two_session_id}" != "${slow_work_session_id}" ]]
for session_id in "${workspace_session_id}" "${work_one_session_id}" "${work_two_session_id}" "${slow_work_session_id}"; do
    [[ -f "${project}/logs/${session_id}.jsonl" ]]
    [[ "$(stat -c '%a' "${project}/logs/${session_id}.jsonl")" == "600" ]]
done

# The audit index now contains one workspace session plus one private session per Job.
audit_after_work="$(curl --noproxy '*' -sS -H "Authorization: Bearer ${token}" "${base_url}/api/audit/list")"
jq -e \
    --arg workspace "${workspace_session_id}" \
    --arg one "${work_one_session_id}" \
    --arg two "${work_two_session_id}" \
    --arg slow "${slow_work_session_id}" '
    [.sessions[]?.session_id] as $ids
    | .ok == true
      and ($ids | index($workspace)) != null
      and ($ids | index($one)) != null
      and ($ids | index($two)) != null
      and ($ids | index($slow)) != null
' <<<"${audit_after_work}" >/dev/null

audit_query_payload="$(jq -cn --arg query "${workspace_session_id}" '{limit:1, query:$query}')"
audit_query_result="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${audit_query_payload}" \
    "${base_url}/api/audit/list")"
jq -e --arg session_id "${workspace_session_id}" '
    .ok == true and (.sessions | length) == 1 and .sessions[0].session_id == $session_id
' <<<"${audit_query_result}" >/dev/null

# Workspace display comes from immutable protocol turns; its audit contains only
# serialized merge summaries, never interleaved private Job lifecycle events.
workspace_audit="$(read_audit_session "${workspace_session_id}")"
jq -e \
    --arg one "${work_job_one_id}" \
    --arg two "${work_job_two_id}" \
    --arg slow "${slow_work_job_id}" \
    --slurpfile domain "${project}/schema/domain.json" '
    . as $root
    | ($domain[0].step_status) as $allowed
    | [.events[]? | select(.stage == "job_session_merged") | .payload.job_id] as $merged
    | .ok == true
      and .web_timeline.source == "persisted"
      and (.web_timeline.turns | length) == 3
      and all(.web_timeline.turns[];
          .source == "persisted"
          and .context_eligible == true
          and .history_merged_count >= 1
          and (.result.timeline | type) == "array")
      and all(.web_timeline.turns[].result.timeline[]?; . as $item | ($allowed | index($item.status)) != null)
      and ($merged | index($one)) != null
      and ($merged | index($two)) != null
      and ($merged | index($slow)) != null
      and all(.events[]? | select(.stage == "job_session_merged");
          (.outbox_event_id | type) == "string"
          and .outbox_event_id == .payload.outbox_event_id)
      and ([.events[]? | select(.stage == "received" or .stage == "step_running")] | length) == 0
' <<<"${workspace_audit}" >/dev/null

work_one_audit="$(read_audit_session "${work_one_session_id}")"
work_two_audit="$(read_audit_session "${work_two_session_id}")"
slow_private_audit="$(read_audit_session "${slow_work_session_id}")"
jq -e --arg session_id "${work_one_session_id}" --arg job_id "${work_job_one_id}" '
    .ok == true
    and .web_timeline.source == "persisted"
    and (.web_timeline.turns | length) == 1
    and all(.events[]; .session_id == $session_id)
    and ([.events[]? | select(.job_id != null and .job_id != $job_id)] | length) == 0
    and ([.events[]? | select(.stage == "request_context_built") | .payload.conversation_turns] | first) == 0
' <<<"${work_one_audit}" >/dev/null
jq -e --arg session_id "${work_two_session_id}" --arg job_id "${work_job_two_id}" '
    .ok == true
    and .web_timeline.source == "persisted"
    and (.web_timeline.turns | length) == 1
    and all(.events[]; .session_id == $session_id)
    and ([.events[]? | select(.job_id != null and .job_id != $job_id)] | length) == 0
    and ([.events[]? | select(.stage == "request_context_built") | .payload.conversation_turns] | first) == 0
' <<<"${work_two_audit}" >/dev/null
jq -e --arg session_id "${slow_work_session_id}" --arg job_id "${slow_work_job_id}" '
    .ok == true
    and .web_timeline.source == "persisted"
    and (.web_timeline.turns | length) == 1
    and all(.events[]; .session_id == $session_id)
    and ([.events[]? | select(.job_id != null and .job_id != $job_id)] | length) == 0
    and ([.events[]? | select(.stage == "request_context_built") | .payload.conversation_turns] | first) >= 1
' <<<"${slow_private_audit}" >/dev/null
jq -e 'type == "array"' "${project}/tmp/web/jobs/${work_job_one_id}.history.json" >/dev/null
jq -e 'type == "array"' "${project}/tmp/web/jobs/${work_job_two_id}.history.json" >/dev/null

# A legacy audit file remains readable as evidence but cannot be reconstructed
# into protocol state or restored into the workbench.
legacy_session_id="session_web_legacy_readonly"
legacy_log="${project}/logs/${legacy_session_id}.jsonl"
printf '%s\n' \
    '{"timestamp":"2026-07-05T00:00:00Z","session_id":"session_web_legacy_readonly","stage":"session_started","payload":{"request":"agent-web","entrypoint":"web"}}' \
    '{"timestamp":"2026-07-05T00:00:01Z","session_id":"session_web_legacy_readonly","stage":"received","payload":{"mode":"work","input_preview":"legacy fixture"}}' \
    >"${legacy_log}"
legacy_audit="$(read_audit_session "${legacy_session_id}")"
jq -e '
    .ok == true
    and (.events | length) == 2
    and .web_timeline == null
    and .timeline_unavailable_reason == "legacy_session_no_persisted_turns"
' <<<"${legacy_audit}" >/dev/null
legacy_restore_payload="$(jq -cn --arg session_id "${legacy_session_id}" '{session_id:$session_id}')"
legacy_restore="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${legacy_restore_payload}" \
    "${base_url}/api/session/restore")"
jq -e '.ok == false and .status == "legacy_session_no_persisted_turns"' <<<"${legacy_restore}" >/dev/null

# Restoring a new session copies persisted turns/history; no audit replay is used.
workspace_restore_payload="$(jq -cn --arg session_id "${workspace_session_id}" '{session_id:$session_id}')"
restore_result="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${workspace_restore_payload}" \
    "${base_url}/api/session/restore")"
restored_session_id="$(jq -r '.session.session_id // empty' <<<"${restore_result}")"
jq -e --arg session_id "${workspace_session_id}" '
    .ok == true
    and .status == "restored"
    and .session.restored_from == $session_id
    and (.session.session_id | startswith("session_web_"))
    and .history_count >= 3
    and .session.history_count == .history_count
    and .session.turn_count == 3
    and (.web_timeline.turns | length) == 3
    and .web_timeline.source == "persisted"
' <<<"${restore_result}" >/dev/null
[[ -n "${restored_session_id}" ]]

session_state="$(curl --noproxy '*' -sS -H "Authorization: Bearer ${token}" "${base_url}/api/session/state")"
jq -e --arg session_id "${workspace_session_id}" --arg restored_session_id "${restored_session_id}" '
    .ok == true
    and .session_id == $restored_session_id
    and .restored_from == $session_id
    and .history_count >= 3
    and .context_window_count > 0
    and .turn_count == 3
    and (.web_timeline.turns | length) == 3
' <<<"${session_state}" >/dev/null

leave_result="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d '{}' \
    "${base_url}/api/session/leave")"
left_session_id="$(jq -r '.session.session_id // empty' <<<"${leave_result}")"
jq -e --arg session_id "${workspace_session_id}" --arg restored_session_id "${restored_session_id}" '
    .ok == true
    and .status == "left_restored"
    and .left_restored_from == $session_id
    and .session.restored_from == ""
    and .session.history_count == 0
    and .session.context_window_count == 0
    and .session.turn_count == 0
    and .session.session_id != $restored_session_id
    and (.session.session_id | startswith("session_web_"))
' <<<"${leave_result}" >/dev/null
[[ -n "${left_session_id}" ]]

work_job_after_leave="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${work_payload}" \
    "${base_url}/api/jobs")"
work_job_after_leave_id="$(jq -r '.job_id' <<<"${work_job_after_leave}")"
[[ "${work_job_after_leave_id}" =~ ^[0-9a-f]+$ ]]
for _ in $(seq 1 "${job_poll_attempts}"); do
    work_result_after_leave="$(curl --noproxy '*' -sS -H "Authorization: Bearer ${token}" "${base_url}/api/jobs/${work_job_after_leave_id}")"
    work_status_after_leave="$(jq -r '.status' <<<"${work_result_after_leave}")"
    if [[ "${work_status_after_leave}" != "queued" && "${work_status_after_leave}" != "running" ]]; then
        break
    fi
    sleep 0.2
done
[[ "${work_status_after_leave}" == "succeeded" ]]
left_job_session_id="$(jq -r '.session_id' <<<"${work_result_after_leave}")"
left_job_audit="$(read_audit_session "${left_job_session_id}")"
jq -e '
    ([.events[]? | select(.stage == "request_context_built") | .payload.conversation_turns] | first) == 0
    and .web_timeline.source == "persisted"
' <<<"${left_job_audit}" >/dev/null
left_workspace_state="$(curl --noproxy '*' -sS -H "Authorization: Bearer ${token}" "${base_url}/api/session/state")"
jq -e '.history_count >= 1 and .turn_count == 1 and (.web_timeline.turns | length) == 1' <<<"${left_workspace_state}" >/dev/null

job_payload="$(jq -cn '{resource:"terminal", action:"run", payload:{command:"printf web-job-ok", approve:true}}')"
job="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${job_payload}" \
    "${base_url}/api/jobs")"
job_id="$(jq -r '.job_id' <<<"${job}")"
[[ "${job_id}" =~ ^[0-9a-f]+$ ]]

job_status=""
job_result=""
for _ in $(seq 1 "${job_poll_attempts}"); do
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
job_session_id="$(jq -r '.session_id' <<<"${job_result}")"
jq -e --arg session_id "${job_session_id}" '
    .ok == true
    and ([.sessions[]? | select(.session_id == $session_id and .entrypoint == "web" and (.modes | index("terminal")))] | length) == 1
' <<<"${audit_after_job}" >/dev/null
audit_read="$(read_audit_session "${job_session_id}")"
jq -e --arg session_id "${job_session_id}" '
    .ok == true
    and .session_id == $session_id
    and .web_timeline == null
    and (.timeline_unavailable_reason | type) == "string"
    and ([.events[]? | select(.stage == "terminal_executed")] | length) == 1
' <<<"${audit_read}" >/dev/null

history_before_cancel="$(curl --noproxy '*' -sS -H "Authorization: Bearer ${token}" "${base_url}/api/session/state")"
history_count_before_cancel="$(jq -r '.history_count' <<<"${history_before_cancel}")"
turn_count_before_cancel="$(jq -r '.turn_count' <<<"${history_before_cancel}")"
cancel_payload="$(jq -cn '{resource:"work", action:"run", payload:{input:"慢速实时输出检查"}}')"
cancel_job="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${cancel_payload}" \
    "${base_url}/api/jobs")"
cancel_job_id="$(jq -r '.job_id' <<<"${cancel_job}")"
cancel_session_id="$(jq -r '.session_id' <<<"${cancel_job}")"
[[ "${cancel_job_id}" =~ ^[0-9a-f]+$ ]]

survivor_payload="$(jq -cn '{resource:"terminal", action:"run", payload:{command:"printf survivor-ok", approve:true}}')"
survivor_job="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${survivor_payload}" \
    "${base_url}/api/jobs")"
survivor_job_id="$(jq -r '.job_id' <<<"${survivor_job}")"
survivor_session_id="$(jq -r '.session_id' <<<"${survivor_job}")"
[[ "${survivor_job_id}" =~ ^[0-9a-f]+$ ]]
[[ "${survivor_session_id}" != "${cancel_session_id}" ]]

sleep 0.3
busy_leave_file="${tmp_root}/busy-leave.json"
busy_leave_code="$(curl --noproxy '*' -sS -o "${busy_leave_file}" -w '%{http_code}' \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d '{}' \
    "${base_url}/api/session/leave")"
[[ "${busy_leave_code}" == "409" ]]
jq -e '.status == "session_busy" and .retryable == true and .active_jobs >= 1' "${busy_leave_file}" >/dev/null
cancel_result="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d '{}' \
    "${base_url}/api/jobs/${cancel_job_id}/cancel")"
jq -e '.ok == true and .status == "cancelled"' <<<"${cancel_result}" >/dev/null
for _ in $(seq 1 "${job_poll_attempts}"); do
    cancelled_state="$(curl --noproxy '*' -sS -H "Authorization: Bearer ${token}" "${base_url}/api/jobs/${cancel_job_id}")"
    survivor_state="$(curl --noproxy '*' -sS -H "Authorization: Bearer ${token}" "${base_url}/api/jobs/${survivor_job_id}")"
    cancelled_status="$(jq -r '.status' <<<"${cancelled_state}")"
    survivor_status="$(jq -r '.status' <<<"${survivor_state}")"
    if [[ "${cancelled_status}" == "cancelled" && "${survivor_status}" != "queued" && "${survivor_status}" != "running" ]]; then
        break
    fi
    sleep 0.1
done
[[ "${cancelled_status}" == "cancelled" ]]
[[ "${survivor_status}" == "succeeded" ]]
jq -e '.result.status == "cancelled" and .result_status == "cancelled"' <<<"${cancelled_state}" >/dev/null
jq -e '.result.status == "executed"
    and ([.result.output_blocks[]? | select(.kind == "stdout") | .text] | first) == "survivor-ok"' <<<"${survivor_state}" >/dev/null
sleep 0.3
cancelled_final="$(curl --noproxy '*' -sS -H "Authorization: Bearer ${token}" "${base_url}/api/jobs/${cancel_job_id}")"
jq -e '.status == "cancelled" and .result.status == "cancelled"' <<<"${cancelled_final}" >/dev/null
history_after_cancel="$(curl --noproxy '*' -sS -H "Authorization: Bearer ${token}" "${base_url}/api/session/state")"
jq -e \
    --argjson history_count "${history_count_before_cancel}" \
    --argjson turn_count "${turn_count_before_cancel}" '
    .history_count == $history_count
    and .turn_count == ($turn_count + 1)
    and .web_timeline.turns[-1].status == "cancelled"
    and .web_timeline.turns[-1].context_eligible == false
    and .web_timeline.turns[-1].history_merged_count == 0
' <<<"${history_after_cancel}" >/dev/null
cancel_private_audit="$(read_audit_session "${cancel_session_id}")"
survivor_private_audit="$(read_audit_session "${survivor_session_id}")"
jq -e --arg session_id "${cancel_session_id}" 'all(.events[]; .session_id == $session_id)' <<<"${cancel_private_audit}" >/dev/null
jq -e --arg session_id "${survivor_session_id}" 'all(.events[]; .session_id == $session_id)' <<<"${survivor_private_audit}" >/dev/null

# Idempotency-Key deduplicates both header and body submissions. New requests
# return 202, a replay returns 200, and overlong keys are rejected (not truncated).
idem_payload="$(jq -cn '{resource:"terminal", action:"run", payload:{command:"printf idem-ok"}}')"
idem_one_file="${tmp_root}/idem-one.json"
idem_one_code="$(curl --noproxy '*' -sS -o "${idem_one_file}" -w '%{http_code}' \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -H "Idempotency-Key: web-idem-key-1" \
    -d "${idem_payload}" \
    "${base_url}/api/jobs")"
idem_one="$(<"${idem_one_file}")"
idem_one_id="$(jq -r '.job_id' <<<"${idem_one}")"
[[ "${idem_one_code}" == "202" ]]
[[ "${idem_one_id}" =~ ^[0-9a-f]+$ ]]

idem_two_file="${tmp_root}/idem-two.json"
idem_two_code="$(curl --noproxy '*' -sS -o "${idem_two_file}" -w '%{http_code}' \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -H "Idempotency-Key: web-idem-key-1" \
    -d "${idem_payload}" \
    "${base_url}/api/jobs")"
idem_two="$(<"${idem_two_file}")"
[[ "${idem_two_code}" == "200" ]]
jq -e --arg id "${idem_one_id}" '.ok == true and .deduplicated == true and .job_id == $id' <<<"${idem_two}" >/dev/null

idem_three="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -H "Idempotency-Key: web-idem-key-2" \
    -d "${idem_payload}" \
    "${base_url}/api/jobs")"
[[ "$(jq -r '.job_id' <<<"${idem_three}")" != "${idem_one_id}" ]]
jq -e '.deduplicated != true' <<<"${idem_three}" >/dev/null

idem_body_payload="$(jq -cn '{resource:"terminal", action:"run", idempotency_key:"web-body-key-1", payload:{command:"printf body-idem"}}')"
idem_body_one="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${idem_body_payload}" \
    "${base_url}/api/jobs")"
idem_body_two="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${idem_body_payload}" \
    "${base_url}/api/jobs")"
jq -e --arg id "$(jq -r '.job_id' <<<"${idem_body_one}")" '
    .deduplicated == true and .job_id == $id
' <<<"${idem_body_two}" >/dev/null

long_key="$(python3 -c 'print("x" * 257)')"
long_key_payload="$(jq -cn --arg key "${long_key}" '{resource:"terminal",action:"run",idempotency_key:$key,payload:{command:"true"}}')"
long_key_file="${tmp_root}/long-key.json"
long_key_code="$(curl --noproxy '*' -sS -o "${long_key_file}" -w '%{http_code}' \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${long_key_payload}" \
    "${base_url}/api/jobs")"
[[ "${long_key_code}" == "400" ]]
jq -e '.status == "invalid_idempotency_key"' "${long_key_file}" >/dev/null

# Reusing a key for a different canonical request is an explicit 409, and the
# standardized error envelope keeps compatibility aliases plus request details.
idem_conflict_payload="$(jq -cn '{resource:"terminal",action:"run",payload:{command:"printf different-request"}}')"
idem_conflict_file="${tmp_root}/idem-conflict.json"
idem_conflict_code="$(curl --noproxy '*' -sS -o "${idem_conflict_file}" -w '%{http_code}' \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -H "Idempotency-Key: web-idem-key-1" \
    -H "X-Request-ID: idem-conflict-request" \
    -d "${idem_conflict_payload}" \
    "${base_url}/api/jobs")"
[[ "${idem_conflict_code}" == "409" ]]
jq -e --arg existing "${idem_one_id}" '
    .ok == false
    and .status == "idempotency_conflict"
    and .code == .status
    and .message == .error
    and .retryable == false
    and .request_id == "idem-conflict-request"
    and .details.existing_job_id == $existing
' "${idem_conflict_file}" >/dev/null

# A failed Job can be retried into a new isolated session. Retry lineage and
# attempts are durable, replay is idempotent, stale versions conflict, and the
# configured maximum is enforced.
retry_source_payload="$(jq -cn '{resource:"terminal",action:"run",payload:{command:"exit 7",approve:true}}')"
retry_source="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${retry_source_payload}" \
    "${base_url}/api/jobs")"
retry_source_id="$(jq -r '.job_id' <<<"${retry_source}")"
for _ in $(seq 1 "${job_poll_attempts}"); do
    retry_source_state="$(curl --noproxy '*' -sS -H "Authorization: Bearer ${token}" "${base_url}/api/jobs/${retry_source_id}")"
    retry_source_status="$(jq -r '.status' <<<"${retry_source_state}")"
    [[ "${retry_source_status}" != "queued" && "${retry_source_status}" != "running" ]] && break
    sleep 0.1
done
jq -e '.status == "failed" and .attempt == 1 and .max_attempts == 3' <<<"${retry_source_state}" >/dev/null
retry_source_version="$(jq -r '.version' <<<"${retry_source_state}")"
retry_source_session="$(jq -r '.session_id' <<<"${retry_source_state}")"

stale_retry_file="${tmp_root}/stale-retry.json"
stale_retry_code="$(curl --noproxy '*' -sS -o "${stale_retry_file}" -w '%{http_code}' \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "$(jq -cn --argjson version "$((retry_source_version + 1))" '{expected_version:$version}')" \
    "${base_url}/api/jobs/${retry_source_id}/retry")"
[[ "${stale_retry_code}" == "409" ]]
jq -e --argjson actual "${retry_source_version}" '
    .status == "job_version_conflict" and .details.actual_version == $actual
' "${stale_retry_file}" >/dev/null

retry_one_file="${tmp_root}/retry-one.json"
retry_one_code="$(curl --noproxy '*' -sS -o "${retry_one_file}" -w '%{http_code}' \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "$(jq -cn --argjson version "${retry_source_version}" '{expected_version:$version}')" \
    "${base_url}/api/jobs/${retry_source_id}/retry")"
[[ "${retry_one_code}" == "202" ]]
retry_one_id="$(jq -r '.job_id' "${retry_one_file}")"
jq -e --arg parent "${retry_source_id}" --arg root "${retry_source_id}" --arg old_session "${retry_source_session}" '
    .retry_of == $parent and .root_job_id == $root
    and .attempt == 2 and .max_attempts == 3
    and .session_id != $old_session
' "${retry_one_file}" >/dev/null

retry_replay_file="${tmp_root}/retry-replay.json"
retry_replay_code="$(curl --noproxy '*' -sS -o "${retry_replay_file}" -w '%{http_code}' \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "$(jq -cn --argjson version "${retry_source_version}" '{expected_version:$version}')" \
    "${base_url}/api/jobs/${retry_source_id}/retry")"
[[ "${retry_replay_code}" == "200" ]]
jq -e --arg id "${retry_one_id}" '.deduplicated == true and .job_id == $id' "${retry_replay_file}" >/dev/null

for _ in $(seq 1 "${job_poll_attempts}"); do
    retry_one_state="$(curl --noproxy '*' -sS -H "Authorization: Bearer ${token}" "${base_url}/api/jobs/${retry_one_id}")"
    retry_one_status="$(jq -r '.status' <<<"${retry_one_state}")"
    [[ "${retry_one_status}" != "queued" && "${retry_one_status}" != "running" ]] && break
    sleep 0.1
done
jq -e '.status == "failed" and .attempt == 2' <<<"${retry_one_state}" >/dev/null
retry_one_version="$(jq -r '.version' <<<"${retry_one_state}")"

retry_two="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "$(jq -cn --argjson version "${retry_one_version}" '{expected_version:$version}')" \
    "${base_url}/api/jobs/${retry_one_id}/retry")"
retry_two_id="$(jq -r '.job_id' <<<"${retry_two}")"
jq -e --arg parent "${retry_one_id}" --arg root "${retry_source_id}" '
    .retry_of == $parent and .root_job_id == $root and .attempt == 3
' <<<"${retry_two}" >/dev/null
for _ in $(seq 1 "${job_poll_attempts}"); do
    retry_two_state="$(curl --noproxy '*' -sS -H "Authorization: Bearer ${token}" "${base_url}/api/jobs/${retry_two_id}")"
    retry_two_status="$(jq -r '.status' <<<"${retry_two_state}")"
    [[ "${retry_two_status}" != "queued" && "${retry_two_status}" != "running" ]] && break
    sleep 0.1
done
retry_two_version="$(jq -r '.version' <<<"${retry_two_state}")"
retry_limit_file="${tmp_root}/retry-limit.json"
retry_limit_code="$(curl --noproxy '*' -sS -o "${retry_limit_file}" -w '%{http_code}' \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "$(jq -cn --argjson version "${retry_two_version}" '{expected_version:$version}')" \
    "${base_url}/api/jobs/${retry_two_id}/retry")"
[[ "${retry_limit_code}" == "409" ]]
jq -e '.status == "job_retry_limit_reached"' "${retry_limit_file}" >/dev/null

# A pending approval remains visible as a Turn but must not enter model context.
approval_state_before="$(curl --noproxy '*' -sS -H "Authorization: Bearer ${token}" "${base_url}/api/session/state")"
approval_history_before="$(jq -r '.history_count' <<<"${approval_state_before}")"
approval_turns_before="$(jq -r '.turn_count' <<<"${approval_state_before}")"
approval_payload="$(jq -cn '{resource:"work", action:"run", payload:{input:"帮我检查磁盘空间是否异常"}}')"
approval_job="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${approval_payload}" \
    "${base_url}/api/jobs")"
approval_job_id="$(jq -r '.job_id' <<<"${approval_job}")"
for _ in $(seq 1 "${job_poll_attempts}"); do
    approval_result="$(curl --noproxy '*' -sS -H "Authorization: Bearer ${token}" "${base_url}/api/jobs/${approval_job_id}")"
    approval_job_status="$(jq -r '.status' <<<"${approval_result}")"
    if [[ "${approval_job_status}" != "queued" && "${approval_job_status}" != "running" ]]; then
        break
    fi
    sleep 0.2
done
jq -e '.status == "succeeded" and .result_status == "approval_required"
    and .result.ok == false
    and (.result.execution_state | type) == "object"' <<<"${approval_result}" >/dev/null

approval_state_pending="$(curl --noproxy '*' -sS -H "Authorization: Bearer ${token}" "${base_url}/api/session/state")"
jq -e \
    --argjson history_before "${approval_history_before}" \
    --argjson turns_before "${approval_turns_before}" '
    .history_count == $history_before
    and .turn_count == ($turns_before + 1)
    and .turns[-1].status == "approval_required"
    and .turns[-1].context_eligible == false
    and .turns[-1].history_merged_count == 0
' <<<"${approval_state_pending}" >/dev/null

approval_resume_payload="$(jq -cn \
    --arg input "帮我检查磁盘空间是否异常" \
    --argjson response "$(jq -c '.result.response' <<<"${approval_result}")" \
    --argjson context "$(jq -c '.result.context' <<<"${approval_result}")" \
    --argjson execution_state "$(jq -c '.result.execution_state' <<<"${approval_result}")" '
    {
        resource:"work",
        action:"run",
        payload:{
            input:$input,
            response:$response,
            context:$context,
            execution_state:$execution_state,
            decisions:["y"]
        }
    }
')"
approval_resume_job="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${approval_resume_payload}" \
    "${base_url}/api/jobs")"
approval_resume_job_id="$(jq -r '.job_id' <<<"${approval_resume_job}")"
for _ in $(seq 1 "${job_poll_attempts}"); do
    approval_resume_result="$(curl --noproxy '*' -sS -H "Authorization: Bearer ${token}" "${base_url}/api/jobs/${approval_resume_job_id}")"
    approval_resume_status="$(jq -r '.status' <<<"${approval_resume_result}")"
    if [[ "${approval_resume_status}" != "queued" && "${approval_resume_status}" != "running" ]]; then
        break
    fi
    sleep 0.2
done
jq -e '.status == "succeeded" and .result_status == "executed" and .result_ok == true' <<<"${approval_resume_result}" >/dev/null

approval_state_final="$(curl --noproxy '*' -sS -H "Authorization: Bearer ${token}" "${base_url}/api/session/state")"
jq -e \
    --argjson history_before "${approval_history_before}" \
    --argjson turns_before "${approval_turns_before}" '
    .history_count > $history_before
    and .turn_count == ($turns_before + 2)
    and .turns[-2].status == "approval_required"
    and .turns[-2].context_eligible == false
    and .turns[-1].status == "executed"
    and .turns[-1].context_eligible == true
    and .turns[-1].history_merged_count > 0
' <<<"${approval_state_final}" >/dev/null

# SQLite(WAL) job store is the durable backend.
[[ -f "${project}/tmp/web/jobs.db" ]]
python3 - "${project}/tmp/web/jobs.db" <<'PY'
import os
import sqlite3
import stat
import sys

required = {
    "job_id", "status", "resource", "action", "version", "created_at",
    "started_at", "finished_at", "updated_at", "idempotency_key",
    "request_id", "session_id", "payload", "result", "partial_output",
    "result_ok", "result_status",
}
connection = sqlite3.connect(sys.argv[1])
try:
    assert connection.execute("PRAGMA journal_mode").fetchone()[0].lower() == "wal"
    columns = {row[1] for row in connection.execute("PRAGMA table_info(jobs)")}
    indexes = {row[1] for row in connection.execute("PRAGMA index_list(jobs)")}
finally:
    connection.close()
assert required <= columns, sorted(required - columns)
assert {"idx_jobs_status", "idx_jobs_updated_at", "idx_jobs_idempotency_key"} <= indexes
assert stat.S_IMODE(os.stat(sys.argv[1]).st_mode) == 0o600
PY

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

# Reuse the same database across a Web process restart. Startup recovery must
# transactionally fail every queued/running record left by the previous run.
PYTHONPATH="${project}/web" python3 - "${project}/tmp/web/jobs.db" <<'PY'
import sys
from jobs import JobStore, now_iso

store = JobStore(sys.argv[1])
for job_id, status in (("deadbeef01", "queued"), ("deadbeef02", "running")):
    now = now_iso()
    store.create({
        "ok": True,
        "job_id": job_id,
        "resource": "terminal",
        "action": "run",
        "status": status,
        "version": 0,
        "created_at": now,
        "updated_at": now,
        "request_id": f"req-{job_id}",
        "session_id": f"job_{job_id}",
        "payload": {"command": "never-ran"},
        "result": None,
        "result_ok": None,
        "result_status": None,
    })
PY

(cd "${project}" && bash bin/agent-web >"${tmp_root}/server-restart.out" 2>"${tmp_root}/server-restart.err") &
server_pid="$!"
for _ in $(seq 1 60); do
    if curl --noproxy '*' -sS -H "Authorization: Bearer ${token}" "${base_url}/api/health" >/dev/null 2>&1; then
        break
    fi
    sleep 0.2
done
for recovered_id in deadbeef01 deadbeef02; do
    recovered_job="$(curl --noproxy '*' -sS -H "Authorization: Bearer ${token}" "${base_url}/api/jobs/${recovered_id}")"
    jq -e '.status == "failed"
        and .version == 1
        and .result.status == "server_restarted"
        and .result_status == "server_restarted"
        and .result_ok == false' <<<"${recovered_job}" >/dev/null
done

restart_shutdown="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d '{}' \
    "${base_url}/api/server/shutdown")"
jq -e '.ok == true and .status == "shutting_down"' <<<"${restart_shutdown}" >/dev/null
timeout 5 tail --pid="${server_pid}" -f /dev/null >/dev/null 2>&1 || {
    printf 'restarted agent-web did not stop after shutdown request\n' >&2
    exit 1
}
wait "${server_pid}" 2>/dev/null || true
server_pid=""

printf 'web_server: ok\n'
