#!/usr/bin/env python3
"""Dedicated non-root fixed-query database inspector Unix-socket helper."""

from __future__ import annotations

import argparse
import concurrent.futures
import fcntl
import json
import os
import re
import signal
import socket
import stat
import subprocess
import sys
import threading
import time
from pathlib import Path

from database_profiles import (
    DatabaseProfileError,
    list_profiles,
    load_profile,
    public_profile,
)
from helper_protocol import (
    PROTOCOL_VERSION,
    ProtocolError,
    allowed_peer_uid,
    build_request,
    client_request,
    receive_json_with_descriptors,
    require_peer_uid,
    send_json,
    systemd_listener,
    validate_request,
)


REFERENCE_PATTERN = re.compile(r"^[0-9a-f]{32}$")
QUERY_ID_PATTERN = re.compile(r"^[0-9a-f]{32}$")
CREDENTIAL_MEMFD_MAX_BYTES = 16_384
CLIENT_PATHS = {
    "postgresql": ("/usr/bin/psql", "/usr/local/bin/psql"),
    "mysql": ("/usr/bin/mysql", "/usr/bin/mariadb", "/usr/local/bin/mysql"),
}
FIXED_SQL = {
    ("postgresql", "health"): (
        "BEGIN READ ONLY; SELECT 1 AS health; "
        "SELECT current_database(), version(); COMMIT;\n"
    ),
    ("postgresql", "metrics"): (
        "BEGIN READ ONLY; SELECT datname,numbackends,xact_commit,xact_rollback,"
        "blks_read,blks_hit,tup_returned,tup_fetched,tup_inserted,tup_updated,tup_deleted "
        "FROM pg_stat_database WHERE datname=current_database(); COMMIT;\n"
    ),
    ("mysql", "health"): "SELECT 1 AS health; SELECT DATABASE(), VERSION();\n",
    ("mysql", "metrics"): (
        "SELECT VARIABLE_NAME,VARIABLE_VALUE FROM performance_schema.global_status "
        "WHERE VARIABLE_NAME IN ('Threads_connected','Threads_running','Questions',"
        "'Queries','Com_select','Com_insert','Com_update','Com_delete','Uptime') "
        "ORDER BY VARIABLE_NAME;\n"
    ),
}


class DatabaseInspectorError(ProtocolError):
    def __init__(self, message: str, code: str = "database_query_failed"):
        super().__init__(message)
        self.code = code


class DatabaseQueryRegistry:
    """Bind cancellable database clients to helper request IDs."""

    def __init__(self, maximum_cancelled: int = 128):
        self.lock = threading.Lock()
        self.processes: dict[str, tuple[object, threading.Event]] = {}
        self.cancelled: dict[str, None] = {}
        self.maximum_cancelled = maximum_cancelled

    @staticmethod
    def _query_id(query_id: str) -> str:
        if not isinstance(query_id, str) or QUERY_ID_PATTERN.fullmatch(query_id) is None:
            raise DatabaseInspectorError("database query id is invalid")
        return query_id

    def register(self, query_id: str, process) -> threading.Event:
        cancellation = threading.Event()
        if not query_id:
            return cancellation
        normalized = self._query_id(query_id)
        with self.lock:
            if normalized in self.processes:
                raise DatabaseInspectorError("database query id is already active")
            if normalized in self.cancelled:
                self.cancelled.pop(normalized, None)
                cancellation.set()
            self.processes[normalized] = (process, cancellation)
        return cancellation

    def consume_pending_cancellation(self, query_id: str) -> bool:
        if not query_id:
            return False
        normalized = self._query_id(query_id)
        with self.lock:
            if normalized not in self.cancelled:
                return False
            self.cancelled.pop(normalized, None)
            return True

    def unregister(self, query_id: str, process) -> None:
        if not query_id:
            return
        with self.lock:
            current = self.processes.get(query_id)
            if current is not None and current[0] is process:
                self.processes.pop(query_id, None)

    def cancel(self, query_id: str) -> bool:
        normalized = self._query_id(query_id)
        with self.lock:
            current = self.processes.get(normalized)
            if current is None:
                self.cancelled[normalized] = None
                while len(self.cancelled) > self.maximum_cancelled:
                    self.cancelled.pop(next(iter(self.cancelled)))
                return False
            process, cancellation = current
            cancellation.set()
        _signal_query_process(process, signal.SIGTERM)
        return True


QUERY_REGISTRY = DatabaseQueryRegistry()


