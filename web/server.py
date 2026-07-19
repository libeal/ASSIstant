#!/usr/bin/env python3

import calendar
import ipaddress
import json
import os
import errno
import secrets
import signal
import shutil
import socket
import sqlite3
import sys
import threading
import time
import uuid
from http import HTTPStatus
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import quote, unquote, urlparse


ROOT = Path(os.environ.get("LINUX_AGENT_ROOT", Path(__file__).resolve().parents[1])).resolve()
LIB_ROOT = ROOT / "lib"
if str(LIB_ROOT) not in sys.path:
    sys.path.insert(0, str(LIB_ROOT))
from provider_security import (  # noqa: E402
    host_is_trusted,
    inspect_provider_url,
    provider_security_policy,
    provider_url_host,
    provider_url_error_message,
    trusted_provider_hosts,
    validate_provider_url,
)
from subprocess_env import build_subprocess_env  # noqa: E402
WEB_ROOT = ROOT / "web"
if str(WEB_ROOT) not in sys.path:
    sys.path.insert(0, str(WEB_ROOT))
from jobs import (  # noqa: E402
    IdempotencyConflict,
    JobCapacityExceeded,
    JobStore,
    JobVersionConflict,
)
from configuration import (  # noqa: E402
    CONFIG_SECRET_FIELDS,
    ConfigStore,
    normalize_config_value,
    provider_failover_api_key_envs,
    validate_config_relationships,
    write_nested_config_value,
)
from domain import DomainContract, DomainValidationError  # noqa: E402
from execution import ExecutionService  # noqa: E402
from observer import ObserverService  # noqa: E402
from policy import PolicyService  # noqa: E402
from provider import ProviderSecurityHelpers, ProviderService  # noqa: E402
from sessions import (  # noqa: E402
    JobSessionContext,
    SessionDataError,
    SessionStore,
    result_context_eligible,
)
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
from authentication import BootstrapCredential  # noqa: E402
from metrics import (  # noqa: E402
    create_default_registry,
    normalize_route,
)
STATIC_ROOT = ROOT / "web" / "static"
LOG_ROOT = (ROOT / "logs").resolve()
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
MAX_HTTP_WORKERS = 32
HTTP_SOCKET_TIMEOUT_SEC = 30
MAX_ACTIVE_JOBS = int(os.environ.get("LINUX_AGENT_WEB_MAX_ACTIVE_JOBS", "4") or "4")
JOB_TIMEOUT_SEC = int(os.environ.get("LINUX_AGENT_WEB_JOB_TIMEOUT_SEC", "900") or "900")
MAX_JOB_ATTEMPTS = int(os.environ.get("LINUX_AGENT_WEB_MAX_JOB_ATTEMPTS", "3") or "3")
CANCEL_GRACE_SEC = int(os.environ.get("LINUX_AGENT_WEB_CANCEL_GRACE_SEC", "2") or "2")
REQUEST_ID_MAX_LENGTH = 128


class RequestBodyTooLarge(ValueError):
    """Raised when an inbound request body exceeds MAX_REQUEST_BODY_BYTES."""


SERVER_RUN_ID = uuid.uuid4().hex
SERVER_STARTED_AT = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
PROCESS_START_TIME = time.time()
METRICS = create_default_registry(process_start_time=PROCESS_START_TIME)
METRICS.set_gauge("linux_agent_process_start_time_seconds", PROCESS_START_TIME)

API_KEY_PLACEHOLDER = "please-set-your-api-key"
EPHEMERAL_TOKEN_FILE = ROOT / "tmp" / "web" / "auth-token"
WEB_AUDIT_SESSION_ID = f"web_{SERVER_RUN_ID[:16]}"
WEB_AUDIT_LOG = LOG_ROOT / f"{WEB_AUDIT_SESSION_ID}.jsonl"
REMOTE_MODE = os.environ.get("LINUX_AGENT_REMOTE_MODE", "0") == "1"
RUNTIME_SECRET_LOCK = threading.RLock()
RUNTIME_API_KEY = ""
CONFIG_STORE = ConfigStore(CONFIG_PATH)


def read_config():
    return CONFIG_STORE.read()


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

