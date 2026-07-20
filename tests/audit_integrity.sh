#!/usr/bin/env bash

# Audit integrity: strict self-hashing chain, permissions, durable rotation,
# disk policy, Bash/Web parity, and adversarial/concurrent verification.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHAIN="${ROOT_DIR}/lib/audit_chain.py"

# shellcheck source=../lib/common.sh
source "${ROOT_DIR}/lib/common.sh"
# shellcheck source=../lib/config.sh
source "${ROOT_DIR}/lib/config.sh"
# shellcheck source=../lib/audit.sh
source "${ROOT_DIR}/lib/audit.sh"
# shellcheck source=../lib/api.sh
source "${ROOT_DIR}/lib/api.sh"

tmp_root="$(mktemp -d)"
cleanup() {
    linux_agent_audit_writer_stop 2>/dev/null || true
    rm -rf "${tmp_root}"
}
trap cleanup EXIT

verify_failure() {
    local log_path="$1"
    local output_name="$2"
    local report rc
    set +e
    report="$(python3 "${CHAIN}" verify "${log_path}")"
    rc=$?
    set -e
    [[ "${rc}" -eq 1 ]]
    printf -v "${output_name}" '%s' "${report}"
}

# Full-bootstrap project so `bin/agent audit verify` runs end-to-end against it.
project="${tmp_root}/project"
mkdir -p "${project}"
cp -a "${ROOT_DIR}/bin" "${ROOT_DIR}/config" "${ROOT_DIR}/lib" \
    "${ROOT_DIR}/policies" "${ROOT_DIR}/prompts" "${ROOT_DIR}/skills" \
    "${ROOT_DIR}/schema" "${project}/"
linux_agent_init_env "${project}"
linux_agent_load_config
unset LINUX_AGENT_AUDIT_CHAIN_ARGS

# Audit writer options must remain separate argv entries even when the caller's
# IFS disables implicit space splitting. Exercise both persistent and one-shot
# writer paths because each invokes audit_chain.py independently.
ifs_persistent_log="${tmp_root}/ifs-persistent.jsonl"
ifs_oneshot_log="${tmp_root}/ifs-oneshot.jsonl"
(
    IFS=
    event='{"timestamp":"t","session_id":"ifs","stage":"persistent","payload":{}}'
    LINUX_AGENT_AUDIT_LOG="${ifs_persistent_log}" linux_agent_audit_write_event "${event}"
    linux_agent_audit_writer_stop

    event='{"timestamp":"t","session_id":"ifs","stage":"oneshot","payload":{}}'
    LINUX_AGENT_AUDIT_LOG="${ifs_oneshot_log}" linux_agent_audit_append_oneshot "${event}"
)
jq -e '.stage == "persistent" and .session_id == "ifs"' "${ifs_persistent_log}" >/dev/null
jq -e '.stage == "oneshot" and .session_id == "ifs"' "${ifs_oneshot_log}" >/dev/null

# The persistent writer shares SIGINT with the CLI and must exit without a traceback.
PYTHONPATH="${ROOT_DIR}/lib" python3 - "${tmp_root}/interrupt.jsonl" <<'PY'
import sys

import audit_chain


class InterruptingInput:
    def __iter__(self):
        return self

    def __next__(self):
        raise KeyboardInterrupt


real_stdin = sys.stdin
try:
    sys.stdin = InterruptingInput()
    assert audit_chain._cli_serve([sys.argv[1]]) == 130
finally:
    sys.stdin = real_stdin
PY

# --- Part A: a real session is strictly chained, 0600, and verifies clean ---
linux_agent_start_session "audit integrity test"
session_id="${LINUX_AGENT_SESSION_ID}"
log_file="${project}/logs/${session_id}.jsonl"
writer_pid="${LINUX_AGENT_AUDIT_WRITER_PID}"
linux_agent_log_event "received" "$(jq -cn '{mode:"work", input:"disk check"}')"
linux_agent_log_event "planned" "$(jq -cn '{response_type:"answer"}')"
nested_log_rc="$(
    linux_agent_log_event "nested_shell" '{}'
    printf '%s' "$?"
)"
[[ "${nested_log_rc}" == "0" ]]
linux_agent_finish_session "tested"
[[ "${LINUX_AGENT_AUDIT_WRITER_PID}" == "${writer_pid}" ]]
kill -0 "${writer_pid}" 2>/dev/null

