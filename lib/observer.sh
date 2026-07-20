#!/usr/bin/env bash

set -euo pipefail

LINUX_AGENT_OBSERVER_SESSION_CONTEXT=""
LINUX_AGENT_OBSERVER_HELPER_CAPABILITY=""

linux_agent_observer_config_enabled() {
    local enabled="auto"
    if declare -F linux_agent_config_get_default >/dev/null 2>&1 && [[ -n "${LINUX_AGENT_CONFIG_JSON:-}" ]]; then
        enabled="$(linux_agent_config_get_default '.observer.enabled' 'auto')"
    fi
    case "${enabled}" in
        auto | auditd | disabled) printf '%s\n' "${enabled}" ;;
        *) printf 'auto\n' ;;
    esac
}

linux_agent_observer_privilege_mode() {
    local mode="sudo_interactive"
    if declare -F linux_agent_config_get_default >/dev/null 2>&1 && [[ -n "${LINUX_AGENT_CONFIG_JSON:-}" ]]; then
        mode="$(linux_agent_config_get_default '.observer.privilege' 'sudo_interactive')"
    fi
    case "${mode}" in
        sudo_interactive | passwordless | none) printf '%s\n' "${mode}" ;;
        *) printf 'sudo_interactive\n' ;;
    esac
}

linux_agent_observer_helper_socket() {
    printf '%s\n' "${LINUX_AGENT_OBSERVER_HELPER_SOCKET:-/run/linux-agent/observer.sock}"
}

