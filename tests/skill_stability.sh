#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=helpers.sh
source "${ROOT_DIR}/tests/helpers.sh"
linux_agent_test_install_failure_trap skill_stability

tmp_root="$(mktemp -d)"
fake_pid=""
web_pid=""
cleanup() {
    [[ -z "${web_pid}" ]] || kill "${web_pid}" >/dev/null 2>&1 || true
    [[ -z "${fake_pid}" ]] || kill "${fake_pid}" >/dev/null 2>&1 || true
    [[ -z "${web_pid}" ]] || wait "${web_pid}" 2>/dev/null || true
    [[ -z "${fake_pid}" ]] || wait "${fake_pid}" 2>/dev/null || true
    rm -rf -- "${tmp_root}"
}
trap cleanup EXIT

free_port() {
    python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

fake_port="$(free_port)"
web_port="$(free_port)"
python3 "${ROOT_DIR}/tests/fake_ai_server.py" "${fake_port}" \
    >"${tmp_root}/fake.stdout" 2>"${tmp_root}/fake.stderr" &
fake_pid="$!"
for _ in $(seq 1 100); do
    curl --noproxy '*' -fsS "http://127.0.0.1:${fake_port}/health" >/dev/null 2>&1 && break
    sleep 0.02
done
curl --noproxy '*' -fsS "http://127.0.0.1:${fake_port}/health" >/dev/null

project="${tmp_root}/project"
mkdir -p "${project}"
cp -a "${ROOT_DIR}/bin" "${ROOT_DIR}/config" "${ROOT_DIR}/lib" \
    "${ROOT_DIR}/mcp" "${ROOT_DIR}/policies" "${ROOT_DIR}/prompts" \
    "${ROOT_DIR}/schema" "${ROOT_DIR}/third_party" "${ROOT_DIR}/web" \
    "${project}/"
mkdir -p "${project}/skills" "${project}/logs" "${project}/tmp"
printf '# Skill Index\n' >"${project}/skills/INDEX.md"
jq --arg url "http://127.0.0.1:${fake_port}/v1/chat/completions" \
    --argjson port "${web_port}" '
    .api_url = $url
    | .api_key = "TEST_CONFIG_API_KEY_123456"
    | .model = "fake-chat-completions"
    | .observer.enabled = "disabled"
    | .observer.require = false
    | .approvals.auto.shell_readonly = true
    | .providers_security.allowed_hosts = ["127.0.0.1"]
    | .web.host = "127.0.0.1"
    | .web.port = $port
    | .web.token = "skill-matrix-token"
' "${project}/config/config.example.json" >"${project}/config/config.json"

zero_list="$(cd "${project}" && bash bin/agent skills list)"
jq -e '.ok == true and .status == "listed" and .skills == [] and .tools == []' \
    <<<"${zero_list}" >/dev/null
zero_validate="$(cd "${project}" && bash bin/agent skills validate)"
jq -e '.ok == true and .skills == []' <<<"${zero_validate}" >/dev/null
zero_doctor="$(cd "${project}" && bash bin/agent doctor)"
jq -e '.ok == true and .skills_ok == true' <<<"${zero_doctor}" >/dev/null
zero_work="$(cd "${project}" && bash bin/agent api work run '{"input":"zero skill ordinary answer"}')"
jq -e '.ok == true and .status == "answered"' <<<"${zero_work}" >/dev/null
zero_terminal="$(cd "${project}" && bash bin/agent api terminal run \
    '{"command":"printf matrix-terminal","approve":true}')"
jq -e '.ok == true and .status == "executed"
    and ([.output_blocks[]? | select(.kind == "stdout" and .text == "matrix-terminal")] | length) == 1' \
    <<<"${zero_terminal}" >/dev/null
audit_log="$(find "${project}/logs" -maxdepth 1 -type f -name 'session_*.jsonl' | sort | tail -n 1)"
[[ -n "${audit_log}" ]]
(cd "${project}" && bash bin/agent audit verify "$(basename "${audit_log}" .jsonl)") >/dev/null

# A missing project INDEX disables only Skill discovery. Core CLI and Web stay healthy.
rm -f -- "${project}/skills/INDEX.md"
missing_validate="$(cd "${project}" && bash bin/agent skills validate)"
jq -e '.ok == true and .status == "unavailable"
    and ([.findings[] | select(.code == "SKILL_INDEX_INVALID")] | length) == 1' \
    <<<"${missing_validate}" >/dev/null
missing_doctor="$(cd "${project}" && bash bin/agent doctor)"
jq -e '.ok == true and .skills_ok == true' <<<"${missing_doctor}" >/dev/null
(cd "${project}" && bash bin/agent-web) \
    >"${tmp_root}/web.stdout" 2>"${tmp_root}/web.stderr" &
web_pid="$!"
for _ in $(seq 1 100); do
    curl --noproxy '*' -fsS -H 'Authorization: Bearer skill-matrix-token' \
        "http://127.0.0.1:${web_port}/api/health" >/dev/null 2>&1 && break
    sleep 0.02
done
web_health="$(curl --noproxy '*' -fsS -H 'Authorization: Bearer skill-matrix-token' \
    "http://127.0.0.1:${web_port}/api/health")"
jq -e '.ok == true' <<<"${web_health}" >/dev/null
web_skills="$(curl --noproxy '*' -fsS -H 'Authorization: Bearer skill-matrix-token' \
    "http://127.0.0.1:${web_port}/api/skills/validate")"
jq -e '.ok == true' <<<"${web_skills}" >/dev/null
kill "${web_pid}"
wait "${web_pid}" 2>/dev/null || true
web_pid=""

# Use a stable hash selection to exercise a non-empty, non-complete package subset.
cp "${ROOT_DIR}/skills/INDEX.md" "${project}/skills/INDEX.md"
installed_count=0
total_count=0
while IFS= read -r package; do
    total_count=$((total_count + 1))
    selector="$(printf '%s' "${package}" | sha256sum | cut -c1)"
    if ((16#${selector} % 2 == 0)); then
        cp -a "${ROOT_DIR}/skills/${package}" "${project}/skills/${package}"
        installed_count=$((installed_count + 1))
    fi
done < <(find "${ROOT_DIR}/skills" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
((installed_count > 0 && installed_count < total_count))
subset_list="$(cd "${project}" && bash bin/agent skills list)"
jq -e --argjson installed "${installed_count}" --argjson total "${total_count}" '
    .ok == true
    and ([.skills[] | select(.state == "installed")] | length) == $installed
    and ([.skills[] | select(.state == "unavailable")] | length) == ($total - $installed)
' <<<"${subset_list}" >/dev/null
subset_doctor="$(cd "${project}" && bash bin/agent doctor)"
jq -e '.ok == true and .skills_ok == true' <<<"${subset_doctor}" >/dev/null

# One malformed installed package is isolated while the remaining subset stays listed.
broken_name="$(jq -r --argjson installed "$(jq -c '[.skills[] | select(.state == "installed") | .name]' <<<"${subset_list}")" '
    [.skills[] | select(.state == "unavailable") | .name] - $installed | first
' <<<"${subset_list}")"
mkdir -p "${project}/skills/${broken_name}"
printf '%s\n' '---' 'name: wrong-directory-name' 'description: broken fixture' '---' \
    >"${project}/skills/${broken_name}/SKILL.md"
broken_list="$(cd "${project}" && bash bin/agent skills list)"
jq -e --arg skill "${broken_name}" '
    .ok == true
    and ([.skills[] | select(.name == $skill and .state == "invalid")] | length) == 1
    and ([.skills[] | select(.state == "installed")] | length) > 0
' <<<"${broken_list}" >/dev/null
broken_doctor="$(cd "${project}" && bash bin/agent doctor)"
jq -e '.ok == true and .skills_ok == true' <<<"${broken_doctor}" >/dev/null

# Core runtime must not know any concrete builtin package name.
builtin_pattern="$(find "${ROOT_DIR}/skills" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' |
    sort | paste -sd '|' -)"
if core_hits="$(rg -n "${builtin_pattern}" \
    "${ROOT_DIR}/bin" "${ROOT_DIR}/lib" "${ROOT_DIR}/web" \
    "${ROOT_DIR}/schema" "${ROOT_DIR}/prompts" "${ROOT_DIR}/remote" \
    "${ROOT_DIR}/scripts/install.sh")"; then
    printf 'core runtime contains concrete builtin names:\n%s\n' "${core_hits}" >&2
    exit 1
fi

printf 'skill_stability: ok\n'
