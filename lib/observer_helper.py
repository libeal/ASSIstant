#!/usr/bin/env python3
"""Minimal privileged auditd helper with a fixed Unix-socket protocol."""

from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import os
import re
import signal
import socket
import stat
import subprocess
import sys
import threading
import time
from contextlib import nullcontext
from pathlib import Path

from subprocess_env import build_subprocess_env
from helper_protocol import (
    PROTOCOL_VERSION,
    ProtocolError,
    allowed_peer_uid,
    build_request as build_protocol_request,
    client_request as protocol_client_request,
    peer_credentials,
    receive_json,
    runtime_shared_lock,
    send_json,
    systemd_listener,
    validate_request,
)


MAX_STREAM_BYTES = 1_048_576
MAX_CAPABILITY_STATE_BYTES = 1_048_576
COMMAND_TIMEOUT_SEC = 15.0
CAPABILITY_STATE_VERSION = 1
DEFAULT_CAPABILITY_STATE_PATH = "/run/linux-agent/observer-capabilities.json"
KEY_PATTERN = re.compile(r"^linux_agent_[A-Za-z0-9_]{1,112}$")
CAPABILITY_PATTERN = re.compile(r"^[0-9a-f]{64}$")
LOCAL_SOCKET_PATTERN = re.compile(
    r"^linux-agent-observer-(?P<uid>[0-9]+)-(?P<pid>[0-9]+)-(?P<nonce>[0-9a-f]{24})\.sock$"
)
MAX_AUTHORIZED_SESSIONS = 256
ALLOWED_SYSCALLS = frozenset(
    {
        "chmod",
        "chown",
        "creat",
        "execve",
        "execveat",
        "fchmod",
        "fchmodat",
        "fchown",
        "fchownat",
        "ftruncate",
        "link",
        "linkat",
        "mkdir",
        "mkdirat",
        "open",
        "openat",
        "openat2",
        "rename",
        "renameat",
        "renameat2",
        "rmdir",
        "symlink",
        "symlinkat",
        "truncate",
        "unlink",
        "unlinkat",
    }
)
TOOL_PATHS = {
    "auditctl": ("/sbin/auditctl", "/usr/sbin/auditctl", "/usr/bin/auditctl"),
    "ausearch": ("/sbin/ausearch", "/usr/sbin/ausearch", "/usr/bin/ausearch"),
}
_CAPABILITY_LOCK = threading.Lock()
_SESSION_CAPABILITIES: dict[str, dict[str, object]] = {}
_CAPABILITY_STATE_PATH: Path | None = None


class HelperRequestError(ProtocolError):
    """Raised when a client request is outside the helper allowlist."""


def _trusted_tool(name: str) -> str:
    for candidate in TOOL_PATHS.get(name, ()):
        path = Path(candidate)
        try:
            resolved = path.resolve(strict=True)
            metadata = resolved.stat()
        except (FileNotFoundError, OSError):
            continue
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != 0:
            continue
        if metadata.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
            continue
        if os.access(resolved, os.X_OK):
            return os.fspath(resolved)
    raise HelperRequestError(f"trusted {name} executable is unavailable")


def _validated_key(value: object) -> str:
    key = str(value or "")
    if KEY_PATTERN.fullmatch(key) is None:
        raise HelperRequestError("invalid audit key")
    return key


def _validated_capability(value: object) -> str:
    capability = str(value or "")
    if CAPABILITY_PATTERN.fullmatch(capability) is None:
        raise HelperRequestError("invalid observer capability")
    return capability


def _validated_syscall(value: object) -> str:
    syscall_name = str(value or "")
    if syscall_name not in ALLOWED_SYSCALLS:
        raise HelperRequestError("syscall is outside the observer allowlist")
    return syscall_name


def _capability_digest(capability: str) -> str:
    return hashlib.sha256(capability.encode("ascii")).hexdigest()


def _serialized_capability_state() -> dict[str, object]:
    sessions = {}
    for key, record in sorted(_SESSION_CAPABILITIES.items()):
        syscalls = record.get("syscalls")
        sessions[key] = {
            "digest": str(record.get("digest") or ""),
            "audit_uid": record.get("audit_uid"),
            "syscalls": sorted(syscalls) if isinstance(syscalls, set) else [],
        }
    return {
        "version": CAPABILITY_STATE_VERSION,
        "sessions": sessions,
    }


