#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
arguments_json="${1:-}"
[[ -n "${arguments_json}" ]] || arguments_json='{}'
python3 "${script_dir}/container_inspect.py" container-inspect "${arguments_json}"
