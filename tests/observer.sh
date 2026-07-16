#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/common.sh
source "${ROOT_DIR}/lib/common.sh"
# shellcheck source=../lib/config.sh
source "${ROOT_DIR}/lib/config.sh"
# shellcheck source=../lib/audit.sh
source "${ROOT_DIR}/lib/audit.sh"
# shellcheck source=../lib/observer.sh
source "${ROOT_DIR}/lib/observer.sh"
# shellcheck source=../lib/skills.sh
source "${ROOT_DIR}/lib/skills.sh"
# shellcheck source=../lib/executor.sh
source "${ROOT_DIR}/lib/executor.sh"
# shellcheck source=../lib/editor.sh
source "${ROOT_DIR}/lib/editor.sh"
# shellcheck source=../lib/orchestrator.sh
source "${ROOT_DIR}/lib/orchestrator.sh"

linux_agent_init_env "${ROOT_DIR}"
linux_agent_load_config

vault_policy="$(mktemp)"
vault_log="$(mktemp)"
printf '{"paths":["/tmp/linux-agent-observer-vault/*"]}\n' >"${vault_policy}"
export LINUX_AGENT_FILE_VAULT_POLICY_PATH="${vault_policy}"
LINUX_AGENT_AUDIT_LOG="${vault_log}"
LINUX_AGENT_SESSION_ID="session-vault-observer-test"
linux_agent_observer_log_file_vault_observations \
    '{"file_events":[{"name":"/tmp/linux-agent-observer-vault/nested/secret","syscall":"openat","flags":"0x241","success":"yes"},{"name":"/tmp/linux-agent-observer-vault/nested/other","syscall":"openat","flags":"577","success":"yes"}]}' \
    "session"
jq -e 'select(.stage == "file_vault_observed") | .payload.action == "modify" and .payload.observed_path_count == 2' "${vault_log}" >/dev/null
rm -f "${vault_policy}" "${vault_log}"
unset LINUX_AGENT_FILE_VAULT_POLICY_PATH LINUX_AGENT_AUDIT_LOG LINUX_AGENT_SESSION_ID

tmp_root="$(mktemp -d)"
cleanup() {
    rm -rf "${tmp_root}"
}
trap cleanup EXIT

LINUX_AGENT_CONFIG_JSON="$(jq '.observer.enabled="disabled"' <<<"${LINUX_AGENT_CONFIG_JSON}")"
linux_agent_start_session "observer disabled test"
disabled_stdout="${tmp_root}/disabled.stdout"
disabled_stderr="${tmp_root}/disabled.stderr"
disabled_meta="$(linux_agent_run_observed_process \
    "observer_disabled" \
    '{"kind":"test"}' \
    "${disabled_stdout}" \
    "${disabled_stderr}" \
    -- bash -c 'printf disabled-ok')"
grep -q 'disabled-ok' "${disabled_stdout}"
grep -q '"status":"recorded"' <<<"$(jq -c '.observer' <<<"${disabled_meta}")"
grep -q '"session_status":"disabled"' <<<"$(jq -c '.observer' <<<"${disabled_meta}")"
grep -q '"stage":"observer_unavailable"' "${LINUX_AGENT_AUDIT_LOG}"
linux_agent_finish_session "tested"
grep -q '"stage":"observer_session_finished"' "${ROOT_DIR}/logs/${safe_session_id:-${LINUX_AGENT_SESSION_ID}}.jsonl" 2>/dev/null || grep -q '"stage":"observer_session_finished"' "${LINUX_AGENT_AUDIT_LOG}"

LINUX_AGENT_CONFIG_JSON="$(jq '.execution.timeout_sec=1' <<<"${LINUX_AGENT_CONFIG_JSON}")"
timeout_stdout="${tmp_root}/timeout.stdout"
timeout_stderr="${tmp_root}/timeout.stderr"
timeout_meta="$(linux_agent_run_observed_process \
    "observer_timeout" \
    '{"kind":"timeout-test"}' \
    "${timeout_stdout}" \
    "${timeout_stderr}" \
    -- bash -c 'sleep 2')"
jq -e '.exit_code == 124 and .timed_out == true and .observer.status == "timed_out"' <<<"${timeout_meta}" >/dev/null
LINUX_AGENT_CONFIG_JSON="$(jq '.execution.timeout_sec=300' <<<"${LINUX_AGENT_CONFIG_JSON}")"

fake_bin="${tmp_root}/fake-bin"
mkdir -p "${fake_bin}"
audit_calls="${tmp_root}/audit.calls"

cat >"${fake_bin}/sudo" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-n" ]]; then
    shift
fi
exec "$@"
EOF
chmod +x "${fake_bin}/sudo"

cat >"${fake_bin}/auditctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${audit_calls}"
exit 0
EOF
chmod +x "${fake_bin}/auditctl"