def _client(engine: str) -> str:
    for candidate in CLIENT_PATHS[engine]:
        path = Path(candidate)
        try:
            resolved = path.resolve(strict=True)
            metadata = resolved.stat()
        except OSError:
            continue
        trusted = stat.S_ISREG(metadata.st_mode) and os.access(resolved, os.X_OK)
        for component in (resolved, *resolved.parents):
            component_metadata = component.stat()
            if component_metadata.st_uid != 0 or component_metadata.st_mode & (
                stat.S_IWGRP | stat.S_IWOTH
            ):
                trusted = False
                break
        if trusted:
            return str(resolved)
    raise DatabaseInspectorError(f"{engine} client is unavailable", "credential_unavailable")


def _reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise DatabaseInspectorError("credential memfd contains duplicate JSON keys")
        result[key] = value
    return result


def _strict_params(raw: str) -> dict[str, object]:
    try:
        value = json.loads(
            raw,
            parse_constant=lambda constant: (_ for _ in ()).throw(
                DatabaseInspectorError(f"params contain invalid constant: {constant}")
            ),
            object_pairs_hook=_reject_duplicate_keys,
        )
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise DatabaseInspectorError("params are not valid JSON") from exc
    if not isinstance(value, dict):
        raise DatabaseInspectorError("params must be a JSON object")
    return value


