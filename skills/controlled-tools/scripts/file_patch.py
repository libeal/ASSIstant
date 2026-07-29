#!/usr/bin/env python3
"""Transactional implementation for the controlled-tools/file-patch Skill."""

from __future__ import annotations

import difflib
import fcntl
import hashlib
import json
import os
import re
import stat
import sys
import tempfile
import time
from contextlib import contextmanager
from pathlib import Path


MAX_DEFAULT_BYTES = 2 * 1024 * 1024
MAX_BYTES = 16 * 1024 * 1024
MAX_DIFF = 12_000
SHA_PATTERN = re.compile(r"^[0-9a-f]{64}$")
MARKER_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$")
MODE_PATTERN = re.compile(r"^0[0-7]{3}$")
COMMENT_PREFIXES = frozenset({"#", ";", "//", "--"})


class FilePatchError(ValueError):
    def __init__(self, message: str, status: str = "invalid_arguments"):
        super().__init__(message)
        self.status = status


def _emit(payload: dict[str, object]) -> None:
    print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))


def _strict_object(raw: str) -> dict[str, object]:
    def reject_duplicates(pairs: list[tuple[str, object]]) -> dict[str, object]:
        result: dict[str, object] = {}
        for key, value in pairs:
            if key in result:
                raise FilePatchError(f"duplicate JSON key: {key}")
            result[key] = value
        return result

    try:
        value = json.loads(
            raw,
            object_pairs_hook=reject_duplicates,
            parse_constant=lambda constant: (_ for _ in ()).throw(
                FilePatchError(f"invalid JSON constant: {constant}")
            ),
        )
    except (json.JSONDecodeError, TypeError) as exc:
        raise FilePatchError(f"arguments must be valid JSON: {exc}") from exc
    if not isinstance(value, dict):
        raise FilePatchError("arguments must be a JSON object")
    return value


def _fields(args: dict[str, object], allowed: set[str]) -> None:
    unknown = sorted(set(args) - allowed)
    if unknown:
        raise FilePatchError(f"unsupported fields: {', '.join(unknown)}")


def _bool(value: object, name: str) -> bool:
    if not isinstance(value, bool):
        raise FilePatchError(f"{name} must be boolean")
    return value


