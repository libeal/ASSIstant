#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/cosign_compat.sh
source "${ROOT_DIR}/tests/cosign_compat.sh"
tmp_root="$(mktemp -d)"
web_pid=""
release_http_pid=""

cleanup() {
    local status=$?
    if [[ "${status}" -ne 0 ]]; then
        printf 'remote_runtime: exiting with status %s\n' "${status}" >&2
        if [[ -f "${web_stderr:-}" ]]; then
            printf '%s\n' 'remote_runtime: remote Web stderr tail:' >&2
            tail -n 80 "${web_stderr}" >&2 || true
        fi
    fi
    if [[ -n "${web_pid}" ]] && kill -0 "${web_pid}" >/dev/null 2>&1; then
        kill -TERM "${web_pid}" >/dev/null 2>&1 || true
        wait "${web_pid}" 2>/dev/null || true
    fi
    if [[ -n "${release_http_pid}" ]] && kill -0 "${release_http_pid}" >/dev/null 2>&1; then
        kill "${release_http_pid}" >/dev/null 2>&1 || true
        wait "${release_http_pid}" 2>/dev/null || true
    fi
    rm -rf "${tmp_root}"
    return "${status}"
}
trap cleanup EXIT
report_failure() {
    local status=$?
    local line="${1:-unknown}"
    if [[ "$-" != *e* ]]; then
        return "${status}"
    fi
    trap - ERR
    printf 'remote_runtime: failed at line %s (exit=%s)\n' "${line}" "${status}" >&2
    return "${status}"
}
trap 'report_failure "${LINENO}"' ERR

release_dir="${tmp_root}/release"
runtime_base="${tmp_root}/runtime"
web_port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
mkdir -p "${runtime_base}"
SOURCE_DATE_EPOCH=0 bash "${ROOT_DIR}/scripts/build-remote-release.sh" v0.0.0-test "${release_dir}" >/dev/null

# flock is a hard dependency and must fail before the bootstrap downloads even
# the release manifest. Keep every other bootstrap dependency visible.
no_flock_bin="${tmp_root}/no-flock-bin"
no_flock_curl_marker="${tmp_root}/no-flock-curl-invoked"
mkdir -p "${no_flock_bin}"
for command_name in bash python3 jq tar sha256sum stat mktemp; do
    ln -s "$(command -v "${command_name}")" "${no_flock_bin}/${command_name}"
done
printf '%s\n' \
    '#!/usr/bin/env bash' \
    ': >"${NO_FLOCK_CURL_MARKER:?}"' \
    'exit 99' >"${no_flock_bin}/curl"
chmod 0755 "${no_flock_bin}/curl"
if PATH="${no_flock_bin}" NO_FLOCK_CURL_MARKER="${no_flock_curl_marker}" \
    XDG_RUNTIME_DIR="${runtime_base}" \
    LINUX_AGENT_ALLOW_INSECURE_TEST_URL=1 \
    LINUX_AGENT_RELEASE_BASE_URL="file://${release_dir}" \
    "${no_flock_bin}/bash" "${release_dir}/linux-agent-cli.sh" doctor \
    >"${tmp_root}/no-flock.stdout" 2>"${tmp_root}/no-flock.stderr"; then
    printf 'Remote bootstrap unexpectedly ran without flock\n' >&2
    exit 1
fi
grep -q 'flock.*util-linux' "${tmp_root}/no-flock.stderr"
[[ ! -e "${no_flock_curl_marker}" ]]
[[ -z "$(find "${runtime_base}" -mindepth 1 -maxdepth 1 -print -quit)" ]]

run_remote_cli() {
    XDG_RUNTIME_DIR="${runtime_base}" \
        LINUX_AGENT_ALLOW_INSECURE_TEST_URL=1 \
        LINUX_AGENT_RELEASE_BASE_URL="file://${release_dir}" \
        bash "${release_dir}/linux-agent-cli.sh" "$@"
}

latest_stderr="${tmp_root}/latest.stderr"
doctor_json="$(run_remote_cli doctor 2>"${latest_stderr}")"
jq -e '
    .ok == true
    and .skills_ok == true
    and .remote.enabled == true
    and .remote.release_version == "v0.0.0-test"
    and ([.required_commands[] | select(.name == "flock" and .ok == true)] | length == 1)
' <<<"${doctor_json}" >/dev/null
grep -q '浮动 latest' "${latest_stderr}"
[[ -z "$(find "${runtime_base}" -mindepth 1 -maxdepth 1 -print -quit)" ]]