cat >"${fake_bin}/ausearch" <<'EOF'
#!/usr/bin/env bash
key=""
while [[ $# -gt 0 ]]; do
    if [[ "$1" == "-k" ]]; then
        shift
        key="${1:-}"
    fi
    shift || true
done
cat <<AUDIT
type=SYSCALL msg=audit(1710000000.100:1): arch=c000003e syscall=59 success=yes exit=0 ppid=1 pid=123 auid=1000 uid=1000 gid=1000 comm="bash" exe="/usr/bin/bash" key="${key}"
type=EXECVE msg=audit(1710000000.100:1): argc=3 a0="bash" a1="-c" a2="printf ok"
type=PATH msg=audit(1710000000.200:2): item=0 name="/tmp/linux-agent-observer-test" inode=1 dev=00:00 mode=0100644 ouid=1000 ogid=1000 nametype=CREATE cap_fp=0 cap_fi=0 cap_fe=0 cap_fver=0
AUDIT
EOF
chmod +x "${fake_bin}/ausearch"

linux_agent_observer_audit_uid() {
    printf '1234\n'
}

LINUX_AGENT_CONFIG_JSON="$(jq '.observer.enabled="auto" | .observer.max_events=5' <<<"${LINUX_AGENT_CONFIG_JSON}")"
PATH="${fake_bin}:${PATH}" linux_agent_start_session "observer mock auditd test"
mock_stdout="${tmp_root}/mock.stdout"
mock_stderr="${tmp_root}/mock.stderr"
mock_meta="$(
    PATH="${fake_bin}:${PATH}" linux_agent_run_observed_process \
        "observer_mock" \
        '{"kind":"test"}' \
        "${mock_stdout}" \
        "${mock_stderr}" \
        -- bash -c 'printf mock-ok'
)"
second_stdout="${tmp_root}/second.stdout"
second_stderr="${tmp_root}/second.stderr"
PATH="${fake_bin}:${PATH}" linux_agent_run_observed_process \
    "observer_mock_second" \
    '{"kind":"test2"}' \
    "${second_stdout}" \
    "${second_stderr}" \
    -- bash -c 'printf second-ok' >/dev/null
grep -q 'mock-ok' "${mock_stdout}"
grep -q 'second-ok' "${second_stdout}"
grep -q '"status":"recorded"' <<<"$(jq -c '.observer' <<<"${mock_meta}")"
grep -q '"session_status":"running"' <<<"$(jq -c '.observer' <<<"${mock_meta}")"
grep -q -- '-a always,exit' "${audit_calls}"
grep -q -- '-F auid=1234' "${audit_calls}"
grep -q '"stage":"observer_session_started"' "${LINUX_AGENT_AUDIT_LOG}"
[[ "$(jq -r 'select(.stage=="execution_finished") | .stage' "${LINUX_AGENT_AUDIT_LOG}" | wc -l | tr -d ' ')" -eq 2 ]]
PATH="${fake_bin}:${PATH}" linux_agent_finish_session "tested"
grep -q -- '-d always,exit' "${audit_calls}"
grep -q '"stage":"observer_session_finished"' "${LINUX_AGENT_AUDIT_LOG}"
[[ "$(jq -r 'select(.stage=="observer_session_finished") | .payload.exec_count // 0' "${LINUX_AGENT_AUDIT_LOG}" | tail -1)" -eq 1 ]]
[[ "$(jq -r 'select(.stage=="observer_session_finished") | .payload.file_event_count // 0' "${LINUX_AGENT_AUDIT_LOG}" | tail -1)" -eq 1 ]]

fail_bin="${tmp_root}/fail-bin"
mkdir -p "${fail_bin}"
cat >"${fail_bin}/sudo" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-n" ]]; then
    shift
fi
exec "$@"
EOF
chmod +x "${fail_bin}/sudo"
cat >"${fail_bin}/auditctl" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-s" ]]; then
    printf 'Error sending status request (Operation not permitted)\n' >&2
    printf 'There was an error while processing parameters\n' >&2
    exit 1
fi
exit 0
EOF
chmod +x "${fail_bin}/auditctl"
cat >"${fail_bin}/ausearch" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${fail_bin}/ausearch"

PATH="${fail_bin}:${PATH}" linux_agent_start_session "observer auditctl permission test"
grep -q '"reason_code":"auditctl_permission_denied"' "${LINUX_AGENT_AUDIT_LOG}"
grep -q '"sudo_authenticated":true' "${LINUX_AGENT_AUDIT_LOG}"
PATH="${fail_bin}:${PATH}" linux_agent_finish_session "tested"
grep -q '"diagnostic"' "${LINUX_AGENT_AUDIT_LOG}"

boundary_project="${tmp_root}/boundary-project"
mkdir -p "${boundary_project}"
cp -a "${ROOT_DIR}/config" "${ROOT_DIR}/policies" "${boundary_project}/"
linux_agent_init_env "${boundary_project}"
linux_agent_load_config
LINUX_AGENT_CONFIG_JSON="$(jq '.observer.enabled="disabled"' <<<"${LINUX_AGENT_CONFIG_JSON}")"
boundary_tmp="$(mktemp)"
jq '.observing.application_events=["session_started","session_finished"] | .observing.observer_syscalls=[]' \
    "${boundary_project}/policies/audit-boundaries.json" >"${boundary_tmp}"
mv "${boundary_tmp}" "${boundary_project}/policies/audit-boundaries.json"
linux_agent_start_session "audit boundary application event filter"
linux_agent_log_event "received" "$(jq -cn '{mode:"work", input:"should not be logged"}')"
linux_agent_log_event "planned" "$(jq -cn '{response_type:"answer", answer:"should not be logged"}')"
linux_agent_finish_session "filtered"
grep -q '"stage":"session_started"' "${LINUX_AGENT_AUDIT_LOG}"
grep -q '"stage":"session_finished"' "${LINUX_AGENT_AUDIT_LOG}"
! grep -q '"stage":"received"' "${LINUX_AGENT_AUDIT_LOG}"
! grep -q '"stage":"planned"' "${LINUX_AGENT_AUDIT_LOG}"

boundary_syscall_project="${tmp_root}/boundary-syscall-project"
mkdir -p "${boundary_syscall_project}"
cp -a "${ROOT_DIR}/config" "${ROOT_DIR}/policies" "${boundary_syscall_project}/"
linux_agent_init_env "${boundary_syscall_project}"
linux_agent_load_config
LINUX_AGENT_CONFIG_JSON="$(jq '.observer.enabled="auto" | .observer.max_events=5' <<<"${LINUX_AGENT_CONFIG_JSON}")"
boundary_tmp="$(mktemp)"
jq '.observing.application_events=["session_started","observer_*","session_finished"] | .observing.observer_syscalls=["execve"] | .observing.observer_result_fields=["exec_count"]' \
    "${boundary_syscall_project}/policies/audit-boundaries.json" >"${boundary_tmp}"
mv "${boundary_tmp}" "${boundary_syscall_project}/policies/audit-boundaries.json"
: >"${audit_calls}"
PATH="${fake_bin}:${PATH}" linux_agent_start_session "audit boundary syscall filter"
PATH="${fake_bin}:${PATH}" linux_agent_finish_session "filtered"
grep -Eq -- '-S execve([[:space:]]|$)' "${audit_calls}"
! grep -Eq -- '-S openat([[:space:]]|$)' "${audit_calls}"
observer_payload="$(jq -c 'select(.stage=="observer_session_finished") | .payload' "${LINUX_AGENT_AUDIT_LOG}" | tail -1)"
jq -e '.exec_count >= 1 and .file_event_count == null and (.file_events | length) == 0' <<<"${observer_payload}" >/dev/null

# --- observer.require: every selected auditd rule must install or roll back ---
partial_project="${tmp_root}/partial-project"
partial_bin="${tmp_root}/partial-bin"
partial_calls="${tmp_root}/partial-audit.calls"
mkdir -p "${partial_project}" "${partial_bin}"
cp -a "${ROOT_DIR}/config" "${ROOT_DIR}/policies" "${partial_project}/"
cp "${partial_project}/config/config.example.json" "${partial_project}/config/config.json"
partial_tmp="$(mktemp)"
jq '.observer.enabled="auto" | .observer.require=true' \
    "${partial_project}/config/config.json" >"${partial_tmp}"
mv "${partial_tmp}" "${partial_project}/config/config.json"
partial_tmp="$(mktemp)"
jq '.observing.observer_syscalls=["execve","openat"]' \
    "${partial_project}/policies/audit-boundaries.json" >"${partial_tmp}"
mv "${partial_tmp}" "${partial_project}/policies/audit-boundaries.json"
cat >"${partial_bin}/sudo" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-n" ]]; then
    shift
fi
exec "$@"
EOF
chmod +x "${partial_bin}/sudo"
cat >"${partial_bin}/auditctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${partial_calls}"
if [[ " \$* " == *" -a always,exit "* && " \$* " == *" -S openat "* ]]; then
    exit 1
fi
exit 0
EOF
chmod +x "${partial_bin}/auditctl"
cat >"${partial_bin}/ausearch" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${partial_bin}/ausearch"

linux_agent_init_env "${partial_project}"
linux_agent_load_config
PATH="${partial_bin}:${PATH}" linux_agent_start_session "observer strict partial install"
jq -e '
    .status == "failed"
    and .available == false
    and .reason_code == "observer_rule_install_incomplete"
    and .selected_syscalls == ["execve", "openat"]
    and .attempted_installed_syscalls == ["execve"]
    and .rolled_back_syscalls == ["execve"]
    and (.installed_syscalls | length) == 0
' <<<"${LINUX_AGENT_OBSERVER_SESSION_CONTEXT}" >/dev/null
! linux_agent_observer_is_observing
! jq -e 'select(.stage == "observer_session_started")' "${LINUX_AGENT_AUDIT_LOG}" >/dev/null
jq -e 'select(.stage == "observer_failed")' "${LINUX_AGENT_AUDIT_LOG}" >/dev/null
grep -Eq -- '-a always,exit .* -S execve([[:space:]]|$)' "${partial_calls}"
grep -Eq -- '-a always,exit .* -S openat([[:space:]]|$)' "${partial_calls}"
grep -Eq -- '-d always,exit .* -S execve([[:space:]]|$)' "${partial_calls}"
partial_blocked="$(linux_agent_execute_observed_command_output "partial" '{"kind":"partial-install-test"}' -- bash -c 'printf PARTIAL_SHOULD_NOT_RUN')"
jq -e '.status == "blocked" and .error_code == "observer_required_unavailable"' <<<"${partial_blocked}" >/dev/null
! grep -q 'PARTIAL_SHOULD_NOT_RUN' <<<"${partial_blocked}"
PATH="${partial_bin}:${PATH}" linux_agent_finish_session "blocked"

# --- observer.require: a cached running context is revalidated at every gate ---
runtime_project="${tmp_root}/runtime-verify-project"
runtime_bin="${tmp_root}/runtime-verify-bin"
runtime_calls="${tmp_root}/runtime-verify-audit.calls"
runtime_rules="${tmp_root}/runtime-verify-audit.rules"
runtime_mode="${tmp_root}/runtime-verify-audit.mode"
mkdir -p "${runtime_project}" "${runtime_bin}"
cp -a "${ROOT_DIR}/config" "${ROOT_DIR}/policies" "${runtime_project}/"
cp "${runtime_project}/config/config.example.json" "${runtime_project}/config/config.json"
runtime_tmp="$(mktemp)"
jq '.observer.enabled="auto" | .observer.require=true' \
    "${runtime_project}/config/config.json" >"${runtime_tmp}"
mv "${runtime_tmp}" "${runtime_project}/config/config.json"
runtime_tmp="$(mktemp)"
jq '.observing.observer_syscalls=["execve","openat"]' \
    "${runtime_project}/policies/audit-boundaries.json" >"${runtime_tmp}"
mv "${runtime_tmp}" "${runtime_project}/policies/audit-boundaries.json"

export LINUX_AGENT_TEST_OBSERVER_CALLS="${runtime_calls}"
export LINUX_AGENT_TEST_OBSERVER_RULES="${runtime_rules}"
export LINUX_AGENT_TEST_OBSERVER_MODE="${runtime_mode}"
: >"${runtime_calls}"
: >"${runtime_rules}"
printf 'intact\n' >"${runtime_mode}"

cat >"${runtime_bin}/sudo" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-n" ]]; then
    shift
fi
exec "$@"
EOF
chmod +x "${runtime_bin}/sudo"

cat >"${runtime_bin}/auditctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${LINUX_AGENT_TEST_OBSERVER_CALLS}"
mode="$(<"${LINUX_AGENT_TEST_OBSERVER_MODE}")"
case "${1:-}" in
    -s)
        if [[ "${mode}" == "daemon_unavailable" ]]; then
            printf 'audit daemon unavailable\n' >&2
            exit 1
        fi
        exit 0
        ;;
    -l)
        if [[ "${mode}" == "missing_rule" ]]; then
            grep -v -- '-S openat ' "${LINUX_AGENT_TEST_OBSERVER_RULES}" || true
        else
            cat "${LINUX_AGENT_TEST_OBSERVER_RULES}"
        fi
        exit 0
        ;;
    -a)
        audit_key=""
        audit_uid=""
        syscall=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -S)
                    syscall="${2:-}"
                    shift 2
                    ;;
                -F)
                    if [[ "${2:-}" == auid=* ]]; then
                        audit_uid="${2#auid=}"
                    fi
                    shift 2
                    ;;
                -k)
                    audit_key="${2:-}"
                    shift 2
                    ;;
                *)
                    shift
                    ;;
            esac
        done
        printf -- '-a always,exit -F arch=b64 -S %s -F auid=%s -F key=%s\n' \
            "${syscall}" "${audit_uid}" "${audit_key}" >> "${LINUX_AGENT_TEST_OBSERVER_RULES}"
        exit 0
        ;;
    -d)
        exit 0
        ;;
