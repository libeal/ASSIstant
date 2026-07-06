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
import urllib.error
import urllib.request
from http import HTTPStatus
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlencode, unquote, urlparse, urlunparse


ROOT = Path(os.environ.get("LINUX_AGENT_ROOT", Path(__file__).resolve().parents[1])).resolve()
STATIC_ROOT = ROOT / "web" / "static"
JOBS_ROOT = ROOT / "tmp" / "web" / "jobs"
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
WEB_AGENT_LOCK = threading.RLock()
DEFAULT_STDERR_TEXT_LIMIT = 4000
WORK_EXECUTION_FLOW_TEXT_LIMIT = 200000
MODEL_LIST_RESPONSE_LIMIT = 1024 * 1024
SERVER_RUN_ID = uuid.uuid4().hex
SERVER_STARTED_AT = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
WEB_AGENT_SESSION_ID = f"session_web_{SERVER_RUN_ID[:16]}"
WEB_AGENT_AUDIT_LOG = ROOT / "logs" / f"{WEB_AGENT_SESSION_ID}.jsonl"
WEB_AGENT_HISTORY_FILE = ROOT / "tmp" / "web" / "sessions" / f"{WEB_AGENT_SESSION_ID}.history.json"
WEB_AGENT_RESTORED_FROM = ""
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


def read_provider_registry():
    try:
        with PROVIDERS_PATH.open("r", encoding="utf-8") as handle:
            payload = json.load(handle)
    except (FileNotFoundError, json.JSONDecodeError):
        payload = {"providers": []}
    providers = payload.get("providers")
    return providers if isinstance(providers, list) else []


def normalize_provider_id(value):
    normalized = str(value or "").strip().lower()
    normalized = normalized.replace("-", "_").replace(" ", "_")
    normalized = normalized.replace("/", "_")
    aliases = {
        "": "openai_compatible",
        "openai_compatible": "openai_compatible",
        "openai_compatible_custom": "openai_compatible",
        "openai-compatible": "openai_compatible",
        "openai-compatible_custom": "openai_compatible",
        "openai_compatible___custom": "openai_compatible",
        "openai_compatible_/_custom": "openai_compatible",
        "zhipu": "zhipu_ai",
        "zhipuai": "zhipu_ai",
        "zhipu_ai": "zhipu_ai",
        "sarvam": "sarvam_ai",
        "sarvam_ai": "sarvam_ai",
        "moonshot": "moonshot_ai",
        "moonshot_ai": "moonshot_ai",
        "xai": "x_ai",
        "x_ai": "x_ai",
        "nvidia": "nvidia",
        "mistral": "mistral",
        "openai": "openai",
    }
    return aliases.get(normalized, normalized)


def provider_by_id(provider_id):
    normalized = normalize_provider_id(provider_id)
    for provider in read_provider_registry():
        if normalize_provider_id(provider.get("id")) == normalized:
            return provider
    if normalized != "openai_compatible":
        return provider_by_id("openai_compatible")
    return {}


def config_provider_id(config):
    configured = normalize_provider_id(config.get("provider", ""))
    known_ids = {normalize_provider_id(provider.get("id")) for provider in read_provider_registry()}
    if configured in known_ids:
        return configured
    return "openai_compatible"


def public_provider(provider):
    models = provider.get("models") if isinstance(provider.get("models"), dict) else {}
    return {
        "id": str(provider.get("id") or ""),
        "label": str(provider.get("label") or provider.get("id") or ""),
        "api_url": str(provider.get("api_url") or ""),
        "default_model": str(provider.get("default_model") or ""),
        "custom_url": bool(provider.get("custom_url", False)),
        "model_fetch_supported": bool(models.get("supported", False)),
        "model_fetch_reason": str(models.get("reason") or ""),
        "request_format": str(provider.get("request_format") or "openai_chat"),
    }


def providers_public_state():
    providers = [
        public_provider(provider)
        for provider in read_provider_registry()
        if isinstance(provider, dict) and provider.get("id")
    ]
    return {"ok": True, "status": "listed", "providers": providers}


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


def configured_api_key(config, override=None):
    override_value = str(override or "")
    if secret_value_configured(override_value):
        return override_value, "request"
    env_value = os.environ.get("LINUX_AGENT_API_KEY", "")
    if secret_value_configured(env_value):
        return env_value, "env"
    config_value = str(config.get("api_key", ""))
    if secret_value_configured(config_value):
        return config_value, "config"
    return "", "missing"


def redacted_text(value, secret=""):
    text = str(value or "")
    if secret:
        text = text.replace(secret, "[REDACTED]")
    return text[:600]


def validate_http_url(raw_url):
    value = str(raw_url or "").strip()
    if len(value) > 2048:
        return "", "url_too_long"
    parsed = urlparse(value)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        return "", "invalid_url"
    return value, ""