fixed_stderr="${tmp_root}/fixed.stderr"
fixed_doctor_json="$(LINUX_AGENT_VERSION=v0.0.0-test run_remote_cli doctor 2>"${fixed_stderr}")"
jq -e '.ok == true and .remote.release_version == "v0.0.0-test"' <<<"${fixed_doctor_json}" >/dev/null
! grep -q '浮动 latest' "${fixed_stderr}"

# A real HTTP 404 must take the documented old-release SHA256 fallback path.
# A fake cosign proves the verifier is not invoked when no bundle exists.
fake_bin="${tmp_root}/fake-bin"
mkdir -p "${fake_bin}"
apply_marker="${tmp_root}/fake-cosign-invoked"
printf '%s\n' '#!/usr/bin/env bash' ': >"${FAKE_COSIGN_MARKER:?}"' 'exit 1' >"${fake_bin}/cosign"
chmod 0755 "${fake_bin}/cosign"
release_http_port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
python3 -m http.server "${release_http_port}" --bind 127.0.0.1 --directory "${release_dir}" \
    >"${tmp_root}/release-http.stdout" 2>"${tmp_root}/release-http.stderr" &
release_http_pid="$!"
for _ in $(seq 1 80); do
    if curl --noproxy '*' -fsS "http://127.0.0.1:${release_http_port}/release-manifest.json" >/dev/null 2>&1; then
        break
    fi
    sleep 0.1
done
http_fallback_stderr="${tmp_root}/http-fallback.stderr"
http_fallback_json="$(
    PATH="${fake_bin}:${PATH}" \
        FAKE_COSIGN_MARKER="${apply_marker}" \
        XDG_RUNTIME_DIR="${runtime_base}" \
        LINUX_AGENT_ALLOW_INSECURE_TEST_URL=1 \
        LINUX_AGENT_RELEASE_BASE_URL="http://127.0.0.1:${release_http_port}" \
        LINUX_AGENT_VERSION=v0.0.0-test \
        bash "${release_dir}/linux-agent-cli.sh" doctor 2>"${http_fallback_stderr}"
)"
jq -e '.ok == true and .remote.release_version == "v0.0.0-test"' <<<"${http_fallback_json}" >/dev/null
grep -q '未提供签名 bundle' "${http_fallback_stderr}"
[[ ! -e "${apply_marker}" ]]
kill "${release_http_pid}"
wait "${release_http_pid}" 2>/dev/null || true
release_http_pid=""

set +e
LINUX_AGENT_REQUIRE_SIGNATURE=1 run_remote_cli doctor >"${tmp_root}/required-signature.stdout" 2>"${tmp_root}/required-signature.stderr"
required_signature_status="$?"
set -e
[[ "${required_signature_status}" -ne 0 ]]
grep -Eq '签名 bundle 下载失败|未安装 cosign' "${tmp_root}/required-signature.stderr"

set +e
piped_doctor_json="$(curl -fsSL "file://${release_dir}/linux-agent-cli.sh" |
    XDG_RUNTIME_DIR="${runtime_base}" \
        LINUX_AGENT_ALLOW_INSECURE_TEST_URL=1 \
        LINUX_AGENT_RELEASE_BASE_URL="file://${release_dir}" \
        bash -s -- doctor)"
piped_doctor_status="$?"
set -e
if [[ "${piped_doctor_status}" -ne 0 ]]; then
    printf 'piped Remote doctor failed with status %s; stdout: %s\n' \
        "${piped_doctor_status}" "${piped_doctor_json}" >&2
    exit 1
fi
if ! jq -e '.ok == true and .remote.enabled == true' <<<"${piped_doctor_json}" >/dev/null; then
    printf 'piped Remote doctor returned an invalid response: %s\n' "${piped_doctor_json}" >&2
    exit 1
