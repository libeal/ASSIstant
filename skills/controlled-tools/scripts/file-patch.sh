#!/usr/bin/env bash

set -euo pipefail

arguments_json="${1:-}"
[[ -z "${arguments_json}" ]] && arguments_json='{}'

python3 - "${arguments_json}" <<'PY'
import difflib
import json
import os
import shutil
import sys
import tempfile
import time
from pathlib import Path


def emit(payload):
    print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))


try:
    args = json.loads(sys.argv[1])
except json.JSONDecodeError as exc:
    emit({"ok": False, "tool": "controlled.file.patch", "status": "invalid_arguments", "error": str(exc)})
    raise SystemExit(0)

path_value = str(args.get("path") or "")
needle = str(args.get("find") or "")
replacement = str(args.get("replacement") if args.get("replacement") is not None else "")
apply_change = bool(args.get("apply", True))
backup = bool(args.get("backup", True))
max_file_bytes = int(args.get("max_file_bytes") or 2 * 1024 * 1024)

if apply_change and not backup:
    emit({
        "ok": False,
        "tool": "controlled.file.patch",
        "status": "backup_required",
        "error": "真实文件变更必须保留事务性备份。",
    })
    raise SystemExit(0)

try:
    expected_count = int(args.get("expected_count"))
except (TypeError, ValueError):
    expected_count = -1

if not path_value:
    emit({"ok": False, "tool": "controlled.file.patch", "status": "missing_path", "error": "path is required."})
    raise SystemExit(0)
if not needle:
    emit({"ok": False, "tool": "controlled.file.patch", "status": "missing_find", "error": "find is required."})
    raise SystemExit(0)
if expected_count < 1:
    emit({"ok": False, "tool": "controlled.file.patch", "status": "invalid_expected_count", "error": "expected_count must be >= 1."})
    raise SystemExit(0)

try:
    raw_path = Path(path_value).expanduser()
    if raw_path.is_symlink():
        emit({"ok": False, "tool": "controlled.file.patch", "status": "unsupported_path", "path": str(raw_path), "error": "path must be a regular non-symlink file."})
        raise SystemExit(0)
    path = raw_path.resolve(strict=True)
    stat = path.stat()
except OSError as exc:
    emit({"ok": False, "tool": "controlled.file.patch", "status": "path_error", "path": path_value, "error": str(exc)})
    raise SystemExit(0)

if not path.is_file():
    emit({"ok": False, "tool": "controlled.file.patch", "status": "unsupported_path", "path": str(path), "error": "path must be a regular non-symlink file."})
    raise SystemExit(0)
if stat.st_size > max_file_bytes:
    emit({"ok": False, "tool": "controlled.file.patch", "status": "file_too_large", "path": str(path), "size_bytes": stat.st_size, "max_file_bytes": max_file_bytes})
    raise SystemExit(0)

try:
    data = path.read_bytes()
    if b"\x00" in data:
        raise UnicodeError("binary file contains NUL bytes")
    original = data.decode("utf-8")
except (OSError, UnicodeError) as exc:
    emit({"ok": False, "tool": "controlled.file.patch", "status": "read_error", "path": str(path), "error": str(exc)})
    raise SystemExit(0)

actual_count = original.count(needle)
if actual_count != expected_count:
    emit({
        "ok": False,
        "tool": "controlled.file.patch",
        "status": "count_mismatch",
        "path": str(path),
        "expected_count": expected_count,
        "actual_count": actual_count,
        "error": "find occurrence count changed; rerun file-match before patching.",
    })
    raise SystemExit(0)

patched = original.replace(needle, replacement)
diff_lines = list(difflib.unified_diff(
    original.splitlines(),
    patched.splitlines(),
    fromfile=str(path),
    tofile=f"{path} (patched)",
    lineterm="",
))
diff_text = "\n".join(diff_lines)
truncated = False
if len(diff_text) > 12000:
    diff_text = diff_text[:12000] + "\n[TRUNCATED]"
    truncated = True

if not apply_change:
    emit({
        "ok": True,
        "tool": "controlled.file.patch",
        "status": "previewed",
        "path": str(path),
        "expected_count": expected_count,
        "actual_count": actual_count,
        "changed": original != patched,
        "diff": diff_text,
        "diff_truncated": truncated,
    })
    raise SystemExit(0)

backup_path = ""
tmp_name = ""
try:
    if backup:
        backup_path = str(path.with_name(f"{path.name}.bak.{time.strftime('%Y%m%d_%H%M%S')}.{time.time_ns()}"))
        shutil.copy2(path, backup_path)
        os.chmod(backup_path, 0o600)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=str(path.parent), prefix=f".{path.name}.", suffix=".tmp", delete=False) as handle:
        tmp_name = handle.name
        handle.write(patched)
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(tmp_name, stat.st_mode & 0o777)
    os.replace(tmp_name, path)
    try:
        directory_fd = os.open(path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    except OSError:
        directory_fd = -1
    if directory_fd >= 0:
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
except OSError as exc:
    if tmp_name:
        try:
            os.remove(tmp_name)
        except OSError:
            pass
    emit({"ok": False, "tool": "controlled.file.patch", "status": "write_error", "path": str(path), "backup_path": backup_path or None, "error": str(exc)})
    raise SystemExit(0)

emit({
    "ok": True,
    "tool": "controlled.file.patch",
    "status": "patched",
    "path": str(path),
    "backup_path": backup_path or None,
    "expected_count": expected_count,
    "actual_count": actual_count,
    "changed": original != patched,
    "diff": diff_text,
    "diff_truncated": truncated,
})
PY
