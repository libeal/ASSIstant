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
report_failure() {
    local status=$?
    local line="${1:-unknown}"
    trap - ERR
    printf 'security: failed at line %s (exit=%s)\n' "${line}" "${status}" >&2
    return "${status}"
}
trap 'report_failure "${LINENO}"' ERR
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
# shellcheck source=../lib/editor.sh
source "${ROOT_DIR}/lib/editor.sh"

linux_agent_init_env "${ROOT_DIR}"
linux_agent_load_config

legacy_edit_json="$(jq -cn '{
    response_type:"skill_edit",
    skill:{name:"legacy-edit",description:"Legacy edit response fixture."},
    scripts:[{
        name:"run.sh",
        description:"Legacy script fixture.",
        content:"#!/usr/bin/env bash\nprintf \\\"{}\\\\n\\\"\n"
    }]
}')"
if linux_agent_validate_edit_response "${legacy_edit_json}"; then
    printf 'legacy edit JSON unexpectedly passed the next-major schema\n' >&2
    exit 1
fi
legacy_edit_result="$(linux_agent_review_edit_package "${legacy_edit_json}")"
jq -e '.ok == false and .status == "invalid_edit_package"' \
    <<<"${legacy_edit_result}" >/dev/null

# Config reads must reject ambiguous duplicate keys and non-standard finite
# values before jq can normalize them. The live Web gate uses the same parser.
(
    duplicate_config_file="${tmp_root}/duplicate-config.json"
    printf '%s\n' '{"web":{"sensitive_edits_enabled":true,"sensitive_edits_enabled":false}}' \
        >"${duplicate_config_file}"
    if LINUX_AGENT_CONFIG_FILE="${duplicate_config_file}" \
        linux_agent_load_config >"${tmp_root}/duplicate-config.out" 2>"${tmp_root}/duplicate-config.err"; then
        printf 'config loader unexpectedly accepted duplicate JSON keys\n' >&2
        exit 1
    fi
    if LINUX_AGENT_WEB=1 LINUX_AGENT_CONFIG_FILE="${duplicate_config_file}" \
        linux_agent_web_sensitive_edits_enabled; then
        printf 'sensitive edit gate unexpectedly accepted duplicate JSON keys\n' >&2
        exit 1
    fi
)
(
    non_finite_config_file="${tmp_root}/non-finite-config.json"
    printf '%s\n' '{"web":{"sensitive_edits_enabled":true},"value":NaN}' \
        >"${non_finite_config_file}"
    if LINUX_AGENT_CONFIG_FILE="${non_finite_config_file}" \
        linux_agent_load_config >"${tmp_root}/non-finite-config.out" 2>"${tmp_root}/non-finite-config.err"; then
        printf 'config loader unexpectedly accepted a non-finite JSON number\n' >&2
        exit 1
    fi
)

