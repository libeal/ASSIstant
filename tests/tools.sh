#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="${ROOT_DIR}/skills/ops-basic/scripts"
CONTROLLED_SCRIPT_DIR="${ROOT_DIR}/skills/controlled-tools/scripts"
NETWORK_SCRIPT_DIR="${ROOT_DIR}/skills/network-ops-tools/scripts"

python3 "${ROOT_DIR}/tests/network_ops_unit.py"

disk_result="$(bash "${SCRIPT_DIR}/disk-hotspots.sh" '{"path":"/var","top_n":3}')"
resource_result="$(bash "${SCRIPT_DIR}/resource-inspect.sh" '{"top_n":3}')"
process_result="$(bash "${SCRIPT_DIR}/process-inspect.sh" '{"pattern":"systemd"}')"
cleanup_result="$(bash "${SCRIPT_DIR}/safe-log-cleanup.sh" '{"path":"/etc/passwd","dry_run":true}')"
cleanup_plan_result="$(bash "${SCRIPT_DIR}/log-cleanup-plan.sh" '{"root_path":"/etc","min_size_mb":1}')"
cleanup_plan_bad_number="$(bash "${SCRIPT_DIR}/log-cleanup-plan.sh" '{"root_path":"/tmp","min_size_mb":"abc"}')"
restart_plan_result="$(bash "${SCRIPT_DIR}/service-restart-plan.sh" '{"service":"sshd"}')"
log_search_reject="$(bash "${SCRIPT_DIR}/log-search.sh" "{\"path\":\"${ROOT_DIR}/README.md\",\"keyword\":\"Linux\",\"lines\":1}")"
log_search_no_journal="$(bash "${SCRIPT_DIR}/log-search.sh" '{"path":"/var/log","keyword":"__unlikely_linux_agent_test_keyword__","lines":1,"include_journal":false}')"

controlled_file="$(mktemp /tmp/linux-agent-controlled-file.XXXXXX)"
printf 'alpha\nneedle\nomega\n' >"${controlled_file}"
controlled_link="${controlled_file}.link"
ln -s "${controlled_file}" "${controlled_link}"
match_result="$(bash "${CONTROLLED_SCRIPT_DIR}/file-match.sh" "$(jq -cn --arg path "${controlled_file}" '{path:$path, find:"needle", context_lines:1}')")"
patch_preview="$(bash "${CONTROLLED_SCRIPT_DIR}/file-patch.sh" "$(jq -cn --arg path "${controlled_file}" '{path:$path, find:"needle", replacement:"patched", expected_count:1, apply:false}')")"
patch_result="$(bash "${CONTROLLED_SCRIPT_DIR}/file-patch.sh" "$(jq -cn --arg path "${controlled_file}" '{path:$path, find:"needle", replacement:"patched", expected_count:1, backup:true}')")"
patched_content="$(cat "${controlled_file}")"
patch_mismatch="$(bash "${CONTROLLED_SCRIPT_DIR}/file-patch.sh" "$(jq -cn --arg path "${controlled_file}" '{path:$path, find:"patched", replacement:"again", expected_count:2}')")"
after_mismatch_content="$(cat "${controlled_file}")"
analyze_result="$(bash "${CONTROLLED_SCRIPT_DIR}/local-analyze.sh" '{"text":"ok\nfailed to start\nwarning: slow"}')"
match_symlink="$(bash "${CONTROLLED_SCRIPT_DIR}/file-match.sh" "$(jq -cn --arg path "${controlled_link}" '{path:$path, find:"patched"}')")"
patch_symlink="$(bash "${CONTROLLED_SCRIPT_DIR}/file-patch.sh" "$(jq -cn --arg path "${controlled_link}" '{path:$path, find:"patched", replacement:"again", expected_count:1}')")"
analyze_symlink="$(bash "${CONTROLLED_SCRIPT_DIR}/local-analyze.sh" "$(jq -cn --arg path "${controlled_link}" '{path:$path}')")"
download_unsafe="$(bash "${CONTROLLED_SCRIPT_DIR}/file-download.sh" '{"url":"http://example.com/file","output_path":"/tmp/linux-agent-download-test"}')"
rm -f "${controlled_file}" "${controlled_link}" "${controlled_file}".bak.*