esac
exit 0
EOF
chmod +x "${runtime_bin}/auditctl"

cat >"${runtime_bin}/ausearch" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${runtime_bin}/ausearch"

linux_agent_init_env "${runtime_project}"
linux_agent_load_config
PATH="${runtime_bin}:${PATH}" linux_agent_start_session "observer strict runtime rule loss"
jq -e '
    .status == "running"
    and .audit_uid == 1234
    and .installed_syscalls == ["execve", "openat"]
' <<<"${LINUX_AGENT_OBSERVER_SESSION_CONTEXT}" >/dev/null
runtime_install_count="$(grep -c -- '^-a always,exit' "${runtime_calls}")"
printf 'missing_rule\n' >"${runtime_mode}"
runtime_missing_marker="${tmp_root}/runtime-missing-should-not-run.marker"
runtime_missing_blocked="$(
    PATH="${runtime_bin}:${PATH}" linux_agent_execute_observed_command_output \
        "runtime_rule_missing" \
        '{"kind":"runtime-rule-missing-test"}' \
        -- bash -c 'printf executed > "$1"' _ "${runtime_missing_marker}"
)"
jq -e '
    .ok == false
    and .status == "blocked"
    and .error_code == "observer_required_unavailable"
    and .observer.status == "failed"
    and .observer.reason_code == "observer_rule_missing"
    and .observer.runtime_verification.phase == "rule_verification"
    and .observer.runtime_verification.missing_syscalls == ["openat"]
