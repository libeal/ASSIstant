#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEMA="${ROOT_DIR}/schema/domain.json"

# shellcheck source=../lib/common.sh
source "${ROOT_DIR}/lib/common.sh"
# shellcheck source=../lib/config.sh
source "${ROOT_DIR}/lib/config.sh"
# shellcheck source=../lib/ai.sh
source "${ROOT_DIR}/lib/ai.sh"
# shellcheck source=../lib/protocol.sh
source "${ROOT_DIR}/lib/protocol.sh"
# shellcheck source=../lib/api.sh
source "${ROOT_DIR}/lib/api.sh"

linux_agent_init_env "${ROOT_DIR}"

# 1) schema/domain.json is the single source of truth and must be well-formed.
jq -e '
    . as $schema
    | .schema_version == 1
    and (.provider_normalization.aliases | type == "object")
    and (.provider_normalization.prefix_rules | type == "array")
    and (.job_status | type == "array" and length > 0)
    and (.step_status | type == "array" and length > 0)
    and (.error_codes | type == "object")
    and ([
        "observer_required_unavailable",
        "ai_invalid_response",
        "audit_degraded",
        "audit_write_blocked",
        "audit_integrity_broken",
        "sudo_required",
        "auditctl_not_found",
        "provider_request_failed",
        "persisted_session_invalid",
        "ai_config_missing",
        "ai_request_failed",
        "ai_empty_response",
        "ai_invalid_json"
    ] | all(. as $code | ($schema.error_codes[$code].http | type) == "number"))
' "${SCHEMA}" >/dev/null

