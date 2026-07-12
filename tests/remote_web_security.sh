#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="$(mktemp -d)"
cleanup() {
    rm -rf "${tmp_root}"
}
trap cleanup EXIT

cp -a \
    "${ROOT_DIR}/bin" \
    "${ROOT_DIR}/config" \
    "${ROOT_DIR}/lib" \
    "${ROOT_DIR}/mcp" \
    "${ROOT_DIR}/policies" \
    "${ROOT_DIR}/prompts" \
    "${ROOT_DIR}/skills" \
    "${ROOT_DIR}/web" \
    "${tmp_root}/"
cp "${tmp_root}/config/config.example.json" "${tmp_root}/config/config.json"
mkdir -p "${tmp_root}/logs"
printf '%s\n' '{"stage":"finished","payload":{"status":"ok"}}' > "${tmp_root}/logs/session_web_backup.jsonl"

LINUX_AGENT_ROOT="${tmp_root}" LINUX_AGENT_REMOTE_MODE=1 python3 - <<'PY'
import importlib.util
import json
import os
from pathlib import Path

root = Path(os.environ["LINUX_AGENT_ROOT"])
spec = importlib.util.spec_from_file_location("remote_web_server", root / "web" / "server.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

blocked = module.list_provider_models({
    "provider": "openai_compatible",
    "api_url": "https://example.com/v1/chat/completions",
    "api_key": "request-secret",
})
assert blocked["status"] == "secret_transmission_disabled", blocked

updated = module.write_api_key_secret("memory-only-secret")
assert updated["config"]["api_key_source"] == "runtime", updated
assert updated["config"]["api_key_configured"], updated
config_text = (root / "config" / "config.json").read_text(encoding="utf-8")
assert "memory-only-secret" not in config_text

key, source = module.configured_api_key(module.read_config())
assert key == "memory-only-secret"
assert source == "runtime"

module.update_config_value("remote.allow_api_key_transmission", True)
assert module.config_public_state()["config"]["remote"]["allow_api_key_transmission"] is True

skills_dir_update = module.update_config_value("skills_dir", "/tmp/remote-skills-escape")
assert skills_dir_update["ok"] is False
assert skills_dir_update["status"] == "remote_config_read_only"

env = module.agent_subprocess_env()
assert "LINUX_AGENT_API_KEY" not in env
ai_env = module.agent_subprocess_env(include_api_key=True)
assert ai_env["LINUX_AGENT_API_KEY"] == "memory-only-secret"

backup = module.create_runtime_backup()
assert backup["ok"] is True, backup
backup_path = Path(backup["path"])
assert backup_path.is_file()
assert b"memory-only-secret" not in backup_path.read_bytes()
backup_path.unlink()
PY

outside_skills="${tmp_root}/outside-skills"
config_tmp="${tmp_root}/config-with-outside-skills.json"
jq --arg path "${outside_skills}" '.skills_dir = $path' "${tmp_root}/config/config.json" > "${config_tmp}"
mv "${config_tmp}" "${tmp_root}/config/config.json"
resolved_skills_dir="$(
    cd "${tmp_root}"
    LINUX_AGENT_REMOTE_MODE=1 bash -c '
        source lib/common.sh
        source lib/config.sh
        source lib/skills.sh
        linux_agent_init_env "$PWD"
        linux_agent_load_config
        linux_agent_skills_dir
    '
)"
[[ "${resolved_skills_dir}" == "${tmp_root}/skills" ]]
[[ ! -e "${outside_skills}" ]]

if grep -R -Eq -- 'memory-only-secret|request-secret' "${tmp_root}"; then
    printf 'remote web secret was persisted to disk\n' >&2
    exit 1
fi

printf 'remote_web_security: ok\n'