fi
if [[ -n "$(find "${runtime_base}" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    printf 'piped Remote doctor left runtime artifacts:\n' >&2
    find "${runtime_base}" -mindepth 1 -maxdepth 3 -print >&2
    exit 1
fi

web_stdout="${tmp_root}/remote-web.stdout"
web_stderr="${tmp_root}/remote-web.stderr"
observer_fake_bin="${tmp_root}/observer-fake-bin"
mkdir -p "${observer_fake_bin}"
cat >"${observer_fake_bin}/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state="$(dirname "$0")/sudo.state"
if [[ "${1:-}" == "-n" && "${2:-}" == "true" ]]; then
    [[ -f "${state}" ]]
    exit
fi
if [[ "${1:-}" == "-S" && "${2:-}" == "-p" && "${4:-}" == "-v" ]]; then
    IFS= read -r password
    [[ "${password}" == "remote-observer-password" ]]
    : >"${state}"
    exit
fi
if [[ "${1:-}" == "-n" ]]; then
    shift
    [[ -f "${state}" ]]
    exec "$@"
fi
exit 1
EOF
cat >"${observer_fake_bin}/auditctl" <<'EOF'
#!/usr/bin/env bash
printf 'enabled 1\n'
EOF
cat >"${observer_fake_bin}/ausearch" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 0755 "${observer_fake_bin}/sudo" "${observer_fake_bin}/auditctl" \
    "${observer_fake_bin}/ausearch"

remote_web_token() {
    local config_file="" token="" token_file=""
    config_file="$(find "${runtime_base}" -maxdepth 5 -type f \
        -path '*/linux-agent-remote.*/agent/config/config.json' -print -quit 2>/dev/null || true)"
    if [[ -n "${config_file}" ]]; then
        token="$(jq -r '.web.token // empty' "${config_file}" 2>/dev/null || true)"
        if [[ -n "${token}" ]]; then
            printf '%s\n' "${token}"
            return 0
        fi
    fi
    token_file="$(find "${runtime_base}" -maxdepth 5 -type f \
        -path '*/linux-agent-remote.*/agent/tmp/web/auth-token' -print -quit 2>/dev/null || true)"
    if [[ -n "${token_file}" ]]; then
        printf '%s\n' "$(<"${token_file}")"
    fi
}

wait_remote_job() {
    local job_id="$1" result status
    for _ in $(seq 1 100); do
        result="$(curl -fsS -H "Authorization: Bearer ${web_token}" \
            "http://127.0.0.1:${web_port}/api/jobs/${job_id}")"
        status="$(jq -r '.status // empty' <<<"${result}")"
        if [[ "${status}" != "queued" && "${status}" != "running" ]]; then
            printf '%s\n' "${result}"
            return 0
        fi
        sleep 0.1
    done
    printf 'Remote Web job did not finish: %s\n' "${job_id}" >&2
    return 1
}

curl -fsSL "file://${release_dir}/linux-agent-web.sh" |
    PATH="${observer_fake_bin}:${PATH}" \
        XDG_RUNTIME_DIR="${runtime_base}" \
        LINUX_AGENT_REMOTE_WEB_PORT="${web_port}" \
        LINUX_AGENT_ALLOW_INSECURE_TEST_URL=1 \
        LINUX_AGENT_RELEASE_BASE_URL="file://${release_dir}" \
        bash >"${web_stdout}" 2>"${web_stderr}" &
web_pid="$!"
web_token=""
for _ in $(seq 1 100); do
    web_token="$(remote_web_token)"
    if [[ -n "${web_token}" ]] && curl -fsS -H "Authorization: Bearer ${web_token}" \
        "http://127.0.0.1:${web_port}/api/health" |
        jq -e '.ok == true and .remote.enabled == true and .remote.release_version == "v0.0.0-test"' >/dev/null; then
        break
    fi
    sleep 0.1
done
if [[ -z "${web_token}" ]]; then
    printf 'remote Web did not become healthy; stderr:\n' >&2
    sed -n '1,200p' "${web_stderr}" >&2
    exit 1
fi
if grep -Fq -- "${web_token}" "${web_stdout}" "${web_stderr}"; then
    printf 'remote Web token was echoed to stdout/stderr\n' >&2
    exit 1
fi
remote_observer_state="$(curl -fsS -H "Authorization: Bearer ${web_token}" \
    "http://127.0.0.1:${web_port}/api/observer/bootstrap")"
jq -e '.managed_execution == false
    and .requires_permission == true
    and (.authorization_mode == "root" or .authorization_mode == "sudo_interactive")' \
    <<<"${remote_observer_state}" >/dev/null
remote_observer_enabled="$(curl -fsS -X POST \
    -H "Authorization: Bearer ${web_token}" \
    -H 'Content-Type: application/json' \
    -d '{"action":"enable","password":"remote-observer-password"}' \
    "http://127.0.0.1:${web_port}/api/observer/bootstrap")"
jq -e '.ok == true and .status == "enabled" and (.method == "root" or .method == "sudo")' \
    <<<"${remote_observer_enabled}" >/dev/null
if grep -Fq -- 'remote-observer-password' "${web_stdout}" "${web_stderr}"; then
    printf 'remote observer password was echoed to stdout/stderr\n' >&2
    exit 1
fi
tools_json="$(curl -fsS -H "Authorization: Bearer ${web_token}" "http://127.0.0.1:${web_port}/api/tools")"
jq -e '
    ([.scripts[].materialization] | all(. == "available"))
    and ([.scripts[].origin] | all(. == "builtin"))
' <<<"${tools_json}" >/dev/null

database_username="database_owner_for_remote_http_test"
database_password="DATABASE_PASSWORD_MUST_NOT_PERSIST_41c9"
database_credential="$(
    printf '%s' '{"engine":"postgresql","endpoint":"127.0.0.1","port":9,"database":"app","tls":"disable","username":"database_owner_for_remote_http_test","password":"DATABASE_PASSWORD_MUST_NOT_PERSIST_41c9","acknowledge_authorized_scope":true}' |
        curl -sS -X POST \
            -H "Authorization: Bearer ${web_token}" \
            -H 'Content-Type: application/json' \
            --data-binary @- \
            "http://127.0.0.1:${web_port}/api/database/credentials"
)"
if ! jq -e '.ok == true and .status == "saved"
    and (.credential_ref | test("^[0-9a-f]{32}$"))
    and .metadata.mode == "remote"' <<<"${database_credential}" >/dev/null; then
    printf 'Remote database credential returned an unexpected result: %s\n' \
        "${database_credential}" >&2
    exit 1
fi
if grep -Fq -- "${database_password}" <<<"${database_credential}" ||
    grep -Fq -- "${database_username}" <<<"${database_credential}"; then
    printf 'Remote database credential response exposed credential material\n' >&2
    exit 1
fi
database_credential_ref="$(jq -r '.credential_ref' <<<"${database_credential}")"
database_job="$(curl -fsS -X POST \
    -H "Authorization: Bearer ${web_token}" \
    -H 'Content-Type: application/json' \
    -d "$(jq -cn --arg ref "${database_credential_ref}" \
        '{resource:"database",action:"health",payload:{credential_ref:$ref}}')" \
    "http://127.0.0.1:${web_port}/api/jobs")"
database_result="$(wait_remote_job "$(jq -r '.job_id' <<<"${database_job}")")"
if ! jq -e '.result.code as $code
    | .status == "failed"
    and .result.ok == false
    and (["credential_unavailable", "database_unreachable", "database_query_failed"]
        | index($code) != null)' <<<"${database_result}" >/dev/null; then
    printf 'Remote database health Job returned an unexpected result: %s\n' \
        "${database_result}" >&2
    exit 1
fi
database_retry="$(curl -fsS -X POST \
    -H "Authorization: Bearer ${web_token}" \
    -H 'Content-Type: application/json' \
    -d "$(jq -cn --argjson version "$(jq -r '.version' <<<"${database_result}")" \
        '{expected_version:$version}')" \
    "http://127.0.0.1:${web_port}/api/jobs/$(jq -r '.job_id' <<<"${database_result}")/retry")"
database_retry_result="$(wait_remote_job "$(jq -r '.job_id' <<<"${database_retry}")")"
jq -e '.status == "failed" and .result.ok == false
    and .result.code == "credential_unavailable"' <<<"${database_retry_result}" >/dev/null
jq -e '.credentials == []' < <(curl -fsS \
    -H "Authorization: Bearer ${web_token}" \
    "http://127.0.0.1:${web_port}/api/database/credentials") >/dev/null
remote_agent_root="$(find "${runtime_base}" -maxdepth 4 -type d \
    -path '*/linux-agent-remote.*/agent' -print -quit)"
if grep -R -Fq -- "${database_password}" "${remote_agent_root}/data" \
    "${web_stdout}" "${web_stderr}"; then
    printf 'Remote database password was persisted or logged\n' >&2
    exit 1
fi
if grep -R -Fq -- "${database_username}" "${remote_agent_root}/data" \
    "${web_stdout}" "${web_stderr}"; then
    printf 'Remote database username was persisted or logged without redaction\n' >&2
    exit 1
fi

remote_user_script_v1=$'#!/usr/bin/env bash\nset -euo pipefail\nargs="${1:-}"\n[[ -n "${args}" ]] || args="{}"\npython3 - "${args}" <<PY\nimport json\nimport sys\nprint(json.dumps({"ok": True, "status": "executed", "tool": "remote-user/run", "version": "v1", "args": json.loads(sys.argv[1])}))\nPY'
remote_user_edit="$(jq -cn --arg content "${remote_user_script_v1}" '{
    response_type:"skill_edit",
    edit_schema_version:1,
    skill:{name:"remote-user",description:"Remote user overlay fixture"},
    scripts:[{name:"run.sh",description:"Accepts an optional JSON object and reports it.",content:$content}],
    references:[],
    assets:[],
    notes:"remote user create"
}')"
remote_user_review="$(curl -fsS -X POST \
    -H "Authorization: Bearer ${web_token}" \
    -H 'Content-Type: application/json' \
    -d "$(jq -cn --argjson edit "${remote_user_edit}" '{edit:$edit}')" \
    "http://127.0.0.1:${web_port}/api/edit/review")"
