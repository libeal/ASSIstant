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

linux_agent_skill_disclosure_candidates() {
    local request="${1:-}"
    local mode="${2:-work}"
    local lowered skill_name
    lowered="${request,,}"

    case "${mode}" in
        work|work_revision|work_reflect|edit|edit_revision) ;;
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
    done < <(sed -n 's/^##[[:space:]]\+//p' "$(linux_agent_skill_index_path)" 2>/dev/null | sort -u)
}

linux_agent_skill_context_json() {
    local request="${1:-}"
    local mode="${2:-work}"
    local disclosed='[]' unavailable='[]' candidates skill_name skill_md instructions relative_path total_count

    case "${mode}" in
        work|work_revision|work_reflect|edit|edit_revision) ;;
        *)
            jq -cn '{enabled:false, disclosure:"not_available_in_mode", disclosed:[], unavailable:[]}'
            return 0
            ;;
    esac

    candidates="$(linux_agent_skill_disclosure_candidates "${request}" "${mode}" | awk 'NF && !seen[$0]++')"
    while IFS= read -r skill_name; do
        [[ -n "${skill_name}" ]] || continue
        skill_md="$(linux_agent_skills_dir)/${skill_name}/SKILL.md"
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

    total_count="$(find "$(linux_agent_skills_dir)" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
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
    [[ "${LINUX_AGENT_REMOTE_MODE:-0}" == "1" \
        && -n "${LINUX_AGENT_REMOTE_MANIFEST:-}" \
        && -f "${LINUX_AGENT_REMOTE_MANIFEST}" ]]
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

linux_agent_remote_skill_ready() {
    local skill_name="$1"
    local marker="$(linux_agent_skills_dir)/${skill_name}/.remote-verified.json"
    [[ -f "${marker}" ]] || return 1
    local expected_sha expected_version
    expected_sha="$(jq -r --arg skill "${skill_name}" '.skills[$skill].asset.sha256 // empty' "${LINUX_AGENT_REMOTE_MANIFEST}")"
    expected_version="$(jq -r '.version // empty' "${LINUX_AGENT_REMOTE_MANIFEST}")"
    jq -e --arg skill "${skill_name}" --arg sha256 "${expected_sha}" --arg version "${expected_version}" \
        '.skill == $skill and .sha256 == $sha256 and .release_version == $version' \
        "${marker}" >/dev/null 2>&1
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
    local skills_dir lock_root lock_dir attempt lock_acquired asset_name expected_sha expected_size max_size
    local release_base archive_path download_ok actual_size actual_sha stage_root staged_skill validation files marker_tmp
    local manifest_refs index_refs actual_refs

    if ! linux_agent_remote_mode_enabled; then
        linux_agent_remote_skill_result false skill_package_invalid "${skill_name}" "当前不是 remote runtime。"
        return 0
    fi
    if [[ ! "${skill_name}" =~ ^[a-z0-9][a-z0-9-]*$ ]] || ! linux_agent_remote_skill_is_known "${skill_name}"; then
        linux_agent_remote_skill_result false skill_package_invalid "${skill_name}" "Skill 不在远程登记表中。"
        return 0
    fi
    if linux_agent_remote_skill_ready "${skill_name}"; then
        files="$(find "$(linux_agent_skills_dir)/${skill_name}" -type f ! -name .remote-verified.json -printf '%P\n' | sort | jq -R -s --arg skill "${skill_name}" 'split("\n") | map(select(length > 0) | "skills/" + $skill + "/" + .)')"
        linux_agent_remote_skill_result true skill_materialized "${skill_name}" "" "${files}"
        return 0
    fi

    skills_dir="$(linux_agent_skills_dir)"
    if [[ -e "${skills_dir}/${skill_name}" || -L "${skills_dir}/${skill_name}" ]]; then
        linux_agent_remote_skill_result false skill_package_invalid "${skill_name}" "目标 Skill 目录已存在但没有有效的远程校验标记。"
        return 0
    fi
    lock_root="${LINUX_AGENT_TMP_ROOT:-${LINUX_AGENT_ROOT}/tmp}/skill-locks"
    lock_dir="${lock_root}/${skill_name}.lock"
    mkdir -p "${lock_root}"
    lock_acquired=false
    for attempt in $(seq 1 200); do
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

    if [[ ! "${asset_name}" =~ ^linux-agent-skill-[a-z0-9-]+\.tar\.gz$ \
        || ! "${expected_sha}" =~ ^[0-9a-f]{64}$ \
        || ! "${expected_size}" =~ ^[0-9]+$ \
        || ! "${max_size}" =~ ^[0-9]+$ \
        || "${expected_size}" -le 0 \
        || "${expected_size}" -gt "${max_size}" \
        || -z "${release_base}" ]]; then
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
    index_refs="$(linux_agent_index_declared_refs_at "$(linux_agent_skill_index_path)" \
        | sed 's/\.sh$//' \
        | awk -v prefix="${skill_name}/" 'index($0, prefix) == 1' \
        | jq -R -s -c 'split("\n") | map(select(length > 0)) | sort | unique')"
    actual_refs="$(find "${staged_skill}/scripts" -maxdepth 1 -type f -name '*.sh' -printf '%f\n' 2>/dev/null \
        | sed 's/\.sh$//' \
        | awk -v prefix="${skill_name}/" '{print prefix $0}' \
        | jq -R -s -c 'split("\n") | map(select(length > 0)) | sort | unique')"
    if [[ "${manifest_refs}" != "${index_refs}" || "${manifest_refs}" != "${actual_refs}" ]]; then
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

    mkdir -p "${skills_dir}"
    marker_tmp="${staged_skill}/.remote-verified.json.tmp"
    jq -cn --arg skill "${skill_name}" --arg sha256 "${actual_sha}" --arg version "$(jq -r '.version' "${LINUX_AGENT_REMOTE_MANIFEST}")" \
        '{skill:$skill, sha256:$sha256, release_version:$version}' > "${marker_tmp}"
    mv "${marker_tmp}" "${staged_skill}/.remote-verified.json"
    mv "${staged_skill}" "${skills_dir}/${skill_name}"
    files="$(find "${skills_dir}/${skill_name}" -type f ! -name .remote-verified.json -printf '%P\n' | sort | jq -R -s --arg skill "${skill_name}" 'split("\n") | map(select(length > 0) | "skills/" + $skill + "/" + .)')"
    rm -rf "${stage_root}" "${archive_path}"
    rmdir "${lock_dir}" 2>/dev/null || true
    if declare -F linux_agent_log_event >/dev/null 2>&1; then
        linux_agent_log_event "skill_materialized" "$(jq -cn --arg skill "${skill_name}" --arg sha256 "${actual_sha}" '{skill:$skill, sha256:$sha256, status:"skill_materialized"}')"
    fi
    linux_agent_remote_skill_result true skill_materialized "${skill_name}" "" "${files}"
}

