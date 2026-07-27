#!/usr/bin/env python3
"""Unprivileged execution runner for Terminal, Skill, MCP, and remote scripts."""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import select
import signal
import socket
import stat
import subprocess
import sys
import threading
import time
from pathlib import Path

from helper_protocol import (
    MAX_REQUEST_BYTES,
    MAX_STREAM_FRAME_BYTES,
    PROTOCOL_VERSION,
    STREAM_CHUNK_BYTES,
    ProtocolError,
    allowed_peer_uid,
    build_request,
    canonical_json,
    client_request,
    receive_json_frame,
    require_peer_uid,
    runtime_shared_lock,
    send_json,
    send_stream_frame,
    systemd_listener,
    validate_request,
)


EXECUTION_KINDS = frozenset({"terminal", "skill", "mcp", "remote_script"})
SAFE_ID_PATTERN = re.compile(r"^[A-Za-z0-9_.:-]{0,128}$")
SKILL_NAME_PATTERN = re.compile(r"^[a-z0-9][a-z0-9-]*$")
SCRIPT_NAME_PATTERN = re.compile(r"^[a-z0-9][a-z0-9-]*\.sh$")
RISK_LEVELS = frozenset({"low", "medium", "high", "critical"})
SKILL_EXECUTION_CLASSES = frozenset({"runner", "host_helper"})
HOST_HELPER_CAPABILITIES = {
    "network-ops-tools/firewall": "firewall.apply",
    "network-ops-tools/hosts-file-editor": "hosts.apply",
}
DEFAULT_SOCKET = "/run/linux-agent/runner.sock"
MAX_OUTPUT_BYTES = 104_857_600
DEFAULT_MAX_CONCURRENT = 4
RESPONSE_SEND_TIMEOUT_SEC = 30.0
TRUSTED_EXECUTABLES = {
    "bash": ("/usr/bin/bash", "/bin/bash"),
    "python3": ("/usr/bin/python3", "/bin/python3"),
}


class RunnerRequestError(ProtocolError):
    """The requested process falls outside the runner contract."""


def _trusted_executable(name: str) -> str:
    for candidate in TRUSTED_EXECUTABLES.get(name, ()):
        path = Path(candidate)
        try:
            metadata = path.resolve(strict=True).stat()
        except OSError:
            continue
        if not stat.S_ISREG(metadata.st_mode):
            continue
        if metadata.st_uid != 0 or metadata.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
            continue
        if os.access(path, os.X_OK):
            return os.fspath(path.resolve())
    raise RunnerRequestError(f"trusted executable is unavailable: {name}")