# The hash chain is a mandatory invariant: neither project config nor the
# low-level writer CLI may expose a path that emits unchained events.
if linux_agent_config_has_removed_integrity_chain '{"audit":{"integrity_chain":false}}'; then
    :
else
    printf 'removed audit.integrity_chain setting was not detected\n' >&2
    exit 1
fi
no_chain_log="${tmp_root}/no-chain.jsonl"
no_chain_stderr="${tmp_root}/no-chain.stderr"
set +e
printf '%s' '{"timestamp":"t","session_id":"no-chain","stage":"event","payload":{}}' |
    python3 "${CHAIN}" append "${no_chain_log}" --no-chain 2>"${no_chain_stderr}"
no_chain_rc=$?
set -e
[[ "${no_chain_rc}" -eq 2 ]]
[[ ! -e "${no_chain_log}" ]]
grep -q 'unknown option: --no-chain' "${no_chain_stderr}"

[[ "$(stat -c '%a' "${log_file}")" == "600" ]]
[[ "$(stat -c '%a' "${log_file}.lock")" == "600" ]]
jq -e '
    .seq == 1
    and (.prev_hash | test("^0{64}$"))
    and (.hash | test("^[0-9a-f]{64}$"))
' <<<"$(head -1 "${log_file}")" >/dev/null
jq -e '.seq and .prev_hash and .hash' <<<"$(tail -1 "${log_file}")" >/dev/null

verify_report="$(linux_agent_audit_verify_chain "${session_id}")"
jq -e '
    .ok == true
    and .status == "verified"
    and .events >= 3
    and .events == .chained_events
    and (.breaks | length) == 0
' <<<"${verify_report}" >/dev/null

# CLI wrapper agrees and does not open a new session.
cli_report="$(bash "${project}/bin/agent" audit verify "${session_id}")"
jq -e '.ok == true and .status == "verified"' <<<"${cli_report}" >/dev/null

# --- Part B: middle tampering is a verify concern, not an append-time scan ---
python3 - "${log_file}" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    lines = handle.read().splitlines()
event = json.loads(lines[1])
event["payload"] = {"tampered": True}
lines[1] = json.dumps(event, ensure_ascii=False, separators=(",", ":"))
with open(path, "w", encoding="utf-8") as handle:
    handle.write("\n".join(lines) + "\n")
PY
tampered_report=""
verify_failure "${log_file}" tampered_report
jq -e '
    .ok == false
    and any(.breaks[]; .line == 2 and .reason == "hash_mismatch")
' <<<"${tampered_report}" >/dev/null
tampered_line_count="$(wc -l <"${log_file}")"
set +e
printf '%s' '{"timestamp":"later","session_id":"tampered","stage":"append_after_tamper","payload":{}}' |
    python3 "${CHAIN}" append "${log_file}" >/dev/null 2>&1
tampered_append_rc=$?
set -e
[[ "${tampered_append_rc}" -eq 0 ]]
[[ "$(wc -l <"${log_file}")" -eq "$((tampered_line_count + 1))" ]]
jq -e '.stage == "append_after_tamper" and .seq > 1' <<<"$(tail -1 "${log_file}")" >/dev/null
tampered_after_append=""
verify_failure "${log_file}" tampered_after_append
jq -e 'any(.breaks[]; .line == 2 and .reason == "hash_mismatch")' <<<"${tampered_after_append}" >/dev/null

# --- Part C: rotation recursively verifies every archived segment ---
rot_log="${tmp_root}/rot.jsonl"
for i in 1 2 3; do
    printf '{"timestamp":"t%s","session_id":"rot","stage":"s%s","payload":{}}' "${i}" "${i}" |
        python3 "${CHAIN}" append "${rot_log}" --max-bytes 1 >/dev/null
done
[[ -f "${rot_log}.1" && -f "${rot_log}.2" ]]
rot_verify="$(python3 "${CHAIN}" verify "${rot_log}")"
jq -e '
    .ok == true
    and .events == 3
    and .segments == 3
    and .rotated_from != ""
