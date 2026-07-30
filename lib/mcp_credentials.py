#!/usr/bin/env python3
"""Validate and transfer MCP credential profiles without exposing secrets."""

from __future__ import annotations

import fcntl
import copy
import hashlib
import json
import os
import re
import stat
import struct
import urllib.parse
from pathlib import Path
from typing import Any

import mcp_manifest


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SCHEMA = ROOT / "schema" / "mcp-credential-profile.json"
PROFILE_ID_PATTERN = re.compile(r"^[a-z0-9][a-z0-9_.-]{0,127}$")
MAX_PROFILE_BYTES = 262_144
UPDATE_HEADER = struct.Struct(">Q")
UPDATE_MEMFD_BYTES = UPDATE_HEADER.size + MAX_PROFILE_BYTES
REQUIRED_SEALS = (
    fcntl.F_SEAL_SEAL
    | fcntl.F_SEAL_SHRINK
    | fcntl.F_SEAL_GROW
    | fcntl.F_SEAL_WRITE
)
UPDATE_INITIAL_SEALS = fcntl.F_SEAL_SHRINK | fcntl.F_SEAL_GROW
UPDATE_FINAL_SEALS = UPDATE_INITIAL_SEALS | fcntl.F_SEAL_WRITE | fcntl.F_SEAL_SEAL


class McpCredentialError(ValueError):
    pass


def _reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise McpCredentialError("credential profile contains duplicate keys")
        result[key] = value
    return result


