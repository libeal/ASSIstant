#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=helpers.sh
source "${ROOT_DIR}/tests/helpers.sh"
linux_agent_test_install_failure_trap "web_api"

tmp_root="$(mktemp -d)"
cleanup() {
    stop_fake_ai_server
    rm -rf -- "${tmp_root}"
}
trap cleanup EXIT
start_fake_ai_server "$((23000 + RANDOM % 1000))" "${tmp_root}"

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
        "${ROOT_DIR}/schema" \
        "${ROOT_DIR}/skills" \
        "${ROOT_DIR}/mcp" \
        "${ROOT_DIR}/web" \
        "${target}/"
    if [[ -f "${target}/mcp/context7/mcp.json" ]]; then
        tmp_manifest="$(mktemp)"
        jq '.enabled = false' "${target}/mcp/context7/mcp.json" >"${tmp_manifest}"
        mv "${tmp_manifest}" "${target}/mcp/context7/mcp.json"
    fi
    configure_fake_ai "${target}"
}

health="$(
    linux_agent_test_capture "API health" 30 "${ROOT_DIR}" inherit \
        bash bin/agent api health
)"
jq -e '.ok == true and .web.host == "127.0.0.1"' <<<"${health}" >/dev/null

tools="$(
    linux_agent_test_capture "API tools list" 45 "${ROOT_DIR}" inherit \
        bash bin/agent api tools list
)"
jq -e '.ok == true and ([.scripts[].ref] | index("ops-basic/resource-inspect"))' <<<"${tools}" >/dev/null
jq -e '([.scripts[] | select(.skill == "network-ops-tools")] | length) == 25
    and ([.scripts[] | select(.skill == "network-ops-tools" and .risk == "low")] | length) == 0
    and ([.scripts[] | select(.ref == "network-ops-tools/ip-scanner") | .risk] | first) == "high"
    and ([.scripts[] | select(.ref == "network-ops-tools/subnet-calculator") | .risk] | first) == "medium"
    and ([.scripts[] | select(.ref == "network-ops-tools/tls-inspect") | .risk] | first) == "medium"
    and ([.scripts[] | select(.ref == "network-ops-tools/service-discovery") | .risk] | first) == "medium"' <<<"${tools}" >/dev/null

mcp_project="${tmp_root}/project-mcp-api"
copy_project "${mcp_project}"
cp -a "${ROOT_DIR}/third_party" "${mcp_project}/"
mkdir -p "${mcp_project}/mcp/stdio-api" "${mcp_project}/mcp/http-api" "${mcp_project}/mcp/sse-api"
cat >"${mcp_project}/mcp/stdio-api/mcp.json" <<JSON
{
  "id": "stdio-api",
  "name": "API stdio server",
  "transport": "stdio",
  "command": "python3",
  "args": ["${ROOT_DIR}/tests/fake_mcp_server.py", "stdio"],
  "env": {"SECRET_TOKEN": "api-secret-value"}
}
JSON
cat >"${mcp_project}/mcp/http-api/mcp.json" <<'JSON'
{
  "id": "http-api",
  "name": "API streamable HTTP server",
  "enabled": false,
  "transport": "streamable_http",
  "url": "https://example.com/mcp",
  "headers": {"Authorization": "Bearer api-secret-value"}
}
JSON
cat >"${mcp_project}/mcp/sse-api/mcp.json" <<'JSON'
{
  "id": "sse-api",
  "name": "API SSE server",
  "enabled": false,
  "transport": "sse",
  "url": "https://example.com/sse",
  "message_url": "https://example.com/messages"
}
JSON
mcp_list="$(
    linux_agent_test_capture "API MCP list" 45 "${mcp_project}" inherit \
        bash bin/agent api mcp list
)"
jq -e '.ok == true and .status == "listed"
    and ([.servers[].id] | index("stdio-api"))
    and ([.servers[].transport] | unique | sort) == ["sse","stdio","streamable_http"]
    and ([.servers[] | select(.id == "context7") | .enabled] | first) == false
    and ([.servers[] | select(.id == "http-api") | .enabled] | first) == false
    and ([.servers[] | select(.id == "stdio-api") | .config.env.SECRET_TOKEN] | first) == "[REDACTED]"' <<<"${mcp_list}" >/dev/null