' <<<"${rot_verify}" >/dev/null
jq -e '
    .seq == 3
    and (.rotated_from | length > 0)
    and (.hash | test("^[0-9a-f]{64}$"))
' <<<"$(tail -1 "${rot_log}")" >/dev/null

# List/read/show consume every numeric rotation segment in chronological order,
# rather than presenting only the current live tail.
api_session="session_rotated_api"
api_log="${LINUX_AGENT_LOG_DIR}/${api_session}.jsonl"
printf '%s' '{"timestamp":"t1","session_id":"session_rotated_api","stage":"session_started","payload":{"entrypoint":"cli"}}' |
    python3 "${CHAIN}" append "${api_log}" --max-bytes 1 >/dev/null
printf '%s' '{"timestamp":"t2","session_id":"session_rotated_api","stage":"received","payload":{"mode":"work"}}' |
    python3 "${CHAIN}" append "${api_log}" --max-bytes 1 >/dev/null
printf '%s' '{"timestamp":"t3","session_id":"session_rotated_api","stage":"session_finished","payload":{"status":"tested"}}' |
    python3 "${CHAIN}" append "${api_log}" --max-bytes 1 >/dev/null
api_list="$(linux_agent_api_audit_list "$(jq -cn --arg query "${api_session}" '{limit:1,query:$query}')")"
jq -e --arg session_id "${api_session}" '
    .ok == true
    and .limit == 1
    and (.sessions | length) == 1
    and .sessions[0].session_id == $session_id
    and .sessions[0].event_count == 3
    and .sessions[0].status == "tested"
' <<<"${api_list}" >/dev/null
api_limit="$(linux_agent_api_audit_list '{"limit":999999999999999999999999999999999999}')"
jq -e '.ok == true and .limit == 200' <<<"${api_limit}" >/dev/null
api_read="$(linux_agent_api_audit_read "$(jq -cn --arg session_id "${api_session}" '{session_id:$session_id}')")"
jq -e '
    .ok == true
    and (.events | length) == 3
    and [.events[].seq] == [1,2,3]
    and (.report | contains("session_rotated_api"))
' <<<"${api_read}" >/dev/null
show_report="$(linux_agent_show_audit "${api_session}")"
grep -q 'session_rotated_api' <<<"${show_report}"

# A configured verbose mode must survive the audit-boundary allowlist and keep
# the complete redacted payload available to the API/UI.
LINUX_AGENT_CONFIG_JSON="$(jq '.audit_mode="redacted_verbose"' <<<"${LINUX_AGENT_CONFIG_JSON}")"
unset LINUX_AGENT_AUDIT_CHAIN_ARGS
linux_agent_start_session "verbose audit test"
verbose_session_id="${LINUX_AGENT_SESSION_ID}"
long_payload="$(printf '%1200s' '' | tr ' ' 'x')"
linux_agent_log_event "received" "$(jq -cn --arg input "${long_payload}" '{mode:"work", input:$input, password:"verbose-secret"}')"
linux_agent_log_event "executed" '{"status":"executed","resume_state":{"thinking_summary":"private-thinking","next_step_index":1}}'
linux_agent_finish_session "tested"
verbose_log="${LINUX_AGENT_LOG_DIR}/${verbose_session_id}.jsonl"
jq -e --arg input "${long_payload}" '
    select(.stage == "received")
    | .payload.input == $input and .payload.password == "[REDACTED]"
' "${verbose_log}" >/dev/null
! grep -q 'private-thinking' "${verbose_log}"
jq -e '
    select(.stage == "executed")
    | .payload.resume_state.next_step_index == 1
        and (.payload.resume_state | has("thinking_summary") | not)
' "${verbose_log}" >/dev/null
grep -q '会话结束' <<<"${show_report}"

# --- Part D: disk-space degrade drops payload but preserves a valid chain ---
deg_log="${tmp_root}/deg.jsonl"
printf '{"timestamp":"t1","session_id":"deg","stage":"real","payload":{"secret":"KEEP1"}}' |
    python3 "${CHAIN}" append "${deg_log}" >/dev/null
