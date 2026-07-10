#!/usr/bin/env bash

set -euo pipefail

LINUX_AGENT_OBSERVER_SESSION_CONTEXT=""

linux_agent_observer_config_enabled() {
    local enabled="auto"
    if declare -F linux_agent_config_get_default >/dev/null 2>&1 && [[ -n "${LINUX_AGENT_CONFIG_JSON:-}" ]]; then
        enabled="$(linux_agent_config_get_default '.observer.enabled' 'auto')"
    fi
    case "${enabled}" in
        auto|auditd|disabled) printf '%s\n' "${enabled}" ;;
        *) printf 'auto\n' ;;
    esac
}

linux_agent_observer_privilege_mode() {
    local mode="sudo_interactive"
    if declare -F linux_agent_config_get_default >/dev/null 2>&1 && [[ -n "${LINUX_AGENT_CONFIG_JSON:-}" ]]; then
        mode="$(linux_agent_config_get_default '.observer.privilege' 'sudo_interactive')"
    fi
    case "${mode}" in
        sudo_interactive|passwordless|none) printf '%s\n' "${mode}" ;;
        *) printf 'sudo_interactive\n' ;;
    esac
}

linux_agent_observer_max_events() {
    local max_events="200"
    if declare -F linux_agent_config_get_default >/dev/null 2>&1 && [[ -n "${LINUX_AGENT_CONFIG_JSON:-}" ]]; then
        max_events="$(linux_agent_config_get_default '.observer.max_events' '200')"
    fi
    if [[ ! "${max_events}" =~ ^[0-9]+$ || "${max_events}" -le 0 ]]; then
        max_events=200
    fi
    if declare -F linux_agent_audit_boundary_observer_max_events >/dev/null 2>&1; then
        max_events="$(linux_agent_audit_boundary_observer_max_events "${max_events}")"
    fi
    printf '%s\n' "${max_events}"
}

linux_agent_observer_log_event() {
    local stage="$1"
    local payload="$2"
    if declare -F linux_agent_log_event >/dev/null 2>&1 && [[ -n "${LINUX_AGENT_AUDIT_LOG:-}" ]]; then
        linux_agent_log_event "${stage}" "${payload}"
    fi
}

linux_agent_observer_auditctl() {
    if [[ "$(id -u)" -eq 0 ]]; then
        auditctl "$@"
    else
        sudo -n auditctl "$@"
    fi
}

linux_agent_observer_ausearch() {
    if [[ "$(id -u)" -eq 0 ]]; then
        ausearch "$@"
    else
        sudo -n ausearch "$@"
    fi
}