AGENT_API_RESPONSE_PROFILES = {
    "health": {"required_fields": {"root": str, "web": dict}},
    "config_web": {"required_fields": {"web": dict}},
    "doctor": {"required_fields": {"doctor": dict}},
    "tools": {"required_fields": {"scripts": list}},
    "skills_validate": {"required_fields": {"validation": dict}},
    "mcp_list": {"required_fields": {"servers": list}},
    "mcp_validate": {"required_fields": {"validation": dict}},
    "mcp_tools": {"required_fields": {"servers": list, "tools": list}},
    "audit_list": {"required_fields": {"sessions": list}},
    "audit_read": {"required_fields": {"events": list}},
    "sense": {"required_fields": {"sense": dict}},
    "review": {"required_fields": {"review": dict, "output_blocks": list}},
    "terminal_run": {"execution_result": True},
    "edit_plan": {"required_fields": {"edit": dict}},
    "edit_review": {"required_fields": {"reviews": list, "scripts": list}},
    "skill_materialize": {"required_fields": {"skill": str, "files": list}},
}


def validate_agent_api_response(result, profile):
    specification = AGENT_API_RESPONSE_PROFILES[profile]
    return DOMAIN_CONTRACT.validate_api_result(result, **specification)


def write_config(config):
    CONFIG_STORE.write(config)


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
        url_host=provider_url_host,
        trusted_hosts=trusted_provider_hosts,
        host_is_trusted=host_is_trusted,
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
    provider_resilience = config.get("provider_resilience") if isinstance(config.get("provider_resilience"), dict) else {}
    provider_failover = provider_resilience.get("failover") if isinstance(provider_resilience.get("failover"), list) else []
    web = config.get("web") if isinstance(config.get("web"), dict) else {}
    metrics_configured = web.get("metrics_enabled", True)
    metrics_public = metrics_configured if isinstance(metrics_configured, bool) else False
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
            "provider_resilience": {
                "enabled": provider_resilience.get("enabled", True) is True,
                "max_attempts": safe_int(provider_resilience.get("max_attempts", 3), 3),
                "backoff_initial_ms": safe_int(provider_resilience.get("backoff_initial_ms", 250), 250),
                "backoff_max_ms": safe_int(provider_resilience.get("backoff_max_ms", 2000), 2000),
                "circuit_failure_threshold": safe_int(provider_resilience.get("circuit_failure_threshold", 5), 5),
                "circuit_open_sec": safe_int(provider_resilience.get("circuit_open_sec", 60), 60),
                "failover_count": len(provider_failover),
            },
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
                "max_output_bytes": safe_int(execution.get("max_output_bytes", 1048576) or 1048576, 1048576),
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
                "metrics_enabled": metrics_public,
            },
        },
    }


def update_config_values(changes):
    global RUNTIME_API_KEY
    if not isinstance(changes, dict) or not changes or len(changes) > 64:
        return {
            "ok": False,
            "status": "invalid_config_value",
            "error": "changes must be a non-empty object with at most 64 entries.",
        }

    normalized_changes = {}
    for raw_key, value in changes.items():
        if not isinstance(raw_key, str) or not raw_key:
            return {"ok": False, "status": "invalid_config_value", "error": "Configuration keys must be non-empty strings."}
        key = raw_key
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
        if key == "api_key":
            normalized_changes[key] = str(value or "")
            continue
        normalized, error = normalize_config_value(key, value)
        if error:
            return {"ok": False, "status": "invalid_config_value", "error": error}
        normalized_changes[key] = normalized

    file_changes = {
        key: value
        for key, value in normalized_changes.items()
        if not (REMOTE_MODE and key == "api_key")
    }

    def apply_changes(config):
        for key, value in file_changes.items():
            if key == "api_key":
                if value:
                    config["api_key"] = value
                else:
                    config.pop("api_key", None)
            else:
                write_nested_config_value(config, key, value)
        relationship_error = validate_config_relationships(config)
        if relationship_error:
            raise ValueError(relationship_error)

    try:
        if file_changes:
            CONFIG_STORE.update(apply_changes)
    except ValueError as exc:
        return {"ok": False, "status": "invalid_config_value", "error": str(exc)}

    if REMOTE_MODE and "api_key" in normalized_changes:
        with RUNTIME_SECRET_LOCK:
            RUNTIME_API_KEY = normalized_changes["api_key"]

    result = config_public_state()
    result["status"] = "updated"
    result["updated"] = {
        key: ("configured" if value else "cleared") if key in CONFIG_SECRET_FIELDS else value
        for key, value in normalized_changes.items()
    }
    return result


