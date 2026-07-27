#!/usr/bin/env python3
"""Shared versioned Unix-socket framing for runner and narrow helpers."""

from __future__ import annotations

import hashlib
import fcntl
import json
import math
import os
import pwd
import re
import socket
import stat
import struct
import uuid
from contextlib import contextmanager
from pathlib import Path


PROTOCOL_VERSION = "1.2.0"
MAX_REQUEST_BYTES = 1_048_576
# Bulk Runner output uses bounded NDJSON stream frames.  Single-response
# helpers are deliberately kept small enough that worst-case JSON escaping
# cannot threaten their systemd memory limit.
MAX_RESPONSE_BYTES = 16_777_216
MAX_STREAM_FRAME_BYTES = 131_072
STREAM_CHUNK_BYTES = 65_536
REQUEST_ID_PATTERN = re.compile(r"^[0-9a-f]{32}$")


class ProtocolError(ValueError):
    """A peer sent data outside the helper protocol contract."""


@contextmanager
def runtime_shared_lock(data_root: str | os.PathLike[str] | None = None):
    """Hold the global runtime barrier for one helper operation."""

    root = Path(
        data_root
        if data_root is not None
        else os.environ.get("LINUX_AGENT_DATA_DIR", "/opt/linux-agent/data")
    )
    path = root / ".runtime.lock"
    descriptor = os.open(
        path,
        os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
    )
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise ProtocolError("runtime lock is not a regular file")
        fcntl.flock(descriptor, fcntl.LOCK_SH)
        yield
    finally:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
        finally:
            os.close(descriptor)


def _reject_json_constant(value: str) -> object:
    raise ProtocolError(f"non-finite JSON value is not allowed: {value}")


def _reject_duplicate_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ProtocolError(f"duplicate JSON key is not allowed: {key}")
        result[key] = value
    return result


def canonical_json(value: object) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=True,
        allow_nan=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")


def plan_digest(operation: str, params: dict[str, object], summary: str) -> str:
    return hashlib.sha256(
        canonical_json(
            {
                "operation": operation,
                "params": params,
                "summary": summary,
            }
        )
    ).hexdigest()


def build_request(
    operation: str,
    params: dict[str, object],
    *,
    summary: str,
    request_id: str | None = None,
) -> dict[str, object]:
    if not isinstance(params, dict):
        raise ProtocolError("helper params must be an object")
    request_id = str(request_id or uuid.uuid4().hex)
    if REQUEST_ID_PATTERN.fullmatch(request_id) is None:
        raise ProtocolError("helper request_id is invalid")
    summary = str(summary or "")
    if not summary or len(summary) > 500:
        raise ProtocolError("helper plan summary must be 1-500 characters")
    return {
        "protocol_version": PROTOCOL_VERSION,
        "request_id": request_id,
        "operation": str(operation),
        "params": params,
        "plan": {
            "summary": summary,
            "sha256": plan_digest(str(operation), params, summary),
        },
    }


def validate_request(request: object) -> tuple[str, dict[str, object], str, str]:
    if not isinstance(request, dict):
        raise ProtocolError("helper request must be a JSON object")
    if set(request) != {"protocol_version", "request_id", "operation", "params", "plan"}:
        raise ProtocolError("helper request fields do not match the protocol schema")
    if request.get("protocol_version") != PROTOCOL_VERSION:
        raise ProtocolError("unsupported helper protocol_version")
    request_id = request.get("request_id")
    if not isinstance(request_id, str) or REQUEST_ID_PATTERN.fullmatch(request_id) is None:
        raise ProtocolError("helper request_id is invalid")
    operation = request.get("operation")
    params = request.get("params")
    plan = request.get("plan")
    if not isinstance(operation, str) or not operation:
        raise ProtocolError("helper operation is required")
    if not isinstance(params, dict):
        raise ProtocolError("helper params must be an object")
    if not isinstance(plan, dict):
        raise ProtocolError("helper plan is required")
    if set(plan) != {"summary", "sha256"}:
        raise ProtocolError("helper plan fields do not match the protocol schema")
    summary = plan.get("summary")
    digest = plan.get("sha256")
    if not isinstance(summary, str) or not summary or len(summary) > 500:
        raise ProtocolError("helper plan summary is invalid")
    expected = plan_digest(operation, params, summary)
    if not isinstance(digest, str) or digest != expected:
        raise ProtocolError("helper plan digest does not match the request")
    return operation, params, summary, request_id


