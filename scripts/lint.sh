#!/usr/bin/env bash
#
# 统一静态检查基线：本地与 CI 共用。
# 必备检查（缺依赖即失败）：bash -n、python3 -m py_compile、node --check。
# 可选检查（未安装则跳过并提示）：shellcheck、shfmt、pyflakes/ruff、eslint。

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

status=0
note() { printf '[lint] %s\n' "$*"; }
warn() { printf '[lint][skip] %s\n' "$*" >&2; }
fail() { printf '[lint][fail] %s\n' "$*" >&2; status=1; }

BASH_FILES=(bin/agent bin/agent-web test_config.sh lib/*.sh remote/*.sh scripts/*.sh tests/*.sh skills/*/scripts/*.sh)
PY_FILES=(lib/command_guard.py lib/mcp_client.py lib/file_vault.py lib/provider_security.py web/server.py tests/fake_ai_server.py tests/fake_mcp_server.py)

note "bash -n"
# shellcheck disable=SC2086
bash -n "${BASH_FILES[@]}" || fail "bash -n reported syntax errors"

note "python3 -m py_compile"
python3 -m py_compile "${PY_FILES[@]}" || fail "py_compile reported syntax errors"

note "node --check web/static/app.js"
if command -v node >/dev/null 2>&1; then
    node --check web/static/app.js || fail "node --check reported syntax errors"
    for module in web/static/modules/*.js; do
        node --check "${module}" || fail "node --check failed for ${module}"
    done
else
    warn "node 未安装，跳过前端语法检查"
fi

# JSON policy/config/schema files must parse.
note "jq JSON validation"
if command -v jq >/dev/null 2>&1; then
    while IFS= read -r json_file; do
        jq -e . "${json_file}" >/dev/null 2>&1 || fail "invalid JSON: ${json_file}"
    done < <(find config policies schema mcp -name '*.json' 2>/dev/null)
else
    warn "jq 未安装，跳过 JSON 校验"
fi

# —— 可选：ShellCheck ——
if command -v shellcheck >/dev/null 2>&1; then
    note "shellcheck"
    # shellcheck disable=SC2086
    shellcheck -S warning "${BASH_FILES[@]}" || fail "shellcheck reported issues"
else
    warn "shellcheck 未安装（CI 应安装；见 .github/workflows）"
fi

# —— 可选：shfmt ——
if command -v shfmt >/dev/null 2>&1; then
    note "shfmt -d"
    # shellcheck disable=SC2086
    shfmt -d -i 4 -ci "${BASH_FILES[@]}" || fail "shfmt reported formatting drift"
else
    warn "shfmt 未安装"
fi

# —— 可选：Python lint ——
if command -v ruff >/dev/null 2>&1; then
    note "ruff check"
    ruff check "${PY_FILES[@]}" || fail "ruff reported issues"
elif python3 -c 'import pyflakes' >/dev/null 2>&1; then
    note "pyflakes"
    python3 -m pyflakes "${PY_FILES[@]}" || fail "pyflakes reported issues"
else
    warn "ruff/pyflakes 未安装"
fi

if [[ "${status}" -eq 0 ]]; then
    note "所有必备检查通过"
else
    printf '[lint] 存在失败项\n' >&2
fi
exit "${status}"
