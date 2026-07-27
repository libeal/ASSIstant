#!/usr/bin/env python3
"""Validate/extract runtime archives and merge their redacted configuration."""

from __future__ import annotations

import hashlib
import fcntl
import json
import os
import re
import shutil
import stat
import sys
import tarfile
from contextlib import ExitStack, contextmanager
from pathlib import Path, PurePosixPath


MAX_ARCHIVE_BYTES = 512 * 1024 * 1024
MAX_MEMBER_BYTES = 128 * 1024 * 1024
MAX_EXPANDED_BYTES = 1024 * 1024 * 1024
MAX_MEMBERS = 100_000
ALLOWED_TOP_LEVEL = frozenset({"config", "logs", "manifest.json", "policies", "reports", "skills"})
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
AUDIT_FILE_PATTERN = re.compile(r"^[A-Za-z0-9._-]+\.jsonl(?:\.[1-9][0-9]*)?$")
POLICY_FILE_PATTERN = re.compile(r"^[a-z0-9][a-z0-9-]*\.json$")
SENSITIVE_KEY_PATTERN = re.compile(
    r"(api[_-]?key|token|password|passwd|secret|authorization|cookie|credential|private[_-]?key)",
    re.IGNORECASE,
)
RELEASE_COMPONENTS = (
    "bin",
    "lib",
    "mcp",
    "packaging",
    "policies",
    "prompts",
    "remote",
    "schema",
    "scripts",
    "skills",
    "web",
)


class ArchiveError(RuntimeError):
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


def _safe_parts(name: str) -> tuple[str, ...]:
    path = PurePosixPath(name)
    if path.is_absolute() or ".." in path.parts:
        raise ArchiveError(f"unsafe archive path: {name}")
    parts = tuple(part for part in path.parts if part not in ("", "."))
    if not parts or parts[0] not in ALLOWED_TOP_LEVEL:
        raise ArchiveError(f"archive path is outside the runtime contract: {name}")
    return parts


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _fingerprint_tree(
    digest: "hashlib._Hash",
    root: Path,
    *,
    prefix: str = "",
    ignored_relative_paths: frozenset[str] = frozenset(),
) -> None:
    for child in sorted(root.rglob("*"), key=lambda item: item.relative_to(root).as_posix()):
        relative_text = child.relative_to(root).as_posix()
        qualified_text = f"{prefix}/{relative_text}" if prefix else relative_text
        if qualified_text in ignored_relative_paths:
            continue
        if any(
            qualified_text.startswith(f"{ignored}/")
            for ignored in ignored_relative_paths
        ):
            continue
        if child.is_symlink():
            raise ArchiveError(f"runtime fingerprint contains a symbolic link: {child}")
        relative = qualified_text.encode("utf-8")
        if child.is_dir():
            digest.update(b"D\0" + relative + b"\0")
        elif child.is_file():
            digest.update(
                b"F\0"
                + relative
                + b"\0"
                + _sha256(child).encode("ascii")
                + b"\0"
            )
        else:
            raise ArchiveError(f"runtime fingerprint contains an unsafe file: {child}")


def _fingerprint_release(digest: "hashlib._Hash", release: Path) -> None:
    """Fingerprint immutable release inputs without following runtime mounts."""

    try:
        release = release.resolve(strict=True)
    except OSError as exc:
        raise ArchiveError("runtime fingerprint target is unavailable: release") from exc
    if not release.is_dir():
        raise ArchiveError("runtime fingerprint target is unavailable: release")
    found_component = False
    for component_name in RELEASE_COMPONENTS:
        component = release / component_name
        if not component.exists() and not component.is_symlink():
            continue
        found_component = True
        if component.is_symlink() or not component.is_dir():
            raise ArchiveError(
                f"runtime release component has an unsafe type: {component_name}"
            )
        digest.update(b"D\0" + component_name.encode("utf-8") + b"\0")
        _fingerprint_tree(digest, component, prefix=component_name)

    config = release / "config"
    if config.exists() and not config.is_symlink():
        if not config.is_dir():
            raise ArchiveError("runtime release component has an unsafe type: config")
        found_component = True
        digest.update(b"D\0config\0")
        _fingerprint_tree(
            digest,
            config,
            prefix="config",
            ignored_relative_paths=frozenset({"config/config.json"}),
        )
    elif config.is_symlink():
        # Managed releases deliberately link this entire component to the
        # persistent data tree; current config is fingerprinted independently.
        digest.update(b"M\0config\0")
    if not found_component:
        raise ArchiveError("runtime release contains no authoritative components")


