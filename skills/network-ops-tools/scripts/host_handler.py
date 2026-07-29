#!/usr/bin/env python3
"""Privileged firewall and hosts handlers owned by network-ops-tools."""

from __future__ import annotations

import fcntl
import hashlib
import ipaddress
import os
import re
import shutil
import stat
import subprocess
import tempfile
from contextlib import contextmanager
from pathlib import Path


HOSTS_PATH = Path("/etc/hosts")
HOSTNAME_PATTERN = re.compile(
    r"^(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)(?:\.(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?))*$"
)
TOOL_PATHS = {
    "ufw": ("/usr/sbin/ufw", "/usr/bin/ufw"),
    "firewall-cmd": ("/usr/bin/firewall-cmd", "/usr/sbin/firewall-cmd"),
}


class HostHelperError(RuntimeError):
    code = "helper_rejected"


class HostOperationError(HostHelperError):
    def __init__(self, message: str, code: str):
        super().__init__(message)
        self.code = code


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


def _firewall_params(
    params: dict[str, object],
) -> tuple[str, list[str], list[str] | None, dict[str, object]]:
    if set(params) != {"backend", "decision", "protocol", "port", "source"}:
        raise HostHelperError("firewall.apply params do not match the fixed schema")
    backend = params.get("backend")
    decision = params.get("decision")
    protocol = params.get("protocol")
    port = params.get("port")
    source = params.get("source")
    if backend not in {"ufw", "firewalld"}:
        raise HostHelperError("firewall backend must be ufw or firewalld")
    if decision not in {"allow", "deny"} or protocol not in {"tcp", "udp"}:
        raise HostHelperError("firewall decision or protocol is invalid")
    if isinstance(port, bool) or not isinstance(port, int) or not 1 <= port <= 65535:
        raise HostHelperError("firewall port is invalid")
    if not isinstance(source, str):
        raise HostHelperError("firewall source is invalid")
    if source.lower() == "any":
        normalized_source = "any"
        network = None
    else:
        try:
            network = ipaddress.ip_network(source, strict=False)
        except ValueError as exc:
            raise HostHelperError("firewall source must be an IP address or CIDR") from exc
        normalized_source = str(network)

    normalized = {
        "backend": backend,
        "decision": decision,
        "protocol": protocol,
        "port": port,
        "source": normalized_source,
    }
    if backend == "ufw":
        command = [
            _trusted_tool("ufw"),
            decision,
            "proto",
            protocol,
            "from",
            normalized_source,
            "to",
            "any",
            "port",
            str(port),
        ]
        return backend, command, None, normalized

    family = f' family="ipv{network.version}"' if network else ""
    source_clause = f' source address="{normalized_source}"' if network else ""
    action = "accept" if decision == "allow" else "drop"
    rich_rule = (
        f'rule{family}{source_clause} port port="{port}" protocol="{protocol}" {action}'
    )
    tool = _trusted_tool("firewall-cmd")
    return (
        backend,
        [tool, "--permanent", "--add-rich-rule", rich_rule],
        [tool, "--reload"],
        normalized,
    )


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


def apply_firewall(params: dict[str, object]) -> dict[str, object]:
    backend, command, reload_command, normalized = _firewall_params(params)
    result = _run_fixed(command)
    reload_result = None
    if result["ok"] and reload_command is not None:
        reload_result = _run_fixed(reload_command)
    ok = result["ok"] and (reload_result is None or reload_result["ok"])
    return {
        "ok": ok,
        "status": "applied" if ok else "apply_failed",
        "operation": "firewall.apply",
        "backend": backend,
        "rule": normalized,
        "command_result": result,
        "reload_result": reload_result,
    }


def _validate_hostname(value: object) -> str:
    if not isinstance(value, str):
        raise HostHelperError("hostname must be a string")
    normalized = value.strip().lower()
    if HOSTNAME_PATTERN.fullmatch(normalized) is None:
        raise HostHelperError("hostname is invalid")
    return normalized


def _hosts_lines() -> tuple[bytes, list[str]]:
    if HOSTS_PATH.is_symlink() or not HOSTS_PATH.is_file():
        raise HostHelperError("/etc/hosts must be a regular non-symlink file")
    raw = HOSTS_PATH.read_bytes()
    if len(raw) > 2 * 1024 * 1024:
        raise HostHelperError("/etc/hosts exceeds the helper size limit")
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise HostHelperError("/etc/hosts must be UTF-8") from exc
    return raw, text.splitlines()


