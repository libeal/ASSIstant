#!/usr/bin/env python3
"""Transactional local lifecycle operations for Agent Skill packages."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import secrets
import shutil
import stat
import tarfile
import tempfile
from contextlib import contextmanager
from pathlib import Path, PurePosixPath

from skill_package import (
    NAME_PATTERN,
    SkillPackageError,
    SkillPackageIncompatibleError,
    load_index,
    load_package,
)


MAX_ARCHIVE_MEMBERS = 10_000
MAX_ARCHIVE_FILE = 32 * 1024 * 1024
MAX_ARCHIVE_TOTAL = 128 * 1024 * 1024
MAX_READ_BYTES = 256 * 1024


class LifecycleError(ValueError):
    """Raised when a lifecycle request cannot be completed safely."""


def _fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _safe_root(root: Path, *, create: bool) -> Path:
    absolute = Path(os.path.abspath(root))
    current = Path(absolute.anchor)
    for component in absolute.parts[1:]:
        current /= component
        if current.exists() or current.is_symlink():
            metadata = current.lstat()
            if stat.S_ISLNK(metadata.st_mode):
                raise LifecycleError(f"Skill root contains a symbolic link: {current}")
            if current != absolute and not stat.S_ISDIR(metadata.st_mode):
                raise LifecycleError(f"Skill root parent is not a directory: {current}")
    if create:
        absolute.mkdir(parents=True, exist_ok=True)
    elif not absolute.exists():
        raise LifecycleError("Skill root is unavailable")
    if absolute.is_symlink() or not absolute.is_dir():
        raise LifecycleError("Skill root must be a real directory")
    return absolute


@contextmanager
def _skill_lock(root: Path, name: str):
    lock_root = root / ".locks"
    if lock_root.is_symlink() or (lock_root.exists() and not lock_root.is_dir()):
        raise LifecycleError("Skill lock root is unsafe")
    lock_root.mkdir(mode=0o700, exist_ok=True)
    lock_root.chmod(0o700)
    descriptor = os.open(
        lock_root / f"{name}.lock",
        os.O_RDWR
        | os.O_CREAT
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0),
        0o600,
    )
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise LifecycleError("Skill lock is not a regular file")
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield
    finally:
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)


def _extract_archive(source: Path, staging: Path) -> Path:
    total = 0
    with tarfile.open(source, "r:gz") as archive:
        members = archive.getmembers()
        if not members or len(members) > MAX_ARCHIVE_MEMBERS:
            raise LifecycleError("Skill archive member count is invalid")
        seen: set[str] = set()
        for member in members:
            path = PurePosixPath(member.name)
            if path.is_absolute() or not path.parts or ".." in path.parts:
                raise LifecycleError("Skill archive contains an unsafe path")
            normalized = "/".join(part for part in path.parts if part not in {"", "."})
            if not normalized or normalized in seen:
                raise LifecycleError("Skill archive contains a duplicate path")
            seen.add(normalized)
            if not (member.isdir() or member.isfile()):
                raise LifecycleError("Skill archive may contain only files and directories")
            if member.isfile():
                if member.size > MAX_ARCHIVE_FILE:
                    raise LifecycleError("Skill archive contains an oversized file")
                total += member.size
                if total > MAX_ARCHIVE_TOTAL:
                    raise LifecycleError("Skill archive expands beyond the allowed size")
        for member in members:
            path = PurePosixPath(member.name)
            target = staging.joinpath(*(part for part in path.parts if part not in {"", "."}))
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            source_file = archive.extractfile(member)
            if source_file is None:
                raise LifecycleError("Skill archive member cannot be read")
            descriptor = os.open(
                target,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0),
                member.mode & 0o755 or 0o600,
            )
            with source_file, os.fdopen(descriptor, "wb") as output:
                shutil.copyfileobj(source_file, output, length=1024 * 1024)
                output.flush()
                os.fsync(output.fileno())
    candidates = [path for path in staging.iterdir() if path.name != "skills"]
    skills_parent = staging / "skills"
    if skills_parent.is_dir() and not candidates:
        candidates = list(skills_parent.iterdir())
    candidates = [path for path in candidates if path.is_dir() and not path.is_symlink()]
    if len(candidates) != 1:
        raise LifecycleError("Skill archive must contain exactly one package")
    return candidates[0]


def _reserved_names(index_path: Path | None) -> set[str]:
    if index_path is None:
        return set()
    try:
        return set(load_index(index_path))
    except SkillPackageError as exc:
        raise LifecycleError(f"builtin Skill catalog is invalid: {exc}") from exc


def _normalize_package_permissions(package: Path) -> None:
    for path in sorted(package.rglob("*")):
        if path.is_dir():
            path.chmod(0o750)
        elif path.is_file():
            path.chmod(0o750 if path.parent.name == "scripts" else 0o640)
    package.chmod(0o750)


def _fsync_tree(package: Path) -> None:
    directories = [package]
    for path in sorted(package.rglob("*")):
        if path.is_file():
            descriptor = os.open(
                path,
                os.O_RDONLY
                | getattr(os, "O_CLOEXEC", 0)
                | getattr(os, "O_NOFOLLOW", 0),
            )
            try:
                if not stat.S_ISREG(os.fstat(descriptor).st_mode):
                    raise LifecycleError("Skill package contains an unsafe file")
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
        elif path.is_dir():
            directories.append(path)
        else:
            raise LifecycleError("Skill package contains an unsafe file type")
    for directory in reversed(directories):
        _fsync_directory(directory)


def install(
    source: Path,
    target_root: Path,
    origin: str,
    index_path: Path | None,
    *,
    replace: bool = False,
) -> dict:
    target_root = _safe_root(target_root, create=True)
    if source.is_symlink() or not source.exists():
        raise LifecycleError("Skill install source is unavailable")
    staging_root = Path(tempfile.mkdtemp(prefix=".install.", dir=target_root))
    staged_package: Path | None = None
    try:
        if source.is_dir():
            staged_package = staging_root / source.name
            # Preserve links so the package validator can reject them. Following
            # a source link here could smuggle files from outside the package.
            shutil.copytree(source, staged_package, symlinks=True)
        elif source.is_file() and source.name.endswith((".tar.gz", ".tgz")):
            staged_package = _extract_archive(source, staging_root)
        else:
            raise LifecycleError("Skill install source must be a directory or .tar.gz archive")
        loaded = load_package(staged_package, origin)
        name = loaded["name"]
        if origin == "user" and name in _reserved_names(index_path):
            raise LifecycleError("Skill name is reserved by the builtin catalog")
        target = target_root / name
        with _skill_lock(target_root, name):
            if target.exists() or target.is_symlink():
                if not replace:
                    raise LifecycleError("Skill is already installed")
                if target.is_symlink() or not target.is_dir():
                    raise LifecycleError("Installed Skill target is unsafe")
            _normalize_package_permissions(staged_package)
            _fsync_tree(staged_package)
            backup = target_root / f".replaced.{name}.{secrets.token_hex(16)}"
            if backup.exists() or backup.is_symlink():
                raise LifecycleError("Skill replacement backup path is occupied")
            replaced = target.is_dir()
            try:
                if replaced:
                    os.rename(target, backup)
                    _fsync_directory(target_root)
                os.rename(staged_package, target)
                _fsync_directory(target_root)
            except Exception as exc:
                try:
                    if target.is_dir() and not target.is_symlink():
                        if staged_package.exists() or staged_package.is_symlink():
                            raise LifecycleError(
                                "Skill install rollback staging is occupied"
                            )
                        os.rename(target, staged_package)
                    if replaced:
                        if not backup.is_dir() or backup.is_symlink() or target.exists():
                            raise LifecycleError(
                                "Skill replacement backup is unavailable during rollback"
                            )
                        os.rename(backup, target)
                    _fsync_directory(target_root)
                except Exception as rollback_exc:
                    raise LifecycleError(
                        f"Skill installation failed and rollback failed: {rollback_exc}"
                    ) from exc
                raise
            warning = ""
            cleanup_pending: list[str] = []
            if replaced:
                try:
                    shutil.rmtree(backup)
                    _fsync_directory(target_root)
                except OSError:
                    warning = "replacement_cleanup_pending"
                    if backup.exists():
                        cleanup_pending.append(os.fspath(backup))
        return {
            "ok": True,
            "status": "replaced" if replaced else "installed",
            "skill": name,
            "scope": origin,
            "path": os.fspath(target),
            "replaced": replaced,
            **({"warning": warning} if warning else {}),
            **({"cleanup_pending": cleanup_pending} if cleanup_pending else {}),
        }
    finally:
        shutil.rmtree(staging_root, ignore_errors=True)


def uninstall(name: str, target_root: Path, origin: str, purge: bool) -> dict:
    if NAME_PATTERN.fullmatch(name) is None:
        raise LifecycleError("Skill name is invalid")
    target_root = _safe_root(target_root, create=False)
    target = target_root / name
    with _skill_lock(target_root, name):
        if target.is_symlink() or not target.is_dir():
            raise LifecycleError("Skill is not installed")
        removed = target_root / f".removed.{name}.{secrets.token_hex(16)}"
        if removed.exists() or removed.is_symlink():
            raise LifecycleError("Skill uninstall staging path is occupied")
        os.rename(target, removed)
        try:
            _fsync_directory(target_root)
        except Exception as exc:
            try:
                if target.exists() or target.is_symlink():
                    raise LifecycleError("Skill uninstall rollback target is occupied")
                if not removed.is_dir() or removed.is_symlink():
                    raise LifecycleError("Skill uninstall rollback staging is unavailable")
                os.rename(removed, target)
                _fsync_directory(target_root)
            except Exception as rollback_exc:
                raise LifecycleError(
                    f"Skill uninstall failed and rollback failed: {rollback_exc}"
                ) from exc
            raise
        warning = ""
        cleanup_pending: list[str] = []
        try:
            shutil.rmtree(removed)
            _fsync_directory(target_root)
        except OSError:
            warning = "uninstall_cleanup_pending"
            if removed.exists():
                cleanup_pending.append(os.fspath(removed))
    return {
        "ok": True,
        "status": "uninstalled",
        "skill": name,
        "scope": origin,
        "purged": purge,
        "purged_paths": [],
        **({"warning": warning} if warning else {}),
        **({"cleanup_pending": cleanup_pending} if cleanup_pending else {}),
    }


def read_package_file(package: Path, relative: str, origin: str) -> dict:
    loaded = load_package(package, origin)
    path = PurePosixPath(relative)
    if path.as_posix() == "SKILL.md":
        pass
    elif len(path.parts) < 2 or path.parts[0] != "references":
        raise LifecycleError("only SKILL.md and package references may be read")
    if path.is_absolute() or any(part in {"", ".", ".."} for part in path.parts):
        raise LifecycleError("Skill read path is invalid")
    target = package.joinpath(*path.parts)
    try:
        target.resolve(strict=True).relative_to(package.resolve(strict=True))
    except (OSError, ValueError) as exc:
        raise LifecycleError("Skill read path escapes the package") from exc
    if target.is_symlink() or not target.is_file() or target.stat().st_size > MAX_READ_BYTES:
        raise LifecycleError("Skill read target is unavailable or too large")
    try:
        content = target.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        raise LifecycleError("Skill read target must be UTF-8 text") from exc
    return {
        "ok": True,
        "status": "read",
        "skill": loaded["name"],
        "path": path.as_posix(),
        "content": content,
        "content_sha256": hashlib.sha256(content.encode("utf-8")).hexdigest(),
        "source_path": os.fspath(target.resolve(strict=True)),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("install", "uninstall", "read"))
    parser.add_argument("subject")
    parser.add_argument("--root", required=True)
    parser.add_argument("--origin", choices=("builtin", "user"), required=True)
    parser.add_argument("--index")
    parser.add_argument("--path", default="SKILL.md")
    parser.add_argument("--purge", action="store_true")
    parser.add_argument("--replace", action="store_true")
    arguments = parser.parse_args()
    try:
        if arguments.command == "install":
            result = install(
                Path(arguments.subject),
                Path(arguments.root),
                arguments.origin,
                Path(arguments.index) if arguments.index else None,
                replace=arguments.replace,
            )
        elif arguments.command == "uninstall":
            result = uninstall(
                arguments.subject, Path(arguments.root), arguments.origin, arguments.purge
            )
        else:
            result = read_package_file(
                Path(arguments.subject), arguments.path, arguments.origin
            )
    except (LifecycleError, SkillPackageError, OSError, tarfile.TarError) as exc:
        if isinstance(exc, SkillPackageIncompatibleError):
            code = "skill_package_incompatible"
        elif "legacy_format_unsupported" in str(exc):
            code = "legacy_format_unsupported"
        else:
            code = "skill_operation_failed"
        result = {
            "ok": False,
            "status": code,
            "code": code,
            "error": str(exc),
        }
    print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
