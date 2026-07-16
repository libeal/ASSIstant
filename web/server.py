#!/usr/bin/env python3

import json
import os
import errno
import secrets
import signal
import shutil
import sqlite3
import subprocess
import sys
import threading
import time
import uuid
from http import HTTPStatus
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlparse


ROOT = Path(os.environ.get("LINUX_AGENT_ROOT", Path(__file__).resolve().parents[1])).resolve()
LIB_ROOT = ROOT / "lib"
if str(LIB_ROOT) not in sys.path:
    sys.path.insert(0, str(LIB_ROOT))
from provider_security import (  # noqa: E402
    inspect_provider_url,
    provider_security_policy,
    provider_url_error_message,
    validate_provider_url,
)
WEB_ROOT = ROOT / "web"
if str(WEB_ROOT) not in sys.path:
    sys.path.insert(0, str(WEB_ROOT))
from jobs import (  # noqa: E402
    IdempotencyConflict,
    JobCapacityExceeded,
    JobStore,
    JobVersionConflict,
)
from domain import DomainContract, DomainValidationError  # noqa: E402
from execution import ExecutionService  # noqa: E402
from policy import PolicyService  # noqa: E402
from provider import ProviderSecurityHelpers, ProviderService  # noqa: E402
from sessions import JobSessionContext, SessionDataError, SessionStore  # noqa: E402
from skills import SkillService  # noqa: E402
from timeline import (  # noqa: E402
    TimelineDataError,
    legacy_timeline_unavailable,
    timeline_from_turns,
)
from audit import (  # noqa: E402
    AuditIntegrityError,
    AuditWriteBlocked,
    append_audit_event as append_web_audit_event,
)
STATIC_ROOT = ROOT / "web" / "static"
JOBS_DB = ROOT / "tmp" / "web" / "jobs.db"
POLICIES_ROOT = ROOT / "policies"
SKILLS_ROOT = ROOT / "skills"
CONFIG_PATH = ROOT / "config" / "config.json"
PROVIDERS_PATH = ROOT / "config" / "ai-providers.json"
AGENT = ROOT / "bin" / "agent"
HOST = os.environ.get("LINUX_AGENT_WEB_HOST", "127.0.0.1")
PORT = int(os.environ.get("LINUX_AGENT_WEB_PORT", "8765"))
TOKEN = os.environ.get("LINUX_AGENT_WEB_TOKEN", "")
JOB_RETENTION_HOURS = int(os.environ.get("LINUX_AGENT_WEB_JOB_RETENTION_HOURS", "24"))
JOB_PROCESSES = {}
JOB_PROCESSES_LOCK = threading.Lock()
JOB_ADMISSION_LOCK = threading.Lock()
JOB_CONTEXTS = {}
JOB_CONTEXTS_LOCK = threading.Lock()
WEB_AGENT_LOCK = threading.RLock()
REQUEST_CONTEXT = threading.local()
DEFAULT_STDERR_TEXT_LIMIT = 4000
WORK_EXECUTION_FLOW_TEXT_LIMIT = 200000
MAX_REQUEST_BODY_BYTES = 1024 * 1024
MAX_ACTIVE_JOBS = int(os.environ.get("LINUX_AGENT_WEB_MAX_ACTIVE_JOBS", "4") or "4")
JOB_TIMEOUT_SEC = int(os.environ.get("LINUX_AGENT_WEB_JOB_TIMEOUT_SEC", "900") or "900")
MAX_JOB_ATTEMPTS = int(os.environ.get("LINUX_AGENT_WEB_MAX_JOB_ATTEMPTS", "3") or "3")
CANCEL_GRACE_SEC = int(os.environ.get("LINUX_AGENT_WEB_CANCEL_GRACE_SEC", "2") or "2")
REQUEST_ID_MAX_LENGTH = 128


class RequestBodyTooLarge(ValueError):
    """Raised when an inbound request body exceeds MAX_REQUEST_BODY_BYTES."""


SERVER_RUN_ID = uuid.uuid4().hex
SERVER_STARTED_AT = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
API_KEY_PLACEHOLDER = "please-set-your-api-key"
EPHEMERAL_TOKEN_FILE = ROOT / "tmp" / "web" / "auth-token"
WEB_AUDIT_SESSION_ID = f"web_{SERVER_RUN_ID[:16]}"
WEB_AUDIT_LOG = ROOT / "logs" / f"{WEB_AUDIT_SESSION_ID}.jsonl"
OBSERVER_BOOTSTRAP_STATE = {
    "status": "pending",
    "ok": True,
    "method": "",
    "error": "",
    "diagnostic": "",
    "updated_at": SERVER_STARTED_AT,
}
REMOTE_MODE = os.environ.get("LINUX_AGENT_REMOTE_MODE", "0") == "1"
RUNTIME_SECRET_LOCK = threading.RLock()
RUNTIME_API_KEY = ""


def read_config():
    try:
        with CONFIG_PATH.open("r", encoding="utf-8") as handle:
            return json.load(handle)
    except FileNotFoundError:
        return {}


def load_domain_schema():
    try:
        with (ROOT / "schema" / "domain.json").open("r", encoding="utf-8") as handle:
            data = json.load(handle)
        if isinstance(data, dict):
            return data
    except (OSError, json.JSONDecodeError):
        pass
    return {}


DOMAIN_SCHEMA = load_domain_schema()
DOMAIN_CONTRACT = DomainContract(DOMAIN_SCHEMA)


