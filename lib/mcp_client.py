#!/usr/bin/env python3
"""Stable JSON adapter for modern-first MCP tools/list and tools/call."""

from __future__ import annotations

import argparse
import asyncio
import builtins
import hashlib
import importlib.metadata
import json
import os
import re
import secrets
import ssl
import stat
import sys
import time
import urllib.parse
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any, AsyncIterator


LIB_ROOT = Path(__file__).resolve().parent
if str(LIB_ROOT) not in sys.path:
    sys.path.insert(0, str(LIB_ROOT))

import mcp_legacy_client as legacy
import mcp_credentials
import mcp_manifest
import mcp_runtime
from subprocess_env import apply_manifest_env, build_subprocess_env


MODERN_PROTOCOL_VERSION = "2026-07-28"
PROTOCOL_MODES = {"modern_then_legacy", "modern_only", "legacy_only"}
DEFAULT_TIMEOUT_SEC = 15.0
MAX_ARGUMENT_BYTES = 1_048_576
MAX_HTTP_REQUEST_BYTES = 1_048_576
MAX_RESPONSE_BYTES = 1_048_576
MAX_SCHEMA_BYTES = 262_144
MAX_SCHEMA_DEPTH = 64
MAX_SCHEMA_REFS = 128
MAX_SCHEMA_COMBINATOR_DEPTH = 16
MAX_TOOL_PAGES = 64
MAX_TOOLS = 4096
MAX_TOOL_CATALOG_BYTES = 4 * 1024 * 1024
MAX_INPUT_ROUNDS = 3
MAX_INPUT_ITEMS = 16
MAX_INPUT_BYTES = 65_536
INPUT_STATE_TTL_SEC = 900
MODERN_SELECTION_TTL_SEC = 300
FALLBACK_SELECTION_TTL_SEC = 60
MAX_SELECTION_CACHE_BYTES = 4096
RESERVED_HTTP_HEADERS = {
    "accept",
    "content-length",
    "content-type",
    "host",
    "traceparent",
    "tracestate",
    "baggage",
}
SECRET_PATTERN = re.compile(
    r"(?i)([\"']?(?:authorization|cookie|access[_-]?token|refresh[_-]?token|"
    r"client[_-]?secret|code[_-]?verifier|password|api[_-]?key|private[_-]?key|"
    r"assertion)[\"']?\s*[:=]\s*)([\"'][^\"']*[\"']|[^\s,;]+)"
)
ACTIVE_CREDENTIAL_SECRETS: set[str] = set()
BASE_EXCEPTION_GROUP = getattr(builtins, "BaseExceptionGroup", ())


class McpAdapterError(RuntimeError):
    def __init__(self, status: str, message: str, *, fallback_allowed: bool = False):
        self.status = status
        self.fallback_allowed = fallback_allowed
        super().__init__(message)


class McpResourceLimitError(McpAdapterError):
    def __init__(self, message: str):
        super().__init__("mcp_resource_limit", message)


class ModernFailure(RuntimeError):
    def __init__(self, cause: BaseException, *, call_sent: bool, result_received: bool):
        self.cause = cause
        self.call_sent = call_sent
        self.result_received = result_received
        super().__init__(str(cause))


class ModernNegotiationFailure(RuntimeError):
    def __init__(self, cause: BaseException):
        self.cause = cause
        super().__init__(str(cause))


def _register_credential_secret(value: Any) -> None:
    if isinstance(value, str) and value:
        ACTIVE_CREDENTIAL_SECRETS.add(value)


def register_credential_secrets(profile: dict[str, Any]) -> None:
    headers = profile.get("headers")
    if isinstance(headers, dict):
        for name, value in headers.items():
            _register_credential_secret(value)
            if not isinstance(name, str) or not isinstance(value, str):
                continue
            if name.lower() == "authorization":
                scheme, separator, credential = value.partition(" ")
                if separator and scheme.lower() in {"basic", "bearer", "digest"}:
                    _register_credential_secret(credential.strip())
            elif name.lower() == "cookie":
                for item in value.split(";"):
                    _, separator, cookie_value = item.partition("=")
                    if separator:
                        _register_credential_secret(cookie_value.strip())

    for key in ("access_token", "refresh_token", "id_token", "client_secret"):
        _register_credential_secret(profile.get(key))
    for container_name in ("tokens", "client_info"):
        container = profile.get(container_name)
        if not isinstance(container, dict):
            continue
        for key in ("access_token", "refresh_token", "id_token", "client_secret"):
            _register_credential_secret(container.get(key))


def redact_credential_secrets(value: Any) -> Any:
    if isinstance(value, dict):
        return {
            redact_credential_secrets(key): redact_credential_secrets(item)
            for key, item in value.items()
        }
    if isinstance(value, list):
        return [redact_credential_secrets(item) for item in value]
    if isinstance(value, str):
        for secret in sorted(ACTIVE_CREDENTIAL_SECRETS, key=len, reverse=True):
            value = value.replace(secret, "[REDACTED]")
    return value


def emit(payload: dict[str, Any], exit_code: int = 0) -> int:
    public_payload = redact_credential_secrets(payload)
    sys.stdout.write(
        json.dumps(public_payload, ensure_ascii=False, separators=(",", ":")) + "\n"
    )
    return exit_code


def clean_error(value: object) -> str:
    text = SECRET_PATTERN.sub(r"\1[REDACTED]", str(value))
    text = " ".join(text.replace("\x00", "").split())
    return text[:1000] or "MCP operation failed"


def load_json_file(path: str, *, max_bytes: int | None = None) -> Any:
    target = Path(path)
    if max_bytes is not None and target.stat().st_size > max_bytes:
        raise McpResourceLimitError(f"JSON input exceeds {max_bytes} bytes")
    with target.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def load_manifest(path: str) -> dict[str, Any]:
    target = Path(path)
    validation = mcp_manifest.validate_path(target)
    if not validation["ok"]:
        finding = next(
            (
                item
                for item in validation.get("findings", [])
                if item.get("severity") == "critical"
            ),
            {},
        )
        code = finding.get("code", "MCP_MANIFEST_SCHEMA_INVALID")
        pointer = finding.get("json_pointer", "/")
        message = finding.get("message", "manifest validation failed")
        raise McpAdapterError(
            "invalid_manifest",
            f"{code} at {pointer}: {message}",
        )
    try:
        manifest = load_json_file(path, max_bytes=mcp_manifest.MAX_MANIFEST_BYTES)
    except (OSError, json.JSONDecodeError) as exc:
        raise McpAdapterError("invalid_manifest", "MCP manifest is not valid JSON") from exc
    if not isinstance(manifest, dict):
        raise McpAdapterError("invalid_manifest", "MCP manifest must be a JSON object")
    return manifest


def protocol_mode(manifest: dict[str, Any]) -> tuple[str, bool]:
    protocol = manifest.get("protocol")
    if protocol is None:
        protocol = {}
    if not isinstance(protocol, dict):
        raise McpAdapterError("invalid_manifest", "manifest protocol must be an object")
    mode = protocol.get("mode", "modern_then_legacy")
    require_modern = protocol.get("require_modern", False)
    if mode not in PROTOCOL_MODES or not isinstance(require_modern, bool):
        raise McpAdapterError("invalid_manifest", "manifest protocol settings are invalid")
    if require_modern:
        mode = "modern_only"
    transport = manifest.get("transport")
    if transport == "sse":
        manifest_version = manifest.get("manifest_version", 1)
        compatibility = manifest.get("compatibility", {})
        allow_sse = isinstance(compatibility, dict) and compatibility.get("allow_legacy_sse") is True
        if manifest_version == 2 and not allow_sse:
            raise McpAdapterError("invalid_manifest", "manifest v2 requires allow_legacy_sse for sse transport")
        mode = "legacy_only"
    return mode, require_modern


