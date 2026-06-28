#!/usr/bin/env bash

set -euo pipefail

arguments_json="${1:-}"
[[ -z "${arguments_json}" ]] && arguments_json='{}'

python3 - "${arguments_json}" <<'PY'
import json
import sys
from pathlib import Path


def emit(payload):
    print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))


try:
    args = json.loads(sys.argv[1])
except json.JSONDecodeError as exc:
    emit({"ok": False, "tool": "controlled.file.match", "status": "invalid_arguments", "error": str(exc)})
    raise SystemExit(0)

path_value = str(args.get("path") or "")
needle = str(args.get("find") or "")
context_lines = int(args.get("context_lines") or 2)
max_matches = int(args.get("max_matches") or 20)
max_file_bytes = int(args.get("max_file_bytes") or 2 * 1024 * 1024)

if not path_value:
    emit({"ok": False, "tool": "controlled.file.match", "status": "missing_path", "error": "path is required."})
    raise SystemExit(0)
if not needle:
    emit({"ok": False, "tool": "controlled.file.match", "status": "missing_find", "error": "find is required."})
    raise SystemExit(0)
if context_lines < 0 or context_lines > 20:
    context_lines = 2
if max_matches <= 0 or max_matches > 100:
    max_matches = 20

try:
    raw_path = Path(path_value).expanduser()
    if raw_path.is_symlink():
        emit({"ok": False, "tool": "controlled.file.match", "status": "unsupported_path", "path": str(raw_path), "error": "path must be a regular non-symlink file."})
        raise SystemExit(0)
    path = raw_path.resolve(strict=True)
    stat = path.stat()
except OSError as exc:
    emit({"ok": False, "tool": "controlled.file.match", "status": "path_error", "path": path_value, "error": str(exc)})
    raise SystemExit(0)

if not path.is_file():
    emit({"ok": False, "tool": "controlled.file.match", "status": "unsupported_path", "path": str(path), "error": "path must be a regular non-symlink file."})
    raise SystemExit(0)
if stat.st_size > max_file_bytes:
    emit({"ok": False, "tool": "controlled.file.match", "status": "file_too_large", "path": str(path), "size_bytes": stat.st_size, "max_file_bytes": max_file_bytes})
    raise SystemExit(0)

try:
    data = path.read_bytes()
    if b"\x00" in data:
        raise UnicodeError("binary file contains NUL bytes")
    text = data.decode("utf-8")
except (OSError, UnicodeError) as exc:
    emit({"ok": False, "tool": "controlled.file.match", "status": "read_error", "path": str(path), "error": str(exc)})
    raise SystemExit(0)

line_starts = [0]
for index, char in enumerate(text):
    if char == "\n":
        line_starts.append(index + 1)
lines = text.splitlines()
matches = []
start = 0
while True:
    idx = text.find(needle, start)
    if idx < 0:
        break
    line_no = 1
    for pos, line_start in enumerate(line_starts):
        if line_start > idx:
            break
        line_no = pos + 1
    context_start = max(1, line_no - context_lines)
    context_end = min(len(lines), line_no + context_lines)
    if len(matches) < max_matches:
        matches.append({
            "line": line_no,
            "column": idx - line_starts[line_no - 1] + 1,
            "context_start": context_start,
            "context_end": context_end,
            "context": "\n".join(lines[context_start - 1:context_end]),
        })
    start = idx + max(1, len(needle))

emit({
    "ok": True,
    "tool": "controlled.file.match",
    "status": "matched",
    "path": str(path),
    "size_bytes": stat.st_size,
    "match_count": len(matches) if text.count(needle) <= max_matches else text.count(needle),
    "shown_count": len(matches),
    "matches": matches,
    "truncated": text.count(needle) > max_matches,
})
PY