' <<<"${runtime_missing_blocked}" >/dev/null
[[ ! -e "${runtime_missing_marker}" ]]
[[ "$(grep -c -- '^-a always,exit' "${runtime_calls}")" -eq "${runtime_install_count}" ]]
jq -e '.status == "failed" and .reason_code == "observer_rule_missing"' \
    <<<"$(linux_agent_observer_current_context)" >/dev/null
runtime_list_count="$(grep -c -- '^-l$' "${runtime_calls}")"
runtime_missing_second_marker="${tmp_root}/runtime-missing-second-should-not-run.marker"
runtime_missing_second="$(
    PATH="${runtime_bin}:${PATH}" linux_agent_execute_observed_command_output \
        "runtime_rule_missing_second" \
        '{"kind":"runtime-rule-missing-second-test"}' \
        -- bash -c 'printf executed > "$1"' _ "${runtime_missing_second_marker}"
)"
jq -e '.status == "blocked" and .observer.status == "failed"' <<<"${runtime_missing_second}" >/dev/null
[[ ! -e "${runtime_missing_second_marker}" ]]
[[ "$(grep -c -- '^-l$' "${runtime_calls}")" -eq "${runtime_list_count}" ]]
jq -e '
    select(
        .stage == "observer_required_unavailable"
        and .payload.scope == "runtime_rule_missing"
        and .payload.status == "failed"
        and .payload.reason_code == "observer_rule_missing"
    )