def selection_cache_key(manifest: dict[str, Any]) -> str:
    canonical = json.dumps(
        manifest,
        sort_keys=True,
        ensure_ascii=False,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(canonical).hexdigest()


def selection_cache_directory() -> Path | None:
    configured = os.environ.get("LINUX_AGENT_MCP_SELECTION_CACHE_DIR")
    base = (
        Path(configured)
        if configured
        else Path(os.environ.get("LINUX_AGENT_TMP_ROOT", LIB_ROOT.parent / "tmp"))
        / ".mcp-selection-cache"
    )
    try:
        if base.is_symlink():
            return None
        base.mkdir(parents=True, exist_ok=True, mode=0o700)
        metadata = base.stat()
        if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.geteuid():
            return None
        if metadata.st_mode & 0o077:
            os.chmod(base, 0o700)
        return base.resolve()
    except OSError:
        return None


def selection_cache_path(manifest: dict[str, Any]) -> Path | None:
    directory = selection_cache_directory()
    if directory is None:
        return None
    return directory / f"{selection_cache_key(manifest)}.json"


def read_protocol_selection(manifest: dict[str, Any]) -> str | None:
    path = selection_cache_path(manifest)
    if path is None:
        return None
    try:
        metadata = path.lstat()
        if (
            not stat.S_ISREG(metadata.st_mode)
            or path.is_symlink()
            or metadata.st_uid != os.geteuid()
            or metadata.st_mode & 0o077
            or not 0 < metadata.st_size <= MAX_SELECTION_CACHE_BYTES
        ):
            return None
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return None
    if (
        not isinstance(payload, dict)
        or set(payload) != {"version", "manifest_sha256", "selection", "expires_at"}
        or payload.get("version") != 1
        or payload.get("manifest_sha256") != selection_cache_key(manifest)
        or payload.get("selection") not in {"modern", "legacy"}
        or isinstance(payload.get("expires_at"), bool)
        or not isinstance(payload.get("expires_at"), (int, float))
        or payload["expires_at"] <= time.time()
    ):
        return None
    return str(payload["selection"])


def write_protocol_selection(manifest: dict[str, Any], selection: str) -> None:
    if selection not in {"modern", "legacy"}:
        return
    path = selection_cache_path(manifest)
    if path is None:
        return
    ttl = (
        MODERN_SELECTION_TTL_SEC
        if selection == "modern"
        else FALLBACK_SELECTION_TTL_SEC
    )
    payload = {
        "version": 1,
        "manifest_sha256": selection_cache_key(manifest),
        "selection": selection,
        "expires_at": int(time.time()) + ttl,
    }
    raw = json.dumps(payload, ensure_ascii=True, separators=(",", ":")).encode(
        "utf-8"
    )
    if len(raw) > MAX_SELECTION_CACHE_BYTES:
        return
    temporary = path.with_name(f".{path.name}.{os.getpid()}.{secrets.token_hex(8)}")
    descriptor = None
    try:
        descriptor = os.open(
            temporary,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0),
            0o600,
        )
        with os.fdopen(descriptor, "wb") as handle:
            descriptor = None
            handle.write(raw)
            handle.write(b"\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    except OSError:
        pass
    finally:
        if descriptor is not None:
            os.close(descriptor)
        try:
            temporary.unlink()
        except (FileNotFoundError, OSError):
            pass


def manifest_timeout(manifest: dict[str, Any]) -> float:
    value = manifest.get("timeout_sec", DEFAULT_TIMEOUT_SEC)
    if isinstance(value, bool):
        raise McpAdapterError("invalid_manifest", "timeout_sec must be numeric")
    try:
        timeout = float(value)
    except (TypeError, ValueError) as exc:
        raise McpAdapterError("invalid_manifest", "timeout_sec must be numeric") from exc
    if timeout < 1 or timeout > 120:
        raise McpAdapterError("invalid_manifest", "timeout_sec must be between 1 and 120")
    return timeout


def validate_http_url(value: object) -> str:
    if not isinstance(value, str) or not value:
        raise McpAdapterError("invalid_manifest", "HTTP MCP manifest requires url")
    try:
        parsed = urllib.parse.urlsplit(value)
        port = parsed.port
    except ValueError as exc:
        raise McpAdapterError("invalid_manifest", "MCP URL is invalid") from exc
    if (
        parsed.scheme.lower() not in {"http", "https"}
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or port is not None and not 1 <= port <= 65535
    ):
        raise McpAdapterError("invalid_manifest", "MCP URL must be credential-free http(s)")
    return value


def http_origin(value: str) -> tuple[str, str, int]:
    try:
        parsed = urllib.parse.urlsplit(value)
        port = parsed.port
    except ValueError as exc:
        raise McpAdapterError("mcp_oauth_issuer_mismatch", "MCP OAuth URL is invalid") from exc
    scheme = parsed.scheme.lower()
    host = (parsed.hostname or "").lower()
    if scheme not in {"http", "https"} or not host:
        raise McpAdapterError("mcp_oauth_issuer_mismatch", "MCP OAuth URL is invalid")
    return scheme, host, port or (443 if scheme == "https" else 80)


def manifest_headers(manifest: dict[str, Any]) -> dict[str, str]:
    raw = manifest.get("headers", {})
    if not isinstance(raw, dict) or not all(isinstance(key, str) and isinstance(value, str) for key, value in raw.items()):
        raise McpAdapterError("invalid_manifest", "manifest headers must contain string values")
    headers: dict[str, str] = {}
    for key, value in raw.items():
        lower = key.lower()
        if lower in RESERVED_HTTP_HEADERS or lower.startswith("mcp-"):
            raise McpAdapterError("mcp_header_forbidden", f"manifest cannot override reserved header {key}")
        if "\r" in value or "\n" in value:
            raise McpAdapterError("mcp_header_forbidden", f"manifest header {key} contains a newline")
        headers[key] = value
    return headers


def load_credential_context(
    manifest: dict[str, Any],
) -> tuple[dict[str, Any] | None, int | None]:
    profile_id = manifest.get("credential_profile")
    descriptor_value = os.environ.pop("LINUX_AGENT_MCP_CREDENTIAL_FD", None)
    update_descriptor_value = os.environ.pop(
        "LINUX_AGENT_MCP_CREDENTIAL_UPDATE_FD", None
    )
    if profile_id is None:
        if descriptor_value is not None or update_descriptor_value is not None:
            raise McpAdapterError("mcp_credential_invalid", "unexpected MCP credential descriptor")
        return None, None
    if not isinstance(profile_id, str) or mcp_credentials.PROFILE_ID_PATTERN.fullmatch(profile_id) is None:
        raise McpAdapterError("mcp_credential_invalid", "MCP credential profile id is invalid")
    if descriptor_value is None or not descriptor_value.isascii() or not descriptor_value.isdigit():
        raise McpAdapterError(
            "mcp_credential_unavailable",
            "MCP credential profile must be supplied by the Runner",
        )
    descriptor = int(descriptor_value)
    if descriptor < 3:
        raise McpAdapterError("mcp_credential_invalid", "MCP credential descriptor is invalid")
    try:
        profile = mcp_credentials.profile_from_fd(descriptor, profile_id)
        server_id = manifest.get("id")
        server_url = manifest.get("url")
        if not isinstance(server_id, str) or not isinstance(server_url, str):
            raise mcp_credentials.McpCredentialError(
                "credential profiles require a Streamable HTTP MCP server"
            )
        mcp_credentials.validate_binding(profile, server_id, server_url)
        register_credential_secrets(profile)
        profile_type = profile.get("type")
        if profile_type in {
            "oauth_authorization_code",
            "oauth_client_credentials",
        }:
            if (
                update_descriptor_value is None
                or not update_descriptor_value.isascii()
                or not update_descriptor_value.isdigit()
            ):
                raise McpAdapterError(
                    "mcp_credential_unavailable",
                    "MCP OAuth update descriptor must be supplied by the Runner",
                )
            update_descriptor = int(update_descriptor_value)
            if update_descriptor < 3 or update_descriptor == descriptor:
                raise McpAdapterError(
                    "mcp_credential_invalid",
                    "MCP OAuth update descriptor is invalid",
                )
            mcp_credentials.validate_oauth_update_fd(update_descriptor)
            os.set_inheritable(update_descriptor, False)
            return profile, update_descriptor
        if update_descriptor_value is not None:
            raise McpAdapterError(
                "mcp_credential_invalid",
                "unexpected MCP OAuth update descriptor",
            )
        return profile, None
    except (OSError, mcp_credentials.McpCredentialError) as exc:
        if update_descriptor_value and update_descriptor_value.isdigit():
            try:
                os.close(int(update_descriptor_value))
            except OSError:
                pass
        raise McpAdapterError("mcp_credential_invalid", clean_error(exc)) from exc
    finally:
        try:
            os.close(descriptor)
        except OSError:
            pass


def credential_headers(
    manifest: dict[str, Any], profile: dict[str, Any] | None
) -> dict[str, str]:
    headers = manifest_headers(manifest)
    if profile is None:
        return headers
    if profile.get("type") != "static_headers":
        return headers
    profile_headers = profile.get("headers")
    if not isinstance(profile_headers, dict):
        raise McpAdapterError("mcp_credential_invalid", "static credential headers are invalid")
    existing = {key.lower() for key in headers}
    for key, value in profile_headers.items():
        if not isinstance(key, str) or not isinstance(value, str):
            raise McpAdapterError("mcp_credential_invalid", "static credential headers are invalid")
        if key.lower() in existing:
            raise McpAdapterError("mcp_credential_invalid", "credential and manifest headers conflict")
        headers[key] = value
        existing.add(key.lower())
    return headers


def oauth_provider(
    profile: dict[str, Any],
    server_url: str,
    error_box: dict[str, McpAdapterError],
    update_descriptor: int,
) -> Any:
    from mcp.client.auth import OAuthClientProvider
    from mcp.client.auth.extensions.client_credentials import ClientCredentialsOAuthProvider
    from mcp.shared.auth import OAuthClientInformationFull, OAuthClientMetadata, OAuthToken

    class MemoryStorage:
        def __init__(self) -> None:
            raw_tokens = profile.get("tokens")
            raw_client = profile.get("client_info")
            try:
                self.tokens = (
                    OAuthToken.model_validate(raw_tokens)
                    if isinstance(raw_tokens, dict)
                    else None
                )
                self.client_info = (
                    OAuthClientInformationFull.model_validate(raw_client)
                    if isinstance(raw_client, dict)
                    else None
                )
            except Exception as exc:
                raise McpAdapterError(
                    "mcp_credential_invalid",
                    "stored MCP OAuth state is invalid",
                ) from exc

        async def get_tokens(self) -> Any:
            return self.tokens

        async def set_tokens(self, tokens: Any) -> None:
            self.tokens = tokens
            self._publish()

        async def get_client_info(self) -> Any:
            return self.client_info

        async def set_client_info(self, client_info: Any) -> None:
            self.client_info = client_info

            self._publish()

        def _publish(self) -> None:
            update: dict[str, Any] = {
                "version": 1,
                "profile_id": str(profile.get("id") or ""),
                "authorization_server_issuer": expected_issuer,
            }
            if self.tokens is not None:
                update["tokens"] = self.tokens.model_dump(
                    by_alias=True,
                    mode="json",
                    exclude_none=True,
                )
            if self.client_info is not None:
                update["client_info"] = self.client_info.model_dump(
                    by_alias=True,
                    mode="json",
                    exclude_none=True,
                )
            register_credential_secrets(update)
            try:
                mcp_credentials.write_oauth_update(update_descriptor, update)
            except (OSError, mcp_credentials.McpCredentialError) as exc:
                raise McpAdapterError(
                    "mcp_credential_invalid",
                    "MCP OAuth state could not be returned to the Runner",
                ) from exc

    storage = MemoryStorage()
    expected_issuer = str(profile.get("authorization_server_issuer") or "")
    allow_dynamic_registration = profile.get("allow_dynamic_registration") is True
    if not expected_issuer:
        raise McpAdapterError(
            "mcp_credential_invalid",
            "OAuth credential profile requires an authorization server issuer",
        )

    class BoundOAuthProviderMixin:
        _linux_agent_error: McpAdapterError | None = None

        def _fail(self, status: str, message: str) -> None:
            error = McpAdapterError(status, message)
            self._linux_agent_error = error
            error_box["error"] = error
            raise error

        def _validate_oauth_issuer(self, *, require_metadata: bool = False) -> None:
            metadata_value = self.context.oauth_metadata
            if metadata_value is None:
                if require_metadata:
                    self._fail(
                        "mcp_oauth_issuer_mismatch",
                        "MCP OAuth authorization server metadata is unavailable",
                    )
                return
            if str(metadata_value.issuer) != expected_issuer:
                self._fail(
                    "mcp_oauth_issuer_mismatch",
                    "MCP OAuth authorization server issuer does not match the credential profile",
                )

        def _is_registration_request(self, request: Any) -> bool:
            if request.method.upper() != "POST":
                return False
            metadata_value = self.context.oauth_metadata
            if metadata_value is not None and metadata_value.registration_endpoint is not None:
                registration_url = str(metadata_value.registration_endpoint)
            else:
                base = self.context.get_authorization_base_url(self.context.server_url)
                registration_url = urllib.parse.urljoin(base, "/register")
            return str(request.url) == registration_url

        def _is_token_request(self, request: Any) -> bool:
            return request.method.upper() == "POST" and str(request.url) == self._get_token_endpoint()

        def _validate_outbound_url(self, request: Any) -> None:
            target = str(request.url)
            if target == server_url:
                return
            target_origin = http_origin(target)
            server_origin = http_origin(server_url)
            issuer_origin = http_origin(expected_issuer)
            metadata_value = self.context.oauth_metadata
            if metadata_value is None:
                # RFC 9728 protected-resource metadata is restricted to the
                # configured resource origin. RFC 8414/OIDC discovery is
                # restricted to the administrator-bound issuer origin.
                target_path = urllib.parse.urlsplit(target).path
                is_authorization_server_metadata = (
                    "/.well-known/oauth-authorization-server" in target_path
                    or "/.well-known/openid-configuration" in target_path
                )
                if is_authorization_server_metadata and target_origin == issuer_origin:
                    return
                if not is_authorization_server_metadata and target_origin in {
                    server_origin,
                    issuer_origin,
                }:
                    return
                self._fail(
                    "mcp_oauth_issuer_mismatch",
                    "MCP OAuth discovery escaped the configured server and issuer",
                )
            self._validate_oauth_issuer(require_metadata=True)
            allowed = {
                str(endpoint)
                for endpoint in (
                    metadata_value.authorization_endpoint,
                    metadata_value.token_endpoint,
                    metadata_value.registration_endpoint,
                )
                if endpoint is not None
            }
            if target not in allowed:
                self._fail(
                    "mcp_oauth_issuer_mismatch",
                    "MCP OAuth request targeted an endpoint outside validated metadata",
                )

        async def async_auth_flow(self, request: Any) -> AsyncIterator[Any]:
            flow = super().async_auth_flow(request)
            try:
                outbound = await anext(flow)
                while True:
                    self._validate_outbound_url(outbound)
                    registration = self._is_registration_request(outbound)
                    if registration or self._is_token_request(outbound):
                        # Never transmit a client secret, authorization code, refresh
                        # token, or registration metadata until the discovered AS is
                        # exactly the administrator-bound issuer.
                        self._validate_oauth_issuer(require_metadata=True)
                    if registration and not allow_dynamic_registration:
                        self._fail(
                            "mcp_oauth_registration_forbidden",
                            "MCP OAuth dynamic client registration is disabled",
                        )
                    response = yield outbound
                    outbound = await flow.asend(response)
            except StopAsyncIteration:
                return
            finally:
                await flow.aclose()

    profile_type = profile.get("type")
    if profile_type == "oauth_client_credentials":
        class GuardedClientCredentialsOAuthProvider(
            BoundOAuthProviderMixin, ClientCredentialsOAuthProvider
        ):
            pass

        provider = GuardedClientCredentialsOAuthProvider(
            server_url=server_url,
            storage=storage,
            client_id=str(profile.get("client_id") or ""),
            client_secret=str(profile.get("client_secret") or ""),
            token_endpoint_auth_method=profile.get("token_endpoint_auth_method", "client_secret_basic"),
            scope=profile.get("scope") if isinstance(profile.get("scope"), str) else None,
        )
        provider.context.client_metadata.application_type = profile.get("application_type", "native")
        return provider
    if profile_type != "oauth_authorization_code":
        raise McpAdapterError("mcp_credential_invalid", "unsupported MCP credential profile type")

    metadata = OAuthClientMetadata.model_validate(profile.get("client_metadata"))

    provider_holder: dict[str, Any] = {}

    async def interaction_required(_authorization_url: str) -> None:
        provider = provider_holder["provider"]
        provider._validate_oauth_issuer(require_metadata=True)
        provider._fail(
            "mcp_authorization_required",
            "MCP OAuth authorization requires an administrator-managed callback",
        )

    async def callback_unavailable() -> Any:
        provider_holder["provider"]._fail(
            "mcp_authorization_required",
            "MCP OAuth authorization requires an administrator-managed callback",
        )

    class GuardedOAuthProvider(BoundOAuthProviderMixin, OAuthClientProvider):
        pass

    provider = GuardedOAuthProvider(
        server_url=server_url,
        client_metadata=metadata,
        storage=storage,
        redirect_handler=interaction_required,
        callback_handler=callback_unavailable,
        client_metadata_url=(
            profile.get("client_metadata_url")
            if isinstance(profile.get("client_metadata_url"), str)
            else None
        ),
    )
    provider_holder["provider"] = provider
    return provider


def ensure_sdk_runtime() -> None:
    try:
        status = mcp_runtime.runtime_status(ensure=True)
    except (OSError, mcp_runtime.McpRuntimeError) as exc:
        raise McpAdapterError("mcp_sdk_unavailable", clean_error(exc)) from exc
    python_path = Path(str(status.get("python_path") or ""))
    if not status.get("ok") or not python_path.is_file():
        raise McpAdapterError("mcp_sdk_unavailable", "isolated MCP SDK runtime is unavailable")
    try:
        already_active = Path(sys.executable).resolve() == python_path.resolve()
    except OSError:
        already_active = False
    if already_active:
        try:
            if importlib.metadata.version("mcp") != "2.0.0" or importlib.metadata.version("mcp-types") != "2.0.0":
                raise McpAdapterError("mcp_sdk_unavailable", "isolated MCP SDK version mismatch")
        except importlib.metadata.PackageNotFoundError as exc:
            raise McpAdapterError("mcp_sdk_unavailable", "isolated MCP SDK packages are missing") from exc
        return
    environment = dict(os.environ)
    environment["LINUX_AGENT_MCP_RUNTIME_ACTIVE"] = "1"
    os.execve(
        python_path,
        [os.fspath(python_path), os.fspath(Path(__file__).resolve()), *sys.argv[1:]],
        environment,
    )


def json_size(value: Any) -> int:
    return len(json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))