# The next-major lifecycle owns one package at a time. It must replace packages
# atomically, reject unsafe sources, preserve an installed version on failure,
# reserve builtin names from INDEX, and never create a user-level INDEX.
(
    lifecycle_root="${tmp_root}/skill-lifecycle"
    user_root="${lifecycle_root}/user"
    builtin_root="${lifecycle_root}/builtin"
    source_root="${lifecycle_root}/source"
    mkdir -p "${user_root}" "${builtin_root}" "${source_root}"
    printf '# Builtin Skills\n\n## reserved\n\n> Reserved builtin fixture.\n' \
        >"${builtin_root}/INDEX.md"

    write_instruction_skill() {
        local target="$1" name="$2" description="$3" body="$4"
        mkdir -p "${target}"
        printf '%s\n' \
            '---' \
            "name: ${name}" \
            "description: ${description}" \
            '---' \
            '' \
            "# ${name}" \
            '' \
            "${body}" >"${target}/SKILL.md"
    }

    write_instruction_skill "${source_root}/existing" existing \
        'Lifecycle replacement fixture.' 'version one'
    mkdir -p "${source_root}/existing/scripts" \
        "${source_root}/existing/references" "${source_root}/existing/assets"
    printf '#!/usr/bin/env bash\nprintf "%s\\n" v1\n' '{}' \
        >"${source_root}/existing/scripts/run.sh"
    printf 'reference v1\n' >"${source_root}/existing/references/note.txt"
    printf 'asset v1\n' >"${source_root}/existing/assets/blob"

    install_result="$(python3 "${ROOT_DIR}/lib/skill_lifecycle.py" install \
        "${source_root}/existing" --root "${user_root}" --origin user \
        --index "${builtin_root}/INDEX.md")"
    jq -e '.ok == true and .status == "installed" and .skill == "existing"' \
        <<<"${install_result}" >/dev/null
    [[ "$(<"${user_root}/existing/references/note.txt")" == 'reference v1' ]]
    [[ ! -e "${user_root}/INDEX.md" && ! -L "${user_root}/INDEX.md" ]]
    [[ "$(stat -c '%a' "${user_root}/existing")" == '750' ]]
    [[ "$(stat -c '%a' "${user_root}/existing/scripts/run.sh")" == '750' ]]
    [[ "$(stat -c '%a' "${user_root}/existing/SKILL.md")" == '640' ]]

    unsafe_root="${source_root}/unsafe"
    write_instruction_skill "${unsafe_root}" unsafe \
        'Unsafe symlink fixture.' 'must be rejected'
    ln -s /etc/passwd "${unsafe_root}/references-link"
    unsafe_result="$(python3 "${ROOT_DIR}/lib/skill_lifecycle.py" install \
        "${unsafe_root}" --root "${user_root}" --origin user \
        --index "${builtin_root}/INDEX.md" 2>/dev/null || true)"
    jq -e '.ok == false and .code == "skill_operation_failed"' \
        <<<"${unsafe_result}" >/dev/null
    [[ ! -e "${user_root}/unsafe" && ! -L "${user_root}/unsafe" ]]

    invalid_replacement="${source_root}/existing-invalid"
    mkdir -p "${invalid_replacement}"
    printf '%s\n' '---' 'name: existing' 'description: Invalid directory name.' \
        '---' '' '# existing' >"${invalid_replacement}/SKILL.md"
    replace_failure="$(python3 "${ROOT_DIR}/lib/skill_lifecycle.py" install \
        "${invalid_replacement}" --root "${user_root}" --origin user \
        --index "${builtin_root}/INDEX.md" --replace 2>/dev/null || true)"
    jq -e '.ok == false' <<<"${replace_failure}" >/dev/null
    [[ "$(<"${user_root}/existing/references/note.txt")" == 'reference v1' ]]

    rm -rf -- "${source_root}/existing"
    write_instruction_skill "${source_root}/existing" existing \
        'Lifecycle replacement fixture updated.' 'version two'
    mkdir -p "${source_root}/existing/scripts" \
        "${source_root}/existing/references" "${source_root}/existing/assets"
    printf '#!/usr/bin/env bash\nprintf "%s\\n" v2\n' '{}' \
        >"${source_root}/existing/scripts/run.sh"
    printf 'reference v2\n' >"${source_root}/existing/references/note.txt"
    printf 'asset v2\n' >"${source_root}/existing/assets/blob"
    replace_result="$(python3 "${ROOT_DIR}/lib/skill_lifecycle.py" install \
        "${source_root}/existing" --root "${user_root}" --origin user \
        --index "${builtin_root}/INDEX.md" --replace)"
    jq -e '.ok == true and .status == "replaced" and .replaced == true' \
        <<<"${replace_result}" >/dev/null
    [[ "$(<"${user_root}/existing/references/note.txt")" == 'reference v2' ]]
    [[ -z "$(find "${user_root}" -maxdepth 1 -name '.replaced.existing.*' -print -quit)" ]]

    write_instruction_skill "${source_root}/reserved" reserved \
        'Reserved collision fixture.' 'must be rejected'
    reserved_result="$(python3 "${ROOT_DIR}/lib/skill_lifecycle.py" install \
        "${source_root}/reserved" --root "${user_root}" --origin user \
        --index "${builtin_root}/INDEX.md" 2>/dev/null || true)"
    jq -e '.ok == false and (.error | contains("reserved"))' \
        <<<"${reserved_result}" >/dev/null
    [[ ! -e "${user_root}/reserved" && ! -L "${user_root}/reserved" ]]

    write_instruction_skill "${source_root}/legacy" legacy \
        'Legacy fixture.' 'must be rejected'
    printf '{}\n' >"${source_root}/legacy/manifest.json"
    legacy_result="$(python3 "${ROOT_DIR}/lib/skill_lifecycle.py" install \
        "${source_root}/legacy" --root "${user_root}" --origin user \
        --index "${builtin_root}/INDEX.md" 2>/dev/null || true)"
    jq -e '.ok == false and .code == "legacy_format_unsupported"' \
        <<<"${legacy_result}" >/dev/null

    uninstall_result="$(python3 "${ROOT_DIR}/lib/skill_lifecycle.py" uninstall existing \
        --root "${user_root}" --origin user)"
    jq -e '.ok == true and .status == "uninstalled" and .purged == false' \
        <<<"${uninstall_result}" >/dev/null
    [[ ! -e "${user_root}/existing" && ! -L "${user_root}/existing" ]]
    [[ ! -e "${user_root}/INDEX.md" && ! -L "${user_root}/INDEX.md" ]]
)

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
[[ "$(linux_agent_execution_privilege_from_review "${sudo_review}")" == "least" ]]

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