' "${LINUX_AGENT_AUDIT_LOG}" >/dev/null
printf 'intact\n' >"${runtime_mode}"
PATH="${runtime_bin}:${PATH}" linux_agent_finish_session "blocked"
[[ ! -e "$(linux_agent_observer_failed_context_path)" ]]

# Start with a healthy observer again, then make preflight fail before the next
# command. The strict gate must not attempt to reinstall either rule.
: >"${runtime_calls}"
: >"${runtime_rules}"
PATH="${runtime_bin}:${PATH}" linux_agent_start_session "observer strict runtime daemon loss"
jq -e '.status == "running"' <<<"${LINUX_AGENT_OBSERVER_SESSION_CONTEXT}" >/dev/null
runtime_install_count="$(grep -c -- '^-a always,exit' "${runtime_calls}")"
printf 'daemon_unavailable\n' >"${runtime_mode}"
runtime_daemon_marker="${tmp_root}/runtime-daemon-should-not-run.marker"
runtime_daemon_blocked="$(
    PATH="${runtime_bin}:${PATH}" linux_agent_execute_observed_command_output \
        "runtime_daemon_unavailable" \
        '{"kind":"runtime-daemon-unavailable-test"}' \
        -- bash -c 'printf executed > "$1"' _ "${runtime_daemon_marker}"
)"
jq -e '
    .ok == false
    and .status == "blocked"
    and .error_code == "observer_required_unavailable"
    and .observer.status == "failed"
    and .observer.reason_code == "auditctl_failed"
    and .observer.runtime_verification.phase == "preflight"
' <<<"${runtime_daemon_blocked}" >/dev/null
[[ ! -e "${runtime_daemon_marker}" ]]
[[ "$(grep -c -- '^-a always,exit' "${runtime_calls}")" -eq "${runtime_install_count}" ]]
jq -e '.status == "failed" and .reason_code == "auditctl_failed"' \
    <<<"$(linux_agent_observer_current_context)" >/dev/null
jq -e '
    select(
        .stage == "observer_required_unavailable"
        and .payload.scope == "runtime_daemon_unavailable"
        and .payload.status == "failed"
        and .payload.reason_code == "auditctl_failed"
    )
' "${LINUX_AGENT_AUDIT_LOG}" >/dev/null
printf 'intact\n' >"${runtime_mode}"
PATH="${runtime_bin}:${PATH}" linux_agent_finish_session "blocked"
[[ ! -e "$(linux_agent_observer_failed_context_path)" ]]
unset LINUX_AGENT_TEST_OBSERVER_CALLS LINUX_AGENT_TEST_OBSERVER_RULES LINUX_AGENT_TEST_OBSERVER_MODE

# --- observer.require: runtime config loading rejects non-boolean values ---
invalid_project="${tmp_root}/invalid-require-project"
mkdir -p "${invalid_project}"
cp -a "${ROOT_DIR}/config" "${invalid_project}/"
cp "${invalid_project}/config/config.example.json" "${invalid_project}/config/config.json"
invalid_tmp="$(mktemp)"
jq '.observer.require="true"' "${invalid_project}/config/config.json" >"${invalid_tmp}"
mv "${invalid_tmp}" "${invalid_project}/config/config.json"
linux_agent_init_env "${invalid_project}"
if linux_agent_load_config >"${tmp_root}/invalid-require.stdout" 2>"${tmp_root}/invalid-require.stderr"; then
    printf 'observer.require string value unexpectedly passed runtime validation\n' >&2
    exit 1
