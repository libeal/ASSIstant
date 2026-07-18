#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=helpers.sh
source "${ROOT_DIR}/tests/helpers.sh"

tmp_root="$(mktemp -d)"
cleanup() {
    stop_fake_ai_server
    rm -rf "${tmp_root}"
}
trap cleanup EXIT
start_fake_ai_server "$((25000 + RANDOM % 1000))" "${tmp_root}"

# shellcheck source=../lib/common.sh
source "${ROOT_DIR}/lib/common.sh"
# shellcheck source=../lib/config.sh
source "${ROOT_DIR}/lib/config.sh"
# shellcheck source=../lib/audit.sh
source "${ROOT_DIR}/lib/audit.sh"
# shellcheck source=../lib/context.sh
source "${ROOT_DIR}/lib/context.sh"
# shellcheck source=../lib/skills.sh
source "${ROOT_DIR}/lib/skills.sh"
# shellcheck source=../lib/mcp.sh
source "${ROOT_DIR}/lib/mcp.sh"
# shellcheck source=../lib/provider_resilience.sh
source "${ROOT_DIR}/lib/provider_resilience.sh"
# shellcheck source=../lib/ai.sh
source "${ROOT_DIR}/lib/ai.sh"
# shellcheck source=../lib/policy.sh
source "${ROOT_DIR}/lib/policy.sh"
# shellcheck source=../lib/observer.sh
source "${ROOT_DIR}/lib/observer.sh"
# shellcheck source=../lib/executor.sh
source "${ROOT_DIR}/lib/executor.sh"

linux_agent_init_env "${ROOT_DIR}"
linux_agent_load_config
LINUX_AGENT_CONFIG_JSON="$(jq --arg api_url "${FAKE_AI_URL}" '
    .api_url = $api_url
    | .api_key = "TEST_CONFIG_API_KEY_123456"
    | del(.api_key_file)
    | .model = "fake-chat-completions"
    | .request_timeout_sec = 10
    | .providers_security.allowed_hosts = ["127.0.0.1"]
' <<<"${LINUX_AGENT_CONFIG_JSON}")"
baseline_config_json="${LINUX_AGENT_CONFIG_JSON}"

request_context="$(linux_agent_build_request_context "检查磁盘" '{"topic":"disk"}' "work")"
grep -q '"current_request":"检查磁盘"' <<<"${request_context}"
! jq -e 'has("environment_context")' <<<"${request_context}" >/dev/null
! jq -e 'has("skill_index")' <<<"${request_context}" >/dev/null
payload_context="$(linux_agent_build_ai_payload_context "${request_context}" '{"topic":"disk"}')"
grep -q '"environment_context":{"topic":"disk"}' <<<"${payload_context}"
repair_response="$(linux_agent_call_ai_with_context "repair" "${request_context}" "repair" '{"topic":"disk"}')"
jq -e '(.failure_context | fromjson).environment_context.topic == "disk"' <<<"${repair_response}" >/dev/null

# Provider address pinning must not be bypassed by ambient proxy variables.
proxy_direct_response="$(
    HTTP_PROXY=http://127.0.0.1:1 \
        HTTPS_PROXY=http://127.0.0.1:1 \
        ALL_PROXY=http://127.0.0.1:1 \
        http_proxy=http://127.0.0.1:1 \
        https_proxy=http://127.0.0.1:1 \
        all_proxy=http://127.0.0.1:1 \
        NO_PROXY='' \
        no_proxy='' \
        linux_agent_call_ai_with_context "proxy bypass regression" "${request_context}" "repair" '{"topic":"disk"}'
)"
jq -e '(.failure_context | fromjson).environment_context.topic == "disk"' <<<"${proxy_direct_response}" >/dev/null

blocked_provider_config="$(jq '
    .api_url = "http://169.254.169.254/latest/meta-data/"
    | .providers_security.require_https = false
    | .providers_security.allowed_hosts = []
' <<<"${baseline_config_json}")"
blocked_provider_response="$(LINUX_AGENT_CONFIG_JSON="${blocked_provider_config}" linux_agent_call_ai_with_context "blocked provider" "${request_context}" "repair" '{"topic":"disk"}')"
jq -e '.status == "blocked_internal_address" and .response_type == "error"' <<<"${blocked_provider_response}" >/dev/null
LINUX_AGENT_CONFIG_JSON="${baseline_config_json}"