run_network_tool() {
    local script="$1"
    local args="$2"
    local result
    result="$(bash "${NETWORK_SCRIPT_DIR}/${script}.sh" "${args}")"
    jq -e --arg tool "network.ops.${script}" '
        .ok == true
        and .tool == $tool
        and (.risk == "medium" or .risk == "high")
    ' <<<"${result}" >/dev/null
}

run_network_tool ip-scanner "$(jq -cn '{cidr:"127.0.0.1/32", ports:[1], timeout_ms:200}')"
run_network_tool port-scanner "$(jq -cn '{target:"127.0.0.1", ports:[1], timeout_ms:200}')"
run_network_tool discovery-protocol "$(jq -cn '{interface:"lo", limit:5}')"
run_network_tool wake-on-lan "$(jq -cn '{mac:"00:11:22:33:44:55", dry_run:true}')"
run_network_tool network-interface "$(jq -cn '{interface:"lo"}')"
run_network_tool wifi "$(jq -cn '{scan:false}')"
run_network_tool connections "$(jq -cn '{limit:3}')"
run_network_tool listeners "$(jq -cn '{limit:3}')"
run_network_tool neighbor-table "$(jq -cn '{limit:3}')"
run_network_tool ping-monitor "$(jq -cn '{target:"127.0.0.1", count:1, timeout_ms:500}')"
run_network_tool traceroute "$(jq -cn '{target:"127.0.0.1"}')"
run_network_tool dns-lookup "$(jq -cn '{query:"localhost", record_type:"A"}')"
run_network_tool sntp-lookup "$(jq -cn '{server:"pool.ntp.org", dry_run:true}')"
run_network_tool whois "$(jq -cn '{query:"example.com", server:"whois.iana.org", dry_run:true}')"
run_network_tool ip-geolocation "$(jq -cn '{ip:"8.8.8.8", dry_run:true}')"
run_network_tool hosts-file-editor "$(jq -cn '{action:"read"}')"
run_network_tool lookup "$(jq -cn '{category:"port", query:"443", protocol:"tcp"}')"
run_network_tool snmp "$(jq -cn '{host:"127.0.0.1", oid:".1.3.6.1.2.1.1.1.0", dry_run:true}')"
run_network_tool firewall "$(jq -cn '{action:"status"}')"
run_network_tool subnet-calculator "$(jq -cn '{cidr:"192.168.1.0/24", new_prefix:26, limit:2}')"
run_network_tool bit-calculator "$(jq -cn '{values:["0b1010","0b1100"], operation:"and", width:8}')"
run_network_tool tls-inspect "$(jq -cn '{host:"127.0.0.1", dry_run:true}')"
run_network_tool http-check "$(jq -cn '{url:"https://example.com", dry_run:true}')"
run_network_tool public-ip "$(jq -cn '{method:"stun", dry_run:true}')"
run_network_tool service-discovery "$(jq -cn '{protocol:"ssdp", dry_run:true}')"

# Field-level assertions (offline: dry-run / pure-compute / loopback) guarding the
# structured output — these fail if parsing or calculation regresses, unlike the
# envelope-only run_network_tool checks above.
assert_network_field() {
    local script="$1" args="$2" filter="$3" result
    result="$(bash "${NETWORK_SCRIPT_DIR}/${script}.sh" "${args}")"
    if ! jq -e "${filter}" <<<"${result}" >/dev/null; then
        printf 'network field assertion failed: %s %s\n  filter: %s\n  result: %s\n' "${script}" "${args}" "${filter}" "${result}" >&2
        exit 1
    fi
}