fi
grep -q 'observer.require' "${tmp_root}/invalid-require.stderr"

# --- observer.require: strict-compliance gate refuses execution when unobserved ---
require_project="${tmp_root}/require-project"
mkdir -p "${require_project}"
cp -a "${ROOT_DIR}/config" "${ROOT_DIR}/policies" "${require_project}/"
linux_agent_init_env "${require_project}"
linux_agent_load_config
# observer disabled => session not observed; require on => execution must block.
LINUX_AGENT_CONFIG_JSON="$(jq '.observer.enabled="disabled" | .observer.require=true' <<<"${LINUX_AGENT_CONFIG_JSON}")"
linux_agent_observer_require_enabled
linux_agent_start_session "observer require blocked"
! linux_agent_observer_is_observing
require_blocked="$(linux_agent_execute_observed_command_output "script" '{"kind":"require-test"}' -- bash -c 'printf REQUIRE_SHOULD_NOT_RUN')"
jq -e '.ok == false and .status == "blocked" and .error_code == "observer_required_unavailable" and .exit_code == 126' <<<"${require_blocked}" >/dev/null
! grep -q 'REQUIRE_SHOULD_NOT_RUN' <<<"${require_blocked}"
grep -q '"stage":"observer_required_unavailable"' "${LINUX_AGENT_AUDIT_LOG}"

# Edit application is itself a side effect and must be gated before creating a
# target skill or any staging files. Stub only the preceding read-only review
# so this test isolates the apply boundary.
linux_agent_review_edit_package() {
    jq -cn '{ok:true, status:"approved", reviews:[]}'
}
direct_edit_skill="observer-direct-should-not-exist"
direct_edit_json="$(jq -cn --arg skill "${direct_edit_skill}" '{
    response_type:"skill_edit",
    skill:{name:$skill, description:"strict observer direct edit fixture"},
    scripts:[{
        name:"apply.sh",
        description:"No-argument test script.",
        content:"#!/usr/bin/env bash\nprintf direct-edit-should-not-run\\n"
    }]
}')"
direct_edit_blocked="$(linux_agent_apply_skill_edit_package_direct "${direct_edit_json}")"
jq -e '
    .ok == false
    and .status == "blocked"
    and .error_code == "observer_required_unavailable"
    and .exit_code == 126
' <<<"${direct_edit_blocked}" >/dev/null
[[ ! -e "${LINUX_AGENT_SKILLS_DIR}/${direct_edit_skill}" ]]
[[ ! -e "${LINUX_AGENT_TMP_DIR}/edit/${direct_edit_skill}" ]]

interactive_edit_skill="observer-interactive-should-not-exist"
interactive_edit_json="$(jq -cn --arg skill "${interactive_edit_skill}" '{
    response_type:"skill_edit",
    skill:{name:$skill, description:"strict observer interactive edit fixture"},
    scripts:[{
        name:"apply.sh",
        description:"No-argument test script.",
        content:"#!/usr/bin/env bash\nprintf interactive-edit-should-not-run\\n"
    }]
}')"
interactive_edit_blocked="$(linux_agent_apply_skill_edit_package "${interactive_edit_json}")"
jq -e '
    .ok == false
    and .status == "blocked"
    and .error_code == "observer_required_unavailable"
    and .exit_code == 126
' <<<"${interactive_edit_blocked}" >/dev/null
[[ ! -e "${LINUX_AGENT_SKILLS_DIR}/${interactive_edit_skill}" ]]
[[ ! -e "${LINUX_AGENT_TMP_DIR}/edit/${interactive_edit_skill}" ]]

# Remote materialization must gate before lock creation or curl. Keep the
# manifest valid enough that, without the gate, the fake curl marker and lock
# directory would both be created.
materialize_skill="observer-remote-should-not-exist"
materialize_root="${tmp_root}/materialize-side-effects"
materialize_skills="${materialize_root}/skills"
materialize_runtime="${materialize_root}/runtime"
materialize_manifest="${tmp_root}/materialize-manifest.json"
materialize_fake_bin="${tmp_root}/materialize-fake-bin"
materialize_curl_marker="${tmp_root}/materialize-curl-should-not-run.marker"
mkdir -p "${materialize_fake_bin}"
jq -cn --arg skill "${materialize_skill}" '{
    version:"v0.0.0-test",
    skills:{
        ($skill):{
            refs:[{ref:($skill + "/apply")}],
            asset:{
                name:("linux-agent-skill-" + $skill + ".tar.gz"),
                sha256:"0000000000000000000000000000000000000000000000000000000000000000",
                size_bytes:1,
                max_size_bytes:1024
            }
        }
    }
}' >"${materialize_manifest}"
cat >"${materialize_fake_bin}/curl" <<EOF
#!/usr/bin/env bash
printf executed > ${materialize_curl_marker@Q}
exit 1
EOF
chmod +x "${materialize_fake_bin}/curl"
materialize_blocked="$(
    PATH="${materialize_fake_bin}:${PATH}" \
        LINUX_AGENT_REMOTE_MODE=1 \
        LINUX_AGENT_REMOTE_MANIFEST="${materialize_manifest}" \
        LINUX_AGENT_REMOTE_RELEASE_BASE="file://${tmp_root}/unused-release" \
        LINUX_AGENT_ALLOW_INSECURE_TEST_URL=1 \
        LINUX_AGENT_SKILLS_DIR="${materialize_skills}" \
        LINUX_AGENT_TMP_ROOT="${materialize_runtime}" \
        linux_agent_materialize_skill "${materialize_skill}"
)"
jq -e '
    .ok == false
    and .status == "blocked"
    and .error_code == "observer_required_unavailable"
    and .exit_code == 126