oversized_ai_response="$(linux_agent_call_ai_with_context "超大AI响应" "${request_context}" "work_plan" '{"topic":"disk"}')"
jq -e '.ok == false and .status == "ai_response_too_large" and .response_type == "error"' \
    <<<"${oversized_ai_response}" >/dev/null

# Provider resilience retries only transient failures, then uses explicitly
# configured failover candidates and shares circuit state across calls.
export LINUX_AGENT_PROVIDER_CIRCUIT_STATE="${tmp_root}/provider-circuits.json"
flaky_api_url="${FAKE_AI_URL%/v1/chat/completions}/flaky-retry/v1/chat/completions"
retry_config="$(jq --arg api_url "${flaky_api_url}" '
    .api_url = $api_url
    | .provider_resilience = {
        enabled:true,
        max_attempts:3,
        backoff_initial_ms:0,
        backoff_max_ms:0,
        circuit_failure_threshold:5,
        circuit_open_sec:60,
        failover:[]
    }
' <<<"${baseline_config_json}")"
retry_response="$(LINUX_AGENT_CONFIG_JSON="${retry_config}" linux_agent_call_ai_with_context "repair" "${request_context}" "repair" '{"topic":"disk"}')"
jq -e '(.failure_context | fromjson).environment_context.topic == "disk"' <<<"${retry_response}" >/dev/null
retry_counters="$(curl --noproxy '*' -sS "http://127.0.0.1:${FAKE_AI_PORT}/counters")"
jq -e '.counters.flaky_retry == 3' <<<"${retry_counters}" >/dev/null

failed_primary_url="${FAKE_AI_URL%/v1/chat/completions}/always-503/v1/chat/completions"
fallback_api_url="${FAKE_AI_URL%/v1/chat/completions}/require-failover-key/v1/chat/completions"
failover_config="$(jq --arg api_url "${failed_primary_url}" --arg fallback_url "${fallback_api_url}" '
    .api_url = $api_url
    | .provider_resilience = {
        enabled:true,
        max_attempts:1,
        backoff_initial_ms:0,
        backoff_max_ms:0,
        circuit_failure_threshold:5,
        circuit_open_sec:60,
        failover:[{
            provider:"openai_compatible",
            api_url:$fallback_url,
            model:"fake-chat-completions",
            api_key_env:"TEST_FAILOVER_API_KEY"
        }]
    }
' <<<"${baseline_config_json}")"
export TEST_FAILOVER_API_KEY="TEST_FAILOVER_API_KEY_123456"
LINUX_AGENT_CONFIG_JSON="${failover_config}" linux_agent_call_ai_with_context \
    "repair" "${request_context}" "repair" '{"topic":"disk"}' >"${tmp_root}/failover-response.json"
failover_response="$(<"${tmp_root}/failover-response.json")"
unset TEST_FAILOVER_API_KEY
jq -e '(.failure_context | fromjson).environment_context.topic == "disk"' <<<"${failover_response}" >/dev/null
! grep -q 'TEST_FAILOVER_API_KEY_123456' <<<"${LINUX_AGENT_LAST_AI_PAYLOAD}"
failover_counters="$(curl --noproxy '*' -sS "http://127.0.0.1:${FAKE_AI_PORT}/counters")"
jq -e '.counters.always_503 == 1' <<<"${failover_counters}" >/dev/null

circuit_api_url="${FAKE_AI_URL%/v1/chat/completions}/always-503-circuit/v1/chat/completions"
circuit_config="$(jq --arg api_url "${circuit_api_url}" '
    .api_url = $api_url
    | .provider_resilience = {
        enabled:true,
        max_attempts:1,
        backoff_initial_ms:0,
        backoff_max_ms:0,
        circuit_failure_threshold:1,
        circuit_open_sec:60,
        failover:[]
    }
' <<<"${baseline_config_json}")"
circuit_first="$(LINUX_AGENT_CONFIG_JSON="${circuit_config}" linux_agent_call_ai_with_context "repair" "${request_context}" "repair" '{"topic":"disk"}')"
circuit_second="$(LINUX_AGENT_CONFIG_JSON="${circuit_config}" linux_agent_call_ai_with_context "repair" "${request_context}" "repair" '{"topic":"disk"}')"
jq -e '.ok == false and .status == "ai_http_error"' <<<"${circuit_first}" >/dev/null
jq -e '.ok == false and .status == "ai_circuit_open"' <<<"${circuit_second}" >/dev/null
circuit_counters="$(curl --noproxy '*' -sS "http://127.0.0.1:${FAKE_AI_PORT}/counters")"
jq -e '.counters.always_503_circuit == 1' <<<"${circuit_counters}" >/dev/null
unset LINUX_AGENT_PROVIDER_CIRCUIT_STATE