# subnet-calculator: true supernet (was a silent no-op), aggregation, membership, wildcard, reverse zone
assert_network_field subnet-calculator '{"cidr":"10.0.0.0/24","new_prefix":22}' '.result.operation == "supernet" and .result.supernet == "10.0.0.0/22"'
assert_network_field subnet-calculator '{"aggregate":["10.0.0.0/24","10.0.1.0/24"]}' '.status == "aggregated" and .aggregated == ["10.0.0.0/23"]'
assert_network_field subnet-calculator '{"cidr":"192.168.1.0/24","contains":"192.168.1.9"}' '.result.wildcard == "0.0.0.255" and .result.contains.in_network == true and .result.reverse_zone == "1.168.192.in-addr.arpa" and .result.ip_class == "C"'
# bit-calculator: rotate, bit test, signed/popcount
assert_network_field bit-calculator '{"value":"0x81","operation":"rol","shift":1,"width":8}' '.result.decimal == 3 and .result.hex == "0x03"'
assert_network_field bit-calculator '{"value":255,"operation":"testbit","index":0,"width":8}' '.bit_set == true'
assert_network_field bit-calculator '{"value":255,"width":8}' '.inputs[0].signed == -1 and .inputs[0].popcount == 8'
# snmp: named-OID resolution, walk action, v3 auth level, authPriv rejection
assert_network_field snmp '{"host":"127.0.0.1","version":"3","user":"u","auth_password":"p","action":"walk","oids":["sysName"],"dry_run":true}' '.action == "walk" and .oids == [".1.3.6.1.2.1.1.5.0"] and .v3_level == "authNoPriv"'
assert_network_field snmp '{"host":"127.0.0.1","version":"3","user":"u","priv_password":"x","dry_run":true}' '.ok == false and .status == "unsupported"'
# lookup: protocol number and ICMP type tables
assert_network_field lookup '{"category":"protocol","query":"tcp"}' '.results[0].number == 6'
assert_network_field lookup '{"category":"icmp","query":"0"}' '.results[0].name == "echo-reply"'
# dns-lookup: multi record-type request shape
assert_network_field dns-lookup '{"query":"localhost","record_types":["A"]}' '.record_types == ["A"] and (.records | type) == "array"'
# traceroute loopback: structured hop
assert_network_field traceroute '{"target":"127.0.0.1"}' '.hops[0].addresses == ["127.0.0.1"]'
# ping-monitor: per-probe sample series present
assert_network_field ping-monitor '{"target":"127.0.0.1","count":1,"timeout_ms":500}' '(.samples | type) == "array"'
# connections/listeners: structured parse (address/port split + summary object)
assert_network_field connections '{"limit":200}' '(.connections | type) == "array" and (.summary | type) == "object"'
assert_network_field listeners '{"limit":200}' '(.listeners | type) == "array" and (.summary | type) == "object"'
# firewall: multi-backend plan
assert_network_field firewall '{"action":"plan","rule":{"decision":"allow","protocol":"tcp","port":8080}}' '(.commands.iptables | type) == "array" and (.commands.firewalld | type) == "array"'
# wake-on-lan: SecureON extends the magic packet (102 + 6 bytes)
assert_network_field wake-on-lan '{"mac":"001122334455","secure_on":"aabbccddeeff","dry_run":true}' '.packet_bytes == 108 and .secure_on == true'
# whois: IP query routes to IANA as the referral entry point
assert_network_field whois '{"query":"1.1.1.1","dry_run":true}' '.server == "whois.iana.org"'
# new tools dry-run planning path
assert_network_field tls-inspect '{"host":"example.com","dry_run":true}' '.status == "planned" and .port == 443'
assert_network_field http-check '{"url":"https://example.com","dry_run":true}' '.status == "planned"'
assert_network_field public-ip '{"method":"stun","dry_run":true}' '.status == "planned"'
assert_network_field service-discovery '{"protocol":"mdns","dry_run":true}' '.status == "planned"'
# hosts-file-editor: merge/dedupe on a temporary file (plan only, no apply)
hosts_tmp="$(mktemp /tmp/linux-agent-hosts.XXXXXX)"
printf '127.0.0.1\tlocalhost\n10.0.0.5\tapp\n' >"${hosts_tmp}"
assert_network_field hosts-file-editor "$(jq -cn --arg p "${hosts_tmp}" '{path:$p, allow_custom_path:true, action:"plan-add", ip:"10.0.0.5", hostnames:["web"], merge:true}')" '.note == "merged into existing entry" and (.line | test("app web"))'
rm -f "${hosts_tmp}"

cleanup_file="$(mktemp /tmp/linux-agent-tools-cleanup.XXXXXX)"
printf '0123456789' >"${cleanup_file}"
cleanup_false_result="$(bash "${SCRIPT_DIR}/safe-log-cleanup.sh" "$(jq -cn --arg path "${cleanup_file}" '{path:$path, max_size_mb:0, dry_run:false}')")"
cleanup_false_size="$(stat -c '%s' "${cleanup_file}")"
rm -f "${cleanup_file}"

