#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

while IFS= read -r test_file; do
    printf '[web_frontend] %s\n' "$(basename "${test_file}")"
    node "${test_file}"
done < <(find "${ROOT_DIR}/tests" -maxdepth 1 -type f -name 'web_*.mjs' | LC_ALL=C sort)

printf 'web_frontend: ok\n'