config_key_state="$(linux_agent_api_key_state_json)"
jq -e '.configured == true and .source == "config" and .config_configured == true and (.file_configured | not)' <<<"${config_key_state}" >/dev/null
! grep -q 'TEST_CONFIG_API_KEY_123456' <<<"${LINUX_AGENT_LAST_AI_PAYLOAD}"

saved_config_json="${LINUX_AGENT_CONFIG_JSON}"
sarvam_api_url="${FAKE_AI_URL%/v1/chat/completions}/require-api-subscription-key/chat/completions"
LINUX_AGENT_CONFIG_JSON="$(jq --arg api_url "${sarvam_api_url}" '
    .provider = "sarvam_ai"
    | .api_url = $api_url
    | .api_key = "TEST_CONFIG_API_KEY_123456"
    | .model = "fake-chat-completions"
' <<<"${saved_config_json}")"
sarvam_response="$(linux_agent_call_ai_with_context "sarvam auth" "${request_context}" "repair" '{"topic":"disk"}')"
jq -e '(.failure_context | fromjson).environment_context.topic == "disk"' <<<"${sarvam_response}" >/dev/null
LINUX_AGENT_CONFIG_JSON="${saved_config_json}"

config_only_json="$(jq '.api_key = "TEST_CONFIG_KEY_123456" | del(.api_key_file)' <<<"${LINUX_AGENT_CONFIG_JSON}")"
LINUX_AGENT_CONFIG_JSON="${config_only_json}"
config_key_value="$(linux_agent_config_api_key)"
config_only_state="$(linux_agent_api_key_state_json)"
[[ "${config_key_value}" == "TEST_CONFIG_KEY_123456" ]]
jq -e '.configured == true and .source == "config" and .config_configured == true and (.file_configured | not)' <<<"${config_only_state}" >/dev/null
LINUX_AGENT_CONFIG_JSON="${saved_config_json}"

# Consumed by linux_agent_config_api_key from the sourced config module.
# shellcheck disable=SC2034
LINUX_AGENT_API_KEY="TEST_ENV_API_KEY_123456"
env_config_json="$(jq '.api_key = "TEST_CONFIG_KEY_MUST_NOT_WIN" | del(.api_key_file)' <<<"${LINUX_AGENT_CONFIG_JSON}")"
LINUX_AGENT_CONFIG_JSON="${env_config_json}"
env_response="$(linux_agent_call_ai_with_context "env secret" "${request_context}" "repair" '{"topic":"disk"}')"
jq -e '(.failure_context | fromjson).environment_context.topic == "disk"' <<<"${env_response}" >/dev/null
env_key_state="$(linux_agent_api_key_state_json)"
jq -e '.configured == true and .source == "env" and .config_configured == true and (.file_configured | not)' <<<"${env_key_state}" >/dev/null
! grep -q 'TEST_ENV_API_KEY' <<<"${LINUX_AGENT_LAST_AI_PAYLOAD}"
! grep -q 'TEST_CONFIG_KEY_MUST_NOT_WIN' <<<"${LINUX_AGENT_LAST_AI_PAYLOAD}"
unset LINUX_AGENT_API_KEY
LINUX_AGENT_CONFIG_JSON="${saved_config_json}"

string_args_response="$(jq -cn '{
    response_type:"work_plan",
    summary:"string args regression",
    continue_decision:{should_continue:false, reason:"test"},
    steps:[{
        id:"step-1",
        title:"resource",
        executor_type:"skill_script",
        skill_script:"ops-basic/resource-inspect",
        arguments:"{}",
        reason:"test",
        expected_effect:"test",
        risk_level:"low",
        rollback_hint:"none"
    }]
}')"
normalized_string_args_response="$(linux_agent_normalize_model_response "${string_args_response}")"
jq -e '.steps[0].arguments == {}' <<<"${normalized_string_args_response}" >/dev/null
linux_agent_validate_work_response "${normalized_string_args_response}"

encoded_step_args="$(linux_agent_step_arguments_json "$(jq -cn --arg args '{"top_n":2}' '{arguments:$args}')")"
grep -q '"top_n":2' <<<"${encoded_step_args}"