linux_agent_ensure_skill_materialized() {
    local ref="$1" skill_name result
    linux_agent_remote_mode_enabled || return 0
    skill_name="$(linux_agent_skill_name_from_ref "${ref}")"
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
    if linux_agent_remote_mode_enabled && ! linux_agent_remote_skill_ready "$(linux_agent_skill_name_from_ref "${ref}")"; then
        linux_agent_remote_ref_is_registered "${ref}"
        return $?
    fi
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

linux_agent_risk_is_valid() {
    case "${1:-}" in
        low|medium|high|critical) return 0 ;;
        *) return 1 ;;
    esac
}

linux_agent_skill_declared_risk_at() {
    local ref="$1"
    local skill_md="$2"
    local script_name line risk
    script_name="$(linux_agent_skill_script_name_from_ref "${ref}")"

    [[ -f "${skill_md}" ]] || {
        printf 'low\n'
        return 0
    }

    line="$(grep -E "scripts/${script_name}(\`|[[:space:]):,-]).*risk:[[:space:]]*\`?(low|medium|high|critical)\`?" "${skill_md}" 2>/dev/null | head -n 1 || true)"
    risk="$(sed -nE 's/.*risk:[[:space:]]*`?(low|medium|high|critical)`?.*/\1/p' <<<"${line}" | head -n 1)"
    if linux_agent_risk_is_valid "${risk}"; then
        printf '%s\n' "${risk}"
    else
        printf 'low\n'
    fi
}

linux_agent_skill_declared_risk() {
    local ref="$1"
    local skill_name skill_md
    if ! linux_agent_skill_ref_is_valid "${ref}"; then
        printf 'low\n'
        return 0
    fi
    if linux_agent_remote_mode_enabled && ! linux_agent_remote_skill_ready "$(linux_agent_skill_name_from_ref "${ref}")"; then
        jq -r --arg ref "${ref%.sh}" '[.skills[].refs[]? | select(.ref == $ref) | .risk][0] // "low"' "${LINUX_AGENT_REMOTE_MANIFEST}"
        return 0
    fi
    skill_name="$(linux_agent_skill_name_from_ref "${ref}")"
    skill_md="$(linux_agent_skill_manifest_path "${skill_name}")"
    linux_agent_skill_declared_risk_at "${ref}" "${skill_md}"
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

    grep -oE '`[a-z0-9][a-z0-9-]*/[a-z0-9][a-z0-9-]*(\.sh)?`' "${index_path}" 2>/dev/null \
        | tr -d '`' \
        | sort -u
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
    local skills_dir index_path ok findings
    skills_dir="$(linux_agent_skills_dir)"
    index_path="$(linux_agent_skill_index_path)"
    ok="true"
    findings='[]'

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

    if linux_agent_remote_mode_enabled; then
        jq -cn --argjson ok "${ok}" --arg skills_dir "${skills_dir}" --argjson remote true --argjson findings "${findings}" \
            '{ok:$ok, skills_dir:$skills_dir, remote:$remote, findings:$findings}'
        return 0
    fi

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