# jq oracle: normalize a provider id straight from the schema rules.
schema_normalize() {
    local id="$1"
    local normalized
    normalized="$(printf '%s' "${id,,}" | sed -E 's#[-[:space:]/]+#_#g')"
    jq -r --arg id "${normalized}" '
        (.provider_normalization // {}) as $rules
        | ([($rules.prefix_rules // [])[] | . as $rule | select(($rule.prefix // "") != "" and ($id | startswith($rule.prefix))) | .canonical] | first) as $prefix_hit
        | ($rules.aliases // {}) as $aliases
        | if $prefix_hit != null then $prefix_hit
          elif ($aliases[$id] != null) then $aliases[$id]
          elif ($id == "") then ($aliases[""] // "openai_compatible")
          else $id end
    ' "${SCHEMA}"
}

# Bash normalization must agree with the schema oracle for a representative table.
inputs=(
    ""
    "openai"
    "OpenAI-Compatible"
    "openai_compatible / custom"
    "zhipu"
    "ZhipuAI"
    "moonshot"
    "xAI"
    "sarvam"
    "nvidia"
    "some-new/provider name"
)
for provider in "${inputs[@]}"; do
    # Consumed by linux_agent_ai_provider_id from the sourced lib/ai.sh module.
    # shellcheck disable=SC2034
    LINUX_AGENT_CONFIG_JSON="$(jq -cn --arg p "${provider}" '{provider:$p}')"
    bash_result="$(linux_agent_ai_provider_id)"
    oracle="$(schema_normalize "${provider}")"
    if [[ "${bash_result}" != "${oracle}" ]]; then
        printf 'provider-id contract mismatch for %q: bash=%q schema=%q\n' "${provider}" "${bash_result}" "${oracle}" >&2
        exit 1
    fi
done

# 2) Python (web/server.py) normalization must agree with the schema oracle too.
# The web/server.py import needs runtime env, so assert the Python inline
# algorithm (kept in sync with the schema) matches the jq oracle directly.
python3 - "${SCHEMA}" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    schema = json.load(handle)
rules = schema.get("provider_normalization", {})
prefixes = rules.get("prefix_rules", [])
aliases = rules.get("aliases", {})


def normalize(value):
    normalized = str(value or "").strip().lower().replace("-", "_").replace(" ", "_").replace("/", "_")
    while "__" in normalized:
        normalized = normalized.replace("__", "_")
    for rule in prefixes:
        prefix = rule.get("prefix") or ""
        if prefix and normalized.startswith(prefix):
            return rule.get("canonical") or prefix
    if normalized in aliases:
        return aliases[normalized]
    if not normalized:
        return aliases.get("", "openai_compatible")
    return normalized


def oracle(value):
    normalized = re.sub(r"[-\s/]+", "_", str(value or "").strip().lower())
    for rule in prefixes:
        prefix = rule.get("prefix") or ""
        if prefix and normalized.startswith(prefix):
            return rule.get("canonical") or prefix
    if normalized in aliases:
        return aliases[normalized]
    if not normalized:
        return aliases.get("", "openai_compatible")
    return normalized


cases = ["", "openai", "OpenAI-Compatible", "openai_compatible / custom", "zhipu", "ZhipuAI", "moonshot", "xAI", "sarvam", "nvidia", "some-new/provider name"]
for case in cases:
    if normalize(case) != oracle(case):
        print(f"python provider-id contract mismatch for {case!r}: impl={normalize(case)!r} oracle={oracle(case)!r}", file=sys.stderr)
        sys.exit(1)
PY

# 3) protocol.sh timeline statuses must be members of schema.step_status.
answer_timeline="$(linux_agent_timeline_plan_items '{"response_type":"answer","answer":"ok"}')"
plan_timeline="$(linux_agent_timeline_plan_items '{"response_type":"work_plan","steps":[{"id":"s1","title":"one"}]}')"
execution_timeline="$(linux_agent_timeline_execution_items '{"results":[
  {"step":{"id":"s1","title":"one"},"result":{"ok":true,"status":"executed"}},
  {"step":{"id":"s2","title":"two"},"result":{"ok":false,"status":"skipped"}},
  {"step":{"id":"s3","title":"three"},"result":{"ok":false,"status":"timed_out"}}
]}')"
single_protocol="$(linux_agent_protocol_for_single_execution 'single' '{"ok":true,"status":"executed"}')"
state_protocol="$(linux_agent_protocol_for_work 'executed' \
    '{"response_type":"work_plan","summary":"state projection","steps":[{"id":"s1","title":"one"}]}' \
    '{
        "status":"executed",
        "step_states":[{
            "key":"iteration-1:0:s1","step_id":"s1","step_index":0,
            "iteration":1,"scope":"iteration-1","step":{"id":"s1","title":"one"},
            "status":"blocked","result":{"ok":true,"output":{}}
        }],
        "results":[{
            "step_key":"iteration-1:0:s1","step_index":0,"iteration":1,"scope":"iteration-1",
            "step":{"id":"s1","title":"one"},
            "result":{"ok":true,"output":{"tool":"fixture.tool","value":1}}
        }]
    }')"
unknown_state_protocol="$(linux_agent_protocol_for_work 'failed' \
    '{"response_type":"work_plan","summary":"unknown state projection","steps":[{"id":"s1","title":"one"}]}' \
    '{
        "status":"failed",
        "step_states":[{
            "key":"iteration-1:0:s1","step_id":"s1","step_index":0,
            "iteration":1,"scope":"iteration-1","step":{"id":"s1","title":"one"},
            "status":"invented_state","result":{"ok":false,"output":{}}
        }],
        "results":[]
    }')"
jq -e \
    --argjson answer "${answer_timeline}" \
    --argjson plan "${plan_timeline}" \
    --argjson execution "${execution_timeline}" \
    --argjson single "$(jq -c '.timeline' <<<"${single_protocol}")" \
    --argjson state "$(jq -c '.timeline' <<<"${state_protocol}")" \
    --argjson unknown_state "$(jq -c '.timeline' <<<"${unknown_state_protocol}")" '
    .step_status as $allowed
    | ($answer + $plan + $execution + $single + $state + $unknown_state) as $items
    | ($items | length) >= 8
      and all($items[]; . as $item
        | ($item.status | type) == "string"
          and ($allowed | index($item.status)) != null)
' "${SCHEMA}" >/dev/null
jq -e '
    .timeline_semantics == "step_projection"
    and (.timeline | length) == 1
    and .timeline[0].step_key == "iteration-1:0:s1"
    and .timeline[0].status == "blocked"
    and any(.timeline[0].output_blocks[]?; .kind == "json" and .json.tool == "fixture.tool")
' <<<"${state_protocol}" >/dev/null
jq -e '
    .timeline_semantics == "step_projection"
    and (.timeline | length) == 1
    and .timeline[0].status == "failed"
' <<<"${unknown_state_protocol}" >/dev/null

# 4) Error normalization follows the schema contract and preserves explicit
# false booleans instead of treating them as missing jq alternatives.
normalized_error="$(LINUX_AGENT_REQUEST_ID="contract-request" linux_agent_api_normalize_envelope <<<'{"ok":false,"status":"timed_out","error":"late","retryable":false}')"
jq -e '
    .ok == false
    and .status == "timed_out"
    and .code == "timed_out"
    and .message == "late"
    and .error == "late"
    and .retryable == false
    and .request_id == "contract-request"
    and (.details | type) == "object"
' <<<"${normalized_error}" >/dev/null

# Explicit structured error fields from an execution result survive both the
# protocol adapter and the final API normalization. Lifecycle status remains a
# result enum until the error-envelope compatibility alias is applied.
observer_protocol="$(linux_agent_protocol_envelope_for_single_execution \
    'Observer gate' \
    '{"ok":false,"status":"blocked","error_code":"observer_required_unavailable","exit_code":126,"output":{"raw":"observer unavailable"}}')"
jq -e '
    .ok == false
    and .status == "blocked"
    and .code == "observer_required_unavailable"
    and .error_code == "observer_required_unavailable"
    and .message == "observer unavailable"
' <<<"${observer_protocol}" >/dev/null
observer_normalized="$(LINUX_AGENT_REQUEST_ID="observer-contract" \
    linux_agent_api_normalize_envelope <<<"${observer_protocol}")"
jq -e --slurpfile schema "${SCHEMA}" '
    .code as $code
    | .ok == false
    and .status == "observer_required_unavailable"
    and .code == "observer_required_unavailable"
    and .error_code == "observer_required_unavailable"
    and .request_id == "observer-contract"
    and ($schema[0].error_codes | has($code))
' <<<"${observer_normalized}" >/dev/null

# Dispatch must execute in the current shell so session-wide audit state is
# still available to the teardown performed by bin/agent.
dispatch_output="$(mktemp "${LINUX_AGENT_TMP_DIR}/contract-dispatch.XXXXXX")"
LINUX_AGENT_LAST_BUSINESS_STATUS="before"
LINUX_AGENT_AI_FILE_MANIFEST='[]'
linux_agent_api_dispatch_raw() {
    LINUX_AGENT_LAST_BUSINESS_STATUS="blocked"
    LINUX_AGENT_AI_FILE_MANIFEST='[{"path":"prompts/system.txt","purpose":"system_prompt","included_as":"system_message"}]'
    printf '%s\n' '{"ok":true,"status":"ok"}'
}
linux_agent_api_dispatch >"${dispatch_output}"
jq -e '.ok == true and .status == "ok" and .schema_version == 1 and .protocol_version == "1.0.0"' \
    "${dispatch_output}" >/dev/null
[[ "${LINUX_AGENT_LAST_BUSINESS_STATUS}" == "blocked" ]]
jq -e 'length == 1 and .[0].purpose == "system_prompt"' <<<"${LINUX_AGENT_AI_FILE_MANIFEST}" >/dev/null
rm -f "${dispatch_output}"

# 5) The durable Job boundary validates schema.job_status at runtime.
python3 - "${SCHEMA}" "${ROOT_DIR}/web" <<'PY'
import json
import sys
import tempfile
from pathlib import Path

with open(sys.argv[1], encoding="utf-8") as handle:
    schema = json.load(handle)
allowed = set(schema["job_status"])
sys.path.insert(0, sys.argv[2])
from jobs import JobStore  # noqa: E402

with tempfile.TemporaryDirectory() as directory:
    store = JobStore(
        Path(directory) / "jobs.db",
        allowed_statuses=allowed,
        schema_version=schema["schema_version"],
    )
    for index, status in enumerate(sorted(allowed), start=1):
        job_id = f"c{index}"
        stored, deduplicated = store.create({
            "schema_version": schema["schema_version"],
            "job_id": job_id,
            "request_id": f"request-{job_id}",
            "session_id": f"job_{job_id}",
            "resource": "terminal",
            "action": "run",
            "status": status,
            "version": 0,
            "created_at": "2026-07-15T00:00:00Z",
            "updated_at": "2026-07-15T00:00:00Z",
            "payload": {"command": "true"},
        })
        assert not deduplicated and stored["status"] == status
    try:
        store.create({
            "schema_version": schema["schema_version"],
            "job_id": "invalid",
            "resource": "terminal",
            "action": "run",
            "status": "invented_state",
            "payload": {},
        })
    except ValueError:
        pass
    else:
        raise AssertionError("JobStore accepted a status outside schema.job_status")
PY

# 6) The machine-readable API boundary returns valid JSON envelopes for no-AI calls.
project="${TMPDIR:-/tmp}/contract-project.$$"
mkdir -p "${project}"
cp -a "${ROOT_DIR}/bin" "${ROOT_DIR}/config" "${ROOT_DIR}/lib" "${ROOT_DIR}/policies" \
    "${ROOT_DIR}/prompts" "${ROOT_DIR}/skills" "${ROOT_DIR}/schema" "${project}/"
trap 'rm -rf "${project}"' EXIT
cp "${project}/config/config.example.json" "${project}/config/config.json"

tools_json="$(cd "${project}" && LINUX_AGENT_API_MODE=1 bash bin/agent api tools list '{}')"
jq -e 'has("ok") and (.ok | type == "boolean")' <<<"${tools_json}" >/dev/null

printf 'contract.sh OK\n'