unmanaged_root="${tmp_root}/unmanaged-root"
unmanaged_logs="${tmp_root}/unmanaged-logs"
mkdir -p "${unmanaged_root}" "${unmanaged_logs}"
ln -s "${unmanaged_logs}" "${unmanaged_root}/logs"
if linux_agent_init_env "${unmanaged_root}" 2>"${tmp_root}/unmanaged-log.err"; then
    printf 'common init unexpectedly accepted an unmanaged audit-log symlink\n' >&2
    exit 1
fi
grep -q '不符合受管安装布局' "${tmp_root}/unmanaged-log.err"

cleanup_root="$(mktemp -d)"
linux_agent_init_env "${cleanup_root}"
mkdir -p "${LINUX_AGENT_TMP_DIR}/nested"
printf stale >"${LINUX_AGENT_TMP_DIR}/stale.tmp"
printf stale >"${LINUX_AGENT_TMP_DIR}/nested/file.tmp"
linux_agent_cleanup_tmp_dir
[[ -d "${LINUX_AGENT_TMP_DIR}" ]]
[[ -z "$(find "${LINUX_AGENT_TMP_DIR}" -mindepth 1 -print -quit)" ]]
rm -rf "${cleanup_root}"
linux_agent_init_env "${ROOT_DIR}"
linux_agent_load_config

secret_json='{"api_key":"TEST_API_SECRET_123456","nested":{"password":"TEST_PASS_123456"},"headers":{"Authorization":"Bearer TEST_BEARER_1234567890"},"pem":"-----BEGIN RSA PRIVATE KEY-----\nabc\n-----END RSA PRIVATE KEY-----"}'
redacted_json="$(linux_agent_sanitize_json "${secret_json}")"
! grep -q 'TEST_API_SECRET\|TEST_PASS\|TEST_BEARER\|BEGIN RSA PRIVATE KEY' <<<"${redacted_json}"
grep -q '\[REDACTED\]\|\[REDACTED_PRIVATE_KEY\]' <<<"${redacted_json}"

secret_text=$'password="TEST PASS WITH SPACES"\nsecret='\''TEST SINGLE QUOTED SECRET'\''\ntoken=TEST UNQUOTED TOKEN WITH SPACES\nAuthorization: Basic TEST_BASIC_AUTH_TOKEN'
redacted_text="$(linux_agent_sanitize_text "${secret_text}")"
! grep -q 'TEST PASS WITH SPACES\|TEST SINGLE QUOTED SECRET\|TEST UNQUOTED TOKEN WITH SPACES\|TEST_BASIC_AUTH_TOKEN' <<<"${redacted_text}"
grep -q '\[REDACTED_SECRET\]' <<<"${redacted_text}"

LINUX_AGENT_CONFIG_JSON="$(jq '.audit_mode="safe_summary" | .audit_text_limit=80' <<<"${LINUX_AGENT_CONFIG_JSON}")"
linux_agent_start_session 'api_key=TEST_AUDIT_SECRET password=TEST_AUDIT_PASS'
safe_session_id="${LINUX_AGENT_SESSION_ID}"
linux_agent_log_event "request_context_built" "$(jq -cn \
    --arg current_request 'token=TEST_CONTEXT_TOKEN' \
    '{mode:"work", current_request:$current_request, conversation_context:[{role:"user", content:"password=TEST_HISTORY_PASS"}], environment_context:{raw:"Bearer TEST_ENV_BEARER_1234567890"}, skill_index:"secret=TEST_SKILL_SECRET"}')"
linux_agent_log_event "script_manual_edit" "$(jq -cn --arg diff 'password=TEST_DIFF_PASS\n+token=TEST_DIFF_TOKEN' '{skill:"demo", script:"x.sh", diff:$diff}')"
linux_agent_finish_session "tested"
audit_output="$(bash "${ROOT_DIR}/bin/agent" audit "${safe_session_id}")"
! grep -R -q 'TEST_AUDIT_SECRET\|TEST_AUDIT_PASS\|TEST_CONTEXT_TOKEN\|TEST_HISTORY_PASS\|TEST_ENV_BEARER\|TEST_SKILL_SECRET\|TEST_RESOURCE_PROCESS_RAW\|TEST_RESOURCE_MEMORY_RAW\|TEST_DIFF_PASS\|TEST_NOTE_BEARER' \
    "${ROOT_DIR}/logs/${safe_session_id}.jsonl"
