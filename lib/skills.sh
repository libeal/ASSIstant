#!/usr/bin/env bash

set -euo pipefail

# Skill registry boundary: callers should use this file instead of reaching into
# skills/ directly. A future manifest-backed resolver should preserve these
# registration, content and execution semantics.
linux_agent_skills_dir() {
    local configured
    configured="$(linux_agent_config_get '.skills_dir')"
    if [[ -n "${configured}" ]]; then
        printf '%s\n' "${configured}"
    else
        printf '%s\n' "${LINUX_AGENT_SKILLS_DIR}"
    fi
}

linux_agent_skill_index_path() {
    printf '%s/INDEX.md\n' "$(linux_agent_skills_dir)"
}

linux_agent_skill_index_text() {
    local index_path
    index_path="$(linux_agent_skill_index_path)"
    [[ -f "${index_path}" ]] && cat "${index_path}"
}

linux_agent_skill_ref_is_valid() {
    local ref="$1"
    [[ "${ref}" =~ ^[a-z0-9][a-z0-9-]*/[a-z0-9][a-z0-9-]*(\.sh)?$ ]]
}

linux_agent_skill_name_from_ref() {
    local ref="$1"
    printf '%s\n' "${ref%%/*}"
}

linux_agent_skill_script_name_from_ref() {
    local ref="$1"
    local script="${ref#*/}"
    script="${script%.sh}.sh"
    printf '%s\n' "${script}"
}

linux_agent_skill_script_path() {
    local ref="$1"
    local skill_name script_name
    skill_name="$(linux_agent_skill_name_from_ref "${ref}")"
    script_name="$(linux_agent_skill_script_name_from_ref "${ref}")"
    printf '%s/%s/scripts/%s\n' "$(linux_agent_skills_dir)" "${skill_name}" "${script_name}"
}

linux_agent_skill_manifest_path() {
    local skill_name="$1"
    printf '%s/%s/SKILL.md\n' "$(linux_agent_skills_dir)" "${skill_name}"
}

linux_agent_skill_is_registered() {
    local ref="$1"
    local skill_name script_name skill_md index_path script_path
    linux_agent_skill_ref_is_valid "${ref}" || return 1
    skill_name="$(linux_agent_skill_name_from_ref "${ref}")"
    script_name="$(linux_agent_skill_script_name_from_ref "${ref}")"
    skill_md="$(linux_agent_skill_manifest_path "${skill_name}")"
    index_path="$(linux_agent_skill_index_path)"
    script_path="$(linux_agent_skill_script_path "${ref}")"

    [[ -f "${skill_md}" && -f "${index_path}" && -f "${script_path}" ]] || return 1
    grep -Eq "(^|[^a-z0-9-])${skill_name}/${script_name%.sh}(\.sh)?([^a-z0-9-]|$)" "${index_path}" || return 1
    grep -Eq "(scripts/${script_name}|${script_name})" "${skill_md}" || return 1
}

linux_agent_skill_is_registered_at() {
    local ref="$1"
    local skill_md="$2"
    local index_path="$3"
    local skill_name script_name script_path
    linux_agent_skill_ref_is_valid "${ref}" || return 1
    skill_name="$(linux_agent_skill_name_from_ref "${ref}")"
    script_name="$(linux_agent_skill_script_name_from_ref "${ref}")"
    script_path="$(dirname "${skill_md}")/scripts/${script_name}"

    [[ -f "${skill_md}" && -f "${index_path}" && -f "${script_path}" ]] || return 1
    grep -Eq "(^|[^a-z0-9-])${skill_name}/${script_name%.sh}(\.sh)?([^a-z0-9-]|$)" "${index_path}" || return 1
    grep -Eq "(scripts/${script_name}|${script_name})" "${skill_md}" || return 1
}

linux_agent_skill_manifest_declared_script_names_at() {
    local skill_md="$1"
    [[ -f "${skill_md}" ]] || return 0

    grep -oE '`scripts/[a-z0-9][a-z0-9-]*\.sh`' "${skill_md}" 2>/dev/null \
        | tr -d '`' \
        | sed 's#^scripts/##' \
        | sort -u
}

linux_agent_index_declared_refs_at() {
    local index_path="$1"
    [[ -f "${index_path}" ]] || return 0

    grep -oE '`[a-z0-9][a-z0-9-]*/[a-z0-9][a-z0-9-]*(\.sh)?`' "${index_path}" 2>/dev/null \
        | tr -d '`' \
        | sort -u
}

linux_agent_skill_script_content() {
    local ref="$1"
    local script_path
    script_path="$(linux_agent_skill_script_path "${ref}")"
    [[ -f "${script_path}" ]] || return 1
    cat "${script_path}"
}

linux_agent_run_skill_script() {
    local ref="$1"
    local arguments_json="${2:-}"
    local script_path
    [[ -z "${arguments_json}" ]] && arguments_json='{}'

    if ! arguments_json="$(linux_agent_normalize_json_object_argument "${arguments_json}")"; then
        jq -cn --arg ref "${ref}" '{ok:false, error:"skill script arguments must be a JSON object", ref:$ref}'
        return 1
    fi

    if ! linux_agent_skill_is_registered "${ref}"; then
        jq -cn --arg ref "${ref}" '{ok:false, error:"skill script is not registered", ref:$ref}'
        return 1
    fi

    script_path="$(linux_agent_skill_script_path "${ref}")"
    if [[ ! -r "${script_path}" ]]; then
        jq -cn --arg ref "${ref}" '{ok:false, error:"skill script is not readable", ref:$ref}'
        return 1
    fi

    bash "${script_path}" "${arguments_json}"
}