if ! jq -e '.ok == true and .status == "approved"
    and ([.reviews[].review.findings[]? | select(.code == "AST_HEREDOC")] | length) == 1' \
    <<<"${remote_user_review}" >/dev/null; then
    printf 'Remote user Skill review returned an unexpected result: %s\n' \
        "${remote_user_review}" >&2
    exit 1
fi
remote_user_create_job="$(curl -fsS -X POST \
    -H "Authorization: Bearer ${web_token}" \
    -H 'Content-Type: application/json' \
    -d "$(jq -cn --argjson edit "${remote_user_edit}" \
        '{resource:"edit",action:"apply",payload:{edit:$edit,approve:true}}')" \
    "http://127.0.0.1:${web_port}/api/jobs")"
remote_user_create_result="$(wait_remote_job "$(jq -r '.job_id' <<<"${remote_user_create_job}")")"
jq -e '.status == "succeeded" and .result_status == "edited" and .result.ok == true
    and (.result.result.skill_dir | endswith("/data/skills/remote-user"))' \
    <<<"${remote_user_create_result}" >/dev/null
remote_agent_root="$(find "${runtime_base}" -maxdepth 4 -type d \
    -path '*/linux-agent-remote.*/agent' -print -quit)"
[[ -f "${remote_agent_root}/data/skills/remote-user/scripts/run.sh" ]]
[[ ! -e "${remote_agent_root}/skills/remote-user" && ! -L "${remote_agent_root}/skills/remote-user" ]]