def validate_profile(payload: Any, expected_id: str | None = None) -> dict[str, Any]:
    try:
        schema = json.loads(DEFAULT_SCHEMA.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise McpCredentialError("credential profile schema is unavailable") from exc
    issues = mcp_manifest.validate(payload, schema)
    if issues:
        issue = issues[0]
        raise McpCredentialError(f"credential profile is invalid at {issue.path or '/'}")
    if not isinstance(payload, dict):
        raise McpCredentialError("credential profile must be an object")
    payload = copy.deepcopy(payload)
    profile_id = payload.get("id")
    if expected_id is not None and profile_id != expected_id:
        raise McpCredentialError("credential profile id does not match the manifest")
    profile_type = payload.get("type")
    allowed_by_type = {
        "static_headers": {
            "profile_version",
            "id",
            "type",
            "server_id",
            "server_url",
            "headers",
        },
        "oauth_authorization_code": {
            "profile_version",
            "id",
            "type",
            "server_id",
            "server_url",
            "authorization_server_issuer",
            "token_issuer",
            "client_metadata",
            "client_metadata_url",
            "allow_dynamic_registration",
            "tokens",
            "client_info",
        },
        "oauth_client_credentials": {
            "profile_version",
            "id",
            "type",
            "server_id",
            "server_url",
            "authorization_server_issuer",
            "token_issuer",
            "client_id",
            "client_secret",
            "application_type",
            "token_endpoint_auth_method",
            "scope",
            "tokens",
        },
    }
    if set(payload) - allowed_by_type.get(str(profile_type), set()):
        raise McpCredentialError("credential profile contains fields that are invalid for its type")
    if "tokens" in payload and payload.get("token_issuer") != payload.get(
        "authorization_server_issuer"
    ):
        # The administrator changed the configured issuer. Never reuse the old
        # token; let the pinned SDK obtain a token for the new issuer.
        payload.pop("tokens", None)
        payload.pop("token_issuer", None)
    if profile_type == "oauth_authorization_code":
        metadata = payload.get("client_metadata")
        if not isinstance(metadata, dict) or not metadata.get("redirect_uris"):
            raise McpCredentialError("OAuth redirect_uris cannot be empty")
        application_type = metadata.get("application_type")
        redirect_uris = metadata.get("redirect_uris")
        if not isinstance(redirect_uris, list) or len(set(redirect_uris)) != len(redirect_uris):
            raise McpCredentialError("OAuth redirect_uris must be unique")
        if application_type == "web" and any(
            urllib.parse.urlsplit(str(uri)).scheme.lower() != "https" for uri in redirect_uris
        ):
            raise McpCredentialError("web OAuth clients require HTTPS redirect_uris")
        if not payload.get("client_metadata_url") and payload.get("allow_dynamic_registration") is not True:
            raise McpCredentialError("OAuth requires a CIMD URL unless dynamic registration is explicitly enabled")
        client_info = payload.get("client_info")
        if isinstance(client_info, dict):
            metadata_url = payload.get("client_metadata_url")
            is_cimd = bool(metadata_url and client_info.get("client_id") == metadata_url)
            if not is_cimd and client_info.get("issuer") != payload.get(
                "authorization_server_issuer"
            ):
                # DCR credentials are not portable. Discard both registration
                # and tokens so SDK v2 re-registers against the new issuer.
                payload.pop("client_info", None)
                payload.pop("tokens", None)
                payload.pop("token_issuer", None)
                client_info = None
            stored_redirects = (
                client_info.get("redirect_uris")
                if isinstance(client_info, dict)
                else None
            )
            if stored_redirects is not None and stored_redirects != redirect_uris:
                raise McpCredentialError(
                    "stored OAuth client information does not match redirect_uris"
                )
    return payload


def validate_binding(profile: dict[str, Any], server_id: str, server_url: str) -> None:
    """Require one credential profile to belong to one logical MCP resource."""
    if profile.get("server_id") != server_id or profile.get("server_url") != server_url:
        raise McpCredentialError("credential profile is not bound to this MCP server")


def _read_profile(path: Path, expected_id: str) -> bytes:
    if PROFILE_ID_PATTERN.fullmatch(expected_id) is None:
        raise McpCredentialError("credential profile id is invalid")
    try:
        metadata = path.lstat()
        if not stat.S_ISREG(metadata.st_mode) or path.is_symlink():
            raise McpCredentialError("credential profile must be a regular non-symlink file")
        if metadata.st_mode & 0o077:
            raise McpCredentialError("credential profile permissions must be 0600")
        if not 0 < metadata.st_size <= MAX_PROFILE_BYTES:
            raise McpCredentialError("credential profile size is invalid")
        raw = path.read_bytes()
    except OSError as exc:
        raise McpCredentialError("credential profile is unavailable") from exc
    if len(raw) != metadata.st_size:
        raise McpCredentialError("credential profile changed while being read")
    return raw


def _parse_profile(raw: bytes, expected_id: str) -> dict[str, Any]:
    try:
        payload = json.loads(
            raw.decode("utf-8"),
            parse_constant=lambda _value: (_ for _ in ()).throw(
                McpCredentialError("credential profile contains an invalid number")
            ),
            object_pairs_hook=_reject_duplicate_keys,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise McpCredentialError("credential profile is not valid JSON") from exc
    return validate_profile(payload, expected_id)


def load_profile(path: Path, expected_id: str) -> dict[str, Any]:
    return _parse_profile(_read_profile(path, expected_id), expected_id)


def load_profile_snapshot(
    path: Path, expected_id: str
) -> tuple[dict[str, Any], str]:
    raw = _read_profile(path, expected_id)
    return _parse_profile(raw, expected_id), hashlib.sha256(raw).hexdigest()


def profile_sha256(path: Path, expected_id: str) -> str:
    return hashlib.sha256(_read_profile(path, expected_id)).hexdigest()


def sealed_profile_payload_fd(payload: dict[str, Any], expected_id: str) -> int:
    payload = validate_profile(payload, expected_id)
    if not hasattr(os, "memfd_create") or not hasattr(os, "MFD_ALLOW_SEALING"):
        raise McpCredentialError("sealed anonymous credential transfer is unsupported")
    raw = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    descriptor = os.memfd_create(
        "linux-agent-mcp-credential",
        getattr(os, "MFD_CLOEXEC", 0) | os.MFD_ALLOW_SEALING,
    )
    try:
        offset = 0
        while offset < len(raw):
            written = os.write(descriptor, raw[offset:])
            if written <= 0:
                raise OSError("credential memfd write made no progress")
            offset += written
        fcntl.fcntl(descriptor, fcntl.F_ADD_SEALS, REQUIRED_SEALS)
        if fcntl.fcntl(descriptor, fcntl.F_GET_SEALS) & REQUIRED_SEALS != REQUIRED_SEALS:
            raise McpCredentialError("credential memfd could not be sealed")
        return descriptor
    except Exception:
        os.close(descriptor)
        raise


def sealed_profile_fd(path: Path, expected_id: str) -> int:
    return sealed_profile_payload_fd(load_profile(path, expected_id), expected_id)


def profile_from_fd(descriptor: int, expected_id: str) -> dict[str, Any]:
    try:
        metadata = os.fstat(descriptor)
        seals = fcntl.fcntl(descriptor, fcntl.F_GET_SEALS)
    except OSError as exc:
        raise McpCredentialError("credential descriptor is unavailable") from exc
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_nlink != 0
        or not 0 < metadata.st_size <= MAX_PROFILE_BYTES
        or seals & REQUIRED_SEALS != REQUIRED_SEALS
    ):
        raise McpCredentialError("credential descriptor is not a bounded sealed memfd")
    raw = os.pread(descriptor, MAX_PROFILE_BYTES + 1, 0)
    if len(raw) != metadata.st_size:
        raise McpCredentialError("credential descriptor size changed")
    try:
        payload = json.loads(
            raw.decode("utf-8"),
            parse_constant=lambda _value: (_ for _ in ()).throw(
                McpCredentialError("credential descriptor contains an invalid number")
            ),
            object_pairs_hook=_reject_duplicate_keys,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise McpCredentialError("credential descriptor is not valid JSON") from exc
    return validate_profile(payload, expected_id)


def oauth_update_memfd() -> int:
    if not hasattr(os, "memfd_create") or not hasattr(os, "MFD_ALLOW_SEALING"):
        raise McpCredentialError("anonymous OAuth update transfer is unsupported")
    descriptor = os.memfd_create(
        "linux-agent-mcp-oauth-update",
        getattr(os, "MFD_CLOEXEC", 0) | os.MFD_ALLOW_SEALING,
    )
    try:
        os.ftruncate(descriptor, UPDATE_MEMFD_BYTES)
        fcntl.fcntl(descriptor, fcntl.F_ADD_SEALS, UPDATE_INITIAL_SEALS)
        if (
            fcntl.fcntl(descriptor, fcntl.F_GET_SEALS) & UPDATE_INITIAL_SEALS
            != UPDATE_INITIAL_SEALS
        ):
            raise McpCredentialError("OAuth update memfd could not be bounded")
        return descriptor
    except Exception:
        os.close(descriptor)
        raise


def validate_oauth_update_fd(descriptor: int) -> None:
    try:
        metadata = os.fstat(descriptor)
        seals = fcntl.fcntl(descriptor, fcntl.F_GET_SEALS)
    except OSError as exc:
        raise McpCredentialError("OAuth update descriptor is unavailable") from exc
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_nlink != 0
        or metadata.st_size != UPDATE_MEMFD_BYTES
        or seals & UPDATE_INITIAL_SEALS != UPDATE_INITIAL_SEALS
        or seals & (fcntl.F_SEAL_WRITE | fcntl.F_SEAL_SEAL)
    ):
        raise McpCredentialError("OAuth update descriptor is not a bounded writable memfd")


def _pwrite_all(descriptor: int, payload: bytes, offset: int) -> None:
    written = 0
    while written < len(payload):
        count = os.pwrite(descriptor, payload[written:], offset + written)
        if count <= 0:
            raise OSError("OAuth update memfd write made no progress")
        written += count


def write_oauth_update(descriptor: int, payload: dict[str, Any]) -> None:
    validate_oauth_update_fd(descriptor)
    raw = json.dumps(
        payload,
        ensure_ascii=False,
        separators=(",", ":"),
        allow_nan=False,
    ).encode("utf-8")
    if not raw or len(raw) > MAX_PROFILE_BYTES:
        raise McpCredentialError("OAuth update exceeds the credential size limit")
    # Invalidate the previous slot first, then commit the new length last. A
    # process terminated midway leaves an empty slot instead of partial JSON.
    _pwrite_all(descriptor, UPDATE_HEADER.pack(0), 0)
    _pwrite_all(descriptor, raw, UPDATE_HEADER.size)
    _pwrite_all(descriptor, UPDATE_HEADER.pack(len(raw)), 0)


def read_oauth_update(descriptor: int) -> dict[str, Any] | None:
    try:
        fcntl.fcntl(
            descriptor,
            fcntl.F_ADD_SEALS,
            fcntl.F_SEAL_WRITE | fcntl.F_SEAL_SEAL,
        )
        seals = fcntl.fcntl(descriptor, fcntl.F_GET_SEALS)
        if seals & UPDATE_FINAL_SEALS != UPDATE_FINAL_SEALS:
            raise McpCredentialError("OAuth update memfd could not be finalized")
        header = os.pread(descriptor, UPDATE_HEADER.size, 0)
        if len(header) != UPDATE_HEADER.size:
            raise McpCredentialError("OAuth update descriptor is truncated")
        length = UPDATE_HEADER.unpack(header)[0]
        if length == 0:
            return None
        if length > MAX_PROFILE_BYTES:
            raise McpCredentialError("OAuth update descriptor length is invalid")
        raw = os.pread(descriptor, length, UPDATE_HEADER.size)
    except OSError as exc:
        raise McpCredentialError("OAuth update descriptor cannot be read") from exc
    if len(raw) != length:
        raise McpCredentialError("OAuth update descriptor is truncated")
    try:
        payload = json.loads(
            raw.decode("utf-8"),
            parse_constant=lambda _value: (_ for _ in ()).throw(
                McpCredentialError("OAuth update contains an invalid number")
            ),
            object_pairs_hook=_reject_duplicate_keys,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise McpCredentialError("OAuth update is not valid JSON") from exc
    if not isinstance(payload, dict):
        raise McpCredentialError("OAuth update must be an object")
    return payload


def _profile_lock(path: Path) -> int:
    lock_path = path.with_name(f".{path.name}.lock")
    try:
        descriptor = os.open(
            lock_path,
            os.O_RDWR
            | os.O_CREAT
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0),
            0o600,
        )
        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != os.geteuid()
            or metadata.st_mode & 0o077
        ):
            raise McpCredentialError("credential profile lock is not private")
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        return descriptor
    except Exception:
        try:
            os.close(descriptor)
        except (OSError, UnboundLocalError):
            pass
        raise


