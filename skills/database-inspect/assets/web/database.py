"""Package-owned Web database credentials and fixed-query adapters."""

import fcntl
import os
import secrets
import sys
import threading
import time
from pathlib import Path

SKILL_SCRIPTS = Path(__file__).resolve().parents[2] / "scripts"
sys.path.insert(0, os.fspath(SKILL_SCRIPTS))

from database_inspector import (
    DatabaseInspectorError,
    DatabaseQueryRegistry,
    run_fixed_query,
)
from database_profiles import DatabaseProfileError, validate_profile
from helper_protocol import ProtocolError, build_request, canonical_json, client_request


CREDENTIAL_MEMFD_MAX_BYTES = 16_384


class SecretStoreError(ValueError):
    def __init__(self, message, code="credential_unavailable"):
        super().__init__(message)
        self.code = code


def _credential_memfd(username, password):
    required = ("F_ADD_SEALS", "F_GET_SEALS", "F_SEAL_SEAL", "F_SEAL_SHRINK", "F_SEAL_GROW", "F_SEAL_WRITE")
    if not hasattr(os, "memfd_create") or not hasattr(os, "MFD_ALLOW_SEALING") or not all(
        hasattr(fcntl, name) for name in required
    ):
        raise SecretStoreError("sealed anonymous credentials are unsupported")
    payload = canonical_json({"password": password, "username": username})
    if len(payload) > CREDENTIAL_MEMFD_MAX_BYTES:
        raise SecretStoreError("database credential exceeds the transfer limit")
    descriptor = os.memfd_create(
        "linux-agent-database-credential",
        getattr(os, "MFD_CLOEXEC", 0) | os.MFD_ALLOW_SEALING,
    )
    try:
        offset = 0
        while offset < len(payload):
            written = os.write(descriptor, payload[offset:])
            if written <= 0:
                raise OSError("credential memfd write returned no progress")
            offset += written
        seals = (
            fcntl.F_SEAL_SEAL
            | fcntl.F_SEAL_SHRINK
            | fcntl.F_SEAL_GROW
            | fcntl.F_SEAL_WRITE
        )
        fcntl.fcntl(descriptor, fcntl.F_ADD_SEALS, seals)
        if fcntl.fcntl(descriptor, fcntl.F_GET_SEALS) & seals != seals:
            raise OSError("credential memfd seals were not applied")
        return descriptor
    except Exception:
        os.close(descriptor)
        raise


def _username_hint(username):
    value = str(username or "")
    if len(value) <= 2:
        return "*" * len(value)
    return f"{value[0]}{'*' * min(len(value) - 2, 8)}{value[-1]}"


def _public_metadata(metadata):
    return {
        key: value
        for key, value in metadata.items()
        if key not in {"profile", "username"}
    }


class WorkspaceSecretStore:
    """A bounded process-only, workspace-wide credential store."""

    def __init__(self, maximum=8, idle_ttl=1800, absolute_ttl=28800, clock=None):
        self.maximum = int(maximum)
        self.idle_ttl = int(idle_ttl)
        self.absolute_ttl = int(absolute_ttl)
        self.clock = clock or time.monotonic
        self.lock = threading.Lock()
        self.values = {}

    def _purge_locked(self, now):
        expired = [
            reference
            for reference, item in self.values.items()
            if now - item["last_used"] > self.idle_ttl
            or now - item["created"] > self.absolute_ttl
        ]
        for reference in expired:
            self.values.pop(reference, None)

    def put(self, username, password, metadata):
        if not isinstance(username, str) or not username or len(username.encode("utf-8")) > 256:
            raise SecretStoreError("database username is invalid")
        if not isinstance(password, str) or not password or len(password.encode("utf-8")) > 4096:
            raise SecretStoreError("database password is invalid")
        if any(character in username + password for character in ("\x00", "\n", "\r")):
            raise SecretStoreError("database credential contains unsupported characters")
        if not isinstance(metadata, dict):
            raise SecretStoreError("database credential metadata is invalid")
        now = self.clock()
        with self.lock:
            self._purge_locked(now)
            if len(self.values) >= self.maximum:
                raise SecretStoreError("database credential capacity is full")
            reference = secrets.token_hex(16)
            self.values[reference] = {
                "created": now,
                "last_used": now,
                "username": username,
                "password": password,
                "metadata": dict(metadata),
            }
        return reference

    def metadata(self, reference):
        now = self.clock()
        with self.lock:
            self._purge_locked(now)
            item = self.values.get(reference)
            if item is None:
                raise SecretStoreError("database credential is unavailable")
            return dict(item["metadata"])

    def consume(self, reference):
        now = self.clock()
        with self.lock:
            item = self.values.pop(reference, None)
        if item is None:
            raise SecretStoreError("database credential is unavailable")
        if now - item["last_used"] > self.idle_ttl or now - item["created"] > self.absolute_ttl:
            raise SecretStoreError("database credential expired", "credential_expired")
        return item["username"], item["password"], dict(item["metadata"])

    def list_metadata(self):
        now = self.clock()
        with self.lock:
            self._purge_locked(now)
            return [
                {
                    "credential_ref": reference,
                    **_public_metadata(item["metadata"]),
                }
                for reference, item in self.values.items()
            ]

    def clear(self):
        with self.lock:
            count = len(self.values)
            self.values.clear()
        return count