remote_user_script_v2="${remote_user_script_v1/v1/v2}"
remote_user_edit_v2="$(jq -c --arg content "${remote_user_script_v2}" \
    '.skill.description = "Remote user overlay fixture updated"
    | .scripts[0].content = $content
    | .notes = "remote user update"' <<<"${remote_user_edit}")"
remote_user_update_job="$(curl -fsS -X POST \
    -H "Authorization: Bearer ${web_token}" \
    -H 'Content-Type: application/json' \
    -d "$(jq -cn --argjson edit "${remote_user_edit_v2}" \
        '{resource:"edit",action:"apply",payload:{edit:$edit,approve:true}}')" \
    "http://127.0.0.1:${web_port}/api/jobs")"
remote_user_update_result="$(wait_remote_job "$(jq -r '.job_id' <<<"${remote_user_update_job}")")"
jq -e '.status == "succeeded" and .result_status == "edited" and .result.ok == true' \
    <<<"${remote_user_update_result}" >/dev/null
grep -q '"version": "v2"' "${remote_agent_root}/data/skills/remote-user/scripts/run.sh"

remote_conflict_script=$'#!/usr/bin/env bash\nset -euo pipefail\nprintf '\''{"ok":true}\\n'\'''
remote_conflict_edit="$(jq -cn --arg content "${remote_conflict_script}" '{
    response_type:"skill_edit",
    edit_schema_version:1,
    skill:{name:"ops-basic",description:"Must conflict with lazy built-in"},
    scripts:[{name:"run.sh",description:"Accepts a JSON object.",content:$content}],
    references:[],
    assets:[]
}')"
remote_conflict_job="$(curl -fsS -X POST \
    -H "Authorization: Bearer ${web_token}" \
    -H 'Content-Type: application/json' \
    -d "$(jq -cn --argjson edit "${remote_conflict_edit}" \
        '{resource:"edit",action:"apply",payload:{edit:$edit,approve:true}}')" \
    "http://127.0.0.1:${web_port}/api/jobs")"
remote_conflict_result="$(wait_remote_job "$(jq -r '.job_id' <<<"${remote_conflict_job}")")"
if ! jq -e '.status == "failed" and .result_status == "failed"
    and .result.code == "skill_conflict" and .result.result.code == "skill_conflict"' \
    <<<"${remote_conflict_result}" >/dev/null; then
    printf 'Remote reserved-name conflict returned an unexpected result: %s\n' \
        "${remote_conflict_result}" >&2
    exit 1
fi
[[ ! -e "${remote_agent_root}/data/skills/ops-basic" && ! -L "${remote_agent_root}/data/skills/ops-basic" ]]