def write_api_key_secret(value):
    return update_config_values({"api_key": value})


def update_config_value(key, value):
    return update_config_values({key: value})


def configured_token():
    if TOKEN:
        return TOKEN
    web = read_config().get("web", {})
    return str(web.get("token") or "")


def agent_subprocess_env(include_api_key=False):
    # Explicit allowlist environment: never inherit ambient cloud credentials or
    # tokens from the parent Web process. AI secrets are injected only for the
    # dedicated AI-calling actions.
    env = build_subprocess_env(include_api_key=False)
    env["LINUX_AGENT_WEB"] = "1"
    if not include_api_key:
        return env
    config = read_config()
    if REMOTE_MODE:
        remote = config.get("remote", {})
        transmission_allowed = isinstance(remote, dict) and bool(remote.get("allow_api_key_transmission", False))
        with RUNTIME_SECRET_LOCK:
            runtime_key = RUNTIME_API_KEY
        if transmission_allowed and secret_value_configured(runtime_key):
            env["LINUX_AGENT_API_KEY"] = runtime_key
        if transmission_allowed:
            for name in provider_failover_api_key_envs(config):
                value = os.environ.get(name, "")
                if secret_value_configured(value):
                    env[name] = value
    else:
        # Local mode: the Bash core reads the key from config.json when it is not
        # in the environment, so we only forward an operator-supplied env key.
        parent_key = os.environ.get("LINUX_AGENT_API_KEY", "")
        if secret_value_configured(parent_key):
            env["LINUX_AGENT_API_KEY"] = parent_key
        for name in provider_failover_api_key_envs(config):
            value = os.environ.get(name, "")
            if secret_value_configured(value):
                env[name] = value
    return env


def create_runtime_backup():
    if not REMOTE_MODE:
        return {"ok": False, "status": "backup_unavailable", "error": "Runtime backup is only available in remote mode."}
    output_path = ROOT.parent / f"linux-agent-runtime-backup-{uuid.uuid4().hex}.tar.gz"
    backup_env = agent_subprocess_env()
    try:
        outcome = execution_service().run_external_sync(
            ["bash", str(AGENT), "backup", str(output_path)],
            backup_env,
            timeout=180,
            resource="backup",
        )
    except (OSError, RuntimeError, ValueError) as exc:
        output_path.unlink(missing_ok=True)
        return {"ok": False, "status": "backup_failed", "error": str(exc)}
    if outcome.timed_out:
        output_path.unlink(missing_ok=True)
        return {"ok": False, "status": "backup_timeout", "error": "Runtime backup timed out."}
    if outcome.output_limit_exceeded:
        output_path.unlink(missing_ok=True)
        return {
            "ok": False,
            "status": "output_limit_exceeded",
            "error": "Runtime backup output exceeded execution.max_output_bytes.",
        }
    try:
        result = json.loads(outcome.stdout.strip()) if outcome.stdout.strip() else {}
    except json.JSONDecodeError:
        result = {}
    if outcome.returncode != 0 or not result.get("ok") or not output_path.is_file():
        output_path.unlink(missing_ok=True)
        stderr_text, _ = limited_text(outcome.stderr, 600)
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

WEB_BOOTSTRAP = BootstrapCredential()


