#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=helpers.sh
source "${ROOT_DIR}/tests/helpers.sh"
linux_agent_test_install_failure_trap skill_lifecycle

tmp_root="$(mktemp -d)"
cleanup() {
    rm -rf -- "${tmp_root}"
}
trap cleanup EXIT

project="${tmp_root}/project"
mkdir -p "${project}/skills"
cp -a \
    "${ROOT_DIR}/bin" \
    "${ROOT_DIR}/config" \
    "${ROOT_DIR}/lib" \
    "${ROOT_DIR}/mcp" \
    "${ROOT_DIR}/policies" \
    "${ROOT_DIR}/prompts" \
    "${ROOT_DIR}/schema" \
    "${project}/"
cp "${ROOT_DIR}/skills/INDEX.md" "${project}/skills/INDEX.md"
cp "${project}/config/config.example.json" "${project}/config/config.json"

source_root="${tmp_root}/sources"
mkdir -p "${source_root}"
cp -a "${ROOT_DIR}/tests/fixtures/agent-skills-spec/with-resources" \
    "${source_root}/with-resources"

installed="$(cd "${project}" && bash bin/agent skills install \
    --scope user "${source_root}/with-resources")"
jq -e '.ok == true and .status == "installed" and .scope == "user"
    and .skill == "with-resources"' <<<"${installed}" >/dev/null
[[ -f "${project}/data/skills/with-resources/SKILL.md" ]]
[[ -f "${project}/data/skills/with-resources/references/guide.md" ]]
[[ -f "${project}/data/skills/with-resources/assets/template.txt" ]]
[[ ! -e "${project}/data/skills/INDEX.md" ]]

listed="$(cd "${project}" && bash bin/agent skills list)"
jq -e 'any(.skills[]; .name == "with-resources" and .origin == "user"
    and .state == "installed")' <<<"${listed}" >/dev/null
jq -e 'all(.skills[]; .name != ".locks")
    and all(.findings[]; .skill != ".locks")' <<<"${listed}" >/dev/null
read_result="$(cd "${project}" && bash bin/agent skills read \
    with-resources references/guide.md)"
jq -e '.ok == true and .status == "read" and .skill == "with-resources"
    and .path == "references/guide.md"
    and (.content | contains("reference"))' <<<"${read_result}" >/dev/null

removed="$(cd "${project}" && bash bin/agent skills uninstall \
    --scope user with-resources)"
jq -e '.ok == true and .status == "uninstalled" and .scope == "user"
    and .skill == "with-resources" and .purged == false
    and .cleanup_pending == []' \
    <<<"${removed}" >/dev/null
[[ ! -e "${project}/data/skills/with-resources" ]]

archive="${tmp_root}/with-resources.tar.gz"
tar -czf "${archive}" -C "${source_root}" with-resources
archive_installed="$(cd "${project}" && bash bin/agent skills install \
    --scope user "${archive}")"
jq -e '.ok == true and .status == "installed" and .skill == "with-resources"' \
    <<<"${archive_installed}" >/dev/null
archive_removed="$(cd "${project}" && bash bin/agent skills uninstall \
    --scope user with-resources --purge --confirm PURGE_SKILL_DATA)"
jq -e '.ok == true and .status == "uninstalled" and .purged == true' \
    <<<"${archive_removed}" >/dev/null

reserved="${source_root}/ops-basic"
mkdir -p "${reserved}"
printf '%s\n' \
    '---' \
    'name: ops-basic' \
    'description: user package attempting to claim a reserved builtin name' \
    '---' \
    '# Instructions' >"${reserved}/SKILL.md"
reserved_result="$(cd "${project}" && bash bin/agent skills install \
    --scope user "${reserved}")"
jq -e '.ok == false and .status == "skill_operation_failed"
    and (.error | contains("reserved by the builtin catalog"))' \
    <<<"${reserved_result}" >/dev/null
[[ ! -e "${project}/data/skills/ops-basic" ]]

legacy="${source_root}/legacy-package"
mkdir -p "${legacy}"
printf '%s\n' \
    '---' \
    'name: legacy-package' \
    'description: legacy package rejection fixture' \
    '---' >"${legacy}/SKILL.md"
printf '{}\n' >"${legacy}/manifest.json"
legacy_result="$(cd "${project}" && bash bin/agent skills install \
    --scope user "${legacy}")"
jq -e '.ok == false and .status == "legacy_format_unsupported"
    and .code == "legacy_format_unsupported"' <<<"${legacy_result}" >/dev/null
[[ ! -e "${project}/data/skills/legacy-package" ]]
[[ ! -e "${project}/data/skills/INDEX.md" ]]

printf 'skill_lifecycle: ok\n'
