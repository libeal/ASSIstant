#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="$(mktemp -d)"
cleanup() {
    rm -rf "${tmp_root}"
}
trap cleanup EXIT

project="${tmp_root}/project"
mkdir -p "${project}"
cp -a \
    "${ROOT_DIR}/bin" \
    "${ROOT_DIR}/config" \
    "${ROOT_DIR}/lib" \
    "${ROOT_DIR}/mcp" \
    "${ROOT_DIR}/policies" \
    "${ROOT_DIR}/prompts" \
    "${ROOT_DIR}/skills" \
    "${project}/"
cp "${project}/config/config.example.json" "${project}/config/config.json"
config_tmp="${tmp_root}/config.json"
jq '
    .api_key = "backup-secret-api-key"
    | .web.token = "backup-secret-web-token"
    | .web.port = 8877
    | .remote.enabled = true
    | .remote.release_version = "v0.0.0-test"
' "${project}/config/config.json" >"${config_tmp}"
mv "${config_tmp}" "${project}/config/config.json"

mkdir -p "${project}/logs" "${project}/tmp/web/jobs" \
    "${project}/data/skills/custom-backup/scripts" "${project}/data/policies"
printf '%s\n' '{"timestamp":"2026-01-01T00:00:00Z","stage":"finished","payload":{"status":"executed","api_key":"audit-secret-should-redact"}}' >"${project}/logs/session_backup.jsonl"
printf '%s\n' '{"timestamp":"2025-12-31T23:59:58Z","stage":"received","payload":{"token":"rotated-one-secret"}}' >"${project}/logs/session_backup.jsonl.1"
printf '%s\n' '{"timestamp":"2025-12-31T23:59:59Z","stage":"received","payload":{"password":"rotated-two-secret"}}' >"${project}/logs/session_backup.jsonl.2"
printf '%s\n' '{"raw":"job-secret-should-not-export"}' >"${project}/tmp/web/jobs/job.json"
printf '%s\n' \
    '---' \
    'name: custom-backup' \
    'description: backup fixture' \
    '---' \
    '' \
    '## Arguments' \
    '' \
    '- `custom-backup/custom`: accepts one JSON object.' \
    >"${project}/data/skills/custom-backup/SKILL.md"
printf '%s\n' '#!/usr/bin/env bash' 'printf '\''{"ok":true}\\n'\''' >"${project}/data/skills/custom-backup/scripts/custom.sh"
jq -n '{
    schema_version:1,
    package_version:"1.0.0",
    core_api:1,
    category:"custom",
    tools:[{
        name:"custom",
        description:"accepts one JSON object.",
        entrypoint:"scripts/custom.sh",
        risk:"low",
        approval_scope:"skill_readonly",
        execution:{class:"runner",capability:"",dispatch:"always"},
        runtime_inputs:[],
        guards:[]
    }],
    components:{}
}' >"${project}/data/skills/custom-backup/linux-agent.json"
project_remote_skills='{}'
while IFS= read -r builtin_skill; do
    skill_name="$(basename "${builtin_skill}")"
    jq -cn --arg skill "${skill_name}" \
        '{skill:$skill,sha256:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",release_version:"v0.0.0-test"}' \
        >"${builtin_skill}/.remote-verified.json"
    project_remote_skills="$(jq -cn \
        --argjson prior "${project_remote_skills}" \
        --arg skill "${skill_name}" \
        '$prior + {($skill):{asset:{sha256:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},contract_digest:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}')"
done < <(find "${project}/skills" -mindepth 1 -maxdepth 1 -type d | sort)
mkdir -p "${project}/remote"
project_remote_manifest="${project}/remote/release-manifest.json"
jq -S -n --argjson skills "${project_remote_skills}" \
    '{schema_version:2,version:"v0.0.0-test",skills:$skills}' \
    >"${project_remote_manifest}"
jq '.warn_patterns += ["backup-restore-marker"]' \
    "${project}/policies/risk-rules.json" >"${project}/data/policies/risk-rules.json"

backup_path="${tmp_root}/runtime-backup.tar.gz"
backup_result="$(cd "${project}" && LINUX_AGENT_REMOTE_MODE=1 \
    LINUX_AGENT_REMOTE_MANIFEST="${project_remote_manifest}" \
    bash bin/agent backup "${backup_path}")"
jq -e '.ok == true and .status == "backup_created" and .size_bytes > 0' <<<"${backup_result}" >/dev/null
[[ -f "${backup_path}" ]]