def ensure_modern_call_request_limit(
    tool_name: str,
    arguments: dict[str, Any],
    input_responses: dict[str, Any] | None,
    request_state: str | None,
) -> None:
    params: dict[str, Any] = {
        "name": tool_name,
        "arguments": arguments,
        "_meta": {
            "io.modelcontextprotocol/protocolVersion": MODERN_PROTOCOL_VERSION,
            "io.modelcontextprotocol/clientInfo": {"name": "mcp", "version": "0.1.0"},
            "io.modelcontextprotocol/clientCapabilities": {},
        },
    }
    if input_responses is not None:
        params["inputResponses"] = input_responses
    if request_state is not None:
        params["requestState"] = request_state
    envelope = {
        "jsonrpc": "2.0",
        "id": (1 << 53) - 1,
        "method": "tools/call",
        "params": params,
    }
    # Leave room for any bounded SDK-owned metadata added after this adapter's
    # preflight. The transport independently enforces the exact wire limit.
    if json_size(envelope) > MAX_HTTP_REQUEST_BYTES - 4096:
        raise McpResourceLimitError(
            f"MCP HTTP request exceeds {MAX_HTTP_REQUEST_BYTES} bytes"
        )


def inspect_schema(value: Any) -> None:
    if not isinstance(value, dict):
        raise McpAdapterError("mcp_schema_invalid", "tool schema must be an object")
    if json_size(value) > MAX_SCHEMA_BYTES:
        raise McpResourceLimitError("tool schema exceeds the byte limit")
    refs = 0

    def visit(item: Any, depth: int, combinator_depth: int) -> None:
        nonlocal refs
        if depth > MAX_SCHEMA_DEPTH:
            raise McpResourceLimitError("tool schema exceeds the depth limit")
        if isinstance(item, dict):
            for key, child in item.items():
                next_combinator = combinator_depth + 1 if key in {"allOf", "anyOf", "oneOf", "not"} else combinator_depth
                if next_combinator > MAX_SCHEMA_COMBINATOR_DEPTH:
                    raise McpResourceLimitError("tool schema exceeds the combinator depth limit")
                if key == "$ref":
                    refs += 1
                    if refs > MAX_SCHEMA_REFS:
                        raise McpResourceLimitError("tool schema exceeds the reference limit")
                    if not isinstance(child, str):
                        raise McpAdapterError("mcp_schema_invalid", "tool schema $ref must be a string")
                visit(child, depth + 1, next_combinator)
        elif isinstance(item, list):
            for child in item:
                visit(child, depth + 1, combinator_depth)

    visit(value, 0, 0)


