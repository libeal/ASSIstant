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
grep -q '"stage":"observer_session_started"' "${LINUX_AGENT_AUDIT_LOG}"
[[ "$(jq -r 'select(.stage=="execution_finished") | .stage' "${LINUX_AGENT_AUDIT_LOG}" | wc -l | tr -d ' ')" -eq 2 ]]
PATH="${fake_bin}:${PATH}" linux_agent_finish_session "tested"
grep -q -- '-d always,exit' "${audit_calls}"
grep -q '"stage":"observer_session_finished"' "${LINUX_AGENT_AUDIT_LOG}"
[[ "$(jq -r 'select(.stage=="observer_session_finished") | .payload.exec_count // 0' "${LINUX_AGENT_AUDIT_LOG}" | tail -1)" -ge 1 ]]
[[ "$(jq -r 'select(.stage=="observer_session_finished") | .payload.file_event_count // 0' "${LINUX_AGENT_AUDIT_LOG}" | tail -1)" -ge 1 ]]

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

printf 'observer: ok\n'