def peer_credentials(connection: socket.socket) -> tuple[int, int, int]:
    if not hasattr(socket, "SO_PEERCRED"):
        raise ProtocolError("SO_PEERCRED is unavailable")
    raw = connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12)
    return struct.unpack("3i", raw)


def allowed_peer_uid(default_user: str) -> int:
    raw_uid = os.environ.get("LINUX_AGENT_ALLOWED_PEER_UID", "")
    if raw_uid:
        try:
            value = int(raw_uid)
        except ValueError as exc:
            raise ProtocolError("LINUX_AGENT_ALLOWED_PEER_UID is invalid") from exc
        if value < 0:
            raise ProtocolError("LINUX_AGENT_ALLOWED_PEER_UID is invalid")
        return value
    user = os.environ.get("LINUX_AGENT_SERVICE_USER", default_user)
    try:
        return pwd.getpwnam(user).pw_uid
    except KeyError as exc:
        raise ProtocolError(f"configured peer user does not exist: {user}") from exc


def require_peer_uid(connection: socket.socket, expected_uid: int) -> tuple[int, int, int]:
    peer_pid, peer_uid, peer_gid = peer_credentials(connection)
    if peer_uid != expected_uid:
        raise ProtocolError("requesting process uid is not authorized")
    return peer_pid, peer_uid, peer_gid


def receive_json(connection: socket.socket, limit: int = MAX_REQUEST_BYTES) -> object:
    payload = bytearray()
    while True:
        chunk = connection.recv(min(65_536, limit + 1 - len(payload)))
        if not chunk:
            break
        payload.extend(chunk)
        if len(payload) > limit:
            raise ProtocolError("request exceeds the protocol byte limit")
    if not payload:
        raise ProtocolError("request is empty")
    first_line, separator, remainder = bytes(payload).partition(b"\n")
    if remainder or not separator:
        raise ProtocolError("request must contain exactly one newline-terminated JSON object")
    try:
        value = json.loads(
            first_line.decode("utf-8"),
            parse_constant=_reject_json_constant,
            object_pairs_hook=_reject_duplicate_keys,
        )
    except (UnicodeDecodeError, json.JSONDecodeError, ProtocolError) as exc:
        raise ProtocolError("request is not valid UTF-8 JSON") from exc
    return value


def receive_json_frame(connection: socket.socket, limit: int = MAX_REQUEST_BYTES) -> object:
    """Receive one newline-delimited request without requiring peer EOF.

    Runner execute clients keep their write half open so the service can bind
    the real process lifetime to the client connection.  Narrow helpers retain
    the older EOF-delimited helper through :func:`receive_json`.
    """

    payload = bytearray()
    while True:
        chunk = connection.recv(min(65_536, limit + 1 - len(payload)))
        if not chunk:
            raise ProtocolError("request ended before its newline frame")
        payload.extend(chunk)
        if len(payload) > limit:
            raise ProtocolError("request exceeds the protocol byte limit")
        newline = payload.find(b"\n")
        if newline < 0:
            continue
        if newline != len(payload) - 1:
            raise ProtocolError("request must contain exactly one JSON frame")
        try:
            return json.loads(
                bytes(payload[:-1]).decode("utf-8"),
                parse_constant=_reject_json_constant,
                object_pairs_hook=_reject_duplicate_keys,
            )
        except (UnicodeDecodeError, json.JSONDecodeError, ProtocolError) as exc:
            raise ProtocolError("request is not valid UTF-8 JSON") from exc


