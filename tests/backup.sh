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
    | .remote.enabled = true
    | .remote.release_version = "v0.0.0-test"
' "${project}/config/config.json" > "${config_tmp}"
mv "${config_tmp}" "${project}/config/config.json"

mkdir -p "${project}/logs" "${project}/tmp/web/jobs" "${project}/skills/custom-backup/scripts"
printf '%s\n' '{"timestamp":"2026-01-01T00:00:00Z","stage":"finished","payload":{"status":"executed","api_key":"audit-secret-should-redact"}}' > "${project}/logs/session_backup.jsonl"
printf '%s\n' '{"raw":"job-secret-should-not-export"}' > "${project}/tmp/web/jobs/job.json"
printf '%s\n' '---' 'name: custom-backup' 'description: backup fixture' '---' > "${project}/skills/custom-backup/SKILL.md"
printf '%s\n' '#!/usr/bin/env bash' 'printf custom-backup' > "${project}/skills/custom-backup/scripts/custom.sh"
printf '%s\n' '{"skill":"ops-basic","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' > "${project}/skills/ops-basic/.remote-verified.json"

backup_path="${tmp_root}/runtime-backup.tar.gz"
backup_result="$(cd "${project}" && LINUX_AGENT_REMOTE_MODE=1 bash bin/agent backup "${backup_path}")"
jq -e '.ok == true and .status == "backup_created" and .size_bytes > 0' <<<"${backup_result}" >/dev/null
[[ -f "${backup_path}" ]]

listing="$(tar -tzf "${backup_path}")"
grep -qx 'manifest.json' <<<"${listing}"
grep -qx 'logs/session_backup.jsonl' <<<"${listing}"
grep -qx 'config/config.redacted.json' <<<"${listing}"
grep -qx 'skills/custom-backup/SKILL.md' <<<"${listing}"
grep -qx 'skills/materialized.json' <<<"${listing}"
if grep -q 'skills/ops-basic/' <<<"${listing}" || grep -q 'tmp/web/jobs' <<<"${listing}"; then
    printf 'backup contains excluded runtime assets\n' >&2
    exit 1
fi

extract_root="${tmp_root}/extract"
mkdir -p "${extract_root}"
tar -xzf "${backup_path}" -C "${extract_root}"
if rg -q 'backup-secret-api-key|backup-secret-web-token|job-secret-should-not-export|audit-secret-should-redact' "${extract_root}"; then
    printf 'backup leaked secret or raw job output\n' >&2
    exit 1
fi
jq -e '.materialized[] | select(.skill == "ops-basic")' "${extract_root}/skills/materialized.json" >/dev/null

ln -s /etc/passwd "${project}/skills/custom-backup/external-link"
unsafe_backup_path="${tmp_root}/unsafe-runtime-backup.tar.gz"
if (cd "${project}" && LINUX_AGENT_REMOTE_MODE=1 bash bin/agent backup "${unsafe_backup_path}") >/dev/null 2>&1; then
    printf 'backup unexpectedly accepted a symlink in a user skill\n' >&2
    exit 1
fi
[[ ! -e "${unsafe_backup_path}" ]]

if (cd "${project}" && LINUX_AGENT_REMOTE_MODE=1 bash bin/agent backup "${backup_path}") >/dev/null 2>&1; then
    printf 'backup unexpectedly overwrote an existing file\n' >&2
    exit 1
fi
rg -q '"stage":"runtime_backup_created"' "${project}/logs"

printf 'backup: ok\n'
