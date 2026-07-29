#!/usr/bin/env python3
"""Durable ownership ledger for privileged builtin Skill components."""

from __future__ import annotations

import argparse
import json
import os
import re
import secrets
import shutil
import stat
import tempfile
from pathlib import Path


NAME_PATTERN = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$")
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
UNIT_PATTERN = re.compile(r"^linux-agent-[a-z0-9][a-z0-9-]{0,62}[.](?:service|socket)$")
MAX_LEDGER_BYTES = 1024 * 1024


class LedgerError(ValueError):
    """Raised when an ownership ledger or managed path is unsafe."""


def _reject_duplicates(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise LedgerError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _strict_json(raw: str) -> object:
    return json.loads(
        raw,
        object_pairs_hook=_reject_duplicates,
        parse_constant=lambda value: (_ for _ in ()).throw(LedgerError(value)),
    )


def _absolute_file(value: object) -> str:
    if not isinstance(value, str) or not value.startswith("/") or "\n" in value:
        raise LedgerError("component file path must be absolute")
    path = Path(value)
    if ".." in path.parts or len(path.parts) < 3 or path == Path("/"):
        raise LedgerError("component file path is unsafe")
    return os.fspath(path)


def _owned_path(value: object) -> dict[str, str]:
    if not isinstance(value, dict) or set(value) != {"kind", "path", "default"}:
        raise LedgerError("owned path record is invalid")
    kind = value.get("kind")
    actual = _absolute_file(value.get("path"))
    default = _absolute_file(value.get("default"))
    if (
        kind != "directory"
        or not default.startswith(("/etc/linux-agent/", "/var/lib/linux-agent/"))
        or Path(actual).name != Path(default).name
        or actual in {"/etc", "/var", "/home", "/root", "/tmp"}
    ):
        raise LedgerError("owned path record is outside the bounded contract")
    return {"kind": kind, "path": actual, "default": default}


def _record(value: object) -> dict[str, object]:
    required = {
        "installed",
        "contract_digest",
        "units",
        "unit_files",
        "host_policy_files",
        "owned_paths",
    }
    if not isinstance(value, dict) or set(value) != required:
        raise LedgerError("Skill ownership record is invalid")
    installed = value.get("installed")
    digest = value.get("contract_digest")
    units = value.get("units")
    unit_files = value.get("unit_files")
    policy_files = value.get("host_policy_files")
    owned_paths = value.get("owned_paths")
    if (
        not isinstance(installed, bool)
        or not isinstance(digest, str)
        or SHA256_PATTERN.fullmatch(digest) is None
        or not isinstance(units, list)
        or len(units) > 16
        or not all(isinstance(unit, str) and UNIT_PATTERN.fullmatch(unit) for unit in units)
        or len(units) != len(set(units))
        or not isinstance(unit_files, list)
        or len(unit_files) > 32
        or not isinstance(policy_files, list)
        or len(policy_files) > 8
        or not isinstance(owned_paths, list)
        or len(owned_paths) > 16
    ):
        raise LedgerError("Skill ownership record is invalid")
    normalized_unit_files = [_absolute_file(path) for path in unit_files]
    normalized_policy_files = [_absolute_file(path) for path in policy_files]
    normalized_owned_paths = [_owned_path(item) for item in owned_paths]
    if (
        len(normalized_unit_files) != len(set(normalized_unit_files))
        or len(normalized_policy_files) != len(set(normalized_policy_files))
        or len({item["path"] for item in normalized_owned_paths})
        != len(normalized_owned_paths)
    ):
        raise LedgerError("Skill ownership record contains duplicate paths")
    return {
        "installed": installed,
        "contract_digest": digest,
        "units": list(units),
        "unit_files": normalized_unit_files,
        "host_policy_files": normalized_policy_files,
        "owned_paths": normalized_owned_paths,
    }


def load(path: Path) -> dict[str, object]:
    if not path.exists():
        return {"schema_version": 1, "skills": {}}
    metadata = path.lstat()
    if not stat.S_ISREG(metadata.st_mode) or path.is_symlink() or metadata.st_size > MAX_LEDGER_BYTES:
        raise LedgerError("Skill ownership ledger is unsafe")
    try:
        value = _strict_json(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise LedgerError(f"Skill ownership ledger is invalid: {exc}") from exc
    if not isinstance(value, dict) or set(value) != {"schema_version", "skills"}:
        raise LedgerError("Skill ownership ledger has an invalid schema")
    skills = value.get("skills")
    if value.get("schema_version") != 1 or not isinstance(skills, dict):
        raise LedgerError("Skill ownership ledger has an invalid schema")
    normalized: dict[str, object] = {}
    for name, record in skills.items():
        if not isinstance(name, str) or NAME_PATTERN.fullmatch(name) is None:
            raise LedgerError("Skill ownership ledger contains an invalid name")
        normalized[name] = _record(record)
    return {"schema_version": 1, "skills": normalized}


def _write(path: Path, ledger: dict[str, object]) -> None:
    parent = path.parent
    if parent.is_symlink() or not parent.is_dir():
        raise LedgerError("Skill ownership ledger directory is unsafe")
    descriptor, temporary_name = tempfile.mkstemp(prefix=".skill-components.", dir=parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            json.dump(ledger, output, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
        parent_descriptor = os.open(parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(parent_descriptor)
        finally:
            os.close(parent_descriptor)
    finally:
        temporary.unlink(missing_ok=True)


def upsert(path: Path, name: str, raw_record: str) -> dict[str, object]:
    if NAME_PATTERN.fullmatch(name) is None:
        raise LedgerError("Skill name is invalid")
    record = _record(_strict_json(raw_record))
    ledger = load(path)
    ledger["skills"][name] = record
    _write(path, ledger)
    return record


def _purge_target(target: Path, name: str) -> Path | None:
    current = Path(target.anchor)
    for component in target.parts[1:]:
        current /= component
        if current.exists() or current.is_symlink():
            if current.is_symlink():
                raise LedgerError(f"owned path contains a symbolic link: {target}")
    if not target.exists():
        return None
    if not target.is_dir():
        raise LedgerError(f"owned path is not a directory: {target}")
    parent_metadata = target.parent.stat()
    target_metadata = target.stat()
    if (
        parent_metadata.st_uid != os.geteuid()
        or target_metadata.st_uid != os.geteuid()
        or stat.S_IMODE(parent_metadata.st_mode) & 0o022
    ):
        raise LedgerError(f"owned path parent is not private to the service owner: {target}")
    staging = target.with_name(
        f".{target.name}.purge-{name}-{secrets.token_hex(16)}"
    )
    if staging.exists() or staging.is_symlink():
        raise LedgerError(f"owned path purge staging is occupied: {target}")
    os.rename(target, staging)
    parent_descriptor = os.open(
        target.parent,
        os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0),
    )
    try:
        os.fsync(parent_descriptor)
    finally:
        os.close(parent_descriptor)
    return staging


def _restore_purge_targets(staged: list[tuple[Path, Path]]) -> None:
    for target, staging in reversed(staged):
        if not staging.is_dir() or staging.is_symlink():
            raise LedgerError(f"purge rollback staging is unavailable: {staging}")
        if target.exists() or target.is_symlink():
            raise LedgerError(f"purge rollback target is occupied: {target}")
        os.rename(staging, target)
        parent_descriptor = os.open(
            target.parent,
            os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0),
        )
        try:
            os.fsync(parent_descriptor)
        finally:
            os.close(parent_descriptor)


def mark_uninstalled(
    path: Path, name: str, *, purge: bool
) -> tuple[dict[str, object], list[str], list[str]]:
    ledger = load(path)
    record = ledger["skills"].get(name)
    if record is None:
        return {}, [], []
    purged: list[str] = []
    staged: list[tuple[Path, Path]] = []
    if purge:
        try:
            for item in record["owned_paths"]:
                target = Path(item["path"])
                staging = _purge_target(target, name)
                if staging is not None:
                    staged.append((target, staging))
                    purged.append(os.fspath(target))
        except Exception:
            _restore_purge_targets(staged)
            raise
    record = {
        **record,
        "installed": False,
        "units": [],
        "unit_files": [],
        "host_policy_files": [],
        "owned_paths": [] if purge else record["owned_paths"],
    }
    ledger["skills"][name] = record
    try:
        _write(path, ledger)
    except Exception as exc:
        try:
            _restore_purge_targets(staged)
        except Exception as rollback_exc:
            raise LedgerError(
                f"Skill ledger update failed and purge rollback failed: {rollback_exc}"
            ) from exc
        raise
    cleanup_pending: list[str] = []
    for _, staging in staged:
        try:
            shutil.rmtree(staging)
            parent_descriptor = os.open(
                staging.parent,
                os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0),
            )
            try:
                os.fsync(parent_descriptor)
            finally:
                os.close(parent_descriptor)
        except OSError:
            cleanup_pending.append(os.fspath(staging))
    return record, purged, cleanup_pending


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("get", "upsert", "uninstall", "list"))
    parser.add_argument("ledger")
    parser.add_argument("name", nargs="?")
    parser.add_argument("--record")
    parser.add_argument("--purge", action="store_true")
    parser.add_argument("--confirm", default="")
    arguments = parser.parse_args()
    try:
        path = Path(arguments.ledger)
        if arguments.command == "list":
            result = load(path)
        elif arguments.command == "get":
            if not arguments.name:
                raise LedgerError("Skill name is required")
            result = load(path)["skills"].get(arguments.name)
        elif arguments.command == "upsert":
            if not arguments.name or arguments.record is None:
                raise LedgerError("Skill name and record are required")
            result = upsert(path, arguments.name, arguments.record)
        else:
            if not arguments.name:
                raise LedgerError("Skill name is required")
            if arguments.purge and arguments.confirm != "PURGE_SKILL_DATA":
                raise LedgerError("purge requires confirm=PURGE_SKILL_DATA")
            record, purged, cleanup_pending = mark_uninstalled(
                path, arguments.name, purge=arguments.purge
            )
            result = {
                "record": record,
                "purged_paths": purged,
                "cleanup_pending": cleanup_pending,
            }
        print(json.dumps({"ok": True, "result": result}, ensure_ascii=False, separators=(",", ":")))
        return 0
    except (LedgerError, OSError, json.JSONDecodeError) as exc:
        print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False, separators=(",", ":")))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
