#!/usr/bin/env python3
"""Root-owned policy writer with a deliberately tiny protocol surface."""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import stat
import subprocess
import tempfile
from contextlib import contextmanager
from pathlib import Path

from helper_protocol import (
    PROTOCOL_VERSION,
    ProtocolError,
    allowed_peer_uid,
    build_request,
    client_request,
    receive_json,
    require_peer_uid,
    runtime_shared_lock,
    send_json,
    systemd_listener,
    validate_request,
)


class PolicyHelperError(ProtocolError):
    pass


class SensitiveEditsDisabled(PolicyHelperError):
    """The administrator disabled Web-originated durable edits mid-request."""


POLICY_CLEANUP_WARNING = "policy_cleanup_pending"


def _paths() -> tuple[Path, Path, Path, Path]:
    def absolute_without_following_symlinks(value: str | os.PathLike[str]) -> Path:
        # abspath normalizes ``..`` lexically but, unlike Path.resolve(), does
        # not turn a user-controlled final symlink into an external target.
        return Path(os.path.abspath(os.fspath(value)))

    release = Path(
        os.environ.get("LINUX_AGENT_RELEASE_ROOT", "/opt/linux-agent/current")
    ).resolve()
    defaults = Path(
        os.environ.get("LINUX_AGENT_POLICY_DEFAULT_ROOT", release / "policies")
    ).resolve()
    overlay = absolute_without_following_symlinks(
        os.environ.get("LINUX_AGENT_POLICY_OVERLAY_ROOT", "/opt/linux-agent/data/policies")
    )
    config = absolute_without_following_symlinks(
        os.environ.get("LINUX_AGENT_CONFIG_PATH", "/opt/linux-agent/data/config/config.json")
    )
    return release, defaults, overlay, config


def _assert_no_symlink_components(path: Path, *, allow_missing_leaf: bool = True) -> None:
    """Reject a path whose existing components are symbolic links.

    The helper runs with elevated privileges, so resolving a Web-writable
    overlay/config symlink before checking it would turn an innocuous-looking
    path into an arbitrary root write.  Missing final components are allowed
    because the normal first-write path creates them below the trusted parent.
    """

    current = Path(path.root)
    for component in path.parts[1:]:
        current /= component
        try:
            metadata = current.lstat()
        except FileNotFoundError:
            if allow_missing_leaf:
                break
            raise PolicyHelperError(f"path component is missing: {current}")
        if stat.S_ISLNK(metadata.st_mode):
            raise PolicyHelperError(f"path component must not be a symlink: {current}")
        if current != path and not stat.S_ISDIR(metadata.st_mode):
            raise PolicyHelperError(f"path component is not a directory: {current}")


def _registered_path(raw: object) -> tuple[str, Path, Path]:
    if not isinstance(raw, str) or "\x00" in raw or "/" in raw or raw.startswith("."):
        raise PolicyHelperError("policy path must be a top-level JSON filename")
    if not raw.endswith(".json") or len(raw) > 128:
        raise PolicyHelperError("policy path is invalid")
    _release, defaults, overlay, _config = _paths()
    _assert_no_symlink_components(overlay)
    default = defaults / raw
    if default.is_symlink() or not default.is_file():
        raise PolicyHelperError("policy is not registered by the current release")
    if overlay.is_symlink():
        raise PolicyHelperError("policy overlay root must not be a symlink")
    if overlay.exists() and not overlay.is_dir():
        raise PolicyHelperError("policy overlay root is not a directory")
    target = overlay / raw
    if target.is_symlink() or (target.exists() and not target.is_file()):
        raise PolicyHelperError("policy overlay target is not a regular file")
    return raw, default, target


def _parse_object(raw: object, label: str) -> dict[str, object]:
    if not isinstance(raw, str) or not raw.strip():
        raise PolicyHelperError(f"{label} must be a non-empty JSON document")
    try:
        value = json.loads(
            raw,
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=_reject_json_constant,
        )
    except (json.JSONDecodeError, ValueError) as exc:
        raise PolicyHelperError(f"{label} is invalid JSON") from exc
    if not isinstance(value, dict):
        raise PolicyHelperError(f"{label} must be a JSON object")
    return value