def _hosts_directory() -> Path:
    """Return the ordinary directory containing the configured hosts file."""
    directory = HOSTS_PATH.parent
    try:
        metadata = directory.lstat()
    except OSError as exc:
        raise HostHelperError("hosts parent directory is unavailable") from exc
    if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        raise HostHelperError("hosts parent directory must be a non-symlink directory")
    return directory


def _fsync_directory(directory: Path) -> None:
    descriptor = os.open(os.fspath(directory), os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _restore_hosts_backup(backup: Path, directory: Path) -> None:
    descriptor, raw_path = tempfile.mkstemp(
        prefix=".hosts.linux-agent.rollback.", dir=os.fspath(directory)
    )
    rollback = Path(raw_path)
    try:
        os.close(descriptor)
        shutil.copy2(backup, rollback)
        descriptor = os.open(os.fspath(rollback), os.O_RDONLY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        os.replace(rollback, HOSTS_PATH)
        _fsync_directory(directory)
    finally:
        try:
            os.close(descriptor)
        except OSError:
            pass
        try:
            rollback.unlink()
        except FileNotFoundError:
            pass


@contextmanager
def _hosts_mutation_lock():
    """Serialize helper writers for the one permitted hosts target."""

    directory = _hosts_directory()
    lock_path = directory / ".linux-agent-hosts.lock"
    flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(os.fspath(lock_path), flags, 0o600)
    except OSError as exc:
        raise HostHelperError("hosts mutation lock is unavailable") from exc
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise HostHelperError("hosts mutation lock must be a regular file")
        os.fchmod(descriptor, 0o600)
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield
    finally:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
        finally:
            os.close(descriptor)


def _write_hosts_locked(lines: list[str], expected_sha256: str | None = None) -> str:
    # The caller reviewed this exact bytestring.  Recheck immediately before
    # taking the backup and again after the copy so a concurrent writer cannot
    # be silently overwritten by the final rename.
    current_raw = HOSTS_PATH.read_bytes()
    if expected_sha256 and hashlib.sha256(current_raw).hexdigest() != expected_sha256:
        raise HostHelperError("/etc/hosts changed after the reviewed plan")
    metadata = HOSTS_PATH.stat()
    directory_path = _hosts_directory()
    descriptor, raw_path = tempfile.mkstemp(
        prefix=".hosts.linux-agent.", dir=os.fspath(directory_path)
    )
    temporary = Path(raw_path)
    backup = None
    replaced = False
    try:
        os.fchmod(descriptor, stat.S_IMODE(metadata.st_mode))
        payload = ("\n".join(lines) + "\n").encode("utf-8")
        offset = 0
        while offset < len(payload):
            written = os.write(descriptor, payload[offset:])
            if written <= 0:
                raise OSError("hosts write made no forward progress")
            offset += written
        os.fsync(descriptor)
        os.close(descriptor)
        os.chown(temporary, metadata.st_uid, metadata.st_gid)
        current_raw = HOSTS_PATH.read_bytes()
        if expected_sha256 and hashlib.sha256(current_raw).hexdigest() != expected_sha256:
            raise HostHelperError("/etc/hosts changed after the reviewed plan")
        backup_descriptor, backup_raw_path = tempfile.mkstemp(
            prefix="hosts.linux-agent.bak.", dir=os.fspath(directory_path)
        )
        os.close(backup_descriptor)
        backup = Path(backup_raw_path)
        shutil.copy2(HOSTS_PATH, backup)
        # Copying the backup is an observable window for a concurrent writer;
        # do one last digest check before replacing the target.
        current_raw = HOSTS_PATH.read_bytes()
        if expected_sha256 and hashlib.sha256(current_raw).hexdigest() != expected_sha256:
            raise HostHelperError("/etc/hosts changed after the reviewed plan")
        os.replace(temporary, HOSTS_PATH)
        replaced = True
        try:
            _fsync_directory(directory_path)
        except OSError as exc:
            try:
                _restore_hosts_backup(backup, directory_path)
            except OSError as rollback_exc:
                raise HostHelperError(
                    "hosts persistence failed and rollback could not be confirmed; "
                    f"recovery backup retained at {backup}: {rollback_exc}"
                ) from exc
            raise HostHelperError(
                "hosts persistence failed; previous content was restored and "
                f"the recovery backup was retained at {backup}"
            ) from exc
    except Exception:
        if backup is not None and not replaced:
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
    return os.fspath(backup)


def _write_hosts(lines: list[str], expected_sha256: str | None = None) -> str:
    # Keep the lock across the final digest check, backup, replace, and
    # directory fsync.  External writers still cannot be controlled, so the
    # expected digest checks remain deliberately in the locked implementation.
    with _hosts_mutation_lock():
        return _write_hosts_locked(lines, expected_sha256)


def apply_hosts(params: dict[str, object]) -> dict[str, object]:
    allowed = {"action", "ip", "hostnames", "hostname", "merge", "expected_sha256"}
    if set(params) != allowed:
        raise HostHelperError("hosts.apply params do not match the fixed schema")
    action = params.get("action")
    if action not in {"add", "remove"}:
        raise HostHelperError("hosts action must be add or remove")
    if not isinstance(params.get("merge"), bool):
        raise HostHelperError("hosts merge must be boolean")
    expected_sha = params.get("expected_sha256")
    if not isinstance(expected_sha, str) or re.fullmatch(r"[0-9a-f]{64}", expected_sha) is None:
        raise HostHelperError("hosts expected_sha256 is invalid")
    raw, lines = _hosts_lines()
    if hashlib.sha256(raw).hexdigest() != expected_sha:
        return {
            "ok": False,
            "status": "target_changed",
            "code": "target_changed",
            "error": "/etc/hosts changed after the reviewed plan",
        }

    if action == "add":
        try:
            address = str(ipaddress.ip_address(str(params.get("ip") or "")))
        except ValueError as exc:
            raise HostHelperError("hosts IP address is invalid") from exc
        raw_hostnames = params.get("hostnames")
        if not isinstance(raw_hostnames, list) or not 1 <= len(raw_hostnames) <= 32:
            raise HostHelperError("hosts hostnames must be a non-empty array")
        hostnames = [_validate_hostname(item) for item in raw_hostnames]
        line = f"{address}\t{' '.join(dict.fromkeys(hostnames))}"
        existing_index = next(
            (
                index
                for index, existing in enumerate(lines)
                if existing.split("#", 1)[0].split()[:1] == [address]
            ),
            None,
        )
        if params["merge"] and existing_index is not None:
            body = lines[existing_index].split("#", 1)[0].split()
            line = f"{address}\t{' '.join(dict.fromkeys(body[1:] + hostnames))}"
            lines[existing_index] = line
        elif not any(existing.split("#", 1)[0].split() == line.split() for existing in lines):
            lines.append(line)
        detail = {"action": action, "ip": address, "hostnames": hostnames, "line": line}
    else:
        raw_ip = str(params.get("ip") or "").strip()
        hostname_raw = str(params.get("hostname") or "").strip()
        if not raw_ip and not hostname_raw:
            raise HostHelperError("hosts remove requires hostname or ip")
        address = ""
        if raw_ip:
            try:
                address = str(ipaddress.ip_address(raw_ip))
            except ValueError as exc:
                raise HostHelperError("hosts IP address is invalid") from exc
        hostname = _validate_hostname(hostname_raw) if hostname_raw else ""
        kept = []
        removed = []
        for line in lines:
            body = line.split("#", 1)[0].split()
            matches = len(body) >= 2 and (
                (hostname and hostname in [item.lower() for item in body[1:]])
                or (address and body[0] == address)
            )
            (removed if matches else kept).append(line)
        lines = kept
        detail = {"action": action, "ip": address, "hostname": hostname, "removed": removed}

    backup = _write_hosts(lines, expected_sha)
    return {
        "ok": True,
        "status": "updated",
        "operation": "hosts.apply",
        "path": "/etc/hosts",
        "backup_path": backup,
        **detail,
    }



_HANDLERS = {
    "firewall.apply": apply_firewall,
    "hosts.apply": apply_hosts,
}


def dispatch(operation: str, params: dict[str, object]) -> dict[str, object]:
    try:
        handler = _HANDLERS[operation]
    except KeyError as exc:
        raise HostHelperError("unsupported network host operation") from exc
    return handler(params)