def runtime_fingerprint(release: Path, config: Path, skills: Path, policies: Path) -> str:
    """Return a content identity for every replaceable restore domain."""

    digest = hashlib.sha256()
    for label, path in (
        ("release", release),
        ("config", config),
        ("skills", skills),
        ("policies", policies),
    ):
        if label == "release":
            digest.update(b"release\0")
            _fingerprint_release(digest, path)
            continue
        if path.is_symlink():
            raise ArchiveError(f"runtime fingerprint target is unavailable: {label}")
        if not path.exists():
            if label in {"skills", "policies"}:
                digest.update(b"N\0")
                continue
            raise ArchiveError(f"runtime fingerprint target is unavailable: {label}")
        digest.update(label.encode("utf-8") + b"\0")
        if path.is_file():
            digest.update(b"F\0" + _sha256(path).encode("ascii") + b"\0")
            continue
        if not path.is_dir():
            raise ArchiveError(f"runtime fingerprint target has an unsafe type: {label}")
        _fingerprint_tree(digest, path)
    return digest.hexdigest()


def build_manifest(
    stage_root: Path,
    output_path: Path,
    exported_at: str,
    release_version: str,
    storage_backend: str,
    managed: bool,
) -> int:
    """Build a deterministic inventory in one pass without argv-sized JSON."""

    if stage_root.is_symlink() or not stage_root.is_dir():
        raise ArchiveError("backup stage root must be a regular directory")
    if output_path.parent != stage_root or output_path.name != "manifest.json":
        raise ArchiveError("backup manifest target is outside the stage root")
    if output_path.exists() or output_path.is_symlink():
        raise ArchiveError("backup manifest target already exists")
    records = []
    for path in sorted(stage_root.rglob("*"), key=lambda item: item.relative_to(stage_root).as_posix()):
        if path == output_path:
            continue
        if path.is_symlink():
            raise ArchiveError(f"backup inventory contains an unsafe file: {path}")
        if path.is_dir():
            continue
        if not path.is_file():
            raise ArchiveError(f"backup inventory contains an unsafe file: {path}")
        relative = path.relative_to(stage_root).as_posix()
        records.append(
            {
                "path": relative,
                "sha256": _sha256(path),
                "size_bytes": path.stat().st_size,
            }
        )
        if len(records) > MAX_MEMBERS:
            raise ArchiveError("backup inventory exceeds the archive member limit")
    payload = {
        "schema_version": 2,
        "exported_at": exported_at,
        "release_version": release_version,
        "storage_backend": storage_backend,
        "managed": managed,
        "redacted": True,
        "contents": {
            "user_skills": True,
            "effective_policies": True,
            "audit_chain_with_rotations": True,
        },
        "files": records,
    }
    descriptor = os.open(
        output_path,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0),
        0o600,
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, ensure_ascii=False, sort_keys=True, indent=2, allow_nan=False)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        _fsync_directory(stage_root)
    except Exception:
        output_path.unlink(missing_ok=True)
        raise
    return len(records)


