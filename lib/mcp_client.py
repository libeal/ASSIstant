#!/usr/bin/env python3
"""Small MCP client helper used by the Bash agent.

This intentionally implements only the client features this project needs:
initialize, tools/list, and tools/call over stdio, Streamable HTTP, and the
legacy HTTP+SSE transport.
"""

from __future__ import annotations

import argparse
import json
import os
import queue
import select
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any


PROTOCOL_VERSION = "2025-11-25"
DEFAULT_TIMEOUT_SEC = 15


class McpError(Exception):
    pass


class RpcError(McpError):
    def __init__(self, error: dict[str, Any]):
        self.error = error
        super().__init__(str(error.get("message") or error))


def emit(payload: dict[str, Any], exit_code: int = 0) -> int:
    sys.stdout.write(json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n")
    return exit_code


def load_json_file(path: str) -> Any:
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def manifest_timeout(manifest: dict[str, Any]) -> float:
    try:
        value = float(manifest.get("timeout_sec", DEFAULT_TIMEOUT_SEC))
    except (TypeError, ValueError):
        value = DEFAULT_TIMEOUT_SEC
    return max(1.0, min(value, 120.0))


def json_rpc_request(message_id: int, method: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
    payload: dict[str, Any] = {"jsonrpc": "2.0", "id": message_id, "method": method}
    if params is not None:
        payload["params"] = params
    return payload


def json_rpc_notification(method: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
    payload: dict[str, Any] = {"jsonrpc": "2.0", "method": method}
    if params is not None:
        payload["params"] = params
    return payload


def parse_sse_payload(raw: str) -> list[tuple[str, str]]:
    events: list[tuple[str, str]] = []
    event_name = "message"
    data_lines: list[str] = []
    for line in raw.splitlines():
        if line == "":
            if data_lines:
                events.append((event_name, "\n".join(data_lines)))
            event_name = "message"
            data_lines = []
            continue
        if line.startswith(":"):
            continue
        if line.startswith("event:"):
            event_name = line[6:].strip() or "message"
        elif line.startswith("data:"):
            data_lines.append(line[5:].lstrip())
    if data_lines:
        events.append((event_name, "\n".join(data_lines)))
    return events


class BaseClient:
    def __init__(self, manifest: dict[str, Any], manifest_path: str):
        self.manifest = manifest
        self.manifest_path = manifest_path
        self.timeout = manifest_timeout(manifest)
        self.next_id = 1
        self.negotiated_protocol = PROTOCOL_VERSION

    def next_message_id(self) -> int:
        value = self.next_id
        self.next_id += 1
        return value

    def send(self, message: dict[str, Any]) -> None:
        raise NotImplementedError

    def read_response(self, message_id: int) -> dict[str, Any]:
        raise NotImplementedError

    def request(self, method: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        message_id = self.next_message_id()
        self.send(json_rpc_request(message_id, method, params))
        response = self.read_response(message_id)
        if "error" in response:
            raise RpcError(response["error"])
        result = response.get("result")
        if not isinstance(result, dict):
            raise McpError(f"{method} returned a non-object result")
        return result

    def notification(self, method: str, params: dict[str, Any] | None = None) -> None:
        self.send(json_rpc_notification(method, params))

    def initialize(self) -> dict[str, Any]:
        result = self.request(
            "initialize",
            {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {},
                "clientInfo": {"name": "linux-agent", "version": "0.1.0"},
            },
        )
        protocol = result.get("protocolVersion")
        if isinstance(protocol, str) and protocol:
            self.negotiated_protocol = protocol
        self.notification("notifications/initialized")
        return result

    def list_tools(self) -> dict[str, Any]:
        self.initialize()
        return self.request("tools/list")

    def call_tool(self, tool_name: str, arguments: dict[str, Any]) -> dict[str, Any]:
        self.initialize()
        return self.request("tools/call", {"name": tool_name, "arguments": arguments})

    def close(self) -> None:
        return


class StdioClient(BaseClient):
    def __init__(self, manifest: dict[str, Any], manifest_path: str):
        super().__init__(manifest, manifest_path)
        command = manifest.get("command")
        if not isinstance(command, str) or not command:
            raise McpError("stdio manifest command is required")
        args = manifest.get("args") if isinstance(manifest.get("args"), list) else []
        if not all(isinstance(item, str) for item in args):
            raise McpError("stdio manifest args must be strings")
        env = os.environ.copy()
        manifest_env = manifest.get("env")
        if isinstance(manifest_env, dict):
            for key, value in manifest_env.items():
                if isinstance(key, str) and isinstance(value, str):
                    env[key] = value
        manifest_dir = str(Path(manifest_path).resolve().parent)
        cwd_value = manifest.get("cwd")
        if isinstance(cwd_value, str) and cwd_value:
            cwd = cwd_value if os.path.isabs(cwd_value) else str(Path(manifest_dir, cwd_value).resolve())
        else:
            cwd = manifest_dir
        self.stderr_lines: list[str] = []
        self.process = subprocess.Popen(
            [command, *args],
            cwd=cwd,
            env=env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            bufsize=1,
        )
        self.stderr_thread = threading.Thread(target=self._drain_stderr, daemon=True)
        self.stderr_thread.start()

    def _drain_stderr(self) -> None:
        if self.process.stderr is None:
            return
        for line in self.process.stderr:
            if len(self.stderr_lines) < 20:
                self.stderr_lines.append(line.rstrip("\n"))

    def send(self, message: dict[str, Any]) -> None:
        if self.process.stdin is None:
            raise McpError("stdio server stdin is unavailable")
        if self.process.poll() is not None:
            raise McpError(f"stdio server exited with code {self.process.returncode}")
        self.process.stdin.write(json.dumps(message, ensure_ascii=False, separators=(",", ":")) + "\n")
        self.process.stdin.flush()

    def read_response(self, message_id: int) -> dict[str, Any]:
        if self.process.stdout is None:
            raise McpError("stdio server stdout is unavailable")
        deadline = time.monotonic() + self.timeout
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise McpError(f"stdio server exited with code {self.process.returncode}")
            remaining = max(0.05, deadline - time.monotonic())
            readable, _, _ = select.select([self.process.stdout], [], [], min(remaining, 0.2))
            if not readable:
                continue
            line = self.process.stdout.readline()
            if not line:
                continue
            try:
                payload = json.loads(line)
            except json.JSONDecodeError:
                raise McpError("stdio server wrote non-JSON data to stdout")
            if not isinstance(payload, dict):
                raise McpError("JSON-RPC response must be an object")
            if payload.get("id") == message_id:
                return payload
        raise McpError(f"timed out waiting for JSON-RPC response id {message_id}")

    def close(self) -> None:
        if self.process.poll() is None:
            try:
                self.process.terminate()
                self.process.wait(timeout=2)
            except Exception:
                self.process.kill()


class StreamableHttpClient(BaseClient):
    def __init__(self, manifest: dict[str, Any], manifest_path: str):
        super().__init__(manifest, manifest_path)
        url = manifest.get("url")
        if not isinstance(url, str) or not url:
            raise McpError("streamable_http manifest url is required")
        self.url = url
        self.session_id = ""

    def _headers(self, accept: str) -> dict[str, str]:
        headers = {
            "Accept": accept,
            "Content-Type": "application/json",
            "MCP-Protocol-Version": self.negotiated_protocol,
        }
        manifest_headers = self.manifest.get("headers")
        if isinstance(manifest_headers, dict):
            for key, value in manifest_headers.items():
                if isinstance(key, str) and isinstance(value, str):
                    headers[key] = value
        if self.session_id:
            headers["MCP-Session-Id"] = self.session_id
        return headers

    def send(self, message: dict[str, Any]) -> None:
        # Streamable HTTP request/response handling is synchronous, so request()
        # overrides this method. Notifications still go through here.
        data = json.dumps(message, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        request = urllib.request.Request(self.url, data=data, headers=self._headers("application/json,text/event-stream"), method="POST")
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                if response.headers.get("MCP-Session-Id"):
                    self.session_id = response.headers.get("MCP-Session-Id", "")
                response.read()
        except urllib.error.HTTPError as exc:
            if exc.code != 202:
                raise McpError(f"HTTP notification failed with status {exc.code}") from exc

    def request(self, method: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        message_id = self.next_message_id()
        message = json_rpc_request(message_id, method, params)
        data = json.dumps(message, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        request = urllib.request.Request(self.url, data=data, headers=self._headers("application/json,text/event-stream"), method="POST")
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                if response.headers.get("MCP-Session-Id"):
                    self.session_id = response.headers.get("MCP-Session-Id", "")
                content_type = response.headers.get("Content-Type", "")
                raw = response.read().decode("utf-8")
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")[:500]
            raise McpError(f"HTTP request failed with status {exc.code}: {detail}") from exc
        if "text/event-stream" in content_type:
            for _, data_text in parse_sse_payload(raw):
                try:
                    payload = json.loads(data_text)
                except json.JSONDecodeError:
                    continue
                if payload.get("id") == message_id:
                    if "error" in payload:
                        raise RpcError(payload["error"])
                    result = payload.get("result")
                    if not isinstance(result, dict):
                        raise McpError(f"{method} returned a non-object result")
                    return result
            raise McpError(f"HTTP SSE stream did not include response id {message_id}")
        payload = json.loads(raw or "{}")
        if payload.get("id") != message_id:
            raise McpError(f"HTTP response id mismatch for {method}")
        if "error" in payload:
            raise RpcError(payload["error"])
        result = payload.get("result")
        if not isinstance(result, dict):
            raise McpError(f"{method} returned a non-object result")
        return result


class LegacySseClient(BaseClient):
    def __init__(self, manifest: dict[str, Any], manifest_path: str):
        super().__init__(manifest, manifest_path)
        url = manifest.get("url")
        if not isinstance(url, str) or not url:
            raise McpError("sse manifest url is required")
        self.url = url
        message_url = manifest.get("message_url")
        self.message_url = message_url if isinstance(message_url, str) else ""
        self.responses: "queue.Queue[dict[str, Any]]" = queue.Queue()
        self.stop_event = threading.Event()
        self.stream_thread = threading.Thread(target=self._read_stream, daemon=True)
        self.stream_thread.start()
        if not self.message_url:
            deadline = time.monotonic() + self.timeout
            while not self.message_url and time.monotonic() < deadline:
                time.sleep(0.05)
        if not self.message_url:
            raise McpError("legacy sse manifest requires message_url or endpoint event")

    def _headers(self) -> dict[str, str]:
        headers = {"Accept": "application/json"}
        manifest_headers = self.manifest.get("headers")
        if isinstance(manifest_headers, dict):
            for key, value in manifest_headers.items():
                if isinstance(key, str) and isinstance(value, str):
                    headers[key] = value
        return headers

    def _read_stream(self) -> None:
        request = urllib.request.Request(self.url, headers={"Accept": "text/event-stream"}, method="GET")
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                event_name = "message"
                data_lines: list[str] = []
                while not self.stop_event.is_set():
                    raw_line = response.readline()
                    if not raw_line:
                        break
                    line = raw_line.decode("utf-8", errors="replace").rstrip("\r\n")
                    if line == "":
                        self._handle_event(event_name, "\n".join(data_lines))
                        event_name = "message"
                        data_lines = []
                    elif line.startswith("event:"):
                        event_name = line[6:].strip() or "message"
                    elif line.startswith("data:"):
                        data_lines.append(line[5:].lstrip())
        except Exception as exc:
            self.responses.put({"jsonrpc": "2.0", "id": "__stream_error__", "error": {"code": -32000, "message": str(exc)}})

    def _handle_event(self, event_name: str, data_text: str) -> None:
        if not data_text:
            return
        if event_name == "endpoint" and not self.message_url:
            self.message_url = urllib.parse.urljoin(self.url, data_text)
            return
        try:
            payload = json.loads(data_text)
        except json.JSONDecodeError:
            return
        if isinstance(payload, dict):
            self.responses.put(payload)

    def send(self, message: dict[str, Any]) -> None:
        data = json.dumps(message, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        request = urllib.request.Request(self.message_url, data=data, headers=self._headers(), method="POST")
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                response.read()
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")[:500]
            raise McpError(f"legacy SSE POST failed with status {exc.code}: {detail}") from exc

    def read_response(self, message_id: int) -> dict[str, Any]:
        deadline = time.monotonic() + self.timeout
        while time.monotonic() < deadline:
            try:
                payload = self.responses.get(timeout=0.2)
            except queue.Empty:
                continue
            if payload.get("id") == "__stream_error__":
                raise McpError(payload.get("error", {}).get("message", "SSE stream failed"))
            if payload.get("id") == message_id:
                return payload
        raise McpError(f"timed out waiting for legacy SSE response id {message_id}")

    def close(self) -> None:
        self.stop_event.set()


def create_client(manifest: dict[str, Any], manifest_path: str) -> BaseClient:
    transport = manifest.get("transport")
    if transport == "stdio":
        return StdioClient(manifest, manifest_path)
    if transport == "streamable_http":
        return StreamableHttpClient(manifest, manifest_path)
    if transport == "sse":
        return LegacySseClient(manifest, manifest_path)
    raise McpError(f"unsupported transport: {transport}")


def normalize_tools(raw_tools: Any) -> list[dict[str, Any]]:
    if not isinstance(raw_tools, list):
        raise McpError("tools/list result.tools must be an array")
    tools: list[dict[str, Any]] = []
    for raw in raw_tools:
        if not isinstance(raw, dict):
            continue
        name = raw.get("name")
        if not isinstance(name, str) or not name:
            continue
        tool = {
            "name": name,
            "description": raw.get("description") if isinstance(raw.get("description"), str) else "",
            "inputSchema": raw.get("inputSchema") if isinstance(raw.get("inputSchema"), dict) else {},
        }
        if isinstance(raw.get("annotations"), dict):
            tool["annotations"] = raw["annotations"]
        if isinstance(raw.get("outputSchema"), dict):
            tool["outputSchema"] = raw["outputSchema"]
        tools.append(tool)
    return tools


def action_list_tools(manifest_path: str) -> int:
    manifest = load_json_file(manifest_path)
    client = create_client(manifest, manifest_path)
    try:
        result = client.list_tools()
        tools = normalize_tools(result.get("tools"))
        return emit(
            {
                "ok": True,
                "status": "listed",
                "server_id": manifest.get("id", ""),
                "server_name": manifest.get("name") or manifest.get("id", ""),
                "transport": manifest.get("transport", ""),
                "server_info": result.get("serverInfo") if isinstance(result.get("serverInfo"), dict) else {},
                "tools": tools,
                "tool_count": len(tools),
            }
        )
    finally:
        client.close()


def action_call_tool(manifest_path: str, tool_name: str, arguments_file: str) -> int:
    manifest = load_json_file(manifest_path)
    arguments = load_json_file(arguments_file)
    if not isinstance(arguments, dict):
        raise McpError("tool arguments must be a JSON object")
    client = create_client(manifest, manifest_path)
    try:
        result = client.call_tool(tool_name, arguments)
        is_error = bool(result.get("isError"))
        server_id = str(manifest.get("id") or "")
        output = {
            "tool": f"mcp.{server_id}.{tool_name}",
            "server_id": server_id,
            "mcp_tool": tool_name,
            "content": result.get("content") if isinstance(result.get("content"), list) else [],
            "structuredContent": result.get("structuredContent") if isinstance(result.get("structuredContent"), dict) else {},
            "isError": is_error,
        }
        return emit(
            {
                "ok": not is_error,
                "status": "tool_error" if is_error else "executed",
                "server_id": server_id,
                "tool": tool_name,
                "transport": manifest.get("transport", ""),
                "result": result,
                "output": output,
            },
            1 if is_error else 0,
        )
    finally:
        client.close()


def main() -> int:
    parser = argparse.ArgumentParser(description="Minimal MCP client helper")
    subparsers = parser.add_subparsers(dest="command", required=True)

    list_parser = subparsers.add_parser("list-tools")
    list_parser.add_argument("manifest")

    call_parser = subparsers.add_parser("call-tool")
    call_parser.add_argument("manifest")
    call_parser.add_argument("tool")
    call_parser.add_argument("arguments_file")

    args = parser.parse_args()
    try:
        if args.command == "list-tools":
            return action_list_tools(args.manifest)
        if args.command == "call-tool":
            return action_call_tool(args.manifest, args.tool, args.arguments_file)
        raise McpError("unknown command")
    except Exception as exc:
        status = "mcp_rpc_error" if isinstance(exc, RpcError) else "mcp_client_error"
        payload: dict[str, Any] = {"ok": False, "status": status, "error": str(exc)}
        if isinstance(exc, RpcError):
            payload["rpc_error"] = exc.error
        return emit(payload, 1)


if __name__ == "__main__":
    raise SystemExit(main())