def _integer(value: object, name: str, minimum: int, maximum: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not minimum <= value <= maximum:
        raise FilePatchError(f"{name} must be an integer in {minimum}..{maximum}")
    return value


def _text(value: object, name: str, *, allow_empty: bool = True, maximum: int = MAX_BYTES) -> str:
    if not isinstance(value, str) or "\x00" in value or len(value.encode("utf-8")) > maximum:
        raise FilePatchError(f"{name} must be a bounded UTF-8 string")
    if not allow_empty and not value:
        raise FilePatchError(f"{name} must not be empty")
    return value


def _digest(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _expected_digest(value: object) -> str:
    if not isinstance(value, str) or SHA_PATTERN.fullmatch(value) is None:
        raise FilePatchError("expected_sha256 must be a lowercase SHA-256 digest")
    return value


def _absolute_path(value: object, *, must_exist: bool) -> Path:
    path_text = _text(value, "path", allow_empty=False, maximum=4096)
    raw = Path(path_text).expanduser()
    if not raw.is_absolute():
        raw = Path.cwd() / raw
    path = Path(os.path.abspath(os.fspath(raw)))
    current = Path(path.anchor)
    for component in path.parts[1:]:
        current /= component
        try:
            metadata = current.lstat()
        except FileNotFoundError:
            if must_exist or current != path:
                raise FilePatchError("path or parent does not exist", "path_error")
            break
        except OSError as exc:
            raise FilePatchError(str(exc), "path_error") from exc
        if stat.S_ISLNK(metadata.st_mode):
            raise FilePatchError("path must not contain symbolic links", "unsupported_path")
    return path


def _read_existing(path: Path, maximum: int) -> tuple[bytes, os.stat_result]:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        raise FilePatchError(str(exc), "path_error") from exc
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise FilePatchError("path must be a regular file", "unsupported_path")
        if metadata.st_size > maximum:
            raise FilePatchError("file exceeds max_file_bytes", "file_too_large")
        chunks = []
        remaining = maximum + 1
        while remaining:
            chunk = os.read(descriptor, min(65_536, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        payload = b"".join(chunks)
        if len(payload) > maximum:
            raise FilePatchError("file exceeds max_file_bytes", "file_too_large")
        return payload, metadata
    finally:
        os.close(descriptor)


def _decode(payload: bytes) -> str:
    if b"\x00" in payload:
        raise FilePatchError("binary files are not supported", "read_error")
    try:
        return payload.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise FilePatchError("file must be UTF-8", "read_error") from exc


def _fsync_directory(directory: Path) -> None:
    descriptor = os.open(directory, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _write_all(descriptor: int, payload: bytes) -> None:
    offset = 0
    while offset < len(payload):
        written = os.write(descriptor, payload[offset:])
        if written <= 0:
            raise OSError("write made no forward progress")
        offset += written
    os.fsync(descriptor)


@contextmanager
def _mutation_lock(path: Path):
    lock_path = path.parent / f".{path.name}.linux-agent.lock"
    flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(lock_path, flags, 0o600)
    except OSError as exc:
        raise FilePatchError(f"mutation lock is unavailable: {exc}", "write_error") from exc
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise FilePatchError("mutation lock must be a regular file", "write_error")
        os.fchmod(descriptor, 0o600)
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield
    finally:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
        finally:
            os.close(descriptor)


def _check_target(path: Path, expected: str, maximum: int) -> tuple[bytes, os.stat_result]:
    payload, metadata = _read_existing(path, maximum)
    if _digest(payload) != expected:
        raise FilePatchError("target changed after review", "target_changed")
    return payload, metadata


def _restore(path: Path, payload: bytes, metadata: os.stat_result) -> None:
    descriptor, raw_path = tempfile.mkstemp(prefix=f".{path.name}.rollback.", dir=path.parent)
    temporary = Path(raw_path)
    try:
        os.fchmod(descriptor, stat.S_IMODE(metadata.st_mode))
        os.fchown(descriptor, metadata.st_uid, metadata.st_gid)
        _write_all(descriptor, payload)
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


def _commit_existing(
    path: Path,
    original: bytes,
    proposed: bytes,
    expected: str,
    maximum: int,
) -> str | None:
    if original == proposed:
        return None
    with _mutation_lock(path):
        current, metadata = _check_target(path, expected, maximum)
        descriptor, raw_path = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
        temporary = Path(raw_path)
        backup: Path | None = None
        replaced = False
        try:
            mode = stat.S_IMODE(metadata.st_mode)
            os.fchmod(descriptor, mode)
            os.fchown(descriptor, metadata.st_uid, metadata.st_gid)
            _write_all(descriptor, proposed)
            os.close(descriptor)
            _check_target(path, expected, maximum)
            backup = path.with_name(f"{path.name}.bak.{time.time_ns()}")
            backup_flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
            backup_descriptor = os.open(backup, backup_flags, 0o600)
            try:
                _write_all(backup_descriptor, current)
            finally:
                os.close(backup_descriptor)
            _fsync_directory(path.parent)
            _check_target(path, expected, maximum)
            os.replace(temporary, path)
            replaced = True
            try:
                _fsync_directory(path.parent)
            except OSError as exc:
                try:
                    _restore(path, current, metadata)
                except Exception as rollback_exc:
                    raise FilePatchError(
                        f"commit fsync failed and rollback failed; backup={backup}: {rollback_exc}",
                        "write_error",
                    ) from exc
                raise FilePatchError("commit fsync failed; original content restored", "write_error") from exc
            return os.fspath(backup)
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


def _diff(path: Path, before: str, after: str) -> tuple[str, bool]:
    text = "\n".join(
        difflib.unified_diff(
            before.splitlines(),
            after.splitlines(),
            fromfile=os.fspath(path),
            tofile=f"{path} (patched)",
            lineterm="",
        )
    )
    if len(text) <= MAX_DIFF:
        return text, False
    return text[:MAX_DIFF] + "\n[TRUNCATED]", True


def _operation(value: object, index: int) -> tuple[str, str, int]:
    if not isinstance(value, dict):
        raise FilePatchError(f"operations[{index}] must be an object")
    _fields(value, {"find", "replacement", "expected_count"})
    needle = _text(value.get("find"), f"operations[{index}].find", allow_empty=False)
    replacement = _text(value.get("replacement", ""), f"operations[{index}].replacement")
    expected_count = _integer(value.get("expected_count"), f"operations[{index}].expected_count", 1, 1_000_000)
    return needle, replacement, expected_count


def _patch(args: dict[str, object], *, legacy: bool) -> dict[str, object]:
    if legacy:
        _fields(args, {"path", "find", "replacement", "expected_count", "apply", "backup", "max_file_bytes"})
        apply_change = _bool(args.get("apply", True), "apply")
        if (
            apply_change
            and "backup" in args
            and _bool(args["backup"], "backup") is not True
        ):
            raise FilePatchError("real file changes require a backup", "backup_required")
        operations = [
            {
                "find": args.get("find"),
                "replacement": args.get("replacement", ""),
                "expected_count": args.get("expected_count"),
            }
        ]
        expected = None
    else:
        _fields(args, {"action", "path", "operations", "expected_sha256", "apply", "max_file_bytes"})
        operations = args.get("operations")
        if not isinstance(operations, list) or not 1 <= len(operations) <= 64:
            raise FilePatchError("operations must contain 1..64 entries")
        apply_change = _bool(args.get("apply", False), "apply")
        expected = _expected_digest(args.get("expected_sha256"))
    maximum = _integer(args.get("max_file_bytes", MAX_DEFAULT_BYTES), "max_file_bytes", 1, MAX_BYTES)
    path = _absolute_path(args.get("path"), must_exist=True)
    original_bytes, _metadata = _read_existing(path, maximum)
    actual_digest = _digest(original_bytes)
    if expected is not None and actual_digest != expected:
        raise FilePatchError("target changed after file-match", "target_changed")
    expected = actual_digest
    original = _decode(original_bytes)
    proposed = original
    operation_results = []
    for index, raw_operation in enumerate(operations):
        needle, replacement, expected_count = _operation(raw_operation, index)
        actual_count = proposed.count(needle)
        if actual_count != expected_count:
            raise FilePatchError(
                f"operations[{index}] expected {expected_count} matches but found {actual_count}",
                "count_mismatch",
            )
        proposed = proposed.replace(needle, replacement)
        operation_results.append(
            {"index": index, "expected_count": expected_count, "actual_count": actual_count}
        )
    proposed_bytes = proposed.encode("utf-8")
    diff, truncated = _diff(path, original, proposed)
    backup_path = None
    if apply_change and proposed_bytes != original_bytes:
        backup_path = _commit_existing(path, original_bytes, proposed_bytes, expected, maximum)
    result: dict[str, object] = {
        "ok": True,
        "tool": "controlled.file.patch",
        "status": "patched" if apply_change and proposed_bytes != original_bytes else ("unchanged" if proposed_bytes == original_bytes else "previewed"),
        "action": "legacy" if legacy else "patch",
        "path": os.fspath(path),
        "sha256_before": expected,
        "sha256_after": _digest(proposed_bytes),
        "backup_path": backup_path,
        "changed": proposed_bytes != original_bytes,
        "applied": apply_change,
        "operations": operation_results,
        "diff": diff,
        "diff_truncated": truncated,
    }
    if legacy:
        result["expected_count"] = operation_results[0]["expected_count"]
        result["actual_count"] = operation_results[0]["actual_count"]
    return result


def _append_block(args: dict[str, object]) -> dict[str, object]:
    _fields(args, {"action", "path", "marker_id", "comment_prefix", "content", "expected_sha256", "apply", "max_file_bytes"})
    apply_change = _bool(args.get("apply"), "apply")
    marker_id = _text(args.get("marker_id"), "marker_id", allow_empty=False, maximum=64)
    if MARKER_PATTERN.fullmatch(marker_id) is None:
        raise FilePatchError("marker_id is invalid")
    prefix = _text(args.get("comment_prefix"), "comment_prefix", allow_empty=False, maximum=2)
    if prefix not in COMMENT_PREFIXES:
        raise FilePatchError("comment_prefix must be #, ;, //, or --")
    content = _text(args.get("content"), "content", maximum=MAX_BYTES).rstrip("\n")
    expected = _expected_digest(args.get("expected_sha256"))
    maximum = _integer(args.get("max_file_bytes", MAX_DEFAULT_BYTES), "max_file_bytes", 1, MAX_BYTES)
    path = _absolute_path(args.get("path"), must_exist=True)
    original_bytes, _metadata = _read_existing(path, maximum)
    if _digest(original_bytes) != expected:
        raise FilePatchError("target changed after file-match", "target_changed")
    original = _decode(original_bytes)
    begin = f"{prefix} BEGIN linux-agent:{marker_id}"
    end = f"{prefix} END linux-agent:{marker_id}"
    block = f"{begin}\n{content}\n{end}"
    begin_count = original.count(begin)
    end_count = original.count(end)
    if begin_count or end_count:
        if begin_count != 1 or end_count != 1 or original.find(begin) > original.find(end):
            raise FilePatchError("managed block markers are malformed", "conflict")
        start = original.index(begin)
        finish = original.index(end, start) + len(end)
        if original[start:finish] != block:
            raise FilePatchError("managed block exists with different content", "conflict")
        return {
            "ok": True,
            "tool": "controlled.file.patch",
            "status": "unchanged",
            "action": "append_block",
            "path": os.fspath(path),
            "sha256_before": expected,
            "sha256_after": expected,
            "backup_path": None,
            "changed": False,
            "applied": apply_change,
        }
    separator = "" if not original else ("\n" if original.endswith("\n") else "\n\n")
    proposed = original + separator + block + "\n"
    proposed_bytes = proposed.encode("utf-8")
    diff, truncated = _diff(path, original, proposed)
    backup_path = None
    if apply_change:
        backup_path = _commit_existing(path, original_bytes, proposed_bytes, expected, maximum)
    return {
        "ok": True,
        "tool": "controlled.file.patch",
        "status": "patched" if apply_change else "previewed",
        "action": "append_block",
        "path": os.fspath(path),
        "sha256_before": expected,
        "sha256_after": _digest(proposed_bytes),
        "backup_path": backup_path,
        "changed": True,
        "applied": apply_change,
        "diff": diff,
        "diff_truncated": truncated,
    }


def _create(args: dict[str, object]) -> dict[str, object]:
    _fields(args, {"action", "path", "content", "apply", "mode"})
    apply_change = _bool(args.get("apply"), "apply")
    content = _text(args.get("content"), "content", maximum=MAX_BYTES)
    mode_text = args.get("mode", "0600")
    if not isinstance(mode_text, str) or MODE_PATTERN.fullmatch(mode_text) is None:
        raise FilePatchError("mode must be an octal string such as 0600")
    mode = int(mode_text, 8)
    path = _absolute_path(args.get("path"), must_exist=False)
    if path.exists() or path.is_symlink():
        raise FilePatchError("create target already exists", "conflict")
    if not path.parent.is_dir() or path.parent.is_symlink():
        raise FilePatchError("create parent must be an existing non-symlink directory", "path_error")
    payload = content.encode("utf-8")
    digest = _digest(payload)
    result: dict[str, object] = {
        "ok": True,
        "tool": "controlled.file.patch",
        "status": "previewed",
        "action": "create",
        "path": os.fspath(path),
        "sha256": digest,
        "mode": mode_text,
        "changed": True,
        "applied": False,
        "deletion_credential": None,
    }
    if not apply_change:
        return result
    with _mutation_lock(path):
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
        try:
            descriptor = os.open(path, flags, mode)
        except OSError as exc:
            raise FilePatchError(str(exc), "write_error") from exc
        try:
            os.fchmod(descriptor, mode)
            _write_all(descriptor, payload)
            metadata = os.fstat(descriptor)
        except Exception:
            try:
                path.unlink()
                _fsync_directory(path.parent)
            except OSError:
                pass
            raise
        finally:
            os.close(descriptor)
        try:
            _fsync_directory(path.parent)
        except OSError as exc:
            try:
                path.unlink()
                _fsync_directory(path.parent)
            except OSError as rollback_exc:
                raise FilePatchError(
                    f"create fsync failed and rollback failed: {rollback_exc}",
                    "write_error",
                ) from exc
            raise FilePatchError(
                "create fsync failed; created target was removed",
                "write_error",
            ) from exc
    result.update(
        {
            "status": "created",
            "applied": True,
            "deletion_credential": {
                "path": os.fspath(path),
                "sha256": digest,
                "inode": str(metadata.st_ino),
                "device": str(metadata.st_dev),
            },
        }
    )
    return result


def execute(args: dict[str, object]) -> dict[str, object]:
    action = args.get("action")
    if action is None:
        return _patch(args, legacy=True)
    if action == "patch":
        return _patch(args, legacy=False)
    if action == "append_block":
        return _append_block(args)
    if action == "create":
        return _create(args)
    raise FilePatchError("action must be patch, append_block, or create")


def main(argv: list[str]) -> int:
    raw = argv[1] if len(argv) == 2 else "{}"
    try:
        result = execute(_strict_object(raw))
    except FilePatchError as exc:
        _emit(
            {
                "ok": False,
                "tool": "controlled.file.patch",
                "status": exc.status,
                "code": exc.status,
                "error": str(exc),
            }
        )
        return 0
    except OSError as exc:
        _emit(
            {
                "ok": False,
                "tool": "controlled.file.patch",
                "status": "write_error",
                "code": "write_error",
                "error": str(exc),
            }
        )
        return 0
    _emit(result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
