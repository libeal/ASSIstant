#!/usr/bin/env bash

set -euo pipefail

linux_agent_backup_runtime() {
    local output_path="$1"
    local output_dir output_name resolved_output_dir resolved_root stage_root archive_tmp
    local config_json size_bytes sha256 skill_dir skill_name log_file session_id line marker ledger unsafe_path
    local audit_rc audit_payload
    local -a archive_entries=()

    if ! linux_agent_remote_mode; then
        jq -cn '{ok:false, status:"backup_unavailable", error:"Runtime backup is only available in remote mode."}'
        return 1
    fi
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
    mkdir -p "${stage_root}/logs" "${stage_root}/reports" "${stage_root}/config" "${stage_root}/skills"

    while IFS= read -r log_file; do
        [[ -n "${log_file}" ]] || continue
        while IFS= read -r line || [[ -n "${line}" ]]; do
            linux_agent_sanitize_json "${line}" 200000
        done <"${log_file}" >"${stage_root}/logs/$(basename "${log_file}")"
        session_id="$(basename "${log_file}" .jsonl)"
        LINUX_AGENT_LOG_DIR="${stage_root}/logs" linux_agent_show_audit "${session_id}" \
            >"${stage_root}/reports/${session_id}.txt" 2>/dev/null ||
            rm -f "${stage_root}/reports/${session_id}.txt"
    done < <(find "${LINUX_AGENT_LOG_DIR}" -maxdepth 1 -type f -name '*.jsonl' | sort)

    config_json="$(cat "${LINUX_AGENT_CONFIG_FILE}")"
    linux_agent_sanitize_json "${config_json}" 200000 | jq . >"${stage_root}/config/config.redacted.json"

    ledger='[]'
    while IFS= read -r skill_dir; do
        [[ -n "${skill_dir}" ]] || continue
        skill_name="$(basename "${skill_dir}")"
        marker="${skill_dir}/.remote-verified.json"
        if [[ -f "${marker}" ]]; then
            ledger="$(jq -cn --argjson prior "${ledger}" --argjson marker "$(jq '{skill, sha256, release_version}' "${marker}")" '$prior + [$marker]')"
            continue
        fi
        unsafe_path="$(find "${skill_dir}" \( -type l -o -type b -o -type c -o -type p -o -type s \) -print -quit)"
        if [[ -n "${unsafe_path}" ]]; then
            rm -rf "${stage_root}"
            rm -f "${archive_tmp}"
            jq -cn --arg skill "${skill_name}" '{ok:false, status:"backup_unsafe_skill", error:("user skill contains an unsafe file type: " + $skill)}'
            return 1
        fi
        cp -a "${skill_dir}" "${stage_root}/skills/${skill_name}"
    done < <(find "$(linux_agent_skills_dir)" -mindepth 1 -maxdepth 1 -type d | sort)
    jq -S -n --argjson materialized "${ledger}" '{schema_version:1, materialized:$materialized}' >"${stage_root}/skills/materialized.json"

    jq -n \
        --arg exported_at "$(linux_agent_now_iso)" \
        --arg release_version "$(linux_agent_config_get_default '.remote.release_version' '')" \
        --arg storage_backend "$(linux_agent_config_get_default '.remote.storage_backend' 'local')" \
        '{schema_version:1, exported_at:$exported_at, release_version:$release_version, storage_backend:$storage_backend, redacted:true}' \
        >"${stage_root}/manifest.json"

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