remote_user_run_job="$(curl -fsS -X POST \
    -H "Authorization: Bearer ${web_token}" \
    -H 'Content-Type: application/json' \
    -d '{"resource":"script","action":"run","payload":{"ref":"remote-user/run","arguments":{"message":"ok"},"approve":true}}' \
    "http://127.0.0.1:${web_port}/api/jobs")"
remote_user_run_result="$(wait_remote_job "$(jq -r '.job_id' <<<"${remote_user_run_job}")")"
if ! jq -e '.status == "succeeded" and .result_status == "executed" and .result.ok == true
    and ([.result.output_blocks[]? | select(.kind == "json") | .json
        | select(.tool == "remote-user/run" and .version == "v2")] | length) == 1' \
    <<<"${remote_user_run_result}" >/dev/null; then
    printf 'Remote user Skill execution returned an unexpected result: %s\n' \
        "${remote_user_run_result}" >&2
    exit 1
fi
tools_with_user="$(curl -fsS -H "Authorization: Bearer ${web_token}" \
    "http://127.0.0.1:${web_port}/api/tools")"
jq -e '
    ([.scripts[] | select(.skill == "remote-user") | select(.origin == "user" and .materialization == "ready")] | length) == 1
    and ([.scripts[] | select(.skill == "ops-basic") | select(.origin == "builtin" and .materialization == "available")] | length > 0)
' <<<"${tools_with_user}" >/dev/null
materialize_one="${tmp_root}/materialize-one.json"
materialize_two="${tmp_root}/materialize-two.json"
curl -fsS -X POST -H "Authorization: Bearer ${web_token}" -H 'Content-Type: application/json' \
    -d '{"skill":"os-deep-inspect"}' "http://127.0.0.1:${web_port}/api/skills/materialize" >"${materialize_one}" &
materialize_pid_one="$!"
curl -fsS -X POST -H "Authorization: Bearer ${web_token}" -H 'Content-Type: application/json' \
    -d '{"skill":"os-deep-inspect"}' "http://127.0.0.1:${web_port}/api/skills/materialize" >"${materialize_two}" &
materialize_pid_two="$!"
wait "${materialize_pid_one}"
wait "${materialize_pid_two}"
jq -e '.ok == true and .status == "skill_materialized"' "${materialize_one}" >/dev/null
jq -e '.ok == true and .status == "skill_materialized"' "${materialize_two}" >/dev/null
tools_after_materialize="$(curl -fsS -H "Authorization: Bearer ${web_token}" "http://127.0.0.1:${web_port}/api/tools")"
jq -e '
    ([.scripts[] | select(.skill == "os-deep-inspect") | .materialization] | all(. == "ready"))
    and ([.scripts[] | select(.skill == "remote-user") | .materialization] | all(. == "ready"))
    and ([.scripts[] | select(.skill == "database-inspect") | .materialization] | all(. == "ready"))
    and ([.scripts[] | select(.skill != "os-deep-inspect" and .skill != "remote-user" and .skill != "database-inspect") | .materialization] | all(. == "available"))
' <<<"${tools_after_materialize}" >/dev/null
remote_skill_review="$(curl -fsS -X POST \
    -H "Authorization: Bearer ${web_token}" \
    -H 'Content-Type: application/json' \
    -d '{"ref":"network-ops-tools/firewall","arguments":{"action":"status"}}' \
    "http://127.0.0.1:${web_port}/api/script/review")"
jq -e '
    .ref == "network-ops-tools/firewall"
    and (.review | type == "object")
    and .review.approval_required == true
' <<<"${remote_skill_review}" >/dev/null
web_backup="${tmp_root}/remote-web-backup.tar.gz"
web_backup_code="$(curl -sS -w '%{http_code}' \
    -H "Authorization: Bearer ${web_token}" -o "${web_backup}" \
    "http://127.0.0.1:${web_port}/api/runtime/backup")"
if [[ "${web_backup_code}" != "200" ]]; then
    printf 'Remote Web backup failed with HTTP %s: %s\n' \
        "${web_backup_code}" "$(<"${web_backup}")" >&2
    exit 1
fi
web_backup_listing="$(tar -tzf "${web_backup}")"
web_backup_extract="${tmp_root}/remote-web-backup"
mkdir -p "${web_backup_extract}"
tar -xzf "${web_backup}" -C "${web_backup_extract}"
grep -q '^skills/remote-user/scripts/run.sh$' <<<"${web_backup_listing}"
if grep -q '^skills/os-deep-inspect/' <<<"${web_backup_listing}"; then
    printf 'remote Web backup contains materialized built-in Skill files\n' >&2
    exit 1
