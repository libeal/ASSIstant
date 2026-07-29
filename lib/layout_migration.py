#!/usr/bin/env python3
"""Migrate and reconcile managed data/skills and data/policies overlays."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import tempfile
from datetime import datetime, timezone
from pathlib import Path

try:
    from .skill_package import SkillPackageError, load_package
except ImportError:  # Executed as a standalone migration command.
    from skill_package import SkillPackageError, load_package


MARKER_NAME = ".overlay-layout-v1.json"


class MigrationError(RuntimeError):
    pass


def _reject_json_constant(value: str) -> object:
    raise ValueError(f"non-finite JSON value is not allowed: {value}")


def _reject_duplicate_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key is not allowed: {key}")
        result[key] = value
    return result


def _strict_json_loads(raw: str) -> object:
    return json.loads(
        raw,
        object_pairs_hook=_reject_duplicate_keys,
        parse_constant=_reject_json_constant,
    )


def _fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _snapshot_target(path: Path) -> Path | None:
    if path.is_symlink():
        raise MigrationError(f"migration target must not be a symbolic link: {path}")
    if not path.exists():
        return None
    if not path.is_file():
        raise MigrationError(f"migration target must be a regular file: {path}")
    descriptor, raw_snapshot = tempfile.mkstemp(
        prefix=f".{path.name}.previous.", suffix=".tmp", dir=path.parent
    )
    snapshot = Path(raw_snapshot)
    try:
        with path.open("rb") as source, os.fdopen(descriptor, "wb") as output:
            shutil.copyfileobj(source, output)
            output.flush()
            os.fsync(output.fileno())
        os.chmod(snapshot, stat.S_IMODE(path.stat().st_mode))
        return snapshot
    except Exception:
        snapshot.unlink(missing_ok=True)
        raise


def _replace_with_recovery(temp_path: Path, target: Path) -> None:
    snapshot = _snapshot_target(target)
    replaced = False
    try:
        os.replace(temp_path, target)
        replaced = True
        _fsync_directory(target.parent)
    except Exception:
        if replaced:
            try:
                if snapshot is None:
                    target.unlink(missing_ok=True)
                else:
                    os.replace(snapshot, target)
                _fsync_directory(target.parent)
            except Exception as rollback_exc:
                if snapshot is not None and snapshot.exists():
                    raise OSError(
                        "migration persistence failed; recovery snapshot retained at "
                        f"{snapshot}"
                    ) from rollback_exc
                raise
        elif snapshot is not None:
            snapshot.unlink(missing_ok=True)
        raise
    else:
        if snapshot is not None:
            snapshot.unlink(missing_ok=True)


def _atomic_json(path: Path, payload: object, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, raw_temp = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temp_path = Path(raw_temp)
    try:
        os.fchmod(descriptor, mode)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(
                payload,
                handle,
                ensure_ascii=False,
                indent=2,
                sort_keys=True,
                allow_nan=False,
            )
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        _replace_with_recovery(temp_path, path)
    except Exception:
        temp_path.unlink(missing_ok=True)
        raise


def _assert_safe_tree(root: Path) -> None:
    if root.is_symlink() or not root.is_dir():
        raise MigrationError(f"migration source is not a regular directory: {root}")
    for current, directories, files in os.walk(root, followlinks=False):
        current_path = Path(current)
        for name in directories + files:
            path = current_path / name
            metadata = path.lstat()
            if stat.S_ISLNK(metadata.st_mode) or not (
                stat.S_ISDIR(metadata.st_mode) or stat.S_ISREG(metadata.st_mode)
            ):
                raise MigrationError(f"unsafe migration file type: {path}")


def _directory_digest(root: Path) -> str:
    _assert_safe_tree(root)
    digest = hashlib.sha256()
    for path in sorted(root.rglob("*"), key=lambda item: item.relative_to(root).as_posix()):
        relative = path.relative_to(root).as_posix().encode("utf-8")
        if path.is_dir():
            digest.update(b"D\0" + relative + b"\0")
        elif path.is_file():
            digest.update(b"F\0" + relative + b"\0")
            with path.open("rb") as handle:
                for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                    digest.update(chunk)
    return digest.hexdigest()


def _unique_conflict_path(root: Path, name: str) -> Path:
    candidate = root / name
    index = 1
    while candidate.exists() or candidate.is_symlink():
        index += 1
        candidate = root / f"{name}.{index}"
    return candidate


def _quarantine_move(source: Path, conflict_root: Path, name: str) -> Path:
    conflict_root.mkdir(parents=True, exist_ok=True)
    target = _unique_conflict_path(conflict_root, name)
    os.replace(source, target)
    _fsync_directory(source.parent)
    _fsync_directory(conflict_root)
    return target


def _previous_report(data_root: Path, marker: dict | None) -> dict | None:
    if marker is None:
        return None
    relative = marker.get("report")
    if not isinstance(relative, str) or not relative:
        return None
    candidate = data_root / relative
    try:
        candidate.resolve(strict=True).relative_to(data_root.resolve(strict=True))
    except (OSError, ValueError) as exc:
        raise MigrationError("previous migration report escapes the data root") from exc
    if candidate.is_symlink() or not candidate.is_file():
        raise MigrationError("previous migration report is unavailable")
    try:
        report = _strict_json_loads(candidate.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, ValueError) as exc:
        raise MigrationError("previous migration report is invalid") from exc
    if not isinstance(report, dict):
        raise MigrationError("previous migration report must be an object")
    return report


def _restore_reversible_conflicts(
    overlay: Path,
    builtin_names: set[str],
    data_root: Path,
    previous_report: dict | None,
    report: dict,
) -> None:
    if previous_report is None:
        return
    conflicts = previous_report.get("skill_conflicts", [])
    if not isinstance(conflicts, list):
        raise MigrationError("previous Skill conflict report is invalid")
    for item in conflicts:
        if not isinstance(item, dict) or item.get("reason") != "user_overlay_conflicts_with_builtin":
            continue
        name = item.get("name")
        relative = item.get("quarantined")
        expected_digest = item.get("sha256")
        if name in builtin_names:
            continue
        if (
            not isinstance(name, str)
            or re.fullmatch(r"[a-z0-9][a-z0-9-]*", name) is None
            or not isinstance(relative, str)
            or not isinstance(expected_digest, str)
            or re.fullmatch(r"[0-9a-f]{64}", expected_digest) is None
        ):
            raise MigrationError(
                "reversible Skill conflict lacks trusted provenance; refusing rollback"
            )
        source = data_root / relative
        try:
            source.resolve(strict=True).relative_to(data_root.resolve(strict=True))
        except (OSError, ValueError) as exc:
            raise MigrationError("quarantined Skill escapes the data root") from exc
        if source.is_symlink() or not source.is_dir():
            raise MigrationError(f"quarantined Skill is unavailable: {name}")
        actual_digest = _directory_digest(source)
        if actual_digest != expected_digest:
            raise MigrationError(f"quarantined Skill digest changed: {name}")
        target = overlay / name
        if target.exists() or target.is_symlink():
            raise MigrationError(f"restored Skill target is already occupied: {name}")
        os.replace(source, target)
        _fsync_directory(overlay)
        _fsync_directory(source.parent)
        report["skills_restored"].append(
            {"name": name, "from": relative, "sha256": expected_digest}
        )


def _migrate_skills(
    legacy_root: Path | None,
    release_root: Path,
    data_root: Path,
    conflict_root: Path,
    report: dict,
    previous_report: dict | None,
    previous_version: str,
    target_version: str,
) -> None:
    overlay = data_root / "skills"
    builtins = release_root / "skills"
    overlay.mkdir(parents=True, exist_ok=True)
    if overlay.is_symlink() or not overlay.is_dir():
        raise MigrationError("user Skill root must be a real directory")
    index_path = builtins / "INDEX.md"
    builtin_names: set[str] = set()
    if index_path.is_file() and not index_path.is_symlink():
        for line in index_path.read_text(encoding="utf-8").splitlines():
            match = re.fullmatch(r"## ([a-z0-9][a-z0-9-]*)", line)
            if match:
                builtin_names.add(match.group(1))
    _restore_reversible_conflicts(
        overlay, builtin_names, data_root, previous_report, report
    )

    legacy_skills = legacy_root / "skills" if legacy_root is not None else None
    if (
        legacy_skills is not None
        and legacy_skills.is_dir()
        and not legacy_skills.is_symlink()
    ):
        for path in sorted(legacy_skills.iterdir(), key=lambda item: item.name):
            if path.name.startswith(".") or path.name == "INDEX.md":
                continue
            report["skills_skipped"].append(
                {
                    "name": path.name,
                    "reason": "legacy_format_unsupported",
                    "source": "legacy_release",
                }
            )

    for path in sorted(overlay.iterdir(), key=lambda item: item.name):
        if path.name == "INDEX.md":
            report["skills_skipped"].append(
                {"name": "INDEX.md", "reason": "legacy_format_unsupported"}
            )
            continue
        if path.name.startswith("."):
            continue
        if not path.is_dir() or path.is_symlink():
            report["skills_skipped"].append(
                {"name": path.name, "reason": "invalid_package"}
            )
            continue
        if path.name in builtin_names:
            try:
                source_digest = _directory_digest(path)
            except MigrationError as exc:
                report["skills_skipped"].append(
                    {
                        "name": path.name,
                        "reason": "invalid_package",
                        "error": str(exc),
                    }
                )
                continue
            quarantined = _quarantine_move(path, conflict_root, path.name)
            report["skill_conflicts"].append(
                {
                    "name": path.name,
                    "reason": "user_overlay_conflicts_with_builtin",
                    "quarantined": str(quarantined.relative_to(data_root)),
                    "sha256": source_digest,
                    "source_version": previous_version,
                    "target_version": target_version,
                }
            )
            continue
        try:
            load_package(path, "user")
        except SkillPackageError as exc:
            reason = (
                "legacy_format_unsupported"
                if "legacy_format_unsupported" in str(exc)
                else "invalid_package"
            )
            report["skills_skipped"].append(
                {"name": path.name, "reason": reason, "error": str(exc)}
            )


def _valid_json_object(path: Path) -> bool:
    if path.is_symlink() or not path.is_file():
        return False
    try:
        return isinstance(_strict_json_loads(path.read_text(encoding="utf-8")), dict)
    except (OSError, UnicodeError, ValueError):
        return False


def _copy_atomic(source: Path, target: Path) -> None:
    descriptor, raw_temp = tempfile.mkstemp(prefix=f".{target.name}.", dir=target.parent)
    temp_path = Path(raw_temp)
    try:
        with source.open("rb") as input_file, os.fdopen(descriptor, "wb") as output_file:
            shutil.copyfileobj(input_file, output_file)
            output_file.flush()
            os.fsync(output_file.fileno())
        os.chmod(temp_path, 0o640)
        _replace_with_recovery(temp_path, target)
    except Exception:
        temp_path.unlink(missing_ok=True)
        raise


def _migrate_policies(
    legacy_root: Path | None, release_root: Path, data_root: Path, report: dict
) -> None:
    overlay = data_root / "policies"
    defaults = release_root / "policies"
    legacy = legacy_root / "policies" if legacy_root is not None else None
    overlay.mkdir(parents=True, exist_ok=True)
    if overlay.is_symlink() or defaults.is_symlink():
        raise MigrationError("policy roots must not be symbolic links")
    registered = {
        path.name
        for path in defaults.iterdir()
        if path.is_file() and not path.is_symlink() and path.suffix == ".json"
    }
    for path in sorted(overlay.iterdir(), key=lambda item: item.name):
        if path.name.startswith("."):
            continue
        if path.suffix == ".json" and path.name not in registered:
            report["orphaned_policies"].append(path.name)
        elif path.name in registered and not _valid_json_object(path):
            raise MigrationError(f"existing policy overlay is invalid: {path.name}")
    if legacy is None or not legacy.is_dir() or legacy.is_symlink():
        return
    for name in sorted(registered):
        target = overlay / name
        source = legacy / name
        if target.exists() or not source.exists():
            continue
        if not _valid_json_object(source):
            raise MigrationError(f"legacy policy is invalid: {name}")
        _copy_atomic(source, target)
        report["policies_migrated"].append(name)


def migrate(legacy_root: Path | None, release_root: Path, data_root: Path, version: str) -> dict:
    marker = data_root / MARKER_NAME
    previous_marker = None
    if marker.is_symlink():
        raise MigrationError("overlay layout marker must not be a symbolic link")
    if marker.exists():
        try:
            previous_marker = _strict_json_loads(marker.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, ValueError) as exc:
            raise MigrationError(f"overlay layout marker is invalid: {exc}") from exc
        if (
            not isinstance(previous_marker, dict)
            or previous_marker.get("schema_version") != 1
        ):
            raise MigrationError("overlay layout marker has an unsupported schema")
        if previous_marker.get("target_version") == version:
            return {"ok": True, "status": "already_migrated", "marker": str(marker)}

    timestamp = datetime.now(timezone.utc).replace(microsecond=0).isoformat()
    safe_version = "".join(ch if ch.isalnum() or ch in "._-" else "_" for ch in version)
    previous_report = _previous_report(data_root, previous_marker)
    conflict_root = data_root / "migration-conflicts" / safe_version / "skills"
    initial_migration = previous_marker is None
    report = {
        "schema_version": 1,
        "status": "completed" if initial_migration else "reconciled",
        "migrated_at": timestamp,
        "target_version": version,
        "previous_version": (
            "" if previous_marker is None else str(previous_marker.get("target_version", ""))
        ),
        "legacy_root": str(legacy_root) if legacy_root is not None else "",
        "skills_migrated": [],
        "skills_restored": [],
        "skills_skipped": [],
        "skill_conflicts": [],
        "policies_migrated": [],
        "orphaned_policies": [],
    }
    # Legacy release contents are imported only once. On later upgrades the old
    # release may contain built-ins removed by the new release; importing those
    # as user Skills would silently change their trust class.
    import_root = legacy_root if initial_migration else None
    _migrate_skills(
        import_root,
        release_root,
        data_root,
        conflict_root,
        report,
        previous_report,
        report["previous_version"],
        version,
    )
    _migrate_policies(import_root, release_root, data_root, report)

    reports = data_root / "migration-reports"
    report_path = reports / f"overlay-layout-v1-{safe_version}.json"
    _atomic_json(report_path, report, 0o640)
    marker_payload = {
        "schema_version": 1,
        "layout": "managed-overlays-v1",
        "migrated_at": timestamp,
        "target_version": version,
        "report": str(report_path.relative_to(data_root)),
    }
    _atomic_json(marker, marker_payload, 0o644)
    return {
        "ok": True,
        "status": "migrated" if initial_migration else "reconciled",
        "marker": str(marker),
        "report": str(report_path),
        "summary": report,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--legacy-root", default="")
    parser.add_argument("--release-root", required=True)
    parser.add_argument("--data-root", required=True)
    parser.add_argument("--version", required=True)
    arguments = parser.parse_args()
    legacy = Path(arguments.legacy_root).resolve() if arguments.legacy_root else None
    release = Path(arguments.release_root).resolve()
    data = Path(arguments.data_root).resolve()
    try:
        result = migrate(legacy, release, data, arguments.version)
    except (MigrationError, OSError, ValueError) as exc:
        print(json.dumps({"ok": False, "status": "migration_failed", "error": str(exc)}))
        return 1
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
