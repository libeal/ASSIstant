#!/usr/bin/env bash
set -euo pipefail
jq -cn '{ok:false,status:"credential_unavailable",code:"credential_unavailable",error:"database health requires the dedicated credential helper"}'
