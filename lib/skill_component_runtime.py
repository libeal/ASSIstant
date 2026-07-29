#!/usr/bin/env python3
"""Install and remove privileged components declared by one builtin Skill."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import stat
import subprocess
import tempfile
from pathlib import Path

from skill_component_ledger import LedgerError, load as load_ledger
from skill_component_ledger import mark_uninstalled, upsert
from skill_package import SkillPackageError, contract_digest, load_package


class ComponentError(RuntimeError):
    """Raised when a package component cannot be reconciled safely."""


MAX_COMPONENT_FILE_BYTES = 4 * 1024 * 1024


def _regular_file(path: Path, label: str) -> None:
    if path.is_symlink() or not path.is_file():
        raise ComponentError(f"{label} is unavailable")


def _safe_directory(path: Path, label: str, *, create: bool = False) -> None:
    absolute = Path(os.path.abspath(path))
    current = Path(absolute.anchor)
    for component in absolute.parts[1:]:
        current /= component
        if current.exists() or current.is_symlink():
            metadata = current.lstat()
            if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
                raise ComponentError(f"{label} is unsafe")
    if path.is_symlink() or (path.exists() and not path.is_dir()):
        raise ComponentError(f"{label} is unsafe")
    if create:
        path.mkdir(parents=True, exist_ok=True)
    if not path.is_dir():
        raise ComponentError(f"{label} is unavailable")


def _fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _atomic_bytes(path: Path, content: bytes, mode: int = 0o644) -> None:
    _safe_directory(path.parent, "component target directory", create=True)
    if path.is_symlink() or (path.exists() and not path.is_file()):
        raise ComponentError("component target file is unsafe")
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(content)
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
        _fsync_directory(path.parent)
    finally:
        temporary.unlink(missing_ok=True)


def _component_paths(record: dict[str, object]) -> list[Path]:
    raw_paths = (*record["unit_files"], *record["host_policy_files"])
    return sorted({Path(path) for path in raw_paths}, key=os.fspath)


def _missing_parent_directories(paths: list[Path]) -> list[Path]:
    missing: set[Path] = set()
    for path in paths:
        absolute = Path(os.path.abspath(path.parent))
        current = Path(absolute.anchor)
        for component in absolute.parts[1:]:
            current /= component
            if current.exists() or current.is_symlink():
                metadata = current.lstat()
                if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
                    raise ComponentError(f"component target directory is unsafe: {current}")
            else:
                missing.add(current)
    return sorted(missing, key=lambda path: len(path.parts), reverse=True)


def _snapshot_files(paths: list[Path]) -> dict[Path, tuple[bytes, int] | None]:
    snapshots: dict[Path, tuple[bytes, int] | None] = {}
    for path in paths:
        if path.is_symlink():
            raise ComponentError(f"component-owned file is unsafe: {path}")
        if not path.exists():
            snapshots[path] = None
            continue
        metadata = path.stat()
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > MAX_COMPONENT_FILE_BYTES:
            raise ComponentError(f"component-owned file is unsafe or too large: {path}")
        snapshots[path] = (path.read_bytes(), stat.S_IMODE(metadata.st_mode))
    return snapshots


def _restore_files(
    snapshots: dict[Path, tuple[bytes, int] | None], missing_directories: list[Path]
) -> None:
    for path, snapshot in snapshots.items():
        if snapshot is None:
            if path.is_symlink() or (path.exists() and not path.is_file()):
                raise ComponentError(f"cannot remove unsafe rollback target: {path}")
            if path.exists():
                path.unlink()
                _fsync_directory(path.parent)
        else:
            content, mode = snapshot
            _atomic_bytes(path, content, mode)
    for directory in missing_directories:
        if directory.is_symlink():
            raise ComponentError(f"cannot remove unsafe rollback directory: {directory}")
        try:
            directory.rmdir()
        except FileNotFoundError:
            continue
        except OSError:
            # Initialization commands may create retained state below a newly
            # created parent. Never remove non-empty directories during rollback.
            continue
        _fsync_directory(directory.parent)


def _restore_systemd_state(
    units: list[str], active_units: set[str], enabled_units: set[str], web_active: bool
) -> None:
    _systemctl("daemon-reload")
    for unit in units:
        if unit in enabled_units:
            _systemctl("enable", unit, required=False)
        if unit in active_units:
            _systemctl("try-restart", unit, required=False)
        else:
            _systemctl("stop", unit, required=False)
    if web_active:
        _systemctl("try-restart", "linux-agent-web.service", required=False)


def _rollback_component_transaction(
    snapshots: dict[Path, tuple[bytes, int] | None],
    missing_directories: list[Path],
    units: list[str],
    active_units: set[str],
    enabled_units: set[str],
    web_active: bool,
    systemd: bool,
) -> None:
    _restore_files(snapshots, missing_directories)
    if systemd:
        _restore_systemd_state(units, active_units, enabled_units, web_active)


def _remove_component_file(path: Path) -> None:
    if path.is_symlink() or (path.exists() and not path.is_file()):
        raise ComponentError(f"component-owned file is unsafe: {path}")
    if path.exists():
        path.unlink()
        _fsync_directory(path.parent)
    if path.parent.name.endswith(".service.d"):
        try:
            path.parent.rmdir()
        except OSError:
            return
        _fsync_directory(path.parent.parent)


def _merge_owned_paths(
    current: list[dict[str, str]], previous: list[dict[str, str]]
) -> list[dict[str, str]]:
    merged: dict[tuple[str, str, str], dict[str, str]] = {}
    for item in (*previous, *current):
        key = (item["kind"], item["path"], item["default"])
        merged[key] = dict(item)
    return [merged[key] for key in sorted(merged)]


def _render_unit(
    source: Path,
    *,
    prefix: Path,
    web_user: str,
    web_group: str,
    credential_user: str,
    credential_group: str,
    host_policy: Path,
) -> bytes:
    _regular_file(source, "component systemd unit")
    text = source.read_text(encoding="utf-8").replace("/opt/linux-agent", os.fspath(prefix))
    replacements = {
        "User=linux-agent-credential": f"User={credential_user}",
        "Group=linux-agent-credential": f"Group={credential_group}",
        "User=linux-agent": f"User={web_user}",
        "Group=linux-agent": f"Group={web_group}",
        "SocketUser=linux-agent": f"SocketUser={web_user}",
        "SocketGroup=linux-agent": f"SocketGroup={web_group}",
        "Environment=LINUX_AGENT_SERVICE_USER=linux-agent": (
            f"Environment=LINUX_AGENT_SERVICE_USER={web_user}"
        ),
        "Environment=LINUX_AGENT_HOST_OPS_POLICY_PATH=/etc/linux-agent/host-ops-policy.json": (
            f"Environment=LINUX_AGENT_HOST_OPS_POLICY_PATH={host_policy}"
        ),
    }
    rendered = "".join(
        replacements.get(line, line) + "\n" for line in text.splitlines()
    )
    return rendered.encode("utf-8")


def _run(command: list[str], *, environment: dict[str, str] | None = None) -> None:
    try:
        completed = subprocess.run(
            command,
            env=environment,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=120,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise ComponentError(f"component command could not run: {command[0]}") from exc
    if completed.returncode != 0:
        message = completed.stderr.strip().splitlines()[-1:] or ["command failed"]
        raise ComponentError(f"component command failed: {message[0][:300]}")


def _systemctl(*arguments: str, required: bool = True) -> bool:
    try:
        completed = subprocess.run(
            ["systemctl", *arguments],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=60,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        if required:
            raise ComponentError("systemctl is unavailable") from exc
        return False
    if required and completed.returncode != 0:
        raise ComponentError(f"systemctl {' '.join(arguments)} failed")
    return completed.returncode == 0


def _component_environment(
    mapping: dict[str, str], *, credential_group: str, egress_path: Path | None
) -> dict[str, str]:
    environment = dict(os.environ)
    environment["PYTHONPATH"] = os.pathsep.join(
        part for part in (os.environ.get("LINUX_AGENT_ROOT", "") + "/lib", environment.get("PYTHONPATH", "")) if part
    )
    for name, source in mapping.items():
        if source == "credential_group":
            environment[name] = credential_group
        elif source == "component_egress_dropin" and egress_path is not None:
            environment[name] = os.fspath(egress_path)
        else:
            raise ComponentError("component environment mapping is invalid")
    return environment


def _resolve_owned_paths(credential: dict[str, object]) -> list[dict[str, str]]:
    result = []
    for declaration in credential.get("owned_paths", []):
        environment = declaration["environment"]
        default = declaration["default"]
        value = os.environ.get(environment, "").strip() or default
        path = Path(value)
        if (
            not path.is_absolute()
            or ".." in path.parts
            or path.name != Path(default).name
            or len(path.parts) < 3
        ):
            raise ComponentError(f"owned path override is unsafe: {environment}")
        result.append({"kind": "directory", "path": os.fspath(path), "default": default})
    return result


def _record_for(
    package: Path,
    loaded: dict[str, object],
    *,
    unit_dir: Path,
    host_policy: Path,
    systemd: bool,
) -> dict[str, object]:
    units: list[str] = []
    unit_files: list[str] = []
    policy_files: list[str] = []
    owned_paths: list[dict[str, str]] = []
    components = loaded["components"]
    credential = components.get("credential_helper")
    if systemd and isinstance(credential, dict):
        service = Path(credential["service_asset"]).name
        socket = Path(credential["socket_asset"]).name
        units.extend((socket, service))
        unit_files.extend((os.fspath(unit_dir / service), os.fspath(unit_dir / socket)))
        egress = credential.get("egress_dropin")
        if isinstance(egress, str):
            unit_files.append(
                os.fspath(unit_dir / f"linux-agent-{credential['name']}.service.d" / egress)
            )
        owned_paths = _resolve_owned_paths(credential)
    host = components.get("host_helper")
    if systemd and isinstance(host, dict) and host.get("policy_asset"):
        policy_files.append(os.fspath(host_policy))
    return {
        "installed": True,
        "contract_digest": contract_digest(package, "builtin"),
        "units": units,
        "unit_files": unit_files,
        "host_policy_files": policy_files,
        "owned_paths": owned_paths,
    }


def install_components(arguments: argparse.Namespace) -> dict[str, object]:
    package = Path(arguments.package)
    loaded = load_package(package, "builtin")
    prefix = Path(arguments.prefix)
    unit_dir = Path(arguments.unit_dir)
    host_policy = Path(arguments.host_policy)
    ledger_path = Path(arguments.ledger)
    ledger = load_ledger(ledger_path)
    previous = ledger["skills"].get(loaded["name"])
    record = _record_for(
        package,
        loaded,
        unit_dir=unit_dir,
        host_policy=host_policy,
        systemd=arguments.systemd,
    )
    previous_record = previous if isinstance(previous, dict) else None
    if previous_record is not None:
        record["owned_paths"] = _merge_owned_paths(
            record["owned_paths"], previous_record["owned_paths"]
        )
    current_paths = _component_paths(record)
    previous_paths = _component_paths(previous_record) if previous_record else []
    transaction_paths = sorted(
        {*current_paths, *previous_paths, ledger_path}, key=os.fspath
    )
    missing_directories = _missing_parent_directories(transaction_paths)
    snapshots = _snapshot_files(transaction_paths)
    units = sorted(
        {
            *record["units"],
            *(previous_record["units"] if previous_record else []),
        }
    )
    active_units: set[str] = set()
    enabled_units: set[str] = set()
    web_active = False
    if arguments.systemd:
        active_units = {
            unit
            for unit in units
            if _systemctl("is-active", "--quiet", unit, required=False)
        }
        enabled_units = {
            unit
            for unit in units
            if _systemctl("is-enabled", "--quiet", unit, required=False)
        }
        web_active = _systemctl(
            "is-active", "--quiet", "linux-agent-web.service", required=False
        )
    try:
        if arguments.systemd:
            _safe_directory(unit_dir, "systemd unit directory", create=True)
            components = loaded["components"]
            credential = components.get("credential_helper")
            if isinstance(credential, dict):
                egress_name = credential.get("egress_dropin")
                egress_path = (
                    unit_dir / f"linux-agent-{credential['name']}.service.d" / egress_name
                    if isinstance(egress_name, str)
                    else None
                )
                for command in credential.get("install", {}).get("commands", []):
                    environment = _component_environment(
                        command["environment"],
                        credential_group=arguments.credential_group,
                        egress_path=egress_path,
                    )
                    _run(
                        [
                            "python3",
                            os.fspath(package / command["entrypoint"]),
                            *command["arguments"],
                        ],
                        environment=environment,
                    )
                for field in ("service_asset", "socket_asset"):
                    source = package / credential[field]
                    target = unit_dir / source.name
                    rendered = _render_unit(
                        source,
                        prefix=prefix,
                        web_user=arguments.web_user,
                        web_group=arguments.web_group,
                        credential_user=arguments.credential_user,
                        credential_group=arguments.credential_group,
                        host_policy=host_policy,
                    )
                    _atomic_bytes(target, rendered)
                verify_files = [
                    path
                    for path in record["unit_files"]
                    if path.endswith((".service", ".socket"))
                ]
                if shutil.which("systemd-analyze") and verify_files:
                    _run(["systemd-analyze", "verify", *verify_files])
            host = components.get("host_helper")
            if isinstance(host, dict) and host.get("policy_asset"):
                source = package / host["policy_asset"]
                _regular_file(source, "host helper policy asset")
                _atomic_bytes(host_policy, source.read_bytes(), 0o600)
            for stale_path in sorted(set(previous_paths) - set(current_paths), key=os.fspath):
                _remove_component_file(stale_path)
            stale_units = sorted(
                set(previous_record["units"] if previous_record else [])
                - set(record["units"])
            )
            for unit in stale_units:
                _systemctl("stop", unit, required=False)
                _systemctl("disable", unit, required=False)
            for item in record["owned_paths"]:
                path = Path(item["path"])
                _safe_directory(path, f"declared owned directory was not initialized: {path}")
            _systemctl("daemon-reload")
            if isinstance(credential, dict):
                _systemctl("start", Path(credential["socket_asset"]).name)
            if web_active:
                _systemctl("try-restart", "linux-agent-web.service")
        result = upsert(ledger_path, loaded["name"], json.dumps(record))
        return {"skill": loaded["name"], "record": result}
    except Exception as exc:
        try:
            _rollback_component_transaction(
                snapshots,
                missing_directories,
                units,
                active_units,
                enabled_units,
                web_active,
                arguments.systemd,
            )
        except Exception as rollback_exc:
            raise ComponentError(
                f"component installation failed and rollback failed: {rollback_exc}"
            ) from exc
        raise


def uninstall_components(arguments: argparse.Namespace) -> dict[str, object]:
    package = Path(arguments.package)
    name = arguments.name or package.name
    ledger_path = Path(arguments.ledger)
    ledger = load_ledger(ledger_path)
    record = ledger["skills"].get(name)
    if record is None:
        loaded = load_package(package, "builtin")
        record = _record_for(
            package,
            loaded,
            unit_dir=Path(arguments.unit_dir),
            host_policy=Path(arguments.host_policy),
            systemd=arguments.systemd,
        )
    component_paths = _component_paths(record)
    transaction_paths = sorted({*component_paths, ledger_path}, key=os.fspath)
    missing_directories = _missing_parent_directories(transaction_paths)
    snapshots = _snapshot_files(transaction_paths)
    units = sorted(record["units"])
    active_units: set[str] = set()
    enabled_units: set[str] = set()
    web_active = False
    if arguments.systemd:
        active_units = {
            unit
            for unit in units
            if _systemctl("is-active", "--quiet", unit, required=False)
        }
        enabled_units = {
            unit
            for unit in units
            if _systemctl("is-enabled", "--quiet", unit, required=False)
        }
        web_active = _systemctl(
            "is-active", "--quiet", "linux-agent-web.service", required=False
        )
    try:
        if arguments.systemd:
            for unit in units:
                _systemctl("stop", unit, required=False)
                _systemctl("disable", unit, required=False)
            for path in component_paths:
                _remove_component_file(path)
            _systemctl("daemon-reload")
        updated, purged, cleanup_pending = mark_uninstalled(
            ledger_path, name, purge=arguments.purge
        )
        return {
            "skill": name,
            "record": updated,
            "purged_paths": purged,
            "cleanup_pending": cleanup_pending,
            "web_restart_required": arguments.systemd and web_active,
        }
    except Exception as exc:
        try:
            _rollback_component_transaction(
                snapshots,
                missing_directories,
                units,
                active_units,
                enabled_units,
                web_active,
                arguments.systemd,
            )
        except Exception as rollback_exc:
            raise ComponentError(
                f"component removal failed and rollback failed: {rollback_exc}"
            ) from exc
        raise


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("install", "uninstall"))
    parser.add_argument("package")
    parser.add_argument("--name")
    parser.add_argument("--ledger", required=True)
    parser.add_argument("--prefix", required=True)
    parser.add_argument("--unit-dir", default="/etc/systemd/system")
    parser.add_argument("--host-policy", default="/etc/linux-agent/host-ops-policy.json")
    parser.add_argument("--web-user", default="linux-agent")
    parser.add_argument("--web-group", default="linux-agent")
    parser.add_argument("--credential-user", default="linux-agent-credential")
    parser.add_argument("--credential-group", default="linux-agent-credential")
    parser.add_argument("--systemd", action="store_true")
    parser.add_argument("--purge", action="store_true")
    parser.add_argument("--confirm", default="")
    arguments = parser.parse_args()
    try:
        if arguments.purge and arguments.confirm != "PURGE_SKILL_DATA":
            raise ComponentError("purge requires confirm=PURGE_SKILL_DATA")
        if arguments.command == "install":
            result = install_components(arguments)
        else:
            result = uninstall_components(arguments)
        print(json.dumps({"ok": True, "status": arguments.command, **result}, ensure_ascii=False))
        return 0
    except (ComponentError, LedgerError, SkillPackageError, OSError, ValueError) as exc:
        print(json.dumps({"ok": False, "status": "failed", "error": str(exc)}, ensure_ascii=False))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