def derive_models_url(api_url):
    parsed = urlparse(str(api_url or ""))
    path = parsed.path.rstrip("/")
    if path.endswith("/chat/completions"):
        path = path[: -len("/chat/completions")] + "/models"
    elif path.endswith("/messages"):
        path = path[: -len("/messages")] + "/models"
    else:
        path = path + "/models"
    return urlunparse((parsed.scheme, parsed.netloc, path, "", "", ""))


class NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def provider_auth_headers(auth, api_key):
    if auth == "anthropic":
        return {
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01",
        }
    if auth == "api_subscription_key":
        return {"api-subscription-key": api_key}
    if auth == "google_key_query":
        return {}
    return {"Authorization": f"Bearer {api_key}"}


def model_list_request_url(provider, api_url, api_key):
    models = provider.get("models") if isinstance(provider.get("models"), dict) else {}
    if models.get("derive_from_api_url"):
        url = derive_models_url(api_url)
    else:
        url = str(models.get("url") or "")
    auth = str(models.get("auth") or provider.get("auth") or "bearer")
    if auth == "google_key_query":
        separator = "&" if urlparse(url).query else "?"
        url = f"{url}{separator}{urlencode({'key': api_key})}"
    return url, auth


def fetch_json_url(url, headers, timeout, secret):
    request = urllib.request.Request(url, headers=headers, method="GET")
    opener = urllib.request.build_opener(NoRedirectHandler)
    try:
        with opener.open(request, timeout=timeout) as response:
            body = response.read(MODEL_LIST_RESPONSE_LIMIT + 1)
            if len(body) > MODEL_LIST_RESPONSE_LIMIT:
                return None, {
                    "ok": False,
                    "status": "provider_response_too_large",
                    "error": "Model list response is too large.",
                }
    except urllib.error.HTTPError as exc:
        detail = ""
        try:
            detail = exc.read(400).decode("utf-8", errors="replace")
        except OSError:
            detail = str(exc)
        return None, {
            "ok": False,
            "status": "provider_request_failed",
            "error": f"Provider returned HTTP {exc.code}.",
            "detail": redacted_text(detail, secret),
        }
    except urllib.error.URLError as exc:
        return None, {
            "ok": False,
            "status": "provider_request_failed",
            "error": "Provider model list request failed.",
            "detail": redacted_text(exc.reason, secret),
        }
    except TimeoutError:
        return None, {
            "ok": False,
            "status": "provider_request_timeout",
            "error": "Provider model list request timed out.",
        }
    try:
        return json.loads(body.decode("utf-8")), None
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None, {
            "ok": False,
            "status": "provider_invalid_response",
            "error": "Provider model list response is not valid JSON.",
        }


def extract_model_ids(payload, parser):
    ids = []
    if parser == "google_models":
        items = payload.get("models") if isinstance(payload, dict) else []
        if not isinstance(items, list):
            return []
        for item in items:
            if not isinstance(item, dict):
                continue
            methods = item.get("supportedGenerationMethods")
            if isinstance(methods, list) and "generateContent" not in methods:
                continue
            name = str(item.get("name") or item.get("id") or "")
            if name.startswith("models/"):
                name = name[len("models/") :]
            ids.append(name)
    elif parser == "models_name_or_id":
        items = payload.get("models") if isinstance(payload, dict) else []
        if not isinstance(items, list):
            return []
        for item in items:
            if isinstance(item, dict):
                ids.append(str(item.get("name") or item.get("id") or ""))
            else:
                ids.append(str(item or ""))
    else:
        items = payload.get("data") if isinstance(payload, dict) else []
        if not isinstance(items, list):
            return []
        for item in items:
            if isinstance(item, dict):
                ids.append(str(item.get("id") or ""))
            else:
                ids.append(str(item or ""))
    clean = []
    seen = set()
    for model_id in ids:
        model_id = " ".join(str(model_id or "").split())
        if not model_id or len(model_id) > 200 or model_id in seen:
            continue
        seen.add(model_id)
        clean.append(model_id)
    return sorted(clean)