' <<<"${materialize_blocked}" >/dev/null
[[ ! -e "${materialize_skills}/${materialize_skill}" ]]
[[ ! -e "${materialize_runtime}/skill-locks" ]]
[[ ! -e "${materialize_runtime}" ]]
[[ ! -e "${materialize_curl_marker}" ]]
jq -e 'select(.stage == "observer_required_unavailable" and .payload.scope == "edit_apply")' \
    "${LINUX_AGENT_AUDIT_LOG}" >/dev/null
jq -e 'select(.stage == "observer_required_unavailable" and .payload.scope == "skill_materialize")' \
    "${LINUX_AGENT_AUDIT_LOG}" >/dev/null

# Work shell and skill dispatch both retain the structured fail-closed result.
shell_blocked="$(linux_agent_execute_step_command \
    '{"id":"require-shell-dispatch","executor_type":"shell","command":"printf SHELL_SHOULD_NOT_RUN"}' '{}')"
jq -e '.status == "blocked" and .error_code == "observer_required_unavailable"' <<<"${shell_blocked}" >/dev/null
! grep -q 'SHELL_SHOULD_NOT_RUN' <<<"${shell_blocked}"
linux_agent_skill_script_path() {
    printf '%s\n' "${tmp_root}/skill-should-not-run.sh"
}
skill_blocked="$(linux_agent_execute_step_command \
    '{"id":"require-skill-dispatch","executor_type":"skill_script","skill_script":"test/blocked","arguments":{}}' '{}')"
jq -e '.status == "blocked" and .error_code == "observer_required_unavailable"' <<<"${skill_blocked}" >/dev/null

# MCP must not reinterpret the observer block as an MCP helper failure.
mcp_marker="${tmp_root}/mcp-should-not-run.marker"
mcp_client="${tmp_root}/mcp-should-not-run.py"
cat >"${mcp_client}" <<EOF
from pathlib import Path
Path(${mcp_marker@Q}).write_text("executed", encoding="utf-8")
EOF
linux_agent_mcp_manifest_path_by_id() {
    printf '/dev/null\n'
}
linux_agent_mcp_client_path() {
    printf '%s\n' "${mcp_client}"
}
mcp_blocked="$(linux_agent_execute_mcp_tool_step \
    '{"id":"require-mcp-dispatch","executor_type":"mcp_tool","mcp_server":"demo","mcp_tool":"echo","arguments":{}}' '{}')"
jq -e '.ok == false and .status == "blocked" and .error_code == "observer_required_unavailable" and .exit_code == 126' <<<"${mcp_blocked}" >/dev/null
[[ ! -e "${mcp_marker}" ]]

# The work-plan state machine must gate before publishing step_running.
linux_agent_policy_review_step() {
    jq -cn '{approved:true, approval_required:false, risk_level:"low", findings:[]}'
}
linux_agent_should_auto_execute_step() {
    return 0
}

# A remote step has a side-effectful preparation phase. Strict Observer mode
# must reject it before the downloader is called or a temporary script is
# materialized; the later runtime gate remains defense in depth.
remote_download_marker="${tmp_root}/remote-download-should-not-run.marker"
linux_agent_download_remote_script() {
    printf 'called\n' >"${remote_download_marker}"
    printf '#!/usr/bin/env bash\nprintf remote-should-not-run\n' >"$2"
}
remote_work_plan="$(jq -cn '{
    response_type:"work_plan",
    summary:"strict observer remote preparation gate",
    steps:[{
        id:"require-work-remote",
        title:"must not download",
        executor_type:"remote_script",
        url:"https://example.invalid/should-not-download.sh",
        risk_level:"high",
        reason:"test",
        expected_effect:"none"
    }]
}')"
remote_work_blocked="$(linux_agent_execute_work_plan "${remote_work_plan}" "observer require remote test" '{}')"
jq -e '
    .status == "blocked"
    and .results[0].result.error_code == "observer_required_unavailable"
    and .step_states[0].status == "blocked"
' <<<"${remote_work_blocked}" >/dev/null
[[ ! -e "${remote_download_marker}" ]]
! jq -e 'select(.stage == "step_running" and .payload.step.id == "require-work-remote")' \
    "${LINUX_AGENT_AUDIT_LOG}" >/dev/null