printf '{"schema_version":1,"timestamp":"t2","session_id":"deg","stage":"real2","request_id":"req-deg","job_id":"job-deg","system_user":"system-deg","execution_user":"exec-deg","payload":{"secret":"KEEP2"}}' |
    python3 "${CHAIN}" append "${deg_log}" --min-free-bytes 999999999999999 >/dev/null
tail -1 "${deg_log}" | jq -e '
    .payload.audit_degraded == true
    and .stage == "real2"
    and .schema_version == 1
    and .request_id == "req-deg"
    and .job_id == "job-deg"
    and .system_user == "system-deg"
    and .execution_user == "exec-deg"
' >/dev/null
! grep -q 'KEEP2' <<<"$(tail -1 "${deg_log}")"
python3 "${CHAIN}" verify "${deg_log}" >/dev/null

# A failed free-space probe cannot silently bypass the configured policy.
space_probe_log="${tmp_root}/space-probe.jsonl"
PYTHONPATH="${ROOT_DIR}/lib" python3 - "${space_probe_log}" <<'PY'
import json
import sys

import audit_chain

path = sys.argv[1]
real_free_bytes = audit_chain._free_bytes
audit_chain._free_bytes = lambda _path: None
try:
    status = audit_chain.append_event(
        path,
        {"stage": "probe", "payload": {"secret": "drop"}},
        fsync=False,
        min_free_bytes=1,
        on_full="degrade",
    )
    assert status == "degraded"
    with open(path, encoding="utf-8") as handle:
        event = json.load(handle)
    assert event["payload"]["reason"] == "disk_space_check_failed"
    try:
        audit_chain.append_event(
            path,
            {"stage": "blocked", "payload": {}},
            fsync=False,
            min_free_bytes=1,
            on_full="block",
        )
    except audit_chain.AuditWriteBlocked:
        pass
    else:
        raise AssertionError("block policy ignored a failed free-space probe")
finally:
    audit_chain._free_bytes = real_free_bytes
PY

# --- Part E: on_full=block refuses the write (rc 3, no new event) ---
blk_log="${tmp_root}/blk.jsonl"
printf '{"timestamp":"t1","session_id":"blk","stage":"real","payload":{}}' |
    python3 "${CHAIN}" append "${blk_log}" >/dev/null
before_lines="$(wc -l <"${blk_log}")"
set +e
printf '{"timestamp":"t2","session_id":"blk","stage":"blocked","payload":{}}' |
    python3 "${CHAIN}" append "${blk_log}" --min-free-bytes 999999999999999 --on-full block
blk_rc=$?
set -e
[[ "${blk_rc}" -eq 3 ]]
[[ "$(wc -l <"${blk_log}")" -eq "${before_lines}" ]]

# --- Part F: CLI writer and the real Web adapter share one implementation ---
mix_log="${tmp_root}/mix.jsonl"
printf '{"timestamp":"t1","session_id":"mix","stage":"cli","payload":{}}' |
    python3 "${CHAIN}" append "${mix_log}" >/dev/null
PYTHONPATH="${ROOT_DIR}/web:${ROOT_DIR}/lib" python3 - "${mix_log}" <<'PY'
import sys

from audit import append_audit_event, audit_options_from_config

options = audit_options_from_config({"audit": {"fsync": False, "max_bytes": 1e3}})
assert "chain" not in options, options
assert options["fsync"] is False
assert options["max_bytes"] == 1000

try:
    audit_options_from_config({"audit": {"integrity_chain": False}})
except ValueError:
    pass
else:
    raise AssertionError("removed audit.integrity_chain was accepted by Web adapter")

append_audit_event(
    sys.argv[1],
    "mix",
    "web",
    {},
    config={
        "audit": {
            "max_bytes": 0,
            "min_free_bytes": 0,
        }
    },
)
PY
python3 "${CHAIN}" verify "${mix_log}" >/dev/null
[[ "$(jq -s 'length' "${mix_log}")" -eq 2 ]]
tail -1 "${mix_log}" | jq -e '.stage == "web" and .seq == 2 and .prev_hash and .hash' >/dev/null
web_block_log="${tmp_root}/web-block.jsonl"
PYTHONPATH="${ROOT_DIR}/web:${ROOT_DIR}/lib" python3 - "${web_block_log}" <<'PY'
import sys