linux_agent_observer_preflight() {
    local enabled privilege reason diagnostic reason_code sudo_exit_code auditctl_exit_code
    enabled="$(linux_agent_observer_config_enabled)"
    privilege="$(linux_agent_observer_privilege_mode)"

    if [[ "${enabled}" == "disabled" ]]; then
        jq -cn '{status:"disabled", backend:"auditd", available:false, reason_code:"observer_disabled", reason:"observer disabled by config", diagnostic:"observer.enabled is disabled in config"}'
        return 0
    fi
    if ! command -v auditctl >/dev/null 2>&1; then
        jq -cn '{status:"unavailable", backend:"auditd", available:false, reason_code:"auditctl_not_found", reason:"auditctl not found", diagnostic:"Install auditd/auditctl or disable observer."}'
        return 0
    fi
    if ! command -v ausearch >/dev/null 2>&1; then
        jq -cn '{status:"unavailable", backend:"auditd", available:false, reason_code:"ausearch_not_found", reason:"ausearch not found", diagnostic:"Install auditd/ausearch or disable observer."}'
        return 0
    fi

    if [[ "$(id -u)" -eq 0 ]]; then
        set +e
        reason="$(auditctl -s 2>&1 >/dev/null)"
        auditctl_exit_code=$?
        set -e
        if [[ "${auditctl_exit_code}" -eq 0 ]]; then
            jq -cn '{status:"available", backend:"auditd", available:true, privilege:"root", sudo_available:null, sudo_authenticated:null, auditctl_exit_code:0}'
        else
            reason_code="auditctl_failed"
            diagnostic="auditctl -s failed as root; auditd may be unavailable or the kernel audit interface may be restricted."
            if grep -qi 'operation not permitted' <<<"${reason}"; then
                reason_code="auditctl_permission_denied"
                diagnostic="auditctl was rejected by the kernel audit interface. This commonly happens in containers, WSL, or environments without CAP_AUDIT_CONTROL/auditd support."
            fi
            jq -cn --arg reason "${reason}" --arg reason_code "${reason_code}" --arg diagnostic "${diagnostic}" --argjson auditctl_exit_code "${auditctl_exit_code}" \
                '{status:"unavailable", backend:"auditd", available:false, privilege:"root", sudo_available:null, sudo_authenticated:null, auditctl_exit_code:$auditctl_exit_code, reason_code:$reason_code, reason:$reason, diagnostic:$diagnostic}'
        fi
        return 0
    fi

    if [[ "${privilege}" == "none" ]]; then
        jq -cn '{status:"unavailable", backend:"auditd", available:false, privilege:"none", sudo_available:null, sudo_authenticated:false, reason_code:"sudo_disabled", reason:"observer sudo privilege disabled", diagnostic:"observer.privilege is set to none."}'
        return 0
    fi
    if ! command -v sudo >/dev/null 2>&1; then
        jq -cn '{status:"unavailable", backend:"auditd", available:false, privilege:"none", sudo_available:false, sudo_authenticated:false, reason_code:"sudo_not_found", reason:"sudo not found for non-root auditd access", diagnostic:"Install sudo, run as root, or disable observer."}'
        return 0
    fi
    set +e
    reason="$(sudo -n true 2>&1 >/dev/null)"
    sudo_exit_code=$?
    set -e
    if [[ "${sudo_exit_code}" -ne 0 ]]; then
        if [[ "${privilege}" == "sudo_interactive" && -t 0 && -t 2 ]]; then
            printf '[信息] observer 需要 sudo 权限以启用 auditd 观察。\n' >&2
            set +e
            reason="$(sudo true 2>&1 >/dev/null)"
            sudo_exit_code=$?
            set -e
        fi
    fi
    set +e
    reason="$(sudo -n true 2>&1 >/dev/null)"
    sudo_exit_code=$?
    set -e
    if [[ "${sudo_exit_code}" -ne 0 ]]; then
        jq -cn --arg reason "${reason}" --argjson sudo_exit_code "${sudo_exit_code}" \
            '{status:"unavailable", backend:"auditd", available:false, privilege:"none", sudo_available:true, sudo_authenticated:false, sudo_exit_code:$sudo_exit_code, reason_code:"sudo_credential_unavailable", reason:($reason // "sudo credential is not available"), diagnostic:"sudo authentication is not currently available to observer; enter the password when prompted or configure passwordless observer access."}'
        return 0
    fi
    set +e
    reason="$(sudo -n auditctl -s 2>&1 >/dev/null)"
    auditctl_exit_code=$?
    set -e
    if [[ "${auditctl_exit_code}" -eq 0 ]]; then
        jq -cn --argjson sudo_exit_code "${sudo_exit_code}" \
            '{status:"available", backend:"auditd", available:true, privilege:"sudo", sudo_available:true, sudo_authenticated:true, sudo_exit_code:$sudo_exit_code, auditctl_exit_code:0}'
    else
        reason_code="auditctl_failed"
        diagnostic="sudo authentication succeeded, but auditctl -s failed; auditd may be unavailable or the kernel audit interface may be restricted."
        if grep -qi 'operation not permitted' <<<"${reason}"; then
            reason_code="auditctl_permission_denied"
            diagnostic="sudo authentication succeeded, but auditctl was rejected by the kernel audit interface. This commonly happens in containers, WSL, or environments without CAP_AUDIT_CONTROL/auditd support."
        fi
        jq -cn \
            --arg reason "${reason}" \
            --arg reason_code "${reason_code}" \
            --arg diagnostic "${diagnostic}" \
            --argjson sudo_exit_code "${sudo_exit_code}" \
            --argjson auditctl_exit_code "${auditctl_exit_code}" \
            '{status:"unavailable", backend:"auditd", available:false, privilege:"sudo", sudo_available:true, sudo_authenticated:true, sudo_exit_code:$sudo_exit_code, auditctl_exit_code:$auditctl_exit_code, reason_code:$reason_code, reason:$reason, diagnostic:$diagnostic}'
    fi
}