! grep -q 'TEST_AUDIT_SECRET\|TEST_AUDIT_PASS\|TEST_CONTEXT_TOKEN\|TEST_HISTORY_PASS\|TEST_ENV_BEARER\|TEST_SKILL_SECRET\|TEST_DIFF_PASS' <<<"${audit_output}"
[[ ! -e "${ROOT_DIR}/sessions/${safe_session_id}.md" ]]
grep -q '# 事件时间线' <<<"${audit_output}"
grep -q '构建模型上下文' <<<"${audit_output}"
grep -q '"stage":"script_manual_edit"' "${ROOT_DIR}/logs/${safe_session_id}.jsonl"
grep -q '"diff_lines"' "${ROOT_DIR}/logs/${safe_session_id}.jsonl"
audit_list_summary="$(bash "${ROOT_DIR}/bin/agent" api audit list '{"limit":50}')"
jq -e --arg session_id "${safe_session_id}" '
    [.sessions[] | select(.session_id == $session_id)] | first
    | .entrypoint == "cli"
      and (.event_count >= 1)
      and (.modes | index("work"))
      and (.event_summary | length > 0)
      and (.highlights | length > 0)
' <<<"${audit_list_summary}" >/dev/null

verbose_project="${tmp_root}/verbose-project"
mkdir -p "${verbose_project}"
cp -a "${ROOT_DIR}/config" "${ROOT_DIR}/policies" "${verbose_project}/"
linux_agent_init_env "${verbose_project}"
linux_agent_load_config
LINUX_AGENT_CONFIG_JSON="$(jq '.audit_mode="safe_summary" | .audit_text_limit=1000' <<<"${LINUX_AGENT_CONFIG_JSON}")"
boundary_tmp="$(mktemp)"
jq '.observing.audit_payload_mode="redacted_verbose" | .observing.audit_text_limit=20 | .observing.application_events=["session_started","received","session_finished"]' \
    "${verbose_project}/policies/audit-boundaries.json" >"${boundary_tmp}"
mv "${boundary_tmp}" "${verbose_project}/policies/audit-boundaries.json"
linux_agent_start_session '检查很长的文本'
verbose_session_id="${LINUX_AGENT_SESSION_ID}"
linux_agent_log_event "received" "$(jq -cn --arg input 'abcdefghijklmnopqrstuvwxyz0123456789 password=TEST_VERBOSE_PASS' '{mode:"work", input:$input}')"
linux_agent_finish_session "tested"
verbose_audit_output="$(linux_agent_show_audit "${verbose_session_id}")"
! grep -R -q 'TEST_VERBOSE_PASS' "${verbose_project}/logs/${verbose_session_id}.jsonl"
! grep -q 'TEST_VERBOSE_PASS' <<<"${verbose_audit_output}"
grep -q '\[TRUNCATED\]' "${verbose_project}/logs/${verbose_session_id}.jsonl"

http_step='{"id":"remote-1","title":"remote","executor_type":"remote_script","url":"http://example.test/install.sh","arguments":{},"reason":"test","expected_effect":"test","risk_level":"low","rollback_hint":"none"}'
http_result="$(linux_agent_prepare_remote_step "${http_step}" 2>&1 || true)"
grep -q 'https URL' <<<"${http_result}"

LINUX_AGENT_CONFIG_JSON="$(jq '.remote_script_policy="disabled"' <<<"${LINUX_AGENT_CONFIG_JSON}")"
disabled_result="$(linux_agent_prepare_remote_step "${http_step}" 2>&1 || true)"
grep -q '策略已禁用' <<<"${disabled_result}"
LINUX_AGENT_CONFIG_JSON="$(jq '.remote_script_policy="download_review"' <<<"${LINUX_AGENT_CONFIG_JSON}")"

linux_agent_download_remote_script() {
    printf '#!/usr/bin/env bash\nprintf ok\n' >"$2"
}
https_step='{"id":"remote-2","title":"remote","executor_type":"remote_script","url":"https://example.test/install.sh","arguments":{},"reason":"test","expected_effect":"test","risk_level":"low","rollback_hint":"none"}'
prepared_step="$(linux_agent_prepare_remote_step "${https_step}")"
grep -q '"risk_level":"high"' <<<"${prepared_step}"
grep -q '"sha256"' <<<"${prepared_step}"
grep -q 'printf ok' <<<"${prepared_step}"
review="$(linux_agent_policy_review_step "${prepared_step}" "$(linux_agent_step_review_material "${prepared_step}")" remote)"
grep -q '"approval_required":true' <<<"${review}"
grep -q '"risk_level":"high"' <<<"${review}"
[[ "$(linux_agent_execution_privilege_from_review "${review}")" == "least" ]]

