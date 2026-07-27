#!/usr/bin/env bash

set -euo pipefail

# Skill registry boundary: callers should use this file instead of reaching into
# skills/ directly. A future manifest-backed resolver should preserve these
# registration, content and execution semantics.
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
    local skill_name="$1" builtin_dir
    [[ "${skill_name}" =~ ^[a-z0-9][a-z0-9-]*$ ]] || return 1
    builtin_dir="$(linux_agent_builtin_skills_dir)"
    if [[ -e "${builtin_dir}/${skill_name}" || -L "${builtin_dir}/${skill_name}" ]]; then
        return 0
    fi
    linux_agent_remote_mode_enabled && linux_agent_remote_skill_is_known "${skill_name}"
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
    local builtin_dir user_dir name
    builtin_dir="$(linux_agent_builtin_skills_dir)"
    user_dir="$(linux_agent_user_skills_dir)"
    {
        find "${builtin_dir}" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null || true
        if [[ "${user_dir}" != "${builtin_dir}" ]]; then
            find "${user_dir}" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null || true
        fi
    } | while IFS= read -r name; do
        [[ "${name}" =~ ^[a-z0-9][a-z0-9-]*$ ]] && printf '%s\n' "${name}"
    done | sort -u
}

linux_agent_skill_index_path_for_dir() {
    local skill_dir="$1"
    local root
    root="$(dirname -- "${skill_dir}")"
    printf '%s/INDEX.md\n' "${root}"
}

linux_agent_skill_index_path() {
    printf '%s/INDEX.md\n' "$(linux_agent_builtin_skills_dir)"
}

linux_agent_user_skill_index_path() {
    printf '%s/INDEX.md\n' "$(linux_agent_user_skills_dir)"
}

linux_agent_skill_index_text() {
    local index_path user_index
    index_path="$(linux_agent_skill_index_path)"
    [[ -f "${index_path}" ]] && cat "${index_path}"
    user_index="$(linux_agent_user_skill_index_path)"
    if [[ "${user_index}" != "${index_path}" && -f "${user_index}" ]]; then
        cat "${user_index}"
    fi
}

linux_agent_skill_disclosure_candidates() {
    local request="${1:-}"
    local mode="${2:-work}"
    local lowered skill_name
    lowered="${request,,}"

    case "${mode}" in
        work | work_revision | work_reflect | edit | edit_revision) ;;
        *) return 0 ;;
    esac

    if [[ "${lowered}" =~ (磁盘|日志|cpu|内存|进程|服务|disk|log|resource|memory|process|service) ]]; then
        printf 'ops-basic\n'
    fi
    if [[ "${lowered}" =~ (端口|连接|句柄|journal|系统快照|network|socket|port|connection|fd|snapshot) ]]; then
        printf 'os-deep-inspect\n'
    fi
    if [[ "${lowered}" =~ (文件|补丁|下载|字面量|file|patch|download|replace) ]]; then
        printf 'controlled-tools\n'
    fi
    if [[ "${lowered}" =~ (上一轮|历史会话|审计会话|session.history|last.command|previous.turn) ]]; then
        printf 'session-history\n'
    fi
    if [[ "${lowered}" =~ (网络|网卡|路由|dns|端口扫描|防火墙|子网|network|route|firewall|subnet|traceroute|whois|snmp) ]]; then
        printf 'network-ops-tools\n'
    fi

    while IFS= read -r skill_name; do
        [[ -n "${skill_name}" ]] || continue
        if [[ "${lowered}" == *"${skill_name}"* ]]; then
            printf '%s\n' "${skill_name}"
        fi
    done < <(linux_agent_skill_index_text 2>/dev/null | sed -n 's/^##[[:space:]]\+//p' | sort -u)
}