def _write_all(descriptor: int, payload: bytes) -> None:
    offset = 0
    while offset < len(payload):
        written = os.write(descriptor, payload[offset:])
        if written <= 0:
            raise OSError("short write while persisting observer capabilities")
        offset += written


def _assert_no_symlink_components(path: Path) -> None:
    """Reject state paths that could redirect persistence outside the runtime."""

    current = Path(path.anchor or "/")
    for component in path.parts[1:] if path.is_absolute() else path.parts:
        current /= component
        try:
            metadata = current.lstat()
        except FileNotFoundError:
            continue
        if stat.S_ISLNK(metadata.st_mode):
            raise RuntimeError(f"observer capability state path contains a symbolic link: {current}")
        if not stat.S_ISDIR(metadata.st_mode):
            raise RuntimeError(f"observer capability state path component is not a directory: {current}")


def _persist_capability_state_locked() -> None:
    path = _CAPABILITY_STATE_PATH
    if path is None:
        return
    _assert_no_symlink_components(path.parent)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.{threading.get_ident()}.tmp")
    payload = (
        json.dumps(
            _serialized_capability_state(),
            ensure_ascii=True,
            separators=(",", ":"),
            sort_keys=True,
        ).encode("utf-8")
        + b"\n"
    )
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(temporary, flags, 0o600)
    try:
        _write_all(descriptor, payload)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    try:
        os.replace(temporary, path)
        os.chmod(path, 0o600)
        directory_flags = os.O_RDONLY
        if hasattr(os, "O_DIRECTORY"):
            directory_flags |= os.O_DIRECTORY
        directory_fd = os.open(path.parent, directory_flags)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def _load_capability_records(path: Path) -> dict[str, dict[str, object]]:
    _assert_no_symlink_components(path.parent)
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except FileNotFoundError:
        return {}
    except OSError as exc:
        raise RuntimeError("observer capability state cannot be opened safely") from exc
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.geteuid():
            raise RuntimeError("observer capability state has an untrusted owner or type")
        if stat.S_IMODE(metadata.st_mode) & 0o077:
            raise RuntimeError("observer capability state must be owner-only")
        if metadata.st_size > MAX_CAPABILITY_STATE_BYTES:
            raise RuntimeError("observer capability state exceeds its size limit")
        with os.fdopen(descriptor, "r", encoding="utf-8") as handle:
            descriptor = -1
            payload = json.load(handle)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise RuntimeError("observer capability state is invalid") from exc
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    if not isinstance(payload, dict) or payload.get("version") != CAPABILITY_STATE_VERSION:
        raise RuntimeError("observer capability state version is unsupported")
    sessions = payload.get("sessions")
    if not isinstance(sessions, dict) or len(sessions) > MAX_AUTHORIZED_SESSIONS:
        raise RuntimeError("observer capability state sessions are invalid")
    records = {}
    for raw_key, raw_record in sessions.items():
        key = _validated_key(raw_key)
        if not isinstance(raw_record, dict):
            raise RuntimeError("observer capability record must be an object")
        digest = str(raw_record.get("digest") or "")
        if CAPABILITY_PATTERN.fullmatch(digest) is None:
            raise RuntimeError("observer capability digest is invalid")
        audit_uid = raw_record.get("audit_uid")
        if (
            isinstance(audit_uid, bool)
            or not isinstance(audit_uid, int)
            or audit_uid < 0
            or audit_uid >= 4_294_967_295
        ):
            raise RuntimeError("observer capability audit uid is invalid")
        raw_syscalls = raw_record.get("syscalls")
        if not isinstance(raw_syscalls, list) or any(
            not isinstance(item, str) or item not in ALLOWED_SYSCALLS
            for item in raw_syscalls
        ):
            raise RuntimeError("observer capability syscall set is invalid")
        records[key] = {
            "digest": digest,
            "audit_uid": audit_uid,
            "syscalls": set(raw_syscalls),
        }
    return records