sudo_review="$(linux_agent_policy_review_text "terminal" "sudo systemctl restart nginx")"
[[ "$(linux_agent_execution_privilege_from_review "${sudo_review}")" == "current" ]]

fake_priv_bin="${tmp_root}/fake-root-bin"
mkdir -p "${fake_priv_bin}"
cat >"${fake_priv_bin}/id" <<'SH'
#!/usr/bin/env bash
case "$*" in
    "-u") printf '0\n' ;;
    "-un") printf 'root\n' ;;
    "-u nobody") printf '65534\n' ;;
    "-g nobody") printf '65534\n' ;;
    "-u nfsnobody") exit 1 ;;
    "-u daemon") printf '1\n' ;;
    "-g daemon") printf '1\n' ;;
    *) /usr/bin/id "$@" ;;
esac
SH
cat >"${fake_priv_bin}/runuser" <<'SH'
#!/usr/bin/env bash
printf 'fake runuser should not execute in this test\n' >&2
exit 127
SH
chmod +x "${fake_priv_bin}/id" "${fake_priv_bin}/runuser"
old_path="${PATH}"
PATH="${fake_priv_bin}:${PATH}"
root_prepared=()
linux_agent_prepare_execution_command "least" root_prepared bash -lc 'id -u'
[[ "${root_prepared[0]}" == "runuser" ]]
[[ "${root_prepared[1]}" == "-u" ]]
[[ "${root_prepared[2]}" == "nobody" ]]
[[ "${root_prepared[3]}" == "--" ]]
# Child steps run under an explicit environment allowlist.
[[ "${root_prepared[4]}" == "env" ]]
[[ "${root_prepared[5]}" == "-i" ]]
[[ "${root_prepared[6]}" == "--" ]]
! printf '%s\n' "${root_prepared[@]}" | grep -q 'LINUX_AGENT_API_KEY'
current_prepared=()
linux_agent_prepare_execution_command "current" current_prepared bash -lc 'id -u'
[[ "${current_prepared[0]}" == "env" ]]
[[ "${current_prepared[1]}" == "-i" ]]
[[ "${current_prepared[2]}" == "--" ]]
! printf '%s\n' "${current_prepared[@]}" | grep -q 'LINUX_AGENT_API_KEY'
printf '%s\n' "${current_prepared[@]}" | grep -qx 'bash'
proxy_meta="$(linux_agent_execution_proxy_metadata "least" "true")"
jq -e '.enabled == true and .requested_privilege == "least" and .execution_user == "root" and .target_user == "nobody" and .prepared_root == true' <<<"${proxy_meta}" >/dev/null
PATH="${old_path}"

linux_agent_init_env "${ROOT_DIR}"
linux_agent_load_config
low_review='{"approved":true,"approval_required":false,"risk_level":"low","findings":[]}'
no_backup_cleanup_review="$(linux_agent_backup_policy_review \
    "ops-basic/safe-log-cleanup" \
    '{"path":"/tmp/example.log","dry_run":false}' \
    "${low_review}")"
jq -e '.approved == false and .risk_level == "critical" and ([.findings[] | select(.code == "BACKUP_REQUIRED")] | length) == 1' \
    <<<"${no_backup_cleanup_review}" >/dev/null
no_backup_patch_review="$(linux_agent_backup_policy_review \
    "controlled-tools/file-patch" \
    '{"path":"/tmp/example.conf","apply":true,"backup":false}' \
    "${low_review}")"
jq -e '.approved == false and .risk_level == "critical" and ([.findings[] | select(.code == "BACKUP_REQUIRED")] | length) == 1' \
    <<<"${no_backup_patch_review}" >/dev/null
backup_gate_target="$(mktemp /tmp/linux-agent-backup-gate.XXXXXX)"
backup_gate_sha256="$(sha256sum "${backup_gate_target}" | awk '{print $1}')"
backup_gate_results="$(jq -cn --arg path "${backup_gate_target}" --arg sha256 "${backup_gate_sha256}" '[{result:{ok:true,output:{tool:"system.config.backup",path:$path,archive:"/tmp/verified-backup.tar.gz",source_sha256:$sha256}}}]')"
backup_gate_step="$(jq -cn --arg path "${backup_gate_target}" '{id:"cleanup",title:"cleanup",executor_type:"skill_script",skill_script:"ops-basic/safe-log-cleanup",arguments:{path:$path,dry_run:false}}')"
prepared_backup_gate="$(linux_agent_prepare_backup_protected_step "${backup_gate_step}" '[]' "${backup_gate_results}")"
jq -e --arg archive "/tmp/verified-backup.tar.gz" --arg sha256 "${backup_gate_sha256}" \
    '.arguments.backup_archive == $archive and .arguments.backup_sha256 == $sha256' \
    <<<"${prepared_backup_gate}" >/dev/null