linux_agent_skill_context_json() {
    local request="${1:-}"
    local mode="${2:-work}"
    local disclosed='[]' unavailable='[]' candidates skill_name skill_md instructions relative_path total_count

    case "${mode}" in
        work | work_revision | work_reflect | edit | edit_revision) ;;
        *)
            jq -cn '{enabled:false, disclosure:"not_available_in_mode", disclosed:[], unavailable:[]}'
            return 0
            ;;
    esac

    candidates="$(linux_agent_skill_disclosure_candidates "${request}" "${mode}" | awk 'NF && !seen[$0]++')"
    while IFS= read -r skill_name; do
        [[ -n "${skill_name}" ]] || continue
        skill_md="$(linux_agent_skill_package_dir "${skill_name}" 2>/dev/null || true)/SKILL.md"
        if [[ ! -r "${skill_md}" ]]; then
            unavailable="$(jq -cn --argjson prior "${unavailable}" --arg name "${skill_name}" '$prior + [$name]')"
            continue
        fi
        instructions="$(linux_agent_sanitize_text "$(cat "${skill_md}")" 20000)"
        relative_path="skills/${skill_name}/SKILL.md"
        disclosed="$(jq -cn \
            --argjson prior "${disclosed}" \
            --arg name "${skill_name}" \
            --arg relative_path "${relative_path}" \
            --arg instructions "${instructions}" \
            '$prior + [{name:$name, relative_path:$relative_path, materialization:"local_ready", instructions:$instructions}]')"
    done <<<"${candidates}"

    total_count="$(linux_agent_skill_package_names | wc -l | tr -d ' ')"
    [[ "${total_count}" =~ ^[0-9]+$ ]] || total_count=0
    jq -cn \
        --argjson disclosed "${disclosed}" \
        --argjson unavailable "${unavailable}" \
        --argjson total_count "${total_count}" \
        '{
            enabled:true,
            disclosure:"triggered_instructions",
            discovery_source:"skills/INDEX.md",
            total_skill_count:$total_count,
            disclosed_count:($disclosed | length),
            disclosed:$disclosed,
            unavailable:$unavailable
        }'
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
    local skills_dir target_skill lock_root lock_dir lock_acquired asset_name expected_sha expected_size max_size
    local release_base archive_path download_ok actual_size actual_sha stage_root staged_skill validation files marker_tmp
    local manifest_refs index_refs actual_refs observer_gate observer_subject audit_rc audit_payload rollback_ok
    local audit_failure mutation_state user_dir

    if ! linux_agent_remote_mode_enabled; then
        linux_agent_remote_skill_result false skill_package_invalid "${skill_name}" "当前不是 remote runtime。"
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
            linux_agent_materialize_skill "${skill_name}"
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
    index_refs="$(linux_agent_index_declared_refs_at "$(linux_agent_skill_index_path)" |
        sed 's/\.sh$//' |
        awk -v prefix="${skill_name}/" 'index($0, prefix) == 1' |
        jq -R -s -c 'split("\n") | map(select(length > 0)) | sort | unique')"
    actual_refs="$(find "${staged_skill}/scripts" -maxdepth 1 -type f -name '*.sh' -printf '%f\n' 2>/dev/null |
        sed 's/\.sh$//' |
        awk -v prefix="${skill_name}/" '{print prefix $0}' |
        jq -R -s -c 'split("\n") | map(select(length > 0)) | sort | unique')"
    if [[ "${manifest_refs}" != "${index_refs}" ]] || [[ "${manifest_refs}" != "${actual_refs}" ]]; then
        rm -rf "${stage_root}" "${archive_path}"
        rmdir "${lock_dir}" 2>/dev/null || true
        linux_agent_remote_skill_result false skill_package_invalid "${skill_name}" "Skill 包、INDEX 与远程登记引用不一致。"
        return 0
    fi
    validation="$(linux_agent_validate_skill_at "${skill_name}" "${staged_skill}" "$(linux_agent_skill_index_path)")"
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
    # Re-read the server-side gate immediately before the materializing rename;
    # a package may have been reviewed while an administrator disabled Web
    # sensitive edits in the meantime.
    if ! linux_agent_web_sensitive_edits_enabled; then
        rm -rf "${stage_root}" "${archive_path}"
        rmdir "${lock_dir}" 2>/dev/null || true
        linux_agent_sensitive_edits_disabled_result
        return 0
    fi
    if ! mv -nT -- "${staged_skill}" "${target_skill}" ||
        [[ -e "${staged_skill}" || -L "${staged_skill}" ]]; then
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
                linux_agent_audit_failure_result "${audit_rc}" "skill_materialized"
                return 0
            fi
            if [[ -d "${target_skill}" && ! -L "${target_skill}" ]]; then
                mutation_state="committed"
            else
                mutation_state="rollback_unconfirmed"
            fi
            audit_failure="$(linux_agent_audit_failure_result "${audit_rc}" "skill_materialized")"
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
    local skill_name script_name package_dir
    skill_name="$(linux_agent_skill_name_from_ref "${ref}")"
    script_name="$(linux_agent_skill_script_name_from_ref "${ref}")"
    package_dir="$(linux_agent_skill_package_dir "${skill_name}")" || return $?
    printf '%s/scripts/%s\n' "${package_dir}" "${script_name}"
}

