"""Web-facing adapter for the shared audit-chain implementation.

This module deliberately contains no persistence logic of its own.  Bash and
Python callers use :mod:`lib.audit_chain` for identical hashing, locking,
rotation, permission, and durability semantics.
"""

import datetime
import getpass
import json
import math
import os
import sys
from pathlib import Path


ROOT = Path(os.environ.get("LINUX_AGENT_ROOT", Path(__file__).resolve().parents[1])).resolve()
LIB_ROOT = ROOT / "lib"
if str(LIB_ROOT) not in sys.path:
    sys.path.insert(0, str(LIB_ROOT))

from audit_chain import (  # noqa: E402
    AuditIntegrityError,
    AuditWriteBlocked,
    append_event,
    verify_chain,
)


DEFAULT_AUDIT_OPTIONS = {
    "fsync": True,
    "max_bytes": 52428800,
    "min_free_bytes": 10485760,
    "on_full": "degrade",
}
JSON_SAFE_INTEGER_MAX = 9007199254740991


def read_project_config():
    try:
        with (ROOT / "config" / "config.json").open("r", encoding="utf-8") as handle:
            return json.load(handle)
    except FileNotFoundError:
        return {}


def _config_bool(value, default, *, present):
    if not present:
        return default
    if not isinstance(value, bool):
        raise ValueError("audit.fsync must be a JSON boolean")
    return value


def _config_nonnegative(value, default, *, field, present):
    if not present:
        return default
    if (
        isinstance(value, bool)
        or not isinstance(value, (int, float))
        or not math.isfinite(value)
        or value != math.floor(value)
        or value < 0
        or value > JSON_SAFE_INTEGER_MAX
    ):
        raise ValueError(
            f"audit.{field} must be an integer from 0 to {JSON_SAFE_INTEGER_MAX}"
        )
    return int(value)


def audit_options_from_config(config):
    """Validate a full project config into ``audit_chain.append_event`` kwargs.

    This intentionally mirrors ``linux_agent_config_validate_audit``.  An
    explicit malformed value is never coerced or replaced with a default.
    """
    if not isinstance(config, dict):
        raise ValueError("project config must be a JSON object")
    if "audit" in config and not isinstance(config["audit"], dict):
        raise ValueError("audit must be a JSON object")
    audit = config.get("audit", {})
    if "integrity_chain" in audit:
        raise ValueError("audit.integrity_chain has been removed; hash chain is mandatory")
    on_full = audit.get("on_full", DEFAULT_AUDIT_OPTIONS["on_full"])
    if on_full not in {"degrade", "block"}:
        raise ValueError("audit.on_full must be degrade or block")
    return {
        "fsync": _config_bool(
            audit.get("fsync"),
            DEFAULT_AUDIT_OPTIONS["fsync"],
            present="fsync" in audit,
        ),
        "max_bytes": _config_nonnegative(
            audit.get("max_bytes"),
            DEFAULT_AUDIT_OPTIONS["max_bytes"],
            field="max_bytes",
            present="max_bytes" in audit,
        ),
        "min_free_bytes": _config_nonnegative(
            audit.get("min_free_bytes"),
            DEFAULT_AUDIT_OPTIONS["min_free_bytes"],
            field="min_free_bytes",
            present="min_free_bytes" in audit,
        ),
        "on_full": on_full,
    }


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def append_audit_event(log_path, session_id, stage, payload=None, config=None, **metadata):
    """Build and append one Web audit event through the shared writer.

    ``AuditWriteBlocked`` and ``AuditIntegrityError`` intentionally propagate
    so the HTTP/business layer can enforce ``audit.on_full=block`` instead of
    silently continuing without a required audit record.
    """
    event_payload = payload if isinstance(payload, dict) else {}
    system_user = str(metadata.pop("system_user", "") or getpass.getuser() or "unknown")
    request_id = str(metadata.pop("request_id", "") or event_payload.get("request_id") or "")
    job_id = str(metadata.pop("job_id", "") or event_payload.get("job_id") or "")
    execution_user = str(
        metadata.pop("execution_user", "")
        or event_payload.get("execution_user")
        or system_user
    )
    event = {
        "schema_version": 1,
        "timestamp": now_iso(),
        "session_id": str(session_id),
        "stage": str(stage),
        "request_id": request_id,
        "job_id": job_id,
        "system_user": system_user,
        "execution_user": execution_user,
        "payload": event_payload,
    }
    reserved = {
        "schema_version", "timestamp", "session_id", "stage", "payload",
        "request_id", "job_id", "system_user", "execution_user",
        "seq", "prev_hash", "hash", "rotated_from",
    }
    for key, value in metadata.items():
        if value is not None and key not in reserved:
            event[key] = value
    effective_config = read_project_config() if config is None else config
    return append_event(
        os.fspath(log_path),
        event,
        **audit_options_from_config(effective_config),
    )


def verify_audit_chain(log_path):
    return verify_chain(os.fspath(log_path))


__all__ = [
    "AuditIntegrityError",
    "AuditWriteBlocked",
    "append_audit_event",
    "audit_options_from_config",
    "read_project_config",
    "verify_audit_chain",
]