cleanup_bad_number_file="$(mktemp /tmp/linux-agent-tools-bad-number.XXXXXX)"
printf 'data' >"${cleanup_bad_number_file}"
cleanup_bad_number_result="$(bash "${SCRIPT_DIR}/safe-log-cleanup.sh" "$(jq -cn --arg path "${cleanup_bad_number_file}" '{path:$path, max_size_mb:"abc"}')")"
rm -f "${cleanup_bad_number_file}"

cleanup_target="$(mktemp /tmp/linux-agent-tools-target.XXXXXX)"
cleanup_link="$(mktemp -u /tmp/linux-agent-tools-link.XXXXXX)"
printf 'keep-me' >"${cleanup_target}"
ln -s "${cleanup_target}" "${cleanup_link}"
cleanup_symlink_result="$(bash "${SCRIPT_DIR}/safe-log-cleanup.sh" "$(jq -cn --arg path "${cleanup_link}" '{path:$path, max_size_mb:0, dry_run:false}')")"
cleanup_target_size="$(stat -c '%s' "${cleanup_target}")"
rm -f "${cleanup_link}" "${cleanup_target}"

tmp_link="$(mktemp -u)"
ln -s "${ROOT_DIR}/README.md" "${tmp_link}"
log_search_symlink="$(bash "${SCRIPT_DIR}/log-search.sh" "{\"path\":\"${tmp_link}\",\"keyword\":\"Linux\",\"lines\":1}")"
rm -f "${tmp_link}"

grep -q '"ok": true' <<<"$(jq . <<<"${disk_result}")"
grep -q '"tool": "system.resource.inspect"' <<<"$(jq . <<<"${resource_result}")"
grep -q '"tool": "system.process.inspect"' <<<"$(jq . <<<"${process_result}")"
grep -q '"ok": false' <<<"$(jq . <<<"${cleanup_result}")"
grep -q '"tool": "system.logs.cleanup_plan"' <<<"$(jq . <<<"${cleanup_plan_result}")"
grep -q '"ok": false' <<<"$(jq . <<<"${cleanup_plan_result}")"
grep -q '"ok": false' <<<"$(jq . <<<"${cleanup_plan_bad_number}")"
grep -q 'min_size_mb 必须是正整数' <<<"${cleanup_plan_bad_number}"
grep -q '"action": "truncate"' <<<"$(jq . <<<"${cleanup_false_result}")"
[[ "${cleanup_false_size}" -eq 0 ]]
grep -q '"ok": false' <<<"$(jq . <<<"${cleanup_bad_number_result}")"
grep -q 'max_size_mb 必须是非负整数' <<<"${cleanup_bad_number_result}"
grep -q '"ok": false' <<<"$(jq . <<<"${cleanup_symlink_result}")"
grep -q '拒绝清理符号链接' <<<"${cleanup_symlink_result}"
[[ "${cleanup_target_size}" -gt 0 ]]
grep -q '"risk": "high"' <<<"$(jq . <<<"${restart_plan_result}")"
grep -q '"ok": false' <<<"$(jq . <<<"${log_search_reject}")"
grep -q '仅允许检索 /var/log' <<<"${log_search_reject}"
grep -q '"ok": false' <<<"$(jq . <<<"${log_search_symlink}")"
grep -q '"include_journal": false' <<<"$(jq . <<<"${log_search_no_journal}")"
grep -q '"journal_sample": ""' <<<"$(jq . <<<"${log_search_no_journal}")"
grep -q '"tool": "controlled.file.match"' <<<"$(jq . <<<"${match_result}")"
jq -e '.ok == true and .match_count == 1 and .matches[0].line == 2' <<<"${match_result}" >/dev/null
jq -e '.ok == true and .status == "previewed" and (.diff | contains("patched"))' <<<"${patch_preview}" >/dev/null
jq -e '.ok == true and .status == "patched" and .backup_path != null' <<<"${patch_result}" >/dev/null
grep -q 'patched' <<<"${patched_content}"
jq -e '.ok == false and .status == "count_mismatch"' <<<"${patch_mismatch}" >/dev/null
[[ "${after_mismatch_content}" == "${patched_content}" ]]
jq -e '.ok == true and .tool == "controlled.local.analyze" and (.keyword_samples | length) == 2' <<<"${analyze_result}" >/dev/null
jq -e '.ok == false and .status == "unsupported_path"' <<<"${match_symlink}" >/dev/null
jq -e '.ok == false and .status == "unsupported_path"' <<<"${patch_symlink}" >/dev/null
jq -e '.ok == false and .status == "unsupported_path"' <<<"${analyze_symlink}" >/dev/null
jq -e '.ok == false and .status == "unsafe_url"' <<<"${download_unsafe}" >/dev/null

