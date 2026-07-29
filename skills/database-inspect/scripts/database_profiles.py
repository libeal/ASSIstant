#!/usr/bin/env python3
"""Root-managed database profile validation and atomic lifecycle operations."""

from __future__ import annotations

import argparse
import grp
import ipaddress
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
from pathlib import Path


PROFILE_ID_PATTERN = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
DATABASE_NAME_PATTERN = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.$-]{0,127}$")
PROFILE_ROOT = Path(os.environ.get("LINUX_AGENT_DATABASE_PROFILE_ROOT", "/etc/linux-agent/database-profiles.d"))
EGRESS_DROPIN = Path(
    os.environ.get(
        "LINUX_AGENT_DATABASE_EGRESS_DROPIN",
        "/etc/systemd/system/linux-agent-database-inspector.service.d/20-database-egress.conf",
    )
)
HELPER_GROUP = os.environ.get("LINUX_AGENT_DATABASE_GROUP", "linux-agent-credential")
DATABASE_SERVICE_UNIT = "linux-agent-database-inspector.service"
ENGINES = frozenset({"postgresql", "mysql"})
TLS_MODES = frozenset({"disable", "require", "verify-full"})
CREDENTIAL_MODES = frozenset({"stored", "temporary", "stored_or_temporary"})


class DatabaseProfileError(ValueError):
    """A database profile is malformed or cannot be managed safely."""


