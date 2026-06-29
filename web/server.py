#!/usr/bin/env python3

import json
import os
import errno
import signal
import shutil
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
STATIC_ROOT = ROOT / "web" / "static"
JOBS_ROOT = ROOT / "tmp" / "web" / "jobs"
POLICIES_ROOT = ROOT / "policies"
SKILLS_ROOT = ROOT / "skills"
CONFIG_PATH = ROOT / "config" / "config.json"
AGENT = ROOT / "bin" / "agent"
HOST = os.environ.get("LINUX_AGENT_WEB_HOST", "127.0.0.1")
PORT = int(os.environ.get("LINUX_AGENT_WEB_PORT", "8765"))
TOKEN = os.environ.get("LINUX_AGENT_WEB_TOKEN", "")
JOB_RETENTION_HOURS = int(os.environ.get("LINUX_AGENT_WEB_JOB_RETENTION_HOURS", "24"))
JOB_PROCESSES = {}
JOB_PROCESSES_LOCK = threading.Lock()
SERVER_RUN_ID = uuid.uuid4().hex
SERVER_STARTED_AT = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
API_KEY_PLACEHOLDER = "please-set-your-api-key"
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


def read_config():
    try:
        with CONFIG_PATH.open("r", encoding="utf-8") as handle:
            return json.load(handle)
    except FileNotFoundError:
        return {}