if grep -q 'api-secret-value' <<<"${mcp_list}"; then
    printf 'mcp api list leaked secret material\n' >&2
    exit 1
fi
mcp_validate="$(
    linux_agent_test_capture "API MCP validate" 45 "${mcp_project}" inherit \
        bash bin/agent api mcp validate
)"
jq -e '.ok == true and .status == "validated" and .validation.ok == true
    and ([.validation.findings[].code] | sort) == ["MCP_INLINE_SECRET_DEPRECATED","MCP_SSE_DEPRECATED"]
    and all(.validation.findings[]; .severity == "low")' <<<"${mcp_validate}" >/dev/null
mcp_tools="$(
    linux_agent_test_capture "API MCP tools" 60 "${mcp_project}" inherit \
        bash bin/agent api mcp tools
)"
jq -e '.ok == true and .status == "listed"
    and .tool_count == 1
    and ([.tools[] | select(.server_id == "stdio-api" and .name == "echo") | .ref] | first) == "stdio-api/echo"
    and ([.servers[] | select(.id == "stdio-api") | .tool_count] | first) == 1' <<<"${mcp_tools}" >/dev/null
if grep -q 'api-secret-value' <<<"${mcp_tools}"; then
    printf 'mcp api tools leaked secret material\n' >&2
    exit 1
fi

project_work="${tmp_root}/project-work-api"
copy_project "${project_work}"
work_run="$(
    linux_agent_test_capture "API work run" 120 "${project_work}" discard \
        bash bin/agent api work run '{"input":"查看cpu占用"}'
)"
jq -e '.ok == true and .status == "executed"
    and ([.output_blocks[]? | select(.kind == "meta" and .title == "工作流摘要") | .json.auto_executed_count] | first) == 2
    and any(.timeline[]?;
        .kind == "execution"
        and .original_step_id == "load-ops-basic"
        and .status == "succeeded"
        and any(.output_blocks[]?;
            .kind == "json"
            and .json.status == "read"))
    and ([.timeline[]? | select(.kind == "execution") | .output_blocks[]? | select(.kind == "meta" and .title == "执行代理") | .json.requested_privilege] | first) == "least"' <<<"${work_run}" >/dev/null
jq -e '([.timeline[]? | select(.kind == "execution") | .output_blocks[]? | select(.kind == "json") | .json
    | select(.tool == "system.resource.inspect" and (.top_processes | length > 0))] | length) > 0' <<<"${work_run}" >/dev/null

continue_answer="$(
    linux_agent_test_capture "API slow output work" 120 "${project_work}" discard \
        bash bin/agent api work run '{"input":"慢速实时输出检查"}'
)"
jq -e '.ok == true and .status == "executed"
    and ([.output_blocks[]? | select(.kind == "markdown" and .title == "最终回答") | .text | contains("慢速实时检查已完成")] | any)
    and ([.output_blocks[]? | select(.kind == "meta" and .title == "工作流摘要") | .json.iterations] | first) == 2
    and ([.timeline[]? | select(.kind == "execution")] | length) == 2
    and any(.timeline[]?;
        .kind == "execution"
        and .original_step_id == "load-ops-basic"
        and .status == "succeeded"
        and any(.output_blocks[]?;
            .kind == "json"
            and .json.status == "read"))' <<<"${continue_answer}" >/dev/null

loop_run="$(
    linux_agent_test_capture "API iterative work" 150 "${project_work}" discard \
        bash bin/agent api work run '{"input":"查看cpu继续深入"}'
)"
jq -e '.ok == true and .status == "executed"
    and ([.output_blocks[]? | select(.kind == "meta" and .title == "工作流摘要") | .json.iterations] | first) == 3
    and ([.timeline[]? | select(.kind == "execution") | .iteration] | unique) == [1, 2, 3]
    and ([.timeline[]? | select(.kind == "execution") | .original_step_id]
        == ["load-ops-basic", "step-1", "reflect-1"])' <<<"${loop_run}" >/dev/null