linux_agent_observer_helper_available() {
    local socket_path helper_path
    socket_path="$(linux_agent_observer_helper_socket)"
    helper_path="${LINUX_AGENT_ROOT}/lib/observer_helper.py"
    [[ "${socket_path}" == /* && -S "${socket_path}" && -f "${helper_path}" ]] &&
        command -v python3 >/dev/null 2>&1
}

linux_agent_observer_helper_request() {
    local operation="$1"
    shift
    local -a capability_args=()
    local socket_path
    socket_path="$(linux_agent_observer_helper_socket)"
    linux_agent_observer_helper_available || return 127
    if [[ "${operation}" != "status" ]]; then
        [[ "${LINUX_AGENT_OBSERVER_HELPER_CAPABILITY:-}" =~ ^[0-9a-f]{64}$ ]] || return 126
        capability_args=(--capability "${LINUX_AGENT_OBSERVER_HELPER_CAPABILITY}")
    fi
    python3 "${LINUX_AGENT_ROOT}/lib/observer_helper.py" request \
        --socket "${socket_path}" "${operation}" "$@" "${capability_args[@]}"
}

linux_agent_observer_new_helper_capability() {
    python3 -c 'import secrets; print(secrets.token_hex(32))'
}

linux_agent_observer_release_helper_key() {
    local key="$1"
    [[ -n "${key}" && -n "${LINUX_AGENT_OBSERVER_HELPER_CAPABILITY:-}" ]] || return 0
    linux_agent_observer_helper_available || return 0
    linux_agent_observer_helper_request release_key --key "${key}" >/dev/null 2>&1 || true
}

linux_agent_observer_close_helper_session() {
    linux_agent_observer_release_helper_key "${1:-}"
    LINUX_AGENT_OBSERVER_HELPER_CAPABILITY=""
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

# Strict-compliance switch: when true, execution is refused if the auditd
# observer is not actively observing this session. Default false (degrade).
linux_agent_observer_require_enabled() {
    [[ -n "${LINUX_AGENT_CONFIG_JSON:-}" ]] || return 1

    # Normal startup rejects this in linux_agent_load_config. Treat an invalid
    # in-memory override as required as a defense-in-depth fail-closed posture.
    if declare -F linux_agent_config_validate_observer_require >/dev/null 2>&1 &&
        ! linux_agent_config_validate_observer_require "${LINUX_AGENT_CONFIG_JSON}"; then
        return 0
    fi
    jq -e '.observer.require == true' >/dev/null 2>&1 <<<"${LINUX_AGENT_CONFIG_JSON}"
}

# Execution gates are normally invoked inside command substitution, so a
# failed-context assignment in the gate's subshell cannot update its parent.
# Persist only the fail-closed transition in the session temp directory and
# treat it as an authoritative overlay for subsequent gates and cleanup.
linux_agent_observer_failed_context_path() {
    local tmp_dir="${LINUX_AGENT_TMP_DIR:-}"
    local session_id="${LINUX_AGENT_SESSION_ID:-}"
    local safe_session
    [[ -n "${tmp_dir}" && -n "${session_id}" ]] || return 1
    safe_session="$(printf '%s' "${session_id}" | tr -c 'A-Za-z0-9_.-' '_' | cut -c 1-96)"
    [[ -n "${safe_session}" ]] || return 1
    printf '%s/observer-%s.failed.json\n' "${tmp_dir}" "${safe_session}"
}

linux_agent_observer_current_context() {
    local context_json="${LINUX_AGENT_OBSERVER_SESSION_CONTEXT:-}"
    local failed_path
    if failed_path="$(linux_agent_observer_failed_context_path)" && [[ -e "${failed_path}" || -L "${failed_path}" ]]; then
        if [[ -f "${failed_path}" && ! -L "${failed_path}" ]] &&
            jq -e 'type == "object" and .status == "failed"' "${failed_path}" >/dev/null 2>&1; then
            cat "${failed_path}"
            return 0
        fi
        jq -cn '{status:"failed", available:false, reason_code:"observer_runtime_context_invalid", reason:"persisted observer failure context is invalid"}'
        return 0
    fi
    printf '%s\n' "${context_json}"
}

linux_agent_observer_persist_failed_context() {
    local context_json="$1"
    local failed_path temp_path previous_umask
    jq -e 'type == "object" and .status == "failed"' >/dev/null 2>&1 <<<"${context_json}" || return 1
    failed_path="$(linux_agent_observer_failed_context_path)" || return 1
    mkdir -p "$(dirname "${failed_path}")"
    previous_umask="$(umask)"
    umask 077
    if ! temp_path="$(mktemp "${failed_path}.tmp.XXXXXX")"; then
        umask "${previous_umask}"
        return 1
    fi
    if ! printf '%s\n' "${context_json}" >"${temp_path}" ||
        ! chmod 600 "${temp_path}" ||
        ! mv -f "${temp_path}" "${failed_path}"; then
        rm -f "${temp_path}"
        umask "${previous_umask}"
        return 1
    fi
    umask "${previous_umask}"
}

linux_agent_observer_clear_failed_context() {
    local failed_path
    failed_path="$(linux_agent_observer_failed_context_path)" || return 0
    if [[ -e "${failed_path}" || -L "${failed_path}" ]]; then
        rm -f "${failed_path}"
    fi
}

# True only when the current session's observer actually installed auditd rules
# (session context status == "running"). Any other status (unavailable /
# disabled / failed / unset) means execution is not being observed.
linux_agent_observer_is_observing() {
    local ctx
    ctx="$(linux_agent_observer_current_context)"
    [[ -n "${ctx}" ]] || return 1
    [[ "$(jq -r '.status // ""' <<<"${ctx}" 2>/dev/null)" == "running" ]]
}

# Print a structured block result and return non-zero when strict compliance is
# enabled but this session is not fully observed. Callers use the return status
# before starting any real process; the command wrapper also calls this as a
# defense-in-depth guard for direct execution paths.
linux_agent_observer_execution_gate() {
    local scope="${1:-execution}"
    local subject_json="${2:-}"
    local observer_ctx observer_status payload runtime_verification audit_rc

    if ! linux_agent_observer_require_enabled; then
        return 0
    fi

    [[ -n "${subject_json}" ]] || subject_json='{}'
    if ! jq -e . >/dev/null 2>&1 <<<"${subject_json}"; then
        subject_json='{}'
    fi
    observer_ctx="$(linux_agent_observer_current_context)"
    if [[ -z "${observer_ctx}" ]] || ! jq -e . >/dev/null 2>&1 <<<"${observer_ctx}"; then
        observer_ctx='{}'
    fi

    observer_status="$(jq -r '.status // ""' <<<"${observer_ctx}")"
    if [[ "${observer_status}" == "running" ]]; then
        runtime_verification="$(linux_agent_observer_runtime_verify "${observer_ctx}")"
        if [[ "$(jq -r '.ok // false' <<<"${runtime_verification}")" == "true" ]]; then
            return 0
        fi
        observer_ctx="$(jq -c \
            --argjson verification "${runtime_verification}" \
            '. + {
                status:"failed",
                available:false,
                reason_code:($verification.reason_code // "observer_runtime_verification_failed"),
                reason:($verification.reason // "strict observer runtime verification failed"),
                runtime_verification:$verification
            }' <<<"${observer_ctx}")"
        LINUX_AGENT_OBSERVER_SESSION_CONTEXT="${observer_ctx}"
        linux_agent_observer_persist_failed_context "${observer_ctx}" || true
    fi

    payload="$(jq -cn \
        --arg scope "${scope}" \
        --argjson subject "${subject_json}" \
        --argjson observer "${observer_ctx}" \
        '{scope:$scope, subject:$subject, error_code:"observer_required_unavailable", status:($observer.status // null), observer_status:($observer.status // null), reason_code:($observer.reason_code // null)}')"
    audit_rc=0
    if declare -F linux_agent_audit_require_event >/dev/null 2>&1; then
        linux_agent_audit_require_event "observer_required_unavailable" "${payload}" || audit_rc=$?
    else
        linux_agent_observer_log_event "observer_required_unavailable" "${payload}" || audit_rc=$?
    fi
    if ((audit_rc != 0)); then
        if declare -F linux_agent_audit_failure_result >/dev/null 2>&1; then
            linux_agent_audit_failure_result "${audit_rc}" "observer_required_unavailable"
        else
            jq -cn --argjson exit_code "${audit_rc}" '
                {ok:false, status:"blocked", code:"audit_integrity_broken", error_code:"audit_integrity_broken", exit_code:$exit_code, output:{raw:"审计事件无法持久写入，操作未执行。"}}'
        fi
        return 1
    fi
    jq -cn \
        --argjson observer "${observer_ctx}" \
        '{ok:false, status:"blocked", error_code:"observer_required_unavailable", exit_code:126, output:{raw:"observer.require 已启用，但 auditd observer 未在观察本次执行，已拒绝执行该步骤。"}, observer:$observer}'
    return 1
}

linux_agent_observer_log_event() {
    local stage="$1"
    local payload="$2"
    if declare -F linux_agent_log_event >/dev/null 2>&1 && [[ -n "${LINUX_AGENT_AUDIT_LOG:-}" ]]; then
        linux_agent_log_event "${stage}" "${payload}"
    fi
}

linux_agent_observer_auditctl() {
    if linux_agent_observer_helper_available; then
        case "$*" in
            -s) linux_agent_observer_helper_request status ;;
            -l) linux_agent_observer_helper_request list_rules ;;
            *)
                printf 'observer helper rejected an unstructured auditctl request\n' >&2
                return 126
                ;;
        esac
        return
    fi
    if [[ "$(id -u)" -eq 0 ]]; then
        auditctl "$@"
    else
        sudo -n auditctl "$@"
    fi
}

linux_agent_observer_ausearch() {
    if linux_agent_observer_helper_available; then
        if [[ "$#" -eq 2 && "$1" == "-k" ]]; then
            linux_agent_observer_helper_request search_key --key "$2"
            return
        fi
        printf 'observer helper rejected an unstructured ausearch request\n' >&2
        return 126
    fi
    if [[ "$(id -u)" -eq 0 ]]; then
        ausearch "$@"
    else
        sudo -n ausearch "$@"
    fi
}

linux_agent_observer_list_rules() {
    local audit_key="$1"
    if linux_agent_observer_helper_available; then
        linux_agent_observer_helper_request list_rules --key "${audit_key}"
        return
    fi
    linux_agent_observer_auditctl -l
}

linux_agent_observer_preflight() {
    local enabled privilege reason diagnostic reason_code sudo_exit_code auditctl_exit_code
    enabled="$(linux_agent_observer_config_enabled)"
    privilege="$(linux_agent_observer_privilege_mode)"

    if [[ "${enabled}" == "disabled" ]]; then
        jq -cn '{status:"disabled", backend:"auditd", available:false, reason_code:"observer_disabled", reason:"observer disabled by config", diagnostic:"observer.enabled is disabled in config"}'
        return 0
    fi
    if [[ "${privilege}" == "none" ]]; then
        jq -cn '{status:"unavailable", backend:"auditd", available:false, privilege:"none", sudo_available:null, sudo_authenticated:false, reason_code:"observer_privilege_disabled", reason:"observer privileged access disabled", diagnostic:"observer.privilege is set to none; neither the privileged helper nor sudo will be used."}'
        return 0
    fi
    if linux_agent_observer_helper_available; then
        set +e
        reason="$(linux_agent_observer_auditctl -s 2>&1 >/dev/null)"
        auditctl_exit_code=$?
        set -e
        if [[ "${auditctl_exit_code}" -eq 0 ]]; then
            jq -cn '{status:"available", backend:"auditd", available:true, privilege:"helper", sudo_available:null, sudo_authenticated:null, auditctl_exit_code:0}'
        else
            jq -cn --arg reason "${reason}" --argjson auditctl_exit_code "${auditctl_exit_code}" \
                '{status:"unavailable", backend:"auditd", available:false, privilege:"helper", sudo_available:null, sudo_authenticated:null, auditctl_exit_code:$auditctl_exit_code, reason_code:"observer_helper_failed", reason:$reason, diagnostic:"The privileged observer helper socket exists but its auditd preflight failed; execution will not fall back to sudo."}'
        fi
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

# Match one complete rule emitted by `auditctl -l`. Observer installs one b64
# always/exit rule per syscall, filtered by login uid and the session key. The
# listing may render the key as either `-F key=...` or `-k ...`, and may combine
# several syscall names after one `-S` token.
linux_agent_observer_rule_is_listed() {
    local listing="$1"
    local audit_key="$2"
    local audit_uid="$3"
    local syscall="$4"

    awk \
        -v expected_key="${audit_key}" \
        -v expected_uid="${audit_uid}" \
        -v expected_syscall="${syscall}" '
        function contains_syscall(value, expected, count, names, i) {
            count = split(value, names, ",")
            for (i = 1; i <= count; i += 1) {
                if (names[i] == expected) {
                    return 1
                }
            }
            return 0
        }
        {
            action = 0
            arch = 0
            uid = 0
            key = 0
            syscall = 0
            for (i = 1; i <= NF; i += 1) {
                if ($i == "-a" && $(i + 1) == "always,exit") {
                    action = 1
                } else if ($i == "-F" && $(i + 1) == "arch=b64") {
                    arch = 1
                } else if ($i == "-F" && $(i + 1) == "auid=" expected_uid) {
                    uid = 1
                } else if ($i == "-F" && $(i + 1) == "key=" expected_key) {
                    key = 1
                } else if ($i == "-k" && $(i + 1) == expected_key) {
                    key = 1
                } else if ($i == "-S" && contains_syscall($(i + 1), expected_syscall)) {
                    syscall = 1
                }
            }
            if (action && arch && uid && key && syscall) {
                found = 1
            }
        }
        END { exit(found ? 0 : 1) }
    ' <<<"${listing}"
}

# Revalidate a cached running context immediately before every strict-mode
# execution. This intentionally never repairs or reinstalls rules: a daemon or
# rule failure is a compliance boundary and must fail closed for the caller.
linux_agent_observer_runtime_verify() {
    local context_json="$1"
    local preflight audit_key audit_uid installed_syscalls listing diagnostic syscall
    local auditctl_exit_code missing_syscalls='[]'

    if ! jq -e '
        type == "object"
        and .status == "running"
        and (.audit_key | type == "string" and test("^[A-Za-z0-9_.-]+$"))
        and ((.audit_uid // .uid) | type == "number")
        and (.installed_syscalls | type == "array" and length > 0)
        and all(.installed_syscalls[]; type == "string" and test("^[A-Za-z0-9_]+$"))
    ' >/dev/null 2>&1 <<<"${context_json}"; then
        jq -cn '{ok:false, status:"failed", phase:"context", reason_code:"observer_runtime_context_invalid", reason:"cached observer context is incomplete or invalid"}'
        return 0
    fi

    preflight="$(linux_agent_observer_preflight)"
    if [[ "$(jq -r '.status // ""' <<<"${preflight}")" != "available" ]]; then
        jq -cn \
            --argjson preflight "${preflight}" \
            '{
                ok:false,
                status:"failed",
                phase:"preflight",
                reason_code:($preflight.reason_code // "observer_runtime_preflight_failed"),
                reason:($preflight.reason // "observer runtime preflight failed"),
                preflight:$preflight
            }'
        return 0
    fi

    audit_key="$(jq -r '.audit_key' <<<"${context_json}")"
    audit_uid="$(jq -r '(.audit_uid // .uid) | tostring' <<<"${context_json}")"
    installed_syscalls="$(jq -c '.installed_syscalls' <<<"${context_json}")"

    set +e
    listing="$(linux_agent_observer_list_rules "${audit_key}" 2>&1)"
    auditctl_exit_code=$?
    set -e
    if [[ "${auditctl_exit_code}" -ne 0 ]]; then
        diagnostic="${listing}"
        if declare -F linux_agent_sanitize_text >/dev/null 2>&1; then
            diagnostic="$(linux_agent_sanitize_text "${listing}" 500)"
        fi
        jq -cn \
            --arg diagnostic "${diagnostic}" \
            --argjson auditctl_exit_code "${auditctl_exit_code}" \
            --argjson preflight "${preflight}" \
            '{
                ok:false,
                status:"failed",
                phase:"rule_listing",
                reason_code:"observer_rule_list_failed",
                reason:"auditctl -l failed during strict observer runtime verification",
                diagnostic:$diagnostic,
                auditctl_exit_code:$auditctl_exit_code,
                preflight:$preflight
            }'
        return 0
    fi

    while IFS= read -r syscall; do
        [[ -z "${syscall}" ]] && continue
        if ! linux_agent_observer_rule_is_listed "${listing}" "${audit_key}" "${audit_uid}" "${syscall}"; then
            missing_syscalls="$(jq -cn \
                --argjson prior "${missing_syscalls}" \
                --arg syscall "${syscall}" \
                '$prior + [$syscall]')"
        fi
    done < <(jq -r '.[]' <<<"${installed_syscalls}")

    if [[ "$(jq 'length' <<<"${missing_syscalls}")" -gt 0 ]]; then
        jq -cn \
            --arg audit_key "${audit_key}" \
            --arg audit_uid "${audit_uid}" \
            --argjson checked_syscalls "${installed_syscalls}" \
            --argjson missing_syscalls "${missing_syscalls}" \
            --argjson preflight "${preflight}" \
            '{
                ok:false,
                status:"failed",
                phase:"rule_verification",
                reason_code:"observer_rule_missing",
                reason:"one or more strict observer auditd rules are no longer installed",
                audit_key:$audit_key,
                audit_uid:($audit_uid | tonumber),
                checked_syscalls:$checked_syscalls,
                missing_syscalls:$missing_syscalls,
                preflight:$preflight
            }'
        return 0
    fi

    jq -cn \
        --arg audit_key "${audit_key}" \
        --arg audit_uid "${audit_uid}" \
        --argjson checked_syscalls "${installed_syscalls}" \
        --argjson preflight "${preflight}" \
        '{
            ok:true,
            status:"verified",
            phase:"rule_verification",
            audit_key:$audit_key,
            audit_uid:($audit_uid | tonumber),
            checked_syscalls:$checked_syscalls,
            preflight:$preflight
        }'
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
    if [[ -r /proc/self/loginuid ]] && read -r login_uid </proc/self/loginuid; then
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
    if linux_agent_observer_helper_available; then
        linux_agent_observer_helper_request add_rule \
            --audit-uid "${audit_uid}" --key "${key}" --syscall "${syscall}" >/dev/null 2>&1
        return
    fi
    linux_agent_observer_auditctl -a always,exit -F arch=b64 -S "${syscall}" -F "auid=${audit_uid}" -k "${key}" >/dev/null 2>&1
}

linux_agent_observer_remove_syscall_rule() {
    local audit_uid="$1"
    local key="$2"
    local syscall="$3"
    if linux_agent_observer_helper_available; then
        linux_agent_observer_helper_request remove_rule \
            --audit-uid "${audit_uid}" --key "${key}" --syscall "${syscall}" >/dev/null 2>&1
        return
    fi
    linux_agent_observer_auditctl -d always,exit -F arch=b64 -S "${syscall}" -F "auid=${audit_uid}" -k "${key}" >/dev/null 2>&1
}

linux_agent_observer_session_start() {
    local scope="${1:-session}"
    local subject_json="${2:-}"
    local preflight key uid audit_uid start_time installed='[]' notes='[]' selected_syscalls boundary_summary
    local require_all=false selected_count installed_count rolled_back='[]' rollback_failed='[]'
    [[ -n "${subject_json}" ]] || subject_json='{}'
    linux_agent_observer_clear_failed_context
    LINUX_AGENT_OBSERVER_HELPER_CAPABILITY=""

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

    if linux_agent_observer_require_enabled; then
        require_all=true
    fi

    uid="$(id -u)"
    audit_uid="$(linux_agent_observer_audit_uid)"
    key="$(linux_agent_observer_key "${scope}")"
    if linux_agent_observer_helper_available; then
        LINUX_AGENT_OBSERVER_HELPER_CAPABILITY="$(linux_agent_observer_new_helper_capability)"
    else
        LINUX_AGENT_OBSERVER_HELPER_CAPABILITY=""
    fi
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

    selected_count="$(jq 'length' <<<"${selected_syscalls}")"
    installed_count="$(jq 'length' <<<"${installed}")"
    if [[ "${require_all}" == "true" && "${installed_count}" -ne "${selected_count}" ]]; then
        while IFS= read -r syscall; do
            [[ -z "${syscall}" ]] && continue
            if linux_agent_observer_remove_syscall_rule "${audit_uid}" "${key}" "${syscall}"; then
                rolled_back="$(jq -cn --argjson prior "${rolled_back}" --arg syscall "${syscall}" '$prior + [$syscall]')"
            else
                rollback_failed="$(jq -cn --argjson prior "${rollback_failed}" --arg syscall "${syscall}" '$prior + [$syscall]')"
                notes="$(jq -cn --argjson prior "${notes}" --arg syscall "${syscall}" '$prior + ["failed to roll back syscall rule: " + $syscall]')"
            fi
        done < <(jq -r '.[]' <<<"${installed}")

        LINUX_AGENT_OBSERVER_SESSION_CONTEXT="$(jq -cn \
            --arg scope "${scope}" \
            --argjson subject "${subject_json}" \
            --arg audit_key "${key}" \
            --arg uid "${uid}" \
            --arg audit_uid "${audit_uid}" \
            --arg start_time "${start_time}" \
            --argjson selected_syscalls "${selected_syscalls}" \
            --argjson attempted_installed_syscalls "${installed}" \
            --argjson installed_syscalls "${rollback_failed}" \
            --argjson rolled_back_syscalls "${rolled_back}" \
            --argjson rollback_failed_syscalls "${rollback_failed}" \
            --argjson notes "${notes}" \
            --argjson audit_boundary "${boundary_summary}" \
            '{status:"failed", available:false, backend:"auditd", lifecycle:"session", scope:$scope, subject:$subject, audit_key:$audit_key, uid:($uid|tonumber), audit_uid:($audit_uid|tonumber), start_time:$start_time, audit_boundary:$audit_boundary, reason_code:"observer_rule_install_incomplete", reason:"strict observer requires every selected auditd rule to be installed", selected_syscalls:$selected_syscalls, attempted_installed_syscalls:$attempted_installed_syscalls, installed_syscalls:$installed_syscalls, rolled_back_syscalls:$rolled_back_syscalls, rollback_failed_syscalls:$rollback_failed_syscalls, notes:$notes}')"
        linux_agent_observer_log_event "observer_failed" "${LINUX_AGENT_OBSERVER_SESSION_CONTEXT}"
        return 0
    fi

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
            flags:(field("a2") // null),
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
                | map(select(.name != null) as $file
                    | {
                        name:$file.name,
                        syscall:(($events | map(select(.record_id != null and .record_id == $file.record_id and .syscall != null)) | .[0].syscall) // $file.syscall),
                        flags:(($events | map(select(.record_id != null and .record_id == $file.record_id and .flags != null)) | .[0].flags) // $file.flags),
                        success:(($events | map(select(.record_id != null and .record_id == $file.record_id and .success != null)) | .[0].success) // $file.success)
                    })
                | unique_by(.name, .syscall, .flags, .success)
                | .[0:$max_events]) else [] end)
        }
    ' <<<"${raw}"
}

linux_agent_observer_log_file_vault_observations() {
    local parsed="$1"
    local scope="${2:-session}"
    local policy_path="${LINUX_AGENT_FILE_VAULT_POLICY_PATH:-${LINUX_AGENT_ROOT}/policies/file-vault.json}"
    local paths observed

    [[ -f "${policy_path}" ]] || return 0
    paths="$(jq -c '.paths // []' "${policy_path}" 2>/dev/null || printf '[]')"
    observed="$(jq -c --argjson paths "${paths}" '
        def path_matches($policy):
            if ($policy | type) != "string" then false
            elif ($policy | endswith("/*")) then
                (($policy | .[0:-2]) as $base
                 | . == $base or startswith($base + "/"))
            else . == $policy
            end;
        [(.file_events // [])[] as $event
         | select(($event.name // "") != "")
         | select(($event.success // "yes") | tostring | IN("yes", "1", "true"))
         | select(any($paths[]; . as $policy | ($event.name | path_matches($policy))))
         | $event]
        | unique_by(.name, .syscall, .flags, .success)
    ' <<<"${parsed}" 2>/dev/null || printf '[]')"
    [[ "${observed}" != "[]" ]] || return 0

    linux_agent_observer_log_event "file_vault_observed" "$(jq -cn \
        --arg scope "${scope}" \
        --argjson events "${observed}" \
        '
        def is_open_syscall:
            (.syscall // "") | tostring | IN("2", "257", "437", "open", "openat", "openat2");
        def hex_digit:
            if . >= 48 and . <= 57 then . - 48
            elif . >= 65 and . <= 70 then . - 55
            elif . >= 97 and . <= 102 then . - 87
            else 0
            end;
        def numeric_flags:
            if test("^0[xX][0-9a-fA-F]+$") then
                .[2:] | explode | reduce .[] as $digit (0; . * 16 + ($digit | hex_digit))
            elif test("^[0-9]+$") then tonumber
            else null
            end;
        def open_flags_modify:
            ((.flags // "") | tostring) as $flags
            | if ($flags | test("O_WRONLY|O_RDWR|O_CREAT|O_TRUNC|O_APPEND|O_TMPFILE")) then true
              elif ($flags | test("^(0[xX][0-9a-fA-F]+|[0-9]+)$")) then
                  (($flags | numeric_flags) as $value
                   | (($value % 4) != 0
                      or ((($value / 64) | floor) % 2) == 1
                      or ((($value / 512) | floor) % 2) == 1
                      or ((($value / 1024) | floor) % 2) == 1
                      or ((($value / 4194304) | floor) % 2) == 1))
              else false
              end;
        def event_is_modify:
            if is_open_syscall then open_flags_modify
            else (.syscall // "") | tostring | IN(
                "85", "76", "77", "82", "264", "316", "87", "263", "90", "91", "268", "92", "93", "260", "83", "258", "84", "88", "266", "86", "265",
                "creat", "truncate", "ftruncate", "rename", "renameat", "renameat2", "unlink", "unlinkat", "chmod", "fchmod", "fchmodat", "chown", "fchown", "fchownat", "mkdir", "mkdirat", "rmdir", "symlink", "symlinkat", "link", "linkat"
            )
            end;
        {
            scope:$scope,
            mode:(if $scope == "terminal" then "terminal" elif $scope == "session" then "unknown" else "work" end),
            observed_paths:($events | map(.name) | unique),
            observed_path_count:([$events[] | .name] | unique | length),
            event_count:($events | length),
            action:(if any($events[]; event_is_modify) then "modify" else "access" end),
            warning:"auditd 观察到文件保险箱路径发生文件事件。"
        }')"
}

linux_agent_observer_session_finish() {
    local final_status="${1:-unknown}"
    local context_json
    local status end_time audit_key audit_uid installed cleanup_notes cleanup_remaining notes raw parsed query_status syscall
    context_json="$(linux_agent_observer_current_context)"
    if [[ -z "${context_json}" ]]; then
        linux_agent_observer_close_helper_session ""
        linux_agent_observer_clear_failed_context
        return 0
    fi

    status="$(jq -r '.status // "unknown"' <<<"${context_json}")"
    end_time="$(linux_agent_now_iso)"
    if [[ "${status}" != "running" ]]; then
        local done_context
        audit_key="$(jq -r '.audit_key // empty' <<<"${context_json}")"
        audit_uid="$(jq -r '.audit_uid // .uid // empty' <<<"${context_json}")"
        installed="$(jq -c '.installed_syscalls // []' <<<"${context_json}")"
        cleanup_notes='[]'
        cleanup_remaining='[]'
        if [[ -n "${audit_key}" && -n "${audit_uid}" ]]; then
            while IFS= read -r syscall; do
                [[ -z "${syscall}" ]] && continue
                if ! linux_agent_observer_remove_syscall_rule "${audit_uid}" "${audit_key}" "${syscall}"; then
                    cleanup_notes="$(jq -cn --argjson prior "${cleanup_notes}" --arg syscall "${syscall}" '$prior + ["failed to remove syscall rule: " + $syscall]')"
                    cleanup_remaining="$(jq -cn --argjson prior "${cleanup_remaining}" --arg syscall "${syscall}" '$prior + [$syscall]')"
                fi
            done < <(jq -r '.[]' <<<"${installed}")
        fi
        done_context="$(jq -c \
            --arg end_time "${end_time}" \
            --arg final_status "${final_status}" \
            --argjson cleanup_notes "${cleanup_notes}" \
            --argjson cleanup_remaining "${cleanup_remaining}" \
            '. + {end_time:$end_time, final_status:$final_status, cleanup_notes:$cleanup_notes, installed_syscalls:$cleanup_remaining}' <<<"${context_json}")"
        linux_agent_observer_log_event "observer_session_finished" "${done_context}"
        linux_agent_observer_close_helper_session "${audit_key}"
        linux_agent_observer_clear_failed_context
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
        linux_agent_observer_close_helper_session "${audit_key}"
        linux_agent_observer_clear_failed_context
        LINUX_AGENT_OBSERVER_SESSION_CONTEXT=""
        return 0
    fi

    parsed="$(linux_agent_observer_parse_ausearch "${raw}" "${audit_key}")"
    linux_agent_observer_log_file_vault_observations "${parsed}" "$(jq -r '.scope // "session"' <<<"${context_json}")"
    notes="$(jq -cn --argjson prior "$(jq -c '.notes // []' <<<"${context_json}")" --argjson cleanup "${cleanup_notes}" '$prior + $cleanup')"
    parsed="$(jq -c \
        --arg start_time "$(jq -r '.start_time' <<<"${context_json}")" \
        --arg end_time "${end_time}" \
        --arg final_status "${final_status}" \
        --argjson notes "${notes}" \
        '. + {lifecycle:"session", start_time:$start_time, end_time:$end_time, final_status:$final_status, notes:$notes}' <<<"${parsed}")"
    linux_agent_observer_log_event "observer_session_finished" "${parsed}"
    linux_agent_observer_close_helper_session "${audit_key}"
    linux_agent_observer_clear_failed_context
    LINUX_AGENT_OBSERVER_SESSION_CONTEXT=""
}

# A daemonized descendant can keep a FIFO writer open after the direct command
# exits. Plain `wait` would then block forever, so limiter shutdown is bounded
# and any forced stop is treated as an output-integrity failure.
linux_agent_wait_output_limiter() {
    local limiter_pid="$1"
    local poll_count=0
    local status=0

    [[ "${limiter_pid}" =~ ^[0-9]+$ ]] || return 125
    while ((poll_count < 100)); do
        if ! kill -0 "${limiter_pid}" >/dev/null 2>&1; then
            wait "${limiter_pid}" 2>/dev/null
            return $?
        fi
        sleep 0.05
        ((poll_count += 1))
    done

    kill -TERM "${limiter_pid}" >/dev/null 2>&1 || true
    sleep 0.1
    kill -KILL "${limiter_pid}" >/dev/null 2>&1 || true
    wait "${limiter_pid}" 2>/dev/null || status=$?
    if ((status == 0)); then
        status=125
    fi
    return "${status}"
}

linux_agent_run_observed_process() {
    local scope="$1"
    local subject_json="$2"
    local stdout_file="$3"
    local stderr_file="$4"
    shift 4
    [[ "${1:-}" == "--" ]] && shift

    local pid exit_code start_time end_time observer_marker timeout_sec timed_out observer_status
    local audit_payload audit_rc audit_block
    local -a execution_command
    start_time="$(linux_agent_now_iso)"
    timeout_sec="$(linux_agent_execution_timeout_sec)"
    timed_out=false
    observer_status="recorded"
    if ! command -v timeout >/dev/null 2>&1 ||
        ! command -v setsid >/dev/null 2>&1 ||
        ! command -v mkfifo >/dev/null 2>&1 ||
        ! command -v python3 >/dev/null 2>&1; then
        end_time="$(linux_agent_now_iso)"
        printf 'execution lifecycle guard is unavailable; refusing unbounded execution\n' >"${stderr_file}"
        observer_marker="$(jq -cn \
            --arg scope "${scope}" \
            --argjson subject "${subject_json}" \
            --arg start_time "${start_time}" \
            --arg end_time "${end_time}" \
            --argjson timeout_sec "${timeout_sec}" \
            '{status:"guard_unavailable", backend:"auditd", lifecycle:"execution", scope:$scope, subject:$subject, start_time:$start_time, end_time:$end_time, root_pid:null, exit_code:127, timed_out:false, timeout_sec:$timeout_sec}')"
        linux_agent_observer_log_event "execution_finished" "${observer_marker}"
        jq -cn --argjson observer "${observer_marker}" '{exit_code:127, root_pid:null, timed_out:false, observer:$observer}'
        return 0
    fi
    execution_command=(setsid --wait timeout -s TERM -k 5s "${timeout_sec}s" "$@")
    audit_payload="$(jq -cn \
        --arg scope "${scope}" \
        --argjson subject "${subject_json}" \
        --arg start_time "${start_time}" \
        '{scope:$scope, subject:$subject, start_time:$start_time, root_pid:null}')"
    audit_rc=0
    if declare -F linux_agent_audit_require_event >/dev/null 2>&1; then
        linux_agent_audit_require_event "execution_started" "${audit_payload}" || audit_rc=$?
    else
        linux_agent_observer_log_event "execution_started" "${audit_payload}" || audit_rc=$?
    fi
    if ((audit_rc != 0)); then
        if declare -F linux_agent_audit_failure_result >/dev/null 2>&1; then
            audit_block="$(linux_agent_audit_failure_result "${audit_rc}" "execution_started")"
        else
            audit_block="$(jq -cn --argjson exit_code "${audit_rc}" \
                '{ok:false, status:"blocked", code:"audit_integrity_broken", error_code:"audit_integrity_broken", exit_code:$exit_code, output:{raw:"审计事件无法持久写入，操作未执行。"}}')"
        fi
        jq -cn \
            --argjson blocked_result "${audit_block}" \
            '{exit_code:($blocked_result.exit_code // 125), root_pid:null, timed_out:false, observer:{status:"audit_blocked", backend:"auditd", lifecycle:"execution"}, blocked_result:$blocked_result}'
        return 0
    fi
    local max_output_bytes output_capped output_integrity_unknown
    local stdout_truncated_bytes stderr_truncated_bytes
    local stdout_pipe stderr_pipe stdout_marker stderr_marker stdout_limiter_pid stderr_limiter_pid
    local stdout_limiter_status stderr_limiter_status
    max_output_bytes="$(linux_agent_execution_max_output_bytes 2>/dev/null || printf '1048576')"
    [[ "${max_output_bytes}" =~ ^[0-9]+$ ]] || max_output_bytes=1048576
    output_capped=false
    output_integrity_unknown=false
    stdout_truncated_bytes=0
    stderr_truncated_bytes=0
    stdout_pipe="${stdout_file}.pipe.$$"
    stderr_pipe="${stderr_file}.pipe.$$"
    stdout_marker="${stdout_file}.overflow.$$"
    stderr_marker="${stderr_file}.overflow.$$"
    rm -f -- "${stdout_pipe}" "${stderr_pipe}" "${stdout_marker}" "${stderr_marker}"
    mkfifo -m 600 "${stdout_pipe}" "${stderr_pipe}"
    set +e
    # The producer opens its FIFO writers first and blocks until both limiter
    # readers are attached. This makes its PID available to the limiters.
    "${execution_command[@]}" >"${stdout_pipe}" 2>"${stderr_pipe}" &
    pid=$!
    python3 "${LINUX_AGENT_ROOT}/lib/output_limiter.py" \
        --output "${stdout_file}" --marker "${stdout_marker}" \
        --max-bytes "${max_output_bytes}" --producer-pid "${pid}" <"${stdout_pipe}" &
    stdout_limiter_pid=$!
    python3 "${LINUX_AGENT_ROOT}/lib/output_limiter.py" \
        --output "${stderr_file}" --marker "${stderr_marker}" \
        --max-bytes "${max_output_bytes}" --producer-pid "${pid}" <"${stderr_pipe}" &
    stderr_limiter_pid=$!
    while kill -0 "${pid}" 2>/dev/null; do
        if [[ -f "${stdout_marker}" || -f "${stderr_marker}" ]]; then
            output_capped=true
            kill -TERM -- "-${pid}" 2>/dev/null || true
            for _ in {1..20}; do
                kill -0 "${pid}" 2>/dev/null || break
                sleep 0.05
            done
            kill -KILL -- "-${pid}" 2>/dev/null || true
            break
        fi
        sleep 0.02
    done
    wait "${pid}"
    exit_code=$?
    linux_agent_wait_output_limiter "${stdout_limiter_pid}"
    stdout_limiter_status=$?
    linux_agent_wait_output_limiter "${stderr_limiter_pid}"
    stderr_limiter_status=$?
    rm -f -- "${stdout_pipe}" "${stderr_pipe}"
    set -e
    local stdout_marker_json stderr_marker_json
    stdout_marker_json="$(cat "${stdout_marker}" 2>/dev/null || true)"
    stderr_marker_json="$(cat "${stderr_marker}" 2>/dev/null || true)"
    if [[ "${stdout_limiter_status}" -ne 0 || "${stderr_limiter_status}" -ne 0 ]]; then
        output_integrity_unknown=true
        printf 'execution output limiter failed; output integrity is unknown\n' >"${stderr_file}"
        exit_code=125
        observer_status="guard_unavailable"
    fi
    if jq -e '.truncated == true' <<<"${stdout_marker_json}" >/dev/null 2>&1; then
        stdout_truncated_bytes="$(jq -r '.truncated_bytes // 1' <<<"${stdout_marker_json}" 2>/dev/null || printf '1')"
        output_capped=true
    fi
    if jq -e '.truncated == true' <<<"${stderr_marker_json}" >/dev/null 2>&1; then
        stderr_truncated_bytes="$(jq -r '.truncated_bytes // 1' <<<"${stderr_marker_json}" 2>/dev/null || printf '1')"
        output_capped=true
    fi
    if jq -e '.producer_detached == true' <<<"${stdout_marker_json}" >/dev/null 2>&1 ||
        jq -e '.producer_detached == true' <<<"${stderr_marker_json}" >/dev/null 2>&1; then
        output_integrity_unknown=true
        printf 'execution descendant retained an output stream; output integrity is unknown\n' >"${stderr_file}"
    fi
    rm -f -- "${stdout_marker}" "${stderr_marker}"
    if [[ "${output_integrity_unknown}" == "true" ]]; then
        output_capped=false
        observer_status="guard_unavailable"
        exit_code=125
    elif [[ "${output_capped}" == "true" ]]; then
        observer_status="output_capped"
        exit_code=125
    elif [[ "${exit_code}" -eq 124 ]]; then
        timed_out=true
        observer_status="timed_out"
    fi
    end_time="$(linux_agent_now_iso)"
    observer_marker="$(jq -cn \
        --arg scope "${scope}" \
        --argjson subject "${subject_json}" \
        --arg status "${observer_status}" \
        --arg start_time "${start_time}" \
        --arg end_time "${end_time}" \
        --argjson root_pid "${pid}" \
        --argjson exit_code "${exit_code}" \
        --argjson timed_out "${timed_out}" \
        --argjson timeout_sec "${timeout_sec}" \
        --argjson output_capped "${output_capped}" \
        --argjson output_integrity_unknown "${output_integrity_unknown}" \
        --argjson stdout_truncated_bytes "${stdout_truncated_bytes}" \
        --argjson stderr_truncated_bytes "${stderr_truncated_bytes}" \
        --argjson session_observer "${LINUX_AGENT_OBSERVER_SESSION_CONTEXT:-null}" \
        '{status:$status, backend:"auditd", lifecycle:"execution", scope:$scope, subject:$subject, start_time:$start_time, end_time:$end_time, root_pid:$root_pid, exit_code:$exit_code, timed_out:$timed_out, timeout_sec:$timeout_sec, output_capped:$output_capped, output_integrity_unknown:$output_integrity_unknown, stdout_truncated_bytes:$stdout_truncated_bytes, stderr_truncated_bytes:$stderr_truncated_bytes, session_audit_key:($session_observer.audit_key // null), session_status:($session_observer.status // null)}')"
    linux_agent_observer_log_event "execution_finished" "${observer_marker}"
    jq -cn \
        --argjson exit_code "${exit_code}" \
        --argjson root_pid "${pid}" \
        --argjson timed_out "${timed_out}" \
        --argjson observer "${observer_marker}" \
        --argjson output_capped "${output_capped}" \
        --argjson output_integrity_unknown "${output_integrity_unknown}" \
        --argjson stdout_truncated_bytes "${stdout_truncated_bytes}" \
        --argjson stderr_truncated_bytes "${stderr_truncated_bytes}" \
        '{exit_code:$exit_code, root_pid:$root_pid, timed_out:$timed_out, output_capped:$output_capped, output_integrity_unknown:$output_integrity_unknown, stdout_truncated_bytes:$stdout_truncated_bytes, stderr_truncated_bytes:$stderr_truncated_bytes, observer:$observer}'
}
