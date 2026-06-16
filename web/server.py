#!/usr/bin/env python3

import json
import os
import errno
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
AGENT = ROOT / "bin" / "agent"
HOST = os.environ.get("LINUX_AGENT_WEB_HOST", "127.0.0.1")
PORT = int(os.environ.get("LINUX_AGENT_WEB_PORT", "8765"))
TOKEN = os.environ.get("LINUX_AGENT_WEB_TOKEN", "")
JOB_RETENTION_HOURS = int(os.environ.get("LINUX_AGENT_WEB_JOB_RETENTION_HOURS", "24"))


def read_config():
    path = ROOT / "config" / "config.json"
    try:
        with path.open("r", encoding="utf-8") as handle:
            return json.load(handle)
    except FileNotFoundError:
        return {}


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


def text_response(handler, status, text, content_type="text/plain; charset=utf-8"):
    body = text.encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", content_type)
    handler.send_header("Content-Length", str(len(body)))
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


def write_policy_file(relative_path, content, password):
    target = safe_policy_path(relative_path)
    if not isinstance(content, str) or not content.strip():
        return {"ok": False, "status": "empty_content", "error": "Policy content is empty."}
    try:
        parsed = json.loads(content)
    except json.JSONDecodeError as exc:
        return {"ok": False, "status": "invalid_json", "error": str(exc)}

    target.parent.mkdir(parents=True, exist_ok=True)
    tmp_dir = ROOT / "tmp" / "web" / "policy-edits"
    tmp_dir.mkdir(parents=True, exist_ok=True)
    tmp_path = tmp_dir / f"{target.name}.{uuid.uuid4().hex}.tmp"
    tmp_path.write_text(json.dumps(parsed, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

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


def run_agent_api(resource, action="", payload=None, timeout=None):
    payload = payload or {}
    command = ["bash", str(AGENT), "api", resource]
    if action:
        command.append(action)
    command.append(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))
    env = os.environ.copy()
    env.setdefault("LINUX_AGENT_WEB", "1")
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
    try:
        result = json.loads(stdout) if stdout else {}
    except json.JSONDecodeError:
        result = {
            "ok": False,
            "status": "invalid_agent_output",
            "stdout_preview": stdout[:4000],
        }
    if isinstance(result, dict):
        result.setdefault("ok", process.returncode == 0 and result.get("ok", False))
        result.setdefault("status", "completed" if process.returncode == 0 else "failed")
        result["agent_exit_code"] = process.returncode
        if stderr:
            result["stderr_preview"] = stderr[:4000]
    return result


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
    }
    write_job(job_id, job)

    def worker():
        started_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        job["status"] = "running"
        job["started_at"] = started_at
        job["updated_at"] = started_at
        write_job(job_id, job)
        try:
            result = run_agent_api(resource, action, payload, timeout=None)
            finished_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
            job["status"] = "succeeded" if result.get("ok") or result.get("status") == "approval_required" else "failed"
            job["result"] = result
            job["finished_at"] = finished_at
            job["updated_at"] = finished_at
            write_job(job_id, job)
        except Exception as exc:  # noqa: BLE001 - surfaced as a job failure.
            finished_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
            job["status"] = "failed"
            job["result"] = {"ok": False, "status": "job_exception", "error": str(exc)}
            job["finished_at"] = finished_at
            job["updated_at"] = finished_at
            write_job(job_id, job)

    threading.Thread(target=worker, daemon=True).start()
    return job


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
        json_response(self, HTTPStatus.OK, result)

    def handle_api_post(self, path, body):
        sync_routes = {
            "/api/sense": ("sense", "get"),
            "/api/script/review": ("script", "review"),
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
        server.server_close()


if __name__ == "__main__":
    main()
