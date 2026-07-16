#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="$(mktemp -d)"
web_pid=""

cleanup() {
    if [[ -n "${web_pid}" ]] && kill -0 "${web_pid}" >/dev/null 2>&1; then
        kill -TERM "${web_pid}" >/dev/null 2>&1 || true
        wait "${web_pid}" 2>/dev/null || true
    fi
    rm -rf "${tmp_root}"
}
trap cleanup EXIT

release_dir="${tmp_root}/release"
runtime_base="${tmp_root}/runtime"
mkdir -p "${runtime_base}"
SOURCE_DATE_EPOCH=0 bash "${ROOT_DIR}/scripts/build-remote-release.sh" v0.0.0-test "${release_dir}" >/dev/null

run_remote_cli() {
    XDG_RUNTIME_DIR="${runtime_base}" \
        LINUX_AGENT_ALLOW_INSECURE_TEST_URL=1 \
        LINUX_AGENT_RELEASE_BASE_URL="file://${release_dir}" \
        bash "${release_dir}/linux-agent-cli.sh" "$@"
}

doctor_json="$(run_remote_cli doctor)"
jq -e '
    .ok == true
    and .skills_ok == true
    and .remote.enabled == true
    and .remote.release_version == "v0.0.0-test"
' <<<"${doctor_json}" >/dev/null
[[ -z "$(find "${runtime_base}" -mindepth 1 -maxdepth 1 -print -quit)" ]]

piped_doctor_json="$(curl -fsSL "file://${release_dir}/linux-agent-cli.sh" |
    XDG_RUNTIME_DIR="${runtime_base}" \
        LINUX_AGENT_ALLOW_INSECURE_TEST_URL=1 \
        LINUX_AGENT_RELEASE_BASE_URL="file://${release_dir}" \
        bash -s -- doctor)"
jq -e '.ok == true and .remote.enabled == true' <<<"${piped_doctor_json}" >/dev/null
[[ -z "$(find "${runtime_base}" -mindepth 1 -maxdepth 1 -print -quit)" ]]

web_stdout="${tmp_root}/remote-web.stdout"
web_stderr="${tmp_root}/remote-web.stderr"
curl -fsSL "file://${release_dir}/linux-agent-web.sh" |
    XDG_RUNTIME_DIR="${runtime_base}" \
        LINUX_AGENT_ALLOW_INSECURE_TEST_URL=1 \
        LINUX_AGENT_RELEASE_BASE_URL="file://${release_dir}" \
        bash >"${web_stdout}" 2>"${web_stderr}" &
web_pid="$!"
web_token=""
for _ in $(seq 1 100); do
    token_file="$(find "${runtime_base}" -maxdepth 5 -type f \
        -path '*/linux-agent-remote.*/agent/tmp/web/auth-token' -print -quit 2>/dev/null || true)"
    web_token=""
    if [[ -n "${token_file}" ]]; then
        web_token="$(<"${token_file}")"
    fi
    if [[ -n "${web_token}" ]] && curl -fsS -H "Authorization: Bearer ${web_token}" \
        http://127.0.0.1:8765/api/health |
        jq -e '.ok == true and .remote.enabled == true and .remote.release_version == "v0.0.0-test"' >/dev/null; then
        break
    fi
    sleep 0.1
done
[[ -n "${web_token}" ]]
if grep -Fq -- "${web_token}" "${web_stdout}" "${web_stderr}"; then
    printf 'remote Web token was echoed to stdout/stderr\n' >&2
    exit 1
fi
tools_json="$(curl -fsS -H "Authorization: Bearer ${web_token}" http://127.0.0.1:8765/api/tools)"
jq -e '[.scripts[].materialization] | all(. == "available")' <<<"${tools_json}" >/dev/null
materialize_one="${tmp_root}/materialize-one.json"
materialize_two="${tmp_root}/materialize-two.json"
curl -fsS -X POST -H "Authorization: Bearer ${web_token}" -H 'Content-Type: application/json' \
    -d '{"skill":"os-deep-inspect"}' http://127.0.0.1:8765/api/skills/materialize >"${materialize_one}" &
materialize_pid_one="$!"
curl -fsS -X POST -H "Authorization: Bearer ${web_token}" -H 'Content-Type: application/json' \
    -d '{"skill":"os-deep-inspect"}' http://127.0.0.1:8765/api/skills/materialize >"${materialize_two}" &