def configure_capability_state(path: str | os.PathLike[str] | None) -> None:
    """Select and load the root-owned capability registry used by the daemon."""

    global _CAPABILITY_STATE_PATH
    state_path = None if path is None else Path(path)
    if state_path is not None and not state_path.is_absolute():
        raise RuntimeError("observer capability state path must be absolute")
    records = {} if state_path is None else _load_capability_records(state_path)
    with _CAPABILITY_LOCK:
        _CAPABILITY_STATE_PATH = state_path
        _SESSION_CAPABILITIES.clear()
        _SESSION_CAPABILITIES.update(records)


def authorize_request(
    request: object,
    *,
    peer_pid: int,
    peer_uid: int,
) -> tuple[str, bool, bool] | None:
    """Bind every mutable/readback operation to one session capability."""

    if not isinstance(request, dict):
        raise HelperRequestError("request must be a JSON object")
    operation = str(request.get("operation") or "")
    if operation in {"ping", "status"}:
        return None
    if operation not in {
        "list_rules",
        "search_key",
        "add_rule",
        "remove_rule",
        "release_key",
    }:
        return None

    key = _validated_key(request.get("key"))
    capability = _validated_capability(request.get("capability"))
    digest = _capability_digest(capability)
    audit_uid = None
    if operation in {"add_rule", "remove_rule"}:
        audit_uid = _validated_uid(
            request.get("audit_uid"),
            peer_pid=peer_pid,
            peer_uid=peer_uid,
        )

    with _CAPABILITY_LOCK:
        record = _SESSION_CAPABILITIES.get(key)
        created = False
        if record is None:
            if operation != "add_rule":
                raise HelperRequestError("observer capability is not registered")
            if len(_SESSION_CAPABILITIES) >= MAX_AUTHORIZED_SESSIONS:
                raise HelperRequestError("observer capability registry is full")
            record = {
                "digest": digest,
                "audit_uid": audit_uid,
                "syscalls": set(),
            }
            _SESSION_CAPABILITIES[key] = record
            created = True
        if not hmac.compare_digest(str(record.get("digest") or ""), digest):
            raise HelperRequestError("observer capability does not match the session")
        if audit_uid is not None and record.get("audit_uid") != audit_uid:
            raise HelperRequestError("observer audit uid does not match the session")
        syscall_prepared = False
        if operation == "add_rule":
            syscall_name = _validated_syscall(request.get("syscall"))
            syscalls = record.get("syscalls")
            if not isinstance(syscalls, set):
                syscalls = set()
                record["syscalls"] = syscalls
            if syscall_name not in syscalls:
                syscalls.add(syscall_name)
                syscall_prepared = True
            try:
                _persist_capability_state_locked()
            except Exception:
                if syscall_prepared:
                    syscalls.discard(syscall_name)
                if created and not syscalls:
                    _SESSION_CAPABILITIES.pop(key, None)
                raise
    return key, created, syscall_prepared


def finish_authorized_request(
    request: dict[str, object],
    authorization: tuple[str, bool, bool] | None,
    response: dict[str, object],
) -> None:
    if authorization is None:
        return
    key, created, syscall_prepared = authorization
    operation = str(request.get("operation") or "")
    with _CAPABILITY_LOCK:
        record = _SESSION_CAPABILITIES.get(key)
        if record is None:
            return
        syscalls = record.get("syscalls")
        if not isinstance(syscalls, set):
            syscalls = set()
            record["syscalls"] = syscalls
        if operation == "release_key" and response.get("ok") is True:
            if syscalls:
                response.update(
                    {
                        "ok": False,
                        "status": "rules_pending_cleanup",
                        "exit_code": 1,
                        "stderr": (
                            "observer capability still has pending syscall rules: "
                            + ", ".join(sorted(syscalls))
                        ),
                    }
                )
                return
            _SESSION_CAPABILITIES.pop(key, None)
            try:
                _persist_capability_state_locked()
            except OSError:
                _SESSION_CAPABILITIES[key] = record
                raise
            return
        syscall_name = str(request.get("syscall") or "")
        if operation == "add_rule" and response.get("ok") is True:
            # The intended syscall was persisted before auditctl ran, so a
            # helper crash during the command still leaves cleanup ownership.
            return
        if operation == "add_rule" and syscall_prepared:
            syscalls.discard(syscall_name)
            removed_record = created and not syscalls
            if removed_record:
                _SESSION_CAPABILITIES.pop(key, None)
            try:
                _persist_capability_state_locked()
            except OSError:
                syscalls.add(syscall_name)
                if removed_record:
                    _SESSION_CAPABILITIES[key] = record
                raise
            return
        if operation == "remove_rule" and response.get("ok") is True:
            was_present = syscall_name in syscalls
            syscalls.discard(syscall_name)
            try:
                _persist_capability_state_locked()
            except OSError:
                if was_present:
                    syscalls.add(syscall_name)
                raise