from audit import AuditWriteBlocked, append_audit_event

try:
    append_audit_event(
        sys.argv[1],
        "web-block",
        "required",
        {},
        config={
            "audit": {
                "max_bytes": 0,
                "min_free_bytes": 999999999999999,
                "on_full": "block",
            }
        },
    )
except AuditWriteBlocked:
    pass
else:
    raise AssertionError("Web adapter swallowed audit.on_full=block")
PY
[[ ! -s "${web_block_log}" ]]

# --- Part G: changing the final event is detected without a successor ---
last_log="${tmp_root}/last.jsonl"
for i in 1 2; do
    printf '{"timestamp":"t%s","session_id":"last","stage":"s%s","payload":{"value":%s}}' "${i}" "${i}" "${i}" |
        python3 "${CHAIN}" append "${last_log}" >/dev/null
done
python3 - "${last_log}" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    lines = handle.read().splitlines()
event = json.loads(lines[-1])
event["payload"]["value"] = 999
lines[-1] = json.dumps(event, separators=(",", ":"))
with open(path, "w", encoding="utf-8") as handle:
    handle.write("\n".join(lines) + "\n")
PY
last_report=""
verify_failure "${last_log}" last_report
jq -e 'any(.breaks[]; .line == 2 and .reason == "hash_mismatch")' <<<"${last_report}" >/dev/null
last_line_count="$(wc -l <"${last_log}")"
set +e
printf '%s' '{"timestamp":"later","session_id":"last","stage":"must_not_append","payload":{}}' |
    python3 "${CHAIN}" append "${last_log}" >/dev/null 2>&1
last_append_rc=$?
set -e
[[ "${last_append_rc}" -eq 4 ]]
[[ "$(wc -l <"${last_log}")" -eq "${last_line_count}" ]]

# --- Part H: seq discontinuity and a legacy unchained log are rejected ---
seq_log="${tmp_root}/seq.jsonl"
for i in 1 2; do
    printf '{"timestamp":"t%s","session_id":"seq","stage":"s%s","payload":{}}' "${i}" "${i}" |
        python3 "${CHAIN}" append "${seq_log}" >/dev/null
done
python3 - "${seq_log}" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    lines = handle.read().splitlines()
event = json.loads(lines[-1])
event["seq"] = 999
lines[-1] = json.dumps(event, separators=(",", ":"))
with open(path, "w", encoding="utf-8") as handle:
    handle.write("\n".join(lines) + "\n")
PY
seq_report=""
verify_failure "${seq_log}" seq_report
jq -e 'any(.breaks[]; .line == 2 and .reason == "seq_mismatch")' <<<"${seq_report}" >/dev/null

legacy_log="${tmp_root}/legacy.jsonl"
printf '%s\n' '{"timestamp":"legacy","session_id":"legacy","stage":"old","payload":{}}' >"${legacy_log}"
legacy_report=""
verify_failure "${legacy_log}" legacy_report
jq -e '
    .ok == false
    and .chained_events == 0
    and any(.breaks[]; .reason == "missing_chain_fields")
' <<<"${legacy_report}" >/dev/null

# JSON that is valid but not an object, and malformed JSON, remain structured.
scalar_log="${tmp_root}/scalar.jsonl"
printf 'null\n' >"${scalar_log}"
scalar_report=""
verify_failure "${scalar_log}" scalar_report
jq -e 'any(.breaks[]; .line == 1 and .reason == "non_object")' <<<"${scalar_report}" >/dev/null

bad_json_log="${tmp_root}/bad-json.jsonl"
printf '{bad json}\n' >"${bad_json_log}"
bad_json_report=""
verify_failure "${bad_json_log}" bad_json_report
jq -e 'any(.breaks[]; .line == 1 and .reason == "invalid_json")' <<<"${bad_json_report}" >/dev/null