def normalize_tool(raw: dict[str, Any]) -> dict[str, Any]:
    name = raw.get("name")
    if not isinstance(name, str) or not name or len(name) > 256:
        raise McpAdapterError("mcp_tool_invalid", "tools/list returned an invalid tool name", fallback_allowed=True)
    description = raw.get("description", "")
    if description is None:
        description = ""
    if not isinstance(description, str) or len(description.encode("utf-8")) > 65_536:
        raise McpResourceLimitError(f"tool description exceeds the limit: {name}")
    input_schema = raw.get("inputSchema", {})
    inspect_schema(input_schema)
    result: dict[str, Any] = {"name": name, "description": description, "inputSchema": input_schema}
    annotations = raw.get("annotations")
    if isinstance(annotations, dict):
        result["annotations"] = annotations
    output_schema = raw.get("outputSchema")
    if output_schema is not None:
        inspect_schema(output_schema)
        result["outputSchema"] = output_schema
    return result


def normalize_tools(raw_tools: Any) -> list[dict[str, Any]]:
    if not isinstance(raw_tools, list):
        raise McpAdapterError("mcp_tool_list_invalid", "tools/list result.tools must be an array", fallback_allowed=True)
    if not all(isinstance(item, dict) for item in raw_tools):
        raise McpAdapterError(
            "mcp_tool_list_invalid",
            "tools/list result.tools must contain only objects",
            fallback_allowed=True,
        )
    return [normalize_tool(item) for item in raw_tools]


def model_json(value: Any) -> dict[str, Any]:
    dumped = value.model_dump(by_alias=True, mode="json", exclude_none=True)
    if not isinstance(dumped, dict):
        raise McpAdapterError("mcp_result_invalid", "MCP SDK returned a non-object result")
    fields = getattr(value.__class__, "model_fields", {})
    for field_name in getattr(value, "model_fields_set", set()):
        field = fields.get(field_name)
        if field is None or getattr(value, field_name, None) is not None:
            continue
        alias = field.serialization_alias or field.alias or field_name
        dumped[alias] = None
    return dumped


async def list_all_modern_tools(
    client: Any, *, cache_mode: str = "use"
) -> list[dict[str, Any]]:
    tools: list[dict[str, Any]] = []
    names: set[str] = set()
    cursors: set[str] = set()
    cursor: str | None = None
    for _page in range(MAX_TOOL_PAGES):
        result = await client.list_tools(cursor=cursor, cache_mode=cache_mode)
        raw = model_json(result)
        page = normalize_tools(raw.get("tools"))
        for tool in page:
            if tool["name"] in names:
                raise McpAdapterError("mcp_tool_list_invalid", "tools/list returned a duplicate tool name", fallback_allowed=True)
            names.add(tool["name"])
            tools.append(tool)
        if len(tools) > MAX_TOOLS or json_size(tools) > MAX_TOOL_CATALOG_BYTES:
            raise McpResourceLimitError("tools/list exceeds the catalog limit")
        next_cursor = raw.get("nextCursor")
        if next_cursor is None:
            return sorted(tools, key=lambda item: item["name"])
        if not isinstance(next_cursor, str) or not next_cursor or next_cursor in cursors:
            raise McpAdapterError("mcp_pagination_invalid", "tools/list returned an invalid or repeated cursor", fallback_allowed=True)
        cursors.add(next_cursor)
        cursor = next_cursor
    raise McpResourceLimitError("tools/list exceeds the page limit")


def server_metadata(client: Any) -> tuple[dict[str, Any], dict[str, Any]]:
    info = model_json(client.server_info) if client.server_info is not None else {}
    capabilities = model_json(client.server_capabilities)
    return info, capabilities


def sdk_transport(
    manifest: dict[str, Any],
    manifest_path: str,
    credential_profile: dict[str, Any] | None,
    credential_update_fd: int | None,
) -> Any:
    from mcp import StdioServerParameters
    from mcp.client.stdio import stdio_client

    transport = manifest.get("transport")
    if transport == "stdio":
        if credential_profile is not None:
            raise McpAdapterError(
                "mcp_credential_invalid",
                "credential profiles are only supported for Streamable HTTP",
            )
        command = manifest.get("command")
        arguments = manifest.get("args", [])
        if not isinstance(command, str) or not command:
            raise McpAdapterError("invalid_manifest", "stdio manifest command is required")
        if not isinstance(arguments, list) or not all(isinstance(item, str) for item in arguments):
            raise McpAdapterError("invalid_manifest", "stdio manifest args must contain strings")
        environment = build_subprocess_env(include_api_key=False)
        apply_manifest_env(environment, manifest.get("env"))
        guard = LIB_ROOT / "mcp_stdio_guard.py"
        parameters = StdioServerParameters(
            command=sys.executable,
            args=[os.fspath(guard), os.fspath(Path(manifest_path).resolve())],
            env=environment,
            cwd=Path(manifest_path).resolve().parent,
        )
        return stdio_client(parameters)
    if transport != "streamable_http":
        raise McpAdapterError("invalid_manifest", f"unsupported modern transport: {transport}")

    import httpx2
    import mcp.client.streamable_http as streamable_module

    url = validate_http_url(manifest.get("url"))
    headers = credential_headers(manifest, credential_profile)
    timeout = manifest_timeout(manifest)
    auth = None
    oauth_error_box: dict[str, McpAdapterError] = {}
    if credential_profile is not None and credential_profile.get("type") != "static_headers":
        if credential_update_fd is None:
            raise McpAdapterError(
                "mcp_credential_unavailable",
                "MCP OAuth update descriptor is unavailable",
            )
        auth = oauth_provider(
            credential_profile,
            url,
            oauth_error_box,
            credential_update_fd,
        )

    class LimitedResponseStream(httpx2.AsyncByteStream):
        def __init__(self, stream: Any, limit: int):
            self.stream = stream
            self.limit = limit
            self.total = 0

        async def __aiter__(self) -> AsyncIterator[bytes]:
            async for chunk in self.stream:
                self.total += len(chunk)
                if self.total > self.limit:
                    raise httpx2.ReadError(f"MCP HTTP response exceeds {self.limit} bytes")
                yield chunk

        async def aclose(self) -> None:
            await self.stream.aclose()

    class LimitedRequestStream(httpx2.AsyncByteStream):
        def __init__(self, stream: Any, limit: int):
            self.stream = stream
            self.limit = limit
            self.total = 0

        async def __aiter__(self) -> AsyncIterator[bytes]:
            async for chunk in self.stream:
                self.total += len(chunk)
                if self.total > self.limit:
                    # A streaming request may already be partially written, so
                    # retain the transport error and the adapter's unknown-outcome
                    # classification for tools/call.
                    raise httpx2.WriteError(
                        f"MCP HTTP request exceeds {self.limit} bytes"
                    )
                yield chunk

        async def aclose(self) -> None:
            close = getattr(self.stream, "aclose", None)
            if close is not None:
                await close()

    class LimitedTransport(httpx2.AsyncBaseTransport):
        def __init__(self) -> None:
            self.inner = httpx2.AsyncHTTPTransport(
                trust_env=False,
                retries=0,
                limits=httpx2.Limits(max_connections=4, max_keepalive_connections=2),
            )

        async def handle_async_request(self, request: Any) -> Any:
            length = request.headers.get("content-length")
            if length is not None:
                try:
                    if int(length) > MAX_HTTP_REQUEST_BYTES:
                        # httpx has not handed this request to the network
                        # transport yet, so this local refusal has a known
                        # outcome even for tools/call.
                        raise McpResourceLimitError(
                            f"MCP HTTP request exceeds {MAX_HTTP_REQUEST_BYTES} bytes"
                        )
                except ValueError:
                    pass
            request.stream = LimitedRequestStream(
                request.stream, MAX_HTTP_REQUEST_BYTES
            )
            response = await self.inner.handle_async_request(request)
            length = response.headers.get("content-length")
            if length is not None:
                try:
                    if int(length) > MAX_RESPONSE_BYTES:
                        await response.aclose()
                        raise httpx2.ReadError(f"MCP HTTP response exceeds {MAX_RESPONSE_BYTES} bytes")
                except ValueError:
                    pass
            response.stream = LimitedResponseStream(response.stream, MAX_RESPONSE_BYTES)
            return response

        async def aclose(self) -> None:
            await self.inner.aclose()

    http_client = httpx2.AsyncClient(
        headers=headers,
        auth=auth,
        timeout=httpx2.Timeout(timeout, connect=timeout, read=timeout, write=timeout, pool=timeout),
        follow_redirects=False,
        trust_env=False,
        transport=LimitedTransport(),
    )
    # Modern response streams must never send Last-Event-ID. The pinned SDK
    # resolves a disconnected request immediately when this retry cap is zero.
    streamable_module.MAX_RECONNECTION_ATTEMPTS = 0

    @asynccontextmanager
    async def managed_transport() -> AsyncIterator[Any]:
        try:
            async with http_client:
                async with streamable_module.streamable_http_client(
                    url,
                    http_client=http_client,
                    terminate_on_close=False,
                ) as streams:
                    yield streams
        except BaseException as exc:
            oauth_error = oauth_error_box.get("error") or getattr(
                auth, "_linux_agent_error", None
            )
            if isinstance(oauth_error, McpAdapterError):
                raise oauth_error from exc
            raise

    transport_context = managed_transport()
    setattr(transport_context, "linux_agent_oauth_error_box", oauth_error_box)
    return transport_context


