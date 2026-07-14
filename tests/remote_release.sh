#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="$(mktemp -d)"

cleanup() {
    rm -rf "${tmp_root}"
}
trap cleanup EXIT

first="${tmp_root}/first"
second="${tmp_root}/second"

SOURCE_DATE_EPOCH=0 bash "${ROOT_DIR}/scripts/build-remote-release.sh" v0.0.0-test "${first}"
SOURCE_DATE_EPOCH=0 bash "${ROOT_DIR}/scripts/build-remote-release.sh" v0.0.0-test "${second}"

required_assets=(
    linux-agent-cli.sh
    linux-agent-web.sh
    linux-agent-core.tar.gz
    linux-agent-web.tar.gz
    release-manifest.json
    SHA256SUMS
)
for asset in "${required_assets[@]}"; do
    [[ -f "${first}/${asset}" ]]
    cmp "${first}/${asset}" "${second}/${asset}"
done

(cd "${first}" && sha256sum -c SHA256SUMS)

jq -e '
    .schema_version == 1
    and .version == "v0.0.0-test"
    and .repository == "libeal/ASSIstant"
    and (.assets.bootstrap_cli.name == "linux-agent-cli.sh")
    and (.assets.bootstrap_web.name == "linux-agent-web.sh")
    and (.assets.core.name == "linux-agent-core.tar.gz")
    and (.assets.web.name == "linux-agent-web.tar.gz")
    and ([.skills | keys[]] | length > 0)
    and ([.skills[] | select((.refs | length) == 0)] | length == 0)
    and ([.skills[] | select((.description | length) == 0 or (.risk | IN("low", "medium", "high", "critical") | not))] | length == 0)
' "${first}/release-manifest.json" >/dev/null

registered_assets="$(jq -r '[.assets[].name, .skills[].asset.name] | sort | .[]' "${first}/release-manifest.json")"
actual_assets="$(find "${first}" -maxdepth 1 -type f ! -name release-manifest.json ! -name SHA256SUMS -printf '%f\n' | sort)"
if [[ "${registered_assets}" != "${actual_assets}" ]]; then
    printf 'release contains unregistered or missing assets\n' >&2
    diff -u <(printf '%s\n' "${registered_assets}") <(printf '%s\n' "${actual_assets}") || true
    exit 1
fi

core_listing="$(tar -tzf "${first}/linux-agent-core.tar.gz")"
if grep -Eq '^skills/[^/]+/' <<<"${core_listing}"; then
    printf 'core archive unexpectedly contains materialized skill packages\n' >&2
    exit 1
fi
grep -qx 'skills/INDEX.md' <<<"${core_listing}"

while IFS= read -r skill_name; do
    asset="$(jq -r --arg skill "${skill_name}" '.skills[$skill].asset.name' "${first}/release-manifest.json")"
    [[ -f "${first}/${asset}" ]]
    skill_listing="$(tar -tzf "${first}/${asset}")"
    grep -qx "skills/${skill_name}/SKILL.md" <<<"${skill_listing}"
    grep -q "^skills/${skill_name}/scripts/" <<<"${skill_listing}"
    skill_extract="${tmp_root}/extract-${skill_name}"
    mkdir -p "${skill_extract}"
    tar -xzf "${first}/${asset}" -C "${skill_extract}"
    manifest_refs="$(jq -r --arg skill "${skill_name}" '.skills[$skill].refs[].ref' "${first}/release-manifest.json" | sort)"
    package_refs="$(find "${skill_extract}/skills/${skill_name}/scripts" -maxdepth 1 -type f -name '*.sh' -printf '%f\n' \
        | sed 's/\.sh$//' | awk -v prefix="${skill_name}/" '{print prefix $0}' | sort)"
    [[ "${manifest_refs}" == "${package_refs}" ]]
done < <(jq -r '.skills | keys[]' "${first}/release-manifest.json")

grep -q 'LINUX_AGENT_REMOTE_ENTRYPOINT=cli' "${first}/linux-agent-cli.sh"
grep -q 'LINUX_AGENT_REMOTE_ENTRYPOINT=web' "${first}/linux-agent-web.sh"

bash -n "${ROOT_DIR}/scripts/publish-remote-release.sh"
grep -q 'workflow_dispatch' "${ROOT_DIR}/.github/workflows/remote-release.yml"
grep -q 'publish-remote-release.sh' "${ROOT_DIR}/.github/workflows/remote-release.yml"
grep -q 'RUNNER_TEMP}/publish-remote-release.sh' "${ROOT_DIR}/.github/workflows/remote-release.yml"
! grep -q 'Authorization Bearer token:' "${ROOT_DIR}/.github/workflows/remote-release.yml"
grep -q 'agent/tmp/web/auth-token' "${ROOT_DIR}/.github/workflows/remote-release.yml"

printf 'remote_release: ok\n'
