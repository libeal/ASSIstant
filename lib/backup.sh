#!/usr/bin/env bash

set -euo pipefail

linux_agent_backup_runtime() {
    local output_path="$1"
    local output_dir output_name resolved_output_dir resolved_root stage_root archive_tmp
    local config_json size_bytes sha256 skill_dir skill_name log_file session_id line marker installation_state unsafe_path
    local snapshot_path segment sanitized_tmp
    local user_skills_dir builtin_skills_dir policy_default policy_name effective_policy archive_tool validation
    local audit_rc audit_payload
    local -a archive_entries=()

    if [[ -z "${output_path}" ]]; then
        jq -cn '{ok:false, status:"invalid_backup_path", error:"backup output path is required"}'
        return 1
    fi
    output_dir="$(dirname "${output_path}")"
    output_name="$(basename "${output_path}")"
    [[ -d "${output_dir}" && -w "${output_dir}" && ! -L "${output_dir}" ]] || {
        jq -cn '{ok:false, status:"invalid_backup_path", error:"backup output directory is not writable"}'
        return 1
    }
    [[ ! -e "${output_path}" && ! -L "${output_path}" ]] || {
        jq -cn '{ok:false, status:"backup_exists", error:"backup output already exists"}'
        return 1
    }
    [[ "${output_name}" == *.tar.gz ]] || {
        jq -cn '{ok:false, status:"invalid_backup_path", error:"backup output must end with .tar.gz"}'
        return 1
    }

    resolved_output_dir="$(readlink -f "${output_dir}")"
    resolved_root="$(readlink -f "${LINUX_AGENT_ROOT}")"
    if [[ "${resolved_output_dir}" == "${resolved_root}" || "${resolved_output_dir}" == "${resolved_root}/"* ]]; then
        jq -cn '{ok:false, status:"invalid_backup_path", error:"backup output must be outside the ephemeral runtime root"}'
        return 1
    fi

    audit_payload="$(jq -cn --arg name "${output_name}" '{name:$name}')"
    audit_rc=0
    linux_agent_audit_require_event "runtime_backup_started" "${audit_payload}" || audit_rc=$?
    if ((audit_rc != 0)); then
        linux_agent_audit_failure_result "${audit_rc}" "runtime_backup_started"
        return 1
    fi

    stage_root="$(mktemp -d "${LINUX_AGENT_TMP_DIR}/runtime-backup-stage.XXXXXX")"
    archive_tmp="$(mktemp "${output_dir}/.${output_name}.XXXXXX.tmp")"
    mkdir -p "${stage_root}/logs" "${stage_root}/reports" "${stage_root}/config" \
        "${stage_root}/skills" "${stage_root}/policies"

    while IFS= read -r log_file; do
        [[ -n "${log_file}" ]] || continue
        session_id="$(basename "${log_file}" .jsonl)"
        if ! snapshot_path="$(linux_agent_audit_snapshot "${session_id}" "${stage_root}/logs")"; then
            rm -rf "${stage_root}"
            rm -f "${archive_tmp}"
            jq -cn --arg session_id "${session_id}" \
                '{ok:false, status:"backup_failed", error:("could not snapshot audit session: " + $session_id)}'
            return 1
        fi
        while IFS= read -r segment; do
            [[ -n "${segment}" ]] || continue
            sanitized_tmp="${segment}.redacted.$$"
            while IFS= read -r line || [[ -n "${line}" ]]; do
                linux_agent_sanitize_json "${line}" 200000
            done <"${segment}" >"${sanitized_tmp}"
            chmod 0600 "${sanitized_tmp}"
            mv "${sanitized_tmp}" "${segment}"
        done < <(linux_agent_audit_segment_paths "${snapshot_path}")
        if ! python3 "$(linux_agent_audit_chain_writer)" rechain "${snapshot_path}" \
            >"${stage_root}/reports/${session_id}.rechain.json"; then
            rm -rf "${stage_root}"
            rm -f "${archive_tmp}"
            jq -cn --arg session_id "${session_id}" \
                '{ok:false, status:"backup_failed", error:("could not rechain redacted audit session: " + $session_id)}'
            return 1
        fi
        if ! linux_agent_audit_verify_chain "${session_id}" "${snapshot_path}" \
            >"${stage_root}/reports/${session_id}.verify.json"; then
            rm -rf "${stage_root}"
            rm -f "${archive_tmp}"
            jq -cn --arg session_id "${session_id}" \
                '{ok:false, status:"backup_failed", error:("redacted audit session failed integrity verification: " + $session_id)}'
            return 1
        fi
        rm -f -- "${snapshot_path}.lock"
        LINUX_AGENT_LOG_DIR="${stage_root}/logs" linux_agent_show_audit "${session_id}" \
            >"${stage_root}/reports/${session_id}.txt" 2>/dev/null ||
            rm -f "${stage_root}/reports/${session_id}.txt"
    done < <(find "${LINUX_AGENT_LOG_DIR}" -maxdepth 1 -type f -name '*.jsonl' | sort)

    config_json="$(cat "${LINUX_AGENT_CONFIG_FILE}")"
    linux_agent_redact_json_full "${config_json}" | jq . >"${stage_root}/config/config.redacted.json"

    installation_state='[]'
    user_skills_dir="$(linux_agent_user_skills_dir)"
    if [[ (-e "${user_skills_dir}" || -L "${user_skills_dir}") &&
        (! -d "${user_skills_dir}" || -L "${user_skills_dir}") ]]; then
        rm -rf "${stage_root}"
        rm -f "${archive_tmp}"
        jq -cn '{ok:false, status:"backup_failed", error:"user Skill overlay has an unsafe type"}'
        return 1
    fi
    if [[ -d "${user_skills_dir}" ]]; then
        while IFS= read -r skill_dir; do
            [[ -n "${skill_dir}" ]] || continue
            skill_name="$(basename "${skill_dir}")"
            marker="${skill_dir}/.remote-verified.json"
            if [[ -e "${marker}" || -L "${marker}" ]]; then
                rm -rf "${stage_root}"
                rm -f "${archive_tmp}"
                jq -cn --arg skill "${skill_name}" \
                    '{ok:false, status:"backup_unsafe_skill", code:"backup_unsafe_skill", error:("user Skill must not contain a remote verification marker: " + $skill)}'
                return 1
            fi
            unsafe_path="$(find "${skill_dir}" \( -type l -o -type b -o -type c -o -type p -o -type s \) -print -quit)"
            if [[ -n "${unsafe_path}" ]]; then
                rm -rf "${stage_root}"
                rm -f "${archive_tmp}"
                jq -cn --arg skill "${skill_name}" '{ok:false, status:"backup_unsafe_skill", error:("user skill contains an unsafe file type: " + $skill)}'
                return 1
            fi
            validation="$(python3 "${LINUX_AGENT_ROOT}/lib/skill_package.py" validate "${skill_dir}" --origin user 2>/dev/null || true)"
            if ! jq -e '.ok == true' <<<"${validation}" >/dev/null 2>&1; then
                rm -rf "${stage_root}"
                rm -f "${archive_tmp}"
                jq -cn --arg skill "${skill_name}" --arg error "$(jq -r '.error // "invalid package"' <<<"${validation}" 2>/dev/null || printf 'invalid package')" \
                    '{ok:false,status:"backup_unsafe_skill",code:"backup_unsafe_skill",error:("user Skill is invalid: " + $skill + ": " + $error)}'
                return 1
            fi
            cp -a "${skill_dir}" "${stage_root}/skills/${skill_name}"
        done < <(find "${user_skills_dir}" -mindepth 1 -maxdepth 1 -type d ! -name .locks | sort)
    fi
    builtin_skills_dir="${LINUX_AGENT_BUILTIN_SKILLS_DIR}"
    if linux_agent_remote_mode && [[ -d "${builtin_skills_dir}" && ! -L "${builtin_skills_dir}" ]]; then
        while IFS= read -r skill_dir; do
            [[ -n "${skill_dir}" ]] || continue
            skill_name="$(basename "${skill_dir}")"
            marker="${skill_dir}/.remote-verified.json"
            [[ -e "${marker}" || -L "${marker}" ]] || continue
            if ! linux_agent_remote_skill_marker_valid_at "${skill_name}" "${skill_dir}"; then
                rm -rf "${stage_root}"
                rm -f "${archive_tmp}"
                jq -cn --arg skill "${skill_name}" \
                    '{ok:false, status:"backup_unsafe_skill", code:"backup_unsafe_skill", error:("remote Skill marker is not trusted: " + $skill)}'
                return 1
            fi
            installation_state="$(jq -cn \
                --argjson prior "${installation_state}" \
                --arg name "${skill_name}" \
                --arg contract_digest "$(jq -r --arg skill "${skill_name}" '.skills[$skill].contract_digest // ""' "${LINUX_AGENT_REMOTE_MANIFEST}")" \
                --arg asset_sha256 "$(jq -r '.sha256' "${marker}")" \
                --arg release_version "$(jq -r '.release_version' "${marker}")" \
                '$prior + [{name:$name,installed:true,source:"remote",contract_digest:$contract_digest,asset_sha256:$asset_sha256,release_version:$release_version}]')"
        done < <(find "${builtin_skills_dir}" -mindepth 1 -maxdepth 1 -type d | sort)
    elif linux_agent_managed_mode_enabled && [[ -f "${LINUX_AGENT_DATA_DIR}/skill-components.json" ]]; then
        installation_state="$(python3 "${LINUX_AGENT_ROOT}/lib/skill_component_ledger.py" list \
            "${LINUX_AGENT_DATA_DIR}/skill-components.json" | jq -c '[
                .result.skills | to_entries[]
                | {
                    name:.key,
                    installed:.value.installed,
                    source:"managed",
                    contract_digest:.value.contract_digest
                }
            ]')" || {
            rm -rf "${stage_root}"
            rm -f "${archive_tmp}"
            jq -cn '{ok:false,status:"backup_failed",error:"managed Skill installation state is invalid"}'
            return 1
        }
    fi
    archive_tool="${LINUX_AGENT_ROOT}/lib/runtime_archive.py"
    jq -S -n --argjson builtin "${installation_state}" \
        '{schema_version:1,builtin:$builtin}' \
        >"${stage_root}/skills/installation-state.json"

    while IFS= read -r policy_default; do
        [[ -n "${policy_default}" ]] || continue
        policy_name="$(basename "${policy_default}")"
        effective_policy="$(linux_agent_policy_path "${policy_name}" 2>/dev/null || true)"
        [[ -f "${effective_policy}" && ! -L "${effective_policy}" ]] || {
            rm -rf "${stage_root}"
            rm -f "${archive_tmp}"
            jq -cn --arg policy "${policy_name}" \
                '{ok:false, status:"backup_failed", error:("effective policy is unavailable: " + $policy)}'
            return 1
        }
        cp -p -- "${effective_policy}" "${stage_root}/policies/${policy_name}"
    done < <(find "${LINUX_AGENT_BUILTIN_POLICIES_DIR}" -maxdepth 1 -type f -name '*.json' | sort)

    if ! python3 "${archive_tool}" build-manifest \
        "${stage_root}" "${stage_root}/manifest.json" \
        "$(linux_agent_now_iso)" \
        "$(linux_agent_config_get_default '.remote.release_version' '')" \
        "$(linux_agent_config_get_default '.remote.storage_backend' 'local')" \
        "$(linux_agent_managed_mode_enabled && printf true || printf false)" >/dev/null; then
        rm -rf "${stage_root}"
        rm -f "${archive_tmp}"
        jq -cn '{ok:false, status:"backup_failed", error:"runtime backup inventory could not be created"}'
        return 1
    fi

    mapfile -t archive_entries < <(find "${stage_root}" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)
    if ! tar --sort=name --owner=0 --group=0 --numeric-owner -C "${stage_root}" -czf "${archive_tmp}" "${archive_entries[@]}"; then
        rm -rf "${stage_root}"
        rm -f "${archive_tmp}"
        jq -cn '{ok:false, status:"backup_failed", error:"runtime backup archive could not be created"}'
        return 1
    fi
    chmod 0600 "${archive_tmp}"
    size_bytes="$(stat -c '%s' "${archive_tmp}")"
    sha256="$(sha256sum "${archive_tmp}" | awk '{print $1}')"
    audit_payload="$(jq -cn --arg name "${output_name}" --arg sha256 "${sha256}" --argjson size_bytes "${size_bytes}" '{name:$name, sha256:$sha256, size_bytes:$size_bytes}')"
    audit_rc=0
    linux_agent_audit_require_event "runtime_backup_commit" "${audit_payload}" || audit_rc=$?
    if ((audit_rc != 0)); then
        rm -rf "${stage_root}"
        rm -f "${archive_tmp}"
        linux_agent_audit_failure_result "${audit_rc}" "runtime_backup_commit"
        return 1
    fi
    if ! mv "${archive_tmp}" "${output_path}"; then
        rm -rf "${stage_root}"
        rm -f "${archive_tmp}"
        jq -cn '{ok:false, status:"backup_failed", error:"runtime backup could not be moved to the requested path"}'
        return 1
    fi
    audit_rc=0
    linux_agent_audit_require_event "runtime_backup_created" "${audit_payload}" || audit_rc=$?
    if ((audit_rc != 0)); then
        rm -f "${output_path}"
        rm -rf "${stage_root}"
        linux_agent_audit_failure_result "${audit_rc}" "runtime_backup_created"
        return 1
    fi
    rm -rf "${stage_root}"
    jq -cn --arg path "${output_path}" --arg sha256 "${sha256}" --argjson size_bytes "${size_bytes}" \
        '{ok:true, status:"backup_created", path:$path, sha256:$sha256, size_bytes:$size_bytes}'
}