async def connect_modern(
    manifest: dict[str, Any],
    manifest_path: str,
    credential_profile: dict[str, Any] | None,
    credential_update_fd: int | None = None,
    *,
    skip_discover: bool = False,
) -> Any:
    from mcp import Client
    from mcp.client import CacheConfig
    from mcp.shared.exceptions import MCPError
    from mcp_types import (
        UNSUPPORTED_PROTOCOL_VERSION,
        DiscoverResult,
        UnsupportedProtocolVersionErrorData,
    )
    from pydantic import ValidationError

    transport_context = sdk_transport(
        manifest,
        manifest_path,
        credential_profile,
        credential_update_fd,
    )
    client = Client(
        transport_context,
        mode=MODERN_PROTOCOL_VERSION,
        read_timeout_seconds=manifest_timeout(manifest),
        # Keep cache entries private to this Client/process. The SDK then
        # honors ttlMs/cacheScope without introducing a shared principal
        # boundary or writing catalog data to disk.
        cache=CacheConfig(default_ttl_ms=0, share_public=False),
        sampling_callback=None,
        list_roots_callback=None,
        logging_callback=None,
        elicitation_callback=None,
    )
    entered = False
    try:
        await client.__aenter__()
        entered = True
        client.session._dispatcher._next_id = secrets.randbelow((1 << 53) - 10_000)
        if skip_discover:
            if client.protocol_version != MODERN_PROTOCOL_VERSION:
                raise McpAdapterError(
                    "mcp_protocol_unsupported",
                    "cached modern protocol selection is no longer valid",
                    fallback_allowed=True,
                )
            return client
        # A version-pinned SDK Client installs synthetic discover state when it
        # enters, so call send_discover explicitly to preserve a real read-only
        # compatibility probe. Retry at most once only when the server returns
        # UnsupportedProtocolVersion and explicitly names our modern version.
        try:
            raw = await client.session.send_discover(MODERN_PROTOCOL_VERSION)
        except MCPError as exc:
            if exc.code != UNSUPPORTED_PROTOCOL_VERSION:
                raise
            try:
                rejection = UnsupportedProtocolVersionErrorData.model_validate(
                    exc.data
                )
            except ValidationError:
                raise exc from None
            if MODERN_PROTOCOL_VERSION not in rejection.supported:
                raise
            raw = await client.session.send_discover(MODERN_PROTOCOL_VERSION)
        discover = DiscoverResult.model_validate(raw)
        if MODERN_PROTOCOL_VERSION not in discover.supported_versions:
            legacy_supported = bool(
                set(discover.supported_versions) & legacy.SUPPORTED_PROTOCOL_VERSIONS
            )
            raise McpAdapterError(
                "mcp_protocol_unsupported",
                "server does not support MCP 2026-07-28",
                fallback_allowed=legacy_supported,
            )
        client.session.adopt(discover)
        if client.protocol_version != MODERN_PROTOCOL_VERSION:
            raise McpAdapterError(
                "mcp_protocol_unsupported",
                "server selected an unsupported modern protocol",
                fallback_allowed=True,
            )
        return client
    except BaseException as exc:
        oauth_error_box = getattr(
            transport_context, "linux_agent_oauth_error_box", {}
        )
        oauth_error = (
            oauth_error_box.get("error")
            if isinstance(oauth_error_box, dict)
            else None
        )
        if entered:
            try:
                await client.__aexit__(*sys.exc_info())
            except BaseException:
                pass
        if isinstance(oauth_error, McpAdapterError):
            exc = oauth_error
        raise ModernNegotiationFailure(exc) from exc


def normalize_result(raw: dict[str, Any]) -> dict[str, Any]:
    result = dict(raw)
    result.setdefault("resultType", "complete")
    content = result.get("content")
    if content is None:
        result["content"] = []
    elif not isinstance(content, list):
        raise McpAdapterError("mcp_result_invalid", "tools/call content must be an array")
    if json_size(result) > MAX_RESPONSE_BYTES:
        raise McpResourceLimitError("MCP tool result exceeds the response limit")
    return result


def input_state_directory(arguments_file: str) -> Path:
    configured = os.environ.get("LINUX_AGENT_MCP_STATE_DIR")
    target = Path(configured).resolve() if configured else Path(arguments_file).resolve().parent
    if configured:
        if not target.is_dir() or Path(configured).is_symlink():
            raise McpAdapterError(
                "mcp_input_state_unavailable",
                "MCP continuation output directory is unavailable",
            )
    else:
        target.mkdir(parents=True, exist_ok=True, mode=0o700)
    return target


def current_flow_digest() -> str:
    flow_id = os.environ.get("LINUX_AGENT_MCP_FLOW_ID", "")
    if not flow_id:
        flow_id = os.environ.get("LINUX_AGENT_JOB_ID", "") or os.environ.get(
            "LINUX_AGENT_SESSION_ID", ""
        )
    return hashlib.sha256(flow_id.encode("utf-8")).hexdigest() if flow_id else ""


def write_input_state(
    arguments_file: str,
    manifest: dict[str, Any],
    tool_name: str,
    arguments: dict[str, Any],
    request_state: str | None,
    input_requests: dict[str, Any],
    round_number: int,
    input_bytes: int,
) -> tuple[Path, str, int]:
    expires_at = int(time.time()) + INPUT_STATE_TTL_SEC
    payload = {
        "version": 1,
        "server_id": str(manifest.get("id") or ""),
        "tool": tool_name,
        "flow_sha256": current_flow_digest(),
        "arguments_sha256": hashlib.sha256(
            json.dumps(arguments, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        ).hexdigest(),
        "request_state": request_state,
        "input_requests": input_requests,
        "round": round_number,
        "input_bytes": input_bytes,
        "expires_at": expires_at,
    }
    if json_size(payload) > MAX_INPUT_BYTES:
        raise McpResourceLimitError("MCP input continuation state exceeds the limit")
    state_dir = input_state_directory(arguments_file)
    filename = f"mcp-state.{secrets.token_hex(16)}.json"
    path = state_dir / filename
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False, separators=(",", ":"))
        handle.write("\n")
    digest = hashlib.sha256((request_state or "").encode("utf-8")).hexdigest()
    return path, digest, expires_at