def _reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _reject_json_constant(value):
    raise ValueError(f"non-finite JSON value is not allowed: {value}")


def _sensitive_edits_enabled(config: Path) -> bool:
    """Read the mutation gate from a stable, non-symlink file descriptor.

    The policy writer runs with elevated privileges while the configuration
    directory is writable by the Web service.  Opening by pathname after a
    separate ``is_symlink`` check leaves a small but real replacement window;
    ``O_NOFOLLOW`` plus ``fstat`` makes the final component identity explicit.
    """

    try:
        value = json.loads(
            _read_regular_text(config),
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=_reject_json_constant,
        )
    except (OSError, PolicyHelperError, UnicodeError, json.JSONDecodeError, ValueError):
        return False
    if not isinstance(value, dict):
        return False
    if "web" not in value:
        return True
    web = value.get("web")
    if not isinstance(web, dict):
        return False
    if "sensitive_edits_enabled" not in web:
        return True
    return web.get("sensitive_edits_enabled") is True


def _read_regular_text(path: Path) -> str:
    """Read a regular, non-symlink file without reopening it by pathname."""

    _assert_no_symlink_components(path.parent)
    descriptor = -1
    try:
        flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(os.fspath(path), flags)
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise PolicyHelperError("configuration path must be a regular file")
        with os.fdopen(descriptor, "r", encoding="utf-8") as handle:
            descriptor = -1
            return handle.read()
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def _require_sensitive_edits_enabled(config: Path) -> None:
    if not _sensitive_edits_enabled(config):
        raise SensitiveEditsDisabled("sensitive Web edits are disabled")


def _fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _atomic_write(
    target: Path,
    content: str,
    mode: int,
    *,
    pre_replace=None,
) -> str | None:
    _assert_no_symlink_components(target.parent)
    target.parent.mkdir(parents=True, exist_ok=True, mode=0o750)
    if target.parent.is_symlink() or target.is_symlink():
        raise PolicyHelperError("policy target must not be a symlink")
    ownership_source = target if target.exists() else target.parent
    ownership = ownership_source.stat(follow_symlinks=False)
    descriptor, raw_path = tempfile.mkstemp(
        prefix=f".{target.name}.", suffix=".tmp", dir=target.parent
    )
    temporary = Path(raw_path)
    backup = None
    replaced = False
    try:
        os.fchmod(descriptor, mode)
        payload = content.encode("utf-8")
        offset = 0
        while offset < len(payload):
            written = os.write(descriptor, payload[offset:])
            if written <= 0:
                raise OSError("policy write made no forward progress")
            offset += written
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = -1
        os.chown(temporary, ownership.st_uid, ownership.st_gid)

        # Keep a same-directory snapshot before the final gate/rename.  If a
        # chmod or directory fsync fails after replace, the old inode can be
        # restored without exposing a partially committed policy.
        if target.exists():
            backup, _ = _snapshot_file(target, target.parent)
            _fsync_directory(target.parent)
        elif target.is_symlink():
            raise PolicyHelperError("policy target appeared as a symlink")

        # The caller may re-read a policy switch here.  Keep this callback
        # immediately adjacent to os.replace so a disabled Web edit cannot
        # pass validation and then silently materialize afterward.
        if pre_replace is not None:
            pre_replace()
        os.replace(temporary, target)
        replaced = True
        try:
            os.chmod(target, mode)
            _fsync_file(target)
            _fsync_directory(target.parent)
        except Exception as exc:
            if backup is not None:
                try:
                    _restore_snapshot(backup, target, target.parent)
                except Exception as rollback_exc:
                    raise PolicyHelperError(
                        f"policy replacement failed and rollback failed; recovery backup: {backup}"
                    ) from rollback_exc
                try:
                    backup.unlink(missing_ok=True)
                except OSError:
                    # The restored target is already durable.  A retained
                    # owner-only backup is preferable to masking that result.
                    pass
            else:
                try:
                    target.unlink(missing_ok=True)
                    _fsync_directory(target.parent)
                except Exception as rollback_exc:
                    raise PolicyHelperError(
                        f"policy replacement failed and cleanup failed: {rollback_exc}"
                    ) from exc
            raise
        if backup is not None:
            try:
                backup.unlink(missing_ok=True)
                _fsync_directory(target.parent)
            except OSError:
                # The replacement has already been synced.  Cleanup failure
                # must not make callers believe the old policy is still live.
                return POLICY_CLEANUP_WARNING
        return None
    except Exception:
        if backup is not None and not replaced:
            try:
                backup.unlink(missing_ok=True)
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