listing="$(tar -tzf "${backup_path}")"
grep -qx 'manifest.json' <<<"${listing}"
grep -qx 'logs/session_backup.jsonl' <<<"${listing}"
grep -qx 'logs/session_backup.jsonl.1' <<<"${listing}"
grep -qx 'logs/session_backup.jsonl.2' <<<"${listing}"
grep -qx 'config/config.redacted.json' <<<"${listing}"
grep -qx 'skills/custom-backup/SKILL.md' <<<"${listing}"
grep -qx 'skills/custom-backup/linux-agent.json' <<<"${listing}"
grep -qx 'skills/installation-state.json' <<<"${listing}"
! grep -q '^skills/INDEX.md$' <<<"${listing}"
! grep -q '^skills/custom-backup/manifest.json$' <<<"${listing}"
grep -qx 'policies/risk-rules.json' <<<"${listing}"
if grep -q 'skills/ops-basic/' <<<"${listing}" || grep -q 'tmp/web/jobs' <<<"${listing}"; then
    printf 'backup contains excluded runtime assets\n' >&2
    exit 1
fi

extract_root="${tmp_root}/extract"
mkdir -p "${extract_root}"
tar -xzf "${backup_path}" -C "${extract_root}"
if grep -R -Eq -- 'backup-secret-api-key|backup-secret-web-token|job-secret-should-not-export|audit-secret-should-redact|rotated-one-secret|rotated-two-secret' "${extract_root}"; then
    printf 'backup leaked secret or raw job output\n' >&2
    exit 1
fi
jq -e '.builtin[] | select(.name == "ops-basic" and .installed == true and .source == "remote")' \
    "${extract_root}/skills/installation-state.json" >/dev/null
jq -e '
    .schema_version == 3
    and .redacted == true
    and .contents.user_skills == true
    and .contents.effective_policies == true
    and .contents.audit_chain_with_rotations == true
    and (.files | length > 0)
    and all(.files[];
        (.path | type == "string" and length > 0)
        and (.sha256 | test("^[0-9a-f]{64}$"))
        and (.size_bytes | type == "number" and . >= 0)
    )
' "${extract_root}/manifest.json" >/dev/null
jq -e '.warn_patterns | index("backup-restore-marker") != null' \
    "${extract_root}/policies/risk-rules.json" >/dev/null
python3 "${project}/lib/audit_chain.py" verify \
    "${extract_root}/logs/session_backup.jsonl" >/dev/null

restore_project="${tmp_root}/restore-project"
mkdir -p "${restore_project}"
cp -a \
    "${ROOT_DIR}/bin" \
    "${ROOT_DIR}/config" \
    "${ROOT_DIR}/lib" \
    "${ROOT_DIR}/mcp" \
    "${ROOT_DIR}/policies" \
    "${ROOT_DIR}/prompts" \
    "${ROOT_DIR}/skills" \
    "${restore_project}/"
cp "${restore_project}/config/config.example.json" "${restore_project}/config/config.json"
jq '
    .api_key = "restore-current-api-key"
    | .web.token = "restore-current-web-token"
    | .web.port = 8899
    | .remote.enabled = true
    | .remote.release_version = "v0.0.0-test"
' "${restore_project}/config/config.json" >"${config_tmp}"
mv "${config_tmp}" "${restore_project}/config/config.json"
mkdir -p "${restore_project}/remote"
restore_remote_manifest="${restore_project}/remote/release-manifest.json"
jq -S -n \
    '{schema_version:2,version:"v0.0.0-test",skills:{}}' \
    >"${restore_remote_manifest}"

mkdir -p "${restore_project}/data"
: >"${restore_project}/data/.runtime.lock"
chmod 0600 "${restore_project}/data/.runtime.lock"

for remote_restore_path in "${backup_path}" "${tmp_root}/does-not-exist.tar.gz"; do
    if remote_restore_result="$(cd "${restore_project}" && LINUX_AGENT_REMOTE_MODE=1 \
        LINUX_AGENT_REMOTE_MANIFEST="${restore_remote_manifest}" \
        bash bin/agent restore "${remote_restore_path}")"; then
        echo "Remote restore unexpectedly succeeded" >&2
        exit 1
    fi
    jq -e '.ok == false and .status == "restore_unavailable" and .code == "restore_unavailable"' \
        <<<"${remote_restore_result}" >/dev/null
    [[ -z "$(find "${restore_project}/tmp" -maxdepth 1 \
        \( -name 'runtime-restore.*' -o -name '.runtime-restore.lock' \) -print -quit)" ]]
done

exec {busy_lock_fd}<>"${restore_project}/data/.runtime.lock"
flock -s "${busy_lock_fd}"
if busy_restore_result="$(cd "${restore_project}" &&
    bash bin/agent restore "${backup_path}")"; then
    echo "restore unexpectedly replaced an active runtime" >&2
    exit 1
fi
jq -e '.ok == false and .status == "restore_busy" and .code == "restore_busy"' \
    <<<"${busy_restore_result}" >/dev/null
flock -u "${busy_lock_fd}"
exec {busy_lock_fd}>&-

restore_result="$(cd "${restore_project}" && bash bin/agent restore "${backup_path}")"
jq -e '.ok == true and .status == "restored"' <<<"${restore_result}" >/dev/null
[[ -f "${restore_project}/data/skills/custom-backup/linux-agent.json" ]]
[[ ! -e "${restore_project}/data/skills/INDEX.md" ]]
[[ ! -e "${restore_project}/data/skills/custom-backup/manifest.json" ]]
jq -e '.warn_patterns | index("backup-restore-marker") != null' \
    "${restore_project}/data/policies/risk-rules.json" >/dev/null