def rollback_new_authorization(
    authorization: tuple[str, bool, bool] | None,
    request: object = None,
) -> None:
    if authorization is None:
        return
    key, created, syscall_prepared = authorization
    with _CAPABILITY_LOCK:
        record = _SESSION_CAPABILITIES.get(key)
        if record is None:
            return
        syscalls = record.get("syscalls")
        if not syscall_prepared or not isinstance(request, dict) or not isinstance(syscalls, set):
            return
        syscall_name = str(request.get("syscall") or "")
        syscalls.discard(syscall_name)
        removed_record = created and not syscalls
        if removed_record:
            _SESSION_CAPABILITIES.pop(key, None)
        try:
            _persist_capability_state_locked()
        except OSError:
            syscalls.add(syscall_name)
            if removed_record:
                _SESSION_CAPABILITIES[key] = record


def _validated_uid(value: object, *, peer_pid: int, peer_uid: int) -> int:
    if isinstance(value, bool):
        raise HelperRequestError("audit_uid must be an integer")
    try:
        audit_uid = int(value)
    except (TypeError, ValueError) as exc:
        raise HelperRequestError("audit_uid must be an integer") from exc
    if audit_uid < 0 or audit_uid >= 4_294_967_295:
        raise HelperRequestError("audit_uid is outside the Linux uid range")
    if peer_uid == 0:
        return audit_uid

    allowed = {peer_uid}
    try:
        login_uid = int(Path(f"/proc/{peer_pid}/loginuid").read_text().strip())
        if 0 <= login_uid < 4_294_967_295:
            allowed.add(login_uid)
    except (FileNotFoundError, PermissionError, OSError, ValueError):
        pass
    if audit_uid not in allowed:
        raise HelperRequestError("audit_uid does not belong to the requesting process")
    return audit_uid


def build_command(request: object, *, peer_pid: int, peer_uid: int) -> list[str]:
    if not isinstance(request, dict):
        raise HelperRequestError("request must be a JSON object")
    operation = str(request.get("operation") or "")
    if operation == "status":
        return [_trusted_tool("auditctl"), "-s"]
    if operation == "list_rules":
        return [_trusted_tool("auditctl"), "-l"]
    if operation == "search_key":
        return [_trusted_tool("ausearch"), "-k", _validated_key(request.get("key"))]
    if operation not in {"add_rule", "remove_rule"}:
        raise HelperRequestError("unsupported helper operation")

    audit_uid = _validated_uid(
        request.get("audit_uid"), peer_pid=peer_pid, peer_uid=peer_uid
    )
    key = _validated_key(request.get("key"))
    syscall_name = _validated_syscall(request.get("syscall"))
    action = "-a" if operation == "add_rule" else "-d"
    return [
        _trusted_tool("auditctl"),
        action,
        "always,exit",
        "-F",
        "arch=b64",
        "-S",
        syscall_name,
        "-F",
        f"auid={audit_uid}",
        "-k",
        key,
    ]


def _bounded_reader(stream, retained: list[bytes], total: list[int], overflow):
    try:
        while True:
            chunk = stream.read(65_536)
            if not chunk:
                break
            previous = total[0]
            total[0] += len(chunk)
            remaining = max(0, MAX_STREAM_BYTES - previous)
            if remaining:
                retained.append(chunk[:remaining])
            if len(chunk) > remaining:
                overflow.set()
    finally:
        stream.close()


