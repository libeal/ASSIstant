#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-}"
OUTPUT_DIR="${2:-${ROOT_DIR}/dist/remote}"
SOURCE_EPOCH="${SOURCE_DATE_EPOCH:-0}"

if [[ ! "${VERSION}" =~ ^v[0-9A-Za-z][0-9A-Za-z._-]*$ ]]; then
    printf 'usage: %s <v-version> [output-dir]\n' "$0" >&2
    exit 2
fi

for command_name in bash jq tar gzip sha256sum stat find sort cp mktemp readlink grep sed awk head basename chmod date; do
    command -v "${command_name}" >/dev/null 2>&1 || {
        printf 'missing build command: %s\n' "${command_name}" >&2
        exit 1
    }
done

tmp_root="$(mktemp -d)"
cleanup() {
    rm -rf "${tmp_root}"
}
trap cleanup EXIT

if [[ -L "${OUTPUT_DIR}" || (-e "${OUTPUT_DIR}" && (! -d "${OUTPUT_DIR}" || -n "$(find "${OUTPUT_DIR}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)")) ]]; then
    printf 'output directory must not exist or must be empty: %s\n' "${OUTPUT_DIR}" >&2
    exit 1
fi
mkdir -p "${OUTPUT_DIR}"
resolved_output="$(readlink -f "${OUTPUT_DIR}")"
resolved_root="$(readlink -f "${ROOT_DIR}")"
if [[ "${resolved_output}" == "${resolved_root}" || ("${resolved_output}" == "${resolved_root}/"* && "${resolved_output}" != "${resolved_root}/dist" && "${resolved_output}" != "${resolved_root}/dist/"*) ]]; then
    printf 'output inside the source tree is only allowed under dist/: %s\n' "${OUTPUT_DIR}" >&2
    exit 1
fi

copy_tree_without_cache() {
    local source_dir="$1"
    local target_dir="$2"
    mkdir -p "${target_dir}"
    cp -a "${source_dir}/." "${target_dir}/"
    find "${target_dir}" -type d -name __pycache__ -prune -exec rm -rf -- {} +
    find "${target_dir}" -type f -name '*.pyc' -delete
}

assert_archive_source_safe() {
    local root="$1"
    local unsafe_path
    unsafe_path="$(find "${root}" \( -type l -o -type b -o -type c -o -type p -o -type s \) -print -quit)"
    if [[ -n "${unsafe_path}" ]]; then
        printf 'release sources may only contain regular files and directories: %s\n' "${root}" >&2
        exit 1
    fi
}

create_archive() {
    local stage_root="$1"
    local output_path="$2"
    local -a entries=()
    assert_archive_source_safe "${stage_root}"
    mapfile -t entries < <(find "${stage_root}" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)
    [[ ${#entries[@]} -gt 0 ]] || {
        printf 'archive source is empty: %s\n' "${stage_root}" >&2
        exit 1
    }
    tar --sort=name \
        --mtime="@${SOURCE_EPOCH}" \
        --owner=0 --group=0 --numeric-owner \
        --format=gnu \
        -C "${stage_root}" -cf - "${entries[@]}" |
        gzip -n >"${output_path}"
}

asset_json() {
    local name="$1"
    local path="${OUTPUT_DIR}/${name}"
    local size_bytes
    size_bytes="$(stat -c '%s' "${path}")"
    if [[ "${size_bytes}" -gt 52428800 ]]; then
        printf 'release asset exceeds 50MiB: %s\n' "${name}" >&2
        exit 1
    fi
    jq -cn \
        --arg name "${name}" \
        --arg sha256 "$(sha256sum "${path}" | awk '{print $1}')" \
        --argjson size_bytes "${size_bytes}" \
        '{name:$name, sha256:$sha256, size_bytes:$size_bytes, max_size_bytes:52428800}'
}

core_stage="${tmp_root}/core"
mkdir -p "${core_stage}/bin" "${core_stage}/lib" "${core_stage}/config" "${core_stage}/skills" "${core_stage}/schema" "${core_stage}/packaging/dropins"
cp -a "${ROOT_DIR}/bin/agent" "${core_stage}/bin/agent"
cp -a "${ROOT_DIR}/lib/"*.sh "${ROOT_DIR}/lib/"*.py "${core_stage}/lib/"
cp -a "${ROOT_DIR}/config/config.example.json" "${ROOT_DIR}/config/ai-providers.json" "${core_stage}/config/"
cp -a "${ROOT_DIR}/schema/domain.json" "${core_stage}/schema/domain.json"
cp -a \
    "${ROOT_DIR}/packaging/linux-agent-web.service" \
    "${ROOT_DIR}/packaging/linux-agent-observer-helper.service" \
    "${ROOT_DIR}/packaging/linux-agent-observer-helper.socket" \
    "${ROOT_DIR}/packaging/权限边界.md" \
    "${core_stage}/packaging/"
cp -a "${ROOT_DIR}/packaging/dropins/10-provider-egress.conf.example" "${core_stage}/packaging/dropins/"
copy_tree_without_cache "${ROOT_DIR}/mcp" "${core_stage}/mcp"
copy_tree_without_cache "${ROOT_DIR}/policies" "${core_stage}/policies"
copy_tree_without_cache "${ROOT_DIR}/prompts" "${core_stage}/prompts"
cp -a "${ROOT_DIR}/skills/INDEX.md" "${core_stage}/skills/INDEX.md"
create_archive "${core_stage}" "${OUTPUT_DIR}/linux-agent-core.tar.gz"

web_stage="${tmp_root}/web"
mkdir -p "${web_stage}/bin"
cp -a "${ROOT_DIR}/bin/agent-web" "${web_stage}/bin/agent-web"
copy_tree_without_cache "${ROOT_DIR}/web" "${web_stage}/web"
create_archive "${web_stage}" "${OUTPUT_DIR}/linux-agent-web.tar.gz"

skills_json='{}'
while IFS= read -r skill_dir; do
    skill_name="$(basename "${skill_dir}")"
    [[ "${skill_name}" =~ ^[a-z0-9][a-z0-9-]*$ ]] || {
        printf 'invalid skill directory name: %s\n' "${skill_name}" >&2
        exit 1
    }
    skill_stage="${tmp_root}/skill-${skill_name}"
    mkdir -p "${skill_stage}/skills"
    copy_tree_without_cache "${skill_dir}" "${skill_stage}/skills/${skill_name}"
    asset_name="linux-agent-skill-${skill_name}.tar.gz"
    create_archive "${skill_stage}" "${OUTPUT_DIR}/${asset_name}"

    refs='[]'
    while IFS= read -r index_line; do
        ref="$(sed -n 's/^- `\([^`]*\)`: .*/\1/p' <<<"${index_line}")"
        [[ "${ref}" == "${skill_name}/"* ]] || continue
        ref="${ref%.sh}"
        description="$(sed -n 's/^- `[^`]*`: \(.*\)$/\1/p' <<<"${index_line}")"
        script_name="${ref#*/}.sh"
        manifest_line="$(grep -E "scripts/${script_name}(\`|[[:space:]):,-])" "${skill_dir}/SKILL.md" 2>/dev/null | head -n 1 || true)"
        risk="$(sed -nE 's/.*risk:[[:space:]]*`?(low|medium|high|critical)`?.*/\1/p' <<<"${manifest_line}" | head -n 1)"
        case "${risk}" in low | medium | high | critical) ;; *) risk=low ;; esac
        refs="$(jq -cn --argjson prior "${refs}" --arg ref "${ref}" --arg description "${description}" --arg risk "${risk}" '$prior + [{ref:$ref, description:$description, risk:$risk}]')"
    done <"${ROOT_DIR}/skills/INDEX.md"
    [[ "$(jq 'length' <<<"${refs}")" -gt 0 ]] || {
        printf 'skill has no INDEX.md references: %s\n' "${skill_name}" >&2
        exit 1
    }
    skill_description="$(sed -n 's/^description:[[:space:]]*//p' "${skill_dir}/SKILL.md" | head -n 1)"
    [[ -n "${skill_description}" ]] || {
        printf 'skill has no description frontmatter: %s\n' "${skill_name}" >&2
        exit 1
    }
    skill_risk="$(jq -r '
        map(.risk)
        | if index("critical") then "critical"
          elif index("high") then "high"
          elif index("medium") then "medium"
          else "low"
          end
    ' <<<"${refs}")"

    skills_json="$(jq -cn \
        --argjson prior "${skills_json}" \
        --arg skill "${skill_name}" \
        --arg description "${skill_description}" \
        --arg risk "${skill_risk}" \
        --argjson asset "$(asset_json "${asset_name}")" \
        --argjson refs "${refs}" \
        '$prior + {($skill): {description:$description, risk:$risk, asset:$asset, refs:$refs}}')"
done < <(find "${ROOT_DIR}/skills" -mindepth 1 -maxdepth 1 -type d | sort)

{
    printf '#!/usr/bin/env bash\nexport LINUX_AGENT_REMOTE_ENTRYPOINT=cli\n'
    sed '1d' "${ROOT_DIR}/remote/bootstrap.sh"
} >"${OUTPUT_DIR}/linux-agent-cli.sh"
{
    printf '#!/usr/bin/env bash\nexport LINUX_AGENT_REMOTE_ENTRYPOINT=web\n'
    sed '1d' "${ROOT_DIR}/remote/bootstrap.sh"
} >"${OUTPUT_DIR}/linux-agent-web.sh"
chmod 0755 "${OUTPUT_DIR}/linux-agent-cli.sh" "${OUTPUT_DIR}/linux-agent-web.sh"
cp -a "${ROOT_DIR}/scripts/install.sh" "${OUTPUT_DIR}/linux-agent-install.sh"
chmod 0755 "${OUTPUT_DIR}/linux-agent-install.sh"

created_at="$(date -u --date="@${SOURCE_EPOCH}" '+%Y-%m-%dT%H:%M:%SZ')" || {
    printf 'SOURCE_DATE_EPOCH must be a valid Unix timestamp: %s\n' "${SOURCE_EPOCH}" >&2
    exit 1
}
sbom_files='[]'
sbom_relationships='[
    {"spdxElementId":"SPDXRef-DOCUMENT","relationshipType":"DESCRIBES","relatedSpdxElement":"SPDXRef-Package-linux-agent"},
    {"spdxElementId":"SPDXRef-Package-linux-agent","relationshipType":"DEPENDS_ON","relatedSpdxElement":"SPDXRef-Package-bash"},
    {"spdxElementId":"SPDXRef-Package-linux-agent","relationshipType":"DEPENDS_ON","relatedSpdxElement":"SPDXRef-Package-curl"},
    {"spdxElementId":"SPDXRef-Package-linux-agent","relationshipType":"DEPENDS_ON","relatedSpdxElement":"SPDXRef-Package-jq"},
    {"spdxElementId":"SPDXRef-Package-linux-agent","relationshipType":"DEPENDS_ON","relatedSpdxElement":"SPDXRef-Package-python3"}
]'
while IFS= read -r name; do
    file_sha="$(sha256sum "${OUTPUT_DIR}/${name}" | awk '{print $1}')"
    file_id="SPDXRef-File-${file_sha}"
    sbom_files="$(jq -cn \
        --argjson prior "${sbom_files}" \
        --arg name "${name}" \
        --arg id "${file_id}" \
        --arg sha "${file_sha}" \
        '$prior + [{fileName:$name, SPDXID:$id, checksums:[{algorithm:"SHA256", checksumValue:$sha}], licenseConcluded:"NOASSERTION", copyrightText:"NOASSERTION"}]')"
    sbom_relationships="$(jq -cn \
        --argjson prior "${sbom_relationships}" \
        --arg id "${file_id}" \
        '$prior + [{spdxElementId:"SPDXRef-Package-linux-agent", relationshipType:"CONTAINS", relatedSpdxElement:$id}]')"
done < <(find "${OUTPUT_DIR}" -maxdepth 1 -type f -printf '%f\n' | sort)

jq -S -n \
    --arg version "${VERSION}" \
    --arg created "${created_at}" \
    --arg namespace "https://github.com/libeal/ASSIstant/releases/download/${VERSION}/sbom.spdx.json" \
    --argjson files "${sbom_files}" \
    --argjson relationships "${sbom_relationships}" \
    '{
        spdxVersion:"SPDX-2.3",
        dataLicense:"CC0-1.0",
        SPDXID:"SPDXRef-DOCUMENT",
        name:("linux-agent-" + $version),
        documentNamespace:$namespace,
        creationInfo:{created:$created, creators:["Tool: linux-agent-release-builder"]},
        packages:[
            {name:"linux-agent", SPDXID:"SPDXRef-Package-linux-agent", versionInfo:$version, downloadLocation:$namespace, filesAnalyzed:false, licenseConcluded:"NOASSERTION", licenseDeclared:"NOASSERTION", copyrightText:"NOASSERTION", comment:"Linux 运维 Agent 发布物；运行时零 npm/pip 依赖。"},
            {name:"bash", SPDXID:"SPDXRef-Package-bash", downloadLocation:"NOASSERTION", filesAnalyzed:false, licenseConcluded:"NOASSERTION", licenseDeclared:"NOASSERTION", copyrightText:"NOASSERTION", comment:"系统运行时依赖"},
            {name:"curl", SPDXID:"SPDXRef-Package-curl", downloadLocation:"NOASSERTION", filesAnalyzed:false, licenseConcluded:"NOASSERTION", licenseDeclared:"NOASSERTION", copyrightText:"NOASSERTION", comment:"系统运行时依赖"},
            {name:"jq", SPDXID:"SPDXRef-Package-jq", downloadLocation:"NOASSERTION", filesAnalyzed:false, licenseConcluded:"NOASSERTION", licenseDeclared:"NOASSERTION", copyrightText:"NOASSERTION", comment:"系统运行时依赖"},
            {name:"python3", SPDXID:"SPDXRef-Package-python3", downloadLocation:"NOASSERTION", filesAnalyzed:false, licenseConcluded:"NOASSERTION", licenseDeclared:"NOASSERTION", copyrightText:"NOASSERTION", comment:"系统运行时依赖"}
        ],
        files:$files,
        relationships:$relationships
    }' >"${OUTPUT_DIR}/sbom.spdx.json"

(
    cd "${OUTPUT_DIR}"
    find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%f\n' |
        sort |
        while IFS= read -r name; do sha256sum "${name}"; done \
            >SHA256SUMS
)

# The signed manifest is generated last so it can authenticate the SBOM and
# SHA256SUMS without introducing a self-reference. SHA256SUMS intentionally
# covers the release payload and SBOM; cosign authenticates the manifest itself.
jq -S -n \
    --arg version "${VERSION}" \
    --argjson bootstrap_cli "$(asset_json linux-agent-cli.sh)" \
    --argjson bootstrap_web "$(asset_json linux-agent-web.sh)" \
    --argjson core "$(asset_json linux-agent-core.tar.gz)" \
    --argjson web "$(asset_json linux-agent-web.tar.gz)" \
    --argjson installer "$(asset_json linux-agent-install.sh)" \
    --argjson sbom "$(asset_json sbom.spdx.json)" \
    --argjson checksums "$(asset_json SHA256SUMS)" \
    --argjson skills "${skills_json}" \
    '{
        schema_version:1,
        version:$version,
        repository:"libeal/ASSIstant",
        assets:{
            bootstrap_cli:$bootstrap_cli,
            bootstrap_web:$bootstrap_web,
            core:$core,
            web:$web,
            installer:$installer,
            sbom:$sbom,
            checksums:$checksums
        },
        skills:$skills
    }' >"${OUTPUT_DIR}/release-manifest.json"

printf 'remote release built: %s\n' "${OUTPUT_DIR}"
