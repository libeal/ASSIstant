#!/usr/bin/env python3
"""Privileged service and systemd handlers owned by ops-change."""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
import re
import stat
import subprocess
import tempfile
import time
from contextlib import contextmanager
from pathlib import Path

from ops_change import (
    OpsChangeError,
    dropin_path,
    dropin_preflight,
    normalize_resources,
    normalize_unit,
    render_dropin,
    service_preflight,
)


HOST_OPS_POLICY_PATH = Path(
    os.environ.get(
        "LINUX_AGENT_HOST_OPS_POLICY_PATH",
        "/etc/linux-agent/host-ops-policy.json",
    )
)
TOOL_PATHS = {
    "systemctl": ("/usr/bin/systemctl", "/bin/systemctl"),
}


class HostHelperError(RuntimeError):
    code = "helper_rejected"


class HostOperationError(HostHelperError):
    def __init__(self, message: str, code: str):
        super().__init__(message)
        self.code = code


def _reject_duplicate_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise HostHelperError(f"duplicate host policy key: {key}")
        result[key] = value
    return result


def _host_ops_policy() -> dict[str, frozenset[str]]:
    path = HOST_OPS_POLICY_PATH
    try:
        metadata = path.lstat()
    except OSError as exc:
        raise HostOperationError("host operations policy is unavailable", "host_operation_not_allowed") from exc
    if (
        not stat.S_ISREG(metadata.st_mode)
        or stat.S_ISLNK(metadata.st_mode)
        or metadata.st_uid != 0
        or metadata.st_gid != 0
        or stat.S_IMODE(metadata.st_mode) != 0o600
        or metadata.st_size > 65_536
    ):
        raise HostOperationError("host operations policy metadata is invalid", "host_operation_not_allowed")
    try:
        policy = json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=lambda value: (_ for _ in ()).throw(
                ValueError(f"invalid JSON constant: {value}")
            ),
        )
    except (
        OSError,
        UnicodeError,
        ValueError,
        json.JSONDecodeError,
        HostHelperError,
    ) as exc:
        raise HostOperationError("host operations policy is invalid", "host_operation_not_allowed") from exc
    if not isinstance(policy, dict) or set(policy) != {
        "schema_version",
        "service_restart_units",
        "systemd_dropin_units",
    }:
        raise HostOperationError("host operations policy schema is invalid", "host_operation_not_allowed")
    if type(policy.get("schema_version")) is not int or policy["schema_version"] != 1:
        raise HostOperationError("host operations policy version is unsupported", "host_operation_not_allowed")
    normalized: dict[str, frozenset[str]] = {}
    for name in ("service_restart_units", "systemd_dropin_units"):
        values = policy.get(name)
        if not isinstance(values, list) or len(values) > 256:
            raise HostOperationError(f"{name} must be a bounded array", "host_operation_not_allowed")
        units = []
        for value in values:
            try:
                unit = normalize_unit(value)
            except OpsChangeError as exc:
                raise HostOperationError(f"{name} contains an invalid unit", "host_operation_not_allowed") from exc
            if unit == "systemd.service" or unit.startswith("linux-agent-"):
                raise HostOperationError(f"{name} contains a protected unit", "host_operation_not_allowed")
            units.append(unit)
        if len(units) != len(set(units)):
            raise HostOperationError(f"{name} contains duplicate units", "host_operation_not_allowed")
        normalized[name] = frozenset(units)
    return normalized


def _trusted_tool(name: str) -> str:
    for candidate in TOOL_PATHS.get(name, ()):
        path = Path(candidate)
        try:
            resolved = path.resolve(strict=True)
            metadata = resolved.stat()
        except OSError:
            continue
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != 0:
            continue
        if metadata.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
            continue
        if os.access(resolved, os.X_OK):
            return os.fspath(resolved)
    raise HostHelperError(f"trusted {name} executable is unavailable")

def _run_fixed(command: list[str]) -> dict[str, object]:
    environment = {
        "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "HOME": "/root",
        "LANG": "C.UTF-8",
    }
    try:
        completed = subprocess.run(
            command,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            timeout=20,
            env=environment,
            check=False,
        )
    except subprocess.TimeoutExpired as exc:
        raise HostHelperError("host operation timed out") from exc
    return {
        "ok": completed.returncode == 0,
        "exit_code": completed.returncode,
        "stdout": completed.stdout[:65536].decode("utf-8", errors="replace"),
        "stderr": completed.stderr[:65536].decode("utf-8", errors="replace"),
    }