def run_command(command: list[str]) -> dict[str, object]:
    process = subprocess.Popen(
        command,
        env=build_subprocess_env(include_api_key=False),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    stdout_parts: list[bytes] = []
    stderr_parts: list[bytes] = []
    stdout_total = [0]
    stderr_total = [0]
    overflow = threading.Event()
    readers = [
        threading.Thread(
            target=_bounded_reader,
            args=(process.stdout, stdout_parts, stdout_total, overflow),
            daemon=True,
        ),
        threading.Thread(
            target=_bounded_reader,
            args=(process.stderr, stderr_parts, stderr_total, overflow),
            daemon=True,
        ),
    ]
    for reader in readers:
        reader.start()

    deadline = time.monotonic() + COMMAND_TIMEOUT_SEC
    timed_out = False
    while process.poll() is None:
        if overflow.is_set() or time.monotonic() >= deadline:
            timed_out = not overflow.is_set()
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            break
        time.sleep(0.02)
    returncode = process.wait()
    for reader in readers:
        reader.join(timeout=2.0)
    if any(reader.is_alive() for reader in readers):
        raise RuntimeError("audit helper output reader did not terminate")

    truncated = overflow.is_set()
    status = "executed"
    if truncated:
        status = "output_limit_exceeded"
    elif timed_out:
        status = "timed_out"
    elif returncode != 0:
        status = "failed"
    return {
        "ok": returncode == 0 and not truncated and not timed_out,
        "status": status,
        "exit_code": returncode,
        "stdout": b"".join(stdout_parts).decode("utf-8", errors="replace"),
        "stderr": b"".join(stderr_parts).decode("utf-8", errors="replace"),
        "stdout_truncated_bytes": max(0, stdout_total[0] - MAX_STREAM_BYTES),
        "stderr_truncated_bytes": max(0, stderr_total[0] - MAX_STREAM_BYTES),
    }


def _peer_credentials(connection: socket.socket) -> tuple[int, int, int]:
    """Keep a patchable local seam while using the shared SO_PEERCRED check."""

    return peer_credentials(connection)


def _validate_operation_params(operation: str, params: dict[str, object]) -> dict[str, object]:
    expected_fields = {
        "ping": set(),
        "status": set(),
        "list_rules": {"key", "capability"},
        "search_key": {"key", "capability"},
        "add_rule": {"audit_uid", "key", "syscall", "capability"},
        "remove_rule": {"audit_uid", "key", "syscall", "capability"},
        "release_key": {"key", "capability"},
    }
    if operation not in expected_fields:
        raise HelperRequestError("unsupported helper operation")
    if set(params) != expected_fields[operation]:
        raise HelperRequestError(f"{operation} params do not match the fixed schema")
    return {"operation": operation, **params}


def handle_connection(
    connection: socket.socket,
    expected_uid: int | None = None,
    *,
    use_runtime_lock: bool = True,
) -> None:
    peer_pid = peer_uid = peer_gid = -1
    operation = ""
    request = None
    authorization = None
    request_id = ""
    try:
        peer_pid, peer_uid, peer_gid = _peer_credentials(connection)
        if expected_uid is not None and peer_uid != expected_uid:
            raise HelperRequestError("requesting process uid is not authorized")
        envelope = receive_json(connection)
        operation, params, _summary, request_id = validate_request(envelope)
        request = _validate_operation_params(operation, params)
        if operation == "ping":
            response = {
                "ok": True,
                "status": "ready",
                "exit_code": 0,
                "stdout": "",
                "stderr": "",
            }
        else:
            lock_context = runtime_shared_lock() if use_runtime_lock else nullcontext()
            with lock_context:
                authorization = authorize_request(
                    request,
                    peer_pid=peer_pid,
                    peer_uid=peer_uid,
                )
                if operation == "release_key":
                    response = {
                        "ok": True,
                        "status": "released",
                        "exit_code": 0,
                        "stdout": "",
                        "stderr": "",
                    }
                else:
                    response = run_command(
                        build_command(request, peer_pid=peer_pid, peer_uid=peer_uid)
                    )
                finish_authorized_request(request, authorization, response)
    except ProtocolError as exc:
        rollback_new_authorization(authorization, request)
        response = {
            "ok": False,
            "status": "helper_rejected",
            "code": "helper_rejected",
            "exit_code": 126,
            "stdout": "",
            "stderr": str(exc),
        }
    except Exception as exc:
        rollback_new_authorization(authorization, request)
        response = {
            "ok": False,
            "status": "helper_failed",
            "code": "helper_failed",
            "exit_code": 125,
            "stdout": "",
            "stderr": str(exc),
        }
    response.update(
        {
            "protocol_version": PROTOCOL_VERSION,
            "request_id": request_id,
        }
    )
    try:
        send_json(connection, response)
    except OSError as exc:
        print(
            json.dumps(
                {
                    "event": "observer_helper_response_delivery_failed",
                    "peer_pid": peer_pid,
                    "peer_uid": peer_uid,
                    "operation": operation,
                    "error": str(exc)[:200],
                },
                separators=(",", ":"),
            ),
            file=sys.stderr,
            flush=True,
        )
        return
    print(
        json.dumps(
            {
                "event": "observer_helper_request",
                "peer_pid": peer_pid,
                "peer_uid": peer_uid,
                "peer_gid": peer_gid,
                "operation": operation,
                "status": response["status"],
                "exit_code": response["exit_code"],
            },
            separators=(",", ":"),
        ),
        file=sys.stderr,
        flush=True,
    )


def serve() -> int:
    if os.geteuid() != 0:
        raise RuntimeError("observer helper service must run as root")
    configure_capability_state(
        os.environ.get(
            "LINUX_AGENT_OBSERVER_HELPER_STATE",
            DEFAULT_CAPABILITY_STATE_PATH,
        )
    )
    listener = systemd_listener()
    expected_uid = allowed_peer_uid("linux-agent")
    while True:
        connection, _ = listener.accept()
        with connection:
            connection.settimeout(5.0)
            try:
                handle_connection(connection, expected_uid)
            except Exception as exc:  # Isolate one malformed peer from the daemon.
                print(
                    json.dumps(
                        {
                            "event": "observer_helper_connection_failed",
                            "error": str(exc)[:200],
                        },
                        separators=(",", ":"),
                    ),
                    file=sys.stderr,
                    flush=True,
                )


def _process_start_time(process_id: int) -> str:
    try:
        raw = Path(f"/proc/{process_id}/stat").read_text(encoding="ascii")
        _prefix, separator, remainder = raw.rpartition(")")
        fields = remainder.strip().split() if separator else []
    except (FileNotFoundError, PermissionError, OSError, UnicodeDecodeError):
        return ""
    if len(fields) <= 19:
        return ""
    return fields[19]


def _process_owner_uid(process_id: int) -> int:
    try:
        return Path(f"/proc/{process_id}").stat().st_uid
    except (FileNotFoundError, PermissionError, OSError):
        return -1


def _validate_local_runtime(
    socket_path: str,
    *,
    expected_uid: int,
    owner_pid: int,
    owner_start_time: str,
) -> Path:
    path = Path(socket_path)
    match = LOCAL_SOCKET_PATTERN.fullmatch(path.name)
    if path.parent != Path("/run") or match is None:
        raise RuntimeError("local observer socket must use the fixed /run name format")
    if int(match.group("uid")) != expected_uid or int(match.group("pid")) != owner_pid:
        raise RuntimeError("local observer socket identity does not match its owner")
    if expected_uid <= 0 or owner_pid <= 1 or not owner_start_time.isdigit():
        raise RuntimeError("local observer owner identity is invalid")
    owner_uid = _process_owner_uid(owner_pid)
    if owner_uid < 0:
        raise RuntimeError("local observer owner process is unavailable")
    if (
        owner_uid != expected_uid
        or _process_start_time(owner_pid) != owner_start_time
    ):
        raise RuntimeError("local observer owner process identity is stale")
    try:
        path.lstat()
    except FileNotFoundError:
        pass
    else:
        raise RuntimeError("local observer socket path already exists")
    return path


def serve_local(
    socket_path: str,
    *,
    expected_uid: int,
    owner_pid: int,
    owner_start_time: str,
) -> int:
    """Serve one source-runtime Web process without relying on sudo tickets."""

    if os.geteuid() != 0:
        raise RuntimeError("local observer helper must run as root")
    path = _validate_local_runtime(
        socket_path,
        expected_uid=expected_uid,
        owner_pid=owner_pid,
        owner_start_time=owner_start_time,
    )
    configure_capability_state(None)
    stop_event = threading.Event()

    def request_stop(_signum, _frame):
        stop_event.set()

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    previous_umask = os.umask(0o177)
    try:
        listener.bind(os.fspath(path))
    finally:
        os.umask(previous_umask)
    try:
        os.chown(path, expected_uid, -1)
        os.chmod(path, 0o600)
        listener.listen(16)
        listener.settimeout(1.0)
        while not stop_event.is_set():
            if _process_start_time(owner_pid) != owner_start_time:
                break
            try:
                connection, _ = listener.accept()
            except socket.timeout:
                continue
            with connection:
                connection.settimeout(5.0)
                try:
                    handle_connection(
                        connection,
                        expected_uid,
                        use_runtime_lock=False,
                    )
                except Exception as exc:
                    print(
                        json.dumps(
                            {
                                "event": "observer_helper_connection_failed",
                                "error": str(exc)[:200],
                            },
                            separators=(",", ":"),
                        ),
                        file=sys.stderr,
                        flush=True,
                    )
    finally:
        listener.close()
        try:
            if stat.S_ISSOCK(path.lstat().st_mode):
                path.unlink()
        except FileNotFoundError:
            pass
    return 0


def client_request(socket_path: str, request: dict[str, object]) -> int:
    if not isinstance(request, dict):
        raise HelperRequestError("request must be a JSON object")
    operation = str(request.get("operation") or "")
    params = {key: value for key, value in request.items() if key != "operation"}
    _validate_operation_params(operation, params)
    summary = f"Observer helper operation {operation}"
    envelope = build_protocol_request(operation, params, summary=summary)
    try:
        response = protocol_client_request(socket_path, envelope, timeout=20.0)
    except ProtocolError as exc:
        raise HelperRequestError(str(exc)) from exc
    stdout = response.get("stdout", "")
    stderr = response.get("stderr", "")
    if not isinstance(stdout, str) or not isinstance(stderr, str):
        raise HelperRequestError("helper response streams must be strings")
    if len(stdout.encode("utf-8")) > MAX_STREAM_BYTES or len(stderr.encode("utf-8")) > MAX_STREAM_BYTES:
        raise HelperRequestError("helper response streams exceed the client limit")
    sys.stdout.write(stdout)
    sys.stderr.write(stderr)
    exit_code = response.get("exit_code", 125)
    if (
        isinstance(exit_code, bool)
        or not isinstance(exit_code, int)
        or not 0 <= exit_code <= 255
    ):
        raise HelperRequestError("helper response exit_code is invalid")
    return exit_code


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("serve")
    local_parser = subparsers.add_parser("serve-local")
    local_parser.add_argument("--socket", required=True)
    local_parser.add_argument("--expected-uid", required=True, type=int)
    local_parser.add_argument("--owner-pid", required=True, type=int)
    local_parser.add_argument("--owner-start-time", required=True)
    request_parser = subparsers.add_parser("request")
    request_parser.add_argument("--socket", required=True)
    request_parser.add_argument(
        "operation",
        choices=(
            "ping",
            "status",
            "list_rules",
            "add_rule",
            "remove_rule",
            "search_key",
            "release_key",
        ),
    )
    request_parser.add_argument("--audit-uid", type=int)
    request_parser.add_argument("--key")
    request_parser.add_argument("--syscall")
    request_parser.add_argument("--capability")
    args = parser.parse_args()
    if args.command == "serve":
        return serve()
    if args.command == "serve-local":
        return serve_local(
            args.socket,
            expected_uid=args.expected_uid,
            owner_pid=args.owner_pid,
            owner_start_time=args.owner_start_time,
        )
    request = {"operation": args.operation}
    if args.audit_uid is not None:
        request["audit_uid"] = args.audit_uid
    if args.key is not None:
        request["key"] = args.key
    if args.syscall is not None:
        request["syscall"] = args.syscall
    if args.capability is not None:
        request["capability"] = args.capability
    try:
        return client_request(args.socket, request)
    except PermissionError as exc:
        print(
            "observer helper request failed: "
            f"permission denied for socket {args.socket}: {exc}. "
            "For a release install, run the current installer with "
            "repair-observer. For a source checkout, run scripts/install.sh "
            "repair-observer --prefix <source-dir> --service-user <web-user>. "
            "Both paths verify SocketGroup and recreate "
            "linux-agent-observer-helper.socket.",
            file=sys.stderr,
        )
        return 125
    except Exception as exc:  # Keep helper transport failures out of shell tracebacks.
        print(f"observer helper request failed: {exc}", file=sys.stderr)
        return 125


if __name__ == "__main__":
    raise SystemExit(main())
