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
        "${ROOT_DIR}/web" \
        "${target}/"
    if [[ -f "${target}/mcp/context7/mcp.json" ]]; then
        tmp_manifest="$(mktemp)"
        jq '.enabled = false' "${target}/mcp/context7/mcp.json" > "${tmp_manifest}"
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
    "${project}/config/config.json" > "${tmp_config}"
mv "${tmp_config}" "${project}/config/config.json"
mkdir -p "${project}/mcp/stdio-web" "${project}/mcp/http-web" "${project}/mcp/sse-web"
cat > "${project}/mcp/stdio-web/mcp.json" <<JSON
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
cat > "${project}/mcp/http-web/mcp.json" <<'JSON'
{
  "id": "http-web",
  "name": "Web streamable server",
  "enabled": false,
  "transport": "streamable_http",
  "url": "https://example.com/mcp",
  "headers": {"Authorization": "Bearer web-secret-value"}
}
JSON
cat > "${project}/mcp/sse-web/mcp.json" <<'JSON'
{
  "id": "sse-web",
  "name": "Web SSE server",
  "enabled": false,
  "transport": "sse",
  "url": "https://example.com/sse",
  "message_url": "https://example.com/messages"
}
JSON

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
grep -q 'on("workInput", "keydown"' "${project}/web/static/app.js"
grep -q 'event.shiftKey' "${project}/web/static/app.js"
grep -q 'scrollActiveNavigationIntoView' "${project}/web/static/app.js"
grep -q 'overscroll-behavior-inline: contain' "${project}/web/static/styles.css"
grep -q 'grid-template-columns: 180px minmax(0, 1fr)' "${project}/web/static/styles.css"
grep -q '"Noto Sans CJK SC"' "${project}/web/static/styles.css"
grep -q 'flex: 0 0 44px' "${project}/web/static/styles.css"
grep -q 'env(safe-area-inset-bottom)' "${project}/web/static/styles.css"
grep -q '@media (prefers-reduced-motion: reduce)' "${project}/web/static/styles.css"
grep -q 'userOutputBlocks(blocks)' "${project}/web/static/app.js"
grep -q '低风险 Skill 自动运行' "${project}/web/static/modules/policy-config.js"
grep -q '低风险 Shell 自动运行' "${project}/web/static/modules/policy-config.js"
grep -q 'Work 自动续写' "${project}/web/static/modules/policy-config.js"
grep -q '文件匹配自动运行' "${project}/web/static/modules/policy-config.js"
grep -q '最小权限代理' "${project}/web/static/modules/policy-config.js"
grep -q '允许远程传输 API Key' "${project}/web/static/modules/policy-config.js"
grep -q 'materializeSkill' "${project}/web/static/app.js"
grep -q 'downloadRuntimeBackup' "${project}/web/static/app.js"
grep -q '开：' "${project}/web/static/app.js"
grep -q '关：' "${project}/web/static/app.js"
grep -q 'state.terminalSubmitting' "${project}/web/static/app.js"
grep -q 'session-turn' "${project}/web/static/app.js"
grep -q 'renderSharedExecutionOutput' "${project}/web/static/app.js"
grep -q 'work-plan-preview' "${project}/web/static/app.js"
grep -q 'prepareNewWorkRun' "${project}/web/static/app.js"
grep -q 'execution_state' "${project}/web/static/app.js"
grep -q 'data-config-model-fetch' "${project}/web/static/app.js"
grep -q 'loadMcpRegistry' "${project}/web/static/app.js"
grep -q 'type: "provider"' "${project}/web/static/modules/policy-config.js"
grep -q 'type: "model"' "${project}/web/static/modules/policy-config.js"
grep -q 'agent_loop_iteration_started' "${project}/web/static/modules/audit.js"
grep -q 'Agent 循环迭代开始' "${project}/web/static/modules/audit.js"
node "${ROOT_DIR}/tests/web_markdown.mjs"
mcp_nav_line="$(grep -n 'data-screen="mcp"' "${project}/web/static/index.html" | cut -d: -f1)"
skills_nav_line="$(grep -n 'data-screen="skills"' "${project}/web/static/index.html" | cut -d: -f1)"
policy_nav_line="$(grep -n 'data-screen="policy"' "${project}/web/static/index.html" | cut -d: -f1)"
[[ "${skills_nav_line}" -lt "${mcp_nav_line}" && "${mcp_nav_line}" -lt "${policy_nav_line}" ]]

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
    and .config.observer.privilege == "sudo_interactive"
    and .config.approvals.auto.skill_readonly == true
    and .config.approvals.auto.shell_readonly == false
    and .config.approvals.auto.file_patch == false
    and .config.remote.allow_api_key_transmission == false' <<<"${config_state}" >/dev/null

