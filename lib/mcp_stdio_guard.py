#!/usr/bin/env python3
"""Bounded relay between the MCP SDK and an isolated stdio server."""

from __future__ import annotations

import concurrent.futures
import json
import os
import selectors
import signal
import socket
import subprocess
import sys
import threading
from pathlib import Path
from typing import BinaryIO

from helper_protocol import allowed_peer_uid, require_peer_uid, systemd_listener
from subprocess_env import apply_manifest_env, build_subprocess_env


MAX_MESSAGE_BYTES = 1_048_576
MAX_STDERR_BYTES = 16_384
MAX_CONNECTIONS = 32


class GuardError(RuntimeError):
    pass


def load_command(manifest_path: Path) -> tuple[list[str], str, dict[str, str]]:
    with manifest_path.open("r", encoding="utf-8") as handle:
        manifest = json.load(handle)
    if not isinstance(manifest, dict):
        raise GuardError("MCP manifest must be an object")
    command = manifest.get("command")
    arguments = manifest.get("args", [])
    if not isinstance(command, str) or not command:
        raise GuardError("stdio manifest command is required")
    if not isinstance(arguments, list) or not all(isinstance(item, str) for item in arguments):
        raise GuardError("stdio manifest args must be strings")
    cwd_value = manifest.get("cwd")
    if isinstance(cwd_value, str) and cwd_value:
        cwd_path = Path(cwd_value)
        cwd = os.fspath(cwd_path if cwd_path.is_absolute() else (manifest_path.parent / cwd_path).resolve())
    else:
        cwd = os.fspath(manifest_path.parent.resolve())
    environment = build_subprocess_env(include_api_key=False)
    apply_manifest_env(environment, manifest.get("env"))
    return [command, *arguments], cwd, environment


def trusted_manifest_path(raw_path: object) -> Path:
    if not isinstance(raw_path, str) or not raw_path or "\x00" in raw_path:
        raise GuardError("MCP manifest path is invalid")
    configured_root = os.environ.get("LINUX_AGENT_MCP_DIR")
    if not configured_root:
        raise GuardError("MCP manifest root is unavailable")
    root = Path(configured_root).resolve(strict=True)
    unresolved = Path(raw_path)
    if not unresolved.is_absolute() or unresolved.is_symlink():
        raise GuardError("MCP manifest path must be absolute and non-symlink")
    path = unresolved.resolve(strict=True)
    try:
        path.relative_to(root)
    except ValueError as exc:
        raise GuardError("MCP manifest is outside the configured root") from exc
    metadata = path.stat()
    if not path.is_file() or metadata.st_mode & 0o022:
        raise GuardError("MCP manifest metadata is unsafe")
    return path


def validate_protocol_line(line: bytes, direction: str) -> None:
    if len(line) > MAX_MESSAGE_BYTES:
        raise GuardError(f"MCP {direction} message exceeds {MAX_MESSAGE_BYTES} bytes")
    if not line.endswith(b"\n"):
        raise GuardError(f"MCP {direction} message is not newline terminated")
    try:
        payload = json.loads(line)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise GuardError(f"MCP {direction} contains non-JSON data") from exc
    if not isinstance(payload, dict):
        raise GuardError(f"MCP {direction} JSON-RPC message must be an object")


def drain_stderr(source: BinaryIO, stop: threading.Event) -> None:
    try:
        emitted = 0
        while not stop.is_set():
            chunk = source.read(4096)
            if not chunk:
                return
            if emitted < MAX_STDERR_BYTES:
                allowed = chunk[: MAX_STDERR_BYTES - emitted]
                sys.stderr.buffer.write(allowed)
                sys.stderr.buffer.flush()
                emitted += len(allowed)
    finally:
        source.close()