# --- Part I: tampering any old archive breaks verification of the live log ---
archive_log="${tmp_root}/archive.jsonl"
for i in 1 2 3 4; do
    printf '{"timestamp":"t%s","session_id":"archive","stage":"s%s","payload":{}}' "${i}" "${i}" |
        python3 "${CHAIN}" append "${archive_log}" --max-bytes 1 >/dev/null
done
python3 - "${archive_log}.1" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    event = json.load(handle)
event["payload"] = {"tampered_archive": True}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(event, handle, separators=(",", ":"))
    handle.write("\n")
PY
archive_report=""
verify_failure "${archive_log}" archive_report
jq -e '
    .events == 4
    and any(.breaks[]; (.path | endswith("archive.jsonl.1")) and .reason == "hash_mismatch")
' <<<"${archive_report}" >/dev/null
archive_live_count="$(wc -l <"${archive_log}")"
set +e
printf '%s' '{"timestamp":"later","session_id":"archive","stage":"append_after_archive_tamper","payload":{}}' |
    python3 "${CHAIN}" append "${archive_log}" >/dev/null 2>&1
archive_append_rc=$?
set -e
[[ "${archive_append_rc}" -eq 0 ]]
[[ "$(wc -l <"${archive_log}")" -eq "$((archive_live_count + 1))" ]]
archive_after_append=""
verify_failure "${archive_log}" archive_after_append
jq -e '
    any(.breaks[]; (.path | endswith("archive.jsonl.1")) and .reason == "hash_mismatch")
' <<<"${archive_after_append}" >/dev/null

# rotated_from cannot escape the log directory.
escape_log="${tmp_root}/escape.jsonl"
printf '%s' '{"timestamp":"t","session_id":"escape","stage":"s","payload":{}}' |
    python3 "${CHAIN}" append "${escape_log}" >/dev/null
python3 - "${escape_log}" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    event = json.load(handle)
event["rotated_from"] = "../outside.jsonl"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(event, handle, separators=(",", ":"))
    handle.write("\n")
PY
escape_report=""
verify_failure "${escape_log}" escape_report
jq -e 'any(.breaks[]; .reason == "rotation_path_escape")' <<<"${escape_report}" >/dev/null

# Rotation indices must strictly decrease, which rejects self/cyclic links
# before recursion can loop.
cycle_log="${tmp_root}/cycle.jsonl"
for i in 1 2; do
    printf '{"timestamp":"t%s","session_id":"cycle","stage":"s%s","payload":{}}' "${i}" "${i}" |
        python3 "${CHAIN}" append "${cycle_log}" --max-bytes 1 >/dev/null
done
PYTHONPATH="${ROOT_DIR}/lib" python3 - "${cycle_log}.1" <<'PY'
import json
import os
import sys

import audit_chain

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    event = json.load(handle)
event["rotated_from"] = os.path.basename(path)
event["hash"] = audit_chain.event_hash(event)
with open(path, "w", encoding="utf-8") as handle:
    json.dump(event, handle, separators=(",", ":"))
    handle.write("\n")
PY
cycle_report=""
verify_failure "${cycle_log}" cycle_report
jq -e 'any(.breaks[]; .reason == "invalid_rotation_order")' <<<"${cycle_report}" >/dev/null

# --- Part J: an event larger than the read block keeps a valid next link ---
large_log="${tmp_root}/large.jsonl"
python3 -c 'import json; print(json.dumps({"timestamp":"t1","session_id":"large","stage":"large","payload":{"text":"x" * 100000}}, separators=(",", ":")))' |
    python3 "${CHAIN}" append "${large_log}" >/dev/null
printf '%s' '{"timestamp":"t2","session_id":"large","stage":"next","payload":{}}' |
    python3 "${CHAIN}" append "${large_log}" >/dev/null
PYTHONPATH="${ROOT_DIR}/lib" python3 - "${large_log}" <<'PY'
import sys

import audit_chain

path = sys.argv[1]
real_last_nonempty_line = audit_chain._last_nonempty_line
calls = 0


def counted_last_nonempty_line(fd):
    global calls
    calls += 1
    return real_last_nonempty_line(fd)