fi
jq -e '.builtin[] | select(.name == "os-deep-inspect" and .installed == true and .source == "remote")' \
    "${web_backup_extract}/skills/installation-state.json" >/dev/null
if grep -R -Fq -- "${web_token}" "${web_backup_extract}"; then
    printf 'remote Web backup contains the Web token\n' >&2
    exit 1
fi
if grep -R -Fq -- 'remote-observer-password' "${web_backup_extract}"; then
    printf 'remote Web backup contains the observer password\n' >&2
    exit 1
fi
grep -R -Eq -- '"stage":"remote_bootstrap_verified"' "${web_backup_extract}/logs"
grep -R -Eq -- '"stage":"skill_materialized"' "${web_backup_extract}/logs"
curl -fsS -X POST -H "Authorization: Bearer ${web_token}" -H 'Content-Type: application/json' \
    -d '{}' "http://127.0.0.1:${web_port}/api/server/shutdown" >/dev/null
wait "${web_pid}"
web_pid=""
[[ -z "$(find "${runtime_base}" -mindepth 1 -maxdepth 1 -print -quit)" ]]

sleep 0.2
signal_stdout="${tmp_root}/remote-web-signal.stdout"
signal_stderr="${tmp_root}/remote-web-signal.stderr"
curl -fsSL "file://${release_dir}/linux-agent-web.sh" |
    XDG_RUNTIME_DIR="${runtime_base}" \
        LINUX_AGENT_REMOTE_WEB_PORT="${web_port}" \
        LINUX_AGENT_ALLOW_INSECURE_TEST_URL=1 \
        LINUX_AGENT_RELEASE_BASE_URL="file://${release_dir}" \
        bash >"${signal_stdout}" 2>"${signal_stderr}" &
web_pid="$!"
signal_token=""
for _ in $(seq 1 100); do
    signal_token="$(remote_web_token)"
    if [[ -n "${signal_token}" ]] && curl -fsS -H "Authorization: Bearer ${signal_token}" \
        "http://127.0.0.1:${web_port}/api/health" >/dev/null; then
        break
    fi
    sleep 0.1
done
if [[ -z "${signal_token}" ]]; then
    printf 'remote Web signal test did not become healthy; stderr:\n' >&2
    sed -n '1,200p' "${signal_stderr}" >&2
    exit 1
fi
kill -TERM "${web_pid}"
set +e
wait "${web_pid}"
signal_status="$?"
set -e
web_pid=""
[[ "${signal_status}" -eq 143 ]]
[[ -z "$(find "${runtime_base}" -mindepth 1 -maxdepth 1 -print -quit)" ]]

secret_blocked="$(LINUX_AGENT_API_KEY='remote-test-secret-value' run_remote_cli api work run '{"input":"remote secret gate"}')"
jq -e '.ok == false and .status == "blocked" and .code == "secret_transmission_disabled"' <<<"${secret_blocked}" >/dev/null
preplanned_blocked="$(run_remote_cli api work run '{"input":"preplanned bypass","response":{"response_type":"work_plan","summary":"bypass","steps":[],"continue_decision":{"should_continue":false,"reason":"done"}}}')"
jq -e '.ok == false and .status == "blocked" and .code == "secret_transmission_disabled"' <<<"${preplanned_blocked}" >/dev/null
edit_blocked="$(run_remote_cli api edit plan '{"input":"edit bypass"}')"
jq -e '.ok == false and .status == "secret_transmission_disabled"' <<<"${edit_blocked}" >/dev/null

materialized="$(run_remote_cli api skills materialize '{"skill":"os-deep-inspect"}')"
jq -e '
    .ok == true
    and .status == "skill_materialized"
    and .skill == "os-deep-inspect"
    and (.files | index("skills/os-deep-inspect/agents/openai.yaml")) != null
' <<<"${materialized}" >/dev/null

cp "${release_dir}/linux-agent-skill-os-deep-inspect.tar.gz" "${tmp_root}/valid-skill.tar.gz"
printf 'corrupt' >>"${release_dir}/linux-agent-skill-os-deep-inspect.tar.gz"
digest_failure="$(run_remote_cli api skills materialize '{"skill":"os-deep-inspect"}')"
jq -e '.ok == false and .status == "skill_digest_mismatch"' <<<"${digest_failure}" >/dev/null
[[ -z "$(find "${runtime_base}" -mindepth 1 -maxdepth 1 -print -quit)" ]]
mv "${tmp_root}/valid-skill.tar.gz" "${release_dir}/linux-agent-skill-os-deep-inspect.tar.gz"