def list_provider_models(body):
    config = read_config()
    provider_id = normalize_provider_id(body.get("provider") or config.get("provider") or config_provider_id(config))
    provider = provider_by_id(provider_id)
    provider_id = normalize_provider_id(provider.get("id") or provider_id)
    models = provider.get("models") if isinstance(provider.get("models"), dict) else {}
    if not models.get("supported", False):
        return {
            "ok": False,
            "status": "model_list_unavailable",
            "provider": provider_id,
            "models": [],
            "error": models.get("reason") or "This provider does not expose a configured model list endpoint.",
        }

    api_url = str(body.get("api_url") or config.get("api_url") or provider.get("api_url") or "")
    if models.get("derive_from_api_url") or not models.get("url"):
        api_url, url_error = validate_http_url(api_url)
        if url_error:
            return {"ok": False, "status": url_error, "provider": provider_id, "models": [], "error": "api_url must be a valid http(s) URL."}

    api_key, key_source = configured_api_key(config, body.get("api_key"))
    url, auth = model_list_request_url(provider, api_url, api_key)
    url, url_error = validate_http_url(url)
    if url_error:
        return {"ok": False, "status": url_error, "provider": provider_id, "models": [], "error": "model list URL must be a valid http(s) URL."}
    if auth != "none" and not api_key:
        return {"ok": False, "status": "api_key_missing", "provider": provider_id, "models": [], "error": "API key is required to list models."}

    timeout = min(max(safe_int(config.get("request_timeout_sec", 30) or 30, 30), 1), 60)
    headers = {"Accept": "application/json"}
    headers.update(provider_auth_headers(auth, api_key))
    payload, error = fetch_json_url(url, headers, timeout, api_key)
    if error:
        error["provider"] = provider_id
        error["models"] = []
        return error
    parser = str(models.get("parser") or "openai_data_id")
    model_ids = extract_model_ids(payload, parser)
    return {
        "ok": True,
        "status": "listed",
        "provider": provider_id,
        "key_source": key_source,
        "models": [{"id": model_id} for model_id in model_ids],
        "model_count": len(model_ids),
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
                "privilege": observer.get("privilege", "sudo_interactive"),
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


def append_audit_event(log_path, session_id, stage, payload=None):
    payload = payload if isinstance(payload, dict) else {}
    log_path.parent.mkdir(parents=True, exist_ok=True)
    event = {
        "timestamp": now_iso(),
        "session_id": session_id,
        "stage": stage,
        "payload": payload,
    }
    with log_path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(event, ensure_ascii=False, separators=(",", ":")))
        handle.write("\n")


def record_web_audit_event(stage, payload=None):
    append_audit_event(WEB_AUDIT_LOG, WEB_AUDIT_SESSION_ID, stage, payload)


def record_web_agent_session_event(stage, payload=None):
    append_audit_event(WEB_AGENT_AUDIT_LOG, WEB_AGENT_SESSION_ID, stage, payload)


def new_web_agent_session_id():
    return f"session_web_{uuid.uuid4().hex[:16]}"


def set_web_agent_session_paths(session_id):
    global WEB_AGENT_SESSION_ID, WEB_AGENT_AUDIT_LOG, WEB_AGENT_HISTORY_FILE
    WEB_AGENT_SESSION_ID = session_id
    WEB_AGENT_AUDIT_LOG = ROOT / "logs" / f"{WEB_AGENT_SESSION_ID}.jsonl"
    WEB_AGENT_HISTORY_FILE = ROOT / "tmp" / "web" / "sessions" / f"{WEB_AGENT_SESSION_ID}.history.json"


def read_json_array(path):
    try:
        with path.open("r", encoding="utf-8") as handle:
            value = json.load(handle)
    except (FileNotFoundError, json.JSONDecodeError):
        return []
    return value if isinstance(value, list) else []


