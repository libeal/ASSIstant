#!/usr/bin/env bash

set -euo pipefail

LINUX_AGENT_SESSION_ID="${LINUX_AGENT_SESSION_ID:-}"
LINUX_AGENT_AUDIT_LOG="${LINUX_AGENT_AUDIT_LOG:-}"
LINUX_AGENT_SESSION_ACTIVE=0
LINUX_AGENT_SESSION_FINISHED=0
LINUX_AGENT_LAST_BUSINESS_STATUS=""
declare -a LINUX_AGENT_AUDIT_CHAIN_ARGS=()

linux_agent_audit_boundaries_path() {
    printf '%s/policies/audit-boundaries.json\n' "${LINUX_AGENT_ROOT}"
}

linux_agent_audit_chain_writer() {
    local candidate="${LINUX_AGENT_ROOT}/lib/audit_chain.py"
    if [[ -f "${candidate}" ]]; then
        printf '%s\n' "${candidate}"
        return 0
    fi
    # Fall back to the directory this script was sourced from (mirrors the
    # lib/mcp.sh + lib/policy.sh resolution), so callers that point
    # LINUX_AGENT_ROOT at a project dir without a bundled lib/ still find it.
    printf '%s\n' "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/audit_chain.py"
}

# Cached CLI option array for lib/audit_chain.py, derived from config .audit.*.
# Changing .audit.* at runtime requires clearing LINUX_AGENT_AUDIT_CHAIN_ARGS.
linux_agent_audit_chain_args() {
    if ! declare -p LINUX_AGENT_AUDIT_CHAIN_ARGS >/dev/null 2>&1; then
        declare -ga LINUX_AGENT_AUDIT_CHAIN_ARGS=()
    fi
    if ((${#LINUX_AGENT_AUDIT_CHAIN_ARGS[@]} == 0)); then
        # The hash chain (seq/prev_hash/hash) is a mandatory integrity invariant,
        # not a toggle: verify rejects unchained events as tampered, so writing
        # them would be self-contradictory. Only fsync and disk policy are tunable.
        local fsync="true" max_bytes="52428800" min_free="10485760" on_full="degrade"
        if [[ -n "${LINUX_AGENT_CONFIG_JSON:-}" ]] && declare -F linux_agent_config_bool_strict >/dev/null 2>&1; then
            fsync="$(linux_agent_config_bool_strict '.audit.fsync' 'true')"
            max_bytes="$(linux_agent_config_nonneg_int_default '.audit.max_bytes' '52428800')"
            min_free="$(linux_agent_config_nonneg_int_default '.audit.min_free_bytes' '10485760')"
            on_full="$(linux_agent_config_get_default '.audit.on_full' 'degrade')"
        fi
        [[ "${on_full}" == "block" || "${on_full}" == "degrade" ]] || on_full="degrade"
        [[ "${fsync}" == "true" ]] || LINUX_AGENT_AUDIT_CHAIN_ARGS+=(--no-fsync)
        LINUX_AGENT_AUDIT_CHAIN_ARGS+=(
            --max-bytes "${max_bytes}"
            --min-free-bytes "${min_free}"
            --on-full "${on_full}"
        )
    fi
    local IFS=" "
    printf '%s\n' "${LINUX_AGENT_AUDIT_CHAIN_ARGS[*]}"
}

# Keep one Python chain writer per Bash process/session. The protocol is
# synchronous: success is returned only after the event has been persisted.
linux_agent_audit_writer_stop() {
    local input_fd="${LINUX_AGENT_AUDIT_WRITER_INPUT_FD:-}"
    local output_fd="${LINUX_AGENT_AUDIT_WRITER_OUTPUT_FD:-}"
    local writer_pid="${LINUX_AGENT_AUDIT_WRITER_PID:-}"
    if [[ -n "${LINUX_AGENT_AUDIT_WRITER_OWNER_PID:-}" &&
        "${LINUX_AGENT_AUDIT_WRITER_OWNER_PID}" != "${BASHPID}" ]]; then
        unset LINUX_AGENT_AUDIT_WRITER_INPUT_FD LINUX_AGENT_AUDIT_WRITER_OUTPUT_FD
        unset LINUX_AGENT_AUDIT_WRITER_PID LINUX_AGENT_AUDIT_WRITER_KEY
        unset LINUX_AGENT_AUDIT_WRITER_OWNER_PID
        unset LINUX_AGENT_AUDIT_WRITER_PROCESS LINUX_AGENT_AUDIT_WRITER_PROCESS_PID
        return 0
    fi
    if [[ -n "${input_fd}" ]]; then
        { exec {input_fd}>&-; } 2>/dev/null || true
    fi
    if [[ -n "${output_fd}" ]]; then
        { exec {output_fd}<&-; } 2>/dev/null || true
    fi
    if [[ -n "${writer_pid}" ]]; then
        wait "${writer_pid}" 2>/dev/null || true
    fi
    unset LINUX_AGENT_AUDIT_WRITER_INPUT_FD LINUX_AGENT_AUDIT_WRITER_OUTPUT_FD
    unset LINUX_AGENT_AUDIT_WRITER_PID LINUX_AGENT_AUDIT_WRITER_KEY
    unset LINUX_AGENT_AUDIT_WRITER_OWNER_PID
    unset LINUX_AGENT_AUDIT_WRITER_PROCESS LINUX_AGENT_AUDIT_WRITER_PROCESS_PID
}

linux_agent_audit_writer_start() {
    local writer chain_key writer_key
    local -a chain_args=()
    writer="$(linux_agent_audit_chain_writer)"
    linux_agent_audit_chain_args >/dev/null
    chain_args=("${LINUX_AGENT_AUDIT_CHAIN_ARGS[@]}")
    printf -v chain_key '%q ' "${chain_args[@]}"
    writer_key="${writer}|${LINUX_AGENT_AUDIT_LOG}|${chain_key}"
    if [[ "${LINUX_AGENT_AUDIT_WRITER_KEY:-}" == "${writer_key}" &&
        "${LINUX_AGENT_AUDIT_WRITER_OWNER_PID:-}" == "${BASHPID}" &&
        -n "${LINUX_AGENT_AUDIT_WRITER_PID:-}" ]] &&
        kill -0 "${LINUX_AGENT_AUDIT_WRITER_PID}" 2>/dev/null; then
        return 0
    fi

    linux_agent_audit_writer_stop
    coproc LINUX_AGENT_AUDIT_WRITER_PROCESS {
        python3 "${writer}" serve "${LINUX_AGENT_AUDIT_LOG}" "${chain_args[@]}"
    }
    LINUX_AGENT_AUDIT_WRITER_INPUT_FD="${LINUX_AGENT_AUDIT_WRITER_PROCESS[1]}"
    LINUX_AGENT_AUDIT_WRITER_OUTPUT_FD="${LINUX_AGENT_AUDIT_WRITER_PROCESS[0]}"
    LINUX_AGENT_AUDIT_WRITER_PID="${LINUX_AGENT_AUDIT_WRITER_PROCESS_PID}"
    LINUX_AGENT_AUDIT_WRITER_KEY="${writer_key}"
    LINUX_AGENT_AUDIT_WRITER_OWNER_PID="${BASHPID}"
}

# One-shot append via a throwaway python3 process. Used from subshells that
# inherited a parent coproc they do not own: bash allows only one coproc per
# shell and cannot spawn a second without warning, and the inherited writer's
# fds belong to the parent. `serve` takes a fresh flock per line, so a one-shot
# `append` interleaves safely with the owner's persistent writer.
linux_agent_audit_append_oneshot() {
    local event="$1"
    local writer
    local -a chain_args=()
    writer="$(linux_agent_audit_chain_writer)"
    linux_agent_audit_chain_args >/dev/null
    chain_args=("${LINUX_AGENT_AUDIT_CHAIN_ARGS[@]}")
    printf '%s\n' "${event}" |
        python3 "${writer}" append "${LINUX_AGENT_AUDIT_LOG}" "${chain_args[@]}"
}

linux_agent_audit_write_event() {
    local event="$1"
    local input_fd output_fd response_code response_error
    # A subshell (command substitution) inherits the coproc fds and tracking
    # variables but has a different BASHPID. Rebuilding a coproc here would make
    # bash warn "coproc ... still exists" and orphan the inherited writer, so
    # non-owner contexts take the one-shot append path instead.
    if [[ -n "${LINUX_AGENT_AUDIT_WRITER_OWNER_PID:-}" &&
        "${LINUX_AGENT_AUDIT_WRITER_OWNER_PID}" != "${BASHPID}" ]]; then
        linux_agent_audit_append_oneshot "${event}"
        return $?
    fi
    linux_agent_audit_writer_start || return 4
    input_fd="${LINUX_AGENT_AUDIT_WRITER_INPUT_FD}"
    output_fd="${LINUX_AGENT_AUDIT_WRITER_OUTPUT_FD}"
    if ! printf '%s\n' "${event}" >&"${input_fd}"; then
        linux_agent_audit_writer_stop
        return 4
    fi
    if ! IFS=$'\t' read -r response_code response_error <&"${output_fd}"; then
        linux_agent_audit_writer_stop
        return 4
    fi
    if [[ ! "${response_code}" =~ ^[0-9]+$ ]]; then
        linux_agent_audit_writer_stop
        return 4
    fi
    if ((response_code != 0)) && [[ -n "${response_error}" ]]; then
        printf '%s\n' "${response_error}" >&2
    fi
    return "${response_code}"
}

linux_agent_audit_segment_paths() {
    local live_file="$1"
    if [[ -z "${live_file}" ]]; then
        return 1
    fi
    [[ -f "${live_file}" && ! -L "${live_file}" ]] || return 1

    local candidate suffix
    local -a indexes=() sorted_indexes=()
    for candidate in "${live_file}".*; do
        [[ -f "${candidate}" && ! -L "${candidate}" ]] || continue
        suffix="${candidate#"${live_file}".}"
        [[ "${suffix}" =~ ^[1-9][0-9]*$ ]] || continue
        indexes+=("${suffix}")
    done
    if ((${#indexes[@]} > 0)); then
        mapfile -t sorted_indexes < <(printf '%s\n' "${indexes[@]}" | LC_ALL=C sort -n)
        for suffix in "${sorted_indexes[@]}"; do
            printf '%s\n' "${live_file}.${suffix}"
        done
    fi
    printf '%s\n' "${live_file}"
}

linux_agent_audit_segment_files() {
    local session_id="$1"
    if [[ -z "${session_id}" || ! "${session_id}" =~ ^[A-Za-z0-9._-]+$ ]]; then
        return 1
    fi
    linux_agent_audit_segment_paths "${LINUX_AGENT_LOG_DIR}/${session_id}.jsonl"
}

linux_agent_audit_snapshot() {
    local session_id="$1"
    local destination_directory="$2"
    if [[ -z "${session_id}" || ! "${session_id}" =~ ^[A-Za-z0-9._-]+$ ]]; then
        return 1
    fi
    python3 "$(linux_agent_audit_chain_writer)" snapshot \
        "${LINUX_AGENT_LOG_DIR}/${session_id}.jsonl" \
        "${destination_directory}"
}

linux_agent_audit_verify_chain() {
    local session_id="$1"
    local log_file="${2:-}"
    if [[ -z "${session_id}" || ! "${session_id}" =~ ^[A-Za-z0-9._-]+$ ]]; then
        jq -cn '{ok:false, status:"invalid_session_id", error:"session_id 非法。"}'
        return 1
    fi
    [[ -n "${log_file}" ]] || log_file="${LINUX_AGENT_LOG_DIR}/${session_id}.jsonl"
    if [[ ! -f "${log_file}" ]]; then
        jq -cn '{ok:false, status:"not_found", error:"审计 session 不存在。"}'
        return 1
    fi
    python3 "$(linux_agent_audit_chain_writer)" verify "${log_file}"
}

linux_agent_audit_export_error() {
    local message="$1"
    jq -cn --arg message "${message}" '{
        ok:false,
        status:"audit_export_failed",
        code:"audit_export_failed",
        error:$message,
        message:$message,
        retryable:true
    }'
}

linux_agent_audit_export() {
    local selector="${1:-}" output_dir="${LINUX_AGENT_ROOT}/tmp/audit-export"
    local stage_root archive_tmp archive_path timestamp suffix=0
    local session_id snapshot_path verify_path verify_report verify_rc
    local session_files file_path relative_path file_sha file_size
    local sessions_json='[]' files_json='[]' all_verified=true
    local -a session_ids=() archive_entries=()
    shift || true

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --output)
                [[ $# -ge 2 ]] || {
                    linux_agent_audit_export_error '--output 缺少目录参数。'
                    return 1
                }
                output_dir="$2"
                shift 2
                ;;
            *)
                linux_agent_audit_export_error "未知审计导出参数: $1"
                return 1
                ;;
        esac
    done

    if [[ "${selector}" == "--all" ]]; then
        while IFS= read -r file_path; do
            session_id="$(basename "${file_path}" .jsonl)"
            [[ "${session_id}" =~ ^[A-Za-z0-9._-]+$ ]] || continue
            session_ids+=("${session_id}")
        done < <(find "${LINUX_AGENT_LOG_DIR}" -maxdepth 1 -type f -name '*.jsonl' -print | LC_ALL=C sort)
    elif [[ "${selector}" =~ ^[A-Za-z0-9._-]+$ ]]; then
        session_ids+=("${selector}")
    else
        jq -cn '{ok:false,status:"invalid_session_id",code:"invalid_session_id",error:"session_id 非法。",message:"session_id 非法。",retryable:false}'
        return 1
    fi

    if [[ ${#session_ids[@]} -eq 0 ]]; then
        linux_agent_audit_export_error '没有可导出的审计 session。'
        return 1
    fi
    if [[ -L "${output_dir}" || (-e "${output_dir}" && ! -d "${output_dir}") ]]; then
        linux_agent_audit_export_error '审计导出目录必须是普通目录且不能是符号链接。'
        return 1
    fi
    if ! mkdir -p "${output_dir}" || [[ ! -w "${output_dir}" ]]; then
        linux_agent_audit_export_error '无法创建或写入审计导出目录。'
        return 1
    fi
    chmod 0700 "${output_dir}" 2>/dev/null || true
    output_dir="$(readlink -f "${output_dir}")"
    stage_root="$(mktemp -d "${output_dir}/.audit-export-stage.XXXXXX")" || {
        linux_agent_audit_export_error '无法创建审计导出 staging 目录。'
        return 1
    }
    chmod 0700 "${stage_root}"
    mkdir -p "${stage_root}/logs" "${stage_root}/reports"

    for session_id in "${session_ids[@]}"; do
        if ! snapshot_path="$(linux_agent_audit_snapshot "${session_id}" "${stage_root}/logs" 2>/dev/null)"; then
            rm -rf "${stage_root}"
            linux_agent_audit_export_error "无法取得审计 session 快照: ${session_id}"
            return 1
        fi
        verify_path="${stage_root}/reports/${session_id}.verify.json"
        verify_rc=0
        linux_agent_audit_verify_chain "${session_id}" "${snapshot_path}" >"${verify_path}" || verify_rc=$?
        if ! jq -e 'type == "object" and (.ok | type) == "boolean"' "${verify_path}" >/dev/null 2>&1; then
            rm -rf "${stage_root}"
            linux_agent_audit_export_error "审计校验未生成有效报告: ${session_id}"
            return 1
        fi
        rm -f "${snapshot_path}.lock"
        chmod 0600 "${verify_path}"
        if [[ "${verify_rc}" -ne 0 || "$(jq -r '.ok' "${verify_path}")" != "true" ]]; then
            all_verified=false
        fi

        session_files='[]'
        while IFS= read -r file_path; do
            relative_path="logs/$(basename "${file_path}")"
            session_files="$(jq -cn --argjson prior "${session_files}" --arg path "${relative_path}" '$prior + [$path]')"
        done < <(linux_agent_audit_segment_paths "${snapshot_path}")
        verify_report="$(cat "${verify_path}")"
        sessions_json="$(jq -cn \
            --argjson prior "${sessions_json}" \
            --arg session_id "${session_id}" \
            --argjson verified "$(jq -c '.ok' <<<"${verify_report}")" \
            --argjson events "$(jq -c '.events // 0' <<<"${verify_report}")" \
            --argjson files "${session_files}" \
            '$prior + [{session_id:$session_id, verified:$verified, events:$events, files:$files}]')"
    done

    while IFS= read -r file_path; do
        relative_path="${file_path#"${stage_root}"/}"
        file_sha="$(sha256sum "${file_path}" | awk '{print $1}')"
        file_size="$(stat -c '%s' "${file_path}")"
        files_json="$(jq -cn \
            --argjson prior "${files_json}" \
            --arg path "${relative_path}" \
            --arg sha256 "${file_sha}" \
            --argjson size_bytes "${file_size}" \
            '$prior + [{path:$path, sha256:$sha256, size_bytes:$size_bytes}]')"
    done < <(find "${stage_root}/logs" "${stage_root}/reports" -type f -print | LC_ALL=C sort)

    jq -S -n \
        --arg exported_at "$(linux_agent_now_iso)" \
        --arg agent_version "$(linux_agent_config_get_default '.remote.release_version' 'local')" \
        --argjson verified "${all_verified}" \
        --argjson sessions "${sessions_json}" \
        --argjson files "${files_json}" '
        {
            schema_version:1,
            exported_at:$exported_at,
            agent_version:(if $agent_version == "" then "local" else $agent_version end),
            verified:$verified,
            sessions:$sessions,
            files:$files
        }
    ' >"${stage_root}/export-manifest.json"
    chmod 0600 "${stage_root}/export-manifest.json"
    (
        cd "${stage_root}"
        mapfile -t checksum_paths < <(find . -type f ! -name SHA256SUMS -printf '%P\n' | LC_ALL=C sort)
        : >SHA256SUMS
        for relative_path in "${checksum_paths[@]}"; do
            sha256sum "${relative_path}" >>SHA256SUMS
        done
        chmod 0600 SHA256SUMS
    )

    timestamp="$(date -u +'%Y%m%dT%H%M%SZ')"
    archive_path="${output_dir}/audit-export-${timestamp}.tar.gz"
    while [[ -e "${archive_path}" || -L "${archive_path}" ]]; do
        suffix=$((suffix + 1))
        archive_path="${output_dir}/audit-export-${timestamp}-${suffix}.tar.gz"
    done
    archive_tmp="$(mktemp "${output_dir}/.audit-export.XXXXXX.tmp")" || {
        rm -rf "${stage_root}"
        linux_agent_audit_export_error '无法创建审计导出 archive 临时文件。'
        return 1
    }
    mapfile -t archive_entries < <(find "${stage_root}" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort)
    if ! tar --sort=name --owner=0 --group=0 --numeric-owner -C "${stage_root}" -czf "${archive_tmp}" "${archive_entries[@]}"; then
        rm -f "${archive_tmp}"
        rm -rf "${stage_root}"
        linux_agent_audit_export_error '无法创建审计导出 archive。'
        return 1
    fi
    chmod 0600 "${archive_tmp}"
    if ! mv "${archive_tmp}" "${archive_path}"; then
        rm -f "${archive_tmp}"
        rm -rf "${stage_root}"
        linux_agent_audit_export_error '无法提交审计导出 archive。'
        return 1
    fi
    rm -rf "${stage_root}"
    jq -cn \
        --arg archive "${archive_path}" \
        --argjson sessions "$(jq -c '[.[].session_id]' <<<"${sessions_json}")" \
        --argjson verified "${all_verified}" \
        '{ok:true,status:"exported",archive:$archive,sessions:$sessions,verified:$verified}'
}

linux_agent_audit_boundary_default_config() {
    cat <<'JSON'
{
  "observing": {
    "audit_payload_mode": "safe_summary",
    "audit_text_limit": 1000,
    "application_events": [
      "session_started",
      "session_finished",
      "command_started",
      "command_finished",
      "turn_started",
      "turn_finished",
      "control_event",
      "received",
      "sensed",
      "request_context_built",
      "ai_failed",
      "ai_invalid_response",
      "planned",
      "finished",
      "executed",
      "agent_loop_*",
      "agent_reflection_*",
      "agent_checkpoint_*",
      "work_revision_requested",
      "revision_planned",
      "repair_*",
      "step_*",
      "script_*",
      "skill_*",
      "remote_*",
      "runtime_backup_*",
      "script_manual_edit",
      "terminal_executed",
      "edit_*",
      "ai_files_manifest",
      "ai_provider_*",
      "execution_started",
      "execution_finished",
      "observer_*",
      "file_vault_*"
    ],
    "observer_syscalls": [
      "execve",
      "execveat",
      "open",
      "openat",
      "creat",
      "truncate",
      "ftruncate",
      "rename",
      "renameat",
      "unlink",
      "unlinkat",
      "chmod",
      "fchmod",
      "chown",
      "fchown",
      "mkdir",
      "rmdir"
    ],
    "observer_result_fields": [
      "exec_count",
      "file_event_count",
      "processes",
      "file_events"
    ],
    "observer_max_events": 200
  },
  "allowed_to_observe": {
    "audit_payload_modes": [
      "safe_summary",
      "redacted_verbose"
    ],
    "audit_text_limit": {
      "min": 1,
      "max": 100000
    },
    "application_events": [
      "session_started",
      "session_finished",
      "command_started",
      "command_finished",
      "turn_started",
      "turn_finished",
      "control_event",
      "received",
      "sensed",
      "request_context_built",
      "ai_failed",
      "ai_invalid_response",
      "planned",
      "finished",
      "executed",
      "agent_loop_*",
      "agent_reflection_*",
      "agent_checkpoint_*",
      "work_revision_requested",
      "revision_planned",
      "repair_*",
      "step_*",
      "script_*",
      "skill_*",
      "remote_*",
      "runtime_backup_*",
      "terminal_executed",
      "edit_*",
      "script_manual_edit",
      "ai_files_manifest",
      "ai_provider_*",
      "execution_started",
      "execution_finished",
      "observer_*",
      "file_vault_*"
    ],
    "observer_syscalls": [
      "execve",
      "execveat",
      "open",
      "openat",
      "openat2",
      "creat",
      "truncate",
      "ftruncate",
      "rename",
      "renameat",
      "renameat2",
      "unlink",
      "unlinkat",
      "chmod",
      "fchmod",
      "fchmodat",
      "chown",
      "fchown",
      "fchownat",
      "mkdir",
      "mkdirat",
      "rmdir",
      "symlink",
      "symlinkat",
      "link",
      "linkat"
    ],
    "observer_result_fields": [
      "exec_count",
      "file_event_count",
      "processes",
      "file_events"
    ],
    "observer_max_events": {
      "min": 1,
      "max": 1000
    }
  }
}
JSON
}

linux_agent_audit_boundary_config() {
    local path
    path="$(linux_agent_audit_boundaries_path)"
    if [[ -f "${path}" ]] && jq -e 'type == "object"' "${path}" >/dev/null 2>&1; then
        jq -c . "${path}"
        return 0
    fi
    linux_agent_audit_boundary_default_config | jq -c .
}

linux_agent_audit_boundary_values() {
    local jq_path="$1"
    linux_agent_audit_boundary_config | jq -r "${jq_path}[]? | strings" 2>/dev/null || true
}

linux_agent_audit_boundary_pattern_matches() {
    local pattern="$1"
    local value="$2"
    local prefix
    if [[ "${pattern}" == "all" ]]; then
        return 0
    fi
    if [[ "${pattern}" == *"*" ]]; then
        prefix="${pattern%\*}"
        [[ "${value}" == "${prefix}"* ]]
        return $?
    fi
    [[ "${value}" == "${pattern}" ]]
}

linux_agent_audit_boundary_entry_allowed() {
    local entry="$1"
    local allowed_path="$2"
    local allowed
    while IFS= read -r allowed; do
        [[ -z "${allowed}" ]] && continue
        if [[ "${entry}" == *"*" ]]; then
            if [[ "${allowed}" == "all" || "${allowed}" == "${entry}" ]]; then
                return 0
            fi
        elif linux_agent_audit_boundary_pattern_matches "${allowed}" "${entry}"; then
            return 0
        fi
    done < <(linux_agent_audit_boundary_values "${allowed_path}")
    return 1
}

linux_agent_audit_boundary_selected_patterns() {
    local selected_path="$1"
    local allowed_path="$2"
    local entry
    while IFS= read -r entry; do
        [[ -z "${entry}" ]] && continue
        if linux_agent_audit_boundary_entry_allowed "${entry}" "${allowed_path}"; then
            printf '%s\n' "${entry}"
        fi
    done < <(linux_agent_audit_boundary_values "${selected_path}")
}

linux_agent_audit_boundary_selected_exact_values() {
    local selected_path="$1"
    local allowed_path="$2"
    local entry
    while IFS= read -r entry; do
        [[ -z "${entry}" || "${entry}" == *"*"* ]] && continue
        if linux_agent_audit_boundary_entry_allowed "${entry}" "${allowed_path}"; then
            printf '%s\n' "${entry}"
        fi
    done < <(linux_agent_audit_boundary_values "${selected_path}") | awk '!seen[$0]++'
}

linux_agent_audit_boundary_observes_value() {
    local value="$1"
    local selected_path="$2"
    local allowed_path="$3"
    local entry matched=1
    while IFS= read -r entry; do
        [[ -z "${entry}" ]] && continue
        if linux_agent_audit_boundary_pattern_matches "${entry}" "${value}"; then
            matched=0
        fi
    done < <(linux_agent_audit_boundary_selected_patterns "${selected_path}" "${allowed_path}")
    return "${matched}"
}

linux_agent_audit_boundary_should_log_stage() {
    local stage="$1"
    linux_agent_audit_boundary_observes_value \
        "${stage}" \
        '.observing.application_events' \
        '.allowed_to_observe.application_events'
}

linux_agent_audit_boundary_payload_mode() {
    local fallback="${1:-safe_summary}"
    local mode
    if linux_agent_audit_boundary_entry_allowed "${fallback}" '.allowed_to_observe.audit_payload_modes'; then
        printf '%s\n' "${fallback}"
        return 0
    fi
    mode="$(linux_agent_audit_boundary_config | jq -r '.observing.audit_payload_mode // empty' 2>/dev/null || true)"
    if [[ -n "${mode}" ]] && linux_agent_audit_boundary_entry_allowed "${mode}" '.allowed_to_observe.audit_payload_modes'; then
        printf '%s\n' "${mode}"
        return 0
    fi
    printf '%s\n' "${fallback}"
}

linux_agent_audit_boundary_number() {
    local value_path="$1"
    local min_path="$2"
    local max_path="$3"
    local fallback="$4"
    local config value min max
    config="$(linux_agent_audit_boundary_config)"
    value="$(jq -r "${value_path} // empty" <<<"${config}" 2>/dev/null || true)"
    min="$(jq -r "${min_path} // 1" <<<"${config}" 2>/dev/null || true)"
    max="$(jq -r "${max_path} // empty" <<<"${config}" 2>/dev/null || true)"

    if [[ ! "${value}" =~ ^[0-9]+$ || "${value}" -le 0 ]]; then
        value="${fallback}"
    fi
    if [[ "${min}" =~ ^[0-9]+$ && "${value}" -lt "${min}" ]]; then
        value="${min}"
    fi
    if [[ "${max}" =~ ^[0-9]+$ && "${max}" -gt 0 && "${value}" -gt "${max}" ]]; then
        value="${max}"
    fi
    printf '%s\n' "${value}"
}

linux_agent_audit_boundary_text_limit() {
    linux_agent_audit_boundary_number \
        '.observing.audit_text_limit' \
        '.allowed_to_observe.audit_text_limit.min' \
        '.allowed_to_observe.audit_text_limit.max' \
        "${1:-1000}"
}

linux_agent_audit_boundary_observer_max_events() {
    linux_agent_audit_boundary_number \
        '.observing.observer_max_events' \
        '.allowed_to_observe.observer_max_events.min' \
        '.allowed_to_observe.observer_max_events.max' \
        "${1:-200}"
}

linux_agent_audit_boundary_observer_syscalls() {
    linux_agent_audit_boundary_selected_exact_values \
        '.observing.observer_syscalls' \
        '.allowed_to_observe.observer_syscalls'
}

linux_agent_audit_boundary_observer_field_enabled() {
    local field="$1"
    linux_agent_audit_boundary_observes_value \
        "${field}" \
        '.observing.observer_result_fields' \
        '.allowed_to_observe.observer_result_fields'
}

linux_agent_audit_boundary_runtime_summary() {
    local events syscalls fields payload_mode text_limit max_events
    events="$(linux_agent_audit_boundary_selected_patterns '.observing.application_events' '.allowed_to_observe.application_events' | jq -R -s 'split("\n") | map(select(length > 0))')"
    syscalls="$(linux_agent_audit_boundary_observer_syscalls | jq -R -s 'split("\n") | map(select(length > 0))')"
    fields="$(linux_agent_audit_boundary_selected_exact_values '.observing.observer_result_fields' '.allowed_to_observe.observer_result_fields' | jq -R -s 'split("\n") | map(select(length > 0))')"
    payload_mode="$(linux_agent_audit_boundary_payload_mode "$(linux_agent_audit_mode)")"
    text_limit="$(linux_agent_audit_boundary_text_limit "$(linux_agent_audit_text_limit)")"
    max_events="$(linux_agent_audit_boundary_observer_max_events "$(linux_agent_observer_max_events 2>/dev/null || printf '200')")"
    jq -cn \
        --arg payload_mode "${payload_mode}" \
        --argjson text_limit "${text_limit}" \
        --argjson application_events "${events}" \
        --argjson observer_syscalls "${syscalls}" \
        --argjson observer_result_fields "${fields}" \
        --argjson observer_max_events "${max_events}" \
        '{audit_payload_mode:$payload_mode, audit_text_limit:$text_limit, application_events:$application_events, observer_syscalls:$observer_syscalls, observer_result_fields:$observer_result_fields, observer_max_events:$observer_max_events}'
}

linux_agent_audit_safe_summary() {
    local stage="$1"
    local payload="$2"
    local limit
    limit="$(linux_agent_audit_text_limit)"

    if ! printf '%s' "${payload}" | jq -e . >/dev/null 2>&1; then
        jq -cn --arg raw "$(linux_agent_sanitize_text "${payload}" "${limit}")" '{raw_preview:$raw}'
        return 0
    fi

    jq -c --arg stage "${stage}" --argjson limit "${limit}" '
        def preview:
            if type == "string" then
                if length > $limit then .[0:$limit] + "[TRUNCATED]" else . end
            else . end;
        def step_summary($s):
            if ($s | type) == "object" then {
                id:($s.id // null),
                title:($s.title // null),
                executor_type:($s.executor_type // null),
                skill_script:($s.skill_script // null),
                mcp_server:($s.mcp_server // null),
                mcp_tool:($s.mcp_tool // null),
                risk_level:($s.risk_level // null),
                has_command:($s | has("command")),
                command_preview:(.command // "" | preview),
                argument_keys:(if (.arguments? | type) == "object" then (.arguments | keys) else null end),
                url:($s.url // $s.command // null | if type == "string" and test("^https://") then . else null end),
                sha256:($s.sha256 // null),
                size_bytes:($s.size_bytes // null),
                line_count:($s.line_count // null)
            } else null end;
        def result_summary($r):
            if ($r | type) == "object" then {
                ok:($r.ok // null),
                status:($r.status // null),
                exit_code:($r.exit_code // null),
                tool:($r.output.tool // $r.tool // null),
                action:($r.output.action // $r.action // null),
                output_preview:(
                    if ($r.output.raw? | type) == "string" then ($r.output.raw | preview)
                    elif ($r.stdout? | type) == "string" then ($r.stdout | preview)
                    elif ($r.output.summary? | type) == "string" then ($r.output.summary | preview)
                    elif ($r.output.message? | type) == "string" then ($r.output.message | preview)
                    elif ($r.output.error? | type) == "string" then ($r.output.error | preview)
                    elif ($r.output.action? | type) == "string" then ($r.output.action | preview)
                    else null end
                ),
                stderr_preview:(if ($r.stderr? | type) == "string" then ($r.stderr | preview) else null end),
                result_count:(if ($r.results? | type) == "array" then ($r.results | length) else null end),
                output_keys:(if ($r.output? | type) == "object" then ($r.output | keys) else null end),
                finding_count:(if ($r.findings? | type) == "array" then ($r.findings | length) else null end)
            } else null end;
        def fallback:
            if type == "object" then
                with_entries(
                    if (.value | type) == "string" then .value |= preview
                    elif (.value | type) == "array" then .value = {type:"array", length:(.value | length)}
                    elif (.value | type) == "object" then .value = {type:"object", keys:(.value | keys)}
                    else . end
                )
            else
                {value:(. | tostring | preview)}
            end;

        if ($stage == "command_started" or $stage == "command_finished") then
            {
                command:(.command // null),
                args_preview:(.args // "" | preview),
                status:(.status // null),
                exit_code:(.exit_code // null)
            }
        elif ($stage == "turn_started" or $stage == "turn_finished") then
            {
                mode:(.mode // null),
                input_preview:(.input // "" | preview),
                status:(.status // null)
            }
        elif $stage == "control_event" then
            {
                event:(.event // null),
                mode:(.mode // null),
                value_preview:(.value // "" | preview),
                status:(.status // null)
            }
        elif $stage == "ai_files_manifest" then
            {
                file_count:(.file_count // ((.files // []) | length)),
                files:[(.files // [])[] | {
                    relative_path:(.relative_path // null),
                    path:(.path // null),
                    purpose:(.purpose // null),
                    included_as:(.included_as // null),
                    exists:(.exists // null),
                    readable:(.readable // null),
                    size_bytes:(.size_bytes // null),
                    sha256:(.sha256 // null)
                }]
            }
        elif $stage == "received" then
            {
                mode:(.mode // null),
                input_preview:(.input // .command // .ref // "" | preview),
                ref:(.ref // null),
                argument_keys:(if (.arguments? | type) == "object" then (.arguments | keys) else null end)
            }
        elif $stage == "sensed" then
            {
                topic:(.topic // null),
                context_keys:(if type == "object" then keys else [] end)
            }
        elif $stage == "request_context_built" then
            {
                mode:(.mode // null),
                conversation_turns:(if (.conversation_context? | type) == "array" then (.conversation_context | length) else 0 end),
                environment_keys:(if (.environment_context? | type) == "object" then (.environment_context | keys) else [] end),
                disclosed_skill_count:(if (.skills.disclosed? | type) == "array" then (.skills.disclosed | length) else 0 end),
                disclosed_skills:[.skills.disclosed[]?.name],
                unavailable_skills:(.skills.unavailable // []),
                mcp_server_count:(.mcp.server_count // 0),
                mcp_tool_count:(.mcp.tool_count // 0),
                mcp_finding_count:(if (.mcp.findings? | type) == "array" then (.mcp.findings | length) else 0 end),
                fixed_context_excluded:(has("skill_index") | not),
                runtime_context_excluded:(has("environment_context") | not)
            }
        elif ($stage == "planned" or $stage == "repair_planned" or $stage == "revision_planned" or $stage == "agent_reflection_planned") then
            {
                response_type:(.response_type // null),
                summary_preview:(.summary // "" | preview),
                continue_decision:(.continue_decision // null),
                step_count:(if (.steps? | type) == "array" then (.steps | length) else 0 end),
                steps:[.steps[]? | step_summary(.)]
            }
        elif $stage == "agent_reflection_requested" then
            {
                iteration:(.iteration // null),
                execution_status:(.execution_status // null),
                result_count:(.result_count // null)
            }
        elif ($stage == "agent_loop_started" or $stage == "agent_loop_iteration_started" or $stage == "agent_checkpoint_requested" or $stage == "agent_checkpoint_decision" or $stage == "agent_loop_finished") then
            {
                mode:(.mode // null),
                iteration:(.iteration // null),
                iterations:(.iterations // null),
                checkpoint_turns:(.checkpoint_turns // null),
                max_iterations:(.max_iterations // null),
                approved:(.approved // null),
                status:(.status // null),
                stopped_reason:(.stopped_reason // null),
                auto_executed_count:(.auto_executed_count // null),
                plan_step_count:(if (.plan.steps? | type) == "array" then (.plan.steps | length) else null end)
            }
        elif $stage == "work_revision_requested" then
            {
                original_request_preview:(.original_request // "" | preview),
                revision_request_preview:(.revision_request // "" | preview),
                original_step_count:(if (.plan.steps? | type) == "array" then (.plan.steps | length) else 0 end),
                executed_count:(if (.executed_steps? | type) == "array" then (.executed_steps | length) else 0 end),
                skipped_step:step_summary(.skipped_step),
                remaining_step_count:(if (.remaining_steps? | type) == "array" then (.remaining_steps | length) else 0 end)
            }
        elif $stage == "edit_planned" then
            {
                response_type:(.response_type // null),
                skill:(.skill.name // null),
                script_count:(if (.scripts? | type) == "array" then (.scripts | length) else 0 end),
                notes_preview:(.notes // "" | preview)
            }
        elif $stage == "edit_revision_requested" then
            {
                skill:(.original_edit.skill.name // null),
                cancelled_script:(.cancelled_script // null),
                revision_request_preview:(.revision_request // "" | preview),
                script_count:(if (.original_edit.scripts? | type) == "array" then (.original_edit.scripts | length) else 0 end)
            }
        elif $stage == "script_manual_edit" then
            {
                skill:(.skill // null),
                script:(.script // null),
                diff_lines:(if (.diff? | type) == "string" then (.diff | split("\n") | length) else 0 end)
            }
        elif $stage == "step_policy_checked" then
            {
                step:step_summary(.step),
                review:((.detail // .review // {}) as $review | {
                    approved:($review.approved // null),
                    approval_required:($review.approval_required // null),
                    risk_level:($review.risk_level // null),
                    finding_count:(if ($review.findings? | type) == "array" then ($review.findings | length) else 0 end)
                })
            }
        elif $stage == "step_revision_requested" then
            {
                status:(.status // "revision_requested"),
                step:step_summary(.step),
                revision_request_preview:(.detail.revision_request // "" | preview),
                remaining_step_count:(.detail.remaining_step_count // null)
            }
        elif ($stage | startswith("step_")) then
            {
                status:(.status // ($stage | sub("^step_"; ""))),
                step:step_summary(.step),
                detail:result_summary(.detail),
                findings:(.detail.findings // [])
            }
        elif ($stage | startswith("observer_")) then
            {
                status:(.status // null),
                backend:(.backend // "auditd"),
                scope:(.scope // null),
                audit_key:(.audit_key // null),
                uid:(.uid // null),
                audit_uid:(.audit_uid // null),
                identity_filter:(.identity_filter // null),
                root_pid:(.root_pid // null),
                start_time:(.start_time // null),
                end_time:(.end_time // null),
                timed_out:(.timed_out // null),
                timeout_sec:(.timeout_sec // null),
                exec_count:(.exec_count // null),
                file_event_count:(.file_event_count // null),
                process_count:(if (.processes? | type) == "array" then (.processes | length) else 0 end),
                file_event_sample_count:(if (.file_events? | type) == "array" then (.file_events | length) else 0 end),
                sudo_available:(.sudo_available // null),
                sudo_authenticated:(.sudo_authenticated // null),
                sudo_exit_code:(.sudo_exit_code // null),
                auditctl_exit_code:(.auditctl_exit_code // null),
                reason_code:(.reason_code // null),
                reason:(.reason // null),
                diagnostic:(.diagnostic // null),
                notes:(.notes // [])
            }
        elif ($stage | startswith("file_vault_")) then
            {
                subject:(.subject // null),
                scope:(.scope // null),
                mode:(.mode // null),
                action:(.action // null),
                matched_path_count:(if (.matched_paths? | type) == "array" then (.matched_paths | length) else 0 end),
                observed_path_count:(if (.observed_paths? | type) == "array" then (.observed_paths | length) else 0 end),
                warning:(.warning // null)
            }
        elif ($stage == "executed" or $stage == "script_executed" or $stage == "terminal_executed" or $stage == "edit_applied") then
            result_summary(.)
            + {
                results:[.results[]? | {step:step_summary(.step), result:result_summary(.result)}],
                command_present:(has("command")),
                stdout_present:(has("stdout")),
                stderr_present:(has("stderr"))
            }
        else
            fallback
        end
    ' <<<"${payload}"
}

linux_agent_audit_payload() {
    local stage="$1"
    local payload="$2"
    local sanitized

    if [[ "$(linux_agent_audit_mode)" == "redacted_verbose" ]]; then
        sanitized="$(linux_agent_redact_json_full "${payload}")"
        if printf '%s' "${sanitized}" | jq -e . >/dev/null 2>&1; then
            printf '%s\n' "${sanitized}"
        else
            jq -cn --arg raw "${sanitized}" '{raw_preview:$raw}'
        fi
    else
        sanitized="$(linux_agent_sanitize_json "${payload}")"
        linux_agent_audit_safe_summary "${stage}" "${sanitized}"
    fi
}

linux_agent_start_session() {
    local user_input="$1"
    local boundary_summary entrypoint

    if [[ "${LINUX_AGENT_SESSION_ACTIVE:-0}" -eq 1 && "${LINUX_AGENT_SESSION_FINISHED:-0}" -eq 0 ]]; then
        return 0
    fi

    if [[ "${LINUX_AGENT_SESSION_MANAGED_EXTERNALLY:-0}" == "1" && -n "${LINUX_AGENT_SESSION_ID:-}" ]]; then
        LINUX_AGENT_AUDIT_LOG="${LINUX_AGENT_AUDIT_LOG:-${LINUX_AGENT_LOG_DIR}/${LINUX_AGENT_SESSION_ID}.jsonl}"
        mkdir -p "$(dirname "${LINUX_AGENT_AUDIT_LOG}")"
        touch "${LINUX_AGENT_AUDIT_LOG}"
        chmod 600 "${LINUX_AGENT_AUDIT_LOG}" 2>/dev/null || true
        if declare -F linux_agent_use_session_tmp_dir >/dev/null 2>&1; then
            linux_agent_use_session_tmp_dir "${LINUX_AGENT_SESSION_ID}"
        fi
        LINUX_AGENT_SESSION_ACTIVE=1
        LINUX_AGENT_SESSION_FINISHED=0
        if [[ -n "${LINUX_AGENT_REMOTE_PREFLIGHT:-}" ]] && jq -e 'type == "object"' <<<"${LINUX_AGENT_REMOTE_PREFLIGHT}" >/dev/null 2>&1; then
            linux_agent_audit_require_event "remote_bootstrap_verified" "${LINUX_AGENT_REMOTE_PREFLIGHT}" || return $?
        fi
        if declare -F linux_agent_observer_session_start >/dev/null 2>&1; then
            linux_agent_observer_session_start "session" "$(jq -cn --arg request "${user_input}" '{request:$request}')"
        fi
        return 0
    fi

    LINUX_AGENT_SESSION_ID="$(linux_agent_new_session_id)"
    if [[ -z "${LINUX_AGENT_REQUEST_ID:-}" ]]; then
        LINUX_AGENT_REQUEST_ID="req_${LINUX_AGENT_SESSION_ID}"
        export LINUX_AGENT_REQUEST_ID
    fi
    if declare -F linux_agent_use_session_tmp_dir >/dev/null 2>&1; then
        linux_agent_use_session_tmp_dir "${LINUX_AGENT_SESSION_ID}"
    fi
    LINUX_AGENT_AUDIT_LOG="${LINUX_AGENT_LOG_DIR}/${LINUX_AGENT_SESSION_ID}.jsonl"
    LINUX_AGENT_SESSION_ACTIVE=1
    LINUX_AGENT_SESSION_FINISHED=0

    : >"${LINUX_AGENT_AUDIT_LOG}"
    chmod 600 "${LINUX_AGENT_AUDIT_LOG}" 2>/dev/null || true
    boundary_summary="$(linux_agent_audit_boundary_runtime_summary)"
    if [[ "${LINUX_AGENT_WEB:-0}" == "1" ]]; then
        entrypoint="web"
    else
        entrypoint="cli"
    fi
    linux_agent_audit_require_event "session_started" "$(jq -cn \
        --arg request "${user_input}" \
        --arg entrypoint "${entrypoint}" \
        --arg audit_mode "$(linux_agent_audit_mode)" \
        --argjson audit_boundary "${boundary_summary}" \
        '{request:$request, entrypoint:$entrypoint, audit_mode:$audit_mode, audit_boundary:$audit_boundary}')" || return $?
    if [[ -n "${LINUX_AGENT_REMOTE_PREFLIGHT:-}" ]] && jq -e 'type == "object"' <<<"${LINUX_AGENT_REMOTE_PREFLIGHT}" >/dev/null 2>&1; then
        linux_agent_audit_require_event "remote_bootstrap_verified" "${LINUX_AGENT_REMOTE_PREFLIGHT}" || return $?
    fi
    if declare -F linux_agent_observer_session_start >/dev/null 2>&1; then
        linux_agent_observer_session_start "session" "$(jq -cn --arg request "${user_input}" '{request:$request}')"
    fi
}

# bin/agent reads LINUX_AGENT_LAST_BUSINESS_STATUS after this sourced function
# records the terminal business event.
# shellcheck disable=SC2034
linux_agent_log_event() {
    local stage="$1"
    local payload="${2:-}"
    local required="${3:-false}"
    local safe_payload event_execution_user
    [[ -n "${LINUX_AGENT_AUDIT_LOG:-}" ]] || return 0
    [[ -z "${payload}" ]] && payload='{}'
    if [[ "${stage}" == "finished" ]] && printf '%s' "${payload}" | jq -e . >/dev/null 2>&1; then
        LINUX_AGENT_LAST_BUSINESS_STATUS="$(jq -r '.status // empty' <<<"${payload}")"
    fi
    if [[ "${required}" != "true" ]] && ! linux_agent_audit_boundary_should_log_stage "${stage}"; then
        return 0
    fi
    if [[ -z "${LINUX_AGENT_SYSTEM_USER:-}" ]]; then
        LINUX_AGENT_SYSTEM_USER="$(id -un 2>/dev/null || printf 'unknown')"
    fi
    safe_payload="$(linux_agent_audit_payload "${stage}" "${payload}")"
    event_execution_user="$(jq -r '
        [.. | objects | .execution_proxy? // empty
         | .target_user // .execution_user // empty]
        | first // empty
    ' <<<"${safe_payload}" 2>/dev/null || true)"
    if [[ -z "${event_execution_user}" ]]; then
        event_execution_user="${LINUX_AGENT_EXECUTION_USER:-${LINUX_AGENT_SYSTEM_USER:-unknown}}"
    fi
    local event chain_rc=0
    event="$(jq -cn \
        --arg ts "$(linux_agent_now_iso)" \
        --arg session_id "${LINUX_AGENT_SESSION_ID}" \
        --arg stage "${stage}" \
        --arg request_id "${LINUX_AGENT_REQUEST_ID:-}" \
        --arg job_id "${LINUX_AGENT_JOB_ID:-}" \
        --arg system_user "${LINUX_AGENT_SYSTEM_USER:-unknown}" \
        --arg execution_user "${event_execution_user}" \
        --argjson payload "${safe_payload}" \
        '{
            schema_version:1,
            timestamp:$ts,
            session_id:$session_id,
            stage:$stage,
            request_id:$request_id,
            job_id:$job_id,
            system_user:$system_user,
            execution_user:$execution_user,
            payload:$payload
        }')"
    linux_agent_audit_write_event "${event}" || chain_rc=$?
    if ((chain_rc != 0)); then
        if ((chain_rc == 3)); then
            printf '[错误] 磁盘空间不足或无法确认可用空间，审计事件已被策略拒绝。\n' >&2
        else
            printf '[错误] 审计事件写入失败 (stage=%s, exit=%s)，已停止当前操作。\n' "${stage}" "${chain_rc}" >&2
        fi
        return "${chain_rc}"
    fi
    return 0
}

# Compliance-sensitive callers use this before executing a command or
# committing a durable mutation.  Unlike ordinary observational events, a
# required event cannot be disabled by the application-event display filter.
# Return codes intentionally preserve the writer contract:
#   3: audit.on_full=block refused the write
#   4: the existing chain is untrusted or the audit write failed
linux_agent_audit_require_event() {
    local stage="$1"
    local payload="${2:-}"
    [[ -n "${payload}" ]] || payload='{}'
    linux_agent_log_event "${stage}" "${payload}" true
}

linux_agent_audit_failure_result() {
    local audit_rc="${1:-4}"
    local stage="${2:-audit}"
    local code message retryable
    if [[ "${audit_rc}" -eq 3 ]]; then
        code="audit_write_blocked"
        message="审计空间策略拒绝写入，操作未执行。"
        retryable=true
    else
        code="audit_integrity_broken"
        message="审计链不可信或无法持久写入，操作未执行。"
        retryable=false
    fi
    jq -cn \
        --arg code "${code}" \
        --arg message "${message}" \
        --arg stage "${stage}" \
        --argjson exit_code "${audit_rc}" \
        --argjson retryable "${retryable}" '
        {
            ok:false,
            status:"blocked",
            code:$code,
            error_code:$code,
            error:$message,
            message:$message,
            retryable:$retryable,
            exit_code:$exit_code,
            details:{audit_stage:$stage}
        }'
}

linux_agent_log_step_status() {
    local step_json="$1"
    local status="$2"
    local detail="${3:-}"
    [[ -z "${detail}" ]] && detail='{}'

    local event_payload
    event_payload="$(jq -cn \
        --arg status "${status}" \
        --argjson step "${step_json}" \
        --argjson detail "${detail}" \
        '{status:$status, step:$step, detail:$detail}')"
    linux_agent_log_event "step_${status}" "${event_payload}"
}

linux_agent_finish_session() {
    local final_status="$1"
    if [[ "${LINUX_AGENT_SESSION_ACTIVE:-0}" -ne 1 || "${LINUX_AGENT_SESSION_FINISHED:-0}" -eq 1 ]]; then
        return 0
    fi
    LINUX_AGENT_SESSION_FINISHED=1
    if declare -F linux_agent_log_ai_files_manifest >/dev/null 2>&1; then
        linux_agent_log_ai_files_manifest
    fi
    if declare -F linux_agent_observer_session_finish >/dev/null 2>&1; then
        linux_agent_observer_session_finish "${final_status}"
    fi
    if [[ "${LINUX_AGENT_SESSION_MANAGED_EXTERNALLY:-0}" == "1" ]]; then
        LINUX_AGENT_SESSION_ACTIVE=0
        return 0
    fi
    linux_agent_log_event "session_finished" "$(jq -cn --arg status "${final_status}" '{status:$status}')"
    LINUX_AGENT_SESSION_ACTIVE=0
}

linux_agent_log_command_started() {
    local command="$1"
    local args="${2:-}"
    linux_agent_audit_require_event "command_started" "$(jq -cn --arg command "${command}" --arg args "${args}" '{command:$command, args:$args}')"
}

linux_agent_log_command_finished() {
    local command="$1"
    local status="$2"
    local exit_code="${3:-0}"
    linux_agent_log_event "command_finished" "$(jq -cn --arg command "${command}" --arg status "${status}" --argjson exit_code "${exit_code}" '{command:$command, status:$status, exit_code:$exit_code}')"
}

linux_agent_log_turn_started() {
    local mode="$1"
    local input="$2"
    linux_agent_audit_require_event "turn_started" "$(jq -cn --arg mode "${mode}" --arg input "${input}" '{mode:$mode, input:$input}')"
}

linux_agent_log_turn_finished() {
    local mode="$1"
    local status="$2"
    linux_agent_log_event "turn_finished" "$(jq -cn --arg mode "${mode}" --arg status "${status}" '{mode:$mode, status:$status}')"
}

linux_agent_log_control_event() {
    local event="$1"
    local mode="${2:-}"
    local value="${3:-}"
    local status="${4:-}"
    linux_agent_log_event "control_event" "$(jq -cn --arg event "${event}" --arg mode "${mode}" --arg value "${value}" --arg status "${status}" '{event:$event, mode:$mode, value:$value, status:$status}')"
}

linux_agent_show_audit() {
    local session_id="$1"
    local log_file="${2:-${LINUX_AGENT_LOG_DIR}/${session_id}.jsonl}"
    local report
    local -a log_segments=()

    if [[ -z "${session_id}" || ! "${session_id}" =~ ^[A-Za-z0-9._-]+$ ]]; then
        linux_agent_print_error "审计 session-id 非法。"
        return 1
    fi
    mapfile -t log_segments < <(linux_agent_audit_segment_paths "${log_file}" || true)
    if ((${#log_segments[@]} == 0)); then
        linux_agent_print_error "未找到审计日志: ${session_id}"
        return 1
    fi

    report="$(jq -s -r '
        def count_stage($s): map(select(.stage == $s)) | length;
        . as $events
        | ($events | map(select(.stage == "session_started")) | first) as $started
        | ($events | map(select(.stage == "session_finished")) | last) as $finished
        | ($events | map(select(.stage == "observer_session_finished")) | last) as $observer
        | "- 会话 ID: " + (($started.session_id // $finished.session_id // "unknown") | tostring),
          "- 开始时间: " + (($started.timestamp // "unknown") | tostring),
          "- 最终状态: " + (($finished.payload.status // $observer.payload.final_status // "unknown") | tostring),
          "- Observer 状态: " + (($observer.payload.status // "unknown") | tostring),
          "- Observer backend: " + (($observer.payload.backend // "auditd") | tostring),
          "- audit_key: " + (($observer.payload.audit_key // "null") | tostring),
          "- Observer reason_code: " + (($observer.payload.reason_code // "null") | tostring),
          "- Observer diagnostic: " + (($observer.payload.diagnostic // "null") | tostring),
          "- exec_count: " + (($observer.payload.exec_count // 0) | tostring),
          "- file_event_count: " + (($observer.payload.file_event_count // 0) | tostring),
          "- execution_finished: " + (($events | count_stage("execution_finished")) | tostring),
          "- observer_unavailable: " + (($events | count_stage("observer_unavailable")) | tostring),
          "- observer_failed: " + (($events | count_stage("observer_failed")) | tostring)
    ' "${log_segments[@]}")"
    printf '# 审计报告\n\n'
    linux_agent_sanitize_text "${report}"

    printf '\n# 事件时间线\n\n'
    jq -s -r '
        def stage_label($s):
            if $s == "session_started" then "会话开始"
            elif $s == "session_finished" then "会话结束"
            elif $s == "command_started" then "命令入口开始"
            elif $s == "command_finished" then "命令入口结束"
            elif $s == "received" then "收到请求"
            elif $s == "sensed" then "采集环境"
            elif $s == "request_context_built" then "构建模型上下文"
            elif $s == "planned" then "生成执行计划"
            elif $s == "step_policy_checked" then "策略审查"
            elif $s == "step_auto_approved" then "自动批准步骤"
            elif $s == "step_approval_required" then "等待人工审批"
            elif $s == "step_approved" then "批准步骤"
            elif $s == "step_running" then "开始执行步骤"
            elif $s == "step_succeeded" then "步骤执行成功"
            elif $s == "step_failed" then "步骤执行失败"
            elif $s == "step_blocked" then "步骤被阻断"
            elif $s == "step_rejected" then "步骤被拒绝"
            elif $s == "step_skipped_user" then "用户跳过步骤"
            elif $s == "step_skipped_unexecuted" then "后续步骤未执行"
            elif $s == "executed" then "工作流执行结果"
            elif $s == "terminal_executed" then "终端执行结果"
            elif $s == "script_executed" then "Skill 执行结果"
            elif $s == "finished" then "业务状态完成"
            elif ($s | startswith("observer_")) then "Observer 事件"
            elif ($s | startswith("file_vault_")) then "文件保险箱事件"
            elif ($s | startswith("agent_")) then "Agent 循环"
            else $s end;
        def step_name($p):
            ($p.step.title
             // $p.step.id
             // $p.step.skill_script
             // (if (($p.step.mcp_server // "") != "" and ($p.step.mcp_tool // "") != "") then ($p.step.mcp_server + "/" + $p.step.mcp_tool) else null end)
             // $p.step.command_preview
             // "");
        def result_text($d):
            [
                (if ($d.status // "") != "" then "状态=" + ($d.status | tostring) else empty end),
                (if ($d.exit_code // null) != null then "退出码=" + ($d.exit_code | tostring) else empty end),
                (if ($d.tool // "") != "" then "工具=" + ($d.tool | tostring) else empty end),
                (if ($d.action // "") != "" then "动作=" + ($d.action | tostring) else empty end),
                (if ($d.output_preview // "") != "" then "输出=" + ($d.output_preview | tostring) else empty end),
                (if ($d.stderr_preview // "") != "" then "错误=" + ($d.stderr_preview | tostring) else empty end)
            ] | join("；");
        def describe:
            .stage as $s
            | (.payload // {}) as $p
            | if $s == "session_started" then
                "入口=" + (($p.entrypoint // "cli") | tostring) + "；请求=" + (($p.request // "") | tostring)
              elif $s == "session_finished" or $s == "finished" or $s == "command_finished" then
                "状态=" + (($p.status // "unknown") | tostring)
              elif $s == "command_started" then
                "调用=" + (($p.command // "") | tostring) + "；参数=" + (($p.args_preview // $p.args // "") | tostring)
              elif $s == "received" then
                "模式=" + (($p.mode // "unknown") | tostring) + "；输入=" + (($p.input_preview // $p.command // $p.ref // "") | tostring)
              elif $s == "sensed" then
                "主题=" + (($p.topic // "unknown") | tostring) + "；上下文字段=" + ((($p.context_keys // []) | join(",")) | tostring)
              elif $s == "request_context_built" then
                "模式=" + (($p.mode // "unknown") | tostring) + "；当前请求=" + (($p.current_request_preview // "") | tostring)
              elif $s == "planned" or $s == "revision_planned" or $s == "repair_planned" then
                "摘要=" + (($p.summary_preview // "") | tostring) + "；步骤数=" + (($p.step_count // 0) | tostring)
              elif $s == "step_policy_checked" then
                "步骤=" + (step_name($p) | tostring) + "；风险=" + (($p.review.risk_level // "unknown") | tostring) + "；发现项=" + (($p.review.finding_count // 0) | tostring)
              elif ($s | startswith("step_")) then
                "步骤=" + (step_name($p) | tostring) + "；" + (result_text($p.detail // {}))
              elif $s == "executed" then
                "状态=" + (($p.status // "unknown") | tostring) + "；结果数=" + (($p.result_count // (($p.results // []) | length)) | tostring)
              elif $s == "terminal_executed" or $s == "script_executed" then
                result_text($p)
              elif ($s | startswith("observer_")) then
                "状态=" + (($p.status // "unknown") | tostring) + "；后端=" + (($p.backend // "auditd") | tostring) + "；exec=" + (($p.exec_count // 0) | tostring) + "；file=" + (($p.file_event_count // 0) | tostring)
              elif ($s | startswith("file_vault_")) then
                "模式=" + (($p.mode // "unknown") | tostring) + "；动作=" + (($p.action // "unknown") | tostring) + "；匹配文件数=" + ((if $s == "file_vault_observed" then ($p.observed_path_count // 0) else ($p.matched_path_count // 0) end) | tostring)
              else
                ($p.message // $p.status // $p.event // ($p | tostring))
              end;
        .[] | "- " + ((.timestamp // "--") | tostring) + " · " + stage_label(.stage // "event") + "： " + describe
    ' "${log_segments[@]}" | while IFS= read -r line; do
        linux_agent_sanitize_text "${line}"
    done

    printf '\n# JSONL 审计流\n\n'
    for log_file in "${log_segments[@]}"; do
        while IFS= read -r line; do
            linux_agent_sanitize_text "${line}"
        done <"${log_file}"
    done
}