linux_agent_observer_key() {
    local scope="$1"
    local session="${LINUX_AGENT_SESSION_ID:-session}"
    local safe_scope
    safe_scope="$(printf '%s' "${scope}" | tr -c 'A-Za-z0-9_' '_' | cut -c 1-32)"
    printf 'linux_agent_%s_%s_%s\n' \
        "$(printf '%s' "${session}" | tr -c 'A-Za-z0-9_' '_' | cut -c 1-48)" \
        "${safe_scope:-scope}" \
        "${RANDOM}"
}

linux_agent_observer_audit_uid() {
    local uid login_uid
    uid="$(id -u)"
    if [[ -r /proc/self/loginuid ]] && read -r login_uid < /proc/self/loginuid; then
        if [[ "${login_uid}" =~ ^[0-9]+$ && "${login_uid}" != "4294967295" ]]; then
            printf '%s\n' "${login_uid}"
            return 0
        fi
    fi
    printf '%s\n' "${uid}"
}

linux_agent_observer_install_syscall_rule() {
    local audit_uid="$1"
    local key="$2"
    local syscall="$3"
    linux_agent_observer_auditctl -a always,exit -F arch=b64 -S "${syscall}" -F "auid=${audit_uid}" -k "${key}" >/dev/null 2>&1
}

linux_agent_observer_remove_syscall_rule() {
    local audit_uid="$1"
    local key="$2"
    local syscall="$3"
    linux_agent_observer_auditctl -d always,exit -F arch=b64 -S "${syscall}" -F "auid=${audit_uid}" -k "${key}" >/dev/null 2>&1
}