def write_json_atomic(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = path.with_suffix(f"{path.suffix}.tmp")
    with tmp_path.open("w", encoding="utf-8") as handle:
        json.dump(value, handle, ensure_ascii=False, separators=(",", ":"))
        handle.write("\n")
    tmp_path.replace(path)


def context_turn_limit():
    try:
        value = int(read_config().get("context_turns", 6))
    except (TypeError, ValueError):
        value = 6
    return max(0, value)


def web_agent_session_state_locked():
    history = read_json_array(WEB_AGENT_HISTORY_FILE)
    turns = context_turn_limit()
    window = history[-turns:] if turns else []
    return {
        "ok": True,
        "status": "active",
        "session_id": WEB_AGENT_SESSION_ID,
        "audit_log": str(WEB_AGENT_AUDIT_LOG),
        "history_file": str(WEB_AGENT_HISTORY_FILE),
        "history_count": len(history),
        "context_turns": turns,
        "context_window_count": len(window),
        "restored_from": WEB_AGENT_RESTORED_FROM,
    }


def web_agent_session_state():
    with WEB_AGENT_LOCK:
        return web_agent_session_state_locked()


def finish_current_web_agent_session_locked(status):
    if not WEB_AGENT_SESSION_ID:
        return
    record_web_agent_session_event(
        "session_finished",
        {
            "status": status,
            "run_id": SERVER_RUN_ID,
        },
    )


def start_web_agent_session_locked(history=None, restored_from="", start_reason="started", session_id=None):
    global WEB_AGENT_RESTORED_FROM
    next_session_id = session_id or new_web_agent_session_id()
    set_web_agent_session_paths(next_session_id)
    WEB_AGENT_RESTORED_FROM = restored_from
    WEB_AGENT_AUDIT_LOG.parent.mkdir(parents=True, exist_ok=True)
    WEB_AGENT_AUDIT_LOG.write_text("", encoding="utf-8")
    write_json_atomic(WEB_AGENT_HISTORY_FILE, history if isinstance(history, list) else [])
    record_web_agent_session_event(
        "session_started",
        {
            "request": "agent-web",
            "entrypoint": "web",
            "run_id": SERVER_RUN_ID,
            "started_at": now_iso(),
            "audit_mode": read_config().get("audit_mode", "safe_summary"),
            "restored_from": restored_from,
            "start_reason": start_reason,
            "history_count": len(history) if isinstance(history, list) else 0,
        },
    )
    return web_agent_session_state_locked()


def initialize_web_agent_session():
    with WEB_AGENT_LOCK:
        return start_web_agent_session_locked(
            history=[],
            restored_from="",
            start_reason="server_started",
            session_id=f"session_web_{SERVER_RUN_ID[:16]}",
        )


def rotate_web_agent_session(reason="rotated", history=None, restored_from=""):
    with WEB_AGENT_LOCK:
        finish_current_web_agent_session_locked(reason)
        return start_web_agent_session_locked(
            history=history if isinstance(history, list) else [],
            restored_from=restored_from,
            start_reason=reason,
        )


def read_audit_events(session_id):
    if not session_id or not all(ch.isalnum() or ch in "_.-" for ch in session_id):
        raise ValueError("session_id is required and must be a safe file name.")
    log_file = ROOT / "logs" / f"{session_id}.jsonl"
    if not log_file.exists():
        raise FileNotFoundError("Audit session not found.")
    events = []
    with log_file.open("r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(event, dict):
                events.append(event)
    return events


def compact_history_text(value, limit=1200):
    text = " ".join(str(value or "").split())
    if len(text) > limit:
        return text[:limit] + "[TRUNCATED]"
    return text


def audit_history_from_events(events):
    history = []
    turns = build_web_turns_from_audit("audit_restore", events)
    for turn in turns:
        result = turn.get("result") if isinstance(turn.get("result"), dict) else {}
        response = result.get("response") if isinstance(result.get("response"), dict) else {}
        timeline = result.get("timeline") if isinstance(result.get("timeline"), list) else []
        executions = [item for item in timeline if isinstance(item, dict) and item.get("kind") == "execution"]
        status = str(turn.get("status") or result.get("status") or "restored")
        iteration = result.get("iteration")
        plan_summary = response.get("summary") or ""
        final_answer = ""
        for block in result.get("output_blocks") if isinstance(result.get("output_blocks"), list) else []:
            if isinstance(block, dict) and block.get("title") == "最终回答":
                final_answer = str(block.get("text") or "")
                break
        if iteration is not None:
            response_content = {
                "iteration": iteration,
                "status": status,
                "result_count": len(executions),
                "stopped_reason": response.get("continue_decision", {}).get("reason") if isinstance(response.get("continue_decision"), dict) else "",
                "reflection_summary": final_answer or plan_summary,
            }
            response_text = json.dumps(response_content, ensure_ascii=False, separators=(",", ":"))
            metadata = {
                "source": "audit_restore",
                "iteration": iteration,
                "result_count": len(executions),
                "plan_summary": plan_summary,
                "reflection_summary": final_answer,
            }
            turn_type = "agent_loop_iteration"
        else:
            assistant_parts = []
            if plan_summary:
                assistant_parts.append(f"计划: {plan_summary}")
            assistant_parts.append(f"执行状态: {status}; 结果数: {len(executions)}")
            if final_answer:
                assistant_parts.append(f"最终回答: {final_answer}")
            response_text = "；".join(part for part in assistant_parts if part) or status
            metadata = {"source": "audit_restore"}
            turn_type = "request"
        history.append(
            {
                "type": turn_type,
                "mode": turn.get("mode") or "work",
                "request": {"content": compact_history_text(turn.get("input", ""))},
                "response": {
                    "content": compact_history_text(response_text),
                    "status": status,
                },
                "status": status,
                "started_at": turn.get("created_at") or now_iso(),
                "completed_at": turn.get("updated_at") or now_iso(),
                "metadata": metadata,
                **({"iteration": iteration} if iteration is not None else {}),
            }
        )
    return history


def restore_web_agent_session_from_audit(session_id):
    try:
        events = read_audit_events(session_id)
    except ValueError as exc:
        return {"ok": False, "status": "invalid_session_id", "error": str(exc)}
    except FileNotFoundError as exc:
        return {"ok": False, "status": "not_found", "error": str(exc)}
    history = audit_history_from_events(events)
    session = rotate_web_agent_session(
        reason="restored_from_audit",
        history=history,
        restored_from=session_id,
    )
    return {"ok": True, "status": "restored", "session": session, "history_count": len(history)}


def leave_web_agent_session():
    with WEB_AGENT_LOCK:
        restored = WEB_AGENT_RESTORED_FROM
        finish_current_web_agent_session_locked("left_restored" if restored else "rotated")
        session = start_web_agent_session_locked(
            history=[],
            restored_from="",
            start_reason="left_restored" if restored else "rotated",
        )
    return {
        "ok": True,
        "status": "left_restored" if restored else "rotated",
        "left_restored_from": restored,
        "session": session,
    }


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
    job = read_job(job_id)
    if not isinstance(job, dict) or job.get("status") != "running":
        return
    block = agent_stderr_block(resource, stderr)
    if not block:
        return
    job["result"] = {
        "ok": False,
        "status": "running",
        "timeline": [],
        "approval_card": None,
        "output_blocks": [block],
    }
    job["result_ok"] = False
    job["result_status"] = "running"
    job["updated_at"] = now_iso()
    write_job(job_id, job)


def run_agent_api_job_process(command, env, resource, timeout, job_id):
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

    stdout_chunks = []
    stderr_chunks = []
    last_partial_update = [0.0]

    def read_stdout():
        if process.stdout is None:
            return
        stdout_chunks.append(process.stdout.read() or "")

    stdout_thread = threading.Thread(target=read_stdout, daemon=True)
    stdout_thread.start()
    start_time = time.monotonic()
    returncode = None
    try:
        if process.stderr is not None:
            for line in process.stderr:
                stderr_chunks.append(line)
                now = time.monotonic()
                if now - last_partial_update[0] >= 0.25:
                    update_job_partial_output(job_id, resource, "".join(stderr_chunks).strip())
                    last_partial_update[0] = now
                if timeout is not None and now - start_time > timeout:
                    process.kill()
                    break
        if timeout is None:
            returncode = process.wait()
        else:
            remaining = max(0.1, timeout - (time.monotonic() - start_time))
            returncode = process.wait(timeout=remaining)
    except subprocess.TimeoutExpired:
        process.kill()
        returncode = process.wait()
    finally:
        stdout_thread.join(timeout=1)
        with JOB_PROCESSES_LOCK:
            JOB_PROCESSES.pop(job_id, None)

    stderr = "".join(stderr_chunks).strip()
    update_job_partial_output(job_id, resource, stderr)
    return "".join(stdout_chunks).strip(), stderr, returncode


def run_agent_api(resource, action="", payload=None, timeout=None, job_id=None):
    payload = payload or {}
    command = ["bash", str(AGENT), "api", resource]
    if action:
        command.append(action)
    command.append(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))
    env = os.environ.copy()
    env.setdefault("LINUX_AGENT_WEB", "1")
    with WEB_AGENT_LOCK:
        session_id = WEB_AGENT_SESSION_ID
        audit_log = str(WEB_AGENT_AUDIT_LOG)
        history_file = str(WEB_AGENT_HISTORY_FILE)
    env["LINUX_AGENT_SESSION_MANAGED_EXTERNALLY"] = "1"
    env["LINUX_AGENT_SESSION_ID"] = session_id
    env["LINUX_AGENT_AUDIT_LOG"] = audit_log
    env["LINUX_AGENT_CONVERSATION_HISTORY_FILE"] = history_file
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
        stdout, stderr, returncode = run_agent_api_job_process(command, env, resource, timeout, job_id)
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
        stderr_block = agent_stderr_block(resource, stderr)
        if stderr_block:
            blocks.append(stderr_block)
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


def audit_plan_steps(payload):
    if isinstance(payload.get("steps"), list):
        return payload.get("steps") or []
    plan = payload.get("plan") if isinstance(payload.get("plan"), dict) else {}
    if isinstance(plan.get("steps"), list):
        return plan.get("steps") or []
    return []


def audit_plan_summary(payload):
    plan = payload.get("plan") if isinstance(payload.get("plan"), dict) else {}
    return str(payload.get("summary_preview") or payload.get("summary") or plan.get("summary") or "")


def audit_normalized_step(step, index, iteration=None):
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
    normalized.update(step)
    if iteration is not None:
        normalized["iteration"] = iteration
    return normalized


def audit_step_status_rank(status):
    status = str(status or "")
    if status in {"succeeded", "executed", "failed", "rejected", "blocked", "skipped_user", "skipped_unexecuted", "terminated"}:
        return 100
    if status == "approval_required":
        return 80
    if status == "running":
        return 70
    if status in {"approved", "auto_approved"}:
        return 50
    if status == "policy_checked":
        return 40
    if status == "pending":
        return 10
    return 0


def build_web_timeline_from_audit(session_id, events, include_turns=True):
    steps_by_scope = {}
    planned_keys = set()
    planned_steps = []
    timeline_order = []
    step_records = {}
    summary = ""
    final_answer_summary = ""
    input_preview = ""
    final_status = "restored"
    current_request = 0
    current_iteration = 0
    step_statuses = {
        "step_pending",
        "step_policy_checked",
        "step_approved",
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

    def store_plan_steps(payload, iteration):
        nonlocal summary
        plan_summary = audit_plan_summary(payload)
        if plan_summary:
            summary = plan_summary
        normalized_steps = []
        for index, step in enumerate(audit_plan_steps(payload)):
            if not isinstance(step, dict):
                continue
            normalized = audit_normalized_step(step, index, iteration)
            step_id = str(normalized.get("id") or f"step-{index + 1}")
            key = (current_request, iteration, step_id)
            steps_by_scope[key] = normalized
            normalized_steps.append(normalized)
            if key not in planned_keys:
                planned_keys.add(key)
                planned_steps.append(normalized)
        return normalized_steps

    def lifecycle_status(stage, payload):
        status = str(payload.get("status") or stage.replace("step_", ""))
        if stage == "step_policy_checked":
            status = "policy_checked"
        return status

    def upsert_step_record(stage, payload):
        step = payload.get("step") if isinstance(payload.get("step"), dict) else {}
        iteration = safe_int(payload.get("iteration"), current_iteration or 1)
        step_id = str(step.get("id") or f"{stage}-{len(timeline_order) + 1}")
        key = (current_request, iteration, step_id)
        merged_step = {**steps_by_scope.get(key, {}), **step}
        if "id" not in merged_step:
            merged_step["id"] = step_id
        if "title" not in merged_step:
            merged_step["title"] = step_id
        status = lifecycle_status(stage, payload)
        detail = payload.get("detail") if isinstance(payload.get("detail"), dict) else {}
        findings = payload.get("findings") if isinstance(payload.get("findings"), list) else []
        record = step_records.get(key)
        if not record:
            record = {
                "request_index": current_request,
                "iteration": iteration,
                "step_id": step_id,
                "step": merged_step,
                "status": status,
                "status_rank": -1,
                "latest_stage": stage,
                "detail": {},
                "output_detail": {},
                "findings": [],
                "stages": [],
            }
            step_records[key] = record
            timeline_order.append(("step", key))
        else:
            record["step"] = {**record.get("step", {}), **merged_step}
        record["stages"].append({"stage": stage, "status": status})
        rank = audit_step_status_rank(status)
        if rank >= record.get("status_rank", -1):
            record["status"] = status
            record["status_rank"] = rank
            record["latest_stage"] = stage
            record["detail"] = detail
        if detail.get("output_preview") or detail.get("stderr_preview"):
            record["output_detail"] = detail
        if findings:
            record["findings"] = findings

    def output_blocks_for_record(record):
        detail = record.get("detail") if isinstance(record.get("detail"), dict) else {}
        output_detail = record.get("output_detail") if isinstance(record.get("output_detail"), dict) else {}
        preview = output_detail or detail
        findings = record.get("findings") if isinstance(record.get("findings"), list) else []
        blocks = []
        if preview.get("output_preview"):
            blocks.append({"kind": "stdout", "title": "审计输出预览", "text": str(preview.get("output_preview") or ""), "truncated_bytes": 0})
        if preview.get("stderr_preview"):
            blocks.append({"kind": "stderr", "title": "审计错误预览", "text": str(preview.get("stderr_preview") or ""), "truncated_bytes": 0})
        blocks.append(
            {
                "kind": "meta",
                "title": "审计恢复摘要",
                "json": {
                    "stage": record.get("latest_stage"),
                    "status": record.get("status"),
                    "iteration": record.get("iteration"),
                    "request_index": record.get("request_index"),
                    "detail": detail,
                    "stages": record.get("stages") or [],
                    "finding_count": len(findings),
                },
            }
        )
        if findings:
            blocks.append({"kind": "review", "title": "策略审查 findings", "json": {"findings": findings}})
        return blocks

    def timeline_item_for_record(record):
        detail = record.get("detail") if isinstance(record.get("detail"), dict) else {}
        step = record.get("step") if isinstance(record.get("step"), dict) else {}
        iteration = record.get("iteration")
        request_index = record.get("request_index")
        step_id = record.get("step_id")
        return {
            "id": f"execution-r{request_index}-i{iteration}-{step_id}",
            "kind": "execution",
            "status": record.get("status"),
            "iteration": iteration,
            "request_index": request_index,
            "step_id": step_id,
            "title": step.get("title") or step_id,
            "summary": compact_summary(detail.get("status") or detail.get("action") or detail.get("tool") or record.get("status")),
            "risk_level": step.get("risk_level"),
            "step": step,
            "output_blocks": output_blocks_for_record(record),
        }

    for event in events if isinstance(events, list) else []:
        stage = audit_stage(event)
        payload = audit_payload(event)
        if stage == "received" and not input_preview:
            input_preview = str(payload.get("input_preview") or payload.get("command") or payload.get("ref") or "")
        if stage == "received":
            current_request += 1
            current_iteration = 0
        elif stage == "planned":
            planned_iteration = safe_int(payload.get("iteration"), current_iteration or 1)
            store_plan_steps(payload, planned_iteration)
        elif stage == "agent_loop_iteration_started":
            current_iteration = safe_int(payload.get("iteration"), current_iteration + 1 if current_iteration else 1)
            if isinstance(payload.get("plan"), dict):
                store_plan_steps(payload, current_iteration)
        elif stage == "agent_reflection_planned":
            response_type = str(payload.get("response_type") or "")
            if response_type == "answer":
                final_answer_summary = str(payload.get("summary_preview") or payload.get("summary") or final_answer_summary)
            elif response_type == "work_plan":
                store_plan_steps(payload, (current_iteration or 0) + 1)
        elif stage in {"finished", "session_finished", "command_finished", "agent_loop_finished"}:
            final_status = str(payload.get("status") or final_status)

        if stage in {"terminal_executed", "script_executed"}:
            status = str(payload.get("status") or ("executed" if payload.get("ok") else "failed"))
            iteration = current_iteration or None
            output_blocks = []
            if payload.get("output_preview"):
                output_blocks.append({"kind": "stdout", "title": "审计输出预览", "text": str(payload.get("output_preview") or ""), "truncated_bytes": 0})
            if payload.get("stderr_preview"):
                output_blocks.append({"kind": "stderr", "title": "审计错误预览", "text": str(payload.get("stderr_preview") or ""), "truncated_bytes": 0})
            output_blocks.append({"kind": "meta", "title": "审计恢复摘要", "json": {"stage": stage, "status": status, "payload": payload}})
            timeline_order.append(
                (
                    "item",
                    {
                        "id": f"{stage}-r{current_request}-i{iteration or 0}-{len(timeline_order) + 1}",
                        "kind": "execution",
                        "status": status,
                        "iteration": iteration,
                        "request_index": current_request,
                        "step_id": stage,
                        "title": "终端执行" if stage == "terminal_executed" else "Skill 执行",
                        "summary": compact_summary(payload.get("action") or status),
                        "risk_level": None,
                        "step": {
                            "id": stage,
                            "title": "终端执行" if stage == "terminal_executed" else "Skill 执行",
                            "executor_type": "terminal" if stage == "terminal_executed" else "skill_script",
                        },
                        "output_blocks": output_blocks,
                    },
                )
            )
            continue

        if stage not in step_statuses:
            continue
        upsert_step_record(stage, payload)

    timeline = []
    for item_type, value in timeline_order:
        if item_type == "step":
            record = step_records.get(value)
            if record:
                timeline.append(timeline_item_for_record(record))
        else:
            timeline.append(value)

    output_blocks = []
    if final_answer_summary:
        output_blocks.append(
            {
                "kind": "markdown",
                "title": "最终回答",
                "text": final_answer_summary,
                "truncated_bytes": 0,
            }
        )
    output_blocks.append(
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
    )

    restored = {
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
        "output_blocks": output_blocks,
    }
    if include_turns:
        restored["turns"] = build_web_turns_from_audit(session_id, events)
    return restored


def build_web_turns_from_audit(session_id, events):
    turns = []
    current_events = []
    current_input = ""
    current_mode = ""
    current_started_at = ""

    def cloned_event(event, stage=None, payload=None, timestamp=None):
        cloned = dict(event) if isinstance(event, dict) else {}
        if stage is not None:
            cloned["stage"] = stage
        if payload is not None:
            cloned["payload"] = payload
        if timestamp is not None:
            cloned["timestamp"] = timestamp
        return cloned

    def planned_event_from_reflection(event, iteration):
        payload = dict(audit_payload(event))
        payload["iteration"] = iteration
        if not payload.get("summary_preview") and payload.get("summary"):
            payload["summary_preview"] = payload.get("summary")
        return cloned_event(event, stage="planned", payload=payload)

    def synthetic_finished_event(status, timestamp):
        return {
            "timestamp": timestamp or now_iso(),
            "session_id": session_id,
            "stage": "finished",
            "payload": {"status": status},
        }

    def append_turn(turn_events, input_value, mode_value, started_at, iteration=None, status_override=""):
        if not turn_events:
            return
        turn_number = len(turns) + 1
        result = build_web_timeline_from_audit(session_id, turn_events, include_turns=False)
        if iteration is not None:
            result["iteration"] = iteration
            result["loop_iteration"] = iteration
        if status_override and result.get("status") == "restored":
            result["status"] = status_override
        status = result.get("status") or "restored"
        turns.append(
            {
                "id": f"{session_id}-turn-{turn_number}",
                "number": turn_number,
                "mode": mode_value or "work",
                "input": input_value,
                "status": status,
                "created_at": started_at,
                "updated_at": str(turn_events[-1].get("timestamp") or started_at),
                "source": "audit",
                "result": result,
            }
        )

    def append_request_turns(request_events, input_value, mode_value, started_at):
        if not request_events:
            return
        iteration_starts = []
        for index, event in enumerate(request_events):
            if audit_stage(event) != "agent_loop_iteration_started":
                continue
            iteration = safe_int(audit_payload(event).get("iteration"), len(iteration_starts) + 1)
            iteration_starts.append((index, iteration))
        if len(iteration_starts) <= 1:
            iteration = iteration_starts[0][1] if iteration_starts else None
            append_turn(request_events, input_value, mode_value, started_at, iteration=iteration)
            return

        received_event = next((event for event in request_events if audit_stage(event) == "received"), None)
        first_iteration_index = iteration_starts[0][0]
        initial_plan_event = next(
            (
                event
                for event in request_events[:first_iteration_index]
                if audit_stage(event) == "planned"
            ),
            None,
        )
        for position, (start_index, iteration) in enumerate(iteration_starts):
            next_start_index = iteration_starts[position + 1][0] if position + 1 < len(iteration_starts) else len(request_events)
            seed_events = []
            if received_event:
                seed_events.append(received_event)
            if iteration == 1 and initial_plan_event:
                seed_events.append(initial_plan_event)
            elif iteration > 1:
                reflected_plan = next(
                    (
                        event
                        for event in reversed(request_events[:start_index])
                        if audit_stage(event) == "agent_reflection_planned"
                        and str(audit_payload(event).get("response_type") or "") == "work_plan"
                    ),
                    None,
                )
                if reflected_plan:
                    seed_events.append(planned_event_from_reflection(reflected_plan, iteration))

            loop_events = []
            for event in request_events[start_index:next_start_index]:
                if audit_stage(event) == "agent_reflection_planned" and str(audit_payload(event).get("response_type") or "") == "work_plan":
                    continue
                loop_events.append(event)
            if position + 1 < len(iteration_starts) and not any(audit_stage(event) in {"finished", "agent_loop_finished"} for event in loop_events):
                last_timestamp = str(loop_events[-1].get("timestamp") if loop_events else started_at)
                loop_events.append(synthetic_finished_event("executed", last_timestamp))
            append_turn(seed_events + loop_events, input_value, mode_value, started_at, iteration=iteration, status_override="executed")

    def finish_current():
        nonlocal current_events, current_input, current_mode, current_started_at
        if not current_events:
            return
        append_request_turns(current_events, current_input, current_mode, current_started_at)
        current_events = []
        current_input = ""
        current_mode = ""
        current_started_at = ""

    for event in events if isinstance(events, list) else []:
        stage = audit_stage(event)
        payload = audit_payload(event)
        if stage == "received":
            finish_current()
            current_events = [event]
            current_input = str(payload.get("input_preview") or payload.get("command") or payload.get("ref") or "")
            current_mode = str(payload.get("mode") or "")
            current_started_at = str(event.get("timestamp") or "")
            continue
        if current_events:
            current_events.append(event)
            if stage == "finished":
                finish_current()

    finish_current()
    return turns


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
            "/api/mcp": ("mcp", "list"),
            "/api/mcp/validate": ("mcp", "validate"),
            "/api/mcp/tools": ("mcp", "tools"),
            "/api/audit/list": ("audit", "list"),
        }
        if path == "/api/policies":
            json_response(self, HTTPStatus.OK, {"ok": True, "status": "listed", "files": list_policy_files(), "requires_sudo_to_edit": True})
            return
        if path == "/api/config":
            json_response(self, HTTPStatus.OK, config_public_state())
            return
        if path == "/api/config/providers":
            json_response(self, HTTPStatus.OK, providers_public_state())
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
        if path == "/api/audit/list":
            result = run_agent_api("audit", "list", body, timeout=120)
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
            result = restore_web_agent_session_from_audit(str(body.get("session_id") or ""))
            json_response(self, HTTPStatus.OK, result)
            return
        if path == "/api/session/leave":
            json_response(self, HTTPStatus.OK, leave_web_agent_session())
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

    initialize_web_agent_session()
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
        record_web_agent_session_event(
            "session_finished",
            {
                "status": "stopped",
                "run_id": SERVER_RUN_ID,
            },
        )
        server.server_close()


if __name__ == "__main__":
    main()
