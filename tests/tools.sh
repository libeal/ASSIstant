#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

disk_result="$(bash "${ROOT_DIR}/tools/local/disk_hotspots.sh" '{"path":"/var","top_n":3}')"
resource_result="$(bash "${ROOT_DIR}/tools/local/resource_inspect.sh" '{"top_n":3}')"
process_result="$(bash "${ROOT_DIR}/tools/local/process_inspect.sh" '{"pattern":"systemd"}')"
cleanup_result="$(bash "${ROOT_DIR}/tools/local/safe_log_cleanup.sh" '{"path":"/etc/passwd","dry_run":true}')"
cleanup_plan_result="$(bash "${ROOT_DIR}/tools/local/log_cleanup_plan.sh" '{"root_path":"/etc","min_size_mb":1}')"
restart_plan_result="$(bash "${ROOT_DIR}/tools/local/service_restart_plan.sh" '{"service":"sshd"}')"
log_search_reject="$(bash "${ROOT_DIR}/tools/local/log_inspect.sh" "{\"path\":\"${ROOT_DIR}/README.md\",\"keyword\":\"Linux\",\"lines\":1}")"
log_search_no_journal="$(bash "${ROOT_DIR}/tools/local/log_inspect.sh" '{"path":"/var/log","keyword":"__unlikely_linux_agent_test_keyword__","lines":1,"include_journal":false}')"

tmp_link="$(mktemp -u)"
ln -s "${ROOT_DIR}/README.md" "${tmp_link}"
log_search_symlink="$(bash "${ROOT_DIR}/tools/local/log_inspect.sh" "{\"path\":\"${tmp_link}\",\"keyword\":\"Linux\",\"lines\":1}")"
rm -f "${tmp_link}"

grep -q '"ok": true' <<<"$(jq . <<<"${disk_result}")"
grep -q '"tool": "system.resource.inspect"' <<<"$(jq . <<<"${resource_result}")"
grep -q '"tool": "system.process.inspect"' <<<"$(jq . <<<"${process_result}")"
grep -q '"ok": false' <<<"$(jq . <<<"${cleanup_result}")"
grep -q '"tool": "system.logs.cleanup_plan"' <<<"$(jq . <<<"${cleanup_plan_result}")"
grep -q '"ok": false' <<<"$(jq . <<<"${cleanup_plan_result}")"
grep -q '"risk": "high"' <<<"$(jq . <<<"${restart_plan_result}")"
grep -q '"ok": false' <<<"$(jq . <<<"${log_search_reject}")"
grep -q '仅允许检索 /var/log' <<<"${log_search_reject}"
grep -q '"ok": false' <<<"$(jq . <<<"${log_search_symlink}")"
grep -q '"include_journal": false' <<<"$(jq . <<<"${log_search_no_journal}")"
grep -q '"journal_sample": ""' <<<"$(jq . <<<"${log_search_no_journal}")"

source "${ROOT_DIR}/lib/common.sh"
source "${ROOT_DIR}/lib/config.sh"
source "${ROOT_DIR}/lib/policy.sh"
source "${ROOT_DIR}/lib/skills.sh"
source "${ROOT_DIR}/lib/doctor.sh"
linux_agent_init_env "${ROOT_DIR}"
linux_agent_load_config
doctor_json="$(linux_agent_doctor)"
grep -q '"skills_ok": true' <<<"$(jq . <<<"${doctor_json}")"
skills_json="$(linux_agent_validate_skills)"
grep -q '"ok": true' <<<"$(jq . <<<"${skills_json}")"
resource_skill_result="$(linux_agent_run_skill_script ops-basic/resource-inspect '{"top_n":3}')"
process_skill_result="$(linux_agent_run_skill_script ops-basic/process-inspect '{"pattern":"systemd"}')"
grep -q '"tool": "system.resource.inspect"' <<<"$(jq . <<<"${resource_skill_result}")"
grep -q '"tool": "system.process.inspect"' <<<"$(jq . <<<"${process_skill_result}")"

printf 'tools: ok\n'