approval_first="$(
    linux_agent_test_capture "API approval request" 120 "${project_work}" discard \
        bash bin/agent api work run '{"input":"帮我检查磁盘空间是否异常"}'
)"
jq -e '.ok == false and .status == "approval_required" and .response.response_type == "work_plan"
    and .approval_card.review.approval_required == true and .approval_card.step.id != ""
    and .execution_state.next_step_index == 1
    and (.execution_state.results | length) == 1' <<<"${approval_first}" >/dev/null
jq -e '([.timeline[]? | select(.kind == "execution") | .output_blocks[]? | select(.kind == "json") | .json
    | select(.tool == "system.disk.hotspots" and (.top_dirs | length > 0) and (.top_files | length > 0))] | length) > 0' <<<"${approval_first}" >/dev/null
approval_payload="$(
    jq -cn \
        --arg input "帮我检查磁盘空间是否异常" \
        --argjson response "$(jq -c '.response' <<<"${approval_first}")" \
        --argjson context "$(jq -c '.context' <<<"${approval_first}")" \
        --argjson execution_state "$(jq -c '.execution_state' <<<"${approval_first}")" \
        '{input:$input, response:$response, context:$context, execution_state:$execution_state, decisions:["y"]}'
)"
approval_second="$(
    linux_agent_test_capture "API approval resume" 120 "${project_work}" discard \
        bash bin/agent api work run "${approval_payload}"
)"
jq -e '.ok == true and .status == "executed" and .response.response_type == "work_plan"
    and ([.timeline[]? | select(.kind == "execution")] | length) == 3
    and any(.timeline[]?;
        .kind == "execution"
        and .original_step_id == "load-ops-basic"
        and .status == "succeeded"
        and any(.output_blocks[]?;
            .kind == "json"
            and .json.status == "read"))' <<<"${approval_second}" >/dev/null