def build_user_skill_index(skills_root: Path, output_path: Path) -> int:
    """Build a portable INDEX.md from only the user Skills in an archive."""

    if skills_root.is_symlink() or not skills_root.is_dir():
        raise ArchiveError("backup Skill root must be a regular directory")
    if output_path.parent != skills_root or output_path.name != "INDEX.md":
        raise ArchiveError("backup Skill index target is outside the Skill root")
    if output_path.exists() or output_path.is_symlink():
        raise ArchiveError("backup Skill index target already exists")
    manifests: list[tuple[str, str, list[str]]] = []
    for package in sorted(skills_root.iterdir(), key=lambda item: item.name):
        if package.name.startswith(".") or package.name in {"INDEX.md", "materialized.json"}:
            continue
        if package.is_symlink() or not package.is_dir():
            raise ArchiveError(f"backup Skill package has an unsafe type: {package.name}")
        manifest_path = package / "manifest.json"
        if (
            manifest_path.is_symlink()
            or not manifest_path.is_file()
            or manifest_path.stat().st_size > 1_048_576
        ):
            raise ArchiveError(f"backup Skill manifest is unavailable: {package.name}")
        try:
            manifest = _strict_json_loads(manifest_path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, ValueError) as exc:
            raise ArchiveError(f"backup Skill manifest is invalid: {package.name}") from exc
        if (
            not isinstance(manifest, dict)
            or manifest.get("schema_version") != 1
            or manifest.get("name") != package.name
            or not isinstance(manifest.get("description"), str)
            or not manifest["description"].strip()
            or not isinstance(manifest.get("scripts"), list)
            or not manifest["scripts"]
        ):
            raise ArchiveError(f"backup Skill manifest contract is invalid: {package.name}")
        script_names: list[str] = []
        for entry in manifest["scripts"]:
            if not isinstance(entry, dict):
                raise ArchiveError(f"backup Skill script contract is invalid: {package.name}")
            script_name = entry.get("name")
            if (
                not isinstance(script_name, str)
                or re.fullmatch(r"[a-z0-9][a-z0-9-]*\.sh", script_name) is None
                or script_name in script_names
            ):
                raise ArchiveError(f"backup Skill script name is invalid: {package.name}")
            if (
                entry.get("risk") not in {"low", "medium", "high", "critical"}
                or entry.get("execution_class") != "runner"
                or entry.get("capability") != ""
            ):
                raise ArchiveError(f"backup Skill script contract is invalid: {package.name}")
            script_names.append(script_name)
        scripts_root = package / "scripts"
        if scripts_root.is_symlink() or not scripts_root.is_dir():
            raise ArchiveError(f"backup Skill scripts are unavailable: {package.name}")
        actual_scripts = sorted(
            child.name
            for child in scripts_root.iterdir()
            if child.is_file() and not child.is_symlink() and child.suffix == ".sh"
        )
        if sorted(script_names) != actual_scripts:
            raise ArchiveError(f"backup Skill scripts do not match its manifest: {package.name}")
        skill_markdown = package / "SKILL.md"
        if (
            skill_markdown.is_symlink()
            or not skill_markdown.is_file()
            or skill_markdown.stat().st_size > 1_048_576
        ):
            raise ArchiveError(f"backup Skill documentation is unavailable: {package.name}")
        documentation = skill_markdown.read_text(encoding="utf-8")
        for script_name in script_names:
            reference = f"`{package.name}/{Path(script_name).stem}`"
            if reference not in documentation:
                raise ArchiveError(
                    f"backup Skill documentation omits a manifest script: {reference}"
                )
        description = re.sub(r"\s+", " ", manifest["description"].strip()).replace(
            "`", "'"
        )
        manifests.append((package.name, description, script_names))

    lines = [
        "# User Skill Index",
        "",
        "This file is generated from the archived user Skill manifests.",
        "",
    ]
    for name, description, scripts in manifests:
        lines.extend((f"## {name}", ""))
        for script_name in scripts:
            lines.append(f"- `{name}/{Path(script_name).stem}`: {description}")
        lines.append("")
    descriptor = os.open(
        output_path,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0),
        0o600,
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write("\n".join(lines))
            handle.flush()
            os.fsync(handle.fileno())
        _fsync_directory(skills_root)
    except Exception:
        output_path.unlink(missing_ok=True)
        raise
    return len(manifests)