providers_state="$(curl --noproxy '*' -sS -H "Authorization: Bearer ${token}" "${base_url}/api/config/providers")"
jq -e '.ok == true and .status == "listed"
    and ([.providers[].id] | index("openai"))
    and ([.providers[].id] | index("openai_compatible"))
    and ([.providers[].id] | index("anthropic"))
    and ([.providers[] | select(.id == "openai_compatible") | .custom_url] | first) == true
    and ([.providers[] | select(.id == "openai") | .api_url] | first | endswith("/v1/chat/completions"))' <<<"${providers_state}" >/dev/null

model_key_value="test-model-fetch-key-12345"
models_payload="$(jq -cn \
    --arg provider "openai_compatible" \
    --arg api_url "${FAKE_AI_URL}" \
    --arg api_key "${model_key_value}" \
    '{provider:$provider, api_url:$api_url, api_key:$api_key}')"
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
for _ in $(seq 1 40); do
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
[[ "${slow_partial_seen}" == "1" ]]
for _ in $(seq 1 100); do
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
audit_query_payload="$(jq -cn --arg query "${web_work_session_id}" '{limit:1, query:$query}')"
audit_query_result="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${audit_query_payload}" \
    "${base_url}/api/audit/list")"
jq -e --arg session_id "${web_work_session_id}" '.ok == true and (.sessions | length) == 1 and .sessions[0].session_id == $session_id' <<<"${audit_query_result}" >/dev/null
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

mkdir -p "${project}/logs"
reflection_answer_log="${project}/logs/session_web_reflection_answer.jsonl"
printf '%s\n' \
    '{"timestamp":"2026-07-05T00:00:00Z","session_id":"session_web_reflection_answer","stage":"session_started","payload":{"request":"agent-web","entrypoint":"web"}}' \
    '{"timestamp":"2026-07-05T00:00:01Z","session_id":"session_web_reflection_answer","stage":"received","payload":{"mode":"work","input_preview":"fixture"}}' \
    '{"timestamp":"2026-07-05T00:00:02Z","session_id":"session_web_reflection_answer","stage":"planned","payload":{"response_type":"work_plan","summary_preview":"fixture plan","step_count":1,"steps":[{"id":"step-1","title":"fixture step","executor_type":"skill_script","skill_script":"ops-basic/resource-inspect","risk_level":"low"}]}}' \
    '{"timestamp":"2026-07-05T00:00:03Z","session_id":"session_web_reflection_answer","stage":"agent_reflection_planned","payload":{"response_type":"answer","summary_preview":"最终回答摘要: fixture complete","continue_decision":{"should_continue":false,"reason":"done"},"step_count":0,"steps":[]}}' \
    '{"timestamp":"2026-07-05T00:00:04Z","session_id":"session_web_reflection_answer","stage":"finished","payload":{"status":"executed"}}' \
    > "${reflection_answer_log}"
reflection_answer_payload="$(jq -cn '{session_id:"session_web_reflection_answer"}')"
reflection_answer_audit="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${reflection_answer_payload}" \
    "${base_url}/api/audit/read")"
jq -e '.ok == true
    and ([.web_timeline.output_blocks[]? | select(.kind == "markdown" and .title == "最终回答") | .text | contains("最终回答摘要")] | any)' <<<"${reflection_answer_audit}" >/dev/null