network_steps="$(jq -cn '[
    {id:"net-ip-scanner", title:"IP scanner", executor_type:"skill_script", skill_script:"network-ops-tools/ip-scanner", arguments:{cidr:"127.0.0.1/32", ports:[1], timeout_ms:200}, reason:"regression", expected_effect:"scan loopback IP", risk_level:"low", rollback_hint:"none"},
    {id:"net-port-scanner", title:"Port scanner", executor_type:"skill_script", skill_script:"network-ops-tools/port-scanner", arguments:{target:"127.0.0.1", ports:[1], timeout_ms:200}, reason:"regression", expected_effect:"scan loopback port", risk_level:"low", rollback_hint:"none"},
    {id:"net-discovery", title:"Discovery protocol", executor_type:"skill_script", skill_script:"network-ops-tools/discovery-protocol", arguments:{interface:"lo", limit:5}, reason:"regression", expected_effect:"inspect discovery data", risk_level:"low", rollback_hint:"none"},
    {id:"net-wol", title:"Wake on LAN", executor_type:"skill_script", skill_script:"network-ops-tools/wake-on-lan", arguments:{mac:"00:11:22:33:44:55", dry_run:true}, reason:"regression", expected_effect:"plan WOL packet", risk_level:"low", rollback_hint:"none"},
    {id:"net-interface", title:"Network interface", executor_type:"skill_script", skill_script:"network-ops-tools/network-interface", arguments:{interface:"lo"}, reason:"regression", expected_effect:"inspect interface", risk_level:"low", rollback_hint:"none"},
    {id:"net-wifi", title:"WiFi", executor_type:"skill_script", skill_script:"network-ops-tools/wifi", arguments:{scan:false}, reason:"regression", expected_effect:"inspect wifi", risk_level:"low", rollback_hint:"none"},
    {id:"net-connections", title:"Connections", executor_type:"skill_script", skill_script:"network-ops-tools/connections", arguments:{limit:3}, reason:"regression", expected_effect:"inspect connections", risk_level:"low", rollback_hint:"none"},
    {id:"net-listeners", title:"Listeners", executor_type:"skill_script", skill_script:"network-ops-tools/listeners", arguments:{limit:3}, reason:"regression", expected_effect:"inspect listeners", risk_level:"low", rollback_hint:"none"},
    {id:"net-neighbor", title:"Neighbor table", executor_type:"skill_script", skill_script:"network-ops-tools/neighbor-table", arguments:{limit:3}, reason:"regression", expected_effect:"inspect neighbors", risk_level:"low", rollback_hint:"none"},
    {id:"net-ping", title:"Ping monitor", executor_type:"skill_script", skill_script:"network-ops-tools/ping-monitor", arguments:{target:"127.0.0.1", count:1, timeout_ms:500}, reason:"regression", expected_effect:"ping loopback", risk_level:"low", rollback_hint:"none"},
    {id:"net-traceroute", title:"Traceroute", executor_type:"skill_script", skill_script:"network-ops-tools/traceroute", arguments:{target:"127.0.0.1"}, reason:"regression", expected_effect:"trace loopback", risk_level:"low", rollback_hint:"none"},
    {id:"net-dns", title:"DNS lookup", executor_type:"skill_script", skill_script:"network-ops-tools/dns-lookup", arguments:{query:"localhost", record_type:"A"}, reason:"regression", expected_effect:"resolve localhost", risk_level:"low", rollback_hint:"none"},
    {id:"net-sntp", title:"SNTP lookup", executor_type:"skill_script", skill_script:"network-ops-tools/sntp-lookup", arguments:{server:"pool.ntp.org", dry_run:true}, reason:"regression", expected_effect:"plan SNTP lookup", risk_level:"low", rollback_hint:"none"},
    {id:"net-whois", title:"Whois", executor_type:"skill_script", skill_script:"network-ops-tools/whois", arguments:{query:"example.com", server:"whois.iana.org", dry_run:true}, reason:"regression", expected_effect:"plan whois lookup", risk_level:"low", rollback_hint:"none"},
    {id:"net-geo", title:"IP geolocation", executor_type:"skill_script", skill_script:"network-ops-tools/ip-geolocation", arguments:{ip:"8.8.8.8", dry_run:true}, reason:"regression", expected_effect:"plan IP geolocation", risk_level:"low", rollback_hint:"none"},
    {id:"net-hosts", title:"Hosts file editor", executor_type:"skill_script", skill_script:"network-ops-tools/hosts-file-editor", arguments:{action:"read"}, reason:"regression", expected_effect:"read hosts file", risk_level:"low", rollback_hint:"none"},
    {id:"net-lookup", title:"Lookup", executor_type:"skill_script", skill_script:"network-ops-tools/lookup", arguments:{category:"port", query:"443", protocol:"tcp"}, reason:"regression", expected_effect:"lookup port", risk_level:"low", rollback_hint:"none"},
    {id:"net-snmp", title:"SNMP", executor_type:"skill_script", skill_script:"network-ops-tools/snmp", arguments:{host:"127.0.0.1", oid:".1.3.6.1.2.1.1.1.0", dry_run:true}, reason:"regression", expected_effect:"plan SNMP query", risk_level:"low", rollback_hint:"none"},
    {id:"net-firewall", title:"Firewall", executor_type:"skill_script", skill_script:"network-ops-tools/firewall", arguments:{action:"status"}, reason:"regression", expected_effect:"inspect firewall", risk_level:"low", rollback_hint:"none"},
    {id:"net-subnet", title:"Subnet calculator", executor_type:"skill_script", skill_script:"network-ops-tools/subnet-calculator", arguments:{cidr:"192.168.1.0/24", new_prefix:26, limit:2}, reason:"regression", expected_effect:"calculate subnet", risk_level:"low", rollback_hint:"none"},
    {id:"net-bit", title:"Bit calculator", executor_type:"skill_script", skill_script:"network-ops-tools/bit-calculator", arguments:{values:["0b1010","0b1100"], operation:"and", width:8}, reason:"regression", expected_effect:"calculate bits", risk_level:"low", rollback_hint:"none"}
]')"
network_response="$(jq -cn --argjson steps "${network_steps}" '{
    response_type:"work_plan",
    summary:"network ops tools regression",
    steps:$steps,
    continue_decision:{should_continue:false, reason:"network ops regression complete"}
}')"
network_decisions="$(jq -cn '[range(0;21) | "y"]')"
network_payload="$(jq -cn --argjson response "${network_response}" --argjson decisions "${network_decisions}" '{input:"执行 network ops tools 回归", response:$response, decisions:$decisions}')"
network_work="$(
    linux_agent_test_capture "API network tools workflow" 240 "${project_work}" discard \
        bash bin/agent api work run "${network_payload}"
)"
jq -e '.ok == false and .status == "blocked" and .code == "skill_not_loaded"
    and (.error | contains("must be loaded through skill_load"))' \
    <<<"${network_work}" >/dev/null