def auto_open_enabled():
    """Only auto-open a browser for an interactive local desktop session."""
    if REMOTE_MODE:
        return False
    configured = os.environ.get("LINUX_AGENT_WEB_AUTO_OPEN", "").strip().lower()
    if configured in {"0", "false", "no", "off"}:
        return False
    if configured in {"1", "true", "yes", "on"}:
        return True
    return sys.platform == "darwin" or bool(os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY"))


def auto_open_web_console():
    """Open the UI with a one-time fragment credential when a desktop is present."""
    if not auto_open_enabled():
        return False
    bootstrap_secret = WEB_BOOTSTRAP.issue(ttl_seconds=90)
    browser_host = HOST
    if browser_host in {"0.0.0.0", "::", "[::]"}:
        browser_host = "127.0.0.1"
    else:
        try:
            if ipaddress.ip_address(browser_host.strip("[]")).version == 6:
                browser_host = f"[{browser_host.strip('[]')}]"
        except ValueError:
            pass
    url = f"http://{browser_host}:{PORT}/#bootstrap={quote(bootstrap_secret, safe='')}"

    def open_browser():
        try:
            import webbrowser

            webbrowser.open(url, new=2, autoraise=True)
        except Exception:
            # Browser launch is a convenience; the server and manual token flow
            # must remain available when no graphical browser is installed.
            pass

    threading.Thread(target=open_browser, name="web-browser-launch", daemon=True).start()
    return True


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


def metrics_enabled(config=None):
    cfg = config if isinstance(config, dict) else read_config()
    web = cfg.get("web") if isinstance(cfg.get("web"), dict) else {}
    if "metrics_enabled" not in web:
        return True
    value = web.get("metrics_enabled")
    return value if isinstance(value, bool) else False


def build_version_label(config=None):
    cfg = config if isinstance(config, dict) else read_config()
    remote = cfg.get("remote") if isinstance(cfg.get("remote"), dict) else {}
    version = str(
        remote.get("release_version")
        or os.environ.get("LINUX_AGENT_REMOTE_RELEASE_VERSION")
        or "local"
    ).strip() or "local"
    return version


def record_http_request(method, path, status_code):
    METRICS.inc(
        "linux_agent_http_requests_total",
        labels={
            "method": str(method or "GET").upper(),
            "route": normalize_route(path),
            "status": str(int(status_code)),
        },
    )


def record_job_completion(record, terminal_status):
    result_label = str(terminal_status or record.get("status") or "failed")
    METRICS.inc(
        "linux_agent_jobs_completed_total",
        labels={"result": result_label},
    )
    started = str(record.get("started_at") or record.get("created_at") or "")
    finished = str(record.get("finished_at") or "")
    duration = None
    if started and finished:
        try:
            # ISO Z timestamps produced by now_iso()
            def parse_iso(value):
                return calendar.timegm(time.strptime(value, "%Y-%m-%dT%H:%M:%SZ"))

            duration = max(0.0, parse_iso(finished) - parse_iso(started))
        except (TypeError, ValueError, OverflowError):
            duration = None
    if duration is not None:
        METRICS.inc("linux_agent_job_duration_seconds_sum", amount=duration)
        METRICS.inc("linux_agent_job_duration_seconds_count")


def job_status_gauges():
    try:
        counts = JOB_STORE.status_counts()
    except Exception:  # noqa: BLE001 - metrics scrape must not fail the process
        counts = {}
    gauges = []
    total_active = 0
    for status in sorted(set(list(counts) + ["queued", "running", "succeeded", "failed", "cancelled"])):
        value = int(counts.get(status, 0) or 0)
        gauges.append(("linux_agent_jobs", {"status": status}, value))
        if status in ("queued", "running"):
            total_active += value
    gauges.append(("linux_agent_jobs_active", {}, total_active))
    return gauges


def render_metrics_text():
    version = build_version_label()
    extra = [
        ("linux_agent_build_info", {"version": version}, 1),
        ("linux_agent_process_start_time_seconds", {}, PROCESS_START_TIME),
    ]
    extra.extend(job_status_gauges())
    return METRICS.render_prometheus_text(extra_gauges=extra)


def write_plain_response(handler, status, body, content_type="text/plain; charset=utf-8"):
    data = body if isinstance(body, (bytes, bytearray)) else str(body).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", content_type)
    handler.send_header("Content-Length", str(len(data)))
    handler.send_header("Cache-Control", "no-store")
    request_id = str(getattr(handler, "request_id", "") or uuid.uuid4().hex)
    handler.send_header("X-Request-ID", request_id)
    handler.end_headers()
    handler.wfile.write(data)


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
    transfer_encoding = str(handler.headers.get("Transfer-Encoding") or "").strip()
    if transfer_encoding:
        raise ValueError("Transfer-Encoding request bodies are not supported")
    raw_length = str(handler.headers.get("Content-Length", "0") or "0").strip()
    try:
        length = int(raw_length)
    except ValueError as exc:
        raise ValueError("Content-Length must be a non-negative integer") from exc
    if length < 0:
        raise ValueError("Content-Length must be a non-negative integer")
    if length == 0:
        return {}
    if length > MAX_REQUEST_BODY_BYTES:
        # Drain and reject oversized bodies before allocating/parsing them.
        raise RequestBodyTooLarge(
            f"request body {length} bytes exceeds limit {MAX_REQUEST_BODY_BYTES} bytes"
        )
    try:
        raw = handler.rfile.read(length)
    except (OSError, TimeoutError) as exc:
        raise ValueError("request body could not be read completely") from exc
    if len(raw) != length:
        raise ValueError("request body ended before Content-Length bytes were received")
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
                LOG_ROOT / f"{session_id}.jsonl",
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
            config_updater=CONFIG_STORE.update,
            agent_api=run_agent_api,
            audit=record_web_audit_event,
            config_public_state=config_public_state,
            env_builder=agent_subprocess_env,
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
    candidate = Path(log_path)
    resolved_parent = candidate.parent.resolve()
    if resolved_parent != LOG_ROOT:
        raise AuditIntegrityError(
            f"Web audit path escapes the managed log directory: {candidate}"
        )
    resolved_log_path = resolved_parent / candidate.name
    result = append_web_audit_event(
        resolved_log_path,
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
    METRICS.inc("linux_agent_web_audit_events_total")
    return result


def record_web_audit_event(stage, payload=None):
    return append_audit_event(WEB_AUDIT_LOG, WEB_AUDIT_SESSION_ID, stage, payload)


OBSERVER_SERVICE = ObserverService(
    config_reader=read_config,
    audit=record_web_audit_event,
    sudo_check=sudo_check,
    env_builder=agent_subprocess_env,
    lib_root=LIB_ROOT,
    server_started_at=SERVER_STARTED_AT,
    now_iso=now_iso,
)


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
    return OBSERVER_SERVICE.runtime_config()


def observer_bootstrap_public_state(force_ok=None, extra=None):
    return OBSERVER_SERVICE.public_state(force_ok=force_ok, extra=extra)


def observer_bootstrap_skip():
    return OBSERVER_SERVICE.skip()


def observer_bootstrap_enable(password):
    return OBSERVER_SERVICE.enable(password)


def validate_policy_content(relative_path, content):
    return policy_service().validate(relative_path, content)


def write_policy_file(relative_path, content, password):
    return policy_service().write_file(relative_path, content, password)


SKILL_SERVICE = SkillService(
    SKILLS_ROOT,
    manifest_validator=DOMAIN_CONTRACT.validate_skill_manifest,
)


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
    config = read_config()
    execution = config.get("execution") if isinstance(config.get("execution"), dict) else {}
    max_output_bytes = safe_int(execution.get("max_output_bytes", 1048576) or 1048576, 1048576)
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
            max_output_bytes=max_output_bytes,
        )
    else:
        # Each execution snapshots this value before spawning, so a config update
        # applies to later Jobs without mutating an in-flight process limit.
        _EXECUTION_SERVICE.max_output_bytes = max_output_bytes
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
    if (
        isinstance(finalizing_record, dict)
        and finalizing_record.get("cancel_requested_at")
        and result.get("status") not in {"answered", "executed"}
    ):
        result = DOMAIN_CONTRACT.enrich_execution_result(cancelled_job_result(finalizing_record))

    terminal_status = terminal_job_status(result)
    merge_history = result_context_eligible(resource, result)
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
        terminal_record = update_job(job_id, publish_terminal)
        if isinstance(terminal_record, dict):
            record_job_completion(terminal_record, terminal_status)
        else:
            record_job_completion({"status": terminal_status}, terminal_status)
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


def notify_service_ready():
    notify_socket = os.environ.get("NOTIFY_SOCKET", "")
    if not notify_socket:
        return
    address = "\0" + notify_socket[1:] if notify_socket.startswith("@") else notify_socket
    with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as client:
        client.connect(address)
        client.sendall(b"READY=1\nSTATUS=Web console is ready")


class BoundedThreadingHTTPServer(ThreadingHTTPServer):
    """Threading HTTP server with a fixed admission cap."""

    daemon_threads = True

    def __init__(self, server_address, request_handler_class):
        self._worker_slots = threading.BoundedSemaphore(MAX_HTTP_WORKERS)
        super().__init__(server_address, request_handler_class)

    def process_request(self, request, client_address):
        if not self._worker_slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self._worker_slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self._worker_slots.release()


class Handler(SimpleHTTPRequestHandler):
    server_version = "LinuxAgentWeb/1.0"

    def setup(self):
        super().setup()
        self.connection.settimeout(HTTP_SOCKET_TIMEOUT_SEC)

    def begin_request(self):
        self._metrics_recorded = False
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

    def send_response(self, code, message=None):
        super().send_response(code, message)
        if getattr(self, "_metrics_recorded", False):
            return
        self._metrics_recorded = True
        try:
            path = urlparse(getattr(self, "path", "") or "").path
            record_http_request(getattr(self, "command", "GET"), path, int(code))
        except Exception:
            pass

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
        if parsed.path == "/api/auth/bootstrap":
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
            token = WEB_BOOTSTRAP.consume(
                body.get("bootstrap") if isinstance(body, dict) else "",
                AUTH_TOKEN,
            )
            if not token:
                json_domain_error(
                    self,
                    "unauthorized",
                    "Missing or invalid bootstrap credential.",
                    default=HTTPStatus.UNAUTHORIZED,
                )
                return
            json_response(self, HTTPStatus.OK, {"ok": True, "status": "authenticated", "token": token})
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
        if path == "/api/metrics":
            if not metrics_enabled():
                json_domain_error(
                    self,
                    "metrics_disabled",
                    "Prometheus 指标端点已关闭。",
                    default=HTTPStatus.NOT_FOUND,
                )
                return
            body = render_metrics_text()
            write_plain_response(
                self,
                HTTPStatus.OK,
                body,
                content_type="text/plain; version=0.0.4; charset=utf-8",
            )
            return
        routes = {
            "/api/health": ("health", "get", "health"),
            "/api/config/web": ("config", "web", "config_web"),
            "/api/doctor": ("doctor", "run", "doctor"),
            "/api/tools": ("tools", "list", "tools"),
            "/api/skills/validate": ("skills", "validate", "skills_validate"),
            "/api/mcp": ("mcp", "list", "mcp_list"),
            "/api/mcp/validate": ("mcp", "validate", "mcp_validate"),
            "/api/mcp/tools": ("mcp", "tools", "mcp_tools"),
            "/api/audit/list": ("audit", "list", "audit_list"),
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
            try:
                result = list_skill_files()
            except ValueError as exc:
                json_domain_error(
                    self,
                    "invalid_skill_manifest",
                    str(exc),
                    default=HTTPStatus.CONFLICT,
                )
                return
            json_response(self, HTTPStatus.OK, result)
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
        try:
            validate_agent_api_response(result, route[2])
        except DomainValidationError as exc:
            json_domain_error(
                self,
                "invalid_agent_output",
                str(exc),
                default=HTTPStatus.BAD_GATEWAY,
            )
            return
        if path == "/api/health" and isinstance(result, dict):
            result["web_server"] = {
                "run_id": SERVER_RUN_ID,
                "started_at": SERVER_STARTED_AT,
            }
        json_response(self, HTTPStatus.OK, result)

    def handle_api_post(self, path, body):
        sync_routes = {
            "/api/sense": ("sense", "get", "sense"),
            "/api/script/review": ("script", "review", "review"),
            "/api/terminal/review": ("terminal", "review", "review"),
            "/api/terminal/run": ("terminal", "run", "terminal_run"),
            "/api/edit/plan": ("edit", "plan", "edit_plan"),
            "/api/edit/review": ("edit", "review", "edit_review"),
            "/api/skills/materialize": ("skills", "materialize", "skill_materialize"),
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
            try:
                validate_agent_api_response(result, "audit_read")
            except DomainValidationError as exc:
                json_domain_error(
                    self,
                    "invalid_agent_output",
                    str(exc),
                    default=HTTPStatus.BAD_GATEWAY,
                )
                return
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
            try:
                validate_agent_api_response(result, "audit_list")
            except DomainValidationError as exc:
                json_domain_error(
                    self,
                    "invalid_agent_output",
                    str(exc),
                    default=HTTPStatus.BAD_GATEWAY,
                )
                return
            json_response(self, HTTPStatus.OK, result)
            return
        if path == "/api/config/update":
            if isinstance(body.get("changes"), dict):
                result = update_config_values(body["changes"])
            else:
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
        try:
            validate_agent_api_response(result, route[2])
        except DomainValidationError as exc:
            json_domain_error(
                self,
                "invalid_agent_output",
                str(exc),
                default=HTTPStatus.BAD_GATEWAY,
            )
            return
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
        server = BoundedThreadingHTTPServer((HOST, PORT), Handler)
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
        notify_service_ready()
        auto_open_web_console()

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