def _fsync_directory(path: Path) -> None:
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
    descriptor = os.open(path, flags)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def extract_verified(archive_path: Path, destination: Path) -> dict:
    if archive_path.is_symlink() or not archive_path.is_file():
        raise ArchiveError("runtime archive must be a regular file")
    if archive_path.stat().st_size > MAX_ARCHIVE_BYTES:
        raise ArchiveError("runtime archive exceeds 512 MiB")
    if destination.is_symlink() or not destination.is_dir():
        raise ArchiveError("runtime archive destination must be a regular directory")
    if any(destination.iterdir()):
        raise ArchiveError("runtime archive destination must be empty")

    seen: set[str] = set()
    expanded = 0
    with tarfile.open(archive_path, "r:gz") as archive:
        members = archive.getmembers()
        if not members or len(members) > MAX_MEMBERS:
            raise ArchiveError("runtime archive member count is invalid")
        for member in members:
            parts = _safe_parts(member.name)
            normalized = "/".join(parts)
            if normalized in seen:
                raise ArchiveError(f"duplicate archive path: {normalized}")
            seen.add(normalized)
            if not (member.isdir() or member.isfile()):
                raise ArchiveError(f"unsupported archive member type: {normalized}")
            if member.size < 0 or member.size > MAX_MEMBER_BYTES:
                raise ArchiveError(f"archive member is too large: {normalized}")
            expanded += member.size
            if expanded > MAX_EXPANDED_BYTES:
                raise ArchiveError("runtime archive expands beyond 1 GiB")

        for member in members:
            parts = _safe_parts(member.name)
            target = destination.joinpath(*parts)
            try:
                target.relative_to(destination)
            except ValueError as exc:
                raise ArchiveError("archive extraction escaped its destination") from exc
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
                target.chmod(0o700)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            source = archive.extractfile(member)
            if source is None:
                raise ArchiveError(f"could not read archive member: {member.name}")
            descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            try:
                with os.fdopen(descriptor, "wb") as output:
                    remaining = member.size
                    while remaining:
                        chunk = source.read(min(1024 * 1024, remaining))
                        if not chunk:
                            raise ArchiveError(f"truncated archive member: {member.name}")
                        output.write(chunk)
                        remaining -= len(chunk)
                    output.flush()
                    os.fsync(output.fileno())
            finally:
                source.close()

    manifest_path = destination / "manifest.json"
    try:
        manifest = _strict_json_loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, ValueError) as exc:
        raise ArchiveError(f"runtime archive manifest is invalid: {exc}") from exc
    if not isinstance(manifest, dict) or manifest.get("schema_version") != 2:
        raise ArchiveError("runtime archive manifest schema is unsupported")
    if manifest.get("redacted") is not True:
        raise ArchiveError("runtime archive must contain redacted data")
    contents = manifest.get("contents")
    if not isinstance(contents, dict) or any(
        contents.get(name) is not True
        for name in ("user_skills", "effective_policies", "audit_chain_with_rotations")
    ):
        raise ArchiveError("runtime archive contents declaration is invalid")
    records = manifest.get("files")
    if not isinstance(records, list) or not records:
        raise ArchiveError("runtime archive manifest has no file inventory")
    expected = {}
    for record in records:
        if not isinstance(record, dict):
            raise ArchiveError("runtime archive file record is invalid")
        path = record.get("path")
        digest = record.get("sha256")
        size = record.get("size_bytes")
        if not isinstance(path, str) or path == "manifest.json":
            raise ArchiveError("runtime archive file path is invalid")
        normalized = "/".join(_safe_parts(path))
        if normalized != path or normalized in expected:
            raise ArchiveError("runtime archive file inventory is ambiguous")
        if not isinstance(digest, str) or SHA256_PATTERN.fullmatch(digest) is None:
            raise ArchiveError(f"runtime archive digest is invalid: {path}")
        if isinstance(size, bool) or not isinstance(size, int) or size < 0:
            raise ArchiveError(f"runtime archive size is invalid: {path}")
        expected[path] = (digest, size)

    actual = {
        path.relative_to(destination).as_posix(): path
        for path in destination.rglob("*")
        if path.is_file() and path != manifest_path
    }
    if set(expected) != set(actual):
        raise ArchiveError("runtime archive file inventory does not match its contents")
    for relative, path in actual.items():
        digest, size = expected[relative]
        if path.stat().st_size != size or _sha256(path) != digest:
            raise ArchiveError(f"runtime archive integrity check failed: {relative}")

    required = destination / "config" / "config.redacted.json"
    if not required.is_file() or required.is_symlink():
        raise ArchiveError("runtime archive is missing redacted configuration")
    for directory_name in ("logs", "policies", "skills"):
        directory = destination / directory_name
        if not directory.is_dir() or directory.is_symlink():
            raise ArchiveError(f"runtime archive is missing {directory_name}/")
    for path in (destination / "logs").rglob("*"):
        if not path.is_file() or path.parent != destination / "logs":
            raise ArchiveError("runtime archive audit files must be regular direct children")
        if AUDIT_FILE_PATTERN.fullmatch(path.name) is None:
            raise ArchiveError(f"runtime archive audit filename is invalid: {path.name}")
    live_audits = {
        path.name
        for path in (destination / "logs").iterdir()
        if path.is_file() and path.name.endswith(".jsonl")
    }
    for path in (destination / "logs").iterdir():
        if path.is_file() and ".jsonl." in path.name:
            live_name = path.name.split(".jsonl.", 1)[0] + ".jsonl"
            if live_name not in live_audits:
                raise ArchiveError(f"runtime archive rotation has no live audit file: {path.name}")
    for path in (destination / "policies").rglob("*"):
        if (
            not path.is_file()
            or path.parent != destination / "policies"
            or POLICY_FILE_PATTERN.fullmatch(path.name) is None
        ):
            raise ArchiveError("runtime archive policy files must be registered JSON names")
    for required_skill_file in ("INDEX.md", "materialized.json"):
        path = destination / "skills" / required_skill_file
        if not path.is_file() or path.is_symlink():
            raise ArchiveError(f"runtime archive is missing skills/{required_skill_file}")
    return manifest