network_tools='[]'
while IFS= read -r network_step; do
    network_ref="$(jq -r '.skill_script' <<<"${network_step}")"
    network_script_payload="$(jq -cn \
        --arg ref "${network_ref}" \
        --argjson arguments "$(jq -c '.arguments' <<<"${network_step}")" \
        '{ref:$ref,arguments:$arguments,approve:true}')"
    network_script_result="$(
        linux_agent_test_capture "API script ${network_ref}" 60 "${project_work}" discard \
            bash bin/agent api script run "${network_script_payload}"
    )"
    jq -e '.ok == true and .status == "executed"
        and any(.output_blocks[]?; .kind == "json" and (.json.tool | type) == "string")' \
        <<<"${network_script_result}" >/dev/null
    network_tool="$(jq -r \
        '[.output_blocks[]? | select(.kind == "json") | .json.tool // empty] | first // empty' \
        <<<"${network_script_result}")"
    network_tools="$(jq -cn --argjson prior "${network_tools}" --arg tool "${network_tool}" \
        '$prior + [$tool]')"
done < <(jq -c '.[]' <<<"${network_steps}")
jq -e 'length == 21 and (unique | length) == 21 and all(.[]; length > 0)' \
    <<<"${network_tools}" >/dev/null

project_missing="${tmp_root}/project-missing-ai"
copy_project "${project_missing}"
tmp_config="$(mktemp)"
jq 'del(.api_key) | del(.api_key_file)' "${project_missing}/config/config.json" >"${tmp_config}"
mv "${tmp_config}" "${project_missing}/config/config.json"
missing_ai="$(
    linux_agent_test_capture "API missing AI configuration" 45 "${project_missing}" discard \
        bash bin/agent api work run '{"input":"查看cpu占用"}'
)"
jq -e '.ok == false
    and .status == "ai_failed"
    and .code == "ai_config_missing"
    and .error_code == "ai_config_missing"
    and (.timeline | type) == "array"
    and .approval_card == null
    and (.output_blocks | type) == "array"' <<<"${missing_ai}" >/dev/null

script_review="$(
    linux_agent_test_capture "API script review" 45 "${ROOT_DIR}" inherit \
        bash bin/agent api script review \
        '{"ref":"ops-basic/resource-inspect","arguments":{"top_n":1}}'
)"
jq -e '.ok == true and .status == "approved" and .review.engine == "ast+rules" and .review.risk_level == "low" and (.output_blocks | length) > 0' <<<"${script_review}" >/dev/null

script_run="$(
    linux_agent_test_capture "API script run" 60 "${ROOT_DIR}" discard \
        bash bin/agent api script run \
        '{"ref":"ops-basic/resource-inspect","arguments":{"top_n":1},"approve":true}'
)"
jq -e '.ok == true and .status == "executed"
    and ([.output_blocks[]? | select(.kind == "json") | .json | select(.tool == "system.resource.inspect")] | length) > 0
    and ([.output_blocks[]? | select(.kind == "meta" and .title == "执行代理") | .json.requested_privilege] | first) == "least"' <<<"${script_run}" >/dev/null

