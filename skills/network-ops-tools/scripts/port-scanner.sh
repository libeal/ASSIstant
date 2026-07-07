#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
arguments_json="${1:-}"
[[ -z "${arguments_json}" ]] && arguments_json='{}'
python3 "${SCRIPT_DIR}/_network_tool.py" port-scanner "${arguments_json}"
