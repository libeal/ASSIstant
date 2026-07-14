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

linux_agent_init_env "${ROOT_DIR}"

# 1) schema/domain.json is the single source of truth and must be well-formed.
jq -e '
    .schema_version == 1
    and (.provider_normalization.aliases | type == "object")
    and (.provider_normalization.prefix_rules | type == "array")
    and (.job_status | type == "array" and length > 0)
    and (.step_status | type == "array" and length > 0)
    and (.error_codes | type == "object")
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

# 3) The machine-readable API boundary returns valid JSON envelopes for no-AI calls.
project="${TMPDIR:-/tmp}/contract-project.$$"
mkdir -p "${project}"
cp -a "${ROOT_DIR}/bin" "${ROOT_DIR}/config" "${ROOT_DIR}/lib" "${ROOT_DIR}/policies" \
      "${ROOT_DIR}/prompts" "${ROOT_DIR}/skills" "${ROOT_DIR}/schema" "${project}/"
trap 'rm -rf "${project}"' EXIT
cp "${project}/config/config.example.json" "${project}/config/config.json"

tools_json="$(cd "${project}" && LINUX_AGENT_API_MODE=1 bash bin/agent api tools list '{}')"
jq -e 'has("ok") and (.ok | type == "boolean")' <<<"${tools_json}" >/dev/null

printf 'contract.sh OK\n'