network_script_review="$(
    linux_agent_test_capture "API network script review" 45 "${ROOT_DIR}" inherit \
        bash bin/agent api script review \
        '{"ref":"network-ops-tools/subnet-calculator","arguments":{"cidr":"192.168.1.0/24"}}'
)"
jq -e '.ok == true and .status == "approval_required"
    and .review.risk_level == "medium"
    and ([.review.findings[]? | select(.code == "SKILL_DECLARED_RISK")] | length) == 1' <<<"${network_script_review}" >/dev/null

network_script_run="$(
    linux_agent_test_capture "API network script run" 60 "${ROOT_DIR}" discard \
        bash bin/agent api script run \
        '{"ref":"network-ops-tools/subnet-calculator","arguments":{"cidr":"192.168.1.0/24"},"approve":true}'
)"
jq -e '.ok == true and .status == "executed"
    and ([.output_blocks[]? | select(.kind == "json") | .json | select(.tool == "network.ops.subnet-calculator")] | length) > 0' <<<"${network_script_run}" >/dev/null

terminal_review_low="$(
    linux_agent_test_capture "API terminal low-risk review" 30 "${ROOT_DIR}" inherit \
        bash bin/agent api terminal review '{"command":"printf api-ok"}'
)"
jq -e '.ok == true and .status == "approval_required" and .review.risk_level == "low"
    and .review.approval_required == true
    and ([.review.findings[]? | select(.code == "SHELL_AUTO_APPROVAL_DISABLED")] | length) == 1
    and .approval_card.type == "terminal"' <<<"${terminal_review_low}" >/dev/null

terminal_run_requires_approval="$(
    linux_agent_test_capture "API terminal approval required" 30 \
        "${ROOT_DIR}" discard bash bin/agent api terminal run '{"command":"printf api-ok"}'
)"
jq -e '.ok == false and .status == "approval_required" and .approval_card.type == "terminal"' <<<"${terminal_run_requires_approval}" >/dev/null

terminal_run="$(
    linux_agent_test_capture "API terminal run" 60 "${ROOT_DIR}" discard \
        bash bin/agent api terminal run '{"command":"printf api-ok","approve":true}'
)"
jq -e '.ok == true
    and ([.output_blocks[]? | select(.kind == "stdout") | .text] | first) == "api-ok"
    and ([.output_blocks[]? | select(.kind == "meta" and .title == "执行代理") | .json.requested_privilege] | first) == "least"' <<<"${terminal_run}" >/dev/null

terminal_review="$(
    linux_agent_test_capture "API high-risk terminal review" 30 "${ROOT_DIR}" inherit \
        bash bin/agent api terminal review '{"command":"sudo systemctl restart nginx"}'
)"
jq -e '.ok == true and .status == "approval_required" and .review.risk_level == "high" and .approval_card.type == "terminal"' <<<"${terminal_review}" >/dev/null

terminal_approval_required="$(
    linux_agent_test_capture "API high-risk approval required" 30 \
        "${ROOT_DIR}" discard bash bin/agent api terminal run \
        '{"command":"sudo systemctl restart nginx"}'
)"
jq -e '.ok == false and .status == "approval_required" and .approval_card.type == "terminal"' <<<"${terminal_approval_required}" >/dev/null

project_edit="${tmp_root}/project-edit-api"
copy_project "${project_edit}"
edit_plan="$(
    linux_agent_test_capture "API edit plan" 120 "${project_edit}" discard \
        bash bin/agent api edit plan '{"input":"创建一个 API 测试 skill"}'
)"
edit_json="$(jq -c '.edit' <<<"${edit_plan}")"
review_payload="$(jq -cn --argjson edit "${edit_json}" '{edit:$edit}')"
edit_review="$(
    linux_agent_test_capture "API edit review" 60 "${project_edit}" inherit \
        bash bin/agent api edit review "${review_payload}"
)"
jq -e '.ok == true and .status == "approved"' <<<"${edit_review}" >/dev/null