def _reject_duplicates(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise DatabaseProfileError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def strict_json(raw: str) -> object:
    try:
        return json.loads(
            raw,
            object_pairs_hook=_reject_duplicates,
            parse_constant=lambda value: (_ for _ in ()).throw(
                DatabaseProfileError(f"invalid JSON constant: {value}")
            ),
        )
    except json.JSONDecodeError as exc:
        raise DatabaseProfileError(f"invalid JSON: {exc}") from exc


def _bounded_string(value: object, name: str, maximum: int = 256) -> str:
    if (
        not isinstance(value, str)
        or not value
        or len(value.encode("utf-8")) > maximum
        or any(character in value for character in ("\x00", "\n", "\r"))
    ):
        raise DatabaseProfileError(f"{name} must be a non-empty bounded string")
    return value


def _database_name(value: object) -> str:
    name = _bounded_string(value, "database", 128)
    if DATABASE_NAME_PATTERN.fullmatch(name) is None:
        raise DatabaseProfileError(
            "database must be a simple name, not a connection string or client option"
        )
    return name


def validate_profile(value: object) -> dict[str, object]:
    if not isinstance(value, dict):
        raise DatabaseProfileError("profile must be a JSON object")
    allowed = {
        "schema_version",
        "id",
        "engine",
        "endpoint",
        "port",
        "socket",
        "database",
        "tls",
        "credential_mode",
        "credentials",
    }
    unknown = sorted(set(value) - allowed)
    if unknown:
        raise DatabaseProfileError(f"unsupported profile fields: {', '.join(unknown)}")
    if type(value.get("schema_version")) is not int or value["schema_version"] != 1:
        raise DatabaseProfileError("profile schema_version must be 1")
    profile_id = value.get("id")
    if not isinstance(profile_id, str) or PROFILE_ID_PATTERN.fullmatch(profile_id) is None:
        raise DatabaseProfileError("profile id is invalid")
    engine = value.get("engine")
    if engine not in ENGINES:
        raise DatabaseProfileError("engine must be postgresql or mysql")
    endpoint = value.get("endpoint")
    socket_path = value.get("socket")
    if (endpoint is None) == (socket_path is None):
        raise DatabaseProfileError("exactly one of endpoint or socket is required")
    normalized_endpoint = None
    normalized_socket = None
    if endpoint is not None:
        endpoint_text = _bounded_string(endpoint, "endpoint", 128)
        if endpoint_text == "localhost":
            endpoint_text = "127.0.0.1"
        try:
            normalized_endpoint = str(ipaddress.ip_address(endpoint_text))
        except ValueError as exc:
            raise DatabaseProfileError("endpoint must be an exact IP address") from exc
    else:
        normalized_socket = _bounded_string(socket_path, "socket", 4096)
        socket_object = Path(normalized_socket)
        if (
            not socket_object.is_absolute()
            or ".." in socket_object.parts
            or os.path.normpath(normalized_socket) != normalized_socket
        ):
            raise DatabaseProfileError("socket must be a canonical absolute path")
    default_port = 5432 if engine == "postgresql" else 3306
    port = value.get("port", default_port)
    if isinstance(port, bool) or not isinstance(port, int) or not 1 <= port <= 65535:
        raise DatabaseProfileError("port must be an integer in 1..65535")
    database = _database_name(value.get("database"))
    tls = value.get("tls", "verify-full" if normalized_endpoint else "disable")
    if tls not in TLS_MODES:
        raise DatabaseProfileError("tls must be disable, require, or verify-full")
    if normalized_endpoint is not None:
        address = ipaddress.ip_address(normalized_endpoint)
        if not address.is_loopback and tls != "verify-full":
            raise DatabaseProfileError("non-loopback profiles require tls=verify-full")
    credential_mode = value.get("credential_mode")
    if credential_mode not in CREDENTIAL_MODES:
        raise DatabaseProfileError("credential_mode is invalid")
    credentials = value.get("credentials")
    normalized_credentials = None
    if credentials is not None:
        if not isinstance(credentials, dict) or set(credentials) != {"username", "password"}:
            raise DatabaseProfileError("credentials must contain only username and password")
        normalized_credentials = {
            "username": _bounded_string(credentials.get("username"), "username", 256),
            "password": _bounded_string(credentials.get("password"), "password", 4096),
        }
    if credential_mode == "stored" and normalized_credentials is None:
        raise DatabaseProfileError("stored credential mode requires credentials")
    if credential_mode == "temporary" and normalized_credentials is not None:
        raise DatabaseProfileError("temporary credential mode cannot store credentials")
    result: dict[str, object] = {
        "schema_version": 1,
        "id": profile_id,
        "engine": engine,
        "endpoint": normalized_endpoint,
        "port": port,
        "socket": normalized_socket,
        "database": database,
        "tls": tls,
        "credential_mode": credential_mode,
    }
    if normalized_credentials is not None:
        result["credentials"] = normalized_credentials
    return result


def profile_path(profile_id: str) -> Path:
    if PROFILE_ID_PATTERN.fullmatch(profile_id) is None:
        raise DatabaseProfileError("profile id is invalid")
    return PROFILE_ROOT / f"{profile_id}.json"


def load_profile(profile_id: str, *, require_root_owner: bool = True) -> dict[str, object]:
    path = profile_path(profile_id)
    try:
        metadata = path.lstat()
    except OSError as exc:
        raise DatabaseProfileError("database profile is unavailable") from exc
    if (
        not stat.S_ISREG(metadata.st_mode)
        or stat.S_ISLNK(metadata.st_mode)
        or metadata.st_size > 65_536
        or stat.S_IMODE(metadata.st_mode) != 0o640
        or metadata.st_gid != _helper_gid()
        or (require_root_owner and metadata.st_uid != 0)
    ):
        raise DatabaseProfileError("database profile metadata is invalid")
    try:
        profile = validate_profile(strict_json(path.read_text(encoding="utf-8")))
    except (OSError, UnicodeError) as exc:
        raise DatabaseProfileError("database profile cannot be read") from exc
    if profile["id"] != profile_id:
        raise DatabaseProfileError("database profile id does not match its filename")
    return profile


def public_profile(profile: dict[str, object]) -> dict[str, object]:
    return {
        key: value
        for key, value in profile.items()
        if key != "credentials"
    } | {"stored_credentials": "credentials" in profile}


def list_profiles(*, require_root_owner: bool = True) -> list[dict[str, object]]:
    try:
        entries = sorted(PROFILE_ROOT.iterdir(), key=lambda path: path.name)
    except FileNotFoundError:
        return []
    profiles = []
    for entry in entries:
        if not entry.name.endswith(".json"):
            continue
        profile_id = entry.name[:-5]
        if PROFILE_ID_PATTERN.fullmatch(profile_id) is None:
            continue
        profiles.append(public_profile(load_profile(profile_id, require_root_owner=require_root_owner)))
    return profiles


def _helper_gid() -> int:
    try:
        return grp.getgrnam(HELPER_GROUP).gr_gid
    except KeyError as exc:
        raise DatabaseProfileError(f"database helper group does not exist: {HELPER_GROUP}") from exc


def _fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _assert_no_symlink_components(path: Path) -> None:
    absolute = Path(os.path.abspath(os.fspath(path)))
    current = Path(absolute.anchor)
    for component in absolute.parts[1:]:
        current /= component
        try:
            metadata = current.lstat()
        except FileNotFoundError:
            continue
        if stat.S_ISLNK(metadata.st_mode):
            raise DatabaseProfileError(f"managed path contains a symbolic link: {current}")


def _atomic_write(path: Path, payload: bytes, mode: int, uid: int, gid: int) -> None:
    descriptor, raw_path = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(raw_path)
    try:
        offset = 0
        while offset < len(payload):
            offset += os.write(descriptor, payload[offset:])
        os.fchmod(descriptor, mode)
        os.fchown(descriptor, uid, gid)
        os.fsync(descriptor)
        os.close(descriptor)
        os.replace(temporary, path)
        _fsync_directory(path.parent)
    finally:
        try:
            os.close(descriptor)
        except OSError:
            pass
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def _ensure_root() -> None:
    if os.geteuid() != 0:
        raise DatabaseProfileError("database credential management requires root")


def initialize_profile_root() -> Path:
    """Create and validate the package-owned credential profile directory."""

    _ensure_root()
    _assert_no_symlink_components(PROFILE_ROOT)
    PROFILE_ROOT.mkdir(parents=True, exist_ok=True, mode=0o750)
    _assert_no_symlink_components(PROFILE_ROOT)
    metadata = PROFILE_ROOT.lstat()
    if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        raise DatabaseProfileError("database profile root is not a real directory")
    os.chown(PROFILE_ROOT, 0, _helper_gid())
    os.chmod(PROFILE_ROOT, 0o750)
    return PROFILE_ROOT


def install_profile(
    profile: dict[str, object], *, activate_systemd: bool = False
) -> Path:
    _ensure_root()
    normalized = validate_profile(profile)
    initialize_profile_root()
    target = profile_path(str(normalized["id"]))
    previous = None
    if target.exists() or target.is_symlink():
        metadata = target.lstat()
        if not stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
            raise DatabaseProfileError("database profile target is invalid")
        previous = (
            target.read_bytes(),
            stat.S_IMODE(metadata.st_mode),
            metadata.st_uid,
            metadata.st_gid,
        )
    payload = (
        json.dumps(normalized, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n"
    ).encode("utf-8")
    _atomic_write(target, payload, 0o640, 0, _helper_gid())
    try:
        refresh_egress(activate_systemd=activate_systemd)
    except Exception as refresh_error:
        try:
            if previous is None:
                target.unlink()
                _fsync_directory(PROFILE_ROOT)
            else:
                _atomic_write(target, *previous)
            refresh_egress(activate_systemd=activate_systemd)
        except Exception as rollback_error:
            raise DatabaseProfileError(
                f"egress refresh failed and profile rollback failed: {rollback_error}"
            ) from refresh_error
        raise DatabaseProfileError(
            f"egress refresh failed; profile was restored: {refresh_error}"
        ) from refresh_error
    return target


def remove_profile(profile_id: str, *, activate_systemd: bool = False) -> None:
    _ensure_root()
    target = profile_path(profile_id)
    _assert_no_symlink_components(PROFILE_ROOT)
    try:
        metadata = target.lstat()
    except FileNotFoundError as exc:
        raise DatabaseProfileError("database profile does not exist") from exc
    if not stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        raise DatabaseProfileError("database profile target is invalid")
    previous = (
        target.read_bytes(),
        stat.S_IMODE(metadata.st_mode),
        metadata.st_uid,
        metadata.st_gid,
    )
    current = target.lstat()
    if (current.st_dev, current.st_ino) != (metadata.st_dev, metadata.st_ino):
        raise DatabaseProfileError("database profile changed before removal")
    target.unlink()
    _fsync_directory(PROFILE_ROOT)
    try:
        refresh_egress(activate_systemd=activate_systemd)
    except Exception as refresh_error:
        try:
            _atomic_write(target, *previous)
            refresh_egress(activate_systemd=activate_systemd)
        except Exception as rollback_error:
            raise DatabaseProfileError(
                f"egress refresh failed and profile rollback failed: {rollback_error}"
            ) from refresh_error
        raise DatabaseProfileError(
            f"egress refresh failed; profile was restored: {refresh_error}"
        ) from refresh_error


def _trusted_systemctl() -> str:
    for candidate in ("/usr/bin/systemctl", "/bin/systemctl"):
        path = Path(candidate)
        try:
            resolved = path.resolve(strict=True)
            metadata = resolved.stat()
        except OSError:
            continue
        if (
            stat.S_ISREG(metadata.st_mode)
            and metadata.st_uid == 0
            and not metadata.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
            and os.access(resolved, os.X_OK)
        ):
            return os.fspath(resolved)
    raise DatabaseProfileError("trusted systemctl is unavailable")


def _activate_systemd_egress() -> None:
    systemctl = _trusted_systemctl()
    environment = {
        "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
    }
    for arguments in (("daemon-reload",), ("try-restart", DATABASE_SERVICE_UNIT)):
        try:
            completed = subprocess.run(
                [systemctl, *arguments],
                stdin=subprocess.DEVNULL,
                capture_output=True,
                check=False,
                timeout=30,
                env=environment,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise DatabaseProfileError(
                f"systemd database egress activation failed: {arguments[0]}"
            ) from exc
        if completed.returncode != 0:
            error = completed.stderr[:4096].decode("utf-8", errors="replace").strip()
            raise DatabaseProfileError(
                error
                or f"systemd database egress activation failed: {arguments[0]}"
            )


def refresh_egress(*, activate_systemd: bool = False) -> Path:
    _ensure_root()
    profiles = list_profiles()
    addresses = sorted(
        {
            str(profile["endpoint"])
            for profile in profiles
            if profile.get("endpoint") is not None
            and not ipaddress.ip_address(str(profile["endpoint"])).is_loopback
        }
    )
    lines = [
        "# Generated by linux-agent database profile manager.",
        "[Service]",
        "IPAddressDeny=any",
        "IPAddressAllow=localhost",
    ]
    for address in addresses:
        suffix = "/32" if ipaddress.ip_address(address).version == 4 else "/128"
        lines.append(f"IPAddressAllow={address}{suffix}")
    payload = ("\n".join(lines) + "\n").encode("utf-8")
    parent = EGRESS_DROPIN.parent
    _assert_no_symlink_components(parent)
    parent.mkdir(parents=True, exist_ok=True, mode=0o755)
    _assert_no_symlink_components(parent)
    if EGRESS_DROPIN.is_symlink():
        raise DatabaseProfileError("database egress drop-in target is invalid")
    _atomic_write(EGRESS_DROPIN, payload, 0o644, 0, 0)
    if activate_systemd:
        _activate_systemd_egress()
    return EGRESS_DROPIN


def discover_instances() -> dict[str, object]:
    standard_paths = (
        "/run/postgresql/.s.PGSQL.5432",
        "/var/run/postgresql/.s.PGSQL.5432",
        "/run/mysqld/mysqld.sock",
        "/var/run/mysqld/mysqld.sock",
    )
    sockets = []
    for value in standard_paths:
        path = Path(value)
        try:
            mode = path.stat().st_mode
        except OSError:
            continue
        if stat.S_ISSOCK(mode):
            sockets.append(value)
    clients = {}
    for name, candidates in {
        "postgresql": ("/usr/bin/psql", "/usr/local/bin/psql"),
        "mysql": ("/usr/bin/mysql", "/usr/bin/mariadb", "/usr/local/bin/mysql"),
    }.items():
        clients[name] = next((candidate for candidate in candidates if Path(candidate).is_file()), None)
    return {
        "ok": True,
        "status": "listed",
        "tool": "database-inspect/instance-discovery",
        "standard_sockets": sockets,
        "clients": clients,
        "credentials_read": False,
        "network_probe_performed": False,
    }


def _read_stdin_profile() -> dict[str, object]:
    raw = sys.stdin.buffer.read(65_537)
    if len(raw) > 65_536:
        raise DatabaseProfileError("profile input exceeds 64 KiB")
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise DatabaseProfileError("profile input must be UTF-8") from exc
    return validate_profile(strict_json(text))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("initialize")
    subparsers.add_parser("validate")
    install_parser = subparsers.add_parser("install")
    install_parser.add_argument("--activate-systemd", action="store_true")
    subparsers.add_parser("list")
    remove_parser = subparsers.add_parser("remove")
    remove_parser.add_argument("profile_id")
    remove_parser.add_argument("--activate-systemd", action="store_true")
    refresh_parser = subparsers.add_parser("refresh-egress")
    refresh_parser.add_argument("--activate-systemd", action="store_true")
    subparsers.add_parser("discover")
    args = parser.parse_args(argv)
    try:
        if args.command == "initialize":
            path = initialize_profile_root()
            result = {"ok": True, "status": "initialized", "path": os.fspath(path)}
        elif args.command == "validate":
            profile = _read_stdin_profile()
            result = {"ok": True, "status": "validated", "profile": public_profile(profile)}
        elif args.command == "install":
            profile = _read_stdin_profile()
            path = install_profile(profile, activate_systemd=args.activate_systemd)
            result = {"ok": True, "status": "installed", "id": profile["id"], "path": os.fspath(path)}
        elif args.command == "list":
            result = {"ok": True, "status": "listed", "profiles": list_profiles()}
        elif args.command == "remove":
            remove_profile(args.profile_id, activate_systemd=args.activate_systemd)
            result = {"ok": True, "status": "removed", "id": args.profile_id}
        elif args.command == "refresh-egress":
            path = refresh_egress(activate_systemd=args.activate_systemd)
            result = {"ok": True, "status": "updated", "path": os.fspath(path)}
        else:
            result = discover_instances()
    except DatabaseProfileError as exc:
        result = {"ok": False, "status": "validation_failed", "code": "validation_failed", "error": str(exc)}
    print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