class DatabaseService:
    def __init__(self, secret_store, *, remote_mode, managed_execution, helper_socket):
        self.secret_store = secret_store
        self.remote_mode = bool(remote_mode)
        self.managed_execution = bool(managed_execution)
        self.helper_socket = str(helper_socket)
        self.query_registry = DatabaseQueryRegistry()

    def _helper(self, operation, params, summary, credential=None, request_id=None):
        if not self.managed_execution or self.remote_mode:
            raise SecretStoreError("database inspector helper is unavailable")
        if not Path(self.helper_socket).is_socket():
            raise SecretStoreError("database inspector helper is unavailable")
        descriptor = None
        try:
            if credential is not None:
                descriptor = _credential_memfd(*credential)
            response = client_request(
                self.helper_socket,
                build_request(
                    operation,
                    params,
                    summary=summary,
                    request_id=request_id,
                ),
                descriptor=descriptor,
            )
        except (OSError, ProtocolError) as exc:
            raise SecretStoreError("database inspector helper is unavailable") from exc
        finally:
            if descriptor is not None:
                os.close(descriptor)
        if not isinstance(response, dict):
            raise SecretStoreError("database inspector returned an invalid response")
        return response

    def profiles(self):
        if self.remote_mode:
            return {"ok": True, "status": "listed", "profiles": [], "mode": "remote"}
        response = self._helper("profiles.list", {}, "List registered database profiles")
        if response.get("ok") is not True:
            raise SecretStoreError(
                str(response.get("error") or "database profiles are unavailable"),
                str(response.get("code") or "credential_unavailable"),
            )
        return {"ok": True, "status": "listed", "profiles": response.get("profiles", []), "mode": "managed"}

    def create_credential(self, body):
        if not isinstance(body, dict):
            raise SecretStoreError("database credential request must be an object")
        if self.remote_mode:
            return self._create_remote_credential(body)
        if set(body) != {"profile_id", "username", "password"}:
            raise SecretStoreError("managed credentials require profile_id, username, and password")
        profile_id = body.get("profile_id")
        profiles = self.profiles()["profiles"]
        profile = next(
            (item for item in profiles if isinstance(item, dict) and item.get("id") == profile_id),
            None,
        )
        if profile is None:
            raise SecretStoreError("managed credential profile is not registered")
        if profile.get("credential_mode") == "stored":
            raise SecretStoreError("profile does not permit temporary credentials")
        metadata = {
            "mode": "managed",
            "profile_id": profile_id,
            "engine": profile.get("engine"),
            "endpoint": profile.get("endpoint"),
            "socket": profile.get("socket"),
            "database": profile.get("database"),
            "tls": profile.get("tls"),
            "username_hint": _username_hint(body.get("username")),
        }
        reference = self.secret_store.put(body.get("username"), body.get("password"), metadata)
        return {
            "ok": True,
            "status": "saved",
            "credential_ref": reference,
            "metadata": _public_metadata(metadata),
        }

    def _create_remote_credential(self, body):
        allowed = {
            "engine",
            "endpoint",
            "port",
            "socket",
            "database",
            "tls",
            "username",
            "password",
            "acknowledge_authorized_scope",
        }
        if set(body) - allowed:
            raise SecretStoreError("remote database credential fields are unsupported")
        if body.get("acknowledge_authorized_scope") is not True:
            raise SecretStoreError("remote database endpoint requires authorized-scope acknowledgement")
        profile_input = {
            "schema_version": 1,
            "id": "remote_profile",
            "engine": "mysql" if body.get("engine") == "mariadb" else body.get("engine"),
            "database": body.get("database"),
            "tls": body.get("tls"),
            "credential_mode": "temporary",
        }
        for name in ("endpoint", "port", "socket"):
            if name in body:
                profile_input[name] = body[name]
        try:
            profile = validate_profile(profile_input)
        except DatabaseProfileError as exc:
            raise SecretStoreError(str(exc)) from exc
        metadata = {
            "mode": "remote",
            "profile": profile,
            "engine": profile["engine"],
            "endpoint": profile.get("endpoint"),
            "socket": profile.get("socket"),
            "database": profile["database"],
            "tls": profile["tls"],
            "username_hint": _username_hint(body.get("username")),
            "authorized_scope_acknowledged": True,
        }
        reference = self.secret_store.put(body.get("username"), body.get("password"), metadata)
        return {
            "ok": True,
            "status": "saved",
            "credential_ref": reference,
            "metadata": _public_metadata(metadata),
        }

    def credentials(self):
        return {
            "ok": True,
            "status": "listed",
            "credentials": self.secret_store.list_metadata(),
        }

    def clear_credentials(self):
        return {
            "ok": True,
            "status": "cleared",
            "cleared": self.secret_store.clear(),
        }

    def sanitize_job_payload(self, action, payload):
        if action not in {"health", "metrics"} or not isinstance(payload, dict):
            raise SecretStoreError("database job action is unsupported")
        if set(payload) - {"profile_id", "credential_ref"}:
            raise SecretStoreError("database job payload fields are unsupported")
        reference = payload.get("credential_ref", "")
        profile_id = payload.get("profile_id", "")
        if reference:
            if not isinstance(reference, str):
                raise SecretStoreError("credential_ref is invalid")
            metadata = self.secret_store.metadata(reference)
            if metadata.get("mode") == "managed" and profile_id != metadata.get("profile_id"):
                raise SecretStoreError("credential_ref does not match profile_id")
            if metadata.get("mode") == "remote" and profile_id:
                raise SecretStoreError("remote jobs cannot set profile_id")
        else:
            if self.remote_mode or not isinstance(profile_id, str) or not profile_id:
                raise SecretStoreError("database job requires a credential_ref")
            metadata = {"mode": "managed", "profile_id": profile_id, "stored_credentials": True}
        return {
            "profile_id": profile_id,
            "credential_ref": reference,
            "credential_metadata": _public_metadata(metadata),
        }

    def inspect(self, action, payload, *, query_id="", cancelled=None):
        try:
            result = self._inspect(
                action,
                payload,
                query_id=query_id,
                cancelled=cancelled,
            )
        except (SecretStoreError, DatabaseInspectorError) as exc:
            code = getattr(exc, "code", "database_query_failed")
            return {
                "ok": False,
                "status": "failed",
                "code": code,
                "error": str(exc),
                "timeline": [],
                "approval_card": None,
                "output_blocks": [],
            }
        return {
            "ok": True,
            "status": "checked",
            "database": result,
            "timeline": [],
            "approval_card": None,
            "output_blocks": [
                {"kind": "json", "title": f"Database {action}", "data": result}
            ],
        }

    def _inspect(self, action, payload, *, query_id="", cancelled=None):
        reference = str(payload.get("credential_ref") or "")
        profile_id = str(payload.get("profile_id") or "")
        metadata = payload.get("credential_metadata")
        if not isinstance(metadata, dict):
            raise SecretStoreError("database job metadata is invalid")
        if reference:
            username, password, stored_metadata = self.secret_store.consume(reference)
            if stored_metadata.get("mode") != metadata.get("mode"):
                raise SecretStoreError("database credential metadata changed")
            metadata = stored_metadata
        else:
            username = password = ""
        if metadata.get("mode") == "remote":
            profile = metadata.get("profile")
            if not isinstance(profile, dict):
                raise SecretStoreError("remote database profile is unavailable")
            return run_fixed_query(
                profile,
                username,
                password,
                action,
                query_id=query_id,
                registry=self.query_registry,
                cancelled=cancelled,
            )
        response = self._helper(
            f"database.{action}",
            {"profile_id": profile_id, "credential_ref": reference},
            f"Run fixed database.{action} query for profile {profile_id}",
            credential=(username, password) if reference else None,
            request_id=query_id or None,
        )
        if response.get("ok") is not True:
            raise SecretStoreError(
                str(response.get("error") or "database query failed"),
                str(response.get("code") or "database_query_failed"),
            )
        return response

    def cancel_query(self, query_id):
        if self.remote_mode:
            running = self.query_registry.cancel(query_id)
            return {
                "ok": True,
                "status": "cancel_requested",
                "operation": "database.cancel",
                "target_request_id": query_id,
                "running": running,
            }
        response = self._helper(
            "database.cancel",
            {"request_id": query_id},
            f"Cancel database query {query_id}",
        )
        if response.get("ok") is not True:
            raise SecretStoreError(
                str(response.get("error") or "database query cancellation failed"),
                str(response.get("code") or "database_query_failed"),
            )
        return response

    def web_action(self, action, body):
        if action == "profiles.list":
            if body:
                raise SecretStoreError("database profile listing does not accept fields")
            return self.profiles()
        if action == "credentials.list":
            if body:
                raise SecretStoreError("database credential listing does not accept fields")
            return self.credentials()
        if action == "credentials.create":
            return self.create_credential(body)
        if action == "credentials.clear":
            if body:
                raise SecretStoreError("database credential clear does not accept fields")
            return self.clear_credentials()
        raise SecretStoreError("database Web action is unsupported")

    def run_job(self, action, payload, *, query_id=""):
        return self.inspect(action, payload, query_id=query_id)

    def cancel_job(self, query_id):
        return self.cancel_query(query_id)

    def clear_secrets(self):
        return self.secret_store.clear()


def create_component(context):
    if not isinstance(context, dict):
        raise SecretStoreError("database Web component context is invalid")
    return DatabaseService(
        WorkspaceSecretStore(),
        remote_mode=context.get("remote_mode") is True,
        managed_execution=context.get("managed_execution") is True,
        helper_socket=str(context.get("helper_socket") or ""),
    )