linux_agent_restore_cleanup_paths() {
    local stage_root="$1"
    local restore_lock="$2"

    linux_agent_runtime_lock_release
    if [[ -n "${stage_root}" && -d "${stage_root}" &&
        "${stage_root}" == "${LINUX_AGENT_TMP_DIR}"/runtime-restore.* ]]; then
        rm -rf -- "${stage_root}"
    fi
    if [[ -n "${restore_lock}" && "${restore_lock}" == "${LINUX_AGENT_TMP_ROOT}/.runtime-restore.lock" ]]; then
        rmdir -- "${restore_lock}" 2>/dev/null || true
    fi
}

linux_agent_restore_error_result() {
    local stage_root="$1"
    local restore_lock="$2"
    local status="$3"
    local message="$4"

    linux_agent_restore_cleanup_paths "${stage_root}" "${restore_lock}"
    jq -cn --arg status "${status}" --arg message "${message}" \
        '{ok:false,status:$status,code:$status,error:$message}'
}

linux_agent_restore_runtime() {
    local archive_path="$1"
    local archive_tool stage_root extract_result
    local candidate_skills candidate_policies merged_config
    local user_skills_dir user_policies_dir log_dir policy_name policy_path validation
    local skill_name skill_dir
    local current_config managed_json commit_result restore_warning audit_rc
    local resolved_current_config expected_config
    local restore_lock before_fingerprint after_fingerprint locked_fingerprint

    if linux_agent_remote_mode; then
        jq -cn \
            '{ok:false,status:"restore_unavailable",code:"restore_unavailable",error:"Remote 运行时退出即清理；restore 仅支持 source checkout、--no-systemd 和 managed 安装"}'
        return 1
    fi

    if [[ -z "${archive_path}" || "${archive_path}" == *$'\n'* ||
        "${archive_path}" == -* || "${archive_path}" != *.tar.gz ]]; then
        jq -cn '{ok:false,status:"invalid_backup_path",code:"invalid_backup_path",error:"restore input must be an existing .tar.gz file"}'
        return 1
    fi
    [[ -f "${archive_path}" && ! -L "${archive_path}" ]] || {
        jq -cn '{ok:false,status:"invalid_backup_path",code:"invalid_backup_path",error:"restore input must be a regular file"}'
        return 1
    }
    if linux_agent_managed_execution_enabled && [[ "${EUID}" -ne 0 ]]; then
        jq -cn '{ok:false,status:"restore_requires_admin",code:"restore_requires_admin",error:"managed runtime restore requires a local administrator"}'
        return 1
    fi

    archive_tool="${LINUX_AGENT_ROOT}/lib/runtime_archive.py"
    [[ -f "${archive_tool}" && ! -L "${archive_tool}" ]] || {
        jq -cn '{ok:false,status:"restore_unavailable",code:"restore_unavailable",error:"runtime archive verifier is unavailable"}'
        return 1
    }
    restore_lock="${LINUX_AGENT_TMP_ROOT}/.runtime-restore.lock"
    if ! mkdir "${restore_lock}" 2>/dev/null; then
        jq -cn '{ok:false,status:"restore_busy",code:"restore_busy",error:"another runtime restore is already running"}'
        return 1
    fi
    stage_root=""
    if ! stage_root="$(mktemp -d "${LINUX_AGENT_TMP_DIR}/runtime-restore.XXXXXX")"; then
        linux_agent_restore_error_result "${stage_root}" "${restore_lock}" \
            restore_failed '无法创建 restore staging 目录'
        return 1
    fi
    if ! extract_result="$(python3 "${archive_tool}" extract "${archive_path}" "${stage_root}")" ||
        ! jq -e '.ok == true' <<<"${extract_result}" >/dev/null; then
        linux_agent_restore_error_result "${stage_root}" "${restore_lock}" \
            invalid_backup \
            "runtime archive 校验失败: $(jq -r '.error // "invalid archive"' <<<"${extract_result:-"{}"}" 2>/dev/null || printf 'invalid archive')"
        return 1
    fi

    candidate_skills="${stage_root}/candidate-skills"
    candidate_policies="${stage_root}/candidate-policies"
    merged_config="${stage_root}/config/config.merged.json"
    if ! mkdir -p "${candidate_skills}" "${candidate_policies}" ||
        ! cp -a "${stage_root}/skills/." "${candidate_skills}/"; then
        linux_agent_restore_error_result "${stage_root}" "${restore_lock}" \
            restore_failed '无法准备 restore 候选目录'
        return 1
    fi
    rm -f -- "${candidate_skills}/installation-state.json"

    user_skills_dir="$(linux_agent_user_skills_dir)"
    user_policies_dir="${LINUX_AGENT_USER_POLICIES_DIR:-${LINUX_AGENT_ROOT}/data/policies}"
    log_dir="${LINUX_AGENT_LOG_DIR}"
    if [[ (-e "${user_skills_dir}" || -L "${user_skills_dir}") &&
        (! -d "${user_skills_dir}" || -L "${user_skills_dir}") ]] ||
        { linux_agent_managed_mode_enabled && [[ ! -d "${user_skills_dir}" ]]; }; then
        linux_agent_restore_error_result "${stage_root}" "${restore_lock}" \
            restore_failed '当前用户 Skill overlay 不可用'
        return 1
    fi
    if [[ (-e "${user_policies_dir}" || -L "${user_policies_dir}") &&
        (! -d "${user_policies_dir}" || -L "${user_policies_dir}") ]] ||
        { linux_agent_managed_mode_enabled && [[ ! -d "${user_policies_dir}" ]]; }; then
        linux_agent_restore_error_result "${stage_root}" "${restore_lock}" \
            restore_failed '当前策略 overlay 不可用'
        return 1
    fi
    if [[ ! -d "${log_dir}" || -L "${log_dir}" ]]; then
        linux_agent_restore_error_result "${stage_root}" "${restore_lock}" \
            restore_failed '当前审计日志目录不可用'
        return 1
    fi
    current_config="${LINUX_AGENT_CONFIG_FILE}"
    if linux_agent_managed_mode_enabled; then
        resolved_current_config="$(readlink -f -- "${current_config}" 2>/dev/null || true)"
        expected_config="$(readlink -f -- "${LINUX_AGENT_DATA_DIR}/config/config.json" 2>/dev/null || true)"
        if [[ -z "${resolved_current_config}" || -z "${expected_config}" ||
            "${resolved_current_config}" != "${expected_config}" ]]; then
            linux_agent_restore_error_result "${stage_root}" "${restore_lock}" \
                restore_failed '受管配置链接不符合持久数据布局'
            return 1
        fi
        current_config="${expected_config}"
    fi
    if [[ ! -f "${current_config}" || -L "${current_config}" ]]; then
        linux_agent_restore_error_result "${stage_root}" "${restore_lock}" \
            restore_failed '当前配置文件不可用'
        return 1
    fi
    if ! linux_agent_runtime_lock_shared; then
        linux_agent_restore_error_result "${stage_root}" "${restore_lock}" \
            restore_busy 'runtime 正在恢复或切换版本'
        return 1
    fi
    before_fingerprint="$(python3 "${archive_tool}" fingerprint \
        "${LINUX_AGENT_ROOT}" "${current_config}" "${user_skills_dir}" \
        "${user_policies_dir}" 2>/dev/null || true)"
    if ! jq -e '.ok == true and (.sha256 | test("^[0-9a-f]{64}$"))' \
        <<<"${before_fingerprint}" >/dev/null 2>&1; then
        linux_agent_restore_error_result "${stage_root}" "${restore_lock}" \
            restore_failed \
            "无法记录 restore 前 runtime 身份: $(jq -r '.error // "fingerprint failed"' <<<"${before_fingerprint:-"{}"}" 2>/dev/null || printf 'fingerprint failed')"
        return 1
    fi

    while IFS= read -r skill_dir; do
        [[ -n "${skill_dir}" ]] || continue
        skill_name="$(basename "${skill_dir}")"
        if [[ ! "${skill_name}" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
            linux_agent_restore_error_result "${stage_root}" "${restore_lock}" \
                invalid_backup "归档 Skill 名称非法: ${skill_name}"
            return 1
        fi
        if linux_agent_builtin_skill_name_reserved "${skill_name}"; then
            linux_agent_restore_error_result "${stage_root}" "${restore_lock}" \
                invalid_backup "归档 Skill 与内置 Skill 冲突: ${skill_name}"
            return 1
        fi
        if [[ -f "${skill_dir}/.remote-verified.json" ]]; then
            if ! linux_agent_remote_skill_marker_valid_at "${skill_name}" "${skill_dir}"; then
                linux_agent_restore_error_result "${stage_root}" "${restore_lock}" \
                    invalid_backup "归档 Skill 的 remote 发布标记未经当前 release manifest 验证: ${skill_name}"
                return 1
            fi
            continue
        fi
        validation="$(python3 "${LINUX_AGENT_ROOT}/lib/skill_package.py" validate \
            "${skill_dir}" --origin user 2>/dev/null || true)"
        if ! jq -e '.ok == true' <<<"${validation}" >/dev/null; then
            linux_agent_restore_error_result "${stage_root}" "${restore_lock}" \
                invalid_backup "归档 Skill 校验失败: ${skill_name}"
            return 1
        fi
    done < <(find "${candidate_skills}" -mindepth 1 -maxdepth 1 -type d | sort)
    while IFS= read -r policy_path; do
        [[ -n "${policy_path}" ]] || continue
        policy_name="$(basename "${policy_path}")"
        if [[ ! -f "${stage_root}/policies/${policy_name}" ||
            -L "${stage_root}/policies/${policy_name}" ]]; then
            linux_agent_restore_error_result "${stage_root}" "${restore_lock}" \
                invalid_backup "归档缺少当前发布策略: ${policy_name}"
            return 1
        fi
    done < <(find "${LINUX_AGENT_BUILTIN_POLICIES_DIR}" -maxdepth 1 -type f -name '*.json' | sort)

    while IFS= read -r policy_path; do
        [[ -n "${policy_path}" ]] || continue
        policy_name="$(basename "${policy_path}")"
        if [[ ! "${policy_name}" =~ ^[a-z0-9][a-z0-9-]*\.json$ ]]; then
            linux_agent_restore_error_result "${stage_root}" "${restore_lock}" \
                invalid_backup "归档策略名称非法: ${policy_name}"
            return 1
        fi
        if [[ ! -f "${LINUX_AGENT_BUILTIN_POLICIES_DIR}/${policy_name}" ||
            -L "${LINUX_AGENT_BUILTIN_POLICIES_DIR}/${policy_name}" ]]; then
            linux_agent_restore_error_result "${stage_root}" "${restore_lock}" \
                invalid_backup "归档策略不是当前发布登记项: ${policy_name}"
            return 1
        fi
        if ! cp -p -- "${policy_path}" "${candidate_policies}/${policy_name}"; then
            linux_agent_restore_error_result "${stage_root}" "${restore_lock}" \
                restore_failed "无法准备归档策略: ${policy_name}"
            return 1
        fi
        validation="$(linux_agent_validate_policy_content "${policy_name}" "$(cat "${policy_path}")")"
        if ! jq -e '.ok == true' <<<"${validation}" >/dev/null; then
            linux_agent_restore_error_result "${stage_root}" "${restore_lock}" \
                invalid_backup "归档策略校验失败: ${policy_name}"
            return 1
        fi
    done < <(find "${stage_root}/policies" -maxdepth 1 -type f -name '*.json' | sort)

    if ! python3 "${archive_tool}" merge-config "${current_config}" \
        "${stage_root}/config/config.redacted.json" "${merged_config}" >/dev/null; then
        linux_agent_restore_error_result "${stage_root}" "${restore_lock}" \
            invalid_backup '脱敏配置无法安全合并'
        return 1
    fi

    # Verify every live audit chain in the archive before any durable rename.
    while IFS= read -r log_file; do
        [[ -n "${log_file}" ]] || continue
        session_id="$(basename "${log_file}" .jsonl)"
        validation="$(linux_agent_audit_verify_chain "${session_id}" "${log_file}" 2>/dev/null || true)"
        if ! jq -e '.ok == true' <<<"${validation}" >/dev/null; then
            linux_agent_restore_error_result "${stage_root}" "${restore_lock}" \
                invalid_backup "归档审计链校验失败: ${session_id}"
            return 1
        fi
    done < <(find "${stage_root}/logs" -maxdepth 1 -type f -name '*.jsonl' | sort)

    after_fingerprint="$(python3 "${archive_tool}" fingerprint \
        "${LINUX_AGENT_ROOT}" "${current_config}" "${user_skills_dir}" \
        "${user_policies_dir}" 2>/dev/null || true)"
    if [[ "$(jq -r '.sha256 // empty' <<<"${before_fingerprint}")" != "$(jq -r '.sha256 // empty' <<<"${after_fingerprint}")" ]]; then
        linux_agent_restore_error_result "${stage_root}" "${restore_lock}" \
            restore_conflict 'restore 准备期间 runtime 已被修改，请重试'
        return 1
    fi
    linux_agent_runtime_lock_release
    if ! linux_agent_runtime_lock_exclusive_nonblocking; then
        linux_agent_restore_error_result "${stage_root}" "${restore_lock}" \
            restore_busy 'runtime 中仍有活动请求，请结束后重试'
        return 1
    fi
    locked_fingerprint="$(python3 "${archive_tool}" fingerprint \
        "${LINUX_AGENT_ROOT}" "${current_config}" "${user_skills_dir}" \
        "${user_policies_dir}" 2>/dev/null || true)"
    if [[ "$(jq -r '.sha256 // empty' <<<"${after_fingerprint}")" != "$(jq -r '.sha256 // empty' <<<"${locked_fingerprint}")" ]]; then
        linux_agent_restore_error_result "${stage_root}" "${restore_lock}" \
            restore_conflict 'runtime 在 restore 提交前已被修改，请重试'
        return 1
    fi

    audit_rc=0
    linux_agent_audit_require_event "runtime_restore_started" \
        "$(jq -cn --arg name "$(basename "${archive_path}")" '{name:$name}')" || audit_rc=$?
    if ((audit_rc != 0)); then
        linux_agent_restore_error_result "${stage_root}" "${restore_lock}" \
            restore_failed '无法记录 runtime restore 审计意图'
        return 1
    fi
    # no-systemd installs use the persistent release/data layout but retain
    # current-user ownership; only helper-managed restores normalize to the
    # production root/Web ownership boundary.
    managed_json="$(linux_agent_managed_execution_enabled && printf true || printf false)"
    if ! commit_result="$(
        python3 - "${archive_tool}" "${candidate_skills}" \
            "${candidate_policies}" "${stage_root}/logs" "${user_skills_dir}" \
            "${user_policies_dir}" "${log_dir}" "${merged_config}" "${current_config}" \
            "${managed_json}" <<'PY'
import json
import sys

from pathlib import Path

sys.path.insert(0, str(Path(sys.argv[1]).parent))
from runtime_archive import ArchiveError, commit_restore  # noqa: E402

try:
    warning = commit_restore(
        Path(sys.argv[2]), Path(sys.argv[3]), Path(sys.argv[4]), Path(sys.argv[5]),
        Path(sys.argv[6]), Path(sys.argv[7]), Path(sys.argv[8]), Path(sys.argv[9]),
        sys.argv[10] == "true",
    )
except (ArchiveError, OSError, ValueError) as exc:
    print(json.dumps({"ok": False, "status": "restore_failed", "error": str(exc)}))
    raise SystemExit(1)
print(json.dumps({"ok": True, "status": "restored", **({"warning": warning} if warning else {})}))
PY
    )"; then
        linux_agent_restore_error_result "${stage_root}" "${restore_lock}" \
            restore_failed \
            "runtime restore 提交失败: $(jq -r '.error // "commit failed"' <<<"${commit_result:-"{}"}" 2>/dev/null || printf 'commit failed')"
        return 1
    fi
    restore_warning="$(jq -r '.warning // empty' <<<"${commit_result}")"
    audit_rc=0
    linux_agent_audit_require_event "runtime_restore_completed" \
        "$(jq -cn --arg name "$(basename "${archive_path}")" '{name:$name}')" || audit_rc=$?
    linux_agent_restore_cleanup_paths "${stage_root}" "${restore_lock}"
    if ((audit_rc != 0)); then
        jq -cn --arg warning "${restore_warning}" '{ok:true,status:"restored",audit_status:"requested_only",audit_error:"restore completion audit could not be persisted"} + (if $warning == "" then {} else {warning:$warning} end)'
    elif [[ -n "${restore_warning}" ]]; then
        jq -cn --arg warning "${restore_warning}" '{ok:true,status:"restored",warning:$warning}'
    else
        jq -cn '{ok:true,status:"restored"}'
    fi
}