rm -f "${backup_gate_target}"
readonly_skill_step='{"id":"auto-1","title":"resource","executor_type":"skill_script","skill_script":"ops-basic/resource-inspect","arguments":{},"reason":"test","expected_effect":"test","risk_level":"low","rollback_hint":"none"}'
file_match_step='{"id":"auto-2","title":"match","executor_type":"skill_script","skill_script":"controlled-tools/file-match","arguments":{},"reason":"test","expected_effect":"test","risk_level":"low","rollback_hint":"none"}'
file_patch_step='{"id":"auto-3","title":"patch","executor_type":"skill_script","skill_script":"controlled-tools/file-patch","arguments":{},"reason":"test","expected_effect":"test","risk_level":"low","rollback_hint":"none"}'
shell_step='{"id":"auto-4","title":"shell","executor_type":"shell","command":"printf ok","arguments":{},"reason":"test","expected_effect":"test","risk_level":"low","rollback_hint":"none"}'
auto_config="${LINUX_AGENT_CONFIG_JSON}"
LINUX_AGENT_CONFIG_JSON="$(jq 'del(.approvals) | .agent_loop.auto_execute_low_risk=false | .agent_loop.auto_execute_shell_low_risk=true' <<<"${auto_config}")"
linux_agent_should_auto_execute_step "${readonly_skill_step}" "${low_review}"
! linux_agent_should_auto_execute_step "${shell_step}" "${low_review}"
LINUX_AGENT_CONFIG_JSON="$(jq '.approvals.auto.skill_readonly=false | .approvals.auto.file_match=true | .approvals.auto.file_patch=false' <<<"${auto_config}")"
! linux_agent_should_auto_execute_step "${readonly_skill_step}" "${low_review}"
linux_agent_should_auto_execute_step "${file_match_step}" "${low_review}"
! linux_agent_should_auto_execute_step "${file_patch_step}" "${low_review}"
LINUX_AGENT_CONFIG_JSON="$(jq '.approvals.auto.skill_readonly=true | .approvals.auto.shell_readonly=false' <<<"${auto_config}")"
linux_agent_should_auto_execute_step "${readonly_skill_step}" "${low_review}"
! linux_agent_should_auto_execute_step "${shell_step}" "${low_review}"
terminal_review_when_shell_disabled="$(linux_agent_terminal_review "printf ok")"
jq -e '.approved == true
    and .approval_required == true
    and .risk_level == "low"
    and ([.findings[]? | select(.code == "SHELL_AUTO_APPROVAL_DISABLED")] | length) == 1' <<<"${terminal_review_when_shell_disabled}" >/dev/null
LINUX_AGENT_CONFIG_JSON="$(jq '.approvals.auto.skill_readonly=false | .approvals.auto.shell_readonly=true' <<<"${auto_config}")"
! linux_agent_should_auto_execute_step "${readonly_skill_step}" "${low_review}"
linux_agent_should_auto_execute_step "${shell_step}" "${low_review}"
terminal_review_when_shell_enabled="$(linux_agent_terminal_review "printf ok")"
jq -e '.approved == true
    and .approval_required == false
    and .risk_level == "low"
    and ([.findings[]? | select(.code == "SHELL_AUTO_APPROVAL_DISABLED")] | length) == 0' <<<"${terminal_review_when_shell_enabled}" >/dev/null
LINUX_AGENT_CONFIG_JSON="${auto_config}"

