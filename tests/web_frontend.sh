#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
jq -e '.private == true and .type == "module"' \
    "${ROOT_DIR}/web/package.json" >/dev/null

node_args=()
if node --help | grep -q -- '--no-experimental-detect-module'; then
    node_args+=(--no-experimental-detect-module)
fi

shopt -s nullglob
test_files=("${ROOT_DIR}"/tests/web_*.mjs)
[[ "${#test_files[@]}" -gt 0 ]] || {
    printf 'web_frontend: no web_*.mjs tests found\n' >&2
    exit 1
}

for test_file in "${test_files[@]}"; do
    printf '[web_frontend] %s\n' "$(basename -- "${test_file}")"
    node "${node_args[@]}" "${test_file}"
done

printf 'web_frontend: ok\n'
