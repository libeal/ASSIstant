#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFORMANCE_BIN="${MCP_CONFORMANCE_BIN:-}"
if [[ -z "${CONFORMANCE_BIN}" ]]; then
    CONFORMANCE_BIN="$(command -v conformance || true)"
fi
[[ -n "${CONFORMANCE_BIN}" && -x "${CONFORMANCE_BIN}" ]] || {
    printf 'official MCP conformance CLI is unavailable; install @modelcontextprotocol/conformance@0.2.0-alpha.10\n' >&2
    exit 1
}

result_dir="$(mktemp -d "${TMPDIR:-/tmp}/linux-agent-mcp-conformance.XXXXXX")"
trap 'rm -rf -- "${result_dir}"' EXIT
cd "${ROOT_DIR}"

for scenario in \
    request-metadata \
    http-standard-headers \
    tools_call \
    json-schema-ref-no-deref; do
    printf '[mcp-conformance] %s\n' "${scenario}"
    "${CONFORMANCE_BIN}" client \
        --command 'python3 tests/mcp_conformance_client.py' \
        --scenario "${scenario}" \
        --spec-version 2026-07-28 \
        --timeout 60000 \
        --output-dir "${result_dir}"
done

printf 'mcp_conformance: ok\n'