mcp_exec_root="$(mktemp -d)"
original_mcp_dir="${LINUX_AGENT_MCP_DIR}"
LINUX_AGENT_MCP_DIR="${mcp_exec_root}"
mkdir -p "${mcp_exec_root}/stdio-tools"
cat >"${mcp_exec_root}/stdio-tools/mcp.json" <<JSON
{
  "id": "stdio-tools",
  "name": "Fake stdio tools",
  "transport": "stdio",
  "command": "python3",
  "args": ["${ROOT_DIR}/tests/fake_mcp_server.py", "stdio"]
}
JSON
mcp_work_plan="$(jq -cn '{
    response_type:"work_plan",
    summary:"mcp tool execution",
    continue_decision:{should_continue:false, reason:"test"},
    steps:[{
        id:"mcp-1",
        title:"call fake mcp echo",
        executor_type:"mcp_tool",
        mcp_server:"stdio-tools",
        mcp_tool:"echo",
        arguments:{text:"hello"},
        reason:"test mcp execution",
        expected_effect:"echoes text through MCP",
        risk_level:"low",
        rollback_hint:"read-only fake tool"
    }]
}')"
linux_agent_validate_work_response "${mcp_work_plan}"
LINUX_AGENT_API_MODE=1
LINUX_AGENT_API_INPUT_JSON='["y"]'
mcp_execution="$(linux_agent_execute_work_plan "${mcp_work_plan}" "call mcp echo" "{}")"
jq -e '.status == "executed"
    and (.results | length) == 1
    and .results[0].step.executor_type == "mcp_tool"
    and .results[0].result.ok == true
    and .results[0].result.output.tool == "mcp.stdio-tools.echo"
    and .results[0].result.output.structuredContent.echo == "hello"' <<<"${mcp_execution}" >/dev/null
# Reset globals consumed by the sourced executor module.
# shellcheck disable=SC2034
LINUX_AGENT_API_MODE=0
# shellcheck disable=SC2034
LINUX_AGENT_API_INPUT_JSON='[]'
LINUX_AGENT_MCP_DIR="${original_mcp_dir}"
rm -rf "${mcp_exec_root}"

linux_agent_download_remote_script() {
    printf '\000\001' >"$2"
}
binary_result="$(linux_agent_prepare_remote_step "${https_step}" 2>&1 || true)"
grep -q '不是文本内容' <<<"${binary_result}"

linux_agent_download_remote_script() {
    head -c 262145 /dev/zero >"$2"
}
large_result="$(linux_agent_prepare_remote_step "${https_step}" 2>&1 || true)"
grep -q '超过 256KB' <<<"${large_result}"

# Remote script review rejects private targets before curl and pins the public
# address while enforcing protocol and byte limits during download.
# shellcheck source=../lib/executor.sh
source "${ROOT_DIR}/lib/executor.sh"
if linux_agent_download_remote_script "https://127.0.0.1/private.sh" "${tmp_root}/private.sh"; then
    printf 'remote script downloader accepted a private target\n' >&2
    exit 1
fi
remote_curl_args="${tmp_root}/remote-curl.args"
curl() {
    printf '%s\n' "$@" >"${remote_curl_args}"
    local prior=""
    local value
    for value in "$@"; do
        if [[ "${prior}" == "-o" ]]; then
            printf '#!/usr/bin/env bash\ntrue\n' >"${value}"
        fi
        prior="${value}"
    done
}
linux_agent_download_remote_script "https://1.1.1.1/review.sh" "${tmp_root}/bounded.sh"
unset -f curl
grep -qx -- '--max-filesize' "${remote_curl_args}"
grep -qx -- '262144' "${remote_curl_args}"
grep -qx -- '--proto-redir' "${remote_curl_args}"
grep -qx -- '=https' "${remote_curl_args}"
grep -qx -- '--resolve' "${remote_curl_args}"
grep -qx -- '1.1.1.1:443:1.1.1.1' "${remote_curl_args}"

output_limit_config="${LINUX_AGENT_CONFIG_JSON}"
LINUX_AGENT_CONFIG_JSON="$(jq '.execution.max_output_bytes=4096 | .observer.enabled="disabled" | .observer.require=false' <<<"${LINUX_AGENT_CONFIG_JSON}")"
linux_agent_start_session 'execution output limit'
export LINUX_AGENT_EXECUTION_PRIVILEGE=current
limited_result="$(linux_agent_execute_observed_command_output \
    terminal '{"command":"large-output"}' -- \
    python3 -c 'import sys; sys.stdout.write("x" * 50000); sys.stdout.flush()')"
unset LINUX_AGENT_EXECUTION_PRIVILEGE
jq -e '.ok == false
    and .status == "output_limit_exceeded"
    and .output_capped == true
    and .stdout_truncated_bytes > 0
    and .observer.status == "output_capped"' <<<"${limited_result}" >/dev/null
linux_agent_finish_session "output_limit_exceeded"
LINUX_AGENT_CONFIG_JSON="${output_limit_config}"

printf 'security: ok\n'
