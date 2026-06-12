#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/common.sh
source "${ROOT_DIR}/lib/common.sh"
# shellcheck source=../lib/config.sh
source "${ROOT_DIR}/lib/config.sh"
# shellcheck source=../lib/audit.sh
source "${ROOT_DIR}/lib/audit.sh"
# shellcheck source=../lib/context.sh
source "${ROOT_DIR}/lib/context.sh"
# shellcheck source=../lib/policy.sh
source "${ROOT_DIR}/lib/policy.sh"
# shellcheck source=../lib/executor.sh
source "${ROOT_DIR}/lib/executor.sh"

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
linux_agent_append_session_note "环境感知（已脱敏）" "$(jq -cn \
    --arg top_processes 'TEST_RESOURCE_PROCESS_RAW' \
    --arg memory_summary 'TEST_RESOURCE_MEMORY_RAW' \
    '{topic:"resource", top_processes:$top_processes, memory_summary:$memory_summary}')"
linux_agent_log_event "script_manual_edit" "$(jq -cn --arg diff 'password=TEST_DIFF_PASS\n+token=TEST_DIFF_TOKEN' '{skill:"demo", script:"x.sh", diff:$diff}')"
linux_agent_append_session_note "自由文本" 'Bearer TEST_NOTE_BEARER_1234567890'
linux_agent_finish_session "tested"
! grep -R -q 'TEST_AUDIT_SECRET\|TEST_AUDIT_PASS\|TEST_CONTEXT_TOKEN\|TEST_HISTORY_PASS\|TEST_ENV_BEARER\|TEST_SKILL_SECRET\|TEST_RESOURCE_PROCESS_RAW\|TEST_RESOURCE_MEMORY_RAW\|TEST_DIFF_PASS\|TEST_NOTE_BEARER' \
    "${ROOT_DIR}/logs/${safe_session_id}.jsonl" "${ROOT_DIR}/sessions/${safe_session_id}.md"
grep -q '"stage":"script_manual_edit"' "${ROOT_DIR}/logs/${safe_session_id}.jsonl"
grep -q '"diff_lines"' "${ROOT_DIR}/logs/${safe_session_id}.jsonl"

LINUX_AGENT_CONFIG_JSON="$(jq '.audit_mode="redacted_verbose" | .audit_text_limit=20' <<<"${LINUX_AGENT_CONFIG_JSON}")"
linux_agent_start_session '检查很长的文本'
verbose_session_id="${LINUX_AGENT_SESSION_ID}"
linux_agent_log_event "received" "$(jq -cn --arg input 'abcdefghijklmnopqrstuvwxyz0123456789 password=TEST_VERBOSE_PASS' '{mode:"work", input:$input}')"
linux_agent_finish_session "tested"
! grep -R -q 'TEST_VERBOSE_PASS' "${ROOT_DIR}/logs/${verbose_session_id}.jsonl" "${ROOT_DIR}/sessions/${verbose_session_id}.md"
grep -q '\[TRUNCATED\]' "${ROOT_DIR}/logs/${verbose_session_id}.jsonl"

http_step='{"id":"remote-1","title":"remote","executor_type":"remote_script","url":"http://example.test/install.sh","arguments":{},"reason":"test","expected_effect":"test","risk_level":"low","rollback_hint":"none"}'
http_result="$(linux_agent_prepare_remote_step "${http_step}" 2>&1 || true)"
grep -q 'https URL' <<<"${http_result}"

LINUX_AGENT_CONFIG_JSON="$(jq '.remote_script_policy="disabled"' <<<"${LINUX_AGENT_CONFIG_JSON}")"
disabled_result="$(linux_agent_prepare_remote_step "${http_step}" 2>&1 || true)"
grep -q '策略已禁用' <<<"${disabled_result}"
LINUX_AGENT_CONFIG_JSON="$(jq '.remote_script_policy="download_review"' <<<"${LINUX_AGENT_CONFIG_JSON}")"

linux_agent_download_remote_script() {
    printf '#!/usr/bin/env bash\nprintf ok\n' > "$2"
}
https_step='{"id":"remote-2","title":"remote","executor_type":"remote_script","url":"https://example.test/install.sh","arguments":{},"reason":"test","expected_effect":"test","risk_level":"low","rollback_hint":"none"}'
prepared_step="$(linux_agent_prepare_remote_step "${https_step}")"
grep -q '"risk_level":"high"' <<<"${prepared_step}"
grep -q '"sha256"' <<<"${prepared_step}"
grep -q 'printf ok' <<<"${prepared_step}"
review="$(linux_agent_policy_review_step "${prepared_step}" "$(linux_agent_step_review_material "${prepared_step}")" remote)"
grep -q '"approval_required":true' <<<"${review}"
grep -q '"risk_level":"high"' <<<"${review}"

linux_agent_download_remote_script() {
    printf '\000\001' > "$2"
}
binary_result="$(linux_agent_prepare_remote_step "${https_step}" 2>&1 || true)"
grep -q '不是文本内容' <<<"${binary_result}"

linux_agent_download_remote_script() {
    head -c 262145 /dev/zero > "$2"
}
large_result="$(linux_agent_prepare_remote_step "${https_step}" 2>&1 || true)"
grep -q '超过 256KB' <<<"${large_result}"

printf 'security: ok\n'