def write_config(config):
    CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = CONFIG_PATH.with_suffix(".json.tmp")
    with tmp_path.open("w", encoding="utf-8") as handle:
        json.dump(config, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
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
    env_configured = secret_value_configured(os.environ.get("LINUX_AGENT_API_KEY", ""))
    config_configured = secret_value_configured(config.get("api_key", ""))

    if env_configured:
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


def config_public_state():
    config = read_config()
    agent_loop = config.get("agent_loop") if isinstance(config.get("agent_loop"), dict) else {}
    approvals = config.get("approvals") if isinstance(config.get("approvals"), dict) else {}
    auto_approvals = approvals.get("auto") if isinstance(approvals.get("auto"), dict) else {}
    observer = config.get("observer") if isinstance(config.get("observer"), dict) else {}
    execution = config.get("execution") if isinstance(config.get("execution"), dict) else {}
    web = config.get("web") if isinstance(config.get("web"), dict) else {}
    key_state = api_key_state(config)
    return {
        "ok": True,
        "status": "read",
        "config": {
            "provider": config.get("provider", ""),
            "api_url": config.get("api_url", ""),
            "api_key_configured": key_state["configured"],
            "api_key_source": key_state["source"],
            "api_key_configured_in_config": key_state["config_configured"],
            "model": config.get("model", ""),
            "request_timeout_sec": config.get("request_timeout_sec", 90),
            "context_turns": config.get("context_turns", 6),
            "agent_loop": {
                "enabled_for_work": bool(agent_loop.get("enabled_for_work", True)),
                "observation_text_limit": int(agent_loop.get("observation_text_limit", 4000) or 4000),
                "thinking_trace_enabled": bool(agent_loop.get("thinking_trace_enabled", False)),
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
                "privilege": observer.get("privilege", ""),
                "max_events": observer.get("max_events", 200),
            },
            "execution": {
                "min_privilege_proxy": bool(execution.get("min_privilege_proxy", True)),
                "least_privilege_user": execution.get("least_privilege_user", "nobody"),
            },
            "skills_dir": config.get("skills_dir", ""),
            "remote_script_policy": config.get("remote_script_policy", "download_review"),
            "web": {
                "enabled": bool(web.get("enabled", True)),
                "host": web.get("host", HOST),
                "port": safe_int(web.get("port", PORT) or PORT, PORT),
                "token_configured": bool(web.get("token") or TOKEN),
                "job_retention_hours": safe_int(web.get("job_retention_hours", JOB_RETENTION_HOURS) or JOB_RETENTION_HOURS, JOB_RETENTION_HOURS),
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
    "execution.min_privilege_proxy": {"type": "bool"},
    "execution.least_privilege_user": {"type": "str", "min": 1},
    "skills_dir": {"type": "str", "min": 0},
    "remote_script_policy": {"type": "enum", "values": {"download_review", "disabled"}},
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
    secret = str(value or "")
    config = read_config()

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


AUTH_TOKEN = configured_token()
if not AUTH_TOKEN:
    AUTH_TOKEN = uuid.uuid4().hex
    print("[警告] web.token 未配置，已生成本次运行临时 token。", file=sys.stderr, flush=True)


def json_response(handler, status, payload):
    body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json; charset=utf-8")
    handler.send_header("Content-Length", str(len(body)))
    handler.send_header("Cache-Control", "no-store")
    handler.end_headers()
    handler.wfile.write(body)


def read_json_body(handler):
    length = int(handler.headers.get("Content-Length", "0") or "0")
    if length <= 0:
        return {}
    raw = handler.rfile.read(length)
    try:
        return json.loads(raw.decode("utf-8"))
    except json.JSONDecodeError as exc:
        raise ValueError(f"invalid JSON body: {exc}") from exc


def job_path(job_id):
    return JOBS_ROOT / f"{job_id}.json"


def write_job(job_id, payload):
    JOBS_ROOT.mkdir(parents=True, exist_ok=True)
    path = job_path(job_id)
    tmp_path = path.with_suffix(".json.tmp")
    with tmp_path.open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False, separators=(",", ":"))
    tmp_path.replace(path)


def read_job(job_id):
    path = job_path(job_id)
    if not path.exists():
        return None
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def cleanup_jobs():
    JOBS_ROOT.mkdir(parents=True, exist_ok=True)
    cutoff = time.time() - (JOB_RETENTION_HOURS * 3600)
    for path in JOBS_ROOT.glob("*.json"):
        try:
            if path.stat().st_mtime < cutoff:
                path.unlink()
        except OSError:
            continue


def safe_policy_path(relative_path):
    if not isinstance(relative_path, str) or not relative_path:
        raise ValueError("policy path is required")
    candidate = Path(relative_path)
    if candidate.is_absolute() or ".." in candidate.parts:
        raise ValueError("policy path must be relative to policies/")
    target = (POLICIES_ROOT / candidate).resolve()
    target.relative_to(POLICIES_ROOT.resolve())
    if target.suffix != ".json":
        raise ValueError("only JSON policy files are editable from the web console")
    return target


def list_policy_files():
    POLICIES_ROOT.mkdir(parents=True, exist_ok=True)
    files = []
    for path in sorted(POLICIES_ROOT.glob("*.json")):
        stat = path.stat()
        files.append(
            {
                "path": path.relative_to(POLICIES_ROOT).as_posix(),
                "size_bytes": stat.st_size,
                "mtime": int(stat.st_mtime),
            }
        )
    return files


def read_policy_file(relative_path):
    target = safe_policy_path(relative_path)
    if not target.exists() or not target.is_file():
        return {"ok": False, "status": "not_found", "error": "Policy file not found."}
    content = target.read_text(encoding="utf-8")
    parsed = None
    try:
        parsed = json.loads(content)
    except json.JSONDecodeError:
        parsed = None
    return {
        "ok": True,
        "status": "read",
        "path": target.relative_to(POLICIES_ROOT).as_posix(),
        "content": content,
        "json": parsed,
    }


def sudo_check(password):
    if os.geteuid() == 0:
        return {"ok": True, "status": "sudo_ok", "method": "root"}
    if not password:
        return {"ok": False, "status": "sudo_required", "error": "sudo password is required."}
    try:
        process = subprocess.run(
            ["sudo", "-S", "-p", "", "-v"],
            input=f"{password}\n",
            text=True,
            capture_output=True,
            timeout=10,
            check=False,
        )
    except FileNotFoundError:
        return {"ok": False, "status": "sudo_not_found", "error": "sudo is not installed."}
    except subprocess.TimeoutExpired:
        return {"ok": False, "status": "sudo_timeout", "error": "sudo validation timed out."}
    if process.returncode == 0:
        return {"ok": True, "status": "sudo_ok", "method": "sudo"}
    return {
        "ok": False,
        "status": "sudo_denied",
        "error": (process.stderr or "sudo validation failed").strip()[:400],
    }


def record_web_audit_event(stage, payload=None):
    payload = payload if isinstance(payload, dict) else {}
    WEB_AUDIT_LOG.parent.mkdir(parents=True, exist_ok=True)
    event = {
        "timestamp": now_iso(),
        "session_id": WEB_AUDIT_SESSION_ID,
        "stage": stage,
        "payload": payload,
    }
    with WEB_AUDIT_LOG.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(event, ensure_ascii=False, separators=(",", ":")))
        handle.write("\n")


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
    try:
        safe_policy_path(relative_path)
    except ValueError as exc:
        return {"ok": False, "status": "invalid_path", "error": str(exc)}
    return run_agent_api("policy", "validate", {"path": relative_path, "content": content}, timeout=60)


def write_policy_file(relative_path, content, password):
    target = safe_policy_path(relative_path)
    if not isinstance(content, str) or not content.strip():
        return {"ok": False, "status": "empty_content", "error": "Policy content is empty."}
    try:
        parsed = json.loads(content)
    except json.JSONDecodeError as exc:
        return {"ok": False, "status": "invalid_json", "error": str(exc)}

    normalized_content = json.dumps(parsed, ensure_ascii=False, indent=2) + "\n"
    validation = validate_policy_content(relative_path, normalized_content)
    if not validation.get("ok"):
        return {
            "ok": False,
            "status": "validation_failed",
            "error": "Policy validation failed.",
            "validation": validation.get("validation", validation),
        }

    target.parent.mkdir(parents=True, exist_ok=True)
    tmp_dir = ROOT / "tmp" / "web" / "policy-edits"
    tmp_dir.mkdir(parents=True, exist_ok=True)
    tmp_path = tmp_dir / f"{target.name}.{uuid.uuid4().hex}.tmp"
    tmp_path.write_text(normalized_content, encoding="utf-8")

    if os.geteuid() == 0:
        tmp_path.replace(target)
        return {"ok": True, "status": "saved", "path": target.relative_to(POLICIES_ROOT).as_posix(), "method": "root"}

    check = sudo_check(password)
    if not check.get("ok"):
        try:
            tmp_path.unlink()
        except OSError:
            pass
        return check

    try:
        process = subprocess.run(
            ["sudo", "-S", "-p", "", "install", "-m", "0644", str(tmp_path), str(target)],
            input=f"{password}\n",
            text=True,
            capture_output=True,
            timeout=10,
            check=False,
        )
    except subprocess.TimeoutExpired:
        process = None
    finally:
        try:
            tmp_path.unlink()
        except OSError:
            pass

    if process is None:
        return {"ok": False, "status": "sudo_timeout", "error": "sudo install timed out."}
    if process.returncode != 0:
        return {
            "ok": False,
            "status": "sudo_write_failed",
            "error": (process.stderr or "sudo install failed").strip()[:400],
        }
    return {"ok": True, "status": "saved", "path": target.relative_to(POLICIES_ROOT).as_posix(), "method": "sudo"}


def safe_skills_path(relative_path):
    if not isinstance(relative_path, str) or not relative_path:
        raise ValueError("skill path is required")
    candidate = Path(relative_path)
    if candidate.is_absolute() or ".." in candidate.parts:
        raise ValueError("skill path must be relative to skills/")
    target = (SKILLS_ROOT / candidate).resolve()
    target.relative_to(SKILLS_ROOT.resolve())
    if target.suffix not in (".md", ".sh"):
        raise ValueError("only Markdown and shell skill files are readable from the web console")
    return target


def build_skill_tree(path):
    children = []
    try:
        entries = sorted(path.iterdir(), key=lambda item: (not item.is_dir(), item.name.lower()))
    except FileNotFoundError:
        entries = []
    for child in entries:
        if child.name.startswith("."):
            continue
        relative = child.relative_to(SKILLS_ROOT).as_posix()
        if child.is_dir():
            children.append({"type": "dir", "name": child.name, "path": relative, "children": build_skill_tree(child)})
        elif child.suffix in (".md", ".sh"):
            stat = child.stat()
            children.append(
                {
                    "type": "file",
                    "name": child.name,
                    "path": relative,
                    "kind": "markdown" if child.suffix == ".md" else "script",
                    "size_bytes": stat.st_size,
                    "mtime": int(stat.st_mtime),
                }
            )
    return children


def list_skill_files():
    SKILLS_ROOT.mkdir(parents=True, exist_ok=True)
    markdown = []
    scripts = []
    for path in sorted(SKILLS_ROOT.rglob("*")):
        if not path.is_file() or path.name.startswith("."):
            continue
        relative = path.relative_to(SKILLS_ROOT).as_posix()
        if path.suffix == ".md":
            markdown.append(relative)
        elif path.suffix == ".sh":
            scripts.append(relative)
    return {
        "ok": True,
        "status": "listed",
        "root": "skills",
        "tree": build_skill_tree(SKILLS_ROOT),
        "markdown_files": markdown,
        "script_files": scripts,
    }


def read_skill_file(relative_path):
    target = safe_skills_path(relative_path)
    if not target.exists() or not target.is_file():
        return {"ok": False, "status": "not_found", "error": "Skill file not found."}
    content = target.read_text(encoding="utf-8")
    return {
        "ok": True,
        "status": "read",
        "path": target.relative_to(SKILLS_ROOT).as_posix(),
        "kind": "markdown" if target.suffix == ".md" else "script",
        "content": content,
    }


def run_agent_api(resource, action="", payload=None, timeout=None, job_id=None):
    payload = payload or {}
    command = ["bash", str(AGENT), "api", resource]
    if action:
        command.append(action)
    command.append(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))
    env = os.environ.copy()
    env.setdefault("LINUX_AGENT_WEB", "1")
    if job_id is None:
        process = subprocess.run(
            command,
            cwd=str(ROOT),
            env=env,
            text=True,
            capture_output=True,
            timeout=timeout,
            check=False,
        )
        stdout = process.stdout.strip()
        stderr = process.stderr.strip()
        returncode = process.returncode
    else:
        process = subprocess.Popen(
            command,
            cwd=str(ROOT),
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
        with JOB_PROCESSES_LOCK:
            JOB_PROCESSES[job_id] = process
        try:
            stdout, stderr = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            process.kill()
            stdout, stderr = process.communicate()
        finally:
            with JOB_PROCESSES_LOCK:
                JOB_PROCESSES.pop(job_id, None)
        stdout = stdout.strip()
        stderr = stderr.strip()
        returncode = process.returncode
    try:
        result = json.loads(stdout) if stdout else {}
    except json.JSONDecodeError:
        result = {
            "ok": False,
            "status": "invalid_agent_output",
            "timeline": [],
            "approval_card": None,
            "output_blocks": [
                {"kind": "stdout", "title": "Agent stdout", "text": stdout[:4000], "truncated_bytes": max(0, len(stdout) - 4000)}
            ],
        }
    if isinstance(result, dict):
        if returncode is not None and returncode < 0:
            result["ok"] = False
            result["status"] = "cancelled"
            result.setdefault("error", "Job process was terminated.")
        result.setdefault("ok", returncode == 0 and result.get("ok", False))
        result.setdefault("status", "completed" if returncode == 0 else "failed")
        blocks = result.setdefault("output_blocks", [])
        if not isinstance(blocks, list):
            blocks = []
            result["output_blocks"] = blocks
        if stderr:
            blocks.append(
                {"kind": "stderr", "title": "Agent stderr", "text": stderr[:4000], "truncated_bytes": max(0, len(stderr) - 4000)}
            )
        blocks.append({"kind": "meta", "title": "Agent runtime", "json": {"exit_code": returncode}})
    return result


def run_job(job_id, job, resource, action, payload):
    started_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    job["status"] = "running"
    job["started_at"] = started_at
    job["updated_at"] = started_at
    write_job(job_id, job)
    try:
        result = run_agent_api(resource, action, payload, timeout=None, job_id=job_id)
        finished_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        if result.get("status") == "cancelled":
            job["status"] = "cancelled"
        else:
            job["status"] = "succeeded" if result.get("ok") or result.get("status") == "approval_required" else "failed"
        job["result"] = result
        job["result_ok"] = bool(result.get("ok"))
        job["result_status"] = result.get("status", job["status"])
        job["finished_at"] = finished_at
        job["updated_at"] = finished_at
        write_job(job_id, job)
    except Exception as exc:  # noqa: BLE001 - surfaced as a job failure.
        finished_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        job["status"] = "failed"
        job["result"] = {"ok": False, "status": "job_exception", "error": str(exc)}
        job["result_ok"] = False
        job["result_status"] = "job_exception"
        job["finished_at"] = finished_at
        job["updated_at"] = finished_at
        write_job(job_id, job)


def start_job(resource, action, payload):
    cleanup_jobs()
    job_id = uuid.uuid4().hex
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    job = {
        "ok": True,
        "job_id": job_id,
        "resource": resource,
        "action": action,
        "status": "queued",
        "created_at": now,
        "updated_at": now,
        "result": None,
        "result_ok": None,
        "result_status": None,
    }
    write_job(job_id, job)

    threading.Thread(target=run_job, args=(job_id, job, resource, action, payload), daemon=True).start()
    return job


def cancel_job(job_id):
    job = read_job(job_id)
    if job is None:
        return {"ok": False, "status": "not_found"}
    if job.get("status") not in ("queued", "running"):
        return {"ok": False, "status": "not_running", "job": job}
    with JOB_PROCESSES_LOCK:
        process = JOB_PROCESSES.get(job_id)
    if process is None:
        return {"ok": False, "status": "process_not_found", "job": job}
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    except OSError:
        process.terminate()
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    job["status"] = "cancelled"
    job["updated_at"] = now
    job["finished_at"] = now
    job["result"] = {"ok": False, "status": "cancelled", "error": "Job cancellation requested."}
    job["result_ok"] = False
    job["result_status"] = "cancelled"
    write_job(job_id, job)
    return {"ok": True, "status": "cancelled", "job": job}


def compact_summary(value, limit=220):
    text = " ".join(str(value or "").split())
    if len(text) > limit:
        return text[:limit] + "..."
    return text


def audit_stage(event):
    if not isinstance(event, dict):
        return "event"
    return str(event.get("stage") or event.get("event") or event.get("type") or event.get("status") or "event")


def audit_payload(event):
    if isinstance(event, dict) and isinstance(event.get("payload"), dict):
        return event["payload"]
    return event if isinstance(event, dict) else {}


def build_web_timeline_from_audit(session_id, events):
    steps_by_id = {}
    planned_steps = []
    timeline = []
    summary = ""
    input_preview = ""
    final_status = "restored"
    step_statuses = {
        "step_auto_approved",
        "step_approval_required",
        "step_blocked",
        "step_rejected",
        "step_running",
        "step_succeeded",
        "step_failed",
        "step_skipped_user",
        "step_skipped_unexecuted",
        "step_terminated",
    }

    for event in events if isinstance(events, list) else []:
        stage = audit_stage(event)
        payload = audit_payload(event)
        if stage == "received" and not input_preview:
            input_preview = str(payload.get("input_preview") or payload.get("command") or payload.get("ref") or "")
        elif stage == "planned":
            summary = str(payload.get("summary_preview") or summary)
            for index, step in enumerate(payload.get("steps") or []):
                if not isinstance(step, dict):
                    continue
                step_id = str(step.get("id") or f"step-{index + 1}")
                normalized = {
                    "id": step_id,
                    "title": step.get("title") or step_id,
                    "executor_type": step.get("executor_type"),
                    "skill_script": step.get("skill_script"),
                    "risk_level": step.get("risk_level") or "low",
                    "expected_effect": step.get("expected_effect") or "",
                    "reason": step.get("reason") or "",
                }
                steps_by_id[step_id] = normalized
                planned_steps.append(normalized)
        elif stage in {"finished", "session_finished", "command_finished"}:
            final_status = str(payload.get("status") or final_status)

        if stage in {"terminal_executed", "script_executed"}:
            status = str(payload.get("status") or ("executed" if payload.get("ok") else "failed"))
            timeline.append(
                {
                    "id": f"{stage}-{len(timeline) + 1}",
                    "kind": "execution",
                    "status": status,
                    "step_id": stage,
                    "title": "终端执行" if stage == "terminal_executed" else "Skill 执行",
                    "summary": compact_summary(payload.get("action") or status),
                    "risk_level": None,
                    "step": {"id": stage, "title": "终端执行" if stage == "terminal_executed" else "Skill 执行", "executor_type": "terminal" if stage == "terminal_executed" else "skill_script"},
                    "output_blocks": [{"kind": "meta", "title": "审计恢复摘要", "json": {"stage": stage, "status": status, "payload": payload}}],
                }
            )
            continue

        if stage not in step_statuses:
            continue
        step = payload.get("step") if isinstance(payload.get("step"), dict) else {}
        step_id = str(step.get("id") or f"{stage}-{len(timeline) + 1}")
        merged_step = {**steps_by_id.get(step_id, {}), **step}
        status = str(payload.get("status") or stage.replace("step_", ""))
        detail = payload.get("detail") if isinstance(payload.get("detail"), dict) else {}
        findings = payload.get("findings") if isinstance(payload.get("findings"), list) else []
        blocks = [
            {
                "kind": "meta",
                "title": "审计恢复摘要",
                "json": {
                    "stage": stage,
                    "status": status,
                    "detail": detail,
                    "finding_count": len(findings),
                },
            }
        ]
        if findings:
            blocks.append({"kind": "review", "title": "策略审查 findings", "json": {"findings": findings}})
        timeline.append(
            {
                "id": f"{stage}-{len(timeline) + 1}",
                "kind": "execution",
                "status": status,
                "step_id": step_id,
                "title": merged_step.get("title") or step_id,
                "summary": compact_summary(detail.get("status") or detail.get("action") or status),
                "risk_level": merged_step.get("risk_level"),
                "step": merged_step,
                "output_blocks": blocks,
            }
        )

    return {
        "ok": True,
        "status": final_status,
        "source": "audit",
        "session_id": session_id,
        "input": input_preview,
        "response": {
            "response_type": "work_plan" if planned_steps else "answer",
            "summary": summary or f"审计恢复 {session_id}",
            "steps": planned_steps,
            "continue_decision": {"should_continue": False, "reason": "Restored from audit events for Web replay."},
        },
        "timeline": timeline,
        "approval_card": None,
        "output_blocks": [
            {
                "kind": "meta",
                "title": "Web 时间线恢复",
                "json": {
                    "session_id": session_id,
                    "event_count": len(events) if isinstance(events, list) else 0,
                    "timeline_count": len(timeline),
                    "planned_step_count": len(planned_steps),
                },
            }
        ],
    }


def terminate_running_jobs():
    with JOB_PROCESSES_LOCK:
        processes = list(JOB_PROCESSES.values())
    for process in processes:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            continue
        except OSError:
            process.terminate()


def shutdown_server_later(server):
    time.sleep(0.1)
    server.shutdown()


def request_server_shutdown(server):
    terminate_running_jobs()
    threading.Thread(target=shutdown_server_later, args=(server,), daemon=True).start()
    return {"ok": True, "status": "shutting_down"}


class Handler(SimpleHTTPRequestHandler):
    server_version = "LinuxAgentWeb/1.0"

    def log_message(self, fmt, *args):
        print("%s - %s" % (self.address_string(), fmt % args), flush=True)

    def authenticated(self):
        auth = self.headers.get("Authorization", "")
        token = ""
        if auth.startswith("Bearer "):
            token = auth[len("Bearer ") :].strip()
        if not token:
            token = self.headers.get("X-Agent-Token", "").strip()
        return token == AUTH_TOKEN

    def require_auth(self):
        if self.authenticated():
            return True
        json_response(self, HTTPStatus.UNAUTHORIZED, {"ok": False, "status": "unauthorized", "error": "Missing or invalid token."})
        return False

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path.startswith("/api/"):
            if not self.require_auth():
                return
            self.handle_api_get(parsed.path)
            return
        self.serve_static(parsed.path)

    def do_POST(self):
        parsed = urlparse(self.path)
        if not parsed.path.startswith("/api/"):
            json_response(self, HTTPStatus.NOT_FOUND, {"ok": False, "status": "not_found"})
            return
        if not self.require_auth():
            return
        try:
            body = read_json_body(self)
        except ValueError as exc:
            json_response(self, HTTPStatus.BAD_REQUEST, {"ok": False, "status": "invalid_json", "error": str(exc)})
            return
        self.handle_api_post(parsed.path, body)

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
            "/api/audit/list": ("audit", "list"),
        }
        if path == "/api/policies":
            json_response(self, HTTPStatus.OK, {"ok": True, "status": "listed", "files": list_policy_files(), "requires_sudo_to_edit": True})
            return
        if path == "/api/config":
            json_response(self, HTTPStatus.OK, config_public_state())
            return
        if path == "/api/observer/bootstrap":
            json_response(self, HTTPStatus.OK, observer_bootstrap_public_state(force_ok=True))
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
        result = run_agent_api(route[0], route[1], {}, timeout=120)
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
            result = run_agent_api("audit", "read", body, timeout=180)
            if isinstance(result, dict) and isinstance(result.get("events"), list):
                result["web_timeline"] = build_web_timeline_from_audit(str(body.get("session_id") or result.get("session_id") or ""), result["events"])
            json_response(self, HTTPStatus.OK, result)
            return
        if path == "/api/config/update":
            result = update_config_value(str(body.get("key") or ""), body.get("value"))
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
            json_response(self, HTTPStatus.OK, cancel_job(job_id))
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
            job = start_job(resource, action, payload)
            json_response(self, HTTPStatus.ACCEPTED, job)
            return
        route = sync_routes.get(path)
        if not route:
            json_response(self, HTTPStatus.NOT_FOUND, {"ok": False, "status": "not_found"})
            return
        result = run_agent_api(route[0], route[1], body, timeout=180)
        json_response(self, HTTPStatus.OK, result)


def main():
    cleanup_jobs()
    STATIC_ROOT.mkdir(parents=True, exist_ok=True)
    JOBS_ROOT.mkdir(parents=True, exist_ok=True)
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

    print(f"[信息] Web 控制台: http://{HOST}:{PORT}/", file=sys.stderr, flush=True)
    print(f"[信息] Authorization Bearer token: {AUTH_TOKEN}", file=sys.stderr, flush=True)
    print(f"[info] serving {STATIC_ROOT} on http://{HOST}:{PORT}/", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[信息] Web 控制台已停止。", file=sys.stderr, flush=True)
    finally:
        record_web_audit_event(
            "session_finished",
            {
                "status": "stopped",
                "run_id": SERVER_RUN_ID,
            },
        )
        server.server_close()


if __name__ == "__main__":
    main()