loop_coalesce_log="${project}/logs/session_web_loop_coalesce.jsonl"
printf '%s\n' \
    '{"timestamp":"2026-07-05T00:10:00Z","session_id":"session_web_loop_coalesce","stage":"session_started","payload":{"request":"agent-web","entrypoint":"web"}}' \
    '{"timestamp":"2026-07-05T00:10:01Z","session_id":"session_web_loop_coalesce","stage":"received","payload":{"mode":"work","input_preview":"loop fixture"}}' \
    '{"timestamp":"2026-07-05T00:10:02Z","session_id":"session_web_loop_coalesce","stage":"planned","payload":{"response_type":"work_plan","summary_preview":"first plan","step_count":1,"steps":[{"id":"step-1","title":"first step","executor_type":"skill_script","skill_script":"ops-basic/resource-inspect","risk_level":"low"}]}}' \
    '{"timestamp":"2026-07-05T00:10:03Z","session_id":"session_web_loop_coalesce","stage":"agent_loop_iteration_started","payload":{"iteration":1,"plan":{"response_type":"work_plan","summary":"first plan","steps":[{"id":"step-1","title":"first step","executor_type":"skill_script","skill_script":"ops-basic/resource-inspect","risk_level":"low"}]}}}' \
    '{"timestamp":"2026-07-05T00:10:04Z","session_id":"session_web_loop_coalesce","stage":"step_auto_approved","payload":{"status":"auto_approved","step":{"id":"step-1","title":"first step","executor_type":"skill_script","skill_script":"ops-basic/resource-inspect","risk_level":"low"},"detail":{"finding_count":0},"findings":[]}}' \
    '{"timestamp":"2026-07-05T00:10:05Z","session_id":"session_web_loop_coalesce","stage":"step_running","payload":{"status":"running","step":{"id":"step-1","title":"first step","executor_type":"skill_script","skill_script":"ops-basic/resource-inspect","risk_level":"low"},"detail":{},"findings":[]}}' \
    '{"timestamp":"2026-07-05T00:10:06Z","session_id":"session_web_loop_coalesce","stage":"step_succeeded","payload":{"status":"succeeded","step":{"id":"step-1","title":"first step","executor_type":"skill_script","skill_script":"ops-basic/resource-inspect","risk_level":"low"},"detail":{"ok":true,"exit_code":0,"output_preview":"first output"},"findings":[]}}' \
    '{"timestamp":"2026-07-05T00:10:07Z","session_id":"session_web_loop_coalesce","stage":"agent_reflection_planned","payload":{"response_type":"work_plan","summary_preview":"second plan","continue_decision":{"should_continue":true,"reason":"continue"},"step_count":1,"steps":[{"id":"step-2","title":"second step","executor_type":"skill_script","skill_script":"ops-basic/process-inspect","risk_level":"low"}]}}' \
    '{"timestamp":"2026-07-05T00:10:08Z","session_id":"session_web_loop_coalesce","stage":"agent_loop_iteration_started","payload":{"iteration":2,"plan":{"response_type":"work_plan","summary":"second plan","steps":[{"id":"step-2","title":"second step","executor_type":"skill_script","skill_script":"ops-basic/process-inspect","risk_level":"low"}]}}}' \
    '{"timestamp":"2026-07-05T00:10:09Z","session_id":"session_web_loop_coalesce","stage":"step_running","payload":{"status":"running","step":{"id":"step-2","title":"second step","executor_type":"skill_script","skill_script":"ops-basic/process-inspect","risk_level":"low"},"detail":{},"findings":[]}}' \
    '{"timestamp":"2026-07-05T00:10:10Z","session_id":"session_web_loop_coalesce","stage":"step_succeeded","payload":{"status":"succeeded","step":{"id":"step-2","title":"second step","executor_type":"skill_script","skill_script":"ops-basic/process-inspect","risk_level":"low"},"detail":{"ok":true,"exit_code":0,"output_preview":"second output"},"findings":[]}}' \
    '{"timestamp":"2026-07-05T00:10:11Z","session_id":"session_web_loop_coalesce","stage":"agent_reflection_planned","payload":{"response_type":"answer","summary_preview":"final answer","continue_decision":{"should_continue":false,"reason":"done"},"step_count":0,"steps":[]}}' \
    '{"timestamp":"2026-07-05T00:10:12Z","session_id":"session_web_loop_coalesce","stage":"agent_loop_finished","payload":{"status":"executed","stopped_reason":"done","iterations":2,"auto_executed_count":2}}' \
    '{"timestamp":"2026-07-05T00:10:13Z","session_id":"session_web_loop_coalesce","stage":"finished","payload":{"status":"executed"}}' \
    > "${loop_coalesce_log}"
loop_coalesce_payload="$(jq -cn '{session_id:"session_web_loop_coalesce"}')"
loop_coalesce_audit="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${loop_coalesce_payload}" \
    "${base_url}/api/audit/read")"
jq -e '.ok == true
    and ([.web_timeline.timeline[]? | select(.kind == "execution")] | length) == 2
    and ([.web_timeline.timeline[]? | select(.kind == "execution" and .step_id == "step-1")] | length) == 1
    and ([.web_timeline.timeline[]? | select(.kind == "execution" and .step_id == "step-1") | .status] | first) == "succeeded"
    and ([.web_timeline.timeline[]? | select(.kind == "execution" and .status == "auto_approved")] | length) == 0
    and (.web_timeline.turns | length) == 2
    and ([.web_timeline.turns[0].result.timeline[]? | select(.kind == "execution")] | length) == 1
    and ([.web_timeline.turns[1].result.timeline[]? | select(.kind == "execution")] | length) == 1
    and .web_timeline.turns[0].result.iteration == 1
    and .web_timeline.turns[1].result.iteration == 2' <<<"${loop_coalesce_audit}" >/dev/null

loop_restore_result="$(curl --noproxy '*' -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${loop_coalesce_payload}" \
    "${base_url}/api/session/restore")"
jq -e '.ok == true
    and .status == "restored"
    and .history_count == 2
    and .session.history_count == 2' <<<"${loop_restore_result}" >/dev/null

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
