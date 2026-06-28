#!/usr/bin/env bash

set -euo pipefail

arguments_json="${1:-}"
[[ -z "${arguments_json}" ]] && arguments_json='{}'

python3 - "${arguments_json}" <<'PY'
import json
import re
import sys
from pathlib import Path


def emit(payload):
    print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))


try:
    args = json.loads(sys.argv[1])
except json.JSONDecodeError as exc:
    emit({"ok": False, "tool": "controlled.local.analyze", "status": "invalid_arguments", "error": str(exc)})
    raise SystemExit(0)

text = args.get("text")
path_value = str(args.get("path") or "")
max_bytes = int(args.get("max_bytes") or 256 * 1024)

source = "text"
if text is None and path_value:
    try:
        raw_path = Path(path_value).expanduser()
        if raw_path.is_symlink():
            emit({"ok": False, "tool": "controlled.local.analyze", "status": "unsupported_path", "path": str(raw_path), "error": "path must be a regular non-symlink file."})
            raise SystemExit(0)
        path = raw_path.resolve(strict=True)
        if not path.is_file():
            emit({"ok": False, "tool": "controlled.local.analyze", "status": "unsupported_path", "path": str(path), "error": "path must be a regular non-symlink file."})
            raise SystemExit(0)
        data = path.read_bytes()
        if len(data) > max_bytes:
            data = data[:max_bytes]
            truncated = True
        else:
            truncated = False
        text = data.decode("utf-8", errors="replace")
        source = str(path)
    except OSError as exc:
        emit({"ok": False, "tool": "controlled.local.analyze", "status": "path_error", "path": path_value, "error": str(exc)})
        raise SystemExit(0)
else:
    text = str(text or "")
    truncated = len(text.encode("utf-8")) > max_bytes
    if truncated:
        text = text.encode("utf-8")[:max_bytes].decode("utf-8", errors="replace")

if not text:
    emit({"ok": False, "tool": "controlled.local.analyze", "status": "empty_input", "error": "text or path is required."})
    raise SystemExit(0)

lines = text.splitlines()
keyword_re = re.compile(r"\b(error|failed|failure|denied|timeout|exception|traceback|panic|fatal|warn(?:ing)?)\b", re.IGNORECASE)
keyword_lines = []
counts = {}
for number, line in enumerate(lines, start=1):
    found = keyword_re.findall(line)
    for item in found:
        key = item.lower()
        counts[key] = counts.get(key, 0) + 1
    if found and len(keyword_lines) < 20:
        keyword_lines.append({"line": number, "text": line[:500]})

emit({
    "ok": True,
    "tool": "controlled.local.analyze",
    "status": "analyzed",
    "source": source,
    "line_count": len(lines),
    "char_count": len(text),
    "truncated": truncated,
    "keyword_counts": counts,
    "keyword_samples": keyword_lines,
    "summary": f"{len(lines)} lines, {len(keyword_lines)} highlighted lines",
})
PY