materialize_pid_two="$!"
wait "${materialize_pid_one}"
wait "${materialize_pid_two}"
jq -e '.ok == true and .status == "skill_materialized"' "${materialize_one}" >/dev/null
jq -e '.ok == true and .status == "skill_materialized"' "${materialize_two}" >/dev/null
tools_after_materialize="$(curl -fsS -H "Authorization: Bearer ${web_token}" http://127.0.0.1:8765/api/tools)"
jq -e '
    ([.scripts[] | select(.skill == "os-deep-inspect") | .materialization] | all(. == "ready"))
    and ([.scripts[] | select(.skill != "os-deep-inspect") | .materialization] | all(. == "available"))
' <<<"${tools_after_materialize}" >/dev/null
web_backup="${tmp_root}/remote-web-backup.tar.gz"
curl -fsS -H "Authorization: Bearer ${web_token}" -o "${web_backup}" \
    http://127.0.0.1:8765/api/runtime/backup
tar -tzf "${web_backup}" >/dev/null
web_backup_extract="${tmp_root}/remote-web-backup"
mkdir -p "${web_backup_extract}"
tar -xzf "${web_backup}" -C "${web_backup_extract}"
if grep -R -Fq -- "${web_token}" "${web_backup_extract}"; then
    printf 'remote Web backup contains the Web token\n' >&2
    exit 1
fi
grep -R -Eq -- '"stage":"remote_bootstrap_verified"' "${web_backup_extract}/logs"
grep -R -Eq -- '"stage":"skill_materialized"' "${web_backup_extract}/logs"
curl -fsS -X POST -H "Authorization: Bearer ${web_token}" -H 'Content-Type: application/json' \
    -d '{}' http://127.0.0.1:8765/api/server/shutdown >/dev/null
wait "${web_pid}"
web_pid=""
[[ -z "$(find "${runtime_base}" -mindepth 1 -maxdepth 1 -print -quit)" ]]

sleep 0.2
signal_stdout="${tmp_root}/remote-web-signal.stdout"
signal_stderr="${tmp_root}/remote-web-signal.stderr"
curl -fsSL "file://${release_dir}/linux-agent-web.sh" |
    XDG_RUNTIME_DIR="${runtime_base}" \
        LINUX_AGENT_ALLOW_INSECURE_TEST_URL=1 \
        LINUX_AGENT_RELEASE_BASE_URL="file://${release_dir}" \
        bash >"${signal_stdout}" 2>"${signal_stderr}" &
web_pid="$!"
signal_token=""
for _ in $(seq 1 100); do
    token_file="$(find "${runtime_base}" -maxdepth 5 -type f \
        -path '*/linux-agent-remote.*/agent/tmp/web/auth-token' -print -quit 2>/dev/null || true)"
    signal_token=""
    if [[ -n "${token_file}" ]]; then
        signal_token="$(<"${token_file}")"
    fi
    if [[ -n "${signal_token}" ]] && curl -fsS -H "Authorization: Bearer ${signal_token}" \
        http://127.0.0.1:8765/api/health >/dev/null; then
        break
    fi
    sleep 0.1
done
[[ -n "${signal_token}" ]]
kill -TERM "${web_pid}"
set +e
wait "${web_pid}"
signal_status="$?"
set -e
web_pid=""
[[ "${signal_status}" -eq 143 ]]
[[ -z "$(find "${runtime_base}" -mindepth 1 -maxdepth 1 -print -quit)" ]]

secret_blocked="$(LINUX_AGENT_API_KEY='remote-test-secret-value' run_remote_cli api work run '{"input":"remote secret gate"}')"
jq -e '.ok == false and .status == "secret_transmission_disabled"' <<<"${secret_blocked}" >/dev/null
preplanned_blocked="$(run_remote_cli api work run '{"input":"preplanned bypass","response":{"response_type":"work_plan","summary":"bypass","steps":[],"continue_decision":{"should_continue":false,"reason":"done"}}}')"
jq -e '.ok == false and .status == "secret_transmission_disabled"' <<<"${preplanned_blocked}" >/dev/null
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

printf 'remote_runtime: ok\n'