audit_chain._last_nonempty_line = counted_last_nonempty_line
audit_chain.append_event(
    path,
    {"timestamp": "t3", "session_id": "large", "stage": "tail-read-once", "payload": {}},
    fsync=False,
)
assert calls == 1, calls
PY
large_report="$(python3 "${CHAIN}" verify "${large_log}")"
jq -e '.ok == true and .events == 3 and .chained_events == 3' <<<"${large_report}" >/dev/null
jq -e '.seq == 3 and .stage == "tail-read-once"' <<<"$(tail -1 "${large_log}")" >/dev/null

# --- Part K: append repairs an existing file's mode and protects its lock ---
mode_log="${tmp_root}/mode.jsonl"
: >"${mode_log}"
chmod 644 "${mode_log}"
printf '%s' '{"timestamp":"t","session_id":"mode","stage":"s","payload":{}}' |
    python3 "${CHAIN}" append "${mode_log}" >/dev/null
[[ "$(stat -c '%a' "${mode_log}")" == "600" ]]
[[ "$(stat -c '%a' "${mode_log}.lock")" == "600" ]]

# --- Part L: concurrent writers can rotate without loss or duplicate seq ---
concurrent_log="${tmp_root}/concurrent.jsonl"
PYTHONPATH="${ROOT_DIR}/lib" python3 - "${concurrent_log}" <<'PY'
import glob
import json
import os
import re
import sys

import audit_chain

path = sys.argv[1]
workers = 6
per_worker = 50
children = []

for worker in range(workers):
    pid = os.fork()
    if pid == 0:
        try:
            for index in range(per_worker):
                audit_chain.append_event(
                    path,
                    {
                        "timestamp": str(index),
                        "session_id": "concurrent",
                        "stage": "event",
                        "payload": {"worker": worker, "index": index, "pad": "x" * 80},
                    },
                    fsync=False,
                    max_bytes=700,
                    min_free_bytes=0,
                )
        except Exception as exc:  # noqa: BLE001 - child failure is asserted below.
            print(f"worker {worker}: {type(exc).__name__}: {exc}", file=sys.stderr, flush=True)
            os._exit(1)
        os._exit(0)
    children.append(pid)

statuses = [os.waitpid(pid, 0)[1] for pid in children]
assert all(os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0 for status in statuses), statuses

report = audit_chain.verify_chain(path)
assert report["ok"], report
expected = workers * per_worker
assert report["events"] == expected, report

rotation_pattern = re.compile(re.escape(path) + r"\.([1-9][0-9]*)$")
archives = []
for candidate in glob.glob(path + ".*"):
    match = rotation_pattern.fullmatch(candidate)
    if match:
        archives.append((int(match.group(1)), candidate))
ordered_files = [candidate for _, candidate in sorted(archives)] + [path]

events = []
for candidate in ordered_files:
    with open(candidate, encoding="utf-8") as handle:
        events.extend(json.loads(line) for line in handle if line.strip())

assert len(events) == expected, (len(events), expected)
assert sorted(event["seq"] for event in events) == list(range(1, expected + 1))
identities = {(event["payload"]["worker"], event["payload"]["index"]) for event in events}
assert len(identities) == expected
assert (os.stat(path).st_mode & 0o777) == 0o600
assert (os.stat(path + ".lock").st_mode & 0o777) == 0o600
PY

# --- Part M: a failed rotated append restores the last durable chain ---
rollback_log="${tmp_root}/rollback.jsonl"
PYTHONPATH="${ROOT_DIR}/lib" python3 - "${rollback_log}" <<'PY'
import os
import sys

import audit_chain

path = sys.argv[1]
audit_chain.append_event(path, {"stage": "one", "payload": {}}, fsync=False)
with open(path, "rb") as handle:
    original = handle.read()

real_write_all = audit_chain._write_all


def fail_after_partial_write(fd, data):
    os.write(fd, bytes(data[:10]))
    raise OSError("injected partial write")


audit_chain._write_all = fail_after_partial_write
try:
    try:
        audit_chain.append_event(
            path,
            {"stage": "two", "payload": {}},
            fsync=False,
            max_bytes=1,
        )
    except OSError:
        pass
    else:
        raise AssertionError("injected write failure was not propagated")