def _fsync_directory(directory: Path) -> None:
    descriptor = os.open(os.fspath(directory), os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _sha256(value: object, name: str) -> str:
    if not isinstance(value, str) or re.fullmatch(r"[0-9a-f]{64}", value) is None:
        raise HostHelperError(f"{name} must be a SHA-256 digest")
    return value


def _systemd_unit_allowed(unit: str, policy_key: str) -> None:
    if unit == "systemd.service" or unit.startswith("linux-agent-"):
        raise HostOperationError("protected service unit cannot be changed", "host_operation_not_allowed")
    if unit not in _host_ops_policy()[policy_key]:
        raise HostOperationError("service unit is not allowlisted", "host_operation_not_allowed")


def apply_service_restart(params: dict[str, object]) -> dict[str, object]:
    if set(params) != {"unit", "apply", "confirm", "preflight_sha256"}:
        raise HostHelperError("service.restart params do not match the fixed schema")
    if params.get("apply") is not True or params.get("confirm") != "RESTART_SERVICE":
        raise HostHelperError("service restart requires apply and the fixed confirmation token")
    try:
        unit = normalize_unit(params.get("unit"))
    except OpsChangeError as exc:
        raise HostHelperError(str(exc)) from exc
    _systemd_unit_allowed(unit, "service_restart_units")
    expected = _sha256(params.get("preflight_sha256"), "preflight_sha256")
    try:
        state, actual = service_preflight(unit)
    except OpsChangeError as exc:
        raise HostHelperError(str(exc)) from exc
    if state.get("LoadState") != "loaded":
        raise HostHelperError("service unit is not loaded")
    if actual != expected:
        raise HostOperationError("service state changed after the reviewed plan", "target_changed")
    result = _run_fixed([_trusted_tool("systemctl"), "restart", unit])
    return {
        "ok": bool(result["ok"]),
        "status": "restarted" if result["ok"] else "restart_failed",
        "code": None if result["ok"] else "helper_failed",
        "operation": "service.restart",
        "unit": unit,
        "command_result": result,
    }


def _systemd_directory() -> Path:
    directory = Path("/etc/systemd/system")
    current = Path("/")
    for component in directory.parts[1:]:
        current /= component
        try:
            metadata = current.lstat()
        except OSError as exc:
            raise HostHelperError("systemd configuration directory is unavailable") from exc
        if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
            raise HostHelperError("systemd configuration path must not contain symbolic links")
    return directory


@contextmanager
def _systemd_mutation_lock():
    directory = _systemd_directory()
    lock_path = directory / ".linux-agent-systemd.lock"
    flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(os.fspath(lock_path), flags, 0o600)
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise HostHelperError("systemd mutation lock must be a regular file")
        os.fchmod(descriptor, 0o600)
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield
    finally:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
        finally:
            os.close(descriptor)


def _write_descriptor(descriptor: int, payload: bytes) -> None:
    offset = 0
    while offset < len(payload):
        written = os.write(descriptor, payload[offset:])
        if written <= 0:
            raise OSError("write made no forward progress")
        offset += written
    os.fsync(descriptor)


def _validate_dropin_directory(directory: Path) -> None:
    metadata = directory.lstat()
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or stat.S_ISLNK(metadata.st_mode)
        or metadata.st_uid != 0
        or metadata.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
    ):
        raise HostHelperError("systemd drop-in directory is not root-managed")


