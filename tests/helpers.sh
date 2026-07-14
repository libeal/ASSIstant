#!/usr/bin/env bash

# Keep the regression suite hermetic. An ambient LINUX_AGENT_API_KEY exported by
# the caller's shell would flip api_key_source from "config" to "env" and cause
# false failures in the config-source assertions of security.sh and the web
# tests. Sub-tests that exercise the env-override path (e.g. security.sh) set
# this variable explicitly and unset it afterwards, so clearing it here is safe.
unset LINUX_AGENT_API_KEY 2>/dev/null || true

start_fake_ai_server() {
    local port="${1:-$((21000 + RANDOM % 1000))}"
    local log_dir="${2:-${tmp_root:-/tmp}}"

    FAKE_AI_PORT="${port}"
    FAKE_AI_URL="http://127.0.0.1:${FAKE_AI_PORT}/v1/chat/completions"
    python3 "${ROOT_DIR}/tests/fake_ai_server.py" "${FAKE_AI_PORT}" >"${log_dir}/fake-ai.out" 2>"${log_dir}/fake-ai.err" &
    FAKE_AI_PID="$!"

    for _ in $(seq 1 80); do
        if curl --noproxy '*' -sS "http://127.0.0.1:${FAKE_AI_PORT}/health" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.1
    done

    printf 'fake AI server did not start; stderr:\n' >&2
    cat "${log_dir}/fake-ai.err" >&2 2>/dev/null || true
    return 1
}

stop_fake_ai_server() {
    if [[ -n "${FAKE_AI_PID:-}" ]] && kill -0 "${FAKE_AI_PID}" >/dev/null 2>&1; then
        kill "${FAKE_AI_PID}" >/dev/null 2>&1 || true
        wait "${FAKE_AI_PID}" 2>/dev/null || true
    fi
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
    ' "${project}/config/config.json" > "${tmp_config}"
    mv "${tmp_config}" "${project}/config/config.json"
}