def persist_oauth_update(
    path: Path,
    expected_id: str,
    baseline: dict[str, Any],
    update: dict[str, Any],
    baseline_sha256: str | None = None,
) -> None:
    required = {
        "version",
        "profile_id",
        "authorization_server_issuer",
    }
    if (
        not required.issubset(update)
        or set(update) - required - {"tokens", "client_info"}
        or update.get("version") != 1
        or update.get("profile_id") != expected_id
        or update.get("authorization_server_issuer")
        != baseline.get("authorization_server_issuer")
        or baseline.get("type")
        not in {"oauth_authorization_code", "oauth_client_credentials"}
    ):
        raise McpCredentialError("OAuth update does not match its credential profile")
    tokens = update.get("tokens")
    client_info = update.get("client_info")
    if "tokens" in update and not isinstance(tokens, dict):
        raise McpCredentialError("OAuth token update is invalid")
    if "client_info" in update and not isinstance(client_info, dict):
        raise McpCredentialError("OAuth client update is invalid")
    if "client_info" in update and baseline.get("type") != "oauth_authorization_code":
        raise McpCredentialError("OAuth client update is invalid for this profile")

    lock_descriptor = _profile_lock(path)
    try:
        if baseline_sha256 is not None and (
            not isinstance(baseline_sha256, str)
            or len(baseline_sha256) != 64
            or profile_sha256(path, expected_id) != baseline_sha256
        ):
            raise McpCredentialError("credential profile changed during OAuth execution")
        current = load_profile(path, expected_id)
        if current != baseline:
            raise McpCredentialError("credential profile changed during OAuth execution")
        merged = copy.deepcopy(current)
        if "tokens" in update:
            merged["tokens"] = tokens
            merged["token_issuer"] = baseline["authorization_server_issuer"]
        if "client_info" in update:
            merged["client_info"] = client_info
        merged = validate_profile(merged, expected_id)
        raw = json.dumps(
            merged,
            ensure_ascii=False,
            separators=(",", ":"),
            allow_nan=False,
        ).encode("utf-8")
        if not raw or len(raw) > MAX_PROFILE_BYTES:
            raise McpCredentialError(
                "updated credential profile exceeds the size limit"
            )

        temporary = path.with_name(
            f".{path.name}.{os.getpid()}.{os.urandom(8).hex()}"
        )
        descriptor = None
        try:
            descriptor = os.open(
                temporary,
                os.O_WRONLY
                | os.O_CREAT
                | os.O_EXCL
                | getattr(os, "O_CLOEXEC", 0)
                | getattr(os, "O_NOFOLLOW", 0),
                0o600,
            )
            with os.fdopen(descriptor, "wb") as handle:
                descriptor = None
                handle.write(raw)
                handle.write(b"\n")
                handle.flush()
                os.fsync(handle.fileno())
            if (
                load_profile(path, expected_id) != baseline
                or baseline_sha256 is not None
                and profile_sha256(path, expected_id) != baseline_sha256
            ):
                raise McpCredentialError(
                    "credential profile changed during OAuth execution"
                )
            os.replace(temporary, path)
            directory_fd = os.open(
                path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
            )
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
        except OSError as exc:
            raise McpCredentialError(
                "updated credential profile could not be persisted"
            ) from exc
        finally:
            if descriptor is not None:
                os.close(descriptor)
            try:
                temporary.unlink()
            except OSError:
                pass
    finally:
        os.close(lock_descriptor)