# Managed session-history receives one redacted audit snapshot rather than
# access to the protected log directory.
snapshot_logs="${tmp_root}/snapshot-logs"
snapshot_private_tmp="${tmp_root}/snapshot-private"
snapshot_runner_tmp="${tmp_root}/snapshot-runner"
snapshot_session="session_runner_snapshot"
snapshot_log="${snapshot_logs}/${snapshot_session}.jsonl"
mkdir -p "${snapshot_logs}" "${snapshot_private_tmp}" "${snapshot_runner_tmp}"
chmod 2750 "${snapshot_runner_tmp}"
for event in \
    '{"timestamp":"2026-07-22T00:00:00Z","session_id":"session_runner_snapshot","stage":"session_started","payload":{"request":"fixture"}}' \
    '{"timestamp":"2026-07-22T00:00:01Z","session_id":"session_runner_snapshot","stage":"received","payload":{"mode":"terminal","command":"printf previous-output","password":"snapshot-secret-marker"}}' \
    '{"timestamp":"2026-07-22T00:00:02Z","session_id":"session_runner_snapshot","stage":"terminal_executed","payload":{"status":"executed","exit_code":0,"output_preview":"previous-output"}}' \
    '{"timestamp":"2026-07-22T00:00:03Z","session_id":"session_runner_snapshot","stage":"received","payload":{"mode":"script","ref":"session-history/last-command-output"}}'; do
    printf '%s' "${event}" | python3 "${ROOT_DIR}/lib/audit_chain.py" append "${snapshot_log}" >/dev/null
done
old_log_dir="${LINUX_AGENT_LOG_DIR}"
old_tmp_dir="${LINUX_AGENT_TMP_DIR}"
old_runner_tmp_root="${LINUX_AGENT_RUNNER_TMP_ROOT}"
old_runner_tmp_dir="${LINUX_AGENT_RUNNER_TMP_DIR}"
old_builtin_skills="${LINUX_AGENT_BUILTIN_SKILLS_DIR}"
old_session_id="${LINUX_AGENT_SESSION_ID:-}"
LINUX_AGENT_LOG_DIR="${snapshot_logs}"
LINUX_AGENT_TMP_DIR="${snapshot_private_tmp}"
LINUX_AGENT_RUNNER_TMP_ROOT="${snapshot_runner_tmp}"
LINUX_AGENT_RUNNER_TMP_DIR="${snapshot_runner_tmp}"
LINUX_AGENT_BUILTIN_SKILLS_DIR="${ROOT_DIR}/skills"
LINUX_AGENT_SESSION_ID="${snapshot_session}"
linux_agent_prepare_session_history_snapshot skill bash \
    "${ROOT_DIR}/skills/session-history/scripts/last-command-output.sh" \
    '{}'
[[ -f "${LINUX_AGENT_RUNNER_AUDIT_SNAPSHOT}" ]]
[[ "$(stat -c '%a' "${LINUX_AGENT_RUNNER_AUDIT_SNAPSHOT}")" == "640" ]]
! grep -q 'snapshot-secret-marker' "${LINUX_AGENT_RUNNER_AUDIT_SNAPSHOT}"
snapshot_history="$(
    LINUX_AGENT_AUDIT_SNAPSHOT_FILE="${LINUX_AGENT_RUNNER_AUDIT_SNAPSHOT}" \
        LINUX_AGENT_AUDIT_SNAPSHOT_SESSION_ID="${snapshot_session}" \
        bash "${ROOT_DIR}/skills/session-history/scripts/last-command-output.sh" \
        '{}'
)"
jq -e '.ok == true and .session_id == "session_runner_snapshot"
    and .turn.input == "printf previous-output"
    and .outputs[0].output_preview == "previous-output"' <<<"${snapshot_history}" >/dev/null
