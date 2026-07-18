#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/cosign_compat.sh
source "${ROOT_DIR}/tests/cosign_compat.sh"
tmp_root="$(mktemp -d)"
web_pid=""
release_http_pid=""

cleanup() {
    if [[ -n "${web_pid}" ]] && kill -0 "${web_pid}" >/dev/null 2>&1; then
        kill -TERM "${web_pid}" >/dev/null 2>&1 || true
        wait "${web_pid}" 2>/dev/null || true
    fi
    if [[ -n "${release_http_pid}" ]] && kill -0 "${release_http_pid}" >/dev/null 2>&1; then
        kill "${release_http_pid}" >/dev/null 2>&1 || true
        wait "${release_http_pid}" 2>/dev/null || true
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

latest_stderr="${tmp_root}/latest.stderr"
doctor_json="$(run_remote_cli doctor 2>"${latest_stderr}")"
jq -e '
    .ok == true
    and .skills_ok == true
    and .remote.enabled == true
    and .remote.release_version == "v0.0.0-test"
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
release_http_port="$((22000 + RANDOM % 1000))"
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
if [[ -z "${web_token}" ]]; then
    printf 'remote Web did not become healthy; stderr:\n' >&2
    sed -n '1,200p' "${web_stderr}" >&2
    exit 1
fi
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