def relay_output(
    source: BinaryIO,
    target: BinaryIO | None = None,
    stop: threading.Event | None = None,
) -> None:
    output = target if target is not None else sys.stdout.buffer
    selector = selectors.DefaultSelector()
    try:
        selector.register(source, selectors.EVENT_READ)
        buffer = bytearray()
        while True:
            events = selector.select(timeout=0.2)
            if not events:
                if stop is not None and stop.is_set():
                    return
                continue
            chunk = os.read(source.fileno(), 65536)
            if not chunk:
                if buffer:
                    raise GuardError("MCP response is not newline terminated")
                return
            buffer.extend(chunk)
            if len(buffer) > MAX_MESSAGE_BYTES + 1 and b"\n" not in buffer:
                raise GuardError(
                    f"MCP response message exceeds {MAX_MESSAGE_BYTES} bytes"
                )
            while True:
                newline = buffer.find(b"\n")
                if newline < 0:
                    break
                line = bytes(buffer[: newline + 1])
                del buffer[: newline + 1]
                validate_protocol_line(line, "response")
                output.write(line)
                output.flush()
    finally:
        selector.close()


def signal_process_group(process: subprocess.Popen[bytes], requested_signal: int) -> None:
    if os.name == "posix":
        try:
            os.killpg(process.pid, requested_signal)
        except ProcessLookupError:
            pass
        return
    try:
        process.send_signal(requested_signal)
    except ProcessLookupError:
        pass


def stop_process(process: subprocess.Popen[bytes]) -> None:
    signal_process_group(process, signal.SIGTERM)
    try:
        process.wait(timeout=1)
    except subprocess.TimeoutExpired:
        signal_process_group(process, signal.SIGKILL)
        try:
            process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            pass


def start_server(manifest_path: Path) -> subprocess.Popen[bytes]:
    command, cwd, environment = load_command(manifest_path)
    return subprocess.Popen(
        command,
        cwd=cwd,
        env=environment,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=os.name == "posix",
    )


def run_relay(
    process: subprocess.Popen[bytes],
    input_source: BinaryIO,
    output_target: BinaryIO,
) -> int:
    assert process.stdin and process.stdout and process.stderr
    stop = threading.Event()
    input_errors: list[Exception] = []
    input_thread = threading.Thread(
        target=relay_stream_input,
        args=(input_source, process.stdin, stop, input_errors),
        daemon=True,
    )
    stderr_thread = threading.Thread(
        target=drain_stderr, args=(process.stderr, stop), daemon=True
    )
    input_thread.start()
    stderr_thread.start()
    try:
        relay_output(process.stdout, output_target, stop)
        return_code = process.wait(timeout=2)
        if input_errors:
            raise input_errors[0]
        return return_code
    finally:
        stop.set()
        stop_process(process)
        input_thread.join(timeout=0.5)
        stderr_thread.join(timeout=0.5)
        for stream in (process.stdin, process.stdout, process.stderr):
            try:
                stream.close()
            except OSError:
                pass


def relay_stream_input(
    source: BinaryIO,
    target: BinaryIO,
    stop: threading.Event,
    errors: list[Exception],
) -> None:
    try:
        while not stop.is_set():
            line = source.readline(MAX_MESSAGE_BYTES + 2)
            if not line:
                break
            validate_protocol_line(line, "request")
            target.write(line)
            target.flush()
    except (BrokenPipeError, OSError, GuardError) as exc:
        errors.append(exc)
    finally:
        stop.set()
        try:
            target.close()
        except OSError:
            pass


def run_local(manifest_path: Path) -> int:
    try:
        process = start_server(manifest_path)
    except (OSError, json.JSONDecodeError, GuardError) as exc:
        print(f"MCP stdio guard failed: {exc}", file=sys.stderr)
        return 1

    def terminate_guard(received_signal: int, _frame: object) -> None:
        stop_process(process)
        raise SystemExit(128 + received_signal)

    for handled_signal in (signal.SIGTERM, signal.SIGINT):
        signal.signal(handled_signal, terminate_guard)
    try:
        return run_relay(process, sys.stdin.buffer, sys.stdout.buffer)
    except (OSError, subprocess.TimeoutExpired, GuardError) as exc:
        print(f"MCP stdio guard failed: {exc}", file=sys.stderr)
        return 1