apply_payload="$(jq -cn --argjson edit "${edit_json}" '{edit:$edit, approve:true}')"
edit_apply="$(
    linux_agent_test_capture "API edit apply" 120 "${project_edit}" discard \
        bash bin/agent api edit apply "${apply_payload}"
)"
jq -e '.ok == true and .status == "edited"' <<<"${edit_apply}" >/dev/null
grep -q 'generated skill placeholder' "${project_edit}/data/skills/custom-generated/scripts/generated.sh"

invalid_edit="$(
    linux_agent_test_capture "API invalid edit response" 60 "${project_edit}" discard \
        bash bin/agent api edit plan '{"input":"无效响应"}'
)"
jq -e '.ok == false and .status == "ai_invalid_response"' <<<"${invalid_edit}" >/dev/null

audit_list="$(
    linux_agent_test_capture "API audit list" 45 "${ROOT_DIR}" inherit \
        bash bin/agent api audit list '{"limit":5}'
)"
jq -e '.ok == true and (.sessions | type == "array")' <<<"${audit_list}" >/dev/null

large_audit_project="${tmp_root}/project-large-audit"
copy_project "${large_audit_project}"
mkdir -p "${large_audit_project}/logs"
large_log="${large_audit_project}/logs/session_large_api_read.jsonl"
printf '{"timestamp":"2026-07-05T00:00:00Z","session_id":"session_large_api_read","stage":"session_started","payload":{"request":"large","entrypoint":"web"}}\n' >"${large_log}"
for index in $(seq 1 420); do
    printf '{"timestamp":"2026-07-05T00:00:01Z","session_id":"session_large_api_read","stage":"step_succeeded","payload":{"status":"succeeded","step":{"id":"step-%s","title":"Large output step %s","executor_type":"shell","command_preview":"printf line-%s"},"detail":{"ok":true,"exit_code":0,"output_preview":"line-%s repeated payload for audit read regression"}}}\n' "${index}" "${index}" "${index}" "${index}" >>"${large_log}"
done
printf '{"timestamp":"2026-07-05T00:00:02Z","session_id":"session_large_api_read","stage":"session_finished","payload":{"status":"executed"}}\n' >>"${large_log}"
large_audit_read="$(
    linux_agent_test_capture "API large audit read" 90 \
        "${large_audit_project}" inherit bash bin/agent api audit read \
        '{"session_id":"session_large_api_read"}'
)"
jq -e '.ok == true and .status == "read" and (.events | length) == 422 and (.report | contains("session_large_api_read"))' <<<"${large_audit_read}" >/dev/null

history_project="${tmp_root}/project-history-skill"
copy_project "${history_project}"
mkdir -p "${history_project}/logs"
cat >"${history_project}/logs/session_history_fixture.jsonl" <<'JSONL'
{"timestamp":"2026-07-05T00:00:00Z","session_id":"session_history_fixture","stage":"session_started","payload":{"request":"fixture","entrypoint":"web"}}
{"timestamp":"2026-07-05T00:00:01Z","session_id":"session_history_fixture","stage":"received","payload":{"mode":"terminal","command":"printf previous-output"}}
{"timestamp":"2026-07-05T00:00:02Z","session_id":"session_history_fixture","stage":"terminal_executed","payload":{"status":"executed","exit_code":0,"output_preview":"previous-output","stderr_preview":""}}
{"timestamp":"2026-07-05T00:00:03Z","session_id":"session_history_fixture","stage":"finished","payload":{"status":"executed"}}
JSONL
history_read="$(
    linux_agent_test_capture "API session history" 60 "${history_project}" discard \
        bash bin/agent api script run \
        '{"ref":"session-history/last-command-output","arguments":{"session_id":"session_history_fixture","turn_offset":0},"approve":true}'
)"
jq -e '.ok == true and .status == "executed"
    and ([.output_blocks[]? | select(.kind == "json") | .json
      | select(.tool == "session.history.last-command-output" and .turn.input == "printf previous-output" and (.outputs[0].output_preview == "previous-output"))] | length) == 1' <<<"${history_read}" >/dev/null

printf 'web_api: ok\n'