def _canonical_json_upper_bound(value: object, budget: int) -> int:
    """Conservatively bound encoded JSON bytes without allocating the JSON."""

    total = 0
    stack = [value]
    seen: set[int] = set()
    while stack:
        item = stack.pop()
        if isinstance(item, str):
            total += 2 + 6 * len(item) + 6 * sum(
                ord(character) > 0xFFFF for character in item
            )
        elif item is None or isinstance(item, bool):
            total += 5
        elif isinstance(item, int):
            # log10(2) < 30103/100000, plus sign/zero and a rounding byte.
            total += max(1, (abs(item).bit_length() * 30103) // 100000 + 2)
        elif isinstance(item, float):
            if not math.isfinite(item):
                raise ProtocolError("helper response contains a non-finite number")
            total += 32
        elif isinstance(item, dict):
            identity = id(item)
            if identity in seen:
                raise ProtocolError("helper response contains a recursive object")
            seen.add(identity)
            total += 2 + max(0, len(item) - 1)
            for key, child in item.items():
                if not isinstance(key, str):
                    raise ProtocolError("helper response keys must be strings")
                total += 3 + 6 * len(key)
                stack.append(child)
        elif isinstance(item, (list, tuple)):
            identity = id(item)
            if identity in seen:
                raise ProtocolError("helper response contains a recursive array")
            seen.add(identity)
            total += 2 + max(0, len(item) - 1)
            stack.extend(item)
        else:
            raise ProtocolError("helper response contains an unsupported JSON value")
        if total > budget:
            return total
    return total


def send_json(connection: socket.socket, response: dict[str, object]) -> None:
    if _canonical_json_upper_bound(response, MAX_RESPONSE_BYTES - 1) > MAX_RESPONSE_BYTES - 1:
        response = {
            "ok": False,
            "status": "response_too_large",
            "code": "helper_failed",
            "error": "helper response exceeded the protocol byte limit",
            "protocol_version": PROTOCOL_VERSION,
            "request_id": response.get("request_id", ""),
        }
    encoded = canonical_json(response) + b"\n"
    if len(encoded) > MAX_RESPONSE_BYTES:
        raise ProtocolError("helper response exceeded its preflight byte limit")
    connection.sendall(encoded)


def send_stream_frame(connection: socket.socket, frame: dict[str, object]) -> None:
    """Send one bounded Runner stream frame."""

    if _canonical_json_upper_bound(frame, MAX_STREAM_FRAME_BYTES - 1) > MAX_STREAM_FRAME_BYTES - 1:
        raise ProtocolError("runner stream frame exceeds the protocol byte limit")
    encoded = canonical_json(frame) + b"\n"
    if len(encoded) > MAX_STREAM_FRAME_BYTES:
        raise ProtocolError("runner stream frame exceeds the protocol byte limit")
    connection.sendall(encoded)


def systemd_listener() -> socket.socket:
    if int(os.environ.get("LISTEN_PID", "0") or "0") != os.getpid():
        raise RuntimeError("service requires systemd socket activation")
    if int(os.environ.get("LISTEN_FDS", "0") or "0") != 1:
        raise RuntimeError("service requires exactly one systemd socket")
    return socket.socket(fileno=os.dup(3))


def client_request(
    socket_path: str,
    request: dict[str, object],
    *,
    timeout: float = 30.0,
) -> dict[str, object]:
    encoded = canonical_json(request) + b"\n"
    if len(encoded) > MAX_REQUEST_BYTES:
        raise ProtocolError("request exceeds the protocol byte limit")
    response_bytes = bytearray()
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(timeout)
        connection.connect(socket_path)
        connection.sendall(encoded)
        connection.shutdown(socket.SHUT_WR)
        while True:
            chunk = connection.recv(65_536)
            if not chunk:
                break
            response_bytes.extend(chunk)
            if len(response_bytes) > MAX_RESPONSE_BYTES:
                raise ProtocolError("response exceeds the protocol byte limit")
    if not response_bytes:
        raise ProtocolError("helper returned an empty response")
    response_line, separator, remainder = bytes(response_bytes).partition(b"\n")
    if remainder or not separator:
        raise ProtocolError(
            "helper response must contain exactly one newline-terminated JSON object"
        )
    try:
        response = json.loads(
            response_line.decode("utf-8"),
            parse_constant=_reject_json_constant,
            object_pairs_hook=_reject_duplicate_keys,
        )
    except (UnicodeDecodeError, json.JSONDecodeError, ProtocolError) as exc:
        raise ProtocolError("helper returned invalid UTF-8 JSON") from exc
    if not isinstance(response, dict):
        raise ProtocolError("helper response must be a JSON object")
    if response.get("protocol_version") != PROTOCOL_VERSION:
        raise ProtocolError("helper response protocol_version does not match")
    if response.get("request_id") != request.get("request_id"):
        raise ProtocolError("helper response request_id does not match")
    if not isinstance(response.get("ok"), bool):
        raise ProtocolError("helper response ok must be boolean")
    if not isinstance(response.get("status"), str) or not response["status"]:
        raise ProtocolError("helper response status must be a non-empty string")
    return response