linux_agent_skill_manifest_path() {
    local skill_name="$1"
    local package_dir
    package_dir="$(linux_agent_skill_package_dir "${skill_name}")" || return $?
    printf '%s/SKILL.md\n' "${package_dir}"
}

linux_agent_skill_metadata_path() {
    local skill_name="$1"
    local package_dir
    package_dir="$(linux_agent_skill_package_dir "${skill_name}")" || return $?
    printf '%s/manifest.json\n' "${package_dir}"
}

linux_agent_skill_is_registered() {
    local ref="$1"
    local skill_name script_name skill_md index_path script_path package_dir metadata_path origin
    linux_agent_skill_ref_is_valid "${ref}" || return 1
    skill_name="$(linux_agent_skill_name_from_ref "${ref}")"
    if linux_agent_remote_builtin_pending "${skill_name}"; then
        linux_agent_remote_ref_is_registered "${ref}"
        return $?
    fi
    script_name="$(linux_agent_skill_script_name_from_ref "${ref}")"
    package_dir="$(linux_agent_skill_package_dir "${skill_name}")" || return 1
    skill_md="${package_dir}/SKILL.md"
    metadata_path="${package_dir}/manifest.json"
    index_path="$(linux_agent_skill_index_path_for_dir "${package_dir}")"
    script_path="${package_dir}/scripts/${script_name}"

    [[ -f "${skill_md}" && ! -L "${skill_md}" && -f "${metadata_path}" && ! -L "${metadata_path}" &&
        -f "${index_path}" && ! -L "${index_path}" && -f "${script_path}" && ! -L "${script_path}" ]] || return 1
    grep -Eq "(^|[^a-z0-9-])${skill_name}/${script_name%.sh}(\.sh)?([^a-z0-9-]|$)" "${index_path}" || return 1
    origin="$(linux_agent_skill_package_origin "${skill_name}")" || return 1
    linux_agent_skill_manifest_contract_valid "${metadata_path}" "${skill_name}" "${script_name}" "${origin}" || return 1
}