def _snapshot_file(source: Path, directory: Path) -> tuple[Path, os.stat_result]:
    source_descriptor = os.open(
        os.fspath(source), os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    )
    backup_descriptor = -1
    backup = None
    try:
        metadata = os.fstat(source_descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise PolicyHelperError("policy target must be a regular file")
        backup_descriptor, raw_path = tempfile.mkstemp(
            prefix=f".{source.name}.previous.", suffix=".tmp", dir=directory
        )
        backup = Path(raw_path)
        os.fchmod(backup_descriptor, stat.S_IMODE(metadata.st_mode))
        while True:
            chunk = os.read(source_descriptor, 65536)
            if not chunk:
                break
            offset = 0
            while offset < len(chunk):
                written = os.write(backup_descriptor, chunk[offset:])
                if written <= 0:
                    raise OSError("policy backup write made no forward progress")
                offset += written
        os.fsync(backup_descriptor)
        os.close(backup_descriptor)
        backup_descriptor = -1
        os.chown(backup, metadata.st_uid, metadata.st_gid)
        current = os.stat(source, follow_symlinks=False)
        identity = (metadata.st_dev, metadata.st_ino, metadata.st_size, metadata.st_mtime_ns)
        current_identity = (
            current.st_dev,
            current.st_ino,
            current.st_size,
            current.st_mtime_ns,
        )
        if current_identity != identity:
            raise PolicyHelperError("policy target changed while preparing replacement")
        return backup, metadata
    except Exception:
        if backup_descriptor >= 0:
            os.close(backup_descriptor)
        if backup is not None:
            backup.unlink(missing_ok=True)
        raise
    finally:
        os.close(source_descriptor)


def _fsync_file(path: Path) -> None:
    descriptor = os.open(os.fspath(path), os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _restore_snapshot(backup: Path, target: Path, directory: Path) -> None:
    source_descriptor = os.open(
        os.fspath(backup), os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    )
    rollback_descriptor = -1
    rollback = None
    try:
        metadata = os.fstat(source_descriptor)
        rollback_descriptor, raw_path = tempfile.mkstemp(
            prefix=f".{target.name}.rollback.", suffix=".tmp", dir=directory
        )
        rollback = Path(raw_path)
        os.fchmod(rollback_descriptor, stat.S_IMODE(metadata.st_mode))
        while True:
            chunk = os.read(source_descriptor, 65536)
            if not chunk:
                break
            offset = 0
            while offset < len(chunk):
                written = os.write(rollback_descriptor, chunk[offset:])
                if written <= 0:
                    raise OSError("policy rollback write made no forward progress")
                offset += written
        os.fsync(rollback_descriptor)
        os.close(rollback_descriptor)
        rollback_descriptor = -1
        os.chown(rollback, metadata.st_uid, metadata.st_gid)
        os.replace(rollback, target)
        rollback = None
        os.chmod(target, stat.S_IMODE(metadata.st_mode))
        _fsync_file(target)
        _fsync_directory(directory)
    finally:
        if rollback_descriptor >= 0:
            os.close(rollback_descriptor)
        if rollback is not None:
            rollback.unlink(missing_ok=True)
        os.close(source_descriptor)


@contextmanager
def _config_lock(config: Path):
    """Use the same sidecar lock as Web ConfigStore for read-modify-write."""

    _assert_no_symlink_components(config.parent)
    lock_path = config.with_name(f".{config.name}.lock")
    descriptor = os.open(
        lock_path,
        os.O_RDWR | os.O_CREAT | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
        0o600,
    )
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise PolicyHelperError("configuration lock must be a regular file")
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        # Validate the target *after* taking the shared lock.  Web ConfigStore
        # uses the same lock, so this closes the check-then-replace window for
        # the read-modify-write transaction.
        config_descriptor = -1
        try:
            config_descriptor = os.open(
                os.fspath(config),
                os.O_RDONLY
                | getattr(os, "O_CLOEXEC", 0)
                | getattr(os, "O_NOFOLLOW", 0),
            )
            config_metadata = os.fstat(config_descriptor)
            if not stat.S_ISREG(config_metadata.st_mode):
                raise PolicyHelperError(
                    "configuration path must be a regular non-symlink file"
                )
            os.fchown(descriptor, config_metadata.st_uid, config_metadata.st_gid)
            os.fchmod(descriptor, 0o600)
        except PolicyHelperError:
            raise
        except OSError as exc:
            raise PolicyHelperError(
                "configuration path must be a regular non-symlink file"
            ) from exc
        finally:
            if config_descriptor >= 0:
                os.close(config_descriptor)
        yield
    finally:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
        finally:
            os.close(descriptor)


def _run_validator(path: str, content: str) -> None:
    release, _defaults, _overlay, _config = _paths()
    agent = release / "bin" / "agent"
    if not agent.is_file() or agent.is_symlink():
        raise PolicyHelperError("policy validator is unavailable")
    environment = {
        "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "HOME": "/root",
        "LANG": "C.UTF-8",
        "LINUX_AGENT_ROOT": os.fspath(release),
        "LINUX_AGENT_WEB": "0",
    }
    try:
        completed = subprocess.run(
            ["/bin/bash", os.fspath(agent), "api", "policy", "validate", json.dumps({"path": path, "content": content})],
            input="",
            text=True,
            capture_output=True,
            timeout=60,
            env=environment,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise PolicyHelperError("policy validator failed") from exc
    try:
        result = json.loads(completed.stdout.splitlines()[-1])
    except (IndexError, json.JSONDecodeError) as exc:
        raise PolicyHelperError("policy validator returned invalid output") from exc
    validation = result.get("validation") if isinstance(result, dict) else None
    if (
        completed.returncode != 0
        or result.get("ok") is not True
        or not isinstance(validation, dict)
        or validation.get("ok") is not True
    ):
        raise PolicyHelperError("policy validation failed")


def _write_policy(params: dict[str, object]) -> dict[str, object]:
    if set(params) != {"path", "content"}:
        raise PolicyHelperError("policy.write accepts only path and content")
    path, _default, target = _registered_path(params["path"])
    content = params["content"]
    if not isinstance(content, str) or len(content.encode("utf-8")) > 2 * 1024 * 1024:
        raise PolicyHelperError("policy content exceeds the size limit")
    parsed = _parse_object(content, "policy content")
    normalized = json.dumps(parsed, ensure_ascii=False, indent=2, allow_nan=False) + "\n"
    _release, _defaults, _overlay, config = _paths()
    if not _sensitive_edits_enabled(config):
        return {
            "ok": False,
            "status": "sensitive_edits_disabled",
            "code": "sensitive_edits_disabled",
        }
    _run_validator(path, normalized)
    if not _sensitive_edits_enabled(config):
        return {
            "ok": False,
            "status": "sensitive_edits_disabled",
            "code": "sensitive_edits_disabled",
        }
    try:
        warning = _atomic_write(
            target,
            normalized,
            0o640,
            pre_replace=lambda: _require_sensitive_edits_enabled(config),
        )
    except SensitiveEditsDisabled:
        return {
            "ok": False,
            "status": "sensitive_edits_disabled",
            "code": "sensitive_edits_disabled",
        }
    result = {"ok": True, "status": "saved", "path": path, "method": "policy_helper"}
    if warning is not None:
        result["warning"] = warning
    return result


def _set_command_guard(params: dict[str, object]) -> dict[str, object]:
    if set(params) != {"enabled"} or not isinstance(params.get("enabled"), bool):
        raise PolicyHelperError("command_guard.set accepts only boolean enabled")
    _release, _defaults, _overlay, config = _paths()
    with _config_lock(config):
        if not _sensitive_edits_enabled(config):
            return {
                "ok": False,
                "status": "sensitive_edits_disabled",
                "code": "sensitive_edits_disabled",
            }
        try:
            value = json.loads(
                _read_regular_text(config),
                object_pairs_hook=_reject_duplicate_keys,
                parse_constant=_reject_json_constant,
            )
        except (OSError, PolicyHelperError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
            raise PolicyHelperError("configuration is invalid") from exc
        if not isinstance(value, dict):
            raise PolicyHelperError("configuration must be an object")
        guard = value.get("command_guard")
        if not isinstance(guard, dict):
            guard = {}
        value["command_guard"] = {**guard, "enabled": params["enabled"]}
        normalized = json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + "\n"
        if not _sensitive_edits_enabled(config):
            return {
                "ok": False,
                "status": "sensitive_edits_disabled",
                "code": "sensitive_edits_disabled",
            }
        try:
            warning = _atomic_write(
                config,
                normalized,
                0o600,
                pre_replace=lambda: _require_sensitive_edits_enabled(config),
            )
        except SensitiveEditsDisabled:
            return {
                "ok": False,
                "status": "sensitive_edits_disabled",
                "code": "sensitive_edits_disabled",
            }
        result = {
            "ok": True,
            "status": "updated",
            "method": "policy_helper",
            "command_guard": value["command_guard"],
        }
        if warning is not None:
            result["warning"] = warning
        return result


def handle_connection(connection: object, expected_uid: int) -> None:
    request_id = ""
    try:
        require_peer_uid(connection, expected_uid)
        request = receive_json(connection)
        operation, params, _summary, request_id = validate_request(request)
        if operation == "ping":
            if params:
                raise PolicyHelperError("policy helper ping does not accept params")
            response = {"ok": True, "status": "ready", "helper": "policy-writer"}
        elif operation == "policy.write":
            with runtime_shared_lock():
                response = _write_policy(params)
        elif operation == "command_guard.set":
            with runtime_shared_lock():
                response = _set_command_guard(params)
        else:
            raise PolicyHelperError("unsupported policy helper operation")
        response.update({"protocol_version": PROTOCOL_VERSION, "request_id": request_id})
    except ProtocolError as exc:
        response = {
            "ok": False,
            "status": "helper_rejected",
            "code": "helper_rejected",
            "error": str(exc),
            "protocol_version": PROTOCOL_VERSION,
            "request_id": request_id,
        }
    except Exception as exc:
        response = {
            "ok": False,
            "status": "helper_failed",
            "code": "helper_failed",
            "error": str(exc),
            "protocol_version": PROTOCOL_VERSION,
            "request_id": request_id,
        }
    send_json(connection, response)


def serve() -> int:
    expected_uid = allowed_peer_uid("linux-agent")
    listener = systemd_listener()
    while True:
        connection, _ = listener.accept()
        with connection:
            connection.settimeout(15.0)
            handle_connection(connection, expected_uid)


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("serve")
    request = subparsers.add_parser("request")
    request.add_argument("--socket", required=True)
    request.add_argument("operation", choices=("ping", "policy.write", "command_guard.set"))
    request.add_argument("--params", required=True)
    request.add_argument("--summary", required=True)
    args = parser.parse_args()
    if args.command == "serve":
        if os.geteuid() != 0:
            raise SystemExit("policy helper must run as root")
        return serve()
    try:
        params = json.loads(
            args.params,
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=_reject_json_constant,
        )
        request_payload = build_request(
            args.operation,
            params,
            summary=args.summary,
        )
        response = client_request(args.socket, request_payload)
    except (OSError, ProtocolError, json.JSONDecodeError, ValueError) as exc:
        print(str(exc), file=os.sys.stderr)
        return 125
    print(json.dumps(response, ensure_ascii=False, separators=(",", ":")))
    return 0 if response.get("ok") else 1


if __name__ == "__main__":
    raise SystemExit(main())