work_plan="$(jq -cn '{
    response_type:"work_plan",
    summary:"strict observer work gate",
    steps:[{
        id:"require-work-shell",
        title:"must remain blocked",
        executor_type:"shell",
        command:"printf WORK_SHOULD_NOT_RUN",
        risk_level:"low",
        reason:"test",
        expected_effect:"none"
    }]
}')"
work_blocked="$(linux_agent_execute_work_plan "${work_plan}" "observer require work test" '{}')"
jq -e '.status == "blocked" and .results[0].result.error_code == "observer_required_unavailable"' <<<"${work_blocked}" >/dev/null
! grep -q 'WORK_SHOULD_NOT_RUN' <<<"${work_blocked}"
! jq -e 'select(.stage == "step_running" and .payload.step.id == "require-work-shell")' "${LINUX_AGENT_AUDIT_LOG}" >/dev/null
jq -e 'select(.stage == "step_blocked" and .payload.step.id == "require-work-shell")' "${LINUX_AGENT_AUDIT_LOG}" >/dev/null

# Terminal is a real execution entrypoint and must use the same gate.
linux_agent_terminal_review() {
    jq -cn '{approved:true, approval_required:false, risk_level:"low", findings:[]}'
}
terminal_blocked="$(
    LINUX_AGENT_OUTPUT_JSON=1 LINUX_AGENT_API_MODE=1 \
        linux_agent_process_terminal_request "printf TERMINAL_SHOULD_NOT_RUN" true
)"
jq -e '.ok == false and .status == "blocked" and .error_code == "observer_required_unavailable" and .exit_code == 126' <<<"${terminal_blocked}" >/dev/null
! grep -q 'TERMINAL_SHOULD_NOT_RUN' <<<"$(jq -r '.stdout // ""' <<<"${terminal_blocked}")"
jq -e 'select(.stage == "observer_required_unavailable" and .payload.scope == "terminal")' "${LINUX_AGENT_AUDIT_LOG}" >/dev/null
! jq -e 'select(.stage == "terminal_executed")' "${LINUX_AGENT_AUDIT_LOG}" >/dev/null

linux_agent_finish_session "blocked"
# require off restores the default degrade-and-run posture.
LINUX_AGENT_CONFIG_JSON="$(jq '.observer.require=false' <<<"${LINUX_AGENT_CONFIG_JSON}")"
! linux_agent_observer_require_enabled

# Required audit events are execution preconditions. A refusal at any of the
# four step lifecycle boundaries must return a structured block and leave the
# command marker untouched.
audit_stage_calls="${tmp_root}/required-step-audit.calls"
audit_command_marker="${tmp_root}/audit-blocked-command.marker"
linux_agent_audit_require_event() {
    printf '%s\n' "$1" >>"${audit_stage_calls}"
    [[ "$1" != "${TEST_AUDIT_FAIL_STAGE:-}" ]] || return 3
}
audit_work_plan="$(jq -cn --arg marker "${audit_command_marker}" '{
    response_type:"work_plan",
    summary:"required audit failure propagation",
    steps:[{
        id:"audit-gated-shell",
        title:"must remain blocked",
        executor_type:"shell",
        command:("printf executed > " + ($marker | @sh)),
        risk_level:"low",
        reason:"test",
        expected_effect:"none"
    }]
}')"
for required_stage in step_pending step_policy_checked step_approved step_running; do
    : >"${audit_stage_calls}"
    rm -f "${audit_command_marker}"
    TEST_AUDIT_FAIL_STAGE="${required_stage}"
    audit_blocked="$(linux_agent_execute_work_plan "${audit_work_plan}" "audit failure test" '{}')"
    jq -e --arg stage "${required_stage}" '
        .status == "blocked"
        and .results[0].result.status == "blocked"
        and .results[0].result.code == "audit_write_blocked"
        and .results[0].result.error_code == "audit_write_blocked"
        and .results[0].result.details.audit_stage == $stage
        and .step_states[0].status == "blocked"
    ' <<<"${audit_blocked}" >/dev/null
    [[ ! -e "${audit_command_marker}" ]]
    grep -qx "${required_stage}" "${audit_stage_calls}"
done

execution_start_marker="${tmp_root}/audit-execution-start-command.marker"
: >"${audit_stage_calls}"
TEST_AUDIT_FAIL_STAGE="execution_started"
execution_start_blocked="$(linux_agent_execute_observed_command_output \
    "audit_execution_started" \
    '{"kind":"required-audit-test"}' \
    -- bash -c 'printf executed > "$1"' _ "${execution_start_marker}")"
jq -e '
    .ok == false
    and .status == "blocked"
    and .code == "audit_write_blocked"
    and .error_code == "audit_write_blocked"
    and .details.audit_stage == "execution_started"
' <<<"${execution_start_blocked}" >/dev/null
[[ ! -e "${execution_start_marker}" ]]
grep -qx 'execution_started' "${audit_stage_calls}"
unset TEST_AUDIT_FAIL_STAGE

printf 'observer: ok\n'