def _integer(value: object, name: str, minimum: int, maximum: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise RunnerRequestError(f"{name} must be an integer")
    if value < minimum or value > maximum:
        raise RunnerRequestError(f"{name} is outside the allowed range")
    return value


def _safe_regular_path(raw: object, roots: tuple[Path, ...], suffix: str | None = None) -> str:
    if not isinstance(raw, str) or not raw or "\x00" in raw:
        raise RunnerRequestError("runner path is invalid")
    candidate = Path(raw)
    if not candidate.is_absolute() or candidate.is_symlink():
        raise RunnerRequestError("runner path must be an absolute non-symlink path")
    try:
        resolved = candidate.resolve(strict=True)
        metadata = resolved.stat()
    except OSError as exc:
        raise RunnerRequestError("runner path does not exist") from exc
    if not stat.S_ISREG(metadata.st_mode):
        raise RunnerRequestError("runner path must be a regular file")
    if metadata.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        raise RunnerRequestError("runner input files must not be group/world writable")
    if suffix is not None and resolved.suffix != suffix:
        raise RunnerRequestError("runner path has an unsupported suffix")
    for root in roots:
        try:
            resolved.relative_to(root.resolve(strict=True))
            return os.fspath(resolved)
        except (ValueError, OSError):
            continue
    raise RunnerRequestError("runner path is outside the allowed roots")


def _trusted_directory(path: Path, label: str) -> Path:
    """Resolve a runner-owned directory without following a mutable symlink."""

    if not path.is_absolute() or path.is_symlink():
        raise RunnerRequestError(f"{label} must be an absolute non-symlink directory")
    current = Path(path.root)
    for component in path.parts[1:]:
        current /= component
        try:
            metadata = current.lstat()
        except OSError as exc:
            raise RunnerRequestError(f"{label} is unavailable") from exc
        if stat.S_ISLNK(metadata.st_mode):
            raise RunnerRequestError(f"{label} contains a symbolic link")
        if not stat.S_ISDIR(metadata.st_mode):
            raise RunnerRequestError(f"{label} is not a directory")
    metadata = path.stat()
    if metadata.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        raise RunnerRequestError(f"{label} must not be group/world writable")
    return path.resolve(strict=True)


def _reject_json_constant(value: str) -> object:
    raise RunnerRequestError(f"non-finite JSON value is not allowed: {value}")


def _reject_duplicate_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise RunnerRequestError(f"duplicate JSON key is not allowed: {key}")
        result[key] = value
    return result


def _json_object(raw: str, name: str) -> dict[str, object]:
    try:
        value = json.loads(
            raw,
            parse_constant=_reject_json_constant,
            object_pairs_hook=_reject_duplicate_keys,
        )
    except (json.JSONDecodeError, RunnerRequestError) as exc:
        raise RunnerRequestError(f"{name} must be valid JSON") from exc
    if not isinstance(value, dict):
        raise RunnerRequestError(f"{name} must be a JSON object")
    return value


def _load_manifest(path: Path) -> dict[str, object]:
    try:
        value = json.loads(
            path.read_text(encoding="utf-8"),
            parse_constant=_reject_json_constant,
            object_pairs_hook=_reject_duplicate_keys,
        )
    except (OSError, UnicodeError, json.JSONDecodeError, RunnerRequestError) as exc:
        raise RunnerRequestError("Skill manifest is unavailable or invalid") from exc
    if not isinstance(value, dict):
        raise RunnerRequestError("Skill manifest must be a JSON object")
    return value


def _safe_skill_file(package: Path, name: str) -> Path:
    candidate = package / name
    if candidate.is_symlink() or not candidate.is_file():
        raise RunnerRequestError(f"Skill package is missing {name}")
    resolved = candidate.resolve(strict=True)
    try:
        resolved.relative_to(package.resolve(strict=True))
    except (ValueError, OSError) as exc:
        raise RunnerRequestError("Skill package file escapes its package") from exc
    metadata = resolved.stat()
    if not stat.S_ISREG(metadata.st_mode):
        raise RunnerRequestError(f"Skill package file is not regular: {name}")
    return resolved


def _validate_skill_manifest(script: Path, roots: dict[str, Path]) -> dict[str, object]:
    """Re-check the release/user manifest at the execution trust boundary.

    Web and CLI validation protects normal callers, but the Runner socket is a
    separate authorization boundary.  A request that reaches it directly must
    still be tied to a registered package and an allowed execution class.
    """

    resolved_script = script.resolve(strict=True)
    origin = None
    root = None
    for candidate_root, candidate_origin in (
        (roots["builtin_skills"], "builtin"),
        (roots["user_skills"], "user"),
    ):
        try:
            resolved_script.relative_to(candidate_root.resolve(strict=True))
        except (ValueError, OSError):
            continue
        origin = candidate_origin
        root = candidate_root.resolve(strict=True)
        break
    if origin is None or root is None:
        raise RunnerRequestError("Skill script is outside a registered Skill root")
    if candidate_root.is_symlink() or (origin == "user" and root != candidate_root):
        raise RunnerRequestError("Skill root must not be a symlink")
    root_metadata = root.stat()
    if root_metadata.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        raise RunnerRequestError("Skill root must not be group/world writable")
    relative = resolved_script.relative_to(root)
    if len(relative.parts) != 3 or relative.parts[1] != "scripts":
        raise RunnerRequestError("Skill script must be directly below <skill>/scripts")
    skill_name, _scripts_dir, script_name = relative.parts
    if SKILL_NAME_PATTERN.fullmatch(skill_name) is None or SCRIPT_NAME_PATTERN.fullmatch(
        script_name
    ) is None:
        raise RunnerRequestError("Skill package or script name is invalid")
    package = root / skill_name
    if origin == "user":
        builtin_package = roots["builtin_skills"].resolve(strict=True) / skill_name
        if builtin_package.exists() or builtin_package.is_symlink():
            raise RunnerRequestError("User Skill cannot override a built-in Skill")
    if package.is_symlink() or not package.is_dir():
        raise RunnerRequestError("Skill package must be a real directory")
    scripts_dir = package / "scripts"
    if scripts_dir.is_symlink() or not scripts_dir.is_dir():
        raise RunnerRequestError("Skill scripts directory must be a real directory")
    for directory, label in (
        (package, "Skill package"),
        (scripts_dir, "Skill scripts directory"),
    ):
        metadata = directory.stat()
        if metadata.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
            raise RunnerRequestError(f"{label} must not be group/world writable")
    script_file = _safe_skill_file(package, f"scripts/{script_name}")
    manifest_path = _safe_skill_file(package, "manifest.json")
    skill_markdown = _safe_skill_file(package, "SKILL.md")
    for path in (script_file, manifest_path, skill_markdown):
        if path.stat().st_mode & (stat.S_IWGRP | stat.S_IWOTH):
            raise RunnerRequestError("Skill package files must not be group/world writable")
    manifest = _load_manifest(manifest_path)
    schema_version = manifest.get("schema_version")
    if (
        isinstance(schema_version, bool)
        or not isinstance(schema_version, int)
        or schema_version != 1
        or manifest.get("name") != skill_name
    ):
        raise RunnerRequestError("Skill manifest identity is invalid")
    if not isinstance(manifest.get("description"), str) or not manifest["description"].strip():
        raise RunnerRequestError("Skill manifest description is invalid")
    entries = manifest.get("scripts")
    if not isinstance(entries, list) or not entries or not all(
        isinstance(entry, dict) for entry in entries
    ):
        raise RunnerRequestError("Skill manifest scripts are invalid")
    declared_names: set[str] = set()
    selected = None
    for entry in entries:
        name = entry.get("name")
        if not isinstance(name, str) or SCRIPT_NAME_PATTERN.fullmatch(name) is None:
            raise RunnerRequestError("Skill manifest script name is invalid")
        if name in declared_names:
            raise RunnerRequestError("Skill manifest script names must be unique")
        declared_names.add(name)
        risk = entry.get("risk")
        if not isinstance(risk, str) or risk not in RISK_LEVELS:
            raise RunnerRequestError("Skill manifest script risk is invalid")
        execution_class = entry.get("execution_class")
        capability = entry.get("capability")
        if execution_class not in SKILL_EXECUTION_CLASSES or not isinstance(capability, str):
            raise RunnerRequestError("Skill manifest execution contract is invalid")
        expected_capability = HOST_HELPER_CAPABILITIES.get(f"{skill_name}/{name[:-3]}")
        if origin == "user":
            if execution_class != "runner" or capability != "":
                raise RunnerRequestError("User Skill may only use runner execution")
        elif expected_capability is not None:
            if execution_class != "host_helper" or capability != expected_capability:
                raise RunnerRequestError("Privileged built-in Skill is not allowlisted")
        elif execution_class != "runner" or capability != "":
            raise RunnerRequestError("Built-in Skill execution contract is invalid")
        if name == script_name:
            selected = entry
    if selected is None:
        raise RunnerRequestError("Skill script is not declared by its manifest")
    actual_names: set[str] = set()
    for child in scripts_dir.iterdir():
        if child.is_symlink():
            raise RunnerRequestError("Skill scripts directory must not contain symlinks")
        if child.is_file() and child.suffix == ".sh":
            actual_names.add(child.name)
    if actual_names != declared_names:
        raise RunnerRequestError("Skill manifest does not match the script files")
    return selected


def _validate_host_helper_runner_arguments(
    skill_name: str,
    script_name: str,
    capability: object,
    arguments: dict[str, object],
) -> None:
    """Allow only read/plan forms of helper-capable Skills in the Runner.

    The privileged apply forms are handled by the root helper.  Keeping this
    check at the socket boundary prevents a direct Web/Unix-socket caller (or
    a source-runtime fallback) from smuggling an ambiguous truthy ``apply``
    value into the script and bypassing the helper contract.
    """

    if not isinstance(capability, str):
        raise RunnerRequestError("host-helper capability is invalid")
    action_value = arguments.get("action")
    if action_value is None:
        action = "status" if capability == "firewall.apply" else "read"
    elif isinstance(action_value, str):
        action = action_value.strip().lower()
    else:
        raise RunnerRequestError("host-helper Skill action must be a string")
    apply_value = arguments.get("apply", False)
    if not isinstance(apply_value, bool):
        raise RunnerRequestError("host-helper Skill apply must be boolean")

    if skill_name == "network-ops-tools" and script_name == "firewall.sh":
        if action in {"status", "plan"}:
            return
        if action == "apply" and not apply_value:
            return
        raise RunnerRequestError("firewall apply must use the dedicated host helper")
    if skill_name == "network-ops-tools" and script_name == "hosts-file-editor.sh":
        if action in {"read", "search", "plan-add", "plan-remove"}:
            return
        if action in {"add", "remove"} and not apply_value:
            return
        raise RunnerRequestError("hosts apply must use the dedicated host helper")
    raise RunnerRequestError("host-helper capability is not allowlisted")


def _runtime_roots() -> dict[str, Path]:
    root = Path(os.environ.get("LINUX_AGENT_ROOT", "/opt/linux-agent/current")).resolve()
    data = Path(
        os.path.abspath(os.environ.get("LINUX_AGENT_DATA_DIR", "/opt/linux-agent/data"))
    )
    return {
        "root": root,
        "builtin_skills": Path(
            os.environ.get("LINUX_AGENT_BUILTIN_SKILLS_DIR", root / "skills")
        ),
        "user_skills": Path(
            os.environ.get("LINUX_AGENT_USER_SKILLS_DIR", data / "skills")
        ),
        "mcp": Path(os.environ.get("LINUX_AGENT_MCP_DIR", root / "mcp")).resolve(),
        "tmp": Path(
            os.path.abspath(os.environ.get("LINUX_AGENT_TMP_ROOT", data / "runner-tmp"))
        ),
    }


def validate_execution(
    params: dict[str, object],
) -> tuple[str, list[str], int, int, dict[str, str]]:
    allowed_fields = {
        "kind",
        "argv",
        "timeout_sec",
        "max_output_bytes",
        "audit_snapshot",
        "audit_snapshot_session",
    }
    if set(params) - allowed_fields:
        raise RunnerRequestError("runner execute params contain unsupported fields")
    kind = params.get("kind")
    argv = params.get("argv")
    if kind not in EXECUTION_KINDS:
        raise RunnerRequestError("unsupported runner execution kind")
    if not isinstance(argv, list) or not argv or not all(isinstance(item, str) for item in argv):
        raise RunnerRequestError("runner argv must be a non-empty string array")
    if len(argv) > 64 or sum(len(item.encode("utf-8")) for item in argv) > 524_288:
        raise RunnerRequestError("runner argv exceeds the protocol limit")
    timeout_sec = _integer(params.get("timeout_sec"), "timeout_sec", 1, 3600)
    max_output = _integer(
        params.get("max_output_bytes"),
        "max_output_bytes",
        4096,
        MAX_OUTPUT_BYTES,
    )
    roots = _runtime_roots()
    roots["user_skills"] = _trusted_directory(roots["user_skills"], "User Skill root")
    roots["tmp"] = _trusted_directory(roots["tmp"], "Runner staging root")
    environment_overrides: dict[str, str] = {}
    audit_snapshot = params.get("audit_snapshot")
    audit_snapshot_session = params.get("audit_snapshot_session")
    if (audit_snapshot is None) != (audit_snapshot_session is None):
        raise RunnerRequestError("audit snapshot path and session must be provided together")

    if kind == "terminal":
        if len(argv) != 3 or argv[0] != "bash" or argv[1] != "-lc":
            raise RunnerRequestError("terminal requests must use bash -lc")
        command = [_trusted_executable("bash"), "-lc", argv[2]]
    elif kind == "skill":
        if len(argv) != 3 or argv[0] != "bash":
            raise RunnerRequestError("Skill requests must use bash <script> <json-object>")
        script = _safe_regular_path(
            argv[1],
            (roots["builtin_skills"], roots["user_skills"]),
            ".sh",
        )
        if "/scripts/" not in script:
            raise RunnerRequestError("Skill script is outside a scripts directory")
        manifest_entry = _validate_skill_manifest(Path(script), roots)
        arguments = _json_object(argv[2], "Skill arguments")
        if manifest_entry.get("execution_class") == "host_helper":
            _validate_host_helper_runner_arguments(
                Path(script).parent.parent.name,
                Path(script).name,
                manifest_entry.get("capability"),
                arguments,
            )
        command = [_trusted_executable("bash"), script, argv[2]]
        session_history = (
            Path(script).name == "last-command-output.sh"
            and Path(script).parent.name == "scripts"
            and Path(script).parent.parent.name == "session-history"
            and Path(script).parent.parent.parent
            == roots["builtin_skills"].resolve(strict=True)
        )
        if audit_snapshot is not None:
            if not session_history:
                raise RunnerRequestError(
                    "audit snapshots are restricted to the built-in session-history Skill"
                )
            snapshot = _safe_regular_path(
                audit_snapshot,
                (roots["tmp"],),
                ".jsonl",
            )
            metadata = Path(snapshot).stat()
            if metadata.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
                raise RunnerRequestError("audit snapshot must not be group/world writable")
            if metadata.st_size > MAX_OUTPUT_BYTES:
                raise RunnerRequestError("audit snapshot exceeds the runner size limit")
            if (
                not isinstance(audit_snapshot_session, str)
                or not audit_snapshot_session
                or re.fullmatch(r"[A-Za-z0-9_.-]{1,128}", audit_snapshot_session)
                is None
            ):
                raise RunnerRequestError("audit snapshot session id is invalid")
            requested_session = arguments.get("session_id")
            if requested_session is not None and requested_session != audit_snapshot_session:
                raise RunnerRequestError("audit snapshot session does not match Skill arguments")
            environment_overrides = {
                "LINUX_AGENT_AUDIT_SNAPSHOT_FILE": snapshot,
                "LINUX_AGENT_AUDIT_SNAPSHOT_SESSION_ID": audit_snapshot_session,
            }
    elif kind == "remote_script":
        if len(argv) != 3 or argv[0] != "bash":
            raise RunnerRequestError("remote script requests must use bash <script> <json-object>")
        script = _safe_regular_path(argv[1], (roots["tmp"],), ".sh")
        _json_object(argv[2], "remote script arguments")
        command = [_trusted_executable("bash"), script, argv[2]]
    else:
        if len(argv) != 6 or argv[0] != "python3" or argv[2] != "call-tool":
            raise RunnerRequestError("MCP requests do not match the fixed client contract")
        client = _safe_regular_path(argv[1], (roots["root"] / "lib",), ".py")
        if Path(client).name != "mcp_client.py":
            raise RunnerRequestError("MCP client path is not allowlisted")
        manifest = _safe_regular_path(argv[3], (roots["mcp"],), ".json")
        if SAFE_ID_PATTERN.fullmatch(argv[4]) is None or not argv[4]:
            raise RunnerRequestError("MCP tool name is invalid")
        arguments = _safe_regular_path(argv[5], (roots["tmp"],), ".json")
        command = [
            _trusted_executable("python3"),
            client,
            "call-tool",
            manifest,
            argv[4],
            arguments,
        ]
    if kind != "skill" and audit_snapshot is not None:
        raise RunnerRequestError("audit snapshots are only valid for Skill execution")
    return str(kind), command, timeout_sec, max_output, environment_overrides


def runner_environment() -> dict[str, str]:
    roots = _runtime_roots()
    environment = {
        "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "HOME": os.environ.get("HOME", "/nonexistent"),
        "USER": os.environ.get("USER", "linux-agent-runner"),
        "LOGNAME": os.environ.get("LOGNAME", "linux-agent-runner"),
        "LANG": os.environ.get("LANG", "C.UTF-8"),
        "LC_ALL": os.environ.get("LC_ALL", "C.UTF-8"),
        "LINUX_AGENT_ROOT": os.fspath(roots["root"]),
        "LINUX_AGENT_BUILTIN_SKILLS_DIR": os.fspath(roots["builtin_skills"]),
        "LINUX_AGENT_USER_SKILLS_DIR": os.fspath(roots["user_skills"]),
        "LINUX_AGENT_MCP_DIR": os.fspath(roots["mcp"]),
        "LINUX_AGENT_TMP_ROOT": os.fspath(roots["tmp"]),
        "LINUX_AGENT_EXECUTION_ISOLATION": "runner_uid",
    }
    return environment


def _drain(
    stream,
    stream_name: str,
    limit: int,
    consumer,
    total: list[int],
    overflow: threading.Event,
    transport_failed: threading.Event,
) -> None:
    delivered = 0
    try:
        while True:
            chunk = stream.read(STREAM_CHUNK_BYTES)
            if not chunk:
                break
            total[0] += len(chunk)
            remaining = max(0, limit - delivered)
            if remaining:
                retained_chunk = chunk[:remaining]
                try:
                    consumer(stream_name, retained_chunk)
                except (OSError, ProtocolError):
                    transport_failed.set()
                    break
                delivered += len(retained_chunk)
            if len(chunk) > remaining:
                overflow.set()
    finally:
        stream.close()


def _terminate_process_group(process: subprocess.Popen, grace: float = 2.0) -> int:
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        return process.wait(timeout=grace)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        return process.wait()


def execute(
    command: list[str],
    timeout_sec: int,
    max_output: int,
    environment_overrides: dict[str, str] | None = None,
    *,
    chunk_consumer=None,
    peer_disconnected=None,
) -> dict[str, object]:
    environment = runner_environment()
    if environment_overrides:
        environment.update(environment_overrides)
    process = subprocess.Popen(
        command,
        cwd=os.fspath(_runtime_roots()["root"]),
        env=environment,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    retained: dict[str, list[bytes]] = {"stdout": [], "stderr": []}

    def collect(stream_name: str, chunk: bytes) -> None:
        retained[stream_name].append(chunk)

    consumer = chunk_consumer or collect
    stdout_total = [0]
    stderr_total = [0]
    overflow = threading.Event()
    transport_failed = threading.Event()
    stdout_thread = threading.Thread(
        target=_drain,
        args=(
            process.stdout,
            "stdout",
            max_output,
            consumer,
            stdout_total,
            overflow,
            transport_failed,
        ),
        daemon=True,
    )
    stderr_thread = threading.Thread(
        target=_drain,
        args=(
            process.stderr,
            "stderr",
            max_output,
            consumer,
            stderr_total,
            overflow,
            transport_failed,
        ),
        daemon=True,
    )
    stdout_thread.start()
    stderr_thread.start()
    timed_out = False
    cancelled = False
    deadline = time.monotonic() + timeout_sec
    return_code = None
    while process.poll() is None:
        if overflow.is_set():
            return_code = _terminate_process_group(process)
            break
        if transport_failed.is_set():
            cancelled = True
            return_code = _terminate_process_group(process)
            break
        if peer_disconnected is not None and peer_disconnected():
            cancelled = True
            return_code = _terminate_process_group(process)
            break
        if time.monotonic() >= deadline:
            timed_out = True
            return_code = _terminate_process_group(process)
            break
        time.sleep(0.02)
    if return_code is None:
        return_code = process.wait()
    # A shell may exit after leaving descendants in its process group. Only
    # signal the group when a pipe is still held open; once both readers have
    # observed EOF there is no descendant to reap, and probing an already
    # reaped PID would create an unnecessary PID/PGID reuse race.
    if stdout_thread.is_alive() or stderr_thread.is_alive():
        _terminate_process_group(process)
    stdout_thread.join(timeout=2)
    stderr_thread.join(timeout=2)
    if stdout_thread.is_alive() or stderr_thread.is_alive():
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        stdout_thread.join(timeout=5)
        stderr_thread.join(timeout=5)
    if stdout_thread.is_alive() or stderr_thread.is_alive():
        raise RunnerRequestError("runner could not reap command output pipes")
    if return_code < 0:
        return_code = 128 + abs(return_code)
    output_capped = overflow.is_set()
    output_integrity_unknown = transport_failed.is_set()
    if output_integrity_unknown:
        status = "invalid_output"
        return_code = 125
    elif output_capped:
        status = "output_limit_exceeded"
        return_code = 125
    elif cancelled:
        status = "cancelled"
        return_code = 125
    elif timed_out:
        status = "timed_out"
        return_code = 124
    else:
        status = "executed"
    return {
        "ok": return_code == 0 and status == "executed",
        "status": status,
        **({"code": status} if status in {"output_limit_exceeded", "invalid_output"} else {}),
        "exit_code": min(255, int(return_code)),
        "timed_out": timed_out,
        "cancelled": cancelled,
        "stdout": b"".join(retained["stdout"]).decode("utf-8", errors="replace"),
        "stderr": b"".join(retained["stderr"]).decode("utf-8", errors="replace"),
        "stdout_truncated_bytes": max(0, stdout_total[0] - max_output),
        "stderr_truncated_bytes": max(0, stderr_total[0] - max_output),
        "output_capped": output_capped,
        "output_integrity_unknown": output_integrity_unknown,
        "isolation": "runner_uid",
    }


class StreamFrameWriter:
    def __init__(self, connection: socket.socket, request_id: str):
        self.connection = connection
        self.request_id = request_id
        self.sequence = 0
        self.lock = threading.Lock()

    def _send(self, frame: dict[str, object]) -> None:
        with self.lock:
            envelope = {
                "protocol_version": PROTOCOL_VERSION,
                "request_id": self.request_id,
                "sequence": self.sequence,
                **frame,
            }
            send_stream_frame(self.connection, envelope)
            self.sequence += 1

    def write(self, stream_name: str, chunk: bytes) -> None:
        self._send(
            {
                "frame": stream_name,
                "data": base64.b64encode(chunk).decode("ascii"),
            }
        )

    def finish(self, response: dict[str, object]) -> None:
        self._send({"frame": "result", "result": response})


def _peer_disconnected(connection: socket.socket) -> bool:
    try:
        readable, _writable, exceptional = select.select([connection], [], [connection], 0)
        if exceptional:
            return True
        if not readable:
            return False
        # Execute is a one-request connection. Any further readable state is
        # either EOF or an unexpected second request, and both cancel the
        # process instead of permitting an ambiguous control channel.
        connection.recv(1, socket.MSG_PEEK)
        return True
    except (OSError, ValueError):
        return True


def handle_connection(
    connection: socket.socket,
    expected_uid: int,
    execution_slots: threading.BoundedSemaphore | None = None,
) -> None:
    request_id = ""
    operation = ""
    stream_writer = None
    try:
        peer_pid, peer_uid, _peer_gid = require_peer_uid(connection, expected_uid)
        request = receive_json_frame(connection)
        operation, params, _summary, request_id = validate_request(request)
        if operation == "ping":
            if params:
                raise RunnerRequestError("runner ping does not accept params")
            response = {"ok": True, "status": "ready", "isolation": "runner_uid"}
        elif operation == "execute":
            stream_writer = StreamFrameWriter(connection, request_id)
            if execution_slots is not None and not execution_slots.acquire(blocking=False):
                response = {
                    "ok": False,
                    "status": "runner_busy",
                    "code": "runner_unavailable",
                    "error": "runner concurrency limit is reached",
                    "exit_code": 125,
                }
            else:
                try:
                    with runtime_shared_lock():
                        (
                            kind,
                            command,
                            timeout_sec,
                            max_output,
                            environment_overrides,
                        ) = validate_execution(params)
                        # The listener timeout only bounds request framing. A
                        # completed command may produce a large response, so use
                        # a separate bounded write timeout rather than inheriting
                        # the ten-second request timeout.
                        connection.settimeout(RESPONSE_SEND_TIMEOUT_SEC)
                        response = execute(
                            command,
                            timeout_sec,
                            max_output,
                            environment_overrides,
                            chunk_consumer=stream_writer.write,
                            peer_disconnected=lambda: _peer_disconnected(connection),
                        )
                        response["kind"] = kind
                finally:
                    if execution_slots is not None:
                        execution_slots.release()
        else:
            raise RunnerRequestError("unsupported runner operation")
        response.update(
            {
                "protocol_version": PROTOCOL_VERSION,
                "request_id": request_id,
                "peer_pid": peer_pid,
                "peer_uid": peer_uid,
            }
        )
    except ProtocolError as exc:
        response = {
            "ok": False,
            "status": "runner_rejected",
            "code": "runner_rejected",
            "error": str(exc),
            "exit_code": 126,
            "protocol_version": PROTOCOL_VERSION,
            "request_id": request_id,
        }
    except Exception as exc:
        response = {
            "ok": False,
            "status": "runner_failed",
            "code": "runner_unavailable",
            "error": str(exc),
            "exit_code": 125,
            "protocol_version": PROTOCOL_VERSION,
            "request_id": request_id,
        }
    try:
        connection.settimeout(RESPONSE_SEND_TIMEOUT_SEC)
    except (AttributeError, OSError):
        pass
    try:
        if operation == "execute" and stream_writer is not None:
            stream_writer.finish(response)
        else:
            send_json(connection, response)
    except (BrokenPipeError, ConnectionResetError, OSError, ProtocolError):
        # The execute path already bound the child process to peer liveness.
        # Once the peer is gone there is no response consumer to notify.
        pass


def serve() -> int:
    expected_uid = allowed_peer_uid("linux-agent")
    listener = systemd_listener()
    try:
        max_concurrent = int(
            os.environ.get("LINUX_AGENT_RUNNER_MAX_CONCURRENT", str(DEFAULT_MAX_CONCURRENT))
        )
    except ValueError as exc:
        raise RuntimeError("LINUX_AGENT_RUNNER_MAX_CONCURRENT is invalid") from exc
    if not 1 <= max_concurrent <= 64:
        raise RuntimeError("LINUX_AGENT_RUNNER_MAX_CONCURRENT is outside 1..64")
    execution_slots = threading.BoundedSemaphore(max_concurrent)
    while True:
        connection, _ = listener.accept()
        connection.settimeout(10.0)

        def serve_connection(client: socket.socket) -> None:
            with client:
                handle_connection(client, expected_uid, execution_slots)

        threading.Thread(target=serve_connection, args=(connection,), daemon=True).start()


def _strict_frame(raw: bytes) -> dict[str, object]:
    try:
        value = json.loads(
            raw.decode("utf-8"),
            parse_constant=_reject_json_constant,
            object_pairs_hook=_reject_duplicate_keys,
        )
    except (UnicodeDecodeError, json.JSONDecodeError, RunnerRequestError) as exc:
        raise ProtocolError("runner returned an invalid UTF-8 JSON frame") from exc
    if not isinstance(value, dict):
        raise ProtocolError("runner stream frame must be an object")
    return value


def _write_all(descriptor: int, payload: bytes) -> None:
    offset = 0
    while offset < len(payload):
        written = os.write(descriptor, payload[offset:])
        if written <= 0:
            raise OSError("runner output write made no forward progress")
        offset += written


def _stream_request(
    socket_path: str,
    request_payload: dict[str, object],
    timeout: float,
    max_output: int,
) -> dict[str, object]:
    encoded = canonical_json(request_payload) + b"\n"
    if len(encoded) > MAX_REQUEST_BYTES:
        raise ProtocolError("request exceeds the protocol byte limit")
    expected_request_id = request_payload.get("request_id")
    buffer = bytearray()
    expected_sequence = 0
    totals = {"stdout": 0, "stderr": 0}
    final = None
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(timeout)
        connection.connect(socket_path)
        connection.sendall(encoded)
        while final is None:
            chunk = connection.recv(65_536)
            if not chunk:
                raise ProtocolError("runner stream ended before its result frame")
            buffer.extend(chunk)
            if len(buffer) > MAX_STREAM_FRAME_BYTES and b"\n" not in buffer:
                raise ProtocolError("runner stream frame exceeds the protocol byte limit")
            while b"\n" in buffer:
                line, separator, remainder = bytes(buffer).partition(b"\n")
                del separator
                buffer[:] = remainder
                if not line or len(line) + 1 > MAX_STREAM_FRAME_BYTES:
                    raise ProtocolError("runner stream frame is empty or oversized")
                frame = _strict_frame(line)
                if frame.get("protocol_version") != PROTOCOL_VERSION:
                    raise ProtocolError("runner stream protocol_version does not match")
                if frame.get("request_id") != expected_request_id:
                    raise ProtocolError("runner stream request_id does not match")
                # A pre-stream rejection uses the ordinary helper envelope.
                if "frame" not in frame:
                    if not isinstance(frame.get("ok"), bool) or not isinstance(
                        frame.get("status"), str
                    ):
                        raise ProtocolError("runner rejection response is invalid")
                    final = frame
                    break
                if set(frame) not in (
                    {"protocol_version", "request_id", "sequence", "frame", "data"},
                    {"protocol_version", "request_id", "sequence", "frame", "result"},
                ):
                    raise ProtocolError("runner stream frame fields do not match the schema")
                if frame.get("sequence") != expected_sequence:
                    raise ProtocolError("runner stream sequence is invalid")
                expected_sequence += 1
                frame_type = frame.get("frame")
                if frame_type in {"stdout", "stderr"}:
                    data = frame.get("data")
                    if not isinstance(data, str):
                        raise ProtocolError("runner stream data must be base64 text")
                    try:
                        decoded = base64.b64decode(data, validate=True)
                    except (ValueError, base64.binascii.Error) as exc:
                        raise ProtocolError("runner stream data is not valid base64") from exc
                    if len(decoded) > STREAM_CHUNK_BYTES:
                        raise ProtocolError("runner stream decoded chunk is oversized")
                    totals[frame_type] += len(decoded)
                    if totals[frame_type] > max_output:
                        raise ProtocolError("runner stream exceeded the requested output limit")
                    _write_all(
                        sys.stdout.fileno() if frame_type == "stdout" else sys.stderr.fileno(),
                        decoded,
                    )
                elif frame_type == "result":
                    result = frame.get("result")
                    if not isinstance(result, dict):
                        raise ProtocolError("runner result frame must contain an object")
                    if not isinstance(result.get("ok"), bool) or not isinstance(
                        result.get("status"), str
                    ):
                        raise ProtocolError("runner result frame is invalid")
                    if result.get("protocol_version") != PROTOCOL_VERSION:
                        raise ProtocolError("runner result protocol_version does not match")
                    if result.get("request_id") != expected_request_id:
                        raise ProtocolError("runner result request_id does not match")
                    final = result
                    if buffer:
                        raise ProtocolError("runner sent data after its final result")
                    break
                else:
                    raise ProtocolError("runner stream frame type is unsupported")
        trailing = connection.recv(1)
        if trailing:
            raise ProtocolError("runner sent data after its final result")
    if final is None:
        raise ProtocolError("runner did not return a final result")
    return final


def _metadata_payload(response: dict[str, object]) -> dict[str, object]:
    fields = {
        "protocol_version",
        "request_id",
        "ok",
        "status",
        "code",
        "exit_code",
        "timed_out",
        "cancelled",
        "output_capped",
        "output_integrity_unknown",
        "stdout_truncated_bytes",
        "stderr_truncated_bytes",
    }
    return {key: response[key] for key in fields if key in response}


def _write_metadata(path: str, response: dict[str, object]) -> None:
    if not path:
        return
    target = Path(path)
    if not target.is_absolute() or target.is_symlink():
        raise ProtocolError("runner metadata path must be an absolute regular file")
    metadata = target.stat()
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.geteuid():
        raise ProtocolError("runner metadata file ownership is invalid")
    if metadata.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        raise ProtocolError("runner metadata file must not be group/world writable")
    descriptor = os.open(
        target,
        os.O_WRONLY | os.O_TRUNC | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
    )
    try:
        payload = canonical_json(_metadata_payload(response)) + b"\n"
        _write_all(descriptor, payload)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def request(
    socket_path: str,
    kind: str,
    argv: list[str],
    *,
    audit_snapshot: str = "",
    audit_snapshot_session: str = "",
    metadata_file: str = "",
) -> int:
    timeout_sec = int(os.environ.get("LINUX_AGENT_EXECUTION_TIMEOUT_SEC", "300"))
    max_output = int(os.environ.get("LINUX_AGENT_EXECUTION_MAX_OUTPUT_BYTES", "1048576"))
    params = {
        "kind": kind,
        "argv": argv,
        "timeout_sec": timeout_sec,
        "max_output_bytes": max_output,
    }
    if audit_snapshot or audit_snapshot_session:
        params["audit_snapshot"] = audit_snapshot
        params["audit_snapshot_session"] = audit_snapshot_session
    payload = build_request(
        "execute",
        params,
        summary=f"Execute {kind} in the dedicated runner",
    )
    try:
        response = _stream_request(
            socket_path,
            payload,
            timeout=timeout_sec + 10,
            max_output=max_output,
        )
    except (OSError, ProtocolError) as exc:
        response = {
            "protocol_version": PROTOCOL_VERSION,
            "request_id": payload.get("request_id", ""),
            "ok": False,
            "status": "invalid_output",
            "code": "runner_unavailable",
            "exit_code": 125,
            "output_integrity_unknown": True,
        }
        try:
            _write_metadata(metadata_file, response)
        except (OSError, ProtocolError):
            pass
        print(f"runner request failed: {exc}", file=sys.stderr)
        return 125
    try:
        _write_metadata(metadata_file, response)
    except (OSError, ProtocolError) as exc:
        print(f"runner metadata failed: {exc}", file=sys.stderr)
        return 125
    if not response.get("ok") and response.get("error"):
        print(str(response["error"]), file=sys.stderr)
    exit_code = response.get("exit_code", 0 if response.get("ok") else 125)
    if isinstance(exit_code, bool) or not isinstance(exit_code, int):
        return 125
    return max(0, min(255, exit_code))


def ping(socket_path: str) -> int:
    try:
        response = client_request(
            socket_path,
            build_request("ping", {}, summary="Check runner readiness"),
            timeout=5,
        )
    except (OSError, ProtocolError) as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print(json.dumps(response, ensure_ascii=True, separators=(",", ":")))
    return 0 if response.get("ok") else 1


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("serve")
    request_parser = subparsers.add_parser("request")
    request_parser.add_argument("--socket", default=os.environ.get("LINUX_AGENT_RUNNER_SOCKET", DEFAULT_SOCKET))
    request_parser.add_argument("--kind", choices=sorted(EXECUTION_KINDS), required=True)
    request_parser.add_argument("--audit-snapshot", default="")
    request_parser.add_argument("--audit-snapshot-session", default="")
    request_parser.add_argument("--metadata-file", default="")
    request_parser.add_argument("argv", nargs=argparse.REMAINDER)
    ping_parser = subparsers.add_parser("ping")
    ping_parser.add_argument("--socket", default=os.environ.get("LINUX_AGENT_RUNNER_SOCKET", DEFAULT_SOCKET))
    args = parser.parse_args()
    if args.command == "serve":
        return serve()
    if args.command == "ping":
        return ping(args.socket)
    argv = list(args.argv)
    if argv and argv[0] == "--":
        argv.pop(0)
    return request(
        args.socket,
        args.kind,
        argv,
        audit_snapshot=args.audit_snapshot,
        audit_snapshot_session=args.audit_snapshot_session,
        metadata_file=args.metadata_file,
    )


if __name__ == "__main__":
    raise SystemExit(main())