jq -e '
    .api_key == "restore-current-api-key"
    and .web.token == "restore-current-web-token"
    and .web.port == 8877
' "${restore_project}/config/config.json" >/dev/null
python3 "${restore_project}/lib/audit_chain.py" verify \
    "${restore_project}/logs/session_backup.jsonl" >/dev/null

if command -v unshare >/dev/null 2>&1 && unshare -Ur true >/dev/null 2>&1; then
    managed_prefix="${tmp_root}/managed-restore"
    managed_release="${managed_prefix}/releases/v0.0.0-test"
    mkdir -p "${managed_release}" "${managed_prefix}/data/config" \
        "${managed_prefix}/data/logs" "${managed_prefix}/data/tmp" \
        "${managed_prefix}/data/skills" "${managed_prefix}/data/policies" \
        "${managed_prefix}/data/runner-tmp"
    cp -a "${ROOT_DIR}/bin" "${ROOT_DIR}/lib" "${ROOT_DIR}/mcp" \
        "${ROOT_DIR}/policies" "${ROOT_DIR}/prompts" "${ROOT_DIR}/schema" \
        "${ROOT_DIR}/skills" "${managed_release}/"
    cp "${ROOT_DIR}/config/config.example.json" \
        "${managed_prefix}/data/config/config.json"
    ln -s ../../data/config "${managed_release}/config"
    ln -s ../../data/logs "${managed_release}/logs"
    ln -s ../../data/tmp "${managed_release}/tmp"
    ln -s releases/v0.0.0-test "${managed_prefix}/current"
    : >"${managed_prefix}/data/.runtime.lock"
    chmod 0640 "${managed_prefix}/data/.runtime.lock"
    jq -n --arg prefix "${managed_prefix}" \
        '{schema_version:1,prefix:$prefix,installed:true,no_systemd:false}' \
        >"${managed_prefix}/.install-state.json"

    managed_restore_result="$(unshare -Ur bash "${managed_prefix}/current/bin/agent" \
        restore "${backup_path}")"
    jq -e '.ok == true and .status == "restored"' \
        <<<"${managed_restore_result}" >/dev/null
    bash "${managed_prefix}/current/bin/agent" audit verify session_backup >/dev/null
    managed_backup="${tmp_root}/managed-after-restore.tar.gz"
    bash "${managed_prefix}/current/bin/agent" backup "${managed_backup}" >/dev/null
    [[ -s "${managed_backup}" ]]
    while IFS= read -r managed_audit_file; do
        [[ "$(stat -c '%u:%g' "${managed_audit_file}")" == "$(id -u):$(id -g)" ]]
        [[ "$(stat -c '%a' "${managed_audit_file}")" == "600" ]]
    done < <(find "${managed_prefix}/data/logs" -maxdepth 1 -type f \
        \( -name '*.jsonl' -o -name '*.lock' \) | sort)
fi

forged_marker_backup="${tmp_root}/forged-marker-backup.tar.gz"
jq -cn '{skill:"custom-backup",sha256:"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",release_version:"v0.0.0-test"}' \
    >"${project}/data/skills/custom-backup/.remote-verified.json"
if forged_result="$(cd "${project}" && LINUX_AGENT_REMOTE_MODE=1 \
    LINUX_AGENT_REMOTE_MANIFEST="${project_remote_manifest}" \
    bash bin/agent backup "${forged_marker_backup}" 2>/dev/null)"; then
    printf 'backup unexpectedly trusted a forged remote Skill marker\n' >&2
    exit 1
fi
jq -e '.status == "backup_unsafe_skill"' <<<"${forged_result}" >/dev/null
[[ ! -e "${forged_marker_backup}" ]]
rm -f "${project}/data/skills/custom-backup/.remote-verified.json"

ln -s /etc/passwd "${project}/data/skills/custom-backup/external-link"
unsafe_backup_path="${tmp_root}/unsafe-runtime-backup.tar.gz"
if (cd "${project}" && LINUX_AGENT_REMOTE_MODE=1 \
    LINUX_AGENT_REMOTE_MANIFEST="${project_remote_manifest}" \
    bash bin/agent backup "${unsafe_backup_path}") >/dev/null 2>&1; then
    printf 'backup unexpectedly accepted a symlink in a user skill\n' >&2
    exit 1
fi
[[ ! -e "${unsafe_backup_path}" ]]

if (cd "${project}" && LINUX_AGENT_REMOTE_MODE=1 \
    LINUX_AGENT_REMOTE_MANIFEST="${project_remote_manifest}" \
    bash bin/agent backup "${backup_path}") >/dev/null 2>&1; then
    printf 'backup unexpectedly overwrote an existing file\n' >&2
    exit 1
fi
grep -R -Eq -- '"stage":"runtime_backup_created"' "${project}/logs"

printf 'backup: ok\n'
