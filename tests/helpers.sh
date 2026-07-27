#!/usr/bin/env bash

# Keep the regression suite hermetic. An ambient LINUX_AGENT_API_KEY exported by
# the caller's shell would flip api_key_source from "config" to "env" and cause
# false failures in the config-source assertions of security.sh and the web
# tests. Sub-tests that exercise the env-override path (e.g. security.sh) set
# this variable explicitly and unset it afterwards, so clearing it here is safe.
unset LINUX_AGENT_API_KEY 2>/dev/null || true

LINUX_AGENT_TEST_NAME="${LINUX_AGENT_TEST_NAME:-test}"

linux_agent_test_log() {
    printf '[test:%s] %s\n' "${LINUX_AGENT_TEST_NAME}" "$*" >&2
}

linux_agent_test_report_failure() {
    local status=$?
    local line="${1:-unknown}"
    trap - ERR
    printf '[test:%s] failed at line %s (exit=%s)\n' \
        "${LINUX_AGENT_TEST_NAME}" "${line}" "${status}" >&2
    return "${status}"
}

linux_agent_test_install_failure_trap() {
    LINUX_AGENT_TEST_NAME="$1"
    trap 'linux_agent_test_report_failure "${LINENO}"' ERR
}

linux_agent_test_timeout_seconds() {
    local requested="$1"
    local timeout_sec="${LINUX_AGENT_TEST_TIMEOUT_SEC:-${requested}}"
    if [[ ! "${timeout_sec}" =~ ^[1-9][0-9]*$ ]]; then
        printf 'invalid test timeout: %s\n' "${timeout_sec}" >&2
        return 2
    fi
    printf '%s\n' "${timeout_sec}"
}

linux_agent_test_log_command_result() {
    local label="$1"
    local timeout_sec="$2"
    local status="$3"
    if [[ "${status}" -eq 124 || "${status}" -eq 137 ]]; then
        linux_agent_test_log "timeout: ${label} (${timeout_sec}s, exit=${status})"
    else
        linux_agent_test_log "done: ${label} (exit=${status})"
    fi
}

linux_agent_test_run() {
    local label="$1"
    local requested_timeout="$2"
    local working_dir="$3"
    local output_mode="$4"
    shift 4

    local timeout_sec status=0
    timeout_sec="$(linux_agent_test_timeout_seconds "${requested_timeout}")" || return $?
    linux_agent_test_log "start: ${label} (timeout=${timeout_sec}s)"
    case "${output_mode}" in
        inherit)
            if (cd "${working_dir}" && timeout -k 5s "${timeout_sec}s" "$@"); then
                status=0
            else
                status=$?
            fi
            ;;
        discard)
            if (cd "${working_dir}" && timeout -k 5s "${timeout_sec}s" "$@") >/dev/null 2>&1; then
                status=0
            else
                status=$?
            fi
            ;;
        *)
            printf 'invalid test output mode: %s\n' "${output_mode}" >&2
            return 2
            ;;
    esac
    linux_agent_test_log_command_result "${label}" "${timeout_sec}" "${status}"
    return "${status}"
}

linux_agent_test_capture() {
    local label="$1"
    local requested_timeout="$2"
    local working_dir="$3"
    local stderr_mode="$4"
    shift 4

    local timeout_sec output_value status=0
    timeout_sec="$(linux_agent_test_timeout_seconds "${requested_timeout}")" || return $?
    linux_agent_test_log "start: ${label} (timeout=${timeout_sec}s)"
    case "${stderr_mode}" in
        inherit)
            if output_value="$(cd "${working_dir}" && timeout -k 5s "${timeout_sec}s" "$@")"; then
                status=0
            else
                status=$?
            fi
            ;;
        merge)
            if output_value="$(cd "${working_dir}" && timeout -k 5s "${timeout_sec}s" "$@" 2>&1)"; then
                status=0
            else
                status=$?
            fi
            ;;
        discard)
            if output_value="$(cd "${working_dir}" && timeout -k 5s "${timeout_sec}s" "$@" 2>/dev/null)"; then
                status=0
            else
                status=$?
            fi
            ;;
        *)
            printf 'invalid test stderr mode: %s\n' "${stderr_mode}" >&2
            return 2
            ;;
    esac
    linux_agent_test_log_command_result "${label}" "${timeout_sec}" "${status}"
    printf '%s' "${output_value}"
    return "${status}"
}

start_fake_ai_server() {
    local port="${1:-$((21000 + RANDOM % 1000))}"
    local log_dir="${2:-${tmp_root:-/tmp}}"

    FAKE_AI_PORT="${port}"
    FAKE_AI_URL="http://127.0.0.1:${FAKE_AI_PORT}/v1/chat/completions"
    linux_agent_test_log "start: fake AI server (port=${FAKE_AI_PORT})"
    python3 "${ROOT_DIR}/tests/fake_ai_server.py" "${FAKE_AI_PORT}" >"${log_dir}/fake-ai.out" 2>"${log_dir}/fake-ai.err" &
    FAKE_AI_PID="$!"

    for _ in $(seq 1 80); do
        if ! kill -0 "${FAKE_AI_PID}" >/dev/null 2>&1; then
            break
        fi
        if curl --noproxy '*' --connect-timeout 1 --max-time 1 -sS \
            "http://127.0.0.1:${FAKE_AI_PORT}/health" >/dev/null 2>&1; then
            linux_agent_test_log "ready: fake AI server (port=${FAKE_AI_PORT})"
            return 0
        fi
        sleep 0.1
    done

    printf 'fake AI server did not start; stderr:\n' >&2
    cat "${log_dir}/fake-ai.err" >&2 2>/dev/null || true
    return 1
}

stop_fake_ai_server() {
    if [[ -n "${FAKE_AI_PID:-}" ]]; then
        if kill -0 "${FAKE_AI_PID}" >/dev/null 2>&1; then
            kill "${FAKE_AI_PID}" >/dev/null 2>&1 || true
            if ! timeout -k 1s 5s tail --pid="${FAKE_AI_PID}" -f /dev/null >/dev/null 2>&1; then
                linux_agent_test_log "forcing fake AI server shutdown (pid=${FAKE_AI_PID})"
                kill -KILL "${FAKE_AI_PID}" >/dev/null 2>&1 || true
            fi
        fi
        wait "${FAKE_AI_PID}" 2>/dev/null || true
    fi
    FAKE_AI_PID=""
}

configure_fake_ai() {
    local project="$1"
    local tmp_config

    tmp_config="$(mktemp)"
    jq --arg api_url "${FAKE_AI_URL}" '
        .api_url = $api_url
        | .api_key = "test-api-key"
        | del(.api_key_file)
        | .model = "fake-chat-completions"
        | .request_timeout_sec = 10
        | .providers_security.allowed_hosts = ["127.0.0.1"]
    ' "${project}/config/config.json" >"${tmp_config}"
    mv "${tmp_config}" "${project}/config/config.json"
}