linux_agent_validate_skill_at() {
    local skill_name="$1"
    local skill_dir="$2"
    local index_path="$3"
    local ok findings skill_md
    ok="true"
    findings='[]'
    skill_md="${skill_dir}/SKILL.md"

    if [[ ! "${skill_name}" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
        ok="false"
        findings="$(jq -cn --argjson prior "${findings}" --arg skill "${skill_name}" '$prior + [{severity:"critical", code:"SKILL_NAME_INVALID", skill:$skill, message:"skill 目录名非法。"}]')"
    fi
    if [[ ! -f "${skill_md}" ]] || ! sed -n '1,20p' "${skill_md}" | grep -Eq '^name:[[:space:]]*'; then
        ok="false"
        findings="$(jq -cn --argjson prior "${findings}" --arg skill "${skill_name}" '$prior + [{severity:"critical", code:"SKILL_MANIFEST_INVALID", skill:$skill, message:"SKILL.md 缺少 name frontmatter。"}]')"
    fi
    if [[ ! -f "${skill_md}" ]] || ! sed -n '1,30p' "${skill_md}" | grep -Eq '^description:[[:space:]]*'; then
        ok="false"
        findings="$(jq -cn --argjson prior "${findings}" --arg skill "${skill_name}" '$prior + [{severity:"critical", code:"SKILL_DESCRIPTION_MISSING", skill:$skill, message:"SKILL.md 缺少 description frontmatter。"}]')"
    fi

    while IFS= read -r script_path; do
        [[ -z "${script_path}" ]] && continue
        local script_name ref review
        script_name="$(basename "${script_path}")"
        ref="${skill_name}/${script_name%.sh}"
        if ! linux_agent_skill_is_registered_at "${ref}" "${skill_md}" "${index_path}"; then
            ok="false"
            findings="$(jq -cn --argjson prior "${findings}" --arg ref "${ref}" '$prior + [{severity:"critical", code:"SKILL_SCRIPT_UNREGISTERED", ref:$ref, message:"脚本未在 INDEX.md 和 SKILL.md 中登记。"}]')"
        fi
        review="$(linux_agent_policy_review_text "skill:${ref}" "$(cat "${script_path}")")"
        if [[ "$(jq -r '.approved' <<<"${review}")" != "true" ]]; then
            ok="false"
            findings="$(jq -cn --argjson prior "${findings}" --argjson review "${review}" '$prior + ($review.findings // [])')"
        fi
    done < <(find "${skill_dir}/scripts" -maxdepth 1 -type f -name '*.sh' 2>/dev/null | sort)

    while IFS= read -r declared_script; do
        [[ -n "${declared_script}" ]] || continue
        if [[ ! -f "${skill_dir}/scripts/${declared_script}" ]]; then
            ok="false"
            findings="$(jq -cn \
                --argjson prior "${findings}" \
                --arg ref "${skill_name}/${declared_script%.sh}" \
                '$prior + [{severity:"critical", code:"SKILL_SCRIPT_FILE_MISSING", ref:$ref, message:"脚本已在 SKILL.md 中声明，但 scripts/ 下不存在对应文件。"}]')"
        fi
    done < <(linux_agent_skill_manifest_declared_script_names_at "${skill_md}")

    jq -cn --argjson ok "${ok}" --arg skill "${skill_name}" --arg skill_dir "${skill_dir}" --arg index_path "${index_path}" --argjson findings "${findings}" \
        '{ok:$ok, skill:$skill, skill_dir:$skill_dir, index_path:$index_path, findings:$findings}'
}

linux_agent_validate_skills() {
    local skills_dir index_path ok findings
    skills_dir="$(linux_agent_skills_dir)"
    index_path="$(linux_agent_skill_index_path)"
    ok="true"
    findings='[]'

    if [[ ! -f "${index_path}" ]]; then
        ok="false"
        findings="$(jq -cn --argjson prior "${findings}" '$prior + [{severity:"critical", code:"SKILL_INDEX_MISSING", message:"skills/INDEX.md 不存在。"}]')"
    fi

    while IFS= read -r skill_dir; do
        [[ -z "${skill_dir}" ]] && continue
        local skill_name skill_result
        skill_name="$(basename "${skill_dir}")"
        skill_result="$(linux_agent_validate_skill_at "${skill_name}" "${skill_dir}" "${index_path}")"
        if [[ "$(jq -r '.ok // false' <<<"${skill_result}")" != "true" ]]; then
            ok="false"
            findings="$(jq -cn --argjson prior "${findings}" --argjson next "$(jq '.findings' <<<"${skill_result}")" '$prior + $next')"
        fi
    done < <(find "${skills_dir}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)

    while IFS= read -r ref; do
        [[ -n "${ref}" ]] || continue
        if ! linux_agent_skill_is_registered "${ref}"; then
            ok="false"
            findings="$(jq -cn \
                --argjson prior "${findings}" \
                --arg ref "${ref%.sh}" \
                '$prior + [{severity:"critical", code:"SKILL_INDEX_BROKEN_REF", ref:$ref, message:"INDEX.md 中声明的脚本缺少对应文件或 SKILL.md 登记。"}]')"
        fi
    done < <(linux_agent_index_declared_refs_at "${index_path}")

    jq -cn --argjson ok "${ok}" --arg skills_dir "${skills_dir}" --argjson findings "${findings}" \
        '{ok:$ok, skills_dir:$skills_dir, findings:$findings}'
}
