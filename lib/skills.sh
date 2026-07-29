#!/usr/bin/env bash

set -euo pipefail

# Skill registry boundary: callers use this file instead of reaching into
# package directories directly. Resolution is backed by SKILL.md,
# linux-agent.json, the builtin INDEX, and the signed Remote catalog.
linux_agent_skills_dir() {
    local configured
    if [[ "${LINUX_AGENT_REMOTE_MODE:-0}" == "1" ]]; then
        printf '%s\n' "${LINUX_AGENT_SKILLS_DIR}"
        return 0
    fi
    if linux_agent_managed_mode_enabled; then
        printf '%s\n' "${LINUX_AGENT_BUILTIN_SKILLS_DIR}"
        return 0
    fi
    configured="$(linux_agent_config_get '.skills_dir')"
    if [[ -n "${configured}" ]]; then
        printf '%s\n' "${configured}"
    else
        printf '%s\n' "${LINUX_AGENT_BUILTIN_SKILLS_DIR:-${LINUX_AGENT_SKILLS_DIR}}"
    fi
}

linux_agent_builtin_skills_dir() {
    if [[ "${LINUX_AGENT_REMOTE_MODE:-0}" == "1" ]]; then
        printf '%s\n' "${LINUX_AGENT_SKILLS_DIR}"
        return 0
    fi
    printf '%s\n' "${LINUX_AGENT_BUILTIN_SKILLS_DIR:-${LINUX_AGENT_ROOT}/skills}"
}

linux_agent_user_skills_dir() {
    local configured
    if [[ "${LINUX_AGENT_REMOTE_MODE:-0}" == "1" ]]; then
        printf '%s\n' "${LINUX_AGENT_USER_SKILLS_DIR:-${LINUX_AGENT_ROOT}/data/skills}"
        return 0
    fi
    if linux_agent_managed_mode_enabled; then
        printf '%s\n' "${LINUX_AGENT_USER_SKILLS_DIR}"
        return 0
    fi
    configured="$(linux_agent_config_get '.skills_dir' 2>/dev/null || true)"
    if [[ -n "${configured}" ]]; then
        printf '%s\n' "${configured}"
    else
        printf '%s\n' "${LINUX_AGENT_USER_SKILLS_DIR:-${LINUX_AGENT_ROOT}/data/skills}"
    fi
}

linux_agent_builtin_skill_name_reserved() {
    local skill_name="$1"
    [[ "${skill_name}" =~ ^[a-z0-9][a-z0-9-]*$ ]] || return 1
    if linux_agent_remote_mode_enabled &&
        [[ -f "${LINUX_AGENT_REMOTE_MANIFEST:-}" && ! -L "${LINUX_AGENT_REMOTE_MANIFEST}" ]] &&
        jq -e --arg skill "${skill_name}" \
            '.schema_version == 2 and (.skills[$skill] | type) == "object"' \
            "${LINUX_AGENT_REMOTE_MANIFEST}" >/dev/null 2>&1; then
        return 0
    fi
    linux_agent_skill_catalog_json |
        jq -e --arg skill "${skill_name}" 'any(.skills[]?; .name == $skill and .origin == "builtin")' >/dev/null
}

linux_agent_skill_package_dir() {
    local skill_name="$1"
    local user_dir builtin_dir
    [[ "${skill_name}" =~ ^[a-z0-9][a-z0-9-]*$ ]] || return 1
    user_dir="$(linux_agent_user_skills_dir)"
    builtin_dir="$(linux_agent_builtin_skills_dir)"
    if [[ "${user_dir}" == "${builtin_dir}" ]]; then
        [[ -d "${builtin_dir}/${skill_name}" && ! -L "${builtin_dir}/${skill_name}" ]] || return 1
        printf '%s\n' "${builtin_dir}/${skill_name}"
        return 0
    fi
    if [[ -e "${user_dir}/${skill_name}" || -L "${user_dir}/${skill_name}" ]]; then
        [[ -d "${user_dir}/${skill_name}" && ! -L "${user_dir}/${skill_name}" ]] || return 1
        if linux_agent_builtin_skill_name_reserved "${skill_name}"; then
            return 2
        fi
        printf '%s\n' "${user_dir}/${skill_name}"
        return 0
    fi
    [[ -d "${builtin_dir}/${skill_name}" && ! -L "${builtin_dir}/${skill_name}" ]] || return 1
    printf '%s\n' "${builtin_dir}/${skill_name}"
}