source "${ROOT_DIR}/lib/common.sh"
source "${ROOT_DIR}/lib/config.sh"
source "${ROOT_DIR}/lib/policy.sh"
source "${ROOT_DIR}/lib/skills.sh"
source "${ROOT_DIR}/lib/mcp.sh"
source "${ROOT_DIR}/lib/doctor.sh"
linux_agent_init_env "${ROOT_DIR}"
linux_agent_load_config
doctor_json="$(linux_agent_doctor)"
grep -q '"skills_ok": true' <<<"$(jq . <<<"${doctor_json}")"
skills_json="$(linux_agent_validate_skills)"
grep -q '"ok": true' <<<"$(jq . <<<"${skills_json}")"
disk_skill_context="$(linux_agent_skill_context_json "检查磁盘和日志占用" work)"
jq -e '(.disclosed | map(.name)) == ["ops-basic"]
    and .disclosure == "triggered_instructions"
    and (.disclosed[0].instructions | contains("# Ops Basic"))' <<<"${disk_skill_context}" >/dev/null
network_skill_context="$(linux_agent_skill_context_json "检查网络连接与端口" work)"
jq -e '([.disclosed[].name] | index("network-ops-tools"))
    and ([.disclosed[].name] | index("os-deep-inspect"))
    and ([.disclosed[].name] | index("ops-basic") | not)' <<<"${network_skill_context}" >/dev/null
file_skill_context="$(linux_agent_skill_context_json "用 controlled-tools/file-patch 修改文件" work)"
jq -e '([.disclosed[].name] | index("controlled-tools"))' <<<"${file_skill_context}" >/dev/null
resource_skill_result="$(linux_agent_run_skill_script ops-basic/resource-inspect '{"top_n":3}')"
resource_skill_string_arg_result="$(linux_agent_run_skill_script ops-basic/resource-inspect "$(jq -cn --arg args '{"top_n":2}' '$args')")"
process_skill_result="$(linux_agent_run_skill_script ops-basic/process-inspect '{"pattern":"systemd"}')"
controlled_skill_result="$(linux_agent_run_skill_script controlled-tools/file-match "$(jq -cn --arg path "${ROOT_DIR}/README.md" '{path:$path, find:"Linux", max_matches:1}')")"
grep -q '"tool": "system.resource.inspect"' <<<"$(jq . <<<"${resource_skill_result}")"
grep -q '"tool": "system.resource.inspect"' <<<"$(jq . <<<"${resource_skill_string_arg_result}")"
grep -q '"tool": "system.process.inspect"' <<<"$(jq . <<<"${process_skill_result}")"
grep -q '"tool":"controlled.file.match"' <<<"${controlled_skill_result}"

broken_skills_root="$(mktemp -d)"
cp -a "${ROOT_DIR}/skills" "${broken_skills_root}/skills"
printf '\n- `ops-basic/ghost-script`: bogus\n' >>"${broken_skills_root}/skills/INDEX.md"
printf '\n- `scripts/ghost-script.sh`: bogus\n' >>"${broken_skills_root}/skills/ops-basic/SKILL.md"
awk '!/^## .*传参/ && !/^## 参数契约/' "${broken_skills_root}/skills/ops-basic/SKILL.md" >"${broken_skills_root}/skills/ops-basic/SKILL.md.tmp"
mv "${broken_skills_root}/skills/ops-basic/SKILL.md.tmp" "${broken_skills_root}/skills/ops-basic/SKILL.md"
original_config_json="${LINUX_AGENT_CONFIG_JSON}"
LINUX_AGENT_CONFIG_JSON="$(jq --arg skills_dir "${broken_skills_root}/skills" '.skills_dir=$skills_dir' <<<"${LINUX_AGENT_CONFIG_JSON}")"
broken_skills_json="$(linux_agent_validate_skills)"
grep -q '"ok": false' <<<"$(jq . <<<"${broken_skills_json}")"
grep -q 'SKILL_SCRIPT_FILE_MISSING' <<<"${broken_skills_json}"
grep -q 'SKILL_INDEX_BROKEN_REF' <<<"${broken_skills_json}"
grep -q 'SKILL_ARGUMENT_CONTRACT_MISSING' <<<"${broken_skills_json}"
LINUX_AGENT_CONFIG_JSON="${original_config_json}"
rm -rf "${broken_skills_root}"

