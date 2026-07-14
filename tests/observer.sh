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

linux_agent_init_env "${ROOT_DIR}"
linux_agent_load_config

vault_policy="$(mktemp)"
vault_log="$(mktemp)"
printf '{"paths":["/tmp/linux-agent-observer-vault/*"]}\n' > "${vault_policy}"
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

cat > "${fake_bin}/sudo" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-n" ]]; then
    shift
fi
exec "$@"
EOF
chmod +x "${fake_bin}/sudo"

cat > "${fake_bin}/auditctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${audit_calls}"
exit 0
EOF
chmod +x "${fake_bin}/auditctl"

cat > "${fake_bin}/ausearch" <<'EOF'
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
cat > "${fail_bin}/sudo" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-n" ]]; then
    shift
fi
exec "$@"
EOF
chmod +x "${fail_bin}/sudo"
cat > "${fail_bin}/auditctl" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-s" ]]; then
    printf 'Error sending status request (Operation not permitted)\n' >&2
    printf 'There was an error while processing parameters\n' >&2
    exit 1
fi
exit 0
EOF
chmod +x "${fail_bin}/auditctl"
cat > "${fail_bin}/ausearch" <<'EOF'
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
    "${boundary_project}/policies/audit-boundaries.json" > "${boundary_tmp}"
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
    "${boundary_syscall_project}/policies/audit-boundaries.json" > "${boundary_tmp}"
mv "${boundary_tmp}" "${boundary_syscall_project}/policies/audit-boundaries.json"
: > "${audit_calls}"
PATH="${fake_bin}:${PATH}" linux_agent_start_session "audit boundary syscall filter"
PATH="${fake_bin}:${PATH}" linux_agent_finish_session "filtered"
grep -Eq -- '-S execve([[:space:]]|$)' "${audit_calls}"
! grep -Eq -- '-S openat([[:space:]]|$)' "${audit_calls}"
observer_payload="$(jq -c 'select(.stage=="observer_session_finished") | .payload' "${LINUX_AGENT_AUDIT_LOG}" | tail -1)"
jq -e '.exec_count >= 1 and .file_event_count == null and (.file_events | length) == 0' <<<"${observer_payload}" >/dev/null

printf 'observer: ok\n'