def load_continuation(
    path_value: str | None,
    responses_value: str | None,
    arguments_file: str,
    manifest: dict[str, Any],
    tool_name: str,
    arguments: dict[str, Any],
) -> tuple[dict[str, Any] | None, str | None, int, int, Path | None]:
    if path_value is None and responses_value is None:
        return None, None, 1, 0, None
    if not path_value or not responses_value:
        raise McpAdapterError("mcp_input_invalid", "continuation and input responses must be provided together")
    staging_root = Path(arguments_file).resolve().parent
    configured_state_root = os.environ.get("LINUX_AGENT_MCP_CONTINUATION_ROOT")
    state_root = (
        Path(configured_state_root).resolve()
        if configured_state_root
        else staging_root
    )
    unresolved_paths = (Path(path_value), Path(responses_value))
    if any(path.is_symlink() for path in unresolved_paths):
        raise McpAdapterError("mcp_input_invalid", "MCP input files cannot be symbolic links")
    state_path, response_path = (path.resolve() for path in unresolved_paths)
    for path, root in ((state_path, state_root), (response_path, staging_root)):
        try:
            path.relative_to(root)
        except ValueError as exc:
            raise McpAdapterError("mcp_input_invalid", "MCP input file is outside the private staging directory") from exc
        metadata = path.stat()
        if not stat.S_ISREG(metadata.st_mode):
            raise McpAdapterError("mcp_input_invalid", "MCP input files must be private regular files")
        if metadata.st_size > MAX_INPUT_BYTES:
            raise McpResourceLimitError("MCP input file exceeds the limit")
    state_mode = stat.S_IMODE(state_path.stat().st_mode)
    response_mode = stat.S_IMODE(response_path.stat().st_mode)
    exchange_mode = os.environ.get("LINUX_AGENT_EXECUTION_ISOLATION") == "runner_uid"
    if state_mode != 0o600 or response_mode not in ({0o600, 0o640} if exchange_mode else {0o600}):
        raise McpAdapterError("mcp_input_invalid", "MCP input files have unsafe permissions")
    state = load_json_file(os.fspath(state_path), max_bytes=MAX_INPUT_BYTES)
    responses = load_json_file(os.fspath(response_path), max_bytes=MAX_INPUT_BYTES)
    if not isinstance(state, dict) or not isinstance(responses, dict):
        raise McpAdapterError("mcp_input_invalid", "MCP continuation payloads must be objects")
    expected_digest = hashlib.sha256(
        json.dumps(arguments, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    ).hexdigest()
    if (
        state.get("version") != 1
        or state.get("server_id") != str(manifest.get("id") or "")
        or state.get("tool") != tool_name
        or state.get("flow_sha256", "") != current_flow_digest()
        or state.get("arguments_sha256") != expected_digest
    ):
        raise McpAdapterError("mcp_input_invalid", "MCP continuation is not bound to this request")
    round_number = state.get("round")
    prior_input_bytes = state.get("input_bytes")
    expires_at = state.get("expires_at")
    input_requests = state.get("input_requests")
    if (
        not isinstance(round_number, int)
        or round_number < 1
        or round_number > MAX_INPUT_ROUNDS
        or not isinstance(prior_input_bytes, int)
        or prior_input_bytes < 0
        or prior_input_bytes > MAX_INPUT_BYTES
        or not isinstance(expires_at, int)
        or expires_at < int(time.time())
        or not isinstance(input_requests, dict)
        or sorted(responses) != sorted(input_requests)
        or len(responses) > MAX_INPUT_ITEMS
    ):
        raise McpAdapterError("mcp_input_expired", "MCP continuation is expired or does not match its input requests")
    validate_input_responses(input_requests, responses)
    input_bytes = prior_input_bytes + json_size(responses)
    if input_bytes > MAX_INPUT_BYTES:
        raise McpResourceLimitError("MCP input responses exceed the cumulative limit")
    request_state = state.get("request_state")
    if request_state is not None and not isinstance(request_state, str):
        raise McpAdapterError("mcp_input_invalid", "MCP requestState is invalid")
    return responses, request_state, round_number + 1, input_bytes, state_path


def remove_consumed_state(path: Path | None) -> None:
    if path is None:
        return
    try:
        path.unlink(missing_ok=True)
    except PermissionError:
        if os.environ.get("LINUX_AGENT_EXECUTION_ISOLATION") != "runner_uid":
            raise


def validate_input_responses(
    input_requests: dict[str, Any], responses: dict[str, Any]
) -> None:
    from jsonschema import Draft202012Validator
    from jsonschema.exceptions import SchemaError, ValidationError
    from referencing import Registry
    from referencing.exceptions import NoSuchResource, Unresolvable

    def deny_external_reference(uri: str) -> None:
        raise NoSuchResource(ref=uri)

    offline_registry = Registry(retrieve=deny_external_reference)

    for key, request in input_requests.items():
        if not isinstance(request, dict) or request.get("method") != "elicitation/create":
            raise McpAdapterError("mcp_input_unsupported", "only elicitation input requests are supported")
        response = responses.get(key)
        if not isinstance(response, dict) or set(response) - {"action", "content"}:
            raise McpAdapterError("mcp_input_invalid", f"MCP input response is invalid: {key}")
        action = response.get("action")
        if action not in {"accept", "decline", "cancel"}:
            raise McpAdapterError("mcp_input_invalid", f"MCP input response action is invalid: {key}")
        params = request.get("params")
        if not isinstance(params, dict):
            raise McpAdapterError("mcp_input_invalid", f"MCP elicitation request params are invalid: {key}")
        mode = params.get("mode", "form")
        content = response.get("content")
        if mode == "url":
            if "content" in response and content is not None:
                raise McpAdapterError("mcp_input_invalid", f"URL elicitation cannot include content: {key}")
            continue
        if mode != "form":
            raise McpAdapterError("mcp_input_unsupported", f"MCP elicitation mode is unsupported: {key}")
        if action != "accept":
            if "content" in response and content is not None:
                raise McpAdapterError("mcp_input_invalid", f"declined MCP input cannot include content: {key}")
            continue
        schema = params.get("requestedSchema")
        if not isinstance(schema, dict) or not isinstance(content, dict):
            raise McpAdapterError("mcp_input_invalid", f"accepted MCP form input is invalid: {key}")
        inspect_schema(schema)
        try:
            Draft202012Validator.check_schema(schema)
            Draft202012Validator(schema, registry=offline_registry).validate(content)
        except (SchemaError, Unresolvable, ValidationError) as exc:
            raise McpAdapterError("mcp_input_invalid", f"MCP form input does not match its schema: {key}") from exc


def normalize_input_required(
    raw: dict[str, Any],
    arguments_file: str,
    manifest: dict[str, Any],
    tool_name: str,
    arguments: dict[str, Any],
    round_number: int,
    input_bytes: int,
) -> dict[str, Any]:
    requests = raw.get("inputRequests") or {}
    if not isinstance(requests, dict) or not requests:
        raise McpAdapterError("mcp_input_invalid", "InputRequiredResult has no input requests")
    if len(requests) > MAX_INPUT_ITEMS or json_size(requests) > MAX_INPUT_BYTES:
        raise McpResourceLimitError("MCP input requests exceed the limit")
    for request in requests.values():
        if not isinstance(request, dict) or request.get("method") != "elicitation/create":
            raise McpAdapterError("mcp_input_unsupported", "only elicitation input requests are supported")
    if round_number > MAX_INPUT_ROUNDS:
        raise McpAdapterError("mcp_input_rounds_exceeded", "MCP input exceeded the round limit")
    request_state = raw.get("requestState")
    if request_state is not None and not isinstance(request_state, str):
        raise McpAdapterError("mcp_input_invalid", "InputRequiredResult requestState is invalid")
    state_path, state_digest, expires_at = write_input_state(
        arguments_file,
        manifest,
        tool_name,
        arguments,
        request_state,
        requests,
        round_number,
        input_bytes,
    )
    return {
        "inputRequests": requests,
        "request_state_digest": state_digest,
        "continuation_file": os.fspath(state_path),
        "round": round_number,
        "expires_at": expires_at,
    }


async def modern_list(
    manifest: dict[str, Any],
    manifest_path: str,
    credential_profile: dict[str, Any] | None,
    credential_update_fd: int | None = None,
    *,
    refresh: bool = False,
    skip_discover: bool = False,
) -> dict[str, Any]:
    client = await connect_modern(
        manifest,
        manifest_path,
        credential_profile,
        credential_update_fd,
        skip_discover=skip_discover,
    )
    try:
        try:
            tools = await list_all_modern_tools(
                client, cache_mode="refresh" if refresh else "use"
            )
        except BaseException as exc:
            # Protocol selection is not locked until the first read-only
            # tools/list probe succeeds. Compatibility failures in this phase
            # may still use the frozen legacy client on a fresh connection.
            raise ModernNegotiationFailure(exc) from exc
        server_info, capabilities = server_metadata(client)
        return {
            "tools": tools,
            "server_info": server_info,
            "server_capabilities": capabilities,
            "protocol_version": client.protocol_version,
        }
    finally:
        await client.__aexit__(None, None, None)


async def modern_call(
    manifest: dict[str, Any],
    manifest_path: str,
    tool_name: str,
    arguments: dict[str, Any],
    arguments_file: str,
    continuation_file: str | None,
    input_responses_file: str | None,
    credential_profile: dict[str, Any] | None,
    credential_update_fd: int | None = None,
    *,
    skip_discover: bool = False,
) -> dict[str, Any]:
    from mcp_types import InputRequiredResult, InputResponses
    from pydantic import TypeAdapter

    call_sent = False
    result_received = False
    client = None
    prior_state_path: Path | None = None
    try:
        responses, request_state, round_number, input_bytes, prior_state_path = load_continuation(
            continuation_file,
            input_responses_file,
            arguments_file,
            manifest,
            tool_name,
            arguments,
        )
        typed_responses = TypeAdapter(InputResponses).validate_python(responses) if responses is not None else None
        client = await connect_modern(
            manifest,
            manifest_path,
            credential_profile,
            credential_update_fd,
            skip_discover=skip_discover,
        )
        try:
            tools = await list_all_modern_tools(client)
        except BaseException as exc:
            # tools/list is the final compatibility probe. No tools/call has
            # been sent yet, so an explicitly fallback-safe failure can still
            # restart through the legacy client.
            raise ModernNegotiationFailure(exc) from exc
        if tool_name not in {tool["name"] for tool in tools}:
            raise McpAdapterError("tool_not_found", "MCP tool was not declared by tools/list")
        server_info, capabilities = server_metadata(client)
        ensure_modern_call_request_limit(
            tool_name,
            arguments,
            responses,
            request_state,
        )
        call_sent = True
        result = await client.session.call_tool(
            tool_name,
            arguments,
            input_responses=typed_responses,
            request_state=request_state,
            allow_input_required=True,
        )
        result_received = True
        raw = model_json(result)
        if isinstance(result, InputRequiredResult):
            continuation = normalize_input_required(
                raw,
                arguments_file,
                manifest,
                tool_name,
                arguments,
                round_number,
                input_bytes,
            )
            raw.pop("requestState", None)
            remove_consumed_state(prior_state_path)
            return {
                "input_required": True,
                "result": normalize_result(raw),
                "continuation": continuation,
                "server_info": server_info,
                "server_capabilities": capabilities,
                "protocol_version": client.protocol_version,
            }
        remove_consumed_state(prior_state_path)
        return {
            "input_required": False,
            "result": normalize_result(raw),
            "server_info": server_info,
            "server_capabilities": capabilities,
            "protocol_version": client.protocol_version,
        }
    except BaseException as exc:
        if call_sent:
            try:
                from mcp.shared.exceptions import MCPError
                from mcp_types import CONNECTION_CLOSED, REQUEST_TIMEOUT

                if any(
                    isinstance(value, MCPError)
                    and value.code not in {CONNECTION_CLOSED, REQUEST_TIMEOUT}
                    for value in exception_tree(exc)
                ):
                    result_received = True
            except ImportError:
                pass
        raise ModernFailure(exc, call_sent=call_sent, result_received=result_received) from exc
    finally:
        if client is not None:
            unwinding = sys.exc_info()[0] is not None
            try:
                await client.__aexit__(None, None, None)
            except BaseException as exc:
                if not unwinding:
                    raise ModernFailure(exc, call_sent=call_sent, result_received=result_received) from exc


def legacy_transport_manifest(
    manifest: dict[str, Any], manifest_path: str
) -> dict[str, Any]:
    if manifest.get("transport") != "stdio":
        return manifest
    guard = LIB_ROOT / "mcp_stdio_guard.py"
    effective = dict(manifest)
    effective["command"] = sys.executable
    effective["args"] = [
        os.fspath(guard),
        os.fspath(Path(manifest_path).resolve()),
    ]
    effective["cwd"] = os.fspath(Path(manifest_path).resolve().parent)
    effective["env"] = {}
    return effective


def legacy_list(manifest: dict[str, Any], manifest_path: str) -> dict[str, Any]:
    client = legacy.create_client(
        legacy_transport_manifest(manifest, manifest_path), manifest_path
    )
    try:
        initialize = client.initialize()
        tools: list[dict[str, Any]] = []
        cursor: str | None = None
        seen: set[str] = set()
        for _page in range(MAX_TOOL_PAGES):
            params = {"cursor": cursor} if cursor is not None else None
            result = client.request("tools/list", params)
            tools.extend(normalize_tools(result.get("tools")))
            if len(tools) > MAX_TOOLS or json_size(tools) > MAX_TOOL_CATALOG_BYTES:
                raise McpResourceLimitError("legacy tools/list exceeds the catalog limit")
            cursor = result.get("nextCursor")
            if cursor is None:
                break
            if not isinstance(cursor, str) or not cursor or cursor in seen:
                raise McpAdapterError("mcp_pagination_invalid", "legacy tools/list returned an invalid cursor")
            seen.add(cursor)
        else:
            raise McpResourceLimitError("legacy tools/list exceeds the page limit")
        names = [tool["name"] for tool in tools]
        if len(names) != len(set(names)):
            raise McpAdapterError("mcp_tool_list_invalid", "legacy tools/list returned duplicate tools")
        return {
            "tools": sorted(tools, key=lambda item: item["name"]),
            "server_info": initialize.get("serverInfo") if isinstance(initialize.get("serverInfo"), dict) else {},
            "server_capabilities": initialize.get("capabilities") if isinstance(initialize.get("capabilities"), dict) else {},
            "protocol_version": client.negotiated_protocol,
        }
    finally:
        client.close()


def legacy_call(
    manifest: dict[str, Any], manifest_path: str, tool_name: str, arguments: dict[str, Any]
) -> dict[str, Any]:
    client = legacy.create_client(
        legacy_transport_manifest(manifest, manifest_path), manifest_path
    )
    call_sent = False
    try:
        initialize = client.initialize()
        call_sent = True
        result = client.request("tools/call", {"name": tool_name, "arguments": arguments})
        return {
            "result": normalize_result(result),
            "server_info": initialize.get("serverInfo") if isinstance(initialize.get("serverInfo"), dict) else {},
            "server_capabilities": initialize.get("capabilities") if isinstance(initialize.get("capabilities"), dict) else {},
            "protocol_version": client.negotiated_protocol,
        }
    except (legacy.McpError, OSError) as exc:
        if call_sent and not isinstance(exc, legacy.RpcError):
            raise McpAdapterError("mcp_outcome_unknown", clean_error(exc)) from exc
        raise
    finally:
        client.close()


def exception_tree(
    exc: BaseException, seen: set[int] | None = None
) -> list[BaseException]:
    visited = seen if seen is not None else set()
    if id(exc) in visited:
        return []
    visited.add(id(exc))
    values = [exc]
    if isinstance(exc, BASE_EXCEPTION_GROUP):
        for child in exc.exceptions:
            values.extend(exception_tree(child, visited))
    cause = exc.__cause__ or exc.__context__
    if cause is not None and cause is not exc:
        values.extend(exception_tree(cause, visited))
    return values


def modern_fallback_allowed(exc: BaseException) -> bool:
    if not isinstance(exc, ModernNegotiationFailure):
        return False
    exc = exc.cause
    values = exception_tree(exc)
    if any(isinstance(value, (ssl.SSLCertVerificationError, McpResourceLimitError)) for value in values):
        return False
    adapter_errors = [value for value in values if isinstance(value, McpAdapterError)]
    if adapter_errors:
        return all(value.fallback_allowed for value in adapter_errors)
    try:
        from mcp_types import METHOD_NOT_FOUND, PARSE_ERROR, REQUEST_TIMEOUT, UNSUPPORTED_PROTOCOL_VERSION
        from mcp.shared.exceptions import MCPError
        from pydantic import ValidationError
    except ImportError:
        return False
    rpc_errors = [value for value in values if isinstance(value, MCPError)]
    if rpc_errors:
        for value in rpc_errors:
            if value.code == UNSUPPORTED_PROTOCOL_VERSION:
                data = value.data
                supported = data.get("supported") if isinstance(data, dict) else None
                if not isinstance(supported, list) or not (
                    {item for item in supported if isinstance(item, str)}
                    & legacy.SUPPORTED_PROTOCOL_VERSIONS
                ):
                    return False
            elif value.code not in {METHOD_NOT_FOUND, PARSE_ERROR, REQUEST_TIMEOUT}:
                return False
        return True
    if any(isinstance(value, ValidationError) for value in values):
        return True
    return any(isinstance(value, (ConnectionError, TimeoutError, OSError)) for value in values)


def base_payload(manifest: dict[str, Any]) -> dict[str, Any]:
    return {
        "server_id": str(manifest.get("id") or ""),
        "server_name": str(manifest.get("name") or manifest.get("id") or ""),
        "transport": str(manifest.get("transport") or ""),
    }


def legacy_manifest_with_credential(
    manifest: dict[str, Any], profile: dict[str, Any] | None
) -> dict[str, Any]:
    if profile is None:
        return manifest
    if profile.get("type") != "static_headers":
        raise McpAdapterError(
            "mcp_credential_invalid",
            "OAuth credential profiles require the modern MCP protocol",
        )
    effective = dict(manifest)
    effective["headers"] = credential_headers(manifest, profile)
    return effective


def list_payload(
    manifest: dict[str, Any], result: dict[str, Any], fallback_used: bool, fallback_reason: str
) -> dict[str, Any]:
    tools = result["tools"]
    return {
        "ok": True,
        "status": "listed",
        **base_payload(manifest),
        "protocol_version": result["protocol_version"],
        "server_info": result["server_info"],
        "server_capabilities": result["server_capabilities"],
        "tools": tools,
        "tool_count": len(tools),
        "fallback_used": fallback_used,
        "fallback_reason": fallback_reason,
        "outcome_known": True,
    }


def call_payload(
    manifest: dict[str, Any], tool_name: str, result: dict[str, Any], fallback_used: bool, fallback_reason: str
) -> tuple[dict[str, Any], int]:
    raw = result["result"]
    if result.get("input_required"):
        return (
            {
                "ok": False,
                "status": "mcp_input_required",
                **base_payload(manifest),
                "tool": tool_name,
                "protocol_version": result["protocol_version"],
                "server_info": result["server_info"],
                "server_capabilities": result["server_capabilities"],
                "result": raw,
                **result["continuation"],
                "fallback_used": fallback_used,
                "fallback_reason": fallback_reason,
                "outcome_known": True,
            },
            3,
        )
    is_error = bool(raw.get("isError"))
    structured = raw.get("structuredContent") if "structuredContent" in raw else None
    output = {
        "tool": f"mcp.{manifest.get('id', '')}.{tool_name}",
        "server_id": str(manifest.get("id") or ""),
        "mcp_tool": tool_name,
        "content": raw.get("content", []),
        "structuredContent": structured,
        "isError": is_error,
        "resultType": raw.get("resultType", "complete"),
    }
    return (
        {
            "ok": not is_error,
            "status": "tool_error" if is_error else "executed",
            **base_payload(manifest),
            "tool": tool_name,
            "protocol_version": result["protocol_version"],
            "server_info": result["server_info"],
            "server_capabilities": result["server_capabilities"],
            "result": raw,
            "output": output,
            "fallback_used": fallback_used,
            "fallback_reason": fallback_reason,
            "outcome_known": True,
        },
        1 if is_error else 0,
    )


def error_payload(exc: BaseException, *, outcome_known: bool = True) -> dict[str, Any]:
    cause = exc
    while isinstance(cause, (ModernFailure, ModernNegotiationFailure)):
        cause = cause.cause
    try:
        from mcp.shared.exceptions import MCPError
    except ImportError:
        MCPError = None  # type: ignore[assignment,misc]
    if isinstance(cause, McpAdapterError):
        status = cause.status
    elif isinstance(cause, legacy.RpcError) or MCPError is not None and isinstance(cause, MCPError):
        status = "mcp_rpc_error"
    else:
        status = "mcp_client_error"
    payload: dict[str, Any] = {
        "ok": False,
        "status": status,
        "error": clean_error(cause),
        "outcome_known": outcome_known,
        "fallback_used": False,
        "fallback_reason": "",
    }
    if isinstance(cause, legacy.RpcError):
        payload["rpc_error"] = cause.error
    elif MCPError is not None and isinstance(cause, MCPError):
        payload["rpc_error"] = {
            "code": cause.code,
            "message": clean_error(cause.message),
        }
    return payload


def action_list_tools(manifest_path: str, *, refresh: bool = False) -> int:
    ACTIVE_CREDENTIAL_SECRETS.clear()
    manifest = load_manifest(manifest_path)
    mode, _ = protocol_mode(manifest)
    cached_selection = (
        None
        if refresh or mode != "modern_then_legacy"
        else read_protocol_selection(manifest)
    )
    if mode != "legacy_only" and cached_selection != "legacy":
        ensure_sdk_runtime()
    credential_profile, credential_update_fd = load_credential_context(manifest)
    try:
        if mode == "legacy_only":
            legacy_manifest = legacy_manifest_with_credential(
                manifest, credential_profile
            )
            return emit(
                list_payload(
                    manifest,
                    legacy_list(legacy_manifest, manifest_path),
                    False,
                    "",
                )
            )
        if cached_selection == "legacy":
            legacy_manifest = legacy_manifest_with_credential(
                manifest, credential_profile
            )
            fallback = legacy_list(legacy_manifest, manifest_path)
            return emit(
                list_payload(
                    manifest,
                    fallback,
                    True,
                    "cached legacy protocol selection",
                )
            )
        try:
            modern = asyncio.run(
                modern_list(
                    manifest,
                    manifest_path,
                    credential_profile,
                    credential_update_fd,
                    refresh=refresh,
                    skip_discover=cached_selection == "modern",
                )
            )
            write_protocol_selection(manifest, "modern")
            return emit(list_payload(manifest, modern, False, ""))
        except BaseException as exc:
            if mode != "modern_then_legacy" or not modern_fallback_allowed(exc):
                return emit(error_payload(exc), 1)
            reason = clean_error(exc)
            legacy_manifest = legacy_manifest_with_credential(
                manifest, credential_profile
            )
            fallback = legacy_list(legacy_manifest, manifest_path)
            write_protocol_selection(manifest, "legacy")
            return emit(list_payload(manifest, fallback, True, reason))
    finally:
        if credential_update_fd is not None:
            os.close(credential_update_fd)


def action_call_tool(
    manifest_path: str,
    tool_name: str,
    arguments_file: str,
    continuation_file: str | None = None,
    input_responses_file: str | None = None,
) -> int:
    ACTIVE_CREDENTIAL_SECRETS.clear()
    manifest = load_manifest(manifest_path)
    arguments = load_json_file(arguments_file, max_bytes=MAX_ARGUMENT_BYTES)
    if not isinstance(arguments, dict):
        raise McpAdapterError("invalid_arguments", "tool arguments must be a JSON object")
    if json_size(arguments) > MAX_ARGUMENT_BYTES:
        raise McpResourceLimitError("tool arguments exceed the request limit")
    mode, _ = protocol_mode(manifest)
    cached_selection = (
        read_protocol_selection(manifest)
        if mode == "modern_then_legacy"
        and continuation_file is None
        and input_responses_file is None
        else None
    )
    if mode != "legacy_only" and cached_selection != "legacy":
        ensure_sdk_runtime()
    credential_profile, credential_update_fd = load_credential_context(manifest)
    try:
        if mode == "legacy_only":
            if continuation_file or input_responses_file:
                raise McpAdapterError(
                    "mcp_input_unsupported",
                    "legacy MCP does not support input continuation",
                )
            legacy_result = legacy_call(
                legacy_manifest_with_credential(manifest, credential_profile),
                manifest_path,
                tool_name,
                arguments,
            )
            payload, status = call_payload(
                manifest, tool_name, legacy_result, False, ""
            )
            return emit(payload, status)
        if cached_selection == "legacy":
            fallback = legacy_call(
                legacy_manifest_with_credential(manifest, credential_profile),
                manifest_path,
                tool_name,
                arguments,
            )
            payload, status = call_payload(
                manifest,
                tool_name,
                fallback,
                True,
                "cached legacy protocol selection",
            )
            return emit(payload, status)
        try:
            modern = asyncio.run(
                modern_call(
                    manifest,
                    manifest_path,
                    tool_name,
                    arguments,
                    arguments_file,
                    continuation_file,
                    input_responses_file,
                    credential_profile,
                    credential_update_fd,
                    skip_discover=cached_selection == "modern",
                )
            )
            write_protocol_selection(manifest, "modern")
            payload, status = call_payload(manifest, tool_name, modern, False, "")
            return emit(payload, status)
        except ModernFailure as exc:
            outcome_known = not (exc.call_sent and not exc.result_received)
            if exc.call_sent:
                write_protocol_selection(manifest, "modern")
            if not outcome_known:
                payload = error_payload(exc, outcome_known=False)
                payload.update(
                    {
                        **base_payload(manifest),
                        "status": "mcp_outcome_unknown",
                        "tool": tool_name,
                        "protocol_version": MODERN_PROTOCOL_VERSION,
                    }
                )
                return emit(payload, 1)
            if (
                continuation_file
                or input_responses_file
                or mode != "modern_then_legacy"
                or not modern_fallback_allowed(exc.cause)
            ):
                payload = error_payload(exc)
                if exc.call_sent:
                    payload.update(
                        {
                            **base_payload(manifest),
                            "tool": tool_name,
                            "protocol_version": MODERN_PROTOCOL_VERSION,
                        }
                    )
                return emit(payload, 1)
            reason = clean_error(exc.cause)
            fallback = legacy_call(
                legacy_manifest_with_credential(manifest, credential_profile),
                manifest_path,
                tool_name,
                arguments,
            )
            write_protocol_selection(manifest, "legacy")
            payload, status = call_payload(
                manifest, tool_name, fallback, True, reason
            )
            return emit(payload, status)
    finally:
        if credential_update_fd is not None:
            os.close(credential_update_fd)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    list_parser = subparsers.add_parser("list-tools")
    list_parser.add_argument("manifest")
    list_parser.add_argument(
        "--refresh",
        action="store_true",
        help="fetch tools/list and replace the SDK cache entry",
    )
    call_parser = subparsers.add_parser("call-tool")
    call_parser.add_argument("manifest")
    call_parser.add_argument("tool")
    call_parser.add_argument("arguments_file")
    call_parser.add_argument("--continuation")
    call_parser.add_argument("--input-responses")
    args = parser.parse_args()
    try:
        if args.command == "list-tools":
            return action_list_tools(args.manifest, refresh=args.refresh)
        return action_call_tool(
            args.manifest,
            args.tool,
            args.arguments_file,
            args.continuation,
            args.input_responses,
        )
    except BaseException as exc:
        return emit(error_payload(exc), 1)


if __name__ == "__main__":
    raise SystemExit(main())