def send_handshake(connection: socket.socket, manifest_path: Path) -> None:
    payload = json.dumps(
        {"manifest": os.fspath(manifest_path.resolve())},
        ensure_ascii=True,
        separators=(",", ":"),
    ).encode("utf-8") + b"\n"
    connection.sendall(payload)


def run_isolated(manifest_path: Path, socket_path: str) -> int:
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.connect(socket_path)
            send_handshake(connection, manifest_path)
            source = connection.makefile("rb", buffering=0)
            target = connection.makefile("wb", buffering=0)
            stop = threading.Event()
            errors: list[Exception] = []
            input_thread = threading.Thread(
                target=relay_stream_input,
                args=(sys.stdin.buffer, target, stop, errors),
                daemon=True,
            )
            input_thread.start()
            try:
                relay_output(source, stop=stop)
                if errors:
                    raise errors[0]
                return 0
            finally:
                stop.set()
                try:
                    connection.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                input_thread.join(timeout=0.5)
                source.close()
                target.close()
    except (OSError, GuardError) as exc:
        print(f"MCP isolated stdio relay failed: {exc}", file=sys.stderr)
        return 1


def receive_handshake(source: BinaryIO) -> Path:
    line = source.readline(16_386)
    if not line or len(line) > 16_384 or not line.endswith(b"\n"):
        raise GuardError("MCP stdio relay handshake is invalid")
    try:
        payload = json.loads(line)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise GuardError("MCP stdio relay handshake is invalid") from exc
    if not isinstance(payload, dict) or set(payload) != {"manifest"}:
        raise GuardError("MCP stdio relay handshake is invalid")
    return trusted_manifest_path(payload["manifest"])


def handle_connection(connection: socket.socket, expected_uid: int) -> None:
    process: subprocess.Popen[bytes] | None = None
    source: BinaryIO | None = None
    target: BinaryIO | None = None
    try:
        require_peer_uid(connection, expected_uid)
        source = connection.makefile("rb", buffering=0)
        target = connection.makefile("wb", buffering=0)
        manifest_path = receive_handshake(source)
        connection.settimeout(None)
        process = start_server(manifest_path)
        run_relay(process, source, target)
    except Exception as exc:  # Isolate one malformed peer from the relay daemon.
        print(f"MCP isolated stdio server failed: {exc}", file=sys.stderr)
    finally:
        if process is not None:
            stop_process(process)
        if source is not None:
            source.close()
        if target is not None:
            target.close()


def serve() -> int:
    expected_uid = allowed_peer_uid("linux-agent-runner")
    listener = systemd_listener()
    capacity = threading.BoundedSemaphore(MAX_CONNECTIONS)

    def serve_connection(connection: socket.socket) -> None:
        try:
            with connection:
                connection.settimeout(15.0)
                handle_connection(connection, expected_uid)
        finally:
            capacity.release()

    with concurrent.futures.ThreadPoolExecutor(
        max_workers=MAX_CONNECTIONS,
        thread_name_prefix="mcp-stdio",
    ) as executor:
        while True:
            capacity.acquire()
            try:
                connection, _address = listener.accept()
            except Exception:
                capacity.release()
                raise
            try:
                executor.submit(serve_connection, connection)
            except Exception:
                connection.close()
                capacity.release()
                raise


def main() -> int:
    if len(sys.argv) == 2 and sys.argv[1] == "serve":
        return serve()
    if len(sys.argv) != 2:
        print("usage: mcp_stdio_guard.py <manifest> | serve", file=sys.stderr)
        return 2
    manifest_path = Path(sys.argv[1]).resolve()
    socket_path = os.environ.get("LINUX_AGENT_MCP_STDIO_SOCKET", "")
    if socket_path:
        return run_isolated(manifest_path, socket_path)
    return run_local(manifest_path)


if __name__ == "__main__":
    raise SystemExit(main())