cp "${release_dir}/release-manifest.json" "${tmp_root}/valid-manifest.json"
jq '.skills["os-deep-inspect"].refs[0].ref = "os-deep-inspect/not-registered"' \
    "${release_dir}/release-manifest.json" >"${tmp_root}/mismatched-manifest.json"
mv "${tmp_root}/mismatched-manifest.json" "${release_dir}/release-manifest.json"
registry_failure="$(run_remote_cli api skills materialize '{"skill":"os-deep-inspect"}')"
jq -e '.ok == false and .status == "skill_package_invalid"' <<<"${registry_failure}" >/dev/null
[[ -z "$(find "${runtime_base}" -mindepth 1 -maxdepth 1 -print -quit)" ]]
mv "${tmp_root}/valid-manifest.json" "${release_dir}/release-manifest.json"

python3 - "${release_dir}/linux-agent-skill-os-deep-inspect.tar.gz" <<'PY'
import io
import sys
import tarfile

with tarfile.open(sys.argv[1], "w:gz") as archive:
    payload = b"escape"
    member = tarfile.TarInfo("skills/os-deep-inspect/../../escaped")
    member.size = len(payload)
    archive.addfile(member, io.BytesIO(payload))
PY
unsafe_sha="$(sha256sum "${release_dir}/linux-agent-skill-os-deep-inspect.tar.gz" | awk '{print $1}')"
unsafe_size="$(stat -c '%s' "${release_dir}/linux-agent-skill-os-deep-inspect.tar.gz")"
manifest_tmp="${tmp_root}/unsafe-manifest.json"
jq --arg sha "${unsafe_sha}" --argjson size "${unsafe_size}" '
    .skills["os-deep-inspect"].asset.sha256 = $sha
    | .skills["os-deep-inspect"].asset.size_bytes = $size
' "${release_dir}/release-manifest.json" >"${manifest_tmp}"
mv "${manifest_tmp}" "${release_dir}/release-manifest.json"
unsafe_failure="$(run_remote_cli api skills materialize '{"skill":"os-deep-inspect"}')"
jq -e '.ok == false and .status == "skill_package_invalid"' <<<"${unsafe_failure}" >/dev/null
[[ ! -e "${tmp_root}/escaped" ]]
[[ -z "$(find "${runtime_base}" -mindepth 1 -maxdepth 1 -print -quit)" ]]

if command -v cosign >/dev/null 2>&1; then
    signed_release="${tmp_root}/signed-release"
    cp -a "${release_dir}" "${signed_release}"
    cosign_dir="${tmp_root}/cosign"
    mkdir -p "${cosign_dir}"
    (
        cd "${cosign_dir}"
        COSIGN_PASSWORD=remote-runtime-test cosign generate-key-pair >/dev/null
        COSIGN_PASSWORD=remote-runtime-test linux_agent_test_cosign_sign_blob \
            cosign.key "${signed_release}/release-manifest.json.sigstore.json" \
            "${signed_release}/release-manifest.json" >/dev/null
    )
    signed_doctor="$(XDG_RUNTIME_DIR="${runtime_base}" \
        LINUX_AGENT_ALLOW_INSECURE_TEST_URL=1 \
        LINUX_AGENT_RELEASE_BASE_URL="file://${signed_release}" \
        LINUX_AGENT_REQUIRE_SIGNATURE=1 \
        LINUX_AGENT_SIGNATURE_PUBKEY="${cosign_dir}/cosign.pub" \
        bash "${signed_release}/linux-agent-cli.sh" doctor)"
    jq -e '.ok == true and .remote.release_version == "v0.0.0-test"' <<<"${signed_doctor}" >/dev/null

    printf ' ' >>"${signed_release}/release-manifest.json"
    set +e
    XDG_RUNTIME_DIR="${runtime_base}" \
        LINUX_AGENT_ALLOW_INSECURE_TEST_URL=1 \
        LINUX_AGENT_RELEASE_BASE_URL="file://${signed_release}" \
        LINUX_AGENT_REQUIRE_SIGNATURE=1 \
        LINUX_AGENT_SIGNATURE_PUBKEY="${cosign_dir}/cosign.pub" \
        bash "${signed_release}/linux-agent-cli.sh" doctor \
        >"${tmp_root}/tampered-signature.stdout" 2>"${tmp_root}/tampered-signature.stderr"
    tampered_signature_status="$?"
    set -e
    [[ "${tampered_signature_status}" -ne 0 ]]
    grep -q '签名验证失败' "${tmp_root}/tampered-signature.stderr"
else
    printf 'remote_runtime: cosign not installed; signature verification scenarios skipped\n'
fi

printf 'remote_runtime: ok\n'