linux_agent_observer_session_start() {
    local scope="${1:-session}"
    local subject_json="${2:-}"
    local preflight key uid audit_uid start_time installed='[]' notes='[]' selected_syscalls boundary_summary
    [[ -n "${subject_json}" ]] || subject_json='{}'

    boundary_summary="$(linux_agent_audit_boundary_runtime_summary)"
    preflight="$(linux_agent_observer_preflight)"
    if [[ "$(jq -r '.status' <<<"${preflight}")" != "available" ]]; then
        LINUX_AGENT_OBSERVER_SESSION_CONTEXT="$(jq -cn \
            --arg scope "${scope}" \
            --argjson subject "${subject_json}" \
            --argjson preflight "${preflight}" \
            --argjson audit_boundary "${boundary_summary}" \
            --arg start_time "$(linux_agent_now_iso)" \
            '{status:$preflight.status, backend:"auditd", lifecycle:"session", scope:$scope, subject:$subject, start_time:$start_time, audit_boundary:$audit_boundary, reason:($preflight.reason // null), reason_code:($preflight.reason_code // null), diagnostic:($preflight.diagnostic // null), sudo_available:($preflight.sudo_available // null), sudo_authenticated:($preflight.sudo_authenticated // null), sudo_exit_code:($preflight.sudo_exit_code // null), auditctl_exit_code:($preflight.auditctl_exit_code // null), preflight:$preflight}')"
        linux_agent_observer_log_event "observer_unavailable" "${LINUX_AGENT_OBSERVER_SESSION_CONTEXT}"
        return 0
    fi

    selected_syscalls="$(linux_agent_audit_boundary_observer_syscalls | jq -R -s 'split("\n") | map(select(length > 0))')"
    if [[ "$(jq 'length' <<<"${selected_syscalls}")" -eq 0 ]]; then
        LINUX_AGENT_OBSERVER_SESSION_CONTEXT="$(jq -cn \
            --arg scope "${scope}" \
            --argjson subject "${subject_json}" \
            --argjson audit_boundary "${boundary_summary}" \
            --arg start_time "$(linux_agent_now_iso)" \
            '{status:"disabled", backend:"auditd", lifecycle:"session", scope:$scope, subject:$subject, start_time:$start_time, audit_boundary:$audit_boundary, reason_code:"audit_boundary_no_observer_syscalls", reason:"audit boundary selected no observer syscalls", diagnostic:"Add allowed syscalls to policies/audit-boundaries.json observing.observer_syscalls to enable auditd observer."}')"
        linux_agent_observer_log_event "observer_unavailable" "${LINUX_AGENT_OBSERVER_SESSION_CONTEXT}"
        return 0
    fi

    uid="$(id -u)"
    audit_uid="$(linux_agent_observer_audit_uid)"
    key="$(linux_agent_observer_key "${scope}")"
    start_time="$(linux_agent_now_iso)"

    local syscall

    while IFS= read -r syscall; do
        [[ -z "${syscall}" ]] && continue
        if linux_agent_observer_install_syscall_rule "${audit_uid}" "${key}" "${syscall}"; then
            installed="$(jq -cn --argjson prior "${installed}" --arg syscall "${syscall}" '$prior + [$syscall]')"
        else
            notes="$(jq -cn --argjson prior "${notes}" --arg syscall "${syscall}" '$prior + ["failed to install syscall rule: " + $syscall]')"
        fi
    done < <(jq -r '.[]' <<<"${selected_syscalls}")

    if [[ "$(jq 'length' <<<"${installed}")" -eq 0 ]]; then
        LINUX_AGENT_OBSERVER_SESSION_CONTEXT="$(jq -cn \
            --arg scope "${scope}" \
            --argjson subject "${subject_json}" \
            --arg audit_key "${key}" \
            --arg start_time "${start_time}" \
            --argjson notes "${notes}" \
            --argjson audit_boundary "${boundary_summary}" \
            '{status:"failed", backend:"auditd", lifecycle:"session", scope:$scope, subject:$subject, audit_key:$audit_key, start_time:$start_time, audit_boundary:$audit_boundary, notes:$notes}')"
        linux_agent_observer_log_event "observer_failed" "${LINUX_AGENT_OBSERVER_SESSION_CONTEXT}"
        return 0
    fi

    LINUX_AGENT_OBSERVER_SESSION_CONTEXT="$(jq -cn \
        --arg scope "${scope}" \
        --argjson subject "${subject_json}" \
        --arg audit_key "${key}" \
        --arg uid "${uid}" \
        --arg audit_uid "${audit_uid}" \
        --arg start_time "${start_time}" \
        --argjson installed_syscalls "${installed}" \
        --argjson notes "${notes}" \
        --argjson audit_boundary "${boundary_summary}" \
        '{status:"running", backend:"auditd", lifecycle:"session", scope:$scope, subject:$subject, audit_key:$audit_key, uid:($uid|tonumber), audit_uid:($audit_uid|tonumber), identity_filter:"auid", start_time:$start_time, installed_syscalls:$installed_syscalls, audit_boundary:$audit_boundary, notes:$notes}')"
    linux_agent_observer_log_event "observer_session_started" "${LINUX_AGENT_OBSERVER_SESSION_CONTEXT}"
}