linux_agent_skill_package_origin() {
    local skill_name="$1" package user_dir builtin_dir
    package="$(linux_agent_skill_package_dir "${skill_name}")" || return $?
    user_dir="$(linux_agent_user_skills_dir)"
    builtin_dir="$(linux_agent_builtin_skills_dir)"
    if [[ "${user_dir}" != "${builtin_dir}" && "${package}" == "${user_dir}"/* ]]; then
        printf 'user\n'
    else
        printf 'builtin\n'
    fi
}

linux_agent_skill_package_names() {
    linux_agent_skill_catalog_json | jq -r '.skills[]?.name' | sort -u
}

linux_agent_skill_index_path() {
    printf '%s/INDEX.md\n' "$(linux_agent_builtin_skills_dir)"
}

linux_agent_skill_index_text() {
    local index_path
    index_path="$(linux_agent_skill_index_path)"
    [[ -f "${index_path}" ]] && cat "${index_path}"
}

linux_agent_skill_catalog_json() {
    local builtin_dir user_dir result
    builtin_dir="$(linux_agent_builtin_skills_dir)"
    user_dir="$(linux_agent_user_skills_dir)"
    result="$(python3 "${LINUX_AGENT_ROOT}/lib/skill_package.py" catalog "${builtin_dir}" --user-root "${user_dir}" 2>/dev/null || true)"
    if ! jq -e 'type == "object" and (.skills | type == "array") and (.tools | type == "array")' <<<"${result}" >/dev/null 2>&1; then
        jq -cn --arg root "${builtin_dir}" '{ok:true,status:"unavailable",skills:[],tools:[],findings:[{severity:"warning",code:"SKILL_RESOLVER_UNAVAILABLE",message:("Skill resolver could not read " + $root)}]}'
        return 0
    fi
    if linux_agent_remote_mode_enabled; then
        result="$(jq -c --slurpfile release "${LINUX_AGENT_REMOTE_MANIFEST}" '
            . as $catalog
            | ($release[0].skills // {}) as $remote
            | ([.skills[] | select(.origin == "builtin") | .name]) as $indexed
            | ([$remote | keys[] | select(($indexed | index(.)) == null)]) as $remote_only
            | ([.skills[] | select(
                .origin == "user" and (($remote[.name] | type) == "object")
              ) | .name]) as $reserved_conflicts
            | .findings += (
                [$reserved_conflicts[] | {
                    severity:"warning",
                    code:"SKILL_NAME_RESERVED",
                    skill:.,
                    message:"user Skill conflicts with a signed builtin name"
                }]
                + [$remote_only[] | {
                    severity:"warning",
                    code:"SKILL_INDEX_ENTRY_MISSING",
                    skill:.,
                    message:"signed builtin Skill is absent from the local INDEX"
                }]
              )
            | .skills = ([
                .skills[]
                | . as $skill
                | select(
                    ($skill.origin != "user")
                    or (($remote[$skill.name] | type) != "object")
                  )
                | if $skill.origin == "builtin"
                    and $skill.state == "unavailable"
                    and (($remote[$skill.name] | type) == "object")
                  then .state = "available"
                  else . end
              ] + [
                $remote_only[] as $name
                | {
                    name:$name,
                    description:($remote[$name].description // ""),
                    tools:[],
                    origin:"builtin",
                    state:"unavailable",
                    category:($remote[$name].category // "custom")
                  }
              ])
            | ([.skills[] | select(
                .origin == "builtin" and .state == "available"
              ) | .name]) as $available
            | .tools = (
                [.tools[] | select(
                    (.origin != "user")
                    or (($remote[.skill] | type) != "object")
                  )] as $installed
                | [
                    $remote | to_entries[] as $skill
                    | select(($available | index($skill.key)) != null)
                    | $skill.value.refs[]? as $ref
                    | select(([$installed[].ref] | index($ref.ref)) == null)
                    | {
                        ref:$ref.ref,
                        skill:$skill.key,
                        name:($ref.ref | split("/")[1]),
                        description:$ref.description,
                        risk:$ref.risk,
                        approval_scope:($ref.approval_scope // ""),
                        execution:{
                            class:$ref.execution_class,
                            capability:($ref.capability // ""),
                            dispatch:($ref.dispatch // "always")
                        },
                        runtime_inputs:($ref.runtime_inputs // []),
                        guards:($ref.guards // []),
                        origin:"builtin",
                        state:"available",
                        category:($skill.value.category // "custom")
                    }
                  ] as $pending
                | ($installed + $pending | sort_by(.ref))
              )
            | .status = "listed"
        ' <<<"${result}")"
    fi
    printf '%s\n' "${result}"
}

linux_agent_skill_disclosure_candidates() {
    local request="${1:-}"
    local mode="${2:-work}"
    local result

    case "${mode}" in
        work | work_revision | work_reflect | edit | edit_revision) ;;
        *) return 0 ;;
    esac

    result="$(linux_agent_skill_catalog_json |
        python3 "${LINUX_AGENT_ROOT}/lib/skill_package.py" discover-catalog - \
            --request "${request}" 2>/dev/null || true)"
    if jq -e 'type == "object" and (.candidates | type == "array")' <<<"${result}" >/dev/null 2>&1; then
        jq -c '[.candidates[]? | {
            name,
            state:(.state // "unavailable"),
            score:(.score // 0)
        }]' <<<"${result}"
    else
        printf '[]\n'
    fi
}

linux_agent_skill_context_json() {
    local request="${1:-}"
    local mode="${2:-work}"
    local candidates unavailable total_count

    case "${mode}" in
        work | work_revision | work_reflect | edit | edit_revision) ;;
        *)
            jq -cn '{enabled:false, disclosure:"not_available_in_mode", candidates:[], loaded:[], unavailable:[]}'
            return 0
            ;;
    esac

    candidates="$(linux_agent_skill_disclosure_candidates "${request}" "${mode}")"
    unavailable="$(jq -c '[.[] | select(
        .state == "unavailable" or .state == "invalid" or .state == "incompatible"
    ) | .name]' <<<"${candidates}")"

    total_count="$(linux_agent_skill_package_names | wc -l | tr -d ' ')"
    [[ "${total_count}" =~ ^[0-9]+$ ]] || total_count=0
    jq -cn \
        --argjson candidates "${candidates}" \
        --argjson unavailable "${unavailable}" \
        --argjson total_count "${total_count}" \
        '{
            enabled:true,
            disclosure:"index_metadata_then_controlled_read",
            discovery_source:"skills/INDEX.md",
            total_skill_count:$total_count,
            candidate_count:($candidates | length),
            candidates:$candidates,
            loaded_count:0,
            loaded:[],
            unavailable:$unavailable
        }'
}

linux_agent_skill_disclosures_from_results() {
    local results_json="${1:-[]}"
    jq -c '
        [
            .[]?
            | select(.result.ok == true)
            | select(.step.executor_type == "skill_load" or .step.executor_type == "skill_read")
            | .result.output
            | select(type == "object")
            | select((.skill | type) == "string" and (.path | type) == "string" and (.content | type) == "string")
            | {
                name:.skill,
                path:.path,
                kind:(if .path == "SKILL.md" then "instructions" else "reference" end),
                content:.content,
                relative_path:(.relative_path // null),
                source_path:(.source_path // null)
            }
        ]
        | group_by(.name + "\u0000" + .path)
        | map(last)
        | sort_by(.name, .path)
    ' <<<"${results_json}" 2>/dev/null || printf '[]\n'
}

linux_agent_add_loaded_skill_context() {
    local request_context="$1"
    local disclosures="${2:-[]}"
    if ! jq -e 'type == "array"' <<<"${disclosures}" >/dev/null 2>&1; then
        disclosures='[]'
    fi
    jq -c --argjson loaded "${disclosures}" '
        .skills = ((.skills // {}) + {
            loaded_count:($loaded | length),
            loaded:[
                $loaded[]
                | {
                    name,
                    path,
                    kind,
                    content,
                    relative_path
                }
            ]
        })
    ' <<<"${request_context}"
}

linux_agent_skill_is_loaded() {
    local skill_name="$1" disclosures="${2:-[]}"
    jq -e --arg skill "${skill_name}" '
        any(.[]?; .name == $skill and .path == "SKILL.md" and (.content | type) == "string")
    ' <<<"${disclosures}" >/dev/null 2>&1
}

linux_agent_add_skill_context() {
    local request_context="$1"
    local mode="${2:-work}"
    local current_request
    current_request="$(jq -r '.current_request // empty' <<<"${request_context}")"
    jq -c --argjson skills "$(linux_agent_skill_context_json "${current_request}" "${mode}")" \
        '. + {skills:$skills}' <<<"${request_context}"
}

linux_agent_remote_mode_enabled() {
    [[ "${LINUX_AGENT_REMOTE_MODE:-0}" == "1" &&
        -n "${LINUX_AGENT_REMOTE_MANIFEST:-}" &&
        -f "${LINUX_AGENT_REMOTE_MANIFEST}" ]]
}

linux_agent_remote_release_base() {
    printf '%s\n' "${LINUX_AGENT_REMOTE_RELEASE_BASE:-}"
}

linux_agent_remote_skill_is_known() {
    local skill_name="$1"
    linux_agent_remote_mode_enabled || return 1
    jq -e --arg skill "${skill_name}" '.skills[$skill] | type == "object"' "${LINUX_AGENT_REMOTE_MANIFEST}" >/dev/null 2>&1
}

linux_agent_remote_ref_is_registered() {
    local ref="${1%.sh}"
    linux_agent_remote_mode_enabled || return 1
    jq -e --arg ref "${ref}" '[.skills[].refs[]? | select(.ref == $ref)] | length == 1' "${LINUX_AGENT_REMOTE_MANIFEST}" >/dev/null 2>&1
}

linux_agent_remote_skill_marker_valid_at() {
    local skill_name="$1" skill_dir="$2" marker unsafe
    local expected_sha expected_version

    linux_agent_remote_mode_enabled || return 1
    [[ "${skill_name}" =~ ^[a-z0-9][a-z0-9-]*$ ]] || return 1
    marker="${skill_dir}/.remote-verified.json"
    linux_agent_skill_path_components_are_safe "${skill_dir}" || return 1
    [[ -d "${skill_dir}" && ! -L "${skill_dir}" ]] || return 1
    [[ -f "${marker}" && ! -L "${marker}" ]] || return 1
    unsafe="$(find "${skill_dir}" -type l -print -quit 2>/dev/null || true)"
    [[ -z "${unsafe}" ]] || return 1
    expected_sha="$(jq -r --arg skill "${skill_name}" '.skills[$skill].asset.sha256 // empty' "${LINUX_AGENT_REMOTE_MANIFEST}")"
    expected_version="$(jq -r '.version // empty' "${LINUX_AGENT_REMOTE_MANIFEST}")"
    [[ "${expected_sha}" =~ ^[0-9a-f]{64}$ && -n "${expected_version}" ]] || return 1
    jq -e --arg skill "${skill_name}" --arg sha256 "${expected_sha}" --arg version "${expected_version}" \
        '.skill == $skill and .sha256 == $sha256 and .release_version == $version' \
        "${marker}" >/dev/null 2>&1
}

linux_agent_remote_skill_ready() {
    local skill_name="$1"
    linux_agent_remote_skill_marker_valid_at "${skill_name}" "$(linux_agent_skills_dir)/${skill_name}"
}

linux_agent_remote_builtin_pending() {
    local skill_name="$1" user_dir
    linux_agent_remote_skill_is_known "${skill_name}" || return 1
    linux_agent_remote_skill_ready "${skill_name}" && return 1
    user_dir="$(linux_agent_user_skills_dir)"
    [[ ! -e "${user_dir}/${skill_name}" && ! -L "${user_dir}/${skill_name}" ]]
}

linux_agent_skill_path_components_are_safe() {
    local path="$1"
    python3 - "${path}" <<'PY'
import os
import stat
import sys
from pathlib import Path

candidate = Path(os.path.abspath(os.path.expanduser(sys.argv[1])))
current = Path(candidate.anchor)
parts = candidate.parts[1:]
for index, component in enumerate(parts):
    current /= component
    try:
        metadata = current.lstat()
    except FileNotFoundError:
        continue
    if stat.S_ISLNK(metadata.st_mode):
        raise SystemExit(1)
    if index < len(parts) - 1 and not stat.S_ISDIR(metadata.st_mode):
        raise SystemExit(1)
PY
}

linux_agent_fsync_single_directory() {
    python3 - "$1" <<'PY'
import os
import sys

descriptor = os.open(sys.argv[1], os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0))
try:
    os.fsync(descriptor)
finally:
    os.close(descriptor)
PY
}

linux_agent_remote_skill_result() {
    local ok="$1" status="$2" skill="$3" error="${4:-}" files="${5:-[]}"
    jq -cn --argjson ok "${ok}" --arg status "${status}" --arg skill "${skill}" --arg error "${error}" --argjson files "${files}" '
        {ok:$ok, status:$status, skill:$skill, files:$files}
        + (if $error == "" then {} else {error:$error} end)
    '
}

linux_agent_materialize_runtime_lock_release() {
    local upgraded="$1"
    if [[ "${upgraded}" == "true" ]]; then
        linux_agent_runtime_lock_downgrade_shared || {
            linux_agent_runtime_lock_release
            return 1
        }
    else
        linux_agent_runtime_lock_release
    fi
}

linux_agent_remote_validate_archive() {
    local archive_path="$1" skill_name="$2"
    python3 - "${archive_path}" "${skill_name}" <<'PY'
import pathlib
import sys
import tarfile

archive_path = pathlib.Path(sys.argv[1])
skill = sys.argv[2]
required_prefix = ("skills", skill)
with tarfile.open(archive_path, "r:gz") as archive:
    members = archive.getmembers()
    if not members or len(members) > 10000:
        raise SystemExit("invalid archive member count")
    seen = set()
    total_size = 0
    for member in members:
        path = pathlib.PurePosixPath(member.name)
        if path.is_absolute() or ".." in path.parts:
            raise SystemExit("unsafe archive path")
        parts = tuple(part for part in path.parts if part not in ("", "."))
        normalized = "/".join(parts)
        if not normalized or normalized in seen:
            raise SystemExit("empty or duplicate archive path")
        seen.add(normalized)
        if parts in (("skills",), required_prefix):
            if not member.isdir():
                raise SystemExit("archive parent path must be a directory")
            continue
        if len(parts) < 3 or parts[:2] != required_prefix:
            raise SystemExit("archive contains files outside the requested skill")
        if not (member.isfile() or member.isdir()):
            raise SystemExit("unsafe archive member type")
        if member.isfile():
            total_size += member.size
            if member.size > 32 * 1024 * 1024 or total_size > 128 * 1024 * 1024:
                raise SystemExit("skill archive expands beyond the allowed size")
PY
}

linux_agent_materialize_skill() {
    local skill_name="$1"
    local retain_runtime_lock="${2:-false}"
    local skills_dir target_skill lock_root lock_dir lock_acquired asset_name expected_sha expected_size max_size
    local release_base archive_path download_ok actual_size actual_sha stage_root staged_skill validation files marker_tmp
    local manifest_refs index_refs actual_refs observer_gate observer_subject audit_rc audit_payload rollback_ok
    local expected_contract_digest actual_contract_digest expected_index_digest actual_index_digest
    local expected_components actual_components
    local audit_failure mutation_state user_dir runtime_lock_upgraded=false

    if ! linux_agent_remote_mode_enabled; then
        linux_agent_remote_skill_result false skill_package_invalid "${skill_name}" "当前不是 remote runtime。"
        return 0
    fi
    if [[ "${retain_runtime_lock}" != "true" && "${retain_runtime_lock}" != "false" ]]; then
        linux_agent_remote_skill_result false skill_package_invalid "${skill_name}" "Runtime lock retention mode is invalid."
        return 0
    fi
    if [[ "${retain_runtime_lock}" == "true" && "${LINUX_AGENT_RUNTIME_LOCK_DEPTH:-0}" -gt 0 ]]; then
        linux_agent_remote_skill_result false runtime_busy "${skill_name}" "调用方已持有 Runtime 锁，无法保留独占事务。"
        return 0
    fi
    if [[ ! "${skill_name}" =~ ^[a-z0-9][a-z0-9-]*$ ]] || ! linux_agent_remote_skill_is_known "${skill_name}"; then
        linux_agent_remote_skill_result false skill_package_invalid "${skill_name}" "Skill 不在远程登记表中。"
        return 0
    fi
    user_dir="$(linux_agent_user_skills_dir)"
    if [[ -e "${user_dir}/${skill_name}" || -L "${user_dir}/${skill_name}" ]]; then
        jq -cn --arg skill "${skill_name}" \
            '{ok:false,status:"skill_conflict",code:"skill_conflict",skill:$skill,files:[],error:"用户 Skill 与远程内置保留名称冲突。"}'
        return 0
    fi
    if linux_agent_remote_skill_ready "${skill_name}"; then
        if [[ "${retain_runtime_lock}" == "true" ]]; then
            if ! linux_agent_runtime_lock_exclusive_nonblocking; then
                linux_agent_remote_skill_result false runtime_busy "${skill_name}" "Runtime 正在执行或变更，无法安装 Skill 组件。"
                return 0
            fi
            if ! linux_agent_remote_skill_ready "${skill_name}"; then
                linux_agent_runtime_lock_release
                linux_agent_remote_skill_result false runtime_busy "${skill_name}" "Skill 在事务锁获取期间发生变化，请重试。"
                return 0
            fi
        fi
        files="$(find "$(linux_agent_skills_dir)/${skill_name}" -type f ! -name .remote-verified.json -printf '%P\n' | sort | jq -R -s --arg skill "${skill_name}" 'split("\n") | map(select(length > 0) | "skills/" + $skill + "/" + .)')"
        linux_agent_remote_skill_result true skill_materialized "${skill_name}" "" "${files}"
        return 0
    fi
    if ! linux_agent_web_sensitive_edits_enabled; then
        linux_agent_sensitive_edits_disabled_result
        return 0
    fi

    # Materialization downloads and installs code.  In strict-compliance mode
    # it must be gated before even creating locks, archives, or staging files;
    # callers may reach this function while merely resolving a remote Skill.
    observer_subject="$(jq -cn --arg skill "${skill_name}" '{kind:"skill_materialize", skill:$skill}')"
    if declare -F linux_agent_observer_execution_gate >/dev/null 2>&1 &&
        ! observer_gate="$(linux_agent_observer_execution_gate "skill_materialize" "${observer_subject}")"; then
        printf '%s\n' "${observer_gate}"
        return 0
    fi
    if declare -F linux_agent_audit_require_event >/dev/null 2>&1 &&
        [[ -n "${LINUX_AGENT_AUDIT_LOG:-}" ]]; then
        audit_rc=0
        linux_agent_audit_require_event "skill_materialize_started" "${observer_subject}" || audit_rc=$?
        if ((audit_rc != 0)); then
            linux_agent_audit_failure_result "${audit_rc}" "skill_materialize_started"
            return 0
        fi
    fi

    skills_dir="$(linux_agent_skills_dir)"
    target_skill="${skills_dir}/${skill_name}"
    if ! linux_agent_skill_path_components_are_safe "${skills_dir}" ||
        [[ -L "${skills_dir}" || (-e "${skills_dir}" && ! -d "${skills_dir}") ]]; then
        linux_agent_remote_skill_result false skill_package_invalid "${skill_name}" "Skill 目录路径包含不安全的符号链接或非目录组件。"
        return 0
    fi
    if [[ -e "${target_skill}" || -L "${target_skill}" ]]; then
        linux_agent_remote_skill_result false skill_package_invalid "${skill_name}" "目标 Skill 目录已存在但没有有效的远程校验标记。"
        return 0
    fi
    lock_root="${LINUX_AGENT_TMP_ROOT:-${LINUX_AGENT_ROOT}/tmp}/skill-locks"
    lock_dir="${lock_root}/${skill_name}.lock"
    mkdir -p "${lock_root}"
    lock_acquired=false
    for _ in $(seq 1 200); do
        if mkdir "${lock_dir}" 2>/dev/null; then
            lock_acquired=true
            break
        fi
        if linux_agent_remote_skill_ready "${skill_name}"; then
            linux_agent_materialize_skill "${skill_name}" "${retain_runtime_lock}"
            return 0
        fi
        sleep 0.05
    done
    if [[ "${lock_acquired}" != "true" ]]; then
        linux_agent_remote_skill_result false skill_download_failed "${skill_name}" "等待 Skill 下载锁超时。"
        return 0
    fi

    asset_name="$(jq -r --arg skill "${skill_name}" '.skills[$skill].asset.name // empty' "${LINUX_AGENT_REMOTE_MANIFEST}")"
    expected_sha="$(jq -r --arg skill "${skill_name}" '.skills[$skill].asset.sha256 // empty' "${LINUX_AGENT_REMOTE_MANIFEST}")"
    expected_size="$(jq -r --arg skill "${skill_name}" '.skills[$skill].asset.size_bytes // 0' "${LINUX_AGENT_REMOTE_MANIFEST}")"
    max_size="$(jq -r --arg skill "${skill_name}" '.skills[$skill].asset.max_size_bytes // 0' "${LINUX_AGENT_REMOTE_MANIFEST}")"
    release_base="$(linux_agent_remote_release_base)"
    archive_path="${LINUX_AGENT_TMP_ROOT:-${LINUX_AGENT_ROOT}/tmp}/${asset_name}.$$"
    stage_root="${LINUX_AGENT_TMP_ROOT:-${LINUX_AGENT_ROOT}/tmp}/skill-stage.${skill_name}.$$"

    if [[ ! "${asset_name}" =~ ^linux-agent-skill-[a-z0-9-]+\.tar\.gz$ ||
        ! "${expected_sha}" =~ ^[0-9a-f]{64}$ ||
        ! "${expected_size}" =~ ^[0-9]+$ ||
        ! "${max_size}" =~ ^[0-9]+$ ||
        "${expected_size}" -le 0 ||
        "${expected_size}" -gt "${max_size}" ||
        -z "${release_base}" ]]; then
        rmdir "${lock_dir}" 2>/dev/null || true
        linux_agent_remote_skill_result false skill_package_invalid "${skill_name}" "远程 Skill manifest 字段非法。"
        return 0
    fi

    download_ok=true
    if [[ "${LINUX_AGENT_ALLOW_INSECURE_TEST_URL:-0}" == "1" ]]; then
        curl -fsSL --max-time 120 --max-filesize "${max_size}" "${release_base}/${asset_name}" -o "${archive_path}" || download_ok=false
    else
        curl -fsSL --proto '=https' --tlsv1.2 --max-time 120 --max-filesize "${max_size}" "${release_base}/${asset_name}" -o "${archive_path}" || download_ok=false
    fi
    if [[ "${download_ok}" != "true" || ! -f "${archive_path}" ]]; then
        rm -f "${archive_path}"
        rmdir "${lock_dir}" 2>/dev/null || true
        linux_agent_remote_skill_result false skill_download_failed "${skill_name}" "Skill 包下载失败。"
        return 0
    fi

    actual_size="$(stat -c '%s' "${archive_path}" 2>/dev/null || printf '0')"
    actual_sha="$(sha256sum "${archive_path}" | awk '{print $1}')"
    if [[ "${actual_size}" != "${expected_size}" || "${actual_sha}" != "${expected_sha}" ]]; then
        rm -f "${archive_path}"
        rmdir "${lock_dir}" 2>/dev/null || true
        linux_agent_remote_skill_result false skill_digest_mismatch "${skill_name}" "Skill 包摘要或大小不匹配。"
        return 0
    fi
    if ! linux_agent_remote_validate_archive "${archive_path}" "${skill_name}"; then
        rm -f "${archive_path}"
        rmdir "${lock_dir}" 2>/dev/null || true
        linux_agent_remote_skill_result false skill_package_invalid "${skill_name}" "Skill 包含不安全路径或文件类型。"
        return 0
    fi

    rm -rf "${stage_root}"
    mkdir -p "${stage_root}"
    tar --no-same-owner --no-same-permissions -xzf "${archive_path}" -C "${stage_root}"
    staged_skill="${stage_root}/skills/${skill_name}"
    manifest_refs="$(jq -c --arg skill "${skill_name}" '[.skills[$skill].refs[].ref] | sort | unique' "${LINUX_AGENT_REMOTE_MANIFEST}")"
    index_refs="$(python3 "${LINUX_AGENT_ROOT}/lib/skill_package.py" index \
        "$(linux_agent_skill_index_path)" 2>/dev/null |
        jq -c --arg skill "${skill_name}" \
            '[.skills[]? | select(.name == $skill) | .tools[]?.ref] | sort | unique')"
    actual_refs="$(jq -c --arg skill "${skill_name}" '[.tools[]? | $skill + "/" + .name] | sort | unique' \
        "${staged_skill}/linux-agent.json" 2>/dev/null || printf '[]')"
    if [[ "${manifest_refs}" != "${index_refs}" ]] || [[ "${manifest_refs}" != "${actual_refs}" ]]; then
        rm -rf "${stage_root}" "${archive_path}"
        rmdir "${lock_dir}" 2>/dev/null || true
        linux_agent_remote_skill_result false skill_package_invalid "${skill_name}" "Skill 包、INDEX 与远程登记引用不一致。"
        return 0
    fi
    expected_contract_digest="$(jq -r --arg skill "${skill_name}" '.skills[$skill].contract_digest // empty' "${LINUX_AGENT_REMOTE_MANIFEST}")"
    actual_contract_digest="$(python3 "${LINUX_AGENT_ROOT}/lib/skill_package.py" digest "${staged_skill}" --origin builtin 2>/dev/null |
        jq -r '.contract_digest // empty')"
    expected_index_digest="$(jq -r --arg skill "${skill_name}" '.skills[$skill].index_section_digest // empty' "${LINUX_AGENT_REMOTE_MANIFEST}")"
    actual_index_digest="$(python3 "${LINUX_AGENT_ROOT}/lib/skill_package.py" index "$(linux_agent_skill_index_path)" 2>/dev/null |
        jq -r --arg skill "${skill_name}" '.skills[]? | select(.name == $skill) | .section_digest')"
    if [[ ! "${expected_contract_digest}" =~ ^[0-9a-f]{64}$ || "${actual_contract_digest}" != "${expected_contract_digest}" ||
        ! "${expected_index_digest}" =~ ^[0-9a-f]{64}$ || "${actual_index_digest}" != "${expected_index_digest}" ]]; then
        rm -rf "${stage_root}" "${archive_path}"
        rmdir "${lock_dir}" 2>/dev/null || true
        linux_agent_remote_skill_result false skill_digest_mismatch "${skill_name}" "Skill contract 或 INDEX section 摘要不匹配。"
        return 0
    fi
    expected_components="$(jq -Sc --arg skill "${skill_name}" '.skills[$skill].components // {}' \
        "${LINUX_AGENT_REMOTE_MANIFEST}")"
    actual_components="$(python3 "${LINUX_AGENT_ROOT}/lib/skill_package.py" inspect \
        "${staged_skill}" --origin builtin 2>/dev/null | jq -Sc '.components // {}')"
    if [[ "${actual_components}" != "${expected_components}" ]]; then
        rm -rf "${stage_root}" "${archive_path}"
        rmdir "${lock_dir}" 2>/dev/null || true
        linux_agent_remote_skill_result false skill_package_invalid "${skill_name}" "Skill 组件契约与签名远程登记不一致。"
        return 0
    fi
    validation="$(python3 "${LINUX_AGENT_ROOT}/lib/skill_package.py" validate \
        "${staged_skill}" --origin builtin 2>/dev/null || true)"
    if [[ "$(jq -r '.ok // false' <<<"${validation}")" != "true" ]]; then
        rm -rf "${stage_root}" "${archive_path}"
        rmdir "${lock_dir}" 2>/dev/null || true
        linux_agent_remote_skill_result false skill_package_invalid "${skill_name}" "Skill 登记或策略校验失败。"
        return 0
    fi

    audit_payload="$(jq -cn --arg skill "${skill_name}" --arg sha256 "${actual_sha}" '{skill:$skill, sha256:$sha256}')"
    if declare -F linux_agent_audit_require_event >/dev/null 2>&1 &&
        [[ -n "${LINUX_AGENT_AUDIT_LOG:-}" ]]; then
        audit_rc=0
        linux_agent_audit_require_event "skill_materialize_commit" "${audit_payload}" || audit_rc=$?
        if ((audit_rc != 0)); then
            rm -rf "${stage_root}" "${archive_path}"
            rmdir "${lock_dir}" 2>/dev/null || true
            linux_agent_audit_failure_result "${audit_rc}" "skill_materialize_commit"
            return 0
        fi
    fi

    if ! linux_agent_web_sensitive_edits_enabled; then
        rm -rf "${stage_root}" "${archive_path}"
        rmdir "${lock_dir}" 2>/dev/null || true
        linux_agent_sensitive_edits_disabled_result
        return 0
    fi

    if [[ ! -e "${skills_dir}" ]]; then
        if ! mkdir -p "${skills_dir}"; then
            rm -rf "${stage_root}" "${archive_path}"
            rmdir "${lock_dir}" 2>/dev/null || true
            linux_agent_remote_skill_result false skill_package_invalid "${skill_name}" "无法创建 Skill 目标目录。"
            return 0
        fi
    fi
    if ! linux_agent_skill_path_components_are_safe "${skills_dir}" ||
        [[ -L "${skills_dir}" || ! -d "${skills_dir}" ]]; then
        rm -rf "${stage_root}" "${archive_path}"
        rmdir "${lock_dir}" 2>/dev/null || true
        linux_agent_remote_skill_result false skill_package_invalid "${skill_name}" "Skill 目标目录在提交前变得不安全。"
        return 0
    fi
    if [[ -e "${target_skill}" || -L "${target_skill}" ]]; then
        rm -rf "${stage_root}" "${archive_path}"
        rmdir "${lock_dir}" 2>/dev/null || true
        linux_agent_remote_skill_result false skill_package_invalid "${skill_name}" "目标 Skill 目录在提交前已存在。"
        return 0
    fi
    marker_tmp="${staged_skill}/.remote-verified.json.tmp"
    jq -cn --arg skill "${skill_name}" --arg sha256 "${actual_sha}" --arg version "$(jq -r '.version' "${LINUX_AGENT_REMOTE_MANIFEST}")" \
        '{skill:$skill, sha256:$sha256, release_version:$version}' >"${marker_tmp}"
    mv "${marker_tmp}" "${staged_skill}/.remote-verified.json"
    if [[ "${LINUX_AGENT_RUNTIME_LOCK_DEPTH:-0}" -gt 0 ]]; then
        if linux_agent_runtime_lock_upgrade_exclusive_nonblocking; then
            runtime_lock_upgraded=true
        else
            rm -rf "${stage_root}" "${archive_path}"
            rmdir "${lock_dir}" 2>/dev/null || true
            linux_agent_remote_skill_result false runtime_busy "${skill_name}" "Runtime 正在执行或变更，无法提交 Skill。"
            return 0
        fi
    elif ! linux_agent_runtime_lock_exclusive_nonblocking; then
        rm -rf "${stage_root}" "${archive_path}"
        rmdir "${lock_dir}" 2>/dev/null || true
        linux_agent_remote_skill_result false runtime_busy "${skill_name}" "Runtime 正在执行或变更，无法提交 Skill。"
        return 0
    fi
    # Re-read the server-side gate immediately before the materializing rename;
    # a package may have been reviewed while an administrator disabled Web
    # sensitive edits in the meantime.
    if ! linux_agent_web_sensitive_edits_enabled; then
        linux_agent_materialize_runtime_lock_release "${runtime_lock_upgraded}" || true
        rm -rf "${stage_root}" "${archive_path}"
        rmdir "${lock_dir}" 2>/dev/null || true
        linux_agent_sensitive_edits_disabled_result
        return 0
    fi
    if ! mv -nT -- "${staged_skill}" "${target_skill}" ||
        [[ -e "${staged_skill}" || -L "${staged_skill}" ]]; then
        linux_agent_materialize_runtime_lock_release "${runtime_lock_upgraded}" || true
        rm -rf "${stage_root}" "${archive_path}"
        rmdir "${lock_dir}" 2>/dev/null || true
        linux_agent_remote_skill_result false skill_package_invalid "${skill_name}" "Skill 目标目录在原子提交时已被占用。"
        return 0
    fi
    if ! linux_agent_fsync_single_directory "${skills_dir}"; then
        rollback_ok=true
        if [[ -d "${target_skill}" && ! -L "${target_skill}" && ! -e "${staged_skill}" ]]; then
            mv -T -- "${target_skill}" "${staged_skill}" || rollback_ok=false
        else
            rollback_ok=false
        fi
        linux_agent_materialize_runtime_lock_release "${runtime_lock_upgraded}" || true
        rm -rf "${stage_root}" "${archive_path}"
        rmdir "${lock_dir}" 2>/dev/null || true
        if [[ "${rollback_ok}" != "true" ]]; then
            linux_agent_remote_skill_result false skill_package_invalid "${skill_name}" "Skill 提交目录 fsync 失败且无法回滚。"
        else
            linux_agent_remote_skill_result false skill_package_invalid "${skill_name}" "Skill 提交目录 fsync 失败。"
        fi
        return 0
    fi
    files="$(find "${target_skill}" -type f ! -name .remote-verified.json -printf '%P\n' | sort | jq -R -s --arg skill "${skill_name}" 'split("\n") | map(select(length > 0) | "skills/" + $skill + "/" + .)')"
    if declare -F linux_agent_audit_require_event >/dev/null 2>&1 &&
        [[ -n "${LINUX_AGENT_AUDIT_LOG:-}" ]]; then
        audit_rc=0
        linux_agent_audit_require_event "skill_materialized" "$(jq -c '. + {status:"skill_materialized"}' <<<"${audit_payload}")" || audit_rc=$?
        if ((audit_rc != 0)); then
            rollback_ok=false
            if [[ -d "${target_skill}" && ! -L "${target_skill}" &&
                ! -e "${staged_skill}" && ! -L "${staged_skill}" ]] &&
                mv -T -- "${target_skill}" "${staged_skill}" &&
                linux_agent_fsync_single_directory "${skills_dir}"; then
                rollback_ok=true
            fi
            rm -rf "${stage_root}" "${archive_path}"
            rmdir "${lock_dir}" 2>/dev/null || true
            if [[ "${rollback_ok}" == "true" ]]; then
                linux_agent_materialize_runtime_lock_release "${runtime_lock_upgraded}" || true
                linux_agent_audit_failure_result "${audit_rc}" "skill_materialized"
                return 0
            fi
            if [[ -d "${target_skill}" && ! -L "${target_skill}" ]]; then
                mutation_state="committed"
            else
                mutation_state="rollback_unconfirmed"
            fi
            audit_failure="$(linux_agent_audit_failure_result "${audit_rc}" "skill_materialized")"
            linux_agent_materialize_runtime_lock_release "${runtime_lock_upgraded}" || true
            jq -c \
                --arg skill "${skill_name}" \
                --arg mutation_state "${mutation_state}" \
                '.error = "Skill 提交后的审计写入失败，且回滚未能确认持久化；请先检查 mutation_state 再决定是否重试。"
                | .message = .error
                | .details += {skill:$skill, mutation_state:$mutation_state}' \
                <<<"${audit_failure}"
            return 0
        fi
    fi
    if [[ "${retain_runtime_lock}" != "true" ]] &&
        ! linux_agent_materialize_runtime_lock_release "${runtime_lock_upgraded}"; then
        rm -rf "${stage_root}" "${archive_path}"
        rmdir "${lock_dir}" 2>/dev/null || true
        linux_agent_remote_skill_result false runtime_busy "${skill_name}" "Skill 已提交，但无法恢复执行共享锁。"
        return 0
    fi
    rm -rf "${stage_root}" "${archive_path}"
    rmdir "${lock_dir}" 2>/dev/null || true
    linux_agent_remote_skill_result true skill_materialized "${skill_name}" "" "${files}"
}

linux_agent_ensure_skill_materialized() {
    local ref="$1" skill_name origin result
    linux_agent_remote_mode_enabled || return 0
    skill_name="$(linux_agent_skill_name_from_ref "${ref}")"
    origin="$(linux_agent_skill_package_origin "${skill_name}" 2>/dev/null || true)"
    if [[ "${origin}" == "user" ]] || linux_agent_remote_skill_ready "${skill_name}"; then
        return 0
    fi
    if ! linux_agent_remote_builtin_pending "${skill_name}"; then
        linux_agent_print_error "Skill 不在用户 overlay 或远程内置登记表中，或存在同名冲突。"
        return 1
    fi
    result="$(linux_agent_materialize_skill "${skill_name}")"
    if [[ "$(jq -r '.ok // false' <<<"${result}")" != "true" ]]; then
        linux_agent_print_error "$(jq -r '.error // .status' <<<"${result}")"
        return 1
    fi
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
    local skill_name package_dir entrypoint
    skill_name="$(linux_agent_skill_name_from_ref "${ref}")"
    package_dir="$(linux_agent_skill_package_dir "${skill_name}")" || return $?
    entrypoint="$(python3 "${LINUX_AGENT_ROOT}/lib/skill_package.py" tool "${package_dir}" "${ref%.sh}" \
        --origin "$(linux_agent_skill_package_origin "${skill_name}")" 2>/dev/null |
        jq -r '.tool.entrypoint // empty')"
    [[ -n "${entrypoint}" ]] || return 1
    printf '%s/%s\n' "${package_dir}" "${entrypoint}"
}

linux_agent_skill_metadata_path() {
    local skill_name="$1"
    local package_dir
    package_dir="$(linux_agent_skill_package_dir "${skill_name}")" || return $?
    printf '%s/linux-agent.json\n' "${package_dir}"
}

linux_agent_skill_is_registered() {
    local ref="$1"
    local skill_name script_path package_dir origin
    linux_agent_skill_ref_is_valid "${ref}" || return 1
    skill_name="$(linux_agent_skill_name_from_ref "${ref}")"
    if linux_agent_remote_builtin_pending "${skill_name}"; then
        linux_agent_remote_ref_is_registered "${ref}"
        return $?
    fi
    package_dir="$(linux_agent_skill_package_dir "${skill_name}")" || return 1
    origin="$(linux_agent_skill_package_origin "${skill_name}")" || return 1
    python3 "${LINUX_AGENT_ROOT}/lib/skill_package.py" tool "${package_dir}" "${ref%.sh}" --origin "${origin}" >/dev/null 2>&1 || return 1
    if [[ "${origin}" == "builtin" ]]; then
        linux_agent_skill_catalog_json |
            jq -e --arg ref "${ref%.sh}" \
                'any(.tools[]?; .ref == $ref and .origin == "builtin" and .state == "installed")' \
                >/dev/null || return 1
    fi
    script_path="$(linux_agent_skill_script_path "${ref}")" || return 1
    [[ -f "${script_path}" && ! -L "${script_path}" ]]
}

linux_agent_risk_is_valid() {
    case "${1:-}" in
        low | medium | high | critical) return 0 ;;
        *) return 1 ;;
    esac
}

linux_agent_skill_declared_risk_at() {
    local ref="$1"
    local metadata_path="$2"
    local script_name risk
    script_name="$(linux_agent_skill_script_name_from_ref "${ref}")"

    [[ -f "${metadata_path}" && ! -L "${metadata_path}" ]] || {
        printf 'critical\n'
        return 0
    }
    risk="$(jq -r --arg script "${script_name%.sh}" '[.tools[]? | select(.name == $script) | .risk][0] // empty' "${metadata_path}" 2>/dev/null || true)"
    if linux_agent_risk_is_valid "${risk}"; then
        printf '%s\n' "${risk}"
    else
        printf 'critical\n'
    fi
}

linux_agent_skill_declared_risk() {
    local ref="$1"
    local skill_name metadata_path
    if ! linux_agent_skill_ref_is_valid "${ref}"; then
        printf 'critical\n'
        return 0
    fi
    skill_name="$(linux_agent_skill_name_from_ref "${ref}")"
    if linux_agent_remote_builtin_pending "${skill_name}"; then
        jq -r --arg ref "${ref%.sh}" '[.skills[].refs[]? | select(.ref == $ref) | .risk][0] // "critical"' "${LINUX_AGENT_REMOTE_MANIFEST}"
        return 0
    fi
    metadata_path="$(linux_agent_skill_metadata_path "${skill_name}" 2>/dev/null || true)"
    linux_agent_skill_declared_risk_at "${ref}" "${metadata_path}"
}

linux_agent_skill_effective_risk() {
    local ref="$1" arguments_json="${2:-}" metadata_path skill_name tool_name dynamic
    [[ -n "${arguments_json}" ]] || arguments_json='{}'
    skill_name="$(linux_agent_skill_name_from_ref "${ref}")"
    tool_name="$(linux_agent_skill_script_name_from_ref "${ref}")"
    metadata_path="$(linux_agent_skill_metadata_path "${skill_name}" 2>/dev/null || true)"
    if [[ -f "${metadata_path}" && ! -L "${metadata_path}" ]] && jq -e 'type == "object"' <<<"${arguments_json}" >/dev/null 2>&1; then
        dynamic="$(jq -nr \
            --slurpfile extension "${metadata_path}" \
            --arg tool "${tool_name%.sh}" \
            --argjson arguments "${arguments_json}" '
            [$extension[0].tools[]? | select(.name == $tool) | .guards[]?
                | select(.type == "risk_by_value")][0] as $guard
            | if ($guard | type) != "object" then empty
              else ($arguments[$guard.field] // "") as $value
              | ($guard.values[($value | tostring | ascii_downcase)] // $guard.default // empty)
              end' 2>/dev/null || true)"
        if linux_agent_risk_is_valid "${dynamic}"; then
            printf '%s\n' "${dynamic}"
            return 0
        fi
    fi
    linux_agent_skill_declared_risk "${ref}"
}

linux_agent_skill_extension_field() {
    local ref="$1" field="$2" fallback="$3"
    local skill_name script_name metadata_path
    linux_agent_skill_ref_is_valid "${ref}" || {
        printf '%s\n' "${fallback}"
        return 0
    }
    skill_name="$(linux_agent_skill_name_from_ref "${ref}")"
    script_name="$(linux_agent_skill_script_name_from_ref "${ref}")"
    if linux_agent_remote_builtin_pending "${skill_name}"; then
        jq -r --arg ref "${ref%.sh}" --arg field "${field}" --arg fallback "${fallback}" \
            '[.skills[].refs[]? | select(.ref == $ref) | .[$field]][0] // $fallback' \
            "${LINUX_AGENT_REMOTE_MANIFEST}" 2>/dev/null || printf '%s\n' "${fallback}"
        return 0
    fi
    metadata_path="$(linux_agent_skill_metadata_path "${skill_name}" 2>/dev/null || true)"
    [[ -f "${metadata_path}" && ! -L "${metadata_path}" ]] || {
        printf '%s\n' "${fallback}"
        return 0
    }
    jq -r --arg script "${script_name%.sh}" --arg field "${field}" --arg fallback "${fallback}" \
        '[.tools[]? | select(.name == $script) |
            if $field == "execution_class" then .execution.class
            elif $field == "capability" then .execution.capability
            elif $field == "dispatch" then .execution.dispatch
            elif $field == "approval_scope" then .approval_scope
            else .[$field] end][0] // $fallback' \
        "${metadata_path}" 2>/dev/null || printf '%s\n' "${fallback}"
}

linux_agent_skill_tool_contract_json() {
    local ref="$1" skill_name package origin result
    skill_name="$(linux_agent_skill_name_from_ref "${ref}")"
    package="$(linux_agent_skill_package_dir "${skill_name}" 2>/dev/null || true)"
    origin="$(linux_agent_skill_package_origin "${skill_name}" 2>/dev/null || true)"
    [[ -n "${package}" && -n "${origin}" ]] || {
        jq -cn --arg ref "${ref%.sh}" '{ok:false,status:"unavailable",ref:$ref,error:"Skill package is unavailable"}'
        return 0
    }
    result="$(python3 "${LINUX_AGENT_ROOT}/lib/skill_package.py" tool "${package}" "${ref%.sh}" --origin "${origin}" 2>/dev/null || true)"
    if ! jq -e '.ok == true and (.tool | type == "object")' <<<"${result}" >/dev/null 2>&1; then
        jq -cn --arg ref "${ref%.sh}" '{ok:false,status:"invalid",ref:$ref,error:"Skill tool contract is invalid"}'
        return 0
    fi
    printf '%s\n' "${result}"
}

linux_agent_skill_guard_json() {
    local ref="$1" guard_type="$2" skill_name contract
    linux_agent_skill_ref_is_valid "${ref}" || return 1
    skill_name="$(linux_agent_skill_name_from_ref "${ref}")"
    if linux_agent_remote_builtin_pending "${skill_name}"; then
        jq -c --arg ref "${ref%.sh}" --arg type "${guard_type}" '
            [.skills[].refs[]? | select(.ref == $ref) | .guards[]?
             | select(.type == $type)][0] | select(type == "object")
        ' "${LINUX_AGENT_REMOTE_MANIFEST}" 2>/dev/null
        return $?
    fi
    contract="$(linux_agent_skill_tool_contract_json "${ref}")"
    jq -c --arg type "${guard_type}" '
        [.tool.guards[]? | select(.type == $type)][0]
        | select(type == "object")
    ' <<<"${contract}" 2>/dev/null
}

linux_agent_skill_adapter_path() {
    local ref="$1" contract package adapter
    contract="$(linux_agent_skill_tool_contract_json "${ref}")"
    package="$(jq -r '.package // empty' <<<"${contract}")"
    adapter="$(jq -r '.tool.execution.adapter // empty' <<<"${contract}")"
    [[ -n "${package}" && -n "${adapter}" ]] || return 1
    printf '%s/%s\n' "${package}" "${adapter}"
}

linux_agent_filter_builtin_skill_review() {
    local ref="$1"
    local review_json="$2"
    local skill_name origin

    skill_name="${ref%%/*}"
    origin=""
    origin="$(linux_agent_skill_package_origin "${skill_name}" 2>/dev/null || true)"
    if [[ -z "${origin}" ]] && linux_agent_remote_builtin_pending "${skill_name}"; then
        origin="builtin"
    fi
    if [[ "${origin}" != "builtin" ]]; then
        printf '%s\n' "${review_json}"
        return 0
    fi

    # Release-owned Skills are authenticated by the immutable release boundary.
    # Keep dynamic execution, destructive operations, and other semantic
    # findings, but do not treat release commands/functions that are outside
    # the lightweight shell lexer's vocabulary as user-supplied executables.
    # User and unverified remote Skills retain the strict unknown-head guard.
    jq -c '
        .findings = [
            .findings[]?
            | select(
                (
                    (.code | IN(
                        "AST_COMMAND_SUBSTITUTION",
                        "AST_PROCESS_SUBSTITUTION",
                        "AST_HEREDOC",
                        "AST_UNKNOWN_COMMAND"
                    ))
                    or (
                        .code == "AST_WRAPPER_EXEC"
                        and .command_head == "source"
                        and (.text // "") == "source ${ROOT_DIR}/lib/common.sh"
                    )
                )
                | not
            )
        ]
        | .approved = (([.findings[]? | select(.severity == "critical")] | length) == 0)
        | .approval_required = ((.findings | length) > 0)
        | .risk_level = (
            if any(.findings[]?; .severity == "critical") then "critical"
            elif any(.findings[]?; .severity == "high") then "high"
            elif any(.findings[]?; .severity == "medium") then "medium"
            else "low" end
        )
    ' <<<"${review_json}"
}

linux_agent_review_with_declared_skill_risk() {
    local ref="$1"
    local review_json="$2"
    local arguments_json="${3:-}"
    local declared_risk severity action
    [[ -n "${arguments_json}" ]] || arguments_json='{}'
    declared_risk="$(linux_agent_skill_effective_risk "${ref}" "${arguments_json}")"
    if [[ "${declared_risk}" == "low" ]]; then
        printf '%s\n' "${review_json}"
        return 0
    fi

    severity="${declared_risk}"
    if [[ "${declared_risk}" == "critical" ]]; then
        action="block"
    else
        action="approve"
    fi

    jq -c \
        --arg ref "${ref}" \
        --arg declared_risk "${declared_risk}" \
        --arg severity "${severity}" \
        --arg action "${action}" '
        def rank($risk):
            if $risk == "critical" then 4
            elif $risk == "high" then 3
            elif $risk == "medium" then 2
            else 1 end;
        def max_risk($a; $b):
            if rank($a) >= rank($b) then $a else $b end;
        .findings = ((.findings // []) + [{
            severity:$severity,
            code:"SKILL_DECLARED_RISK",
            source:"skill",
            category:"declared_risk",
            action:$action,
            ref:$ref,
            message:("Skill 声明该脚本最低风险为 " + $declared_risk + "，不能作为 low 风险自动执行。")
        }])
        | .approval_required = true
        | .risk_level = max_risk((.risk_level // "low"); $declared_risk)
        | .approved = ((.approved // false) and ($declared_risk != "critical"))
    ' <<<"${review_json}"
}

linux_agent_skill_script_content() {
    local ref="$1"
    local script_path
    linux_agent_ensure_skill_materialized "${ref}" || return 1
    script_path="$(linux_agent_skill_script_path "${ref}")"
    [[ -f "${script_path}" ]] || return 1
    cat "${script_path}"
}

linux_agent_skills_list() {
    linux_agent_skill_catalog_json
}

linux_agent_managed_skill_component_command() {
    local action="$1" package="$2" purge="${3:-false}"
    local state="${LINUX_AGENT_INSTALL_PREFIX}/.install-state.json"
    local ledger="${LINUX_AGENT_DATA_DIR}/skill-components.json"
    local service_user service_group credential_user credential_group
    local unit_dir="${LINUX_AGENT_SYSTEMD_UNIT_DIR:-/etc/systemd/system}"
    local host_policy="${LINUX_AGENT_HOST_OPS_POLICY_PATH:-/etc/linux-agent/host-ops-policy.json}"
    local -a command=()
    [[ -f "${state}" && ! -L "${state}" ]] || {
        jq -cn '{ok:false,status:"invalid_install_state",code:"invalid_install_state",error:"Managed install state is unavailable"}'
        return 1
    }
    service_user="$(jq -er '.service_user' "${state}")" || return 1
    service_group="$(id -gn "${service_user}" 2>/dev/null || true)"
    [[ -n "${service_group}" ]] || {
        jq -cn '{ok:false,status:"invalid_install_state",code:"invalid_install_state",error:"Managed service group is unavailable"}'
        return 1
    }
    credential_user="$(jq -r '.credential_user // ""' "${state}")"
    credential_group="$(id -gn "${credential_user}" 2>/dev/null || true)"
    [[ -n "${credential_user}" && -n "${credential_group}" ]] || {
        credential_user="linux-agent-credential"
        credential_group="linux-agent-credential"
    }
    command=(python3 "${LINUX_AGENT_ROOT}/lib/skill_component_runtime.py" "${action}"
        "${package}" --ledger "${ledger}" --prefix "${LINUX_AGENT_INSTALL_PREFIX}"
        --unit-dir "${unit_dir}" --host-policy "${host_policy}"
        --web-user "${service_user}" --web-group "${service_group}"
        --credential-user "${credential_user}" --credential-group "${credential_group}")
    linux_agent_managed_execution_enabled && command+=(--systemd)
    if [[ "${purge}" == "true" ]]; then
        command+=(--purge --confirm PURGE_SKILL_DATA)
    fi
    "${command[@]}"
}

linux_agent_skill_read() {
    local skill_name="$1" relative_path="${2:-SKILL.md}" package origin result
    [[ "${skill_name}" =~ ^[a-z0-9][a-z0-9-]*$ ]] || {
        jq -cn '{ok:false,status:"invalid_path",code:"invalid_path",error:"Skill name is invalid"}'
        return 0
    }
    if linux_agent_remote_builtin_pending "${skill_name}"; then
        result="$(linux_agent_materialize_skill "${skill_name}")"
        if [[ "$(jq -r '.ok // false' <<<"${result}")" != "true" ]]; then
            printf '%s\n' "${result}"
            return 0
        fi
    fi
    package="$(linux_agent_skill_package_dir "${skill_name}" 2>/dev/null || true)"
    origin="$(linux_agent_skill_package_origin "${skill_name}" 2>/dev/null || true)"
    if [[ -z "${package}" || -z "${origin}" ]]; then
        jq -cn --arg skill "${skill_name}" '{ok:false,status:"not_found",code:"not_found",skill:$skill,error:"Skill is not installed"}'
        return 0
    fi
    if ! linux_agent_runtime_lock_shared; then
        jq -cn '{ok:false,status:"runtime_busy",code:"runtime_busy",error:"Runtime is being changed"}'
        return 0
    fi
    result="$(python3 "${LINUX_AGENT_ROOT}/lib/skill_lifecycle.py" read "${package}" \
        --root "$(dirname "${package}")" --origin "${origin}" --path "${relative_path}" 2>/dev/null || true)"
    linux_agent_runtime_lock_release
    printf '%s\n' "${result}"
}

linux_agent_skill_install() {
    local scope="$1" subject="$2" result component_result package result_file
    local manifest_path saved_remote_mode saved_manifest saved_base saved_skills_dir
    case "${scope}" in
        user)
            if ! linux_agent_runtime_lock_exclusive_nonblocking; then
                jq -cn '{ok:false,status:"runtime_busy",code:"runtime_busy",error:"Runtime is executing or being changed"}'
                return 0
            fi
            result="$(python3 "${LINUX_AGENT_ROOT}/lib/skill_lifecycle.py" install "${subject}" \
                --root "$(linux_agent_user_skills_dir)" --origin user --index "$(linux_agent_skill_index_path)" 2>/dev/null || true)"
            linux_agent_runtime_lock_release
            printf '%s\n' "${result}"
            ;;
        builtin)
            if linux_agent_remote_mode_enabled; then
                result="$(linux_agent_materialize_skill "${subject}")"
                if [[ "$(jq -r '.ok // false' <<<"${result}" 2>/dev/null || printf false)" == "true" ]]; then
                    jq -c '.materialization_status = .status | .status = "installed" | .scope = "builtin"' \
                        <<<"${result}"
                else
                    printf '%s\n' "${result}"
                fi
                return 0
            fi
            if ! linux_agent_managed_mode_enabled; then
                jq -cn '{ok:false,status:"unsupported",code:"unsupported",error:"builtin install is available only in Remote or Managed mode"}'
                return 0
            fi
            if [[ "${EUID}" -ne 0 ]]; then
                jq -cn '{ok:false,status:"forbidden",code:"forbidden",error:"Managed builtin Skill installation requires administrator privileges"}'
                return 0
            fi
            manifest_path="${LINUX_AGENT_INSTALL_PREFIX}/release-manifest.json"
            if [[ ! -f "${manifest_path}" || -L "${manifest_path}" ]]; then
                jq -cn '{ok:false,status:"skill_package_unavailable",code:"skill_package_unavailable",error:"signed release manifest is unavailable"}'
                return 0
            fi
            saved_remote_mode="${LINUX_AGENT_REMOTE_MODE:-0}"
            saved_manifest="${LINUX_AGENT_REMOTE_MANIFEST:-}"
            saved_base="${LINUX_AGENT_REMOTE_RELEASE_BASE:-}"
            saved_skills_dir="${LINUX_AGENT_SKILLS_DIR:-}"
            LINUX_AGENT_REMOTE_MODE=1
            LINUX_AGENT_REMOTE_MANIFEST="${manifest_path}"
            LINUX_AGENT_REMOTE_RELEASE_BASE="${LINUX_AGENT_MANAGED_RELEASE_BASE:-https://github.com/libeal/ASSIstant/releases/download/$(jq -r '.version' "${manifest_path}")}"
            LINUX_AGENT_SKILLS_DIR="$(linux_agent_builtin_skills_dir)"
            result_file="$(mktemp "${LINUX_AGENT_TMP_ROOT}/managed-skill-install.XXXXXX")" || {
                LINUX_AGENT_REMOTE_MODE="${saved_remote_mode}"
                LINUX_AGENT_REMOTE_MANIFEST="${saved_manifest}"
                LINUX_AGENT_REMOTE_RELEASE_BASE="${saved_base}"
                LINUX_AGENT_SKILLS_DIR="${saved_skills_dir}"
                jq -cn '{ok:false,status:"skill_package_unavailable",code:"skill_package_unavailable",error:"cannot create managed Skill transaction result file"}'
                return 0
            }
            if linux_agent_materialize_skill "${subject}" true >"${result_file}"; then
                result="$(<"${result_file}")"
            else
                result='{"ok":false,"status":"skill_package_unavailable","code":"skill_package_unavailable","error":"managed Skill materialization failed"}'
            fi
            rm -f -- "${result_file}"
            LINUX_AGENT_REMOTE_MODE="${saved_remote_mode}"
            LINUX_AGENT_REMOTE_MANIFEST="${saved_manifest}"
            LINUX_AGENT_REMOTE_RELEASE_BASE="${saved_base}"
            LINUX_AGENT_SKILLS_DIR="${saved_skills_dir}"
            if [[ "$(jq -r '.ok // false' <<<"${result}")" != "true" ]]; then
                linux_agent_runtime_lock_release
                printf '%s\n' "${result}"
                return 0
            fi
            result="$(jq -c '.materialization_status = .status | .status = "installed" | .scope = "builtin"' \
                <<<"${result}")"
            package="$(linux_agent_builtin_skills_dir)/${subject}"
            component_result="$(linux_agent_managed_skill_component_command install "${package}" 2>/dev/null || true)"
            if [[ "$(jq -r '.ok // false' <<<"${component_result}" 2>/dev/null || printf false)" != "true" ]]; then
                python3 "${LINUX_AGENT_ROOT}/lib/skill_lifecycle.py" uninstall "${subject}" \
                    --root "$(linux_agent_builtin_skills_dir)" --origin builtin >/dev/null 2>&1 || true
                linux_agent_runtime_lock_release
                jq -cn --arg skill "${subject}" \
                    --arg error "$(jq -r '.error // "component installation failed"' <<<"${component_result:-\{\}}" 2>/dev/null || printf 'component installation failed')" \
                    '{ok:false,status:"skill_component_install_failed",code:"skill_component_install_failed",skill:$skill,error:$error}'
                return 0
            fi
            linux_agent_runtime_lock_release
            jq -cn --argjson package_result "${result}" --argjson components "${component_result}" \
                '$package_result + {components:$components}'
            ;;
        *)
            jq -cn '{ok:false,status:"invalid_action",code:"invalid_action",error:"scope must be user or builtin"}'
            ;;
    esac
}

linux_agent_skill_uninstall() {
    local scope="$1" skill_name="$2" purge="${3:-false}" confirm="${4:-}"
    local root origin result component_result package managed_components=false
    local package_removed=false web_restart_required=false
    if [[ "${purge}" == "true" && "${confirm}" != "PURGE_SKILL_DATA" ]]; then
        jq -cn '{ok:false,status:"invalid_action",code:"invalid_action",error:"purge requires confirm=PURGE_SKILL_DATA"}'
        return 0
    fi
    case "${scope}" in
        user)
            root="$(linux_agent_user_skills_dir)"
            origin=user
            ;;
        builtin)
            if ! linux_agent_remote_mode_enabled && ! linux_agent_managed_mode_enabled; then
                jq -cn '{ok:false,status:"unsupported",code:"unsupported",error:"builtin uninstall is available only in Remote or Managed mode"}'
                return 0
            fi
            if linux_agent_managed_mode_enabled && [[ "${EUID}" -ne 0 ]]; then
                jq -cn '{ok:false,status:"forbidden",code:"forbidden",error:"Managed builtin Skill removal requires administrator privileges"}'
                return 0
            fi
            root="$(linux_agent_builtin_skills_dir)"
            origin=builtin
            linux_agent_managed_mode_enabled && managed_components=true
            ;;
        *)
            jq -cn '{ok:false,status:"invalid_action",code:"invalid_action",error:"scope must be user or builtin"}'
            return 0
            ;;
    esac
    if ! linux_agent_runtime_lock_exclusive_nonblocking; then
        jq -cn '{ok:false,status:"runtime_busy",code:"runtime_busy",error:"Runtime is executing or being changed"}'
        return 0
    fi
    package="${root}/${skill_name}"
    component_result='{"ok":true,"result":{"purged_paths":[]}}'
    if [[ "${managed_components}" == "true" ]]; then
        component_result="$(linux_agent_managed_skill_component_command uninstall \
            "${package}" false 2>/dev/null || true)"
        if [[ "$(jq -r '.ok // false' <<<"${component_result}" 2>/dev/null || printf false)" != "true" ]]; then
            linux_agent_runtime_lock_release
            jq -cn --arg skill "${skill_name}" \
                --arg error "$(jq -r '.error // "component removal failed"' <<<"${component_result:-\{\}}" 2>/dev/null || printf 'component removal failed')" \
                '{ok:false,status:"skill_component_uninstall_failed",code:"skill_component_uninstall_failed",skill:$skill,error:$error}'
            return 0
        fi
        web_restart_required="$(jq -r '.web_restart_required // false' <<<"${component_result}")"
    fi
    local -a command=(python3 "${LINUX_AGENT_ROOT}/lib/skill_lifecycle.py" uninstall "${skill_name}" --root "${root}" --origin "${origin}")
    result="$("${command[@]}" 2>/dev/null || true)"
    if [[ "$(jq -r '.ok // false' <<<"${result}" 2>/dev/null || printf false)" == "true" ]]; then
        package_removed=true
    fi
    if [[ "${managed_components}" == "true" &&
        "$(jq -r '.ok // false' <<<"${result}" 2>/dev/null || printf false)" != "true" ]]; then
        linux_agent_managed_skill_component_command install "${package}" >/dev/null 2>&1 || true
    fi
    if [[ "${managed_components}" == "true" && "${purge}" == "true" &&
        "$(jq -r '.ok // false' <<<"${result}" 2>/dev/null || printf false)" == "true" ]]; then
        component_result="$(linux_agent_managed_skill_component_command uninstall \
            "${package}" true 2>/dev/null || true)"
        if [[ "$(jq -r '.ok // false' <<<"${component_result}" 2>/dev/null || printf false)" != "true" ]]; then
            result="$(jq -cn --arg skill "${skill_name}" \
                --arg error "$(jq -r '.error // "owned data purge failed"' <<<"${component_result:-\{\}}" 2>/dev/null || printf 'owned data purge failed')" \
                '{ok:false,status:"skill_component_uninstall_failed",code:"skill_component_uninstall_failed",skill:$skill,error:$error,package_removed:true}')"
        fi
    fi
    if [[ "${managed_components}" == "true" && "${package_removed}" == "true" &&
        "${web_restart_required}" == "true" ]] &&
        ! systemctl try-restart linux-agent-web.service >/dev/null 2>&1; then
        if [[ "$(jq -r '.ok // false' <<<"${result}" 2>/dev/null || printf false)" == "true" ]]; then
            result="$(jq -cn --arg skill "${skill_name}" \
                '{ok:false,status:"skill_web_restart_failed",code:"skill_web_restart_failed",skill:$skill,error:"Skill was removed, but Web could not reload the installed package set",package_removed:true}')"
        else
            result="$(jq -c '.web_restart_failed = true
                | .error = ((.error // "Skill removal failed") + "; Web could not reload the installed package set")' \
                <<<"${result}")"
        fi
    fi
    linux_agent_runtime_lock_release
    if [[ "$(jq -r '.ok // false' <<<"${result}" 2>/dev/null || printf false)" == "true" ]]; then
        jq -cn --argjson result "${result}" --argjson components "${component_result}" \
            --argjson purge "${purge}" '
            $result
            + {
                purged:$purge,
                purged_paths:($components.purged_paths // $components.result.purged_paths // []),
                cleanup_pending:(
                    ($result.cleanup_pending // [])
                    + ($components.cleanup_pending // $components.result.cleanup_pending // [])
                )
            }
            + {components:$components}'
    else
        printf '%s\n' "${result}"
    fi
}

linux_agent_credential_admin() {
    local admin_name="$1" action="$2"
    shift 2 || true
    local registry match package component egress_dropin admin entrypoint command_contract
    local environment_name environment_value resolved_value credential_group
    local expected_operands activate_systemd result exit_status
    local -a command=(env "PYTHONPATH=${LINUX_AGENT_ROOT}/lib")
    [[ "${admin_name}" =~ ^[a-z0-9][a-z0-9-]*$ &&
        "${action}" =~ ^[a-z0-9][a-z0-9-]*$ ]] || {
        jq -cn '{ok:false,status:"invalid_action",code:"invalid_action",error:"Credential component or action is invalid"}'
        return 0
    }
    if ! linux_agent_runtime_lock_exclusive_nonblocking; then
        jq -cn '{ok:false,status:"runtime_busy",code:"runtime_busy",error:"Runtime is executing or being changed"}'
        return 0
    fi
    registry="$(python3 "${LINUX_AGENT_ROOT}/lib/skill_package.py" validate-root \
        "$(linux_agent_builtin_skills_dir)" 2>/dev/null || true)"
    match="$(jq -c --arg name "${admin_name}" '[
        .skills[]?
        | select(.state == "installed" and .components.credential_helper.admin.name == $name)
        | {
            package:.name,
            component:.components.credential_helper.name,
            egress_dropin:(.components.credential_helper.egress_dropin // ""),
            admin:.components.credential_helper.admin
        }
    ]' <<<"${registry}" 2>/dev/null || printf '[]')"
    if [[ "$(jq -r 'length' <<<"${match}")" -ne 1 ]]; then
        linux_agent_runtime_lock_release
        jq -cn --arg name "${admin_name}" \
            '{ok:false,status:"not_found",code:"not_found",component:$name,error:"Credential component is unavailable or ambiguous"}'
        return 0
    fi
    package="$(jq -r '.[0].package' <<<"${match}")"
    component="$(jq -r '.[0].component' <<<"${match}")"
    egress_dropin="$(jq -r '.[0].egress_dropin' <<<"${match}")"
    admin="$(jq -c '.[0].admin' <<<"${match}")"
    command_contract="$(jq -c --arg action "${action}" '[.commands[] | select(.name == $action)]' \
        <<<"${admin}")"
    if [[ "$(jq -r 'length' <<<"${command_contract}")" -ne 1 ]]; then
        linux_agent_runtime_lock_release
        jq -cn --arg action "${action}" \
            '{ok:false,status:"invalid_action",code:"invalid_action",action:$action,error:"Credential action is not declared"}'
        return 0
    fi
    expected_operands="$(jq -r '.[0].operands' <<<"${command_contract}")"
    if [[ "$#" -ne "${expected_operands}" ]]; then
        linux_agent_runtime_lock_release
        jq -cn --arg action "${action}" --argjson expected "${expected_operands}" \
            '{ok:false,status:"invalid_action",code:"invalid_action",action:$action,expected_operands:$expected,error:"Credential action operand count is invalid"}'
        return 0
    fi
    entrypoint="$(jq -r '.entrypoint' <<<"${admin}")"
    credential_group="${LINUX_AGENT_CREDENTIAL_GROUP:-linux-agent-credential}"
    while IFS=$'\t' read -r environment_name environment_value; do
        [[ -n "${environment_name}" ]] || continue
        case "${environment_value}" in
            credential_group) resolved_value="${credential_group}" ;;
            component_egress_dropin)
                [[ -n "${egress_dropin}" ]] || {
                    linux_agent_runtime_lock_release
                    jq -cn '{ok:false,status:"invalid_contract",code:"invalid_contract",error:"Credential egress contract is incomplete"}'
                    return 0
                }
                resolved_value="${LINUX_AGENT_SYSTEMD_UNIT_DIR:-/etc/systemd/system}/linux-agent-${component}.service.d/${egress_dropin}"
                ;;
            *)
                linux_agent_runtime_lock_release
                jq -cn '{ok:false,status:"invalid_contract",code:"invalid_contract",error:"Credential environment contract is invalid"}'
                return 0
                ;;
        esac
        command+=("${environment_name}=${resolved_value}")
    done < <(jq -r '.environment | to_entries[] | [.key, .value] | @tsv' <<<"${admin}")
    command+=(python3 "$(linux_agent_builtin_skills_dir)/${package}/${entrypoint}" "${action}" "$@")
    activate_systemd="$(jq -r '.[0].activate_systemd' <<<"${command_contract}")"
    if [[ "${activate_systemd}" == "true" ]] && linux_agent_managed_execution_enabled; then
        command+=(--activate-systemd)
    fi
    exit_status=0
    result="$("${command[@]}")" || exit_status=$?
    linux_agent_runtime_lock_release
    printf '%s\n' "${result}"
    return "${exit_status}"
}

linux_agent_validate_skills() {
    local catalog findings ok status skills tools
    catalog="$(linux_agent_skill_catalog_json)"
    findings="$(jq -c '.findings // []' <<<"${catalog}")"
    ok="$(jq -r '.ok // true' <<<"${catalog}")"
    skills="$(jq -c '.skills // []' <<<"${catalog}")"
    tools="$(jq -c '.tools // []' <<<"${catalog}")"
    status="validated"
    if jq -e 'any(.[]?;
        .code == "SKILL_INDEX_INVALID"
        or .code == "SKILL_RESOLVER_UNAVAILABLE"
    )' <<<"${findings}" >/dev/null; then
        status="unavailable"
    fi
    jq -cn \
        --argjson ok "${ok}" \
        --arg status "${status}" \
        --arg skills_dir "$(linux_agent_skills_dir)" \
        --arg builtin_dir "$(linux_agent_builtin_skills_dir)" \
        --arg user_dir "$(linux_agent_user_skills_dir)" \
        --argjson managed "$(linux_agent_managed_mode_enabled && printf true || printf false)" \
        --argjson remote "$(linux_agent_remote_mode_enabled && printf true || printf false)" \
        --argjson skills "${skills}" \
        --argjson tools "${tools}" \
        --argjson findings "${findings}" \
        '{
            ok:$ok,
            status:$status,
            skills_dir:$skills_dir,
            builtin_skills_dir:$builtin_dir,
            user_skills_dir:$user_dir,
            managed:$managed,
            remote:$remote,
            skills:$skills,
            tools:$tools,
            findings:$findings
        }'
}