staged_snapshot="${LINUX_AGENT_RUNNER_AUDIT_SNAPSHOT}"
linux_agent_cleanup_execution_staging
[[ ! -e "${staged_snapshot}" ]]
LINUX_AGENT_LOG_DIR="${old_log_dir}"
LINUX_AGENT_TMP_DIR="${old_tmp_dir}"
LINUX_AGENT_RUNNER_TMP_ROOT="${old_runner_tmp_root}"
LINUX_AGENT_RUNNER_TMP_DIR="${old_runner_tmp_dir}"
LINUX_AGENT_BUILTIN_SKILLS_DIR="${old_builtin_skills}"
LINUX_AGENT_SESSION_ID="${old_session_id}"

# Managed remote scripts are staged in the Runner-specific tree, not in the
# Web process's private tmp tree. The client-side classifier must agree with
# the Runner server's allowlisted tmp root.
runner_kind_private_tmp="${tmp_root}/runner-kind-private"
runner_kind_shared_tmp="${tmp_root}/runner-kind-shared"
mkdir -p "${runner_kind_private_tmp}" "${runner_kind_shared_tmp}"
runner_kind_script="${runner_kind_shared_tmp}/reviewed.sh"
printf '#!/usr/bin/env bash\nprintf "{}\\n"\n' >"${runner_kind_script}"
old_tmp_root="${LINUX_AGENT_TMP_ROOT}"
old_runner_tmp_root="${LINUX_AGENT_RUNNER_TMP_ROOT}"
LINUX_AGENT_TMP_ROOT="${runner_kind_private_tmp}"
LINUX_AGENT_RUNNER_TMP_ROOT="${runner_kind_shared_tmp}"
[[ "$(linux_agent_runner_kind_for_command bash "${runner_kind_script}" '{}')" == "remote_script" ]]
LINUX_AGENT_TMP_ROOT="${old_tmp_root}"
LINUX_AGENT_RUNNER_TMP_ROOT="${old_runner_tmp_root}"

linux_agent_init_env "${ROOT_DIR}"
linux_agent_load_config
low_review='{"approved":true,"approval_required":false,"risk_level":"low","findings":[]}'

# Helper-capable Skills may fall through only for fixed read/plan forms.  An
# ambiguous truthy apply value must be consumed as a helper rejection instead
# of reaching the ordinary same-UID/Runner execution path.
helper_fallback_output="${tmp_root}/helper-safe-fallback.out"
if linux_agent_maybe_execute_host_helper_skill \
    script '{"ref":"network-ops-tools/firewall"}' \
    bash "${ROOT_DIR}/skills/network-ops-tools/scripts/firewall.sh" \
    '{"action":"status"}' >"${helper_fallback_output}"; then
    printf 'read-only firewall request was incorrectly consumed by the helper route\n' >&2
    exit 1
fi
[[ ! -s "${helper_fallback_output}" ]]
ambiguous_helper_result="$(linux_agent_maybe_execute_host_helper_skill \
    script '{"ref":"network-ops-tools/firewall"}' \
    bash "${ROOT_DIR}/skills/network-ops-tools/scripts/firewall.sh" \
    '{"action":"apply","apply":"yes","confirm":"APPLY_FIREWALL_CHANGE"}')"
jq -e '.ok == false and .status == "helper_rejected"
    and .execution_proxy.isolation == "host_helper"' \
    <<<"${ambiguous_helper_result}" >/dev/null
hosts_plan_output="${tmp_root}/hosts-plan-fallback.out"
if linux_agent_maybe_execute_host_helper_skill \
    script '{"ref":"network-ops-tools/hosts-file-editor"}' \
    bash "${ROOT_DIR}/skills/network-ops-tools/scripts/hosts-file-editor.sh" \
    '{"action":"add","apply":false,"ip":"127.0.0.1","hostname":"fixture.test"}' \
    >"${hosts_plan_output}"; then
    printf 'non-applying hosts plan was incorrectly consumed by the helper route\n' >&2
    exit 1