linux_agent_observer_parse_ausearch() {
    local raw="$1"
    local audit_key="$2"
    local max_events include_exec_count=false include_file_event_count=false include_processes=false include_file_events=false
    max_events="$(linux_agent_observer_max_events)"
    if linux_agent_audit_boundary_observer_field_enabled "exec_count"; then
        include_exec_count=true
    fi
    if linux_agent_audit_boundary_observer_field_enabled "file_event_count"; then
        include_file_event_count=true
    fi
    if linux_agent_audit_boundary_observer_field_enabled "processes"; then
        include_processes=true
    fi
    if linux_agent_audit_boundary_observer_field_enabled "file_events"; then
        include_file_events=true
    fi
    jq -Rn \
        --arg audit_key "${audit_key}" \
        --argjson include_exec_count "${include_exec_count}" \
        --argjson include_file_event_count "${include_file_event_count}" \
        --argjson include_processes "${include_processes}" \
        --argjson include_file_events "${include_file_events}" \
        --argjson max_events "${max_events}" '
        def field($name):
            (try capture("(^|[[:space:]])" + $name + "=(?<v>\"[^\"]*\"|[^[:space:]]+)").v catch null)
            | if . == null then null else gsub("^\"|\"$"; "") end;
        def event_type:
            (try capture("^type=(?<t>[^[:space:]]+)").t catch null) // "UNKNOWN";
        def record_id:
            (try capture("msg=audit\\([^:]+:(?<id>[0-9]+)\\)").id catch null);
        def event_key($prefix):
            if .record_id != null then .record_id
            else ([$prefix, .raw_type, .pid, .ppid, .syscall, .name, .comm, .exe] | map(. // "") | join(":"))
            end;
        def is_exec_syscall:
            .syscall == "59" or .syscall == "322" or .syscall == "execve" or .syscall == "execveat";
        def is_file_syscall:
            (.syscall // "") as $syscall
            | [
                "2", "257", "437", "85", "76", "77", "82", "264", "316",
                "87", "263", "90", "91", "268", "92", "93", "260", "83",
                "258", "84", "88", "266", "86", "265",
                "open", "openat", "openat2", "creat", "truncate", "ftruncate",
                "rename", "renameat", "renameat2", "unlink", "unlinkat",
                "chmod", "fchmod", "fchmodat", "chown", "fchown", "fchownat",
                "mkdir", "mkdirat", "rmdir", "symlink", "symlinkat", "link", "linkat"
              ] | index($syscall);
        [inputs | select(length > 0) | {
            raw_type:event_type,
            record_id:record_id,
            pid:(field("pid") // null),
            ppid:(field("ppid") // null),
            comm:(field("comm") // null),
            exe:(field("exe") // null),
            syscall:(field("syscall") // null),
            success:(field("success") // null),
            name:(field("name") // null),
            key:(field("key") // $audit_key)
        }] as $events
        | ($events | map(select(.raw_type == "EXECVE" or (.raw_type == "SYSCALL" and is_exec_syscall)))) as $exec_events
        | ($events | map(select(.name != null or .raw_type == "PATH" or (.raw_type == "SYSCALL" and is_file_syscall)))) as $file_events
        | {
            status:"observed",
            backend:"auditd",
            audit_key:$audit_key,
            exec_count:(if $include_exec_count then ($exec_events | map(event_key("exec")) | unique | length) else null end),
            file_event_count:(if $include_file_event_count then ($file_events | map(event_key("file")) | unique | length) else null end),
            processes:(if $include_processes then ($events
                | map(select(.pid != null) | {pid:(.pid|tonumber?), ppid:(.ppid|tonumber?), comm, exe})
                | unique_by(.pid, .comm, .exe)
                | .[0:$max_events]) else [] end),
            file_events:(if $include_file_events then ($events
                | map(select(.name != null) | {name, syscall, success})
                | unique_by(.name, .syscall, .success)
                | .[0:$max_events]) else [] end)
        }
    ' <<<"${raw}"
}

linux_agent_observer_session_finish() {
    local final_status="${1:-unknown}"
    local context_json="${LINUX_AGENT_OBSERVER_SESSION_CONTEXT:-}"
    local status end_time audit_key audit_uid installed cleanup_notes notes raw parsed query_status
    [[ -n "${context_json}" ]] || return 0

    status="$(jq -r '.status // "unknown"' <<<"${context_json}")"
    end_time="$(linux_agent_now_iso)"
    if [[ "${status}" != "running" ]]; then
        local done_context
        done_context="$(jq -c --arg end_time "${end_time}" --arg final_status "${final_status}" \
            '. + {end_time:$end_time, final_status:$final_status}' <<<"${context_json}")"
        linux_agent_observer_log_event "observer_session_finished" "${done_context}"
        LINUX_AGENT_OBSERVER_SESSION_CONTEXT=""
        return 0
    fi

    audit_key="$(jq -r '.audit_key' <<<"${context_json}")"
    audit_uid="$(jq -r '.audit_uid // .uid' <<<"${context_json}")"
    installed="$(jq -c '.installed_syscalls // []' <<<"${context_json}")"
    cleanup_notes='[]'

    while IFS= read -r syscall; do
        [[ -z "${syscall}" ]] && continue
        if ! linux_agent_observer_remove_syscall_rule "${audit_uid}" "${audit_key}" "${syscall}"; then
            cleanup_notes="$(jq -cn --argjson prior "${cleanup_notes}" --arg syscall "${syscall}" '$prior + ["failed to remove syscall rule: " + $syscall]')"
        fi
    done < <(jq -r '.[]' <<<"${installed}")

    query_status=0
    raw="$(linux_agent_observer_ausearch -k "${audit_key}" 2>&1)" || query_status=$?
    if [[ "${query_status}" -ne 0 ]]; then
        notes="$(jq -cn --argjson prior "$(jq -c '.notes // []' <<<"${context_json}")" --arg raw "$(linux_agent_sanitize_text "${raw}" 500)" --argjson cleanup "${cleanup_notes}" \
            '$prior + $cleanup + ["ausearch failed: " + $raw]')"
        local failed
        failed="$(jq -cn \
            --arg audit_key "${audit_key}" \
            --arg start_time "$(jq -r '.start_time' <<<"${context_json}")" \
            --arg end_time "${end_time}" \
            --arg final_status "${final_status}" \
            --argjson notes "${notes}" \
            '{status:"failed", backend:"auditd", lifecycle:"session", audit_key:$audit_key, start_time:$start_time, end_time:$end_time, final_status:$final_status, exec_count:0, file_event_count:0, processes:[], file_events:[], notes:$notes}')"
        linux_agent_observer_log_event "observer_failed" "${failed}"
        linux_agent_observer_log_event "observer_session_finished" "${failed}"
        LINUX_AGENT_OBSERVER_SESSION_CONTEXT=""
        return 0
    fi

    parsed="$(linux_agent_observer_parse_ausearch "${raw}" "${audit_key}")"
    notes="$(jq -cn --argjson prior "$(jq -c '.notes // []' <<<"${context_json}")" --argjson cleanup "${cleanup_notes}" '$prior + $cleanup')"
    parsed="$(jq -c \
        --arg start_time "$(jq -r '.start_time' <<<"${context_json}")" \
        --arg end_time "${end_time}" \
        --arg final_status "${final_status}" \
        --argjson notes "${notes}" \
        '. + {lifecycle:"session", start_time:$start_time, end_time:$end_time, final_status:$final_status, notes:$notes}' <<<"${parsed}")"
    linux_agent_observer_log_event "observer_session_finished" "${parsed}"
    LINUX_AGENT_OBSERVER_SESSION_CONTEXT=""
}

linux_agent_run_observed_process() {
    local scope="$1"
    local subject_json="$2"
    local stdout_file="$3"
    local stderr_file="$4"
    shift 4
    [[ "${1:-}" == "--" ]] && shift

    local pid exit_code start_time end_time observer_marker
    start_time="$(linux_agent_now_iso)"
    set +e
    "$@" >"${stdout_file}" 2>"${stderr_file}" &
    pid=$!
    linux_agent_observer_log_event "execution_started" "$(jq -cn \
        --arg scope "${scope}" \
        --argjson subject "${subject_json}" \
        --arg start_time "${start_time}" \
        --argjson root_pid "${pid}" \
        '{scope:$scope, subject:$subject, start_time:$start_time, root_pid:$root_pid}')"
    wait "${pid}"
    exit_code=$?
    set -e
    end_time="$(linux_agent_now_iso)"
    observer_marker="$(jq -cn \
        --arg scope "${scope}" \
        --argjson subject "${subject_json}" \
        --arg start_time "${start_time}" \
        --arg end_time "${end_time}" \
        --argjson root_pid "${pid}" \
        --argjson exit_code "${exit_code}" \
        --argjson session_observer "${LINUX_AGENT_OBSERVER_SESSION_CONTEXT:-null}" \
        '{status:"recorded", backend:"auditd", lifecycle:"execution", scope:$scope, subject:$subject, start_time:$start_time, end_time:$end_time, root_pid:$root_pid, exit_code:$exit_code, session_audit_key:($session_observer.audit_key // null), session_status:($session_observer.status // null)}')"
    linux_agent_observer_log_event "execution_finished" "${observer_marker}"
    jq -cn \
        --argjson exit_code "${exit_code}" \
        --argjson root_pid "${pid}" \
        --argjson observer "${observer_marker}" \
        '{exit_code:$exit_code, root_pid:$root_pid, observer:$observer}'
}