def _credential_from_memfd(descriptor: int) -> tuple[str, str]:
    required = ("F_GET_SEALS", "F_SEAL_SEAL", "F_SEAL_SHRINK", "F_SEAL_GROW", "F_SEAL_WRITE")
    if not all(hasattr(fcntl, name) for name in required):
        raise DatabaseInspectorError("sealed anonymous credentials are unsupported", "credential_unavailable")
    metadata = os.fstat(descriptor)
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_nlink != 0
        or not 0 < metadata.st_size <= CREDENTIAL_MEMFD_MAX_BYTES
    ):
        raise DatabaseInspectorError("credential descriptor is not a bounded anonymous file")
    required_seals = (
        fcntl.F_SEAL_SEAL
        | fcntl.F_SEAL_SHRINK
        | fcntl.F_SEAL_GROW
        | fcntl.F_SEAL_WRITE
    )
    if fcntl.fcntl(descriptor, fcntl.F_GET_SEALS) & required_seals != required_seals:
        raise DatabaseInspectorError("credential descriptor is not sealed")
    payload = os.pread(descriptor, CREDENTIAL_MEMFD_MAX_BYTES + 1, 0)
    if len(payload) != metadata.st_size:
        raise DatabaseInspectorError("credential descriptor size changed")
    try:
        value = json.loads(
            payload.decode("utf-8"),
            parse_constant=lambda constant: (_ for _ in ()).throw(
                DatabaseInspectorError(f"credential contains invalid constant: {constant}")
            ),
            object_pairs_hook=_reject_duplicate_keys,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise DatabaseInspectorError("credential descriptor is not valid UTF-8 JSON") from exc
    if not isinstance(value, dict) or set(value) != {"username", "password"}:
        raise DatabaseInspectorError("credential descriptor fields do not match the fixed schema")
    for name, maximum in (("username", 256), ("password", 4096)):
        item = value.get(name)
        if not isinstance(item, str) or not item or len(item.encode("utf-8")) > maximum:
            raise DatabaseInspectorError(f"{name} is invalid", "credential_unavailable")
        if any(character in item for character in ("\x00", "\n", "\r")):
            raise DatabaseInspectorError(
                f"{name} contains unsupported characters",
                "credential_unavailable",
            )
    return value["username"], value["password"]


def _credentials(
    profile: dict[str, object],
    reference: str,
    credential_descriptor: int | None,
) -> tuple[str, str]:
    if reference:
        if profile["credential_mode"] == "stored":
            raise DatabaseInspectorError("profile does not permit temporary credentials", "credential_unavailable")
        if credential_descriptor is None:
            raise DatabaseInspectorError("temporary credential descriptor is unavailable", "credential_unavailable")
        return _credential_from_memfd(credential_descriptor)
    if credential_descriptor is not None:
        raise DatabaseInspectorError("stored credentials do not accept a credential descriptor")
    stored = profile.get("credentials")
    if not isinstance(stored, dict):
        raise DatabaseInspectorError("stored credentials are unavailable", "credential_unavailable")
    return str(stored["username"]), str(stored["password"])


def _base_environment() -> dict[str, str]:
    return {
        "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "HOME": "/nonexistent",
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
    }


def _signal_query_process(process, signum: int) -> None:
    try:
        os.killpg(process.pid, signum)
        return
    except (AttributeError, OSError, ProcessLookupError):
        pass
    try:
        if signum == signal.SIGTERM:
            process.terminate()
        else:
            process.kill()
    except (AttributeError, OSError, ProcessLookupError):
        pass


def _terminate_query_process(process) -> tuple[bytes, bytes]:
    _signal_query_process(process, signal.SIGTERM)
    try:
        return process.communicate(timeout=0.5)
    except subprocess.TimeoutExpired:
        _signal_query_process(process, signal.SIGKILL)
        return process.communicate()


def _run_client(
    argv: list[str],
    payload: bytes,
    environment: dict[str, str],
    *,
    pass_fds: tuple[int, ...] = (),
    query_id: str = "",
    registry: DatabaseQueryRegistry | None = None,
    cancelled=None,
) -> tuple[int, bytes, bytes]:
    query_registry = registry or QUERY_REGISTRY
    if query_id and query_registry.consume_pending_cancellation(query_id):
        raise DatabaseInspectorError(
            "database query was cancelled", "database_query_cancelled"
        )
    process = subprocess.Popen(
        argv,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=environment,
        pass_fds=pass_fds,
        start_new_session=True,
    )
    try:
        cancellation = query_registry.register(query_id, process)
    except Exception:
        try:
            _terminate_query_process(process)
        except Exception:
            pass
        raise
    deadline = time.monotonic() + 20
    input_payload: bytes | None = payload
    try:
        while True:
            if cancelled is not None and cancelled():
                cancellation.set()
            if cancellation.is_set():
                _terminate_query_process(process)
                raise DatabaseInspectorError(
                    "database query was cancelled", "database_query_cancelled"
                )
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                _terminate_query_process(process)
                raise subprocess.TimeoutExpired(argv, 20)
            try:
                stdout, stderr = process.communicate(
                    input=input_payload,
                    timeout=min(0.05, remaining),
                )
            except subprocess.TimeoutExpired:
                input_payload = None
                continue
            if cancellation.is_set() or (cancelled is not None and cancelled()):
                raise DatabaseInspectorError(
                    "database query was cancelled", "database_query_cancelled"
                )
            return process.returncode, stdout, stderr
    finally:
        if process.poll() is None:
            _terminate_query_process(process)
        query_registry.unregister(query_id, process)


def _run_postgresql(
    profile: dict[str, object],
    username: str,
    password: str,
    operation: str,
    *,
    query_id: str = "",
    registry: DatabaseQueryRegistry | None = None,
    cancelled=None,
) -> tuple[int, bytes, bytes]:
    argv = [
        _client("postgresql"),
        "-X",
        "-A",
        "-t",
        "-F",
        "\t",
        "--set",
        "ON_ERROR_STOP=1",
        "--username",
        username,
        "--dbname",
        str(profile["database"]),
    ]
    if profile.get("socket"):
        argv.extend(("--host", str(profile["socket"])))
    else:
        argv.extend(("--host", str(profile["endpoint"]), "--port", str(profile["port"])))
    environment = _base_environment()
    environment["PGPASSWORD"] = password
    environment["PGSSLMODE"] = str(profile["tls"])
    return _run_client(
        argv,
        FIXED_SQL[("postgresql", operation)].encode("utf-8"),
        environment,
        query_id=query_id,
        registry=registry,
        cancelled=cancelled,
    )


def _mysql_config(username: str, password: str) -> tuple[int, str]:
    if not hasattr(os, "memfd_create"):
        raise DatabaseInspectorError("anonymous credential files are unsupported", "credential_unavailable")
    descriptor = os.memfd_create("linux-agent-mysql", getattr(os, "MFD_CLOEXEC", 0))
    def option_value(value: str) -> str:
        return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'

    payload = (
        f"[client]\nuser={option_value(username)}\n"
        f"password={option_value(password)}\n"
    ).encode("utf-8")
    os.write(descriptor, payload)
    os.lseek(descriptor, 0, os.SEEK_SET)
    return descriptor, f"/proc/self/fd/{descriptor}"


def _run_mysql(
    profile: dict[str, object],
    username: str,
    password: str,
    operation: str,
    *,
    query_id: str = "",
    registry: DatabaseQueryRegistry | None = None,
    cancelled=None,
) -> tuple[int, bytes, bytes]:
    descriptor, config_path = _mysql_config(username, password)
    try:
        argv = [
            _client("mysql"),
            f"--defaults-extra-file={config_path}",
            "--batch",
            "--raw",
            "--skip-column-names",
        ]
        if profile.get("socket"):
            argv.extend(("--protocol=SOCKET", f"--socket={profile['socket']}"))
        else:
            argv.extend(("--protocol=TCP", f"--host={profile['endpoint']}", f"--port={profile['port']}"))
            tls = str(profile["tls"])
            ssl_mode = {"disable": "DISABLED", "require": "REQUIRED", "verify-full": "VERIFY_IDENTITY"}[tls]
            argv.append(f"--ssl-mode={ssl_mode}")
        argv.extend(("--", str(profile["database"])))
        return _run_client(
            argv,
            FIXED_SQL[("mysql", operation)].encode("utf-8"),
            _base_environment(),
            pass_fds=(descriptor,),
            query_id=query_id,
            registry=registry,
            cancelled=cancelled,
        )
    finally:
        os.close(descriptor)


def run_fixed_query(
    profile: dict[str, object],
    username: str,
    password: str,
    operation: str,
    *,
    query_id: str = "",
    registry: DatabaseQueryRegistry | None = None,
    cancelled=None,
) -> dict[str, object]:
    if operation not in {"health", "metrics"}:
        raise DatabaseInspectorError("database operation is unsupported")
    try:
        if profile["engine"] == "postgresql":
            returncode, stdout, stderr = _run_postgresql(
                profile,
                username,
                password,
                operation,
                query_id=query_id,
                registry=registry,
                cancelled=cancelled,
            )
        else:
            returncode, stdout, stderr = _run_mysql(
                profile,
                username,
                password,
                operation,
                query_id=query_id,
                registry=registry,
                cancelled=cancelled,
            )
    except subprocess.TimeoutExpired as exc:
        raise DatabaseInspectorError("database query timed out", "database_unreachable") from exc
    except OSError as exc:
        raise DatabaseInspectorError("database client could not be executed", "database_unreachable") from exc
    def redact(value: str) -> str:
        for secret in (password, username):
            if secret:
                value = value.replace(secret, "[REDACTED]")
        return value

    stderr_text = redact(stderr[:65_536].decode("utf-8", errors="replace")).strip()
    if returncode != 0:
        lower = stderr_text.lower()
        unreachable = any(
            marker in lower
            for marker in ("could not connect", "connection refused", "connection timed out", "can't connect")
        )
        raise DatabaseInspectorError(
            stderr_text or "database query failed",
            "database_unreachable" if unreachable else "database_query_failed",
        )
    stdout_text = redact(stdout[:1_048_576].decode("utf-8", errors="replace"))
    rows = [line.split("\t")[:32] for line in stdout_text.splitlines()]
    return {
        "ok": True,
        "status": "checked",
        "operation": f"database.{operation}",
        "profile": public_profile(profile),
        "rows": rows[:512],
        "truncated": len(rows) > 512,
        "fixed_query": True,
    }


def inspect_database(
    params: dict[str, object],
    operation: str,
    credential_descriptor: int | None = None,
    *,
    query_id: str = "",
    registry: DatabaseQueryRegistry | None = None,
) -> dict[str, object]:
    if set(params) != {"profile_id", "credential_ref"}:
        raise DatabaseInspectorError("database inspect params do not match the fixed schema")
    profile_id = params.get("profile_id")
    credential_ref = params.get("credential_ref")
    if not isinstance(profile_id, str) or not isinstance(credential_ref, str):
        raise DatabaseInspectorError("profile_id and credential_ref must be strings")
    if credential_ref and REFERENCE_PATTERN.fullmatch(credential_ref) is None:
        raise DatabaseInspectorError("credential reference is invalid", "credential_unavailable")
    try:
        profile = load_profile(profile_id)
    except DatabaseProfileError as exc:
        raise DatabaseInspectorError(str(exc), "credential_unavailable") from exc
    username, password = _credentials(profile, credential_ref, credential_descriptor)
    return run_fixed_query(
        profile,
        username,
        password,
        operation,
        query_id=query_id,
        registry=registry,
    )


def handle_connection(
    connection: socket.socket,
    expected_uid: int,
    registry: DatabaseQueryRegistry | None = None,
    query_capacity: threading.BoundedSemaphore | None = None,
) -> None:
    request_id = ""
    descriptors = ()
    query_registry = registry or QUERY_REGISTRY
    try:
        require_peer_uid(connection, expected_uid)
        request, descriptors = receive_json_with_descriptors(connection)
        operation, params, _summary, request_id = validate_request(request)
        if operation == "ping":
            if params or descriptors:
                raise DatabaseInspectorError("ping does not accept params")
            response = {"ok": True, "status": "ready", "helper": "database-inspector"}
        elif operation == "profiles.list":
            if params or descriptors:
                raise DatabaseInspectorError("profiles.list does not accept params")
            response = {"ok": True, "status": "listed", "profiles": list_profiles()}
        elif operation in {"database.health", "database.metrics"}:
            acquired = query_capacity is None or query_capacity.acquire(blocking=False)
            if not acquired:
                raise DatabaseInspectorError(
                    "database inspector query capacity is full",
                    "helper_unavailable",
                )
            try:
                response = inspect_database(
                    params,
                    operation.rsplit(".", 1)[-1],
                    descriptors[0] if descriptors else None,
                    query_id=request_id,
                    registry=query_registry,
                )
            finally:
                if query_capacity is not None:
                    query_capacity.release()
        elif operation == "database.cancel":
            if descriptors or set(params) != {"request_id"}:
                raise DatabaseInspectorError(
                    "database.cancel params do not match the fixed schema"
                )
            target_request_id = params.get("request_id")
            if not isinstance(target_request_id, str):
                raise DatabaseInspectorError("database.cancel request_id must be a string")
            running = query_registry.cancel(target_request_id)
            response = {
                "ok": True,
                "status": "cancel_requested",
                "operation": "database.cancel",
                "target_request_id": target_request_id,
                "running": running,
            }
        else:
            raise ProtocolError("unsupported database inspector operation")
        response.update({"protocol_version": PROTOCOL_VERSION, "request_id": request_id})
    except DatabaseInspectorError as exc:
        response = {
            "ok": False,
            "status": "failed",
            "code": exc.code,
            "error": str(exc),
            "protocol_version": PROTOCOL_VERSION,
            "request_id": request_id,
        }
    except (ProtocolError, DatabaseProfileError) as exc:
        response = {
            "ok": False,
            "status": "failed",
            "code": "helper_rejected",
            "error": str(exc),
            "protocol_version": PROTOCOL_VERSION,
            "request_id": request_id,
        }
    except Exception as exc:
        response = {
            "ok": False,
            "status": "failed",
            "code": "helper_failed",
            "error": str(exc),
            "protocol_version": PROTOCOL_VERSION,
            "request_id": request_id,
        }
    finally:
        for descriptor in descriptors:
            try:
                os.close(descriptor)
            except OSError:
                pass
    send_json(connection, response)


def serve() -> int:
    expected_uid = allowed_peer_uid("linux-agent")
    listener = systemd_listener()
    registry = DatabaseQueryRegistry()
    connection_capacity = threading.BoundedSemaphore(9)
    query_capacity = threading.BoundedSemaphore(8)

    def serve_connection(connection: socket.socket) -> None:
        try:
            with connection:
                connection.settimeout(30)
                handle_connection(
                    connection,
                    expected_uid,
                    registry,
                    query_capacity,
                )
        finally:
            connection_capacity.release()

    with concurrent.futures.ThreadPoolExecutor(
        max_workers=9,
        thread_name_prefix="database-inspector",
    ) as executor:
        while True:
            connection_capacity.acquire()
            try:
                connection, _address = listener.accept()
            except Exception:
                connection_capacity.release()
                raise
            try:
                executor.submit(serve_connection, connection)
            except Exception:
                connection.close()
                connection_capacity.release()
                raise


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("serve")
    request_parser = subparsers.add_parser("request")
    request_parser.add_argument("--socket", required=True)
    request_parser.add_argument(
        "operation",
        choices=(
            "ping",
            "profiles.list",
            "database.health",
            "database.metrics",
            "database.cancel",
        ),
    )
    request_parser.add_argument("--params", required=True)
    request_parser.add_argument("--summary", required=True)
    args = parser.parse_args()
    if args.command == "serve":
        if os.geteuid() == 0:
            raise SystemExit("database inspector must not run as root")
        return serve()
    try:
        params = _strict_params(args.params)
        response = client_request(
            args.socket,
            build_request(args.operation, params, summary=args.summary),
        )
    except (OSError, ProtocolError, DatabaseInspectorError) as exc:
        print(str(exc), file=sys.stderr)
        return 125
    print(json.dumps(response, ensure_ascii=False, separators=(",", ":")))
    return 0 if response.get("ok") else 1


if __name__ == "__main__":
    raise SystemExit(main())