fi
[[ ! -s "${hosts_plan_output}" ]]
direct_apply_output="${tmp_root}/helper-direct-apply.out"
if linux_agent_maybe_execute_host_helper_skill \
    script '{"ref":"network-ops-tools/firewall"}' \
    bash "${ROOT_DIR}/skills/network-ops-tools/scripts/firewall.sh" \
    '{"action":"apply","apply":true,"confirm":"APPLY_FIREWALL_CHANGE","port":443}' \
    >"${direct_apply_output}"; then
    printf 'source-runtime firewall apply was incorrectly consumed by the helper route\n' >&2
    exit 1
fi
[[ ! -s "${direct_apply_output}" ]]

export LINUX_AGENT_MANAGED_MODE=1
managed_apply_result="$(linux_agent_maybe_execute_host_helper_skill \
    script '{"ref":"network-ops-tools/firewall"}' \
    bash "${ROOT_DIR}/skills/network-ops-tools/scripts/firewall.sh" \
    '{"action":"apply","apply":true,"confirm":"APPLY_FIREWALL_CHANGE","port":443}')"
jq -e '.ok == false and .status == "helper_unavailable"
    and .execution_proxy.isolation == "host_helper"' \
    <<<"${managed_apply_result}" >/dev/null
export LINUX_AGENT_MANAGED_MODE=0

skill_success="$(linux_agent_normalize_skill_execution_result '{"ok":true,"exit_code":0,"output":{"ok":true,"status":"done"}}')"
skill_false="$(linux_agent_normalize_skill_execution_result '{"ok":true,"exit_code":0,"output":{"ok":false,"status":"business_failed"}}')"
skill_missing="$(linux_agent_normalize_skill_execution_result '{"ok":true,"exit_code":0,"output":{"status":"missing_ok"}}')"
skill_bad_type="$(linux_agent_normalize_skill_execution_result '{"ok":true,"exit_code":0,"output":{"ok":"true"}}')"
skill_nonzero="$(linux_agent_normalize_skill_execution_result '{"ok":false,"exit_code":7,"output":{"ok":true}}')"
jq -e '.ok == true and .status == "done"' <<<"${skill_success}" >/dev/null
jq -e '.ok == false and .status == "business_failed" and .code == "skill_reported_failure"' <<<"${skill_false}" >/dev/null
jq -e '.ok == false and .status == "invalid_skill_output"' <<<"${skill_missing}" >/dev/null
jq -e '.ok == false and .status == "invalid_skill_output"' <<<"${skill_bad_type}" >/dev/null
jq -e '.ok == false and .status == "skill_exit_failed"' <<<"${skill_nonzero}" >/dev/null

# 显式 false 的审批开关必须生效：jq 的 `//` 会把显式 false 当缺失，
# 此回归确保默认 true 的 approvals.auto.* 能被用户显式关闭。
approvals_config_backup="${LINUX_AGENT_CONFIG_JSON}"
LINUX_AGENT_CONFIG_JSON="$(jq '.approvals.auto = {skill_readonly:false, local_analyze:false, file_match:true}' <<<"${LINUX_AGENT_CONFIG_JSON}")"
[[ "$(linux_agent_auto_approval_enabled skill_readonly)" == "false" ]]
[[ "$(linux_agent_auto_approval_enabled local_analyze)" == "false" ]]
[[ "$(linux_agent_auto_approval_enabled file_match)" == "true" ]]
[[ "$(linux_agent_auto_approval_enabled file_patch)" == "false" ]]
LINUX_AGENT_CONFIG_JSON="${approvals_config_backup}"

# Skill business JSON is parsed from stdout only; harmless diagnostics on
# stderr must not turn an otherwise successful Skill into invalid JSON.
skill_stream_config="${LINUX_AGENT_CONFIG_JSON}"
LINUX_AGENT_CONFIG_JSON="$(jq '.observer.enabled="disabled" | .observer.require=false' <<<"${LINUX_AGENT_CONFIG_JSON}")"
skill_stream_result="$(
    LINUX_AGENT_EXECUTION_PRIVILEGE=current linux_agent_execute_observed_command_output \
        script '{"kind":"skill-stream-test"}' -- \
        bash -c 'printf '\''{"ok":true,"status":"done"}\n'\''; printf '\''diagnostic\n'\'' >&2'
)"
jq -e '.ok == true and .output.ok == true and .stderr == "diagnostic"' <<<"${skill_stream_result}" >/dev/null
skill_multi_result="$(
    LINUX_AGENT_EXECUTION_PRIVILEGE=current linux_agent_execute_observed_command_output \
        script '{"kind":"skill-multi-test"}' -- \
        bash -c 'printf '\''{"ok":true}\n{"ok":true}\n'\'''
)"
jq -e '.ok == false and .status == "invalid_skill_output"' <<<"${skill_multi_result}" >/dev/null
LINUX_AGENT_CONFIG_JSON="${skill_stream_config}"

