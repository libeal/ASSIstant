#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/workflow.sh
source "${ROOT_DIR}/lib/workflow.sh"

tmp_root="$(mktemp -d)"
cleanup() {
    rm -rf "${tmp_root}"
}
trap cleanup EXIT

event_log="${tmp_root}/events"
TEST_RESPONSE='{}'
TEST_LOOP=false
TEST_AUDIT_FAIL_STAGE=''

linux_agent_log_event() {
    printf '%s\n' "$1" >>"${event_log}"
    if [[ -n "${TEST_AUDIT_FAIL_STAGE}" && "$1" == "${TEST_AUDIT_FAIL_STAGE}" ]]; then
        return 3
    fi
}
linux_agent_detect_topic() { printf 'resource\n'; }
linux_agent_sense_topic() { printf '{"topic":"resource"}\n'; }
linux_agent_redact_json() { printf '%s\n' "$1"; }
linux_agent_build_request_context() {
    jq -cn --arg input "$1" --argjson sensed "$2" '{current_request:$input, sensed:$sensed}'
}
linux_agent_add_agent_loop_context() { jq -c '. + {agent_loop:{}}' <<<"$1"; }
linux_agent_add_skill_context() { jq -c '. + {skills:[]}' <<<"$1"; }
linux_agent_add_mcp_context() { jq -c '. + {mcp:[]}' <<<"$1"; }
linux_agent_record_ai_request_files() { :; }
linux_agent_call_ai_with_context() { printf '%s\n' "${TEST_RESPONSE}"; }
linux_agent_normalize_model_response() { printf '%s\n' "$1"; }
linux_agent_store_thinking_summary() { :; }
linux_agent_ai_response_is_error() { jq -e '.test_ai_error == true' >/dev/null <<<"$1"; }
linux_agent_ai_error_text() { jq -r '.error // "AI failed"' <<<"$1"; }
linux_agent_validate_work_response() {
    jq -e '(.response_type == "answer" or .response_type == "work_plan") and .test_invalid != true' \
        >/dev/null <<<"$1"
}
linux_agent_response_without_thinking() { jq -c 'del(.thinking_summary)' <<<"$1"; }
linux_agent_agent_loop_enabled() { printf '%s\n' "${TEST_LOOP}"; }
linux_agent_run_agent_loop() {
    jq -cn \
        --arg input "$1" \
        --arg mode "$2" \
        --argjson context "$3" \
        --argjson response "$4" \
        --argjson state "$5" \
        '{status:"executed", engine:"loop", input:$input, mode:$mode, context:$context, response:$response, state:$state, results:[]}'
}
linux_agent_execute_work_plan() {
    jq -cn \
        --argjson response "$1" \
        --arg input "$2" \
        --argjson state "$3" \
        '{status:"executed", engine:"single", input:$input, response:$response, state:$state, results:[]}'
}

event_count() {
    local stage="$1"
    awk -v stage="${stage}" '$0 == stage { count += 1 } END { print count + 0 }' "${event_log}"
}

assert_event_count() {
    local stage="$1"
    local expected="$2"
    local actual
    actual="$(event_count "${stage}")"
    if [[ "${actual}" != "${expected}" ]]; then
        printf 'unexpected event count: stage=%s expected=%s actual=%s\n' \
            "${stage}" "${expected}" "${actual}" >&2
        exit 1
    fi
}

assert_common_prepare_events() {
    assert_event_count received 1
    assert_event_count sensed 1
    assert_event_count request_context_built 1
}

reset_events() {
    : >"${event_log}"
}

reset_events
TEST_RESPONSE='{"response_type":"answer","answer":"done","thinking_summary":"private"}'
answer="$(linux_agent_prepare_work_request "answer request" "work")"
jq -e '.ok == true and .status == "prepared" and .response.answer == "done" and .context.topic == "resource"' \
    >/dev/null <<<"${answer}"
assert_common_prepare_events
assert_event_count planned 1
assert_event_count ai_failed 0
assert_event_count ai_invalid_response 0

reset_events
TEST_RESPONSE='{"ok":false,"status":"ai_config_missing","error":"missing key","test_ai_error":true}'
ai_error="$(linux_agent_prepare_work_request "error request" "work")"
jq -e '.ok == false and .status == "ai_config_missing" and .error == "missing key"' \
    >/dev/null <<<"${ai_error}"
assert_common_prepare_events
assert_event_count ai_failed 1
assert_event_count planned 0
assert_event_count ai_invalid_response 0

reset_events
TEST_RESPONSE='{"response_type":"invalid","test_invalid":true}'
invalid="$(linux_agent_prepare_work_request "invalid request" "work")"
jq -e '.ok == false and .status == "ai_invalid_response"' >/dev/null <<<"${invalid}"
assert_common_prepare_events
assert_event_count ai_invalid_response 1
assert_event_count planned 0
assert_event_count ai_failed 0

reset_events
TEST_AUDIT_FAIL_STAGE='sensed'
audit_blocked="$(linux_agent_prepare_work_request "blocked request" "work")"
jq -e '.ok == false
    and .status == "blocked"
    and .code == "audit_write_blocked"
    and .details.audit_stage == "sensed"' >/dev/null <<<"${audit_blocked}"
assert_event_count received 1
assert_event_count sensed 1
assert_event_count request_context_built 0
assert_event_count planned 0
TEST_AUDIT_FAIL_STAGE=''

reset_events
TEST_RESPONSE='{"response_type":"work_plan","summary":"plan","steps":[]}'
work_plan="$(linux_agent_prepare_work_request "plan request" "work")"
jq -e '.ok == true and .response.response_type == "work_plan"' >/dev/null <<<"${work_plan}"
assert_common_prepare_events
assert_event_count planned 1
assert_event_count ai_failed 0
assert_event_count ai_invalid_response 0

plan='{"response_type":"work_plan","steps":[]}'
context='{"topic":"resource"}'
state='{"next_step_index":2}'
TEST_LOOP=false
single="$(linux_agent_execute_prepared_work "run" "work" "${context}" "${plan}" "${state}")"
jq -e '.used_agent_loop == false
    and .execution.engine == "single"
    and .execution.state.next_step_index == 2' >/dev/null <<<"${single}"

TEST_LOOP=true
loop="$(linux_agent_execute_prepared_work "run" "work" "${context}" "${plan}" "${state}")"
jq -e '.used_agent_loop == true
    and .execution.engine == "loop"
    and .execution.state.next_step_index == 2' >/dev/null <<<"${loop}"

printf 'workflow_unit: ok\n'
