#!/usr/bin/env bash

set -euo pipefail

arguments_json="${1:-}"
[[ -z "${arguments_json}" ]] && arguments_json='{}'
script_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
lib_root="${LINUX_AGENT_ROOT:-${script_root}}/lib"

python3 - "${arguments_json}" "${lib_root}" <<'PY'
import hashlib
import json
import os
import stat
import sys
import tempfile
import urllib.error
from pathlib import Path

sys.path.insert(0, sys.argv[2])
from pinned_http import PinnedHTTPPolicyError, open_public_https


def emit(payload):
    print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))


def fsync_directory(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def open_regular_no_follow(path):
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    metadata = os.fstat(descriptor)
    if not stat.S_ISREG(metadata.st_mode):
        os.close(descriptor)
        raise OSError("output_path must be a regular file")
    return descriptor, metadata


class UnsupportedOutputPath(ValueError):
    """The requested destination traverses an unsafe filesystem component."""


def validate_output_components(path):
    """Return an absolute lexical path after rejecting symlinked components.

    Path.resolve would hide a symlink in a parent directory.  Walk the
    lexical path first so the destination cannot silently escape its intended
    directory.  Reject parent traversal as well: it can otherwise cross a symlink
    before the path is normalized.
    """
    expanded = Path(os.path.expanduser(os.fspath(path)))
    if any(component == ".." for component in expanded.parts):
        raise UnsupportedOutputPath("output_path must not contain '..' components")
    absolute = Path(os.path.abspath(os.fspath(expanded)))
    current = Path(absolute.anchor)
    components = absolute.parts[1:]
    for index, component in enumerate(components):
        current /= component
        try:
            metadata = current.lstat()
        except FileNotFoundError:
            continue
        if stat.S_ISLNK(metadata.st_mode):
            raise UnsupportedOutputPath(
                f"output_path component is a symlink: {current}"
            )
        if index < len(components) - 1 and not stat.S_ISDIR(metadata.st_mode):
            raise UnsupportedOutputPath(
                f"output_path parent is not a directory: {current}"
            )
    return absolute


def ensure_parent_directories(path):
    """Create missing parent components while checking each one with lstat."""
    current = Path(path.anchor)
    for component in path.parts[1:]:
        current /= component
        try:
            metadata = current.lstat()
        except FileNotFoundError:
            try:
                current.mkdir(mode=0o755)
            except FileExistsError:
                metadata = current.lstat()
            else:
                metadata = current.lstat()
        if stat.S_ISLNK(metadata.st_mode):
            raise UnsupportedOutputPath(
                f"output_path component is a symlink: {current}"
            )
        if not stat.S_ISDIR(metadata.st_mode):
            raise UnsupportedOutputPath(
                f"output_path parent is not a directory: {current}"
            )


def backup_existing_target(path):
    source, metadata = open_regular_no_follow(path)
    backup_descriptor, backup_path = tempfile.mkstemp(
        dir=str(path.parent),
        prefix=f".{path.name}.previous.",
        suffix=".tmp",
    )
    digest = hashlib.sha256()
    try:
        os.fchmod(backup_descriptor, stat.S_IMODE(metadata.st_mode))
        while True:
            chunk = os.read(source, 65536)
            if not chunk:
                break
            digest.update(chunk)
            offset = 0
            while offset < len(chunk):
                written = os.write(backup_descriptor, chunk[offset:])
                if written <= 0:
                    raise OSError("backup write made no forward progress")
                offset += written
        os.fsync(backup_descriptor)
    except Exception:
        try:
            os.unlink(backup_path)
        except OSError:
            pass
        raise
    finally:
        os.close(source)
        os.close(backup_descriptor)
    identity = (metadata.st_dev, metadata.st_ino, metadata.st_size, metadata.st_mtime_ns)
    return backup_path, digest.hexdigest(), identity


def current_target_digest(path):
    descriptor, metadata = open_regular_no_follow(path)
    digest = hashlib.sha256()
    try:
        while True:
            chunk = os.read(descriptor, 65536)
            if not chunk:
                break
            digest.update(chunk)
    finally:
        os.close(descriptor)
    identity = (metadata.st_dev, metadata.st_ino, metadata.st_size, metadata.st_mtime_ns)
    return digest.hexdigest(), identity


def restore_previous_target(path, backup_path):
    rollback_descriptor, rollback_path = tempfile.mkstemp(
        dir=str(path.parent),
        prefix=f".{path.name}.rollback.",
        suffix=".tmp",
    )
    try:
        source, metadata = open_regular_no_follow(backup_path)
        try:
            os.fchmod(rollback_descriptor, stat.S_IMODE(metadata.st_mode))
            while True:
                chunk = os.read(source, 65536)
                if not chunk:
                    break
                offset = 0
                while offset < len(chunk):
                    written = os.write(rollback_descriptor, chunk[offset:])
                    if written <= 0:
                        raise OSError("rollback write made no forward progress")
                    offset += written
            os.fsync(rollback_descriptor)
        finally:
            os.close(source)
            os.close(rollback_descriptor)
        os.replace(rollback_path, path)
        fsync_directory(path.parent)
    finally:
        try:
            os.close(rollback_descriptor)
        except OSError:
            pass
        try:
            os.unlink(rollback_path)
        except FileNotFoundError:
            pass


try:
    args = json.loads(sys.argv[1])
except (UnicodeError, json.JSONDecodeError) as exc:
    emit({"ok": False, "tool": "controlled.file.download", "status": "invalid_arguments", "error": str(exc)})
    raise SystemExit(0)
if not isinstance(args, dict):
    emit({"ok": False, "tool": "controlled.file.download", "status": "invalid_arguments", "error": "arguments must be a JSON object."})
    raise SystemExit(0)

url = str(args.get("url") or "")
output_value = str(args.get("output_path") or "")
expected_sha256 = str(args.get("expected_sha256") or "").lower()
max_bytes = args.get("max_bytes", 100 * 1024 * 1024)
overwrite = args.get("overwrite", False)
create_parent = args.get("create_parent", False)

if isinstance(max_bytes, bool) or not isinstance(max_bytes, int) or not 1 <= max_bytes <= 100 * 1024 * 1024:
    emit({"ok": False, "tool": "controlled.file.download", "status": "invalid_arguments", "error": "max_bytes must be an integer between 1 and 104857600."})
    raise SystemExit(0)
if not isinstance(overwrite, bool) or not isinstance(create_parent, bool):
    emit({"ok": False, "tool": "controlled.file.download", "status": "invalid_arguments", "error": "overwrite and create_parent must be booleans."})
    raise SystemExit(0)
if not url or not output_value:
    emit({"ok": False, "tool": "controlled.file.download", "status": "missing_arguments", "error": "url and output_path are required."})
    raise SystemExit(0)
if expected_sha256 and (len(expected_sha256) != 64 or any(ch not in "0123456789abcdef" for ch in expected_sha256)):
    emit({"ok": False, "tool": "controlled.file.download", "status": "invalid_sha256", "error": "expected_sha256 must be a lowercase hex sha256."})
    raise SystemExit(0)

raw_target = Path(output_value).expanduser()
try:
    target = validate_output_components(raw_target)
except (OSError, UnsupportedOutputPath, ValueError) as exc:
    emit({"ok": False, "tool": "controlled.file.download", "status": "unsupported_path", "path": str(raw_target), "error": str(exc)})
    raise SystemExit(0)
if target.exists() and not overwrite:
    emit({"ok": False, "tool": "controlled.file.download", "status": "target_exists", "path": str(target), "error": "output_path exists; set overwrite=true to replace it."})
    raise SystemExit(0)
if not target.parent.exists():
    if create_parent:
        try:
            ensure_parent_directories(target.parent)
        except (OSError, UnsupportedOutputPath, ValueError) as exc:
            emit({"ok": False, "tool": "controlled.file.download", "status": "unsupported_path", "path": str(target.parent), "error": str(exc)})
            raise SystemExit(0)
    else:
        emit({"ok": False, "tool": "controlled.file.download", "status": "missing_parent", "path": str(target.parent), "error": "parent directory does not exist."})
        raise SystemExit(0)
try:
    target = validate_output_components(target)
except (OSError, UnsupportedOutputPath, ValueError) as exc:
    emit({"ok": False, "tool": "controlled.file.download", "status": "unsupported_path", "path": str(target), "error": str(exc)})
    raise SystemExit(0)
if target.exists() and not stat.S_ISREG(target.lstat().st_mode):
    emit({"ok": False, "tool": "controlled.file.download", "status": "unsupported_path", "path": str(target), "error": "output_path must be a regular file."})
    raise SystemExit(0)

hasher = hashlib.sha256()
total = 0
tmp_name = ""
resolved_ips = []
url_chain = []
try:
    response, final_url, addresses, chain = open_public_https(
        url,
        headers={"User-Agent": "linux-agent-controlled-download/1"},
        timeout=30,
        max_redirects=5,
    )
    resolved_ips = list(addresses)
    url_chain = list(chain)
    with response:
        length = response.headers.get("Content-Length")
        if length:
            try:
                content_length = int(length)
            except ValueError as exc:
                raise ValueError("Content-Length is invalid") from exc
            if content_length < 0:
                raise ValueError("Content-Length is invalid")
            if content_length > max_bytes:
                emit({"ok": False, "tool": "controlled.file.download", "status": "file_too_large", "url": final_url, "content_length": content_length, "max_bytes": max_bytes})
                raise SystemExit(0)
        with tempfile.NamedTemporaryFile("wb", dir=str(target.parent), prefix=f".{target.name}.", suffix=".tmp", delete=False) as handle:
            tmp_name = handle.name
            while True:
                chunk = response.read(65536)
                if not chunk:
                    break
                total += len(chunk)
                if total > max_bytes:
                    raise ValueError(f"download exceeded max_bytes={max_bytes}")
                hasher.update(chunk)
                handle.write(chunk)
            handle.flush()
            os.fsync(handle.fileno())
except PinnedHTTPPolicyError as exc:
    emit({"ok": False, "tool": "controlled.file.download", "status": exc.code, "url": exc.url or url, **({"ip": exc.address} if exc.address else {}), "error": str(exc)})
    raise SystemExit(0)
except urllib.error.HTTPError as exc:
    emit({"ok": False, "tool": "controlled.file.download", "status": "http_error", "url": url, "error": f"HTTP {exc.code}"})
    raise SystemExit(0)
except (OSError, ValueError) as exc:
    if tmp_name:
        try:
            os.remove(tmp_name)
        except OSError:
            pass
    emit({"ok": False, "tool": "controlled.file.download", "status": "download_error", "url": url, "error": str(exc)})
    raise SystemExit(0)

actual_sha256 = hasher.hexdigest()
if expected_sha256 and actual_sha256 != expected_sha256:
    try:
        os.remove(tmp_name)
    except OSError:
        pass
    emit({"ok": False, "tool": "controlled.file.download", "status": "sha256_mismatch", "url": url, "expected_sha256": expected_sha256, "actual_sha256": actual_sha256, "size_bytes": total})
    raise SystemExit(0)

backup_name = ""
target_existed = target.exists()
replaced = False
try:
    os.chmod(tmp_name, 0o644)
    target = validate_output_components(target)
    if target_existed:
        backup_name, previous_digest, previous_identity = backup_existing_target(target)
        current_digest, current_identity = current_target_digest(target)
        if current_digest != previous_digest or current_identity != previous_identity:
            raise OSError("output_path changed while preparing the atomic replacement")
    elif target.exists() or target.is_symlink():
        raise OSError("output_path appeared while preparing the atomic replacement")
    os.replace(tmp_name, target)
    tmp_name = ""
    replaced = True
    fsync_directory(target.parent)
except OSError as exc:
    persistence = "unchanged"
    rollback_error = ""
    if replaced:
        try:
            if target_existed and backup_name:
                restore_previous_target(target, backup_name)
            else:
                target.unlink()
                fsync_directory(target.parent)
            persistence = "rolled_back"
        except OSError as rollback_exc:
            persistence = "unknown"
            rollback_error = str(rollback_exc)
    try:
        if tmp_name:
            os.remove(tmp_name)
    except OSError:
        pass
    recovery_path = backup_name if backup_name and os.path.exists(backup_name) else ""
    emit({
        "ok": False,
        "tool": "controlled.file.download",
        "status": "write_error",
        "path": str(target),
        "persistence": persistence,
        "error": str(exc),
        **({"rollback_error": rollback_error} if rollback_error else {}),
        **({"recovery_path": recovery_path} if recovery_path else {}),
    })
    raise SystemExit(0)

backup_cleanup_pending = False
if backup_name:
    try:
        os.remove(backup_name)
        fsync_directory(target.parent)
    except OSError:
        backup_cleanup_pending = True

emit({"ok": True, "tool": "controlled.file.download", "status": "downloaded", "url": url, "final_url": final_url, "redirects": max(0, len(url_chain) - 1), "path": str(target), "size_bytes": total, "sha256": actual_sha256, "resolved_ips": resolved_ips, **({"backup_cleanup_pending": True} if backup_cleanup_pending else {}), **({"recovery_path": backup_name} if backup_cleanup_pending and os.path.exists(backup_name) else {})})
PY