degraded_audit_summary="$(linux_agent_audit_safe_summary terminal_executed \
    '{"ok":true,"exit_code":0,"output":{"raw":"ok"},"execution_proxy":{"isolation":"degraded_same_uid","requested_privilege":"least","execution_user":"tester","target_user":null,"prepared_root":false}}')"
jq -e '.execution_proxy.isolation == "degraded_same_uid"
    and .execution_proxy.execution_user == "tester"
    and .execution_proxy.prepared_root == false' <<<"${degraded_audit_summary}" >/dev/null
old_audit_log="${LINUX_AGENT_AUDIT_LOG:-}"
old_session_id="${LINUX_AGENT_SESSION_ID:-}"
LINUX_AGENT_AUDIT_LOG="${tmp_root}/degraded-execution.jsonl"
LINUX_AGENT_SESSION_ID="session_degraded_execution"
linux_agent_log_event terminal_executed \
    '{"ok":true,"exit_code":0,"output":{"raw":"ok"},"execution_proxy":{"isolation":"degraded_same_uid","requested_privilege":"least","execution_user":"tester","target_user":null,"prepared_root":false}}' \
    true
jq -e 'select(.stage == "terminal_executed")
    | .execution_isolation == "degraded_same_uid"
      and .execution_user == "tester"
      and .payload.execution_proxy.isolation == "degraded_same_uid"' \
    "${LINUX_AGENT_AUDIT_LOG}" >/dev/null
LINUX_AGENT_AUDIT_LOG="${old_audit_log}"
LINUX_AGENT_SESSION_ID="${old_session_id}"
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
skill_load_step='{"id":"load-1","title":"load","executor_type":"skill_load","skill":"ops-basic","arguments":{},"reason":"test","expected_effect":"loaded","risk_level":"low","rollback_hint":"none"}'
file_match_step='{"id":"auto-2","title":"match","executor_type":"skill_script","skill_script":"controlled-tools/file-match","arguments":{},"reason":"test","expected_effect":"test","risk_level":"low","rollback_hint":"none"}'
file_patch_step='{"id":"auto-3","title":"patch","executor_type":"skill_script","skill_script":"controlled-tools/file-patch","arguments":{},"reason":"test","expected_effect":"test","risk_level":"low","rollback_hint":"none"}'
shell_step='{"id":"auto-4","title":"shell","executor_type":"shell","command":"printf ok","arguments":{},"reason":"test","expected_effect":"test","risk_level":"low","rollback_hint":"none"}'
skill_load_result="$(linux_agent_execute_skill_file_step "${skill_load_step}")"
jq -e '.ok == true and .status == "read" and .output.skill == "ops-basic"
    and .output.path == "SKILL.md"
    and (.output.content | contains("# Ops Basic"))
    and (.output.content_sha256 | test("^[0-9a-f]{64}$"))' <<<"${skill_load_result}" >/dev/null
unloaded_block="$(linux_agent_step_disclosure_block "${readonly_skill_step}" '[]')"
jq -e '.status == "blocked" and .code == "skill_not_loaded"' <<<"${unloaded_block}" >/dev/null
loaded_disclosures="$(jq -cn --arg content "$(jq -r '.output.content' <<<"${skill_load_result}")" '[{name:"ops-basic",path:"SKILL.md",content:$content}]')"
if loaded_block="$(linux_agent_step_disclosure_block "${readonly_skill_step}" "${loaded_disclosures}")"; then
    printf 'loaded Skill was unexpectedly blocked: %s\n' "${loaded_block}" >&2
    exit 1