def _contains_redaction(value: object) -> bool:
    if isinstance(value, str):
        return "[REDACTED" in value
    if isinstance(value, list):
        return any(_contains_redaction(item) for item in value)
    if isinstance(value, dict):
        return any(_contains_redaction(item) for item in value.values())
    return False


def _merge_value(current: object, restored: object, key: str = "") -> object:
    if SENSITIVE_KEY_PATTERN.search(key):
        return current
    if isinstance(current, dict) and isinstance(restored, dict):
        merged = dict(current)
        for child_key, child_value in restored.items():
            if child_key in current:
                merged[child_key] = _merge_value(
                    current[child_key], child_value, str(child_key)
                )
            elif not SENSITIVE_KEY_PATTERN.search(str(child_key)):
                if isinstance(child_value, dict):
                    merged[child_key] = _merge_value({}, child_value, str(child_key))
                elif not _contains_redaction(child_value):
                    merged[child_key] = child_value
        return merged
    if _contains_redaction(restored):
        return current
    return restored


def merge_config(current_path: Path, restored_path: Path, output_path: Path) -> None:
    try:
        current = _strict_json_loads(current_path.read_text(encoding="utf-8"))
        restored = _strict_json_loads(restored_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, ValueError) as exc:
        raise ArchiveError(f"configuration JSON is invalid: {exc}") from exc
    if not isinstance(current, dict) or not isinstance(restored, dict):
        raise ArchiveError("configuration JSON must be an object")
    merged = _merge_value(current, restored)
    with output_path.open("x", encoding="utf-8") as handle:
        json.dump(
            merged,
            handle,
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
            allow_nan=False,
        )
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    output_path.chmod(0o600)