finally:
    audit_chain._write_all = real_write_all

with open(path, "rb") as handle:
    assert handle.read() == original
assert not os.path.exists(path + ".1")
assert audit_chain.verify_chain(path)["ok"]

# Simulate the recoverable crash window after rename and before live creation.
os.rename(path, path + ".1")
audit_chain.append_event(path, {"stage": "two", "payload": {}}, fsync=False)
report = audit_chain.verify_chain(path)
assert report["ok"] and report["events"] == 2, report
PY

# --- Part N: offline export snapshots rotations and ships verifiable checksums ---
export_session="session_export_rotated"
export_log="${LINUX_AGENT_LOG_DIR}/${export_session}.jsonl"
for i in 1 2 3; do
    printf '{"timestamp":"e%s","session_id":"%s","stage":"event","payload":{"index":%s}}' \
        "${i}" "${export_session}" "${i}" |
        python3 "${CHAIN}" append "${export_log}" --max-bytes 1 >/dev/null
done
second_export_session="session_export_second"
printf '%s' '{"timestamp":"e1","session_id":"session_export_second","stage":"event","payload":{}}' |
    python3 "${CHAIN}" append "${LINUX_AGENT_LOG_DIR}/${second_export_session}.jsonl" >/dev/null

export_dir="${tmp_root}/exports"
export_result="$(linux_agent_audit_export "${export_session}" --output "${export_dir}")"
jq -e --arg session_id "${export_session}" '
    .ok == true and .status == "exported" and .verified == true
    and .sessions == [$session_id]
' <<<"${export_result}" >/dev/null
export_archive="$(jq -r '.archive' <<<"${export_result}")"
[[ -f "${export_archive}" && "$(stat -c '%a' "${export_archive}")" == "600" ]]
export_extract="${tmp_root}/export-extract"
mkdir -p "${export_extract}"
tar -xzf "${export_archive}" -C "${export_extract}"
(cd "${export_extract}" && sha256sum -c SHA256SUMS >/dev/null)
[[ -f "${export_extract}/logs/${export_session}.jsonl.1" ]]
[[ -f "${export_extract}/logs/${export_session}.jsonl.2" ]]
jq -e '
    .ok == true and .events == 3 and .segments == 3
' "${export_extract}/reports/${export_session}.verify.json" >/dev/null
jq -e --arg session_id "${export_session}" '
    .schema_version == 1 and .verified == true
    and .sessions == [{
        session_id:$session_id,
        verified:true,
        events:3,
        files:[
            ("logs/" + $session_id + ".jsonl.1"),
            ("logs/" + $session_id + ".jsonl.2"),
            ("logs/" + $session_id + ".jsonl")
        ]
    }]
    and (.files | length) == 4
' "${export_extract}/export-manifest.json" >/dev/null
printf ' ' >>"${export_extract}/logs/${export_session}.jsonl"
if (cd "${export_extract}" && sha256sum -c SHA256SUMS >/dev/null 2>&1); then
    printf 'audit export checksum unexpectedly accepted a tampered copy\n' >&2
    exit 1
fi

all_export_result="$(linux_agent_audit_export --all --output "${export_dir}")"
jq -e --arg first "${export_session}" --arg second "${second_export_session}" '
    .ok == true and .status == "exported"
    and (.sessions | index($first)) != null
    and (.sessions | index($second)) != null
' <<<"${all_export_result}" >/dev/null

cli_export_dir="${tmp_root}/cli-exports"
cli_export="$(bash "${project}/bin/agent" audit export "${second_export_session}" --output "${cli_export_dir}")"
jq -e '.ok == true and .status == "exported" and .verified == true' <<<"${cli_export}" >/dev/null

api_export_dir="${tmp_root}/api-exports"
api_payload="$(jq -cn --arg session_id "${second_export_session}" --arg output "${api_export_dir}" '{session_id:$session_id,output:$output}')"
api_export="$(linux_agent_api_dispatch audit export "${api_payload}")"
jq -e '.ok == true and .status == "exported" and .verified == true and .schema_version == 1' <<<"${api_export}" >/dev/null

printf 'audit_integrity: ok\n'