def _restore_dropin(
    target: Path,
    old_content: bytes | None,
    old_metadata: os.stat_result | None,
    directory: Path,
) -> None:
    if old_content is None:
        try:
            target.unlink()
        except FileNotFoundError:
            pass
        _fsync_directory(directory)
        return
    descriptor, raw_path = tempfile.mkstemp(prefix=".90-linux-agent.rollback.", dir=directory)
    temporary = Path(raw_path)
    try:
        if old_metadata is None:
            raise HostHelperError("drop-in rollback metadata is unavailable")
        os.fchmod(descriptor, stat.S_IMODE(old_metadata.st_mode))
        os.fchown(descriptor, old_metadata.st_uid, old_metadata.st_gid)
        _write_descriptor(descriptor, old_content)
        os.close(descriptor)
        os.replace(temporary, target)
        _fsync_directory(directory)
    finally:
        try:
            os.close(descriptor)
        except OSError:
            pass
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def _apply_dropin_locked(
    unit: str,
    resources: dict[str, int],
    expected: str,
) -> dict[str, object]:
    target = dropin_path(unit)
    systemd_root = _systemd_directory()
    directory = target.parent
    if directory.parent != systemd_root or directory.name != f"{unit}.d":
        raise HostHelperError("systemd drop-in target escaped its fixed directory")
    if directory.is_symlink():
        raise HostHelperError("systemd drop-in directory must not be a symbolic link")
    directory.mkdir(mode=0o755, exist_ok=True)
    _validate_dropin_directory(directory)
    if target.is_symlink():
        raise HostHelperError("systemd drop-in target must not be a symbolic link")
    try:
        preflight, actual = dropin_preflight(unit)
    except OpsChangeError as exc:
        raise HostHelperError(str(exc)) from exc
    if actual != expected:
        raise HostOperationError("drop-in target changed after the reviewed plan", "target_changed")
    state = preflight.get("state")
    if not isinstance(state, dict) or state.get("LoadState") != "loaded":
        raise HostHelperError("service unit is not loaded")
    try:
        old_content = target.read_bytes()
        old_metadata = target.stat()
    except FileNotFoundError:
        old_content = None
        old_metadata = None
    current_sha = hashlib.sha256(old_content).hexdigest() if old_content is not None else None
    if current_sha != preflight.get("current_sha256"):
        raise HostOperationError("drop-in target changed after preflight", "target_changed")
    payload = render_dropin(resources)
    if old_content == payload:
        return {
            "ok": True,
            "status": "unchanged",
            "operation": "systemd.dropin.apply",
            "unit": unit,
            "target": os.fspath(target),
            "backup_path": None,
            "restart_performed": False,
        }
    descriptor, raw_path = tempfile.mkstemp(prefix=".90-linux-agent.", dir=directory)
    temporary = Path(raw_path)
    backup: Path | None = None
    replaced = False
    try:
        os.fchmod(descriptor, 0o644)
        _write_descriptor(descriptor, payload)
        os.close(descriptor)
        _preflight, actual = dropin_preflight(unit)
        if actual != expected:
            raise HostOperationError("drop-in target changed before backup", "target_changed")
        if old_content is not None:
            backup = directory / f"90-linux-agent-resources.conf.bak.{time.time_ns()}"
            flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
            backup_descriptor = os.open(os.fspath(backup), flags, 0o600)
            try:
                _write_descriptor(backup_descriptor, old_content)
            finally:
                os.close(backup_descriptor)
            _fsync_directory(directory)
        _preflight, actual = dropin_preflight(unit)
        if actual != expected:
            raise HostOperationError("drop-in target changed before replace", "target_changed")
        os.replace(temporary, target)
        replaced = True
        _fsync_directory(directory)
        reload_result = _run_fixed([_trusted_tool("systemctl"), "daemon-reload"])
        if not reload_result["ok"]:
            raise HostHelperError("systemd daemon-reload failed after persistence")
    except Exception as exc:
        if replaced:
            try:
                _restore_dropin(target, old_content, old_metadata, directory)
                rollback_reload = _run_fixed([_trusted_tool("systemctl"), "daemon-reload"])
                if not rollback_reload["ok"]:
                    raise OSError("rollback daemon-reload failed")
            except Exception as rollback_exc:
                raise HostHelperError(
                    "drop-in apply failed and rollback could not be confirmed; "
                    f"backup={backup}: {rollback_exc}"
                ) from exc
            raise HostHelperError("drop-in apply failed; previous state was restored") from exc
        if backup is not None:
            try:
                backup.unlink()
            except OSError:
                pass
        raise
    finally:
        try:
            os.close(descriptor)
        except OSError:
            pass
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass
    return {
        "ok": True,
        "status": "updated",
        "operation": "systemd.dropin.apply",
        "unit": unit,
        "target": os.fspath(target),
        "backup_path": os.fspath(backup) if backup else None,
        "resources": resources,
        "restart_performed": False,
    }


def apply_systemd_dropin(params: dict[str, object]) -> dict[str, object]:
    if set(params) != {"unit", "resources", "apply", "preflight_sha256"}:
        raise HostHelperError("systemd.dropin.apply params do not match the fixed schema")
    if params.get("apply") is not True:
        raise HostHelperError("systemd drop-in requires apply=true")
    try:
        unit = normalize_unit(params.get("unit"))
        resources = normalize_resources(params.get("resources"))
    except OpsChangeError as exc:
        raise HostHelperError(str(exc)) from exc
    _systemd_unit_allowed(unit, "systemd_dropin_units")
    expected = _sha256(params.get("preflight_sha256"), "preflight_sha256")
    with _systemd_mutation_lock():
        return _apply_dropin_locked(unit, resources, expected)



_HANDLERS = {
    "service.restart": apply_service_restart,
    "systemd.dropin.apply": apply_systemd_dropin,
}


def dispatch(operation: str, params: dict[str, object]) -> dict[str, object]:
    try:
        handler = _HANDLERS[operation]
    except KeyError as exc:
        raise HostHelperError("unsupported ops-change host operation") from exc
    return handler(params)