mcp_root="$(mktemp -d)"
original_mcp_dir="${LINUX_AGENT_MCP_DIR}"
LINUX_AGENT_MCP_DIR="${mcp_root}"
mkdir -p "${mcp_root}/stdio-sample" "${mcp_root}/streamable-sample" "${mcp_root}/sse-sample" "${mcp_root}/broken-sample" "${mcp_root}/array-sample" "${mcp_root}/stdio-tools"
cat >"${mcp_root}/stdio-sample/mcp.json" <<'JSON'
{
  "id": "stdio-sample",
  "name": "Stdio sample",
  "description": "Local stdio MCP server",
  "enabled": true,
  "transport": "stdio",
  "command": "node",
  "args": ["server.js"],
  "env": {"API_TOKEN": "should-not-leak"}
}
JSON
cat >"${mcp_root}/streamable-sample/mcp.json" <<'JSON'
{
  "id": "streamable-sample",
  "name": "Streamable HTTP sample",
  "transport": "streamable_http",
  "url": "http://127.0.0.1:9123/mcp",
  "headers": {"Authorization": "Bearer should-not-leak"}
}
JSON
cat >"${mcp_root}/sse-sample/mcp.json" <<'JSON'
{
  "id": "sse-sample",
  "name": "Legacy SSE sample",
  "transport": "sse",
  "url": "http://127.0.0.1:9124/sse",
  "message_url": "http://127.0.0.1:9124/messages"
}
JSON
cat >"${mcp_root}/broken-sample/mcp.json" <<'JSON'
{
  "id": "broken-sample",
  "transport": "stdio",
  "args": ["missing-command"]
}
JSON
cat >"${mcp_root}/array-sample/mcp.json" <<'JSON'
[
  {"id": "array-sample", "transport": "stdio", "command": "node"}
]
JSON
cat >"${mcp_root}/stdio-tools/mcp.json" <<JSON
{
  "id": "stdio-tools",
  "name": "Fake stdio tools",
  "transport": "stdio",
  "command": "python3",
  "args": ["${ROOT_DIR}/tests/fake_mcp_server.py", "stdio"]
}
JSON
mcp_list="$(linux_agent_mcp_list)"
jq -e '.ok == true
    and .status == "listed"
    and .root != ""
    and ([.servers[].transport] | index("stdio"))
    and ([.servers[].transport] | index("streamable_http"))
    and ([.servers[].transport] | index("sse"))
    and ([.servers[] | select(.id == "stdio-sample") | .config.env.API_TOKEN] | first) == "[REDACTED]"' <<<"${mcp_list}" >/dev/null
if grep -q 'should-not-leak' <<<"${mcp_list}"; then
    printf 'mcp list leaked secret material\n' >&2
    exit 1
fi
mcp_validate="$(linux_agent_validate_mcp)"
jq -e '.ok == false
    and ([.findings[]?.code] | index("MCP_STDIO_COMMAND_MISSING"))
    and ([.findings[]?.code] | index("MCP_MANIFEST_NOT_OBJECT"))' <<<"${mcp_validate}" >/dev/null
mcp_tools="$(linux_agent_mcp_tool_catalog)"
jq -e '.ok == true
    and ([.servers[] | select(.id == "stdio-tools") | .tools[].name] | index("echo"))
    and ([.tools[] | select(.server_id == "stdio-tools" and .name == "echo") | .ref] | first) == "stdio-tools/echo"' <<<"${mcp_tools}" >/dev/null
mcp_call="$(linux_agent_mcp_call_tool "stdio-tools" "echo" '{"text":"hello"}')"
jq -e '.ok == true
    and .status == "executed"
    and .server_id == "stdio-tools"
    and .tool == "echo"
    and .result.structuredContent.echo == "hello"
    and ([.result.content[]? | select(.type == "text") | .text] | first) == "echo:hello"' <<<"${mcp_call}" >/dev/null
LINUX_AGENT_MCP_DIR="${original_mcp_dir}"
rm -rf "${mcp_root}"

printf 'tools: ok\n'
