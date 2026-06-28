#!/usr/bin/env bash

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
    local secret_file="${project}/config/test-api-key.secret"

    printf 'test-api-key\n' > "${secret_file}"
    tmp_config="$(mktemp)"
    jq --arg api_url "${FAKE_AI_URL}" '
        .api_url = $api_url
        | .api_key_file = "config/test-api-key.secret"
        | del(.api_key)
        | .model = "fake-chat-completions"
        | .request_timeout_sec = 10
    ' "${project}/config/config.json" > "${tmp_config}"
    mv "${tmp_config}" "${project}/config/config.json"
}
