#!/usr/bin/env bash
# Cosign v2/v3 compatibility helpers for offline key-based blob signing in tests.

linux_agent_test_cosign_run() {
    # Bound network retries so a broken Rekor path cannot hang the suite.
    if command -v timeout >/dev/null 2>&1; then
        timeout -k 5s 45s "$@"
    else
        "$@"
    fi
}

linux_agent_test_cosign_sign_blob() {
    # usage: linux_agent_test_cosign_sign_blob <key> <bundle> <blob>
    local key="$1"
    local bundle="$2"
    local blob="$3"
    local help_text
    help_text="$(cosign sign-blob --help 2>&1 || true)"

    # cosign <3 shipped --tlog-upload; keep offline key fixtures fully local.
    if grep -q -- '--tlog-upload' <<<"${help_text}"; then
        linux_agent_test_cosign_run cosign sign-blob --yes --tlog-upload=false --key "${key}" --bundle "${bundle}" "${blob}"
        return
    fi

    # cosign v3 requires an explicit signing config for offline key bundles.
    if grep -q -- '--signing-config' <<<"${help_text}" &&
        cosign signing-config create --help >/dev/null 2>&1; then
        local signing_config
        signing_config="$(mktemp "${TMPDIR:-/tmp}/linux-agent-cosign-config.XXXXXX")"
        cosign signing-config create \
            --no-default-fulcio \
            --no-default-oidc \
            --no-default-rekor \
            --no-default-tsa \
            --out "${signing_config}"
        local status
        set +e
        linux_agent_test_cosign_run cosign sign-blob --yes \
            --signing-config "${signing_config}" \
            --key "${key}" --bundle "${bundle}" "${blob}"
        status=$?
        set -e
        rm -f -- "${signing_config}"
        return "${status}"
    fi

    printf 'unsupported cosign sign-blob CLI: offline signing flags unavailable\n' >&2
    return 2
}

linux_agent_test_cosign_verify_blob() {
    # usage: linux_agent_test_cosign_verify_blob <key> <bundle> <blob>
    local key="$1"
    local bundle="$2"
    local blob="$3"
    local -a args
    local help_text
    help_text="$(cosign verify-blob --help 2>&1 || true)"
    args=(verify-blob --key "${key}" --bundle "${bundle}")
    if grep -q -- '--offline' <<<"${help_text}"; then
        args+=(--offline)
    fi
    if grep -q -- '--insecure-ignore-tlog' <<<"${help_text}"; then
        args+=(--insecure-ignore-tlog)
    fi
    linux_agent_test_cosign_run cosign "${args[@]}" "${blob}"
}