def write_config(config):
    CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = CONFIG_PATH.with_suffix(".json.tmp")
    with tmp_path.open("w", encoding="utf-8") as handle:
        json.dump(config, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    # config.json may hold the API key; keep it owner-only.
    os.chmod(tmp_path, 0o600)
    tmp_path.replace(CONFIG_PATH)


def safe_int(value, default):
    try:
        return int(value)
    except (TypeError, ValueError):
        return int(default)


def now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def secret_value_configured(value):
    return bool(value) and str(value) != API_KEY_PLACEHOLDER


def api_key_state(config):
    with RUNTIME_SECRET_LOCK:
        runtime_configured = secret_value_configured(RUNTIME_API_KEY)
    env_configured = secret_value_configured(os.environ.get("LINUX_AGENT_API_KEY", ""))
    config_configured = not REMOTE_MODE and secret_value_configured(config.get("api_key", ""))

    if runtime_configured:
        source = "runtime"
    elif env_configured:
        source = "env"
    elif config_configured:
        source = "config"
    else:
        source = "missing"

    return {
        "configured": source != "missing",
        "source": source,
        "config_configured": config_configured,
    }


def configured_api_key(config, override=None):
    override_value = str(override or "")
    if secret_value_configured(override_value):
        return override_value, "request"
    with RUNTIME_SECRET_LOCK:
        runtime_value = RUNTIME_API_KEY
    if secret_value_configured(runtime_value):
        return runtime_value, "runtime"
    env_value = os.environ.get("LINUX_AGENT_API_KEY", "")
    if secret_value_configured(env_value):
        return env_value, "env"
    config_value = "" if REMOTE_MODE else str(config.get("api_key", ""))
    if secret_value_configured(config_value):
        return config_value, "config"
    return "", "missing"


PROVIDER_SERVICE = ProviderService(
    PROVIDERS_PATH,
    lambda: DOMAIN_SCHEMA,
    config_reader=read_config,
    key_resolver=configured_api_key,
    remote_mode=REMOTE_MODE,
    security_helpers=ProviderSecurityHelpers(
        policy_from_config=provider_security_policy,
        validate_url=validate_provider_url,
        inspect_url=inspect_provider_url,
        error_message=provider_url_error_message,
    ),
)


def read_provider_registry():
    return PROVIDER_SERVICE.read_registry()


def normalize_provider_id(value):
    return PROVIDER_SERVICE.normalize_id(value)


def provider_by_id(provider_id):
    return PROVIDER_SERVICE.get_provider(provider_id)


def config_provider_id(config):
    return PROVIDER_SERVICE.configured_provider_id(config)


def public_provider(provider):
    return PROVIDER_SERVICE.public_provider(provider)


def providers_public_state():
    return PROVIDER_SERVICE.public_state()


def list_provider_models(body):
    return PROVIDER_SERVICE.list_models(body)


def config_public_state():
    config = read_config()
    agent_loop = config.get("agent_loop") if isinstance(config.get("agent_loop"), dict) else {}
    command_guard = config.get("command_guard") if isinstance(config.get("command_guard"), dict) else {}
    command_guard_enabled = command_guard.get("enabled", True)
    if not isinstance(command_guard_enabled, bool):
        command_guard_enabled = True
    approvals = config.get("approvals") if isinstance(config.get("approvals"), dict) else {}
    auto_approvals = approvals.get("auto") if isinstance(approvals.get("auto"), dict) else {}
    observer = config.get("observer") if isinstance(config.get("observer"), dict) else {}
    execution = config.get("execution") if isinstance(config.get("execution"), dict) else {}
    web = config.get("web") if isinstance(config.get("web"), dict) else {}
    remote = config.get("remote") if isinstance(config.get("remote"), dict) else {}
    key_state = api_key_state(config)
    provider_id = config_provider_id(config)
    return {
        "ok": True,
        "status": "read",
        "config": {
            "provider": config.get("provider", ""),
            "provider_id": provider_id,
            "api_url": config.get("api_url", ""),
            "api_key_configured": key_state["configured"],
            "api_key_source": key_state["source"],
            "api_key_configured_in_config": key_state["config_configured"],
            "model": config.get("model", ""),
            "request_timeout_sec": config.get("request_timeout_sec", 90),
            "context_turns": config.get("context_turns", 6),
            "command_guard": {
                "enabled": command_guard_enabled,
            },
            "agent_loop": {
                "enabled_for_work": bool(agent_loop.get("enabled_for_work", True)),
                "observation_text_limit": int(agent_loop.get("observation_text_limit", 4000) or 4000),
                "thinking_trace_enabled": bool(agent_loop.get("thinking_trace_enabled", False)),
                "max_iterations": safe_int(agent_loop.get("max_iterations", 12) or 12, 12),
                "checkpoint_turns": int(agent_loop.get("checkpoint_turns", 0) or 0),
            },
            "approvals": {
                "auto": {
                    "skill_readonly": bool(auto_approvals.get("skill_readonly", True)),
                    "shell_readonly": bool(auto_approvals.get("shell_readonly", False)),
                    "file_match": bool(auto_approvals.get("file_match", True)),
                    "file_patch": bool(auto_approvals.get("file_patch", False)),
                    "file_download": bool(auto_approvals.get("file_download", False)),
                    "local_analyze": bool(auto_approvals.get("local_analyze", True)),
                    "remote_script": bool(auto_approvals.get("remote_script", False)),
                }
            },
            "audit_mode": config.get("audit_mode", "safe_summary"),
            "audit_text_limit": config.get("audit_text_limit", 1000),
            "observer": {
                "enabled": observer.get("enabled", "auto"),
                "privilege": observer.get("privilege", "sudo_interactive"),
                "max_events": observer.get("max_events", 200),
                "require": observer.get("require", False) is True,
            },
            "execution": {
                "timeout_sec": safe_int(execution.get("timeout_sec", 300) or 300, 300),
                "min_privilege_proxy": bool(execution.get("min_privilege_proxy", True)),
                "least_privilege_user": execution.get("least_privilege_user", "nobody"),
            },
            "skills_dir": config.get("skills_dir", ""),
            "remote_script_policy": config.get("remote_script_policy", "download_review"),
            "remote": {
                "enabled": REMOTE_MODE,
                "release_version": str(remote.get("release_version") or os.environ.get("LINUX_AGENT_REMOTE_RELEASE_VERSION", "")),
                "storage_backend": str(remote.get("storage_backend") or os.environ.get("LINUX_AGENT_REMOTE_STORAGE_BACKEND", "local")),
                "allow_api_key_transmission": bool(remote.get("allow_api_key_transmission", False)),
            },
            "web": {
                "enabled": bool(web.get("enabled", True)),
                "host": web.get("host", HOST),
                "port": safe_int(web.get("port", PORT) or PORT, PORT),
                "token_configured": bool(web.get("token") or TOKEN),
                "job_retention_hours": safe_int(web.get("job_retention_hours", JOB_RETENTION_HOURS) or JOB_RETENTION_HOURS, JOB_RETENTION_HOURS),
                "max_active_jobs": safe_int(web.get("max_active_jobs", MAX_ACTIVE_JOBS) or MAX_ACTIVE_JOBS, MAX_ACTIVE_JOBS),
                "job_timeout_sec": safe_int(web.get("job_timeout_sec", JOB_TIMEOUT_SEC) or JOB_TIMEOUT_SEC, JOB_TIMEOUT_SEC),
                "max_job_attempts": safe_int(web.get("max_job_attempts", MAX_JOB_ATTEMPTS) or MAX_JOB_ATTEMPTS, MAX_JOB_ATTEMPTS),
                "cancel_grace_sec": safe_int(web.get("cancel_grace_sec", CANCEL_GRACE_SEC), CANCEL_GRACE_SEC),
            },
        },
    }


CONFIG_WRITABLE_FIELDS = {
    "provider": {"type": "str", "min": 1},
    "api_url": {"type": "str", "min": 1},
    "model": {"type": "str", "min": 1},
    "request_timeout_sec": {"type": "int", "min": 1, "max": 600},
    "context_turns": {"type": "int", "min": 1, "max": 50},
    "agent_loop.enabled_for_work": {"type": "bool"},
    "agent_loop.observation_text_limit": {"type": "int", "min": 200, "max": 200000},
    "agent_loop.thinking_trace_enabled": {"type": "bool"},
    "agent_loop.max_iterations": {"type": "int", "min": 1, "max": 100},
    "agent_loop.checkpoint_turns": {"type": "int", "min": 0, "max": 100},
    "approvals.auto.skill_readonly": {"type": "bool"},
    "approvals.auto.shell_readonly": {"type": "bool"},
    "approvals.auto.file_match": {"type": "bool"},
    "approvals.auto.file_patch": {"type": "bool"},
    "approvals.auto.file_download": {"type": "bool"},
    "approvals.auto.local_analyze": {"type": "bool"},
    "approvals.auto.remote_script": {"type": "bool"},
    "audit_mode": {"type": "enum", "values": {"safe_summary", "redacted_verbose"}},
    "audit_text_limit": {"type": "int", "min": 40, "max": 200000},
    "observer.enabled": {"type": "enum", "values": {"auto", "auditd", "disabled"}},
    "observer.privilege": {"type": "enum", "values": {"sudo_interactive", "passwordless", "none"}},
    "observer.max_events": {"type": "int", "min": 1, "max": 100000},
    "observer.require": {"type": "bool"},
    "execution.min_privilege_proxy": {"type": "bool"},
    "execution.timeout_sec": {"type": "int", "min": 1, "max": 3600},
    "execution.least_privilege_user": {"type": "str", "min": 1},
    "skills_dir": {"type": "str", "min": 0},
    "remote_script_policy": {"type": "enum", "values": {"download_review", "disabled"}},
    "providers_security.require_https": {"type": "bool"},
    "providers_security.block_internal_addresses": {"type": "bool"},
    "providers_security.allowed_hosts": {"type": "host_list", "max_items": 64},
    "remote.allow_api_key_transmission": {"type": "bool"},
    "web.max_active_jobs": {"type": "int", "min": 1, "max": 64},
    "web.job_timeout_sec": {"type": "int", "min": 1, "max": 86400},
    "web.max_job_attempts": {"type": "int", "min": 1, "max": 10},
    "web.cancel_grace_sec": {"type": "int", "min": 0, "max": 30},
}
CONFIG_SECRET_FIELDS = {"api_key"}


def normalize_config_value(key, value):
    spec = CONFIG_WRITABLE_FIELDS.get(key)
    if not spec:
        return None, f"Unsupported writable config key: {key}"
    value_type = spec["type"]
    if value_type == "bool":
        if not isinstance(value, bool):
            return None, f"{key} must be boolean."
        return value, ""
    if value_type == "int":
        if isinstance(value, bool):
            return None, f"{key} must be integer."
        try:
            normalized = int(value)
        except (TypeError, ValueError):
            return None, f"{key} must be integer."
        if normalized < spec.get("min", normalized) or normalized > spec.get("max", normalized):
            return None, f"{key} is outside allowed range."
        return normalized, ""
    if value_type == "enum":
        normalized = str(value)
        if normalized not in spec["values"]:
            return None, f"{key} must be one of: {', '.join(sorted(spec['values']))}."
        return normalized, ""
    if value_type == "host_list":
        if not isinstance(value, list):
            return None, f"{key} must be a list of hostnames."
        max_items = spec.get("max_items", 64)
        if len(value) > max_items:
            return None, f"{key} allows at most {max_items} entries."
        normalized_list = []
        for item in value:
            host = str(item).strip().lower()
            if not host or len(host) > 255 or any(ch.isspace() for ch in host):
                return None, f"{key} contains an invalid hostname."
            normalized_list.append(host)
        return normalized_list, ""
    normalized = str(value)
    if len(normalized) < spec.get("min", 0):
        return None, f"{key} must not be empty."
    return normalized, ""


def write_nested_config_value(config, key, value):
    parts = key.split(".")
    target = config
    for part in parts[:-1]:
        child = target.get(part)
        if not isinstance(child, dict):
            child = {}
            target[part] = child
        target = child
    target[parts[-1]] = value


def write_api_key_secret(value):
    global RUNTIME_API_KEY
    secret = str(value or "")
    config = read_config()

    if REMOTE_MODE:
        with RUNTIME_SECRET_LOCK:
            RUNTIME_API_KEY = secret
        result = config_public_state()
        result["status"] = "updated"
        result["updated"] = {"api_key": "configured" if secret else "cleared"}
        return result

    if not secret:
        config.pop("api_key", None)
        write_config(config)
        result = config_public_state()
        result["status"] = "updated"
        result["updated"] = {"api_key": "cleared"}
        return result

    config["api_key"] = secret
    write_config(config)
    result = config_public_state()
    result["status"] = "updated"
    result["updated"] = {"api_key": "configured"}
    return result


def update_config_value(key, value):
    if key == "api_key":
        return write_api_key_secret(value)
    if REMOTE_MODE and key == "providers_security.require_https" and value is not True:
        return {
            "ok": False,
            "status": "remote_security_policy_locked",
            "error": "Remote runtime always requires HTTPS Provider URLs.",
        }
    if REMOTE_MODE and key == "skills_dir":
        return {
            "ok": False,
            "status": "remote_config_read_only",
            "error": "Remote runtime always keeps skills inside its ephemeral runtime root.",
        }
    normalized, error = normalize_config_value(key, value)
    if error:
        return {"ok": False, "status": "invalid_config_value", "error": error}
    config = read_config()
    write_nested_config_value(config, key, normalized)
    write_config(config)
    result = config_public_state()
    result["status"] = "updated"
    result["updated"] = {key: "configured" if key in CONFIG_SECRET_FIELDS else normalized}
    return result


def configured_token():
    if TOKEN:
        return TOKEN
    web = read_config().get("web", {})
    return str(web.get("token") or "")


def agent_subprocess_env(include_api_key=False):
    env = os.environ.copy()
    env.setdefault("LINUX_AGENT_WEB", "1")
    # Minimal-scope secret injection: strip the API key from every subprocess by
    # default, then re-add it only for the dedicated AI-calling actions. This
    # keeps the key out of skill / terminal / MCP / tools subprocesses in both
    # remote and local modes.
    env.pop("LINUX_AGENT_API_KEY", None)
    env.pop("LINUX_AGENT_API_KEY_SOURCE", None)
    if not include_api_key:
        return env
    if REMOTE_MODE:
        remote = read_config().get("remote", {})
        transmission_allowed = isinstance(remote, dict) and bool(remote.get("allow_api_key_transmission", False))
        with RUNTIME_SECRET_LOCK:
            runtime_key = RUNTIME_API_KEY
        if transmission_allowed and secret_value_configured(runtime_key):
            env["LINUX_AGENT_API_KEY"] = runtime_key
    else:
        # Local mode: the Bash core reads the key from config.json when it is not
        # in the environment, so we only forward an operator-supplied env key.
        parent_key = os.environ.get("LINUX_AGENT_API_KEY", "")
        if secret_value_configured(parent_key):
            env["LINUX_AGENT_API_KEY"] = parent_key
    return env


def create_runtime_backup():
    if not REMOTE_MODE:
        return {"ok": False, "status": "backup_unavailable", "error": "Runtime backup is only available in remote mode."}
    output_path = ROOT.parent / f"linux-agent-runtime-backup-{uuid.uuid4().hex}.tar.gz"
    backup_env = agent_subprocess_env()
    try:
        process = subprocess.run(
            ["bash", str(AGENT), "backup", str(output_path)],
            cwd=str(ROOT),
            env=backup_env,
            text=True,
            capture_output=True,
            timeout=180,
            check=False,
        )
    except subprocess.TimeoutExpired:
        output_path.unlink(missing_ok=True)
        return {"ok": False, "status": "backup_timeout", "error": "Runtime backup timed out."}
    try:
        result = json.loads(process.stdout.strip()) if process.stdout.strip() else {}
    except json.JSONDecodeError:
        result = {}
    if process.returncode != 0 or not result.get("ok") or not output_path.is_file():
        output_path.unlink(missing_ok=True)
        stderr_text, _ = limited_text(process.stderr, 600)
        return {
            "ok": False,
            "status": str(result.get("status") or "backup_failed"),
            "error": str(result.get("error") or stderr_text or "Runtime backup failed."),
        }
    return {
        "ok": True,
        "status": "backup_ready",
        "path": str(output_path),
        "filename": output_path.name,
        "size_bytes": output_path.stat().st_size,
        "sha256": str(result.get("sha256") or ""),
    }


def send_runtime_backup(handler):
    result = create_runtime_backup()
    if not result.get("ok"):
        json_response(handler, HTTPStatus.CONFLICT, result)
        return
    path = Path(result["path"])
    try:
        handler.send_response(HTTPStatus.OK)
        handler.send_header("Content-Type", "application/gzip")
        handler.send_header("Content-Disposition", f'attachment; filename="{result["filename"]}"')
        handler.send_header("Content-Length", str(result["size_bytes"]))
        handler.send_header("Cache-Control", "no-store")
        handler.send_header("X-Content-Type-Options", "nosniff")
        handler.end_headers()
        with path.open("rb") as handle:
            shutil.copyfileobj(handle, handler.wfile, length=1024 * 1024)
    finally:
        path.unlink(missing_ok=True)


AUTH_TOKEN = configured_token()
AUTH_TOKEN_EPHEMERAL = os.environ.get("LINUX_AGENT_WEB_TOKEN_EPHEMERAL", "0") == "1"
if not AUTH_TOKEN:
    AUTH_TOKEN = secrets.token_hex(32)
    AUTH_TOKEN_EPHEMERAL = True


def persist_ephemeral_token():
    """Write an auto-generated token to a 0600 file instead of echoing it.

    The token only exists for this process run. Persisting it (rather than
    printing it) keeps it out of terminal scrollback, logs, and process
    listings while still letting the local operator read it over the same
    trust boundary that can read config.json.
    """
    EPHEMERAL_TOKEN_FILE.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(str(EPHEMERAL_TOKEN_FILE), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.write(fd, (AUTH_TOKEN + "\n").encode("utf-8"))
    finally:
        os.close(fd)
    os.chmod(EPHEMERAL_TOKEN_FILE, 0o600)


def json_response(handler, status, payload):
    request_id = str(getattr(handler, "request_id", "") or uuid.uuid4().hex)
    if isinstance(payload, dict) and payload.get("ok") is False:
        payload = normalize_error_payload(payload, request_id)
        status = domain_error_http(str(payload.get("code") or ""), status)
    body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json; charset=utf-8")
    handler.send_header("Content-Length", str(len(body)))
    handler.send_header("Cache-Control", "no-store")
    handler.send_header("X-Request-ID", request_id)
    handler.end_headers()
    handler.wfile.write(body)


def normalize_error_payload(payload, request_id=""):
    return DOMAIN_CONTRACT.normalize_error(payload, request_id)


def domain_error(code, message="", request_id="", details=None, **extra):
    codes = DOMAIN_SCHEMA.get("error_codes") if isinstance(DOMAIN_SCHEMA, dict) else {}
    spec = codes.get(code) if isinstance(codes, dict) else None
    payload = {
        "ok": False,
        "status": code,
        "code": code,
        "message": str(message or code),
        "request_id": str(request_id or ""),
        "details": details if isinstance(details, dict) else {},
        "retryable": bool(spec.get("retryable", False)) if isinstance(spec, dict) else False,
    }
    if message:
        payload["error"] = str(message)
    payload.update(extra)
    return payload


def domain_error_http(code, default=HTTPStatus.INTERNAL_SERVER_ERROR):
    codes = DOMAIN_SCHEMA.get("error_codes") if isinstance(DOMAIN_SCHEMA, dict) else {}
    spec = codes.get(code) if isinstance(codes, dict) else None
    try:
        return HTTPStatus(int(spec.get("http"))) if isinstance(spec, dict) else default
    except (TypeError, ValueError):
        return default


def json_domain_error(handler, code, message="", default=HTTPStatus.INTERNAL_SERVER_ERROR, **extra):
    json_response(
        handler,
        domain_error_http(code, default),
        domain_error(
            code,
            message,
            request_id=str(getattr(handler, "request_id", "") or ""),
            **extra,
        ),
    )


def read_json_body(handler):
    length = int(handler.headers.get("Content-Length", "0") or "0")
    if length <= 0:
        return {}
    if length > MAX_REQUEST_BODY_BYTES:
        # Drain and reject oversized bodies before allocating/parsing them.
        raise RequestBodyTooLarge(
            f"request body {length} bytes exceeds limit {MAX_REQUEST_BODY_BYTES} bytes"
        )
    raw = handler.rfile.read(length)
    def reject_constant(value):
        raise ValueError(f"non-finite JSON number is not allowed: {value}")

    def reject_duplicates(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f"duplicate JSON key is not allowed: {key}")
            result[key] = value
        return result

    try:
        value = json.loads(
            raw.decode("utf-8"),
            parse_constant=reject_constant,
            object_pairs_hook=reject_duplicates,
        )
        if not isinstance(value, dict):
            raise ValueError("request body must be a JSON object")
        return value
    except json.JSONDecodeError as exc:
        raise ValueError(f"invalid JSON body: {exc}") from exc


JOB_STORE = JobStore(
    JOBS_DB,
    allowed_statuses=DOMAIN_SCHEMA.get("job_status") or None,
    schema_version=int(DOMAIN_SCHEMA.get("schema_version", 1) or 1),
)


def read_job(job_id):
    return JOB_STORE.read(job_id)


def update_job(job_id, mutator):
    return JOB_STORE.update(job_id, mutator)


def cleanup_jobs():
    deleted = JOB_STORE.cleanup(JOB_RETENTION_HOURS)
    for job_id in deleted:
        SESSION_STORE.discard_job_artifacts(job_id)
    return deleted


def recover_interrupted_jobs():
    recovered = []
    for job in JOB_STORE.recover_interrupted(SESSION_STORE.read_job_completion):
        job_id = str(job.get("job_id") or "")
        recovered.append(job_id)
        session_id = str(job.get("session_id") or "")
        if session_id:
            append_audit_event(
                ROOT / "logs" / f"{session_id}.jsonl",
                session_id,
                "job_recovered",
                {
                    "status": job.get("result_status"),
                    "job_id": job_id,
                    "request_id": job.get("request_id"),
                    "recovery_source": job.get("recovery_source"),
                },
            )
    return recovered


_POLICY_SERVICE = None


def policy_service():
    global _POLICY_SERVICE
    if _POLICY_SERVICE is None:
        _POLICY_SERVICE = PolicyService(
            ROOT,
            config_reader=read_config,
            config_writer=write_config,
            agent_api=run_agent_api,
            audit=record_web_audit_event,
            config_public_state=config_public_state,
        )
    return _POLICY_SERVICE


def safe_policy_path(relative_path):
    return policy_service().safe_path(relative_path)


def list_policy_files():
    return policy_service().list_files()


def read_policy_file(relative_path):
    return policy_service().read_file(relative_path)


def sudo_check(password):
    return policy_service().sudo_check(password)


def update_command_guard(enabled, password):
    return policy_service().update_command_guard(enabled, password)


def append_audit_event(log_path, session_id, stage, payload=None):
    """Append through the shared Bash/Web audit implementation.

    Block and integrity failures deliberately propagate: a Web operation must
    not report success after its required audit record was refused.
    """
    outbox_event_id = (
        payload.get("outbox_event_id")
        if isinstance(payload, dict)
        else None
    )
    return append_web_audit_event(
        log_path,
        session_id,
        stage,
        payload,
        config=read_config(),
        request_id=str(getattr(REQUEST_CONTEXT, "request_id", "") or ""),
        # The shared audit writer may replace payloads in low-space degrade
        # mode. Keep the transactional outbox identity in the envelope so a
        # crash before the journal acknowledgement remains deduplicable.
        outbox_event_id=str(outbox_event_id) if outbox_event_id else None,
    )


def record_web_audit_event(stage, payload=None):
    append_audit_event(WEB_AUDIT_LOG, WEB_AUDIT_SESSION_ID, stage, payload)


SESSION_STORE = SessionStore(
    ROOT,
    SERVER_RUN_ID,
    read_config,
    append_audit_event,
    lock=WEB_AGENT_LOCK,
)


def record_web_agent_session_event(stage, payload=None):
    return SESSION_STORE.record_current(stage, payload)


def web_agent_session_state():
    try:
        state = SESSION_STORE.state()
    except SessionDataError as exc:
        return {
            "ok": False,
            "status": "persisted_session_invalid",
            "error": str(exc),
        }
    try:
        state["web_timeline"] = timeline_from_turns(
            state["session_id"],
            state.get("turns") or [],
            DOMAIN_CONTRACT,
        )
    except TimelineDataError as exc:
        return domain_error("persisted_turns_invalid", str(exc))
    return state


def initialize_web_agent_session():
    return SESSION_STORE.initialize()


def reconcile_pending_job_audits():
    reconciled = []
    for pending_job in JOB_STORE.list_audit_pending():
        job_id = str(pending_job.get("job_id") or "")
        completion = SESSION_STORE.read_job_completion(job_id)
        if completion is None:
            continue

        def mark_audit_complete(record):
            if record.get("audit_state") != "pending":
                return False
            record["audit_state"] = "complete"
            record.pop("audit_error", None)
            return None

        updated = update_job(job_id, mark_audit_complete)
        if isinstance(updated, dict) and updated.get("audit_state") == "complete":
            reconciled.append(job_id)
    return reconciled


def restore_web_agent_session(session_id):
    # Lock order is admission -> session everywhere. This makes the active-Job
    # check and workspace rotation one atomic decision with Job snapshot/admit.
    with JOB_ADMISSION_LOCK:
        with SESSION_STORE.lock:
            active_jobs = count_active_jobs()
            if active_jobs:
                return domain_error(
                    "session_busy",
                    "Cannot restore a workspace while Jobs are active.",
                    active_jobs=active_jobs,
                )
            try:
                source_turns = SESSION_STORE.read_persisted_turns(session_id)
                if source_turns:
                    timeline_from_turns(session_id, source_turns, DOMAIN_CONTRACT)
            except (TimelineDataError, SessionDataError) as exc:
                return domain_error("persisted_turns_invalid", str(exc))
            except ValueError as exc:
                return domain_error("invalid_session_id", str(exc))
            result = SESSION_STORE.restore(session_id)
    if result.get("ok"):
        restored_session = result.get("session") if isinstance(result.get("session"), dict) else {}
        active_session_id = str(restored_session.get("session_id") or "")
        result["web_timeline"] = timeline_from_turns(
            active_session_id,
            result.get("turns") or [],
            DOMAIN_CONTRACT,
        )
    return result


def leave_web_agent_session():
    with JOB_ADMISSION_LOCK:
        with SESSION_STORE.lock:
            active_jobs = count_active_jobs()
            if active_jobs:
                return domain_error(
                    "session_busy",
                    "Cannot rotate a workspace while Jobs are active.",
                    active_jobs=active_jobs,
                )
            return SESSION_STORE.leave()


def observer_runtime_config():
    config = read_config()
    observer = config.get("observer") if isinstance(config.get("observer"), dict) else {}
    enabled = str(observer.get("enabled") or "auto")
    if enabled not in {"auto", "auditd", "disabled"}:
        enabled = "auto"
    privilege = str(observer.get("privilege") or "sudo_interactive")
    if privilege not in {"sudo_interactive", "passwordless", "none"}:
        privilege = "sudo_interactive"
    max_events = safe_int(observer.get("max_events", 200) or 200, 200)
    if max_events <= 0:
        max_events = 200
    return {
        "enabled": enabled,
        "privilege": privilege,
        "max_events": max_events,
        "require": observer.get("require", False) is True,
    }


def observer_requires_permission(observer):
    return observer.get("enabled") != "disabled" and observer.get("privilege") != "none"


def observer_bootstrap_public_state(force_ok=None, extra=None):
    observer = observer_runtime_config()
    state = dict(OBSERVER_BOOTSTRAP_STATE)
    if observer.get("enabled") == "disabled":
        state.update(
            {
                "status": "disabled",
                "ok": True,
                "method": "config",
                "diagnostic": "observer.enabled is disabled in config.",
            }
        )
    state.update(extra or {})
    ok = bool(state.get("ok", True)) if force_ok is None else bool(force_ok)
    return {
        "ok": ok,
        "status": state.get("status", "pending"),
        "method": state.get("method", ""),
        "error": state.get("error", ""),
        "diagnostic": state.get("diagnostic", ""),
        "updated_at": state.get("updated_at", SERVER_STARTED_AT),
        "requires_permission": observer_requires_permission(observer),
        "observer": observer,
    }


def update_observer_bootstrap_state(status, ok, method="", error="", diagnostic=""):
    OBSERVER_BOOTSTRAP_STATE.update(
        {
            "status": status,
            "ok": bool(ok),
            "method": method,
            "error": str(error or "")[:400],
            "diagnostic": str(diagnostic or "")[:600],
            "updated_at": now_iso(),
        }
    )
    return observer_bootstrap_public_state(force_ok=ok)


def sudo_cached():
    if not shutil.which("sudo"):
        return False
    try:
        process = subprocess.run(
            ["sudo", "-n", "true"],
            text=True,
            capture_output=True,
            timeout=5,
            check=False,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False
    return process.returncode == 0


def auditctl_preflight_command():
    if os.geteuid() == 0:
        return ["auditctl", "-s"], "root"
    return ["sudo", "-n", "auditctl", "-s"], "sudo"


def observer_bootstrap_skip():
    result = update_observer_bootstrap_state(
        "skipped",
        True,
        method="user",
        diagnostic="User skipped web observer bootstrap; later jobs will record observer_unavailable if sudo credentials are not available.",
    )
    record_web_audit_event(
        "observer_bootstrap_skipped",
        {
            "status": result["status"],
            "method": result["method"],
            "diagnostic": result["diagnostic"],
            "observer": result["observer"],
        },
    )
    result["logged"] = True
    return result


def observer_bootstrap_enable(password):
    observer = observer_runtime_config()
    if observer.get("enabled") == "disabled":
        result = update_observer_bootstrap_state(
            "observer_disabled",
            False,
            method="config",
            error="observer.enabled is disabled.",
            diagnostic="Enable observer.enabled before starting auditd observer bootstrap.",
        )
        record_web_audit_event("observer_bootstrap_failed", public_observer_log_payload(result))
        return result
    if observer.get("privilege") == "none" and os.geteuid() != 0:
        result = update_observer_bootstrap_state(
            "sudo_required",
            False,
            method="none",
            error="observer.privilege is set to none.",
            diagnostic="Set observer.privilege to sudo_interactive or passwordless to enable auditd from web.",
        )
        record_web_audit_event("observer_bootstrap_failed", public_observer_log_payload(result))
        return result
    if not shutil.which("auditctl"):
        result = update_observer_bootstrap_state(
            "auditctl_not_found",
            False,
            method="auditd",
            error="auditctl is not installed.",
            diagnostic="Install auditd/auditctl or disable observer.",
        )
        record_web_audit_event("observer_bootstrap_failed", public_observer_log_payload(result))
        return result
    if not shutil.which("ausearch"):
        result = update_observer_bootstrap_state(
            "ausearch_not_found",
            False,
            method="auditd",
            error="ausearch is not installed.",
            diagnostic="Install auditd/ausearch or disable observer.",
        )
        record_web_audit_event("observer_bootstrap_failed", public_observer_log_payload(result))
        return result

    if os.geteuid() != 0 and not sudo_cached():
        if not password:
            result = update_observer_bootstrap_state(
                "sudo_required",
                False,
                method="sudo",
                error="sudo password is required.",
                diagnostic="Web has no TTY, so sudo credentials must be validated from the browser once per sudo timeout window.",
            )
            record_web_audit_event("observer_bootstrap_failed", public_observer_log_payload(result))
            return result
        check = sudo_check(password)
        if not check.get("ok"):
            result = update_observer_bootstrap_state(
                str(check.get("status") or "sudo_denied"),
                False,
                method=str(check.get("method") or "sudo"),
                error=str(check.get("error") or check.get("status") or "sudo validation failed"),
                diagnostic="sudo credential validation failed; auditd observer was not enabled for web jobs.",
            )
            record_web_audit_event("observer_bootstrap_failed", public_observer_log_payload(result))
            return result

    command, method = auditctl_preflight_command()
    try:
        process = subprocess.run(command, text=True, capture_output=True, timeout=10, check=False)
    except subprocess.TimeoutExpired:
        result = update_observer_bootstrap_state(
            "auditctl_timeout",
            False,
            method=method,
            error="auditctl validation timed out.",
            diagnostic="auditctl -s did not return within 10 seconds.",
        )
        record_web_audit_event("observer_bootstrap_failed", public_observer_log_payload(result))
        return result
    except FileNotFoundError:
        result = update_observer_bootstrap_state(
            "auditctl_not_found",
            False,
            method=method,
            error="auditctl is not installed.",
            diagnostic="Install auditd/auditctl or disable observer.",
        )
        record_web_audit_event("observer_bootstrap_failed", public_observer_log_payload(result))
        return result

    if process.returncode == 0:
        result = update_observer_bootstrap_state(
            "enabled",
            True,
            method=method,
            diagnostic="auditctl preflight succeeded; subsequent web jobs can start auditd observer while sudo credentials remain valid.",
        )
        record_web_audit_event("observer_bootstrap_enabled", public_observer_log_payload(result))
        return result

    stderr = (process.stderr or process.stdout or "auditctl validation failed").strip()[:400]
    status = "auditctl_failed"
    diagnostic = "auditctl -s failed; auditd may be unavailable or the kernel audit interface may be restricted."
    if "operation not permitted" in stderr.lower():
        status = "auditctl_permission_denied"
        diagnostic = "auditctl was rejected by the kernel audit interface; this commonly happens in containers, WSL, or hosts without CAP_AUDIT_CONTROL/auditd support."
    result = update_observer_bootstrap_state(status, False, method=method, error=stderr, diagnostic=diagnostic)
    record_web_audit_event("observer_bootstrap_failed", public_observer_log_payload(result))
    return result


def public_observer_log_payload(result):
    return {
        "status": result.get("status", ""),
        "method": result.get("method", ""),
        "error": result.get("error", ""),
        "diagnostic": result.get("diagnostic", ""),
        "observer": result.get("observer", {}),
    }


def validate_policy_content(relative_path, content):
    return policy_service().validate(relative_path, content)


def write_policy_file(relative_path, content, password):
    return policy_service().write_file(relative_path, content, password)


SKILL_SERVICE = SkillService(SKILLS_ROOT)


def safe_skills_path(relative_path):
    return SKILL_SERVICE.safe_path(relative_path)


def build_skill_tree(path):
    return SKILL_SERVICE.build_tree(path)


def list_skill_files():
    return SKILL_SERVICE.list_files()


def read_skill_file(relative_path):
    return SKILL_SERVICE.read_file(relative_path)


def limited_text(text, limit):
    raw = str(text or "")
    if limit <= 0:
        return "", len(raw)
    if len(raw) <= limit:
        return raw, 0
    return raw[:limit], len(raw) - limit


def agent_stderr_block(resource, stderr):
    if not stderr:
        return None
    is_work = resource == "work"
    limit = WORK_EXECUTION_FLOW_TEXT_LIMIT if is_work else DEFAULT_STDERR_TEXT_LIMIT
    text, truncated = limited_text(stderr, limit)
    return {
        "kind": "stdout" if is_work else "stderr",
        "title": "执行流程" if is_work else "Agent stderr",
        "text": text,
        "truncated_bytes": truncated,
    }


def update_job_partial_output(job_id, resource, stderr):
    if not job_id or not stderr:
        return
    block = agent_stderr_block(resource, stderr)
    if not block:
        return

    def apply_partial(job):
        # Never overwrite a terminal state with a stale "running" snapshot.
        if job.get("status") != "running":
            return False
        job["result"] = {
            "ok": False,
            "status": "running",
            "timeline": [],
            "approval_card": None,
            "output_blocks": [block],
        }
        job["partial_output"] = [block]
        job["result_ok"] = False
        job["result_status"] = "running"
        return None

    update_job(job_id, apply_partial)


_EXECUTION_SERVICE = None


def execution_service():
    global _EXECUTION_SERVICE
    if _EXECUTION_SERVICE is None:
        _EXECUTION_SERVICE = ExecutionService(
            root=ROOT,
            agent=AGENT,
            env_builder=agent_subprocess_env,
            session_store=SESSION_STORE,
            job_reader=read_job,
            partial_writer=update_job_partial_output,
            workspace_lock=WEB_AGENT_LOCK,
            process_registry=JOB_PROCESSES,
            process_registry_lock=JOB_PROCESSES_LOCK,
            cancel_grace=CANCEL_GRACE_SEC,
            default_job_timeout=JOB_TIMEOUT_SEC,
        )
    return _EXECUTION_SERVICE


def run_agent_api(resource, action="", payload=None, timeout=None, job_context=None, request_id=None):
    if job_context is not None:
        if not isinstance(job_context, JobSessionContext):
            raise TypeError("job_context must be JobSessionContext")
        return execution_service().run_job(
            resource,
            action,
            payload,
            context=job_context,
            timeout=timeout,
        )
    effective_request_id = str(
        request_id
        or getattr(REQUEST_CONTEXT, "request_id", "")
        or uuid.uuid4().hex
    )
    return execution_service().run_sync(
        resource,
        action,
        payload,
        timeout=timeout,
        request_id=effective_request_id,
    )


def job_input_text(payload):
    for key in ("input", "command", "ref"):
        value = payload.get(key)
        if value:
            return str(value)
    return ""


def cancelled_job_result(record=None):
    record = record if isinstance(record, dict) else {}
    return {
        "ok": False,
        "status": "cancelled",
        "error": "Job cancellation completed.",
        "cancel_requested_at": str(record.get("cancel_requested_at") or ""),
        "timeline": [],
        "approval_card": None,
        "output_blocks": [],
    }


def terminal_job_status(result):
    if result.get("status") == "cancelled":
        return "cancelled"
    if result.get("ok") or result.get("status") == "approval_required":
        return "succeeded"
    return "failed"


def run_job(job_id, job, resource, action, payload, job_context):
    del job  # The durable store is authoritative after admission.
    result = None
    terminal_status = "failed"

    def mark_running(record):
        if record.get("status") != "queued" or record.get("cancel_requested_at"):
            return False
        record["status"] = "running"
        record["phase"] = "executing"
        record["started_at"] = now_iso()
        return None

    try:
        current = update_job(job_id, mark_running)
        if current is None:
            result = {"ok": False, "status": "not_found", "error": "Job disappeared."}
        elif current.get("cancel_requested_at"):
            result = cancelled_job_result(current)
        else:
            result = run_agent_api(
                resource,
                action,
                payload,
                timeout=JOB_TIMEOUT_SEC,
                job_context=job_context,
            )
    except Exception as exc:  # noqa: BLE001 - persisted as a structured Job failure.
        result = {"ok": False, "status": "job_exception", "error": str(exc)}

    if result is None:
        result = {
            "ok": False,
            "status": "job_exception",
            "error": "Job ended without a result.",
        }
    try:
        result = DOMAIN_CONTRACT.enrich_execution_result(result)
    except DomainValidationError as exc:
        result = DOMAIN_CONTRACT.enrich_execution_result(
            {
                "ok": False,
                "status": "invalid_agent_output",
                "error": str(exc),
                "timeline": [],
                "approval_card": None,
                "output_blocks": [],
            }
        )

    # Close cancellation before durable Session state is written.  Once phase
    # becomes finalizing, cancel_job rejects late cancellation so the persisted
    # Turn and the eventual terminal Job cannot disagree.
    def begin_finalization(record):
        if record.get("status") not in ("queued", "running"):
            return False
        record["phase"] = "finalizing"
        record["execution_finished_at"] = now_iso()
        return None

    finalizing_record = update_job(job_id, begin_finalization)
    if isinstance(finalizing_record, dict) and finalizing_record.get("cancel_requested_at"):
        result = DOMAIN_CONTRACT.enrich_execution_result(cancelled_job_result(finalizing_record))

    terminal_status = terminal_job_status(result)
    merge_history = terminal_status == "succeeded" and resource == "work"
    session_completion = None
    try:
        session_completion = SESSION_STORE.complete_job(
            job_context,
            resource,
            job_input_text(payload),
            result,
            merge_history=merge_history,
        )
    except Exception as exc:  # noqa: BLE001 - durable state is part of Job success.
        result = {
            "ok": False,
            "status": "session_persistence_failed",
            "error": str(exc),
            "agent_result": result,
        }
        result = DOMAIN_CONTRACT.enrich_execution_result(result)
        terminal_status = "failed"

    def publish_terminal(record):
        if record.get("status") not in ("queued", "running"):
            return False
        record["status"] = terminal_status
        record["phase"] = "terminal"
        record["result"] = result
        record["partial_output"] = None
        record["result_ok"] = bool(result.get("ok"))
        record["result_status"] = str(result.get("status") or terminal_status)
        record["finished_at"] = now_iso()
        if isinstance(session_completion, dict):
            record["audit_state"] = str(
                session_completion.get("audit_state") or "complete"
            )
            audit_error = str(session_completion.get("audit_error") or "")
            if audit_error:
                record["audit_error"] = audit_error
            else:
                record.pop("audit_error", None)
        return None

    try:
        update_job(job_id, publish_terminal)
    finally:
        with JOB_CONTEXTS_LOCK:
            JOB_CONTEXTS.pop(job_id, None)


def count_active_jobs():
    return JOB_STORE.count_active()


def start_job(
    resource,
    action,
    payload,
    idempotency_key=None,
    request_id=None,
    retry_of=None,
    root_job_id=None,
    attempt=1,
    max_attempts=None,
):
    cleanup_jobs()
    now = now_iso()
    with JOB_ADMISSION_LOCK:
        job_id = uuid.uuid4().hex
        effective_request_id = str(request_id or uuid.uuid4().hex)
        effective_max_attempts = max(int(max_attempts or MAX_JOB_ATTEMPTS), int(attempt), 1)
        job = {
            "ok": True,
            "schema_version": int(DOMAIN_SCHEMA.get("schema_version", 1) or 1),
            "job_id": job_id,
            "resource": resource,
            "action": action,
            "status": "queued",
            "phase": "queued",
            "version": 0,
            "attempt": int(attempt),
            "max_attempts": effective_max_attempts,
            "created_at": now,
            "updated_at": now,
            "request_id": effective_request_id,
            "session_id": f"job_{job_id}",
            "payload": payload,
            "partial_output": None,
            "result": None,
            "result_ok": None,
            "result_status": None,
        }
        if retry_of:
            job["retry_of"] = str(retry_of)
            job["root_job_id"] = str(root_job_id or retry_of)
        try:
            stored, deduplicated = JOB_STORE.admit(
                job,
                idempotency_key=idempotency_key,
                max_active=MAX_ACTIVE_JOBS,
            )
        except JobCapacityExceeded as exc:
            return domain_error(
                "too_many_jobs",
                f"活动 Job 数已达上限 ({exc.max_active})，请稍后重试。",
                active_jobs=exc.active,
                active_limit=exc.max_active,
            )
        if deduplicated:
            result = dict(stored)
            result["deduplicated"] = True
            return result
        job = stored
        try:
            job_context = SESSION_STORE.create_job_context(job_id, effective_request_id)
        except Exception as exc:
            failure = {
                "ok": False,
                "status": "job_start_failed",
                "error": f"Job session context could not be initialized: {exc}",
            }

            def mark_context_failed(record):
                if record.get("status") != "queued":
                    return False
                record["status"] = "failed"
                record["phase"] = "terminal"
                record["finished_at"] = now_iso()
                record["result"] = failure
                record["result_ok"] = False
                record["result_status"] = "job_start_failed"
                return None

            update_job(job_id, mark_context_failed)
            raise
        with JOB_CONTEXTS_LOCK:
            JOB_CONTEXTS[job_id] = job_context

    try:
        threading.Thread(
            target=run_job,
            args=(job_id, job, resource, action, payload, job_context),
            daemon=True,
        ).start()
    except Exception:
        with JOB_CONTEXTS_LOCK:
            JOB_CONTEXTS.pop(job_id, None)
        SESSION_STORE.discard_job_artifacts(job_context.job_id)
        failure = {
            "ok": False,
            "status": "job_start_failed",
            "error": "The background Job thread could not be started.",
        }

        def mark_start_failed(record):
            if record.get("status") != "queued":
                return False
            record["status"] = "failed"
            record["phase"] = "terminal"
            record["finished_at"] = now_iso()
            record["result"] = failure
            record["result_ok"] = False
            record["result_status"] = "job_start_failed"
            return None

        update_job(job_id, mark_start_failed)
        raise
    return job


def retry_job(job_id, request_id=None, idempotency_key=None, expected_version=None):
    parent = read_job(job_id)
    if parent is None:
        return domain_error("not_found", "Job not found.")
    if expected_version is not None and int(parent.get("version", 0)) != int(expected_version):
        raise JobVersionConflict(job_id, expected_version, int(parent.get("version", 0)))
    if parent.get("status") not in ("failed", "cancelled"):
        return domain_error(
            "job_not_retryable",
            "Only failed or cancelled Jobs can be retried.",
            job=parent,
        )
    attempt = int(parent.get("attempt", 1) or 1) + 1
    max_attempts = int(parent.get("max_attempts", MAX_JOB_ATTEMPTS) or MAX_JOB_ATTEMPTS)
    if attempt > max_attempts:
        return domain_error(
            "job_retry_limit_reached",
            f"Job retry limit reached ({max_attempts} attempts).",
            job=parent,
        )
    retry_key = str(idempotency_key or f"retry:{job_id}:{parent.get('version', 0)}")
    retried = start_job(
        str(parent.get("resource") or ""),
        str(parent.get("action") or ""),
        parent.get("payload") if isinstance(parent.get("payload"), dict) else {},
        idempotency_key=retry_key,
        request_id=request_id,
        retry_of=job_id,
        root_job_id=str(parent.get("root_job_id") or job_id),
        attempt=attempt,
        max_attempts=max_attempts,
    )
    if retried.get("ok") and retried.get("retry_of") != job_id:
        return domain_error(
            "idempotency_conflict",
            "The idempotency key is already bound to a different Job lineage.",
            existing_job_id=retried.get("job_id"),
        )
    return retried


def expected_job_version(body):
    if not isinstance(body, dict) or "expected_version" not in body:
        return None
    value = body.get("expected_version")
    if isinstance(value, bool):
        raise ValueError("expected_version must be a non-negative integer")
    try:
        normalized = int(value)
    except (TypeError, ValueError) as exc:
        raise ValueError("expected_version must be a non-negative integer") from exc
    if normalized < 0 or str(value).strip() != str(normalized):
        raise ValueError("expected_version must be a non-negative integer")
    return normalized


def cancel_job(job_id, expected_version=None):
    job = read_job(job_id)
    if job is None:
        return {"ok": False, "status": "not_found"}
    if job.get("status") not in ("queued", "running") or job.get("phase") == "finalizing":
        return {"ok": False, "status": "not_running", "job": job}

    def request_cancel(record):
        if (
            record.get("status") not in ("queued", "running")
            or record.get("phase") == "finalizing"
        ):
            return False
        if not record.get("cancel_requested_at"):
            record["cancel_requested_at"] = now_iso()
        record["phase"] = "cancelling"
        return None

    updated = JOB_STORE.update(job_id, request_cancel, expected_version=expected_version)
    if updated is None:
        return {"ok": False, "status": "not_found"}
    if not updated.get("cancel_requested_at"):
        return {"ok": False, "status": "not_running", "job": updated}

    execution_service().terminate(job_id)

    deadline = time.monotonic() + max(5.0, CANCEL_GRACE_SEC + 3.0)
    current = updated
    while time.monotonic() < deadline:
        current = read_job(job_id)
        if current is None:
            return {"ok": False, "status": "not_found"}
        if current.get("status") not in ("queued", "running"):
            break
        time.sleep(0.02)
    if current.get("status") == "cancelled":
        return {"ok": True, "status": "cancelled", "job": current}
    if current.get("status") not in ("queued", "running"):
        return {"ok": False, "status": "not_running", "job": current}
    return domain_error(
        "job_cancellation_failed",
        "The process was signalled but the Job did not reach a durable cancelled state in time.",
        job=current,
    )


def terminate_running_jobs():
    return execution_service().terminate_all()


def shutdown_server_later(server):
    time.sleep(0.1)
    server.shutdown()


def request_server_shutdown(server):
    terminate_running_jobs()
    threading.Thread(target=shutdown_server_later, args=(server,), daemon=True).start()
    return {"ok": True, "status": "shutting_down"}


class Handler(SimpleHTTPRequestHandler):
    server_version = "LinuxAgentWeb/1.0"

    def begin_request(self):
        supplied = str(self.headers.get("X-Request-ID") or "").strip()
        if (
            supplied
            and len(supplied) <= REQUEST_ID_MAX_LENGTH
            and all(ch.isalnum() or ch in "._:-" for ch in supplied)
        ):
            self.request_id = supplied
        else:
            self.request_id = uuid.uuid4().hex
        REQUEST_CONTEXT.request_id = self.request_id

    def log_message(self, fmt, *args):
        print("%s - %s" % (self.address_string(), fmt % args), flush=True)

    def authenticated(self):
        auth = self.headers.get("Authorization", "")
        token = ""
        if auth.startswith("Bearer "):
            token = auth[len("Bearer ") :].strip()
        if not token or not AUTH_TOKEN:
            return False
        return secrets.compare_digest(token, AUTH_TOKEN)

    def require_auth(self):
        if self.authenticated():
            return True
        json_domain_error(
            self,
            "unauthorized",
            "Missing or invalid token.",
            default=HTTPStatus.UNAUTHORIZED,
        )
        return False

    def do_GET(self):
        self.begin_request()
        parsed = urlparse(self.path)
        if parsed.path.startswith("/api/"):
            if not self.require_auth():
                return
            self.handle_api_get(parsed.path)
            return
        self.serve_static(parsed.path)

    def do_POST(self):
        self.begin_request()
        parsed = urlparse(self.path)
        if not parsed.path.startswith("/api/"):
            json_response(self, HTTPStatus.NOT_FOUND, {"ok": False, "status": "not_found"})
            return
        if not self.require_auth():
            return
        try:
            body = read_json_body(self)
        except RequestBodyTooLarge as exc:
            json_domain_error(
                self,
                "request_too_large",
                str(exc),
                default=HTTPStatus.REQUEST_ENTITY_TOO_LARGE,
            )
            return
        except ValueError as exc:
            json_domain_error(
                self,
                "invalid_json",
                str(exc),
                default=HTTPStatus.BAD_REQUEST,
            )
            return
        try:
            self.handle_api_post(parsed.path, body)
        except AuditWriteBlocked as exc:
            json_domain_error(
                self,
                "audit_write_blocked",
                str(exc),
                default=HTTPStatus.INSUFFICIENT_STORAGE,
            )
        except AuditIntegrityError as exc:
            json_domain_error(
                self,
                "audit_integrity_broken",
                str(exc),
                default=HTTPStatus.CONFLICT,
            )

    def serve_static(self, path):
        if path in ("", "/"):
            path = "/index.html"
        relative = unquote(path.lstrip("/"))
        target = (STATIC_ROOT / relative).resolve()
        try:
            target.relative_to(STATIC_ROOT.resolve())
        except ValueError:
            json_response(self, HTTPStatus.FORBIDDEN, {"ok": False, "status": "forbidden"})
            return
        if not target.exists() or not target.is_file():
            json_response(self, HTTPStatus.NOT_FOUND, {"ok": False, "status": "not_found"})
            return
        content_type = "text/plain; charset=utf-8"
        if target.suffix == ".html":
            content_type = "text/html; charset=utf-8"
        elif target.suffix == ".css":
            content_type = "text/css; charset=utf-8"
        elif target.suffix == ".js":
            content_type = "application/javascript; charset=utf-8"
        elif target.suffix == ".svg":
            content_type = "image/svg+xml"
        data = target.read_bytes()
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.write(data)

    def handle_api_get(self, path):
        routes = {
            "/api/health": ("health", "get"),
            "/api/config/web": ("config", "web"),
            "/api/doctor": ("doctor", "run"),
            "/api/tools": ("tools", "list"),
            "/api/skills/validate": ("skills", "validate"),
            "/api/mcp": ("mcp", "list"),
            "/api/mcp/validate": ("mcp", "validate"),
            "/api/mcp/tools": ("mcp", "tools"),
            "/api/audit/list": ("audit", "list"),
        }
        if path == "/api/runtime/backup":
            send_runtime_backup(self)
            return
        if path == "/api/policies":
            json_response(self, HTTPStatus.OK, {"ok": True, "status": "listed", "files": list_policy_files(), "requires_sudo_to_edit": True})
            return
        if path == "/api/config":
            json_response(self, HTTPStatus.OK, config_public_state())
            return
        if path == "/api/config/providers":
            json_response(self, HTTPStatus.OK, providers_public_state())
            return
        if path == "/api/schema":
            json_response(self, HTTPStatus.OK, {"ok": True, "status": "ok", "schema": DOMAIN_SCHEMA})
            return
        if path == "/api/observer/bootstrap":
            json_response(self, HTTPStatus.OK, observer_bootstrap_public_state(force_ok=True))
            return
        if path == "/api/session/state":
            json_response(self, HTTPStatus.OK, web_agent_session_state())
            return
        if path == "/api/skills/tree":
            json_response(self, HTTPStatus.OK, list_skill_files())
            return
        if path.startswith("/api/jobs/"):
            job_id = path.rsplit("/", 1)[-1]
            if not job_id or not all(ch in "0123456789abcdef" for ch in job_id):
                json_response(self, HTTPStatus.BAD_REQUEST, {"ok": False, "status": "invalid_job_id"})
                return
            job = read_job(job_id)
            if job is None:
                json_response(self, HTTPStatus.NOT_FOUND, {"ok": False, "status": "not_found"})
                return
            json_response(self, HTTPStatus.OK, job)
            return
        route = routes.get(path)
        if not route:
            json_response(self, HTTPStatus.NOT_FOUND, {"ok": False, "status": "not_found"})
            return
        result = run_agent_api(
            route[0],
            route[1],
            {},
            timeout=120,
            request_id=self.request_id,
        )
        if path == "/api/health" and isinstance(result, dict):
            result["web_server"] = {
                "run_id": SERVER_RUN_ID,
                "started_at": SERVER_STARTED_AT,
            }
        json_response(self, HTTPStatus.OK, result)

    def handle_api_post(self, path, body):
        sync_routes = {
            "/api/sense": ("sense", "get"),
            "/api/script/review": ("script", "review"),
            "/api/terminal/review": ("terminal", "review"),
            "/api/terminal/run": ("terminal", "run"),
            "/api/edit/plan": ("edit", "plan"),
            "/api/edit/review": ("edit", "review"),
            "/api/audit/read": ("audit", "read"),
            "/api/skills/materialize": ("skills", "materialize"),
        }
        if path == "/api/policies/read":
            try:
                result = read_policy_file(str(body.get("path") or ""))
            except ValueError as exc:
                result = {"ok": False, "status": "invalid_path", "error": str(exc)}
            json_response(self, HTTPStatus.OK, result)
            return
        if path == "/api/policies/sudo-check":
            result = sudo_check(str(body.get("password") or ""))
            json_response(self, HTTPStatus.OK, result)
            return
        if path == "/api/policies/command-guard":
            result = update_command_guard(body.get("enabled"), str(body.get("password") or ""))
            json_response(self, HTTPStatus.OK, result)
            return
        if path == "/api/policies/validate":
            try:
                result = validate_policy_content(
                    str(body.get("path") or ""),
                    str(body.get("content") or ""),
                )
            except ValueError as exc:
                result = {"ok": False, "status": "invalid_path", "error": str(exc)}
            json_response(self, HTTPStatus.OK, result)
            return
        if path == "/api/policies/write":
            try:
                result = write_policy_file(
                    str(body.get("path") or ""),
                    str(body.get("content") or ""),
                    str(body.get("password") or ""),
                )
            except ValueError as exc:
                result = {"ok": False, "status": "invalid_path", "error": str(exc)}
            json_response(self, HTTPStatus.OK, result)
            return
        if path == "/api/audit/read":
            result = run_agent_api(
                "audit",
                "read",
                body,
                timeout=180,
                request_id=self.request_id,
            )
            if isinstance(result, dict) and isinstance(result.get("events"), list):
                audit_session_id = str(body.get("session_id") or result.get("session_id") or "")
                try:
                    persisted = SESSION_STORE.read_persisted_turns(audit_session_id)
                except (SessionDataError, ValueError) as exc:
                    result["web_timeline"] = None
                    result["timeline_unavailable_reason"] = "persisted_turns_invalid"
                    result["timeline_error"] = str(exc)
                else:
                    if persisted:
                        try:
                            result["web_timeline"] = timeline_from_turns(
                                audit_session_id,
                                persisted,
                                DOMAIN_CONTRACT,
                            )
                        except TimelineDataError as exc:
                            result["web_timeline"] = None
                            result["timeline_unavailable_reason"] = "persisted_turns_invalid"
                            result["timeline_error"] = str(exc)
                    else:
                        result.update(legacy_timeline_unavailable(audit_session_id))
            json_response(self, HTTPStatus.OK, result)
            return
        if path == "/api/audit/list":
            result = run_agent_api(
                "audit",
                "list",
                body,
                timeout=120,
                request_id=self.request_id,
            )
            json_response(self, HTTPStatus.OK, result)
            return
        if path == "/api/config/update":
            result = update_config_value(str(body.get("key") or ""), body.get("value"))
            json_response(self, HTTPStatus.OK, result)
            return
        if path == "/api/config/models":
            result = list_provider_models(body)
            json_response(self, HTTPStatus.OK, result)
            return
        if path == "/api/observer/bootstrap":
            action = str(body.get("action") or "")
            if action == "skip":
                result = observer_bootstrap_skip()
            elif action == "enable":
                result = observer_bootstrap_enable(str(body.get("password") or ""))
            else:
                result = {"ok": False, "status": "invalid_action", "error": "action must be enable or skip."}
            json_response(self, HTTPStatus.OK, result)
            return
        if path == "/api/session/restore":
            result = restore_web_agent_session(str(body.get("session_id") or ""))
            status = (
                HTTPStatus.OK
                if result.get("ok")
                else domain_error_http(str(result.get("status") or ""), HTTPStatus.BAD_REQUEST)
            )
            json_response(self, status, result)
            return
        if path == "/api/session/leave":
            result = leave_web_agent_session()
            status = (
                HTTPStatus.OK
                if result.get("ok")
                else domain_error_http(str(result.get("status") or ""), HTTPStatus.BAD_REQUEST)
            )
            json_response(self, status, result)
            return
        if path == "/api/skills/read":
            try:
                result = read_skill_file(str(body.get("path") or ""))
            except ValueError as exc:
                result = {"ok": False, "status": "invalid_path", "error": str(exc)}
            json_response(self, HTTPStatus.OK, result)
            return
        if path == "/api/server/shutdown":
            result = request_server_shutdown(self.server)
            json_response(self, HTTPStatus.OK, result)
            return
        if path.startswith("/api/jobs/") and path.endswith("/cancel"):
            parts = path.split("/")
            job_id = parts[-2] if len(parts) >= 4 else ""
            if not job_id or not all(ch in "0123456789abcdef" for ch in job_id):
                json_response(self, HTTPStatus.BAD_REQUEST, {"ok": False, "status": "invalid_job_id"})
                return
            try:
                expected_version = expected_job_version(body)
                cancelled = cancel_job(job_id, expected_version=expected_version)
            except JobVersionConflict as exc:
                json_domain_error(
                    self,
                    "job_version_conflict",
                    str(exc),
                    default=HTTPStatus.CONFLICT,
                    details={
                        "job_id": exc.job_id,
                        "expected_version": exc.expected_version,
                        "actual_version": exc.actual_version,
                    },
                )
                return
            except ValueError as exc:
                json_domain_error(
                    self,
                    "invalid_job_version",
                    str(exc),
                    default=HTTPStatus.BAD_REQUEST,
                )
                return
            json_response(self, HTTPStatus.OK, cancelled)
            return
        if path.startswith("/api/jobs/") and path.endswith("/retry"):
            parts = path.split("/")
            job_id = parts[-2] if len(parts) >= 4 else ""
            if not job_id or not all(ch in "0123456789abcdef" for ch in job_id):
                json_response(self, HTTPStatus.BAD_REQUEST, {"ok": False, "status": "invalid_job_id"})
                return
            retry_key = str(
                body.get("idempotency_key") or self.headers.get("Idempotency-Key") or ""
            ).strip()
            if len(retry_key) > 256 or any(ord(ch) < 32 for ch in retry_key):
                json_domain_error(
                    self,
                    "invalid_idempotency_key",
                    "idempotency key must be at most 256 characters without control characters.",
                    default=HTTPStatus.BAD_REQUEST,
                )
                return
            try:
                retried = retry_job(
                    job_id,
                    request_id=self.request_id,
                    idempotency_key=retry_key or None,
                    expected_version=expected_job_version(body),
                )
            except JobVersionConflict as exc:
                json_domain_error(
                    self,
                    "job_version_conflict",
                    str(exc),
                    default=HTTPStatus.CONFLICT,
                    details={
                        "job_id": exc.job_id,
                        "expected_version": exc.expected_version,
                        "actual_version": exc.actual_version,
                    },
                )
                return
            except IdempotencyConflict as exc:
                json_domain_error(
                    self,
                    "idempotency_conflict",
                    str(exc),
                    default=HTTPStatus.CONFLICT,
                    details={"existing_job_id": exc.existing_job_id},
                )
                return
            except ValueError as exc:
                json_domain_error(
                    self,
                    "invalid_job_version",
                    str(exc),
                    default=HTTPStatus.BAD_REQUEST,
                )
                return
            status = HTTPStatus.OK if retried.get("deduplicated") else HTTPStatus.ACCEPTED
            if not retried.get("ok"):
                status = domain_error_http(str(retried.get("status") or ""), HTTPStatus.CONFLICT)
            json_response(self, status, retried)
            return
        if path == "/api/jobs":
            resource = str(body.get("resource") or "")
            action = str(body.get("action") or "")
            payload = body.get("payload") if isinstance(body.get("payload"), dict) else {}
            allowed = {
                ("work", "run"),
                ("script", "run"),
                ("terminal", "run"),
                ("edit", "apply"),
                ("doctor", "run"),
                ("tools", "list"),
                ("skills", "validate"),
            }
            if (resource, action) not in allowed:
                json_response(self, HTTPStatus.BAD_REQUEST, {"ok": False, "status": "unsupported_job"})
                return
            idempotency_key = str(
                body.get("idempotency_key") or self.headers.get("Idempotency-Key") or ""
            ).strip()
            if len(idempotency_key) > 256 or any(ord(ch) < 32 for ch in idempotency_key):
                json_domain_error(
                    self,
                    "invalid_idempotency_key",
                    "idempotency key must be at most 256 characters without control characters.",
                    default=HTTPStatus.BAD_REQUEST,
                )
                return
            try:
                job = start_job(
                    resource,
                    action,
                    payload,
                    idempotency_key=idempotency_key or None,
                    request_id=self.request_id,
                )
            except IdempotencyConflict as exc:
                json_domain_error(
                    self,
                    "idempotency_conflict",
                    str(exc),
                    default=HTTPStatus.CONFLICT,
                    details={
                        "existing_job_id": exc.existing_job_id,
                        "existing_fingerprint": exc.existing_fingerprint,
                        "request_fingerprint": exc.request_fingerprint,
                    },
                )
                return
            except AuditWriteBlocked as exc:
                json_domain_error(
                    self,
                    "audit_write_blocked",
                    str(exc),
                    default=HTTPStatus.INSUFFICIENT_STORAGE,
                )
                return
            except AuditIntegrityError as exc:
                json_domain_error(
                    self,
                    "audit_integrity_broken",
                    str(exc),
                    default=HTTPStatus.CONFLICT,
                )
                return
            except (OSError, sqlite3.Error, SessionDataError) as exc:
                json_domain_error(
                    self,
                    "job_persistence_failed",
                    str(exc),
                    default=HTTPStatus.INTERNAL_SERVER_ERROR,
                )
                return
            if not job.get("ok") and job.get("status") == "too_many_jobs":
                json_response(
                    self,
                    domain_error_http("too_many_jobs", HTTPStatus.TOO_MANY_REQUESTS),
                    {**domain_error("too_many_jobs", job.get("error", "")), **job},
                )
                return
            json_response(self, HTTPStatus.OK if job.get("deduplicated") else HTTPStatus.ACCEPTED, job)
            return
        route = sync_routes.get(path)
        if not route:
            json_response(self, HTTPStatus.NOT_FOUND, {"ok": False, "status": "not_found"})
            return
        result = run_agent_api(
            route[0],
            route[1],
            body,
            timeout=180,
            request_id=self.request_id,
        )
        json_response(self, HTTPStatus.OK, result)


def main():
    cleanup_jobs()
    STATIC_ROOT.mkdir(parents=True, exist_ok=True)
    JOBS_DB.parent.mkdir(parents=True, exist_ok=True)
    record_web_audit_event(
        "session_started",
        {
            "request": "agent-web",
            "run_id": SERVER_RUN_ID,
            "started_at": SERVER_STARTED_AT,
        },
    )
    try:
        server = ThreadingHTTPServer((HOST, PORT), Handler)
    except OSError as exc:
        print(f"[错误] Web 控制台无法监听 http://{HOST}:{PORT}/: {exc.strerror or exc}", file=sys.stderr, flush=True)
        if exc.errno == errno.EADDRINUSE:
            print("[提示] 端口已被占用。请停止已有 agent-web 进程，或修改 config/config.json 的 web.port 后重试。", file=sys.stderr, flush=True)
        elif exc.errno == errno.EACCES:
            print("[提示] 当前用户没有权限监听该地址或端口。请换用 1024 以上端口，或调整系统权限。", file=sys.stderr, flush=True)
        elif exc.errno == errno.EADDRNOTAVAIL:
            print("[提示] web.host 不是当前机器可用地址。默认建议使用 127.0.0.1。", file=sys.stderr, flush=True)
        raise SystemExit(1) from exc

    initialize_web_agent_session()
    reconcile_pending_job_audits()
    recover_interrupted_jobs()
    try:
        print(f"[信息] Web 控制台: http://{HOST}:{PORT}/", file=sys.stderr, flush=True)
        if AUTH_TOKEN_EPHEMERAL:
            persist_ephemeral_token()
            print(
                f"[信息] 本次运行临时 token 已写入 {EPHEMERAL_TOKEN_FILE}（权限 0600，不在终端回显）。",
                file=sys.stderr,
                flush=True,
            )
        else:
            print("[信息] 使用 config/config.json 中配置的 web.token 认证。", file=sys.stderr, flush=True)
        print(f"[info] serving {STATIC_ROOT} on http://{HOST}:{PORT}/", flush=True)

        def handle_shutdown_signal(_signum, _frame):
            terminate_running_jobs()
            threading.Thread(target=shutdown_server_later, args=(server,), daemon=True).start()

        signal.signal(signal.SIGTERM, handle_shutdown_signal)
        signal.signal(signal.SIGHUP, handle_shutdown_signal)
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[信息] Web 控制台已停止。", file=sys.stderr, flush=True)
    finally:
        if AUTH_TOKEN_EPHEMERAL:
            try:
                EPHEMERAL_TOKEN_FILE.unlink()
            except OSError:
                pass
        record_web_audit_event(
            "session_finished",
            {
                "status": "stopped",
                "run_id": SERVER_RUN_ID,
            },
        )
        SESSION_STORE.finish("stopped")
        server.server_close()


if __name__ == "__main__":
    main()