fi
auto_config="${LINUX_AGENT_CONFIG_JSON}"
LINUX_AGENT_CONFIG_JSON="$(jq 'del(.approvals) | .agent_loop.auto_execute_low_risk=false | .agent_loop.auto_execute_shell_low_risk=true' <<<"${auto_config}")"
# Removed pre-major-version agent_loop flags must not silently grant approval.
! linux_agent_should_auto_execute_step "${readonly_skill_step}" "${low_review}"
! linux_agent_should_auto_execute_step "${shell_step}" "${low_review}"
LINUX_AGENT_CONFIG_JSON="$(jq '.approvals.auto.skill_readonly=false | .approvals.auto.file_match=true | .approvals.auto.file_patch=false' <<<"${auto_config}")"
! linux_agent_should_auto_execute_step "${readonly_skill_step}" "${low_review}"
linux_agent_should_auto_execute_step "${file_match_step}" "${low_review}"
! linux_agent_should_auto_execute_step "${file_patch_step}" "${low_review}"
LINUX_AGENT_CONFIG_JSON="$(jq '.approvals.auto.skill_readonly=true | .approvals.auto.shell_readonly=false' <<<"${auto_config}")"
linux_agent_should_auto_execute_step "${readonly_skill_step}" "${low_review}"
linux_agent_should_auto_execute_step "${skill_load_step}" "${low_review}"
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
forged_mcp_step='{"id":"auto-mcp","title":"mcp","executor_type":"mcp_tool","mcp_server":"demo","mcp_tool":"echo","arguments":{},"reason":"test","expected_effect":"test","risk_level":"low","rollback_hint":"none"}'
LINUX_AGENT_CONFIG_JSON="$(jq '.approvals.auto.mcp_tool=true' <<<"${auto_config}")"
! linux_agent_should_auto_execute_step "${forged_mcp_step}" "${low_review}"
forced_mcp_review="$(linux_agent_policy_review_step "${forged_mcp_step}" 'mcp_tool=demo/echo' mcp)"
jq -e '.approved == true
    and .approval_required == true
    and .risk_level == "medium"
    and ([.findings[]? | select(.code == "MCP_TOOL_REQUIRES_APPROVAL")] | length) == 1' \
    <<<"${forced_mcp_review}" >/dev/null
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

mkdir -p "${mcp_exec_root}/input-tools"
cat >"${mcp_exec_root}/input-tools/mcp.json" <<JSON
{
  "manifest_version": 2,
  "id": "input-tools",
  "name": "Fake MCP input tools",
  "enabled": true,
  "transport": "stdio",
  "command": "python3",
  "args": ["${ROOT_DIR}/tests/fake_mcp_server.py", "stdio"],
  "env": {"FAKE_MCP_BEHAVIOR": "input_required"},
  "protocol": {"mode": "modern_only"}
}
JSON
mcp_input_plan="$(jq -cn '{
    response_type:"work_plan",
    summary:"mcp input continuation",
    continue_decision:{should_continue:false, reason:"test"},
    steps:[{
        id:"mcp-input-1",
        title:"call fake MCP input tool",
        executor_type:"mcp_tool",
        mcp_server:"input-tools",
        mcp_tool:"echo",
        arguments:{text:"hello"},
        reason:"test MCP input continuation",
        expected_effect:"pauses and resumes once",
        risk_level:"low",
        rollback_hint:"read-only fake tool"
    }]
}')"
LINUX_AGENT_API_INPUT_JSON='["y"]'
mcp_input_first="$(linux_agent_execute_work_plan "${mcp_input_plan}" "call MCP input tool" "{}")"
jq -e '.status == "awaiting_mcp_input"
    and .next_step_index == 0
    and (.results | length) == 1
    and .results[0].result.status == "awaiting_mcp_input"
    and .step_states[0].status == "awaiting_mcp_input"
    and (.resume_state.mcp_input.input_requests.email.params.mode == "form")
    and (.resume_state.mcp_input.continuation_id | test("^[0-9a-f]{32}$"))
    and ((tostring | contains("requestState")) | not)
    and ((tostring | contains("continuation_file")) | not)
    and ((tostring | contains("mcp-state.")) | not)' <<<"${mcp_input_first}" >/dev/null
mcp_input_continuation_id="$(jq -r '.resume_state.mcp_input.continuation_id' <<<"${mcp_input_first}")"
mcp_input_continuation_path="$(linux_agent_mcp_continuation_path "${mcp_input_continuation_id}")"
[[ -f "${mcp_input_continuation_path}" && "$(stat -c '%a' "${mcp_input_continuation_path}")" == "600" ]]
mcp_input_binding_path="${mcp_input_continuation_path%.json}.binding.json"
[[ -f "${mcp_input_binding_path}" && "$(stat -c '%a' "${mcp_input_binding_path}")" == "600" ]]
mcp_input_secret='MCP_PRIVATE_RESPONSE_7f6a1d9b'
mcp_input_review="$(linux_agent_mcp_input_review \
    "$(jq -c '.steps[0]' <<<"${mcp_input_plan}")" \
    "$(jq -cn --arg secret "${mcp_input_secret}" '{email:{action:"accept",content:{email:$secret}}}')")"