linux_agent_skill_is_registered_at() {
    local ref="$1"
    local skill_md="$2"
    local index_path="$3"
    local skill_name script_name script_path metadata_path origin package_dir
    linux_agent_skill_ref_is_valid "${ref}" || return 1
    skill_name="$(linux_agent_skill_name_from_ref "${ref}")"
    script_name="$(linux_agent_skill_script_name_from_ref "${ref}")"
    script_path="$(dirname "${skill_md}")/scripts/${script_name}"
    metadata_path="$(dirname "${skill_md}")/manifest.json"

    [[ -f "${skill_md}" && -f "${metadata_path}" && -f "${index_path}" && -f "${script_path}" ]] || return 1
    grep -Eq "(^|[^a-z0-9-])${skill_name}/${script_name%.sh}(\.sh)?([^a-z0-9-]|$)" "${index_path}" || return 1
    package_dir="$(dirname "${metadata_path}")"
    origin="builtin"
    if [[ "${package_dir}" == "$(linux_agent_user_skills_dir)"/* ]]; then
        origin="user"
    fi
    linux_agent_skill_manifest_contract_valid "${metadata_path}" "${skill_name}" "${script_name}" "${origin}" || return 1
}

linux_agent_skill_manifest_contract_valid() {
    local metadata_path="$1" skill_name="$2" script_name="$3" origin="${4:-builtin}"
    local package_dir actual_names declared_names
    [[ -f "${metadata_path}" && ! -L "${metadata_path}" ]] || return 1
    package_dir="$(dirname "${metadata_path}")"
    [[ -d "${package_dir}/scripts" && ! -L "${package_dir}/scripts" ]] || return 1
    declared_names="$(jq -c '[.scripts[].name] | sort' "${metadata_path}" 2>/dev/null || true)"
    actual_names="$(find "${package_dir}/scripts" -maxdepth 1 -type f -name '*.sh' -printf '%f\n' 2>/dev/null | sort | jq -c -R -s 'split("\n") | map(select(length > 0))')"
    [[ -n "${declared_names}" && "${declared_names}" == "${actual_names}" ]] || return 1
    jq -e \
        --arg skill "${skill_name}" \
        --arg script "${script_name}" \
        --arg origin "${origin}" '
        type == "object" and .schema_version == 1 and .name == $skill
        and (.description | type == "string" and length > 0)
        and (.scripts | type == "array" and length > 0)
        and all(.scripts[]; . as $entry
            | ($entry.name | type == "string" and test("^[a-z0-9][a-z0-9-]*\\.sh$"))
            and ($entry.risk | type == "string" and (["low","medium","high","critical"] | index(.)) != null)
            and ($entry.execution_class | type == "string" and (["runner","host_helper"] | index(.)) != null)
            and ($entry.capability | type == "string")
            and (($entry.execution_class == "runner" and $entry.capability == "") or
                 ($entry.execution_class == "host_helper" and (["firewall.apply","hosts.apply"] | index($entry.capability)) != null))
        )
        and ([.scripts[] | select(.name == $script)] | length == 1)
        and (if $origin == "user" then all(.scripts[]; .execution_class == "runner" and .capability == "")
             elif $skill == "network-ops-tools" then
                all(.scripts[];
                    if .name == "firewall.sh" then .execution_class == "host_helper" and .capability == "firewall.apply"
                    elif .name == "hosts-file-editor.sh" then .execution_class == "host_helper" and .capability == "hosts.apply"
                    else .execution_class == "runner" and .capability == ""
                    end)
             else all(.scripts[]; .execution_class == "runner" and .capability == "")
             end)
    ' "${metadata_path}" >/dev/null 2>&1
}

linux_agent_skill_manifest_declared_script_names_at() {
    local skill_md="$1"
    [[ -f "${skill_md}" ]] || return 0

    grep -oE '`scripts/[a-z0-9][a-z0-9-]*\.sh`' "${skill_md}" 2>/dev/null |
        tr -d '`' |
        sed 's#^scripts/##' |
        sort -u
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
    risk="$(jq -r --arg script "${script_name}" '[.scripts[]? | select(.name == $script) | .risk][0] // empty' "${metadata_path}" 2>/dev/null || true)"
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

linux_agent_skill_manifest_field() {
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
    jq -r --arg script "${script_name}" --arg field "${field}" --arg fallback "${fallback}" \
        '[.scripts[]? | select(.name == $script) | .[$field]][0] // $fallback' \
        "${metadata_path}" 2>/dev/null || printf '%s\n' "${fallback}"
}

linux_agent_skill_execution_class() {
    linux_agent_skill_manifest_field "$1" execution_class invalid
}

linux_agent_skill_capability() {
    linux_agent_skill_manifest_field "$1" capability invalid
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
    local declared_risk severity action
    declared_risk="$(linux_agent_skill_declared_risk "${ref}")"
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

linux_agent_index_declared_refs_at() {
    local index_path="$1"
    [[ -f "${index_path}" ]] || return 0

    grep -oE '`[a-z0-9][a-z0-9-]*/[a-z0-9][a-z0-9-]*(\.sh)?`' "${index_path}" 2>/dev/null |
        tr -d '`' |
        sort -u
}

linux_agent_skill_script_content() {
    local ref="$1"
    local script_path
    linux_agent_ensure_skill_materialized "${ref}" || return 1
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

    linux_agent_ensure_skill_materialized "${ref}" || {
        jq -cn --arg ref "${ref}" '{ok:false, error:"skill package could not be materialized", ref:$ref}'
        return 1
    }
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
    local origin="${4:-builtin}"
    local ok findings skill_md metadata_path manifest_validity
    ok="true"
    findings='[]'
    skill_md="${skill_dir}/SKILL.md"
    metadata_path="${skill_dir}/manifest.json"

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
    if [[ ! -f "${metadata_path}" || -L "${metadata_path}" ]]; then
        ok="false"
        findings="$(jq -cn --argjson prior "${findings}" --arg skill "${skill_name}" '$prior + [{severity:"critical", code:"SKILL_METADATA_MISSING", skill:$skill, message:"Skill 必须提供 manifest.json。"}]')"
    else
        manifest_validity="$(
            jq -e --arg skill "${skill_name}" '
            type == "object" and .schema_version == 1 and .name == $skill
            and (.description | type == "string" and length > 0)
            and (.scripts | type == "array" and length > 0)
            and all(.scripts[]; . as $script
                | ($script.name | type == "string" and test("^[a-z0-9][a-z0-9-]*\\.sh$"))
                and ($script.risk | type == "string")
                and (["low","medium","high","critical"] | index($script.risk)) != null
                and ($script.execution_class | type == "string")
                and (["runner","host_helper"] | index($script.execution_class)) != null
                and ($script.capability | type == "string")
                and (($script.execution_class == "runner" and $script.capability == "") or
                     ($script.execution_class == "host_helper" and (["firewall.apply","hosts.apply"] | index($script.capability)) != null))
            )
        ' "${metadata_path}" >/dev/null 2>&1
            printf '%s' "$?"
        )"
        if [[ "${manifest_validity}" != "0" ]]; then
            ok="false"
            findings="$(jq -cn --argjson prior "${findings}" --arg skill "${skill_name}" '$prior + [{severity:"critical", code:"SKILL_METADATA_INVALID", skill:$skill, message:"manifest.json 字段或执行类非法。"}]')"
        else
            local declared_names actual_names
            declared_names="$(jq -c '[.scripts[].name] | sort' "${metadata_path}")"
            actual_names="$(find "${skill_dir}/scripts" -maxdepth 1 -type f -name '*.sh' -printf '%f\n' 2>/dev/null | sort | jq -c -R -s 'split("\n") | map(select(length > 0))')"
            if [[ "${declared_names}" != "${actual_names}" ]]; then
                ok="false"
                findings="$(jq -cn --argjson prior "${findings}" --arg skill "${skill_name}" '$prior + [{severity:"critical", code:"SKILL_METADATA_SCRIPT_MISMATCH", skill:$skill, message:"manifest.json 与 scripts/ 文件集合不一致。"}]')"
            fi
            if [[ "${origin}" == "user" ]] && jq -e 'any(.scripts[]; .execution_class != "runner" or .capability != "")' "${metadata_path}" >/dev/null 2>&1; then
                ok="false"
                findings="$(jq -cn --argjson prior "${findings}" --arg skill "${skill_name}" '$prior + [{severity:"critical", code:"USER_SKILL_PRIVILEGED_CLASS", skill:$skill, message:"用户 Skill 只能使用 runner 且 capability 为空。"}]')"
            fi
            if [[ "${origin}" == "builtin" ]]; then
                if jq -e --arg skill "${skill_name}" '
                    any(.scripts[];
                        if $skill == "network-ops-tools" and .name == "firewall.sh" then
                            .execution_class != "host_helper" or .capability != "firewall.apply"
                        elif $skill == "network-ops-tools" and .name == "hosts-file-editor.sh" then
                            .execution_class != "host_helper" or .capability != "hosts.apply"
                        else
                            .execution_class == "host_helper" or .capability != ""
                        end
                    )
                ' "${metadata_path}" >/dev/null 2>&1; then
                    ok="false"
                    findings="$(jq -cn --argjson prior "${findings}" --arg skill "${skill_name}" '$prior + [{severity:"critical", code:"BUILTIN_HELPER_CLASS_INVALID", skill:$skill, message:"特权内置 Skill 的 helper capability 不符合固定登记。"}]')"
                fi
            fi
        fi
    fi
    if [[ ! -f "${skill_md}" ]] || ! grep -Eq '^## .*(传参|参数契约|参数规范|[Aa]rguments|[Pp]arameters)' "${skill_md}"; then
        ok="false"
        findings="$(jq -cn --argjson prior "${findings}" --arg skill "${skill_name}" '$prior + [{severity:"critical", code:"SKILL_ARGUMENT_CONTRACT_MISSING", skill:$skill, message:"SKILL.md 缺少参数类型、必填性、默认值和约束说明。"}]')"
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
    local skills_dir index_path ok findings builtin_dir user_dir skill_name skill_dir skill_result origin
    ok="true"
    findings='[]'

    skills_dir="$(linux_agent_skills_dir)"
    builtin_dir="$(linux_agent_builtin_skills_dir)"
    user_dir="$(linux_agent_user_skills_dir)"
    index_path="$(linux_agent_skill_index_path)"

    if [[ ! -f "${index_path}" ]]; then
        ok="false"
        findings="$(jq -cn --argjson prior "${findings}" '$prior + [{severity:"critical", code:"SKILL_INDEX_MISSING", message:"skills/INDEX.md 不存在。"}]')"
    fi

    if linux_agent_remote_mode_enabled; then
        if ! jq -e '.schema_version == 1 and (.skills | type == "object")' "${LINUX_AGENT_REMOTE_MANIFEST}" >/dev/null 2>&1; then
            ok="false"
            findings="$(jq -cn --argjson prior "${findings}" '$prior + [{severity:"critical", code:"REMOTE_SKILL_MANIFEST_INVALID", message:"远程 Skill manifest 非法。"}]')"
        fi
        while IFS= read -r ref; do
            [[ -n "${ref}" ]] || continue
            if ! linux_agent_remote_ref_is_registered "${ref}"; then
                ok="false"
                findings="$(jq -cn --argjson prior "${findings}" --arg ref "${ref%.sh}" '$prior + [{severity:"critical", code:"REMOTE_SKILL_INDEX_MISMATCH", ref:$ref, message:"INDEX.md 与远程 Skill manifest 不一致。"}]')"
            fi
        done < <(linux_agent_index_declared_refs_at "${index_path}")
    fi

    while IFS= read -r skill_name; do
        [[ -z "${skill_name}" ]] && continue
        skill_dir="$(linux_agent_skill_package_dir "${skill_name}" 2>/dev/null || true)"
        [[ -n "${skill_dir}" ]] || {
            ok="false"
            findings="$(jq -cn --argjson prior "${findings}" --arg skill "${skill_name}" '$prior + [{severity:"critical", code:"SKILL_PACKAGE_CONFLICT", skill:$skill, message:"用户 Skill 不能覆盖同名内置 Skill 或使用非法目录。"}]')"
            continue
        }
        origin="$(linux_agent_skill_package_origin "${skill_name}" 2>/dev/null || printf 'unknown')"
        index_path="$(linux_agent_skill_index_path_for_dir "${skill_dir}")"
        skill_result="$(linux_agent_validate_skill_at "${skill_name}" "${skill_dir}" "${index_path}" "${origin}")"
        if [[ "$(jq -r '.ok // false' <<<"${skill_result}")" != "true" ]]; then
            ok="false"
            findings="$(jq -cn --argjson prior "${findings}" --argjson next "$(jq '.findings' <<<"${skill_result}")" '$prior + $next')"
        fi
    done < <(linux_agent_skill_package_names)

    if linux_agent_remote_mode_enabled; then
        index_path="$(linux_agent_user_skill_index_path)"
        if [[ -f "${index_path}" && ! -L "${index_path}" ]]; then
            while IFS= read -r ref; do
                [[ -n "${ref}" ]] || continue
                skill_name="${ref%%/*}"
                if [[ "$(linux_agent_skill_package_origin "${skill_name}" 2>/dev/null || true)" != "user" ]] ||
                    ! linux_agent_skill_is_registered "${ref}"; then
                    ok="false"
                    findings="$(jq -cn \
                        --argjson prior "${findings}" \
                        --arg ref "${ref%.sh}" \
                        '$prior + [{severity:"critical", code:"SKILL_INDEX_BROKEN_REF", ref:$ref, message:"用户 Skill INDEX.md 引用了缺失、冲突或非用户脚本。"}]')"
                fi
            done < <(linux_agent_index_declared_refs_at "${index_path}")
        fi
        jq -cn --argjson ok "${ok}" --arg skills_dir "${skills_dir}" --argjson remote true --argjson findings "${findings}" \
            '{ok:$ok, skills_dir:$skills_dir, remote:$remote, findings:$findings}'
        return 0
    fi

    while IFS= read -r index_path; do
        [[ -f "${index_path}" ]] || continue
        while IFS= read -r ref; do
            [[ -n "${ref}" ]] || continue
            if ! linux_agent_skill_is_registered "${ref}"; then
                ok="false"
                findings="$(jq -cn \
                    --argjson prior "${findings}" \
                    --arg ref "${ref%.sh}" \
                    '$prior + [{severity:"critical", code:"SKILL_INDEX_BROKEN_REF", ref:$ref, message:"INDEX.md 中声明的脚本缺少对应文件或 manifest 登记。"}]')"
            fi
        done < <(linux_agent_index_declared_refs_at "${index_path}")
    done < <(printf '%s\n%s\n' "$(linux_agent_skill_index_path)" "$(linux_agent_user_skill_index_path)" | sort -u)

    jq -cn --argjson ok "${ok}" --arg skills_dir "${skills_dir}" \
        --arg builtin_dir "${builtin_dir}" --arg user_dir "${user_dir}" \
        --argjson managed "$(linux_agent_managed_mode_enabled && printf true || printf false)" \
        --argjson findings "${findings}" \
        '{ok:$ok, skills_dir:$skills_dir, builtin_skills_dir:$builtin_dir, user_skills_dir:$user_dir, managed:$managed, findings:$findings}'
}