def _copy_tree_safe(source: Path, destination: Path) -> None:
    if source.is_symlink() or not source.is_dir():
        raise ArchiveError(f"restore source directory is invalid: {source}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(source, destination, symlinks=False)


def _set_tree_mode(root: Path, directory_mode: int, file_mode: int) -> None:
    for path in root.rglob("*"):
        if path.is_symlink():
            raise ArchiveError(f"restore tree contains a symbolic link: {path}")
        if path.is_dir():
            path.chmod(directory_mode)
        elif path.is_file():
            path.chmod(file_mode)
        else:
            raise ArchiveError(f"restore tree contains an unsupported file: {path}")
    root.chmod(directory_mode)


def _set_tree_owner(root: Path, uid: int, gid: int) -> None:
    if os.geteuid() != 0:
        return
    for path in root.rglob("*"):
        os.chown(path, uid, gid, follow_symlinks=False)
    os.chown(root, uid, gid)


@contextmanager
def _exclusive_file_lock(
    path: Path,
    mode: int = 0o600,
    new_owner: tuple[int, int] | None = None,
):
    if path.is_symlink():
        raise ArchiveError(f"restore lock must not be a symbolic link: {path}")
    flags = os.O_RDWR | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    created = False
    try:
        descriptor = os.open(path, flags | os.O_CREAT | os.O_EXCL, mode)
        created = True
    except FileExistsError:
        descriptor = os.open(path, flags)
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise ArchiveError(f"restore lock must be a regular file: {path}")
        if created:
            os.fchmod(descriptor, mode)
            if os.geteuid() == 0 and new_owner is not None:
                os.fchown(descriptor, *new_owner)
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield
    finally:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
        finally:
            os.close(descriptor)


def commit_restore(
    candidate_skills: Path,
    candidate_policies: Path,
    archived_logs: Path,
    target_skills: Path,
    target_policies: Path,
    target_logs: Path,
    merged_config: Path,
    target_config: Path,
    managed: bool,
) -> str | None:
    """Commit validated overlay trees and non-conflicting audit files atomically."""

    for target in (target_skills, target_policies, target_logs, target_config.parent):
        if target.is_symlink():
            raise ArchiveError(f"restore target must not be a symbolic link: {target}")
    if managed and (not target_skills.is_dir() or not target_policies.is_dir()):
        raise ArchiveError("managed runtime overlay directories are unavailable")
    target_skills.mkdir(parents=True, exist_ok=True)
    target_policies.mkdir(parents=True, exist_ok=True)
    target_logs.mkdir(parents=True, exist_ok=True)
    if target_config.is_symlink() or not target_config.is_file():
        raise ArchiveError(f"restore config target is invalid: {target_config}")
    if managed and os.geteuid() != 0:
        raise ArchiveError("managed runtime restore requires a local administrator")
    skills_owner = target_skills.stat()
    policies_owner = target_policies.stat()
    logs_owner = target_logs.stat()
    config_owner = target_config.stat()

    archived_files: list[Path] = []
    for source in sorted(archived_logs.rglob("*")):
        if not source.is_file():
            continue
        relative = source.relative_to(archived_logs)
        if relative.name.endswith(".lock"):
            continue
        archived_files.append(source)

    parent = target_skills.parent
    token = f".restore-backup.{os.getpid()}"
    skills_backup = parent / f"{target_skills.name}{token}"
    policies_backup = target_policies.parent / f"{target_policies.name}{token}"
    config_backup = target_config.parent / f".{target_config.name}{token}"
    staged_skills = parent / f".{target_skills.name}.restore.{os.getpid()}"
    staged_policies = target_policies.parent / f".{target_policies.name}.restore.{os.getpid()}"
    installed_logs: list[Path] = []
    staged_logs: list[Path] = []
    skills_installed = False
    policies_installed = False
    config_installed = False
    lock_paths = (
        (target_skills / ".commit.lock", (skills_owner.st_uid, skills_owner.st_gid)),
        (target_policies / ".commit.lock", (policies_owner.st_uid, policies_owner.st_gid)),
        (
            target_config.with_name(f".{target_config.name}.lock"),
            (config_owner.st_uid, config_owner.st_gid),
        ),
    )
    audit_lock_paths = sorted(
        {
            target_logs / f"{source.relative_to(archived_logs).name}.lock"
            for source in archived_files
            if source.name.endswith(".jsonl")
        }
    )
    new_logs: list[Path] = []
    try:
        lock_stack = ExitStack()
        for lock_path, owner in lock_paths:
            lock_stack.enter_context(_exclusive_file_lock(lock_path, new_owner=owner))
        for lock_path in audit_lock_paths:
            lock_stack.enter_context(
                _exclusive_file_lock(
                    lock_path,
                    new_owner=(logs_owner.st_uid, logs_owner.st_gid),
                )
            )
        for source in archived_files:
            relative = source.relative_to(archived_logs)
            destination = target_logs / relative
            if destination.exists() or destination.is_symlink():
                if destination.is_symlink() or not destination.is_file():
                    raise ArchiveError(f"audit destination has an unsafe type: {destination}")
                if destination.read_bytes() != source.read_bytes():
                    raise ArchiveError(
                        f"audit session already exists with different content: {relative}"
                    )
            else:
                new_logs.append(destination)
        _copy_tree_safe(candidate_skills, staged_skills)
        _copy_tree_safe(candidate_policies, staged_policies)
        _set_tree_mode(staged_skills, 0o2750 if managed else 0o700, 0o640 if managed else 0o600)
        _set_tree_mode(staged_policies, 0o750 if managed else 0o700, 0o640 if managed else 0o600)
        _set_tree_owner(staged_skills, skills_owner.st_uid, skills_owner.st_gid)
        _set_tree_owner(staged_policies, policies_owner.st_uid, policies_owner.st_gid)
        os.replace(target_skills, skills_backup)
        os.replace(staged_skills, target_skills)
        skills_installed = True
        os.replace(target_policies, policies_backup)
        os.replace(staged_policies, target_policies)
        policies_installed = True

        descriptor = os.open(config_backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            with os.fdopen(descriptor, "wb") as output, target_config.open("rb") as source:
                for chunk in iter(lambda: source.read(1024 * 1024), b""):
                    output.write(chunk)
                output.flush()
                os.fsync(output.fileno())
        except Exception:
            config_backup.unlink(missing_ok=True)
            raise
        os.chmod(merged_config, stat.S_IMODE(config_owner.st_mode))
        if os.geteuid() == 0:
            os.chown(merged_config, config_owner.st_uid, config_owner.st_gid)
        os.replace(merged_config, target_config)
        config_installed = True

        for destination in new_logs:
            source = archived_logs / destination.relative_to(target_logs)
            destination.parent.mkdir(parents=True, exist_ok=True)
            temporary = destination.with_name(f".{destination.name}.restore.{os.getpid()}")
            staged_logs.append(temporary)
            with source.open("rb") as input_file, temporary.open("xb") as output_file:
                for chunk in iter(lambda: input_file.read(1024 * 1024), b""):
                    output_file.write(chunk)
                output_file.flush()
                os.fsync(output_file.fileno())
            os.chmod(temporary, 0o600)
            if os.geteuid() == 0:
                os.chown(temporary, logs_owner.st_uid, logs_owner.st_gid)
            # Link first so a concurrent creator cannot be silently replaced.
            # Both paths are in the same directory, making the no-replace
            # operation atomic while retaining the staged inode's metadata.
            os.link(temporary, destination, follow_symlinks=False)
            installed_logs.append(destination)
            temporary.unlink()

        for path in (target_skills.parent, target_policies.parent, target_logs, target_config.parent):
            _fsync_directory(path)
    except Exception:
        for temporary in staged_logs:
            temporary.unlink(missing_ok=True)
        for path in installed_logs:
            path.unlink(missing_ok=True)
        if config_installed:
            target_config.unlink(missing_ok=True)
        if config_backup.exists():
            os.replace(config_backup, target_config)
        if policies_installed:
            shutil.rmtree(target_policies)
        if staged_policies.exists():
            shutil.rmtree(staged_policies)
        if policies_backup.exists():
            os.replace(policies_backup, target_policies)
        if skills_installed:
            shutil.rmtree(target_skills)
        if staged_skills.exists():
            shutil.rmtree(staged_skills)
        if skills_backup.exists():
            os.replace(skills_backup, target_skills)
        for path in (
            target_skills.parent,
            target_policies.parent,
            target_logs,
            target_config.parent,
        ):
            _fsync_directory(path)
        raise
    else:
        cleanup_pending = False
        for backup in (skills_backup, policies_backup):
            try:
                shutil.rmtree(backup)
            except FileNotFoundError:
                pass
            except OSError:
                cleanup_pending = True
        try:
            config_backup.unlink(missing_ok=True)
        except OSError:
            cleanup_pending = True
        if cleanup_pending:
            # All replacements and the final directory sync completed. Keep
            # any recovery snapshot for an administrator instead of reporting
            # a false failed restore.
            return "restore_cleanup_pending"
        return None
    finally:
        if "lock_stack" in locals():
            lock_stack.close()


def main(argv: list[str]) -> int:
    try:
        if len(argv) == 4 and argv[1] == "extract":
            manifest = extract_verified(Path(argv[2]), Path(argv[3]))
            print(json.dumps({"ok": True, "status": "verified", "manifest": manifest}))
            return 0
        if len(argv) == 5 and argv[1] == "merge-config":
            merge_config(Path(argv[2]), Path(argv[3]), Path(argv[4]))
            print(json.dumps({"ok": True, "status": "merged"}))
            return 0
        if len(argv) == 6 and argv[1] == "fingerprint":
            value = runtime_fingerprint(
                Path(argv[2]), Path(argv[3]), Path(argv[4]), Path(argv[5])
            )
            print(json.dumps({"ok": True, "status": "fingerprinted", "sha256": value}))
            return 0
        if len(argv) == 8 and argv[1] == "build-manifest":
            if argv[7] not in {"true", "false"}:
                raise ArchiveError("backup managed flag must be true or false")
            count = build_manifest(
                Path(argv[2]),
                Path(argv[3]),
                argv[4],
                argv[5],
                argv[6],
                argv[7] == "true",
            )
            print(json.dumps({"ok": True, "status": "inventoried", "files": count}))
            return 0
        if len(argv) == 4 and argv[1] == "build-index":
            count = build_user_skill_index(Path(argv[2]), Path(argv[3]))
            print(json.dumps({"ok": True, "status": "indexed", "skills": count}))
            return 0
        raise ArchiveError(
            "usage: runtime_archive.py extract <archive> <destination> | "
            "merge-config <current> <redacted> <output> | "
            "fingerprint <release> <config> <skills> <policies> | "
            "build-manifest <stage> <output> <exported-at> <release> <storage> <managed> | "
            "build-index <skills> <output>"
        )
    except (ArchiveError, OSError, tarfile.TarError, ValueError) as exc:
        print(json.dumps({"ok": False, "status": "invalid_backup", "error": str(exc)}))
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