! grep -Fq "${mcp_input_secret}" <<<"${mcp_input_review}"
mcp_input_audit_payload="$(LINUX_AGENT_CONFIG_JSON="$(jq '.audit_mode="redacted_verbose"' <<<"${LINUX_AGENT_CONFIG_JSON}")" \
    linux_agent_audit_payload step_policy_checked \
    "$(jq -cn --argjson step "$(jq -c '.steps[0]' <<<"${mcp_input_plan}")" --argjson detail "${mcp_input_review}" \
        '{status:"policy_checked",step:$step,detail:$detail}')")"
! grep -Fq "${mcp_input_secret}" <<<"${mcp_input_audit_payload}"
LINUX_AGENT_API_INPUT_JSON='[]'
mcp_input_resumed="$(
    LINUX_AGENT_MCP_INPUT_RESPONSES_JSON='{"email":{"action":"accept","content":{"email":"user@example.test"}}}' \
        LINUX_AGENT_MCP_INPUT_RESPONSES_PRESENT=true \
        LINUX_AGENT_MCP_INPUT_CONFIRMED=true \
        LINUX_AGENT_MCP_INPUT_CANCELLED=false \
        linux_agent_execute_work_plan \
        "${mcp_input_plan}" \
        "call MCP input tool" \
        "$(jq -c '.resume_state' <<<"${mcp_input_first}")"
)"
jq -e '.status == "executed"
    and .next_step_index == 1
    and (.results | length) == 1
    and .results[0].result.ok == true
    and .results[0].result.status == "executed"
    and ((tostring | contains("user@example.test")) | not)
    and ((tostring | contains("inputResponses")) | not)' <<<"${mcp_input_resumed}" >/dev/null
[[ ! -e "${mcp_input_continuation_path}" ]]
[[ ! -e "${mcp_input_binding_path}" ]]

LINUX_AGENT_API_INPUT_JSON='["y"]'
mcp_input_cancel_first="$(linux_agent_execute_work_plan "${mcp_input_plan}" "cancel MCP input tool" "{}")"
mcp_input_cancel_id="$(jq -r '.resume_state.mcp_input.continuation_id' <<<"${mcp_input_cancel_first}")"
mcp_input_cancel_path="$(linux_agent_mcp_continuation_path "${mcp_input_cancel_id}")"
[[ -f "${mcp_input_cancel_path}" ]]
mcp_input_cancelled="$(
    LINUX_AGENT_MCP_INPUT_RESPONSES_PRESENT=false \
        LINUX_AGENT_MCP_INPUT_CONFIRMED=false \
        LINUX_AGENT_MCP_INPUT_CANCELLED=true \
        linux_agent_execute_work_plan \
        "${mcp_input_plan}" \
        "cancel MCP input tool" \
        "$(jq -c '.resume_state' <<<"${mcp_input_cancel_first}")"
)"
jq -e '.status == "failed"
    and .results[0].result.status == "mcp_input_cancelled"
    and .results[0].result.error_code == "mcp_input_cancelled"' \
    <<<"${mcp_input_cancelled}" >/dev/null
[[ ! -e "${mcp_input_cancel_path}" ]]
unknown_remote_execution="$(
    linux_agent_download_remote_script() {
        printf '#!/usr/bin/env bash\nvendor-diagnostic --status\n' >"$2"
    }
    unknown_remote_plan="$(jq -cn '{
        response_type:"work_plan",
        summary:"unknown remote command guard",
        continue_decision:{should_continue:false, reason:"test"},
        steps:[{
            id:"remote-unknown",
            title:"run unknown remote command",
            executor_type:"remote_script",
            url:"https://example.test/unknown.sh",
            arguments:{},
            reason:"test non-interactive command guard",
            expected_effect:"must be blocked",
            risk_level:"low",
            rollback_hint:"none"
        }]
    }')"
    linux_agent_execute_work_plan "${unknown_remote_plan}" "unknown remote command" "{}"
)"
jq -e '.status == "blocked"
    and ([.findings[] | select(.code == "NONINTERACTIVE_UNKNOWN_COMMAND_BLOCKED")] | length) == 1' \
    <<<"${unknown_remote_execution}" >/dev/null
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
