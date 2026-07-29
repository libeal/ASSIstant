#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
arguments_json="${1:-}"
[[ -n "${arguments_json}" ]] || arguments_json='{}'
if ! jq -e 'type == "object" and length == 0' <<<"${arguments_json}" >/dev/null 2>&1; then
    jq -cn '{ok:false,status:"invalid_arguments",code:"invalid_arguments",error:"instance-discovery does not accept arguments"}'
    exit 0
fi
python3 "${script_dir}/database_profiles.py" discover
