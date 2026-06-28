#!/usr/bin/env bash

set -euo pipefail

arguments_json="${1:-}"
[[ -z "${arguments_json}" ]] && arguments_json='{}'

python3 - "${arguments_json}" <<'PY'
import hashlib
import ipaddress
import json
import os
import socket
import ssl
import sys
import tempfile
import urllib.error
import urllib.request
from pathlib import Path
from urllib.parse import urlparse


def emit(payload):
    print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


try:
    args = json.loads(sys.argv[1])
except json.JSONDecodeError as exc:
    emit({"ok": False, "tool": "controlled.file.download", "status": "invalid_arguments", "error": str(exc)})
    raise SystemExit(0)

url = str(args.get("url") or "")
output_value = str(args.get("output_path") or "")
expected_sha256 = str(args.get("expected_sha256") or "").lower()
max_bytes = int(args.get("max_bytes") or 100 * 1024 * 1024)
overwrite = bool(args.get("overwrite", False))
create_parent = bool(args.get("create_parent", False))

if max_bytes <= 0 or max_bytes > 100 * 1024 * 1024:
    max_bytes = 100 * 1024 * 1024
if not url or not output_value:
    emit({"ok": False, "tool": "controlled.file.download", "status": "missing_arguments", "error": "url and output_path are required."})
    raise SystemExit(0)
if expected_sha256 and (len(expected_sha256) != 64 or any(ch not in "0123456789abcdef" for ch in expected_sha256)):
    emit({"ok": False, "tool": "controlled.file.download", "status": "invalid_sha256", "error": "expected_sha256 must be a lowercase hex sha256."})
    raise SystemExit(0)

parsed = urlparse(url)
if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
    emit({"ok": False, "tool": "controlled.file.download", "status": "unsafe_url", "url": url, "error": "only credential-free https URLs are allowed."})
    raise SystemExit(0)

try:
    addresses = socket.getaddrinfo(parsed.hostname, parsed.port or 443, type=socket.SOCK_STREAM)
except OSError as exc:
    emit({"ok": False, "tool": "controlled.file.download", "status": "dns_error", "url": url, "error": str(exc)})
    raise SystemExit(0)

resolved_ips = sorted({item[4][0] for item in addresses})
for raw_ip in resolved_ips:
    ip = ipaddress.ip_address(raw_ip)
    if not ip.is_global:
        emit({"ok": False, "tool": "controlled.file.download", "status": "unsafe_address", "url": url, "ip": raw_ip, "error": "resolved address is not public/global."})
        raise SystemExit(0)

raw_target = Path(output_value).expanduser()
if raw_target.exists() and raw_target.is_symlink():
    emit({"ok": False, "tool": "controlled.file.download", "status": "unsupported_path", "path": str(raw_target), "error": "output_path must not be a symlink."})
    raise SystemExit(0)
target = raw_target.resolve()
if target.exists() and not overwrite:
    emit({"ok": False, "tool": "controlled.file.download", "status": "target_exists", "path": str(target), "error": "output_path exists; set overwrite=true to replace it."})
    raise SystemExit(0)
if not target.parent.exists():
    if create_parent:
        target.parent.mkdir(parents=True, exist_ok=True)
    else:
        emit({"ok": False, "tool": "controlled.file.download", "status": "missing_parent", "path": str(target.parent), "error": "parent directory does not exist."})
        raise SystemExit(0)

opener = urllib.request.build_opener(NoRedirect, urllib.request.HTTPSHandler(context=ssl.create_default_context()))
request = urllib.request.Request(url, headers={"User-Agent": "linux-agent-controlled-download/1"})
hasher = hashlib.sha256()
total = 0
tmp_name = ""
try:
    with opener.open(request, timeout=30) as response:
        length = response.headers.get("Content-Length")
        if length and int(length) > max_bytes:
            emit({"ok": False, "tool": "controlled.file.download", "status": "file_too_large", "url": url, "content_length": int(length), "max_bytes": max_bytes})
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

try:
    os.chmod(tmp_name, 0o644)
    os.replace(tmp_name, target)
except OSError as exc:
    try:
        os.remove(tmp_name)
    except OSError:
        pass
    emit({"ok": False, "tool": "controlled.file.download", "status": "write_error", "path": str(target), "error": str(exc)})
    raise SystemExit(0)

emit({"ok": True, "tool": "controlled.file.download", "status": "downloaded", "url": url, "path": str(target), "size_bytes": total, "sha256": actual_sha256, "resolved_ips": resolved_ips})
PY
