"""Integration tests for the MCP 2.0 adapter and pinned SDK runtime."""

from __future__ import annotations

import asyncio
import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
CLIENT = ROOT / "lib" / "mcp_client.py"
FAKE_SERVER = ROOT / "tests" / "fake_mcp_server.py"
sys.path.insert(0, os.fspath(ROOT / "lib"))
import runner
import mcp_client
import mcp_credentials


class McpAdapterIntegrationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.log_path = self.directory / "wire.jsonl"

    def test_modern_fallback_does_not_require_base_exception_group(self) -> None:
        error = mcp_client.McpAdapterError(
            "mcp_protocol_unsupported",
            "fallback probe",
            fallback_allowed=True,
        )
        with mock.patch.object(mcp_client, "BASE_EXCEPTION_GROUP", ()):
            self.assertTrue(
                mcp_client.modern_fallback_allowed(
                    mcp_client.ModernNegotiationFailure(error)
                )
            )

    def write_manifest(self, mode: str, behavior: str = "normal") -> Path:
        path = self.directory / "mcp.json"
        path.write_text(
            json.dumps(
                {
                    "manifest_version": 2,
                    "id": "fake-modern",
                    "transport": "stdio",
                    "command": sys.executable,
                    "args": [os.fspath(FAKE_SERVER), "stdio"],
                    "env": {
                        "FAKE_MCP_LOG": os.fspath(self.log_path),
                        "FAKE_MCP_BEHAVIOR": behavior,
                    },
                    "protocol": {"mode": mode},
                }
            ),
            encoding="utf-8",
        )
        return path

    def start_http_server(self, behavior: str = "normal") -> tuple[ThreadingHTTPServer, list[dict[str, object]]]:
        records: list[dict[str, object]] = []

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, _format: str, *_arguments: object) -> None:
                return

            def do_GET(self) -> None:
                records.append(
                    {
                        "method": "GET",
                        "path": self.path,
                        "headers": {
                            key.lower(): value for key, value in self.headers.items()
                        },
                    }
                )
                body = b'{}'
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_POST(self) -> None:
                length = int(self.headers.get("Content-Length", "0"))
                raw = self.rfile.read(length)
                request = json.loads(raw)
                records.append(
                    {
                        "request": request,
                        "headers": {key.lower(): value for key, value in self.headers.items()},
                    }
                )
                if behavior == "redirect":
                    self.send_response(307)
                    self.send_header("Location", "/redirected")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                if behavior == "unauthorized":
                    body = b'{"error":"unauthorized"}'
                    self.send_response(401)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                    return
                method = request.get("method")
                message_id = request.get("id")
                if method == "server/discover":
                    result = {
                        "_meta": {
                            "io.modelcontextprotocol/serverInfo": {
                                "name": "fake-http",
                                "version": "2.0.0",
                            }
                        },
                        "cacheScope": "private",
                        "capabilities": {"tools": {"listChanged": False}},
                        "resultType": "complete",
                        "supportedVersions": ["2026-07-28"],
                        "ttlMs": 0,
                    }
                elif method == "tools/list":
                    input_schema = {
                        "type": "object",
                        "properties": {"text": {"type": "string"}},
                    }
                    if behavior == "derived_header":
                        input_schema["properties"]["text"]["x-mcp-header"] = "Region"
                    cursor = request.get("params", {}).get("cursor")
                    if behavior in {"paginated", "repeated_cursor"}:
                        tool_name = "zeta" if cursor is None else "alpha"
                        next_cursor = "page-2" if cursor is None or behavior == "repeated_cursor" else None
                    else:
                        tool_name = "echo"
                        next_cursor = None
                    result = {
                        "cacheScope": "private",
                        "resultType": "complete",
                        "tools": [
                            {
                                "name": tool_name,
                                "description": "Echo text.",
                                "inputSchema": input_schema,
                            }
                        ],
                        "ttlMs": 0,
                    }
                    if next_cursor is not None:
                        result["nextCursor"] = next_cursor
                else:
                    if behavior == "content_blocks":
                        result = {
                            "content": [
                                {"type": "text", "text": "ok"},
                                {"type": "image", "data": "AA==", "mimeType": "image/png"},
                                {"type": "audio", "data": "AA==", "mimeType": "audio/wav"},
                                {
                                    "type": "resource",
                                    "resource": {
                                        "uri": "test://embedded",
                                        "mimeType": "text/plain",
                                        "text": "embedded",
                                    },
                                },
                                {
                                    "type": "resource_link",
                                    "name": "unfetched",
                                    "uri": f"http://127.0.0.1:{self.server.server_port}/unfetched",
                                },
                            ],
                            "isError": False,
                            "resultType": "complete",
                            "structuredContent": request.get("params", {})
                            .get("arguments", {})
                            .get("structured"),
                        }
                    elif behavior == "echo_authorization":
                        authorization = self.headers.get("Authorization", "")
                        _, _, credential = authorization.partition(" ")
                        result = {
                            "content": [
                                {
                                    "type": "text",
                                    "text": f"received {authorization}",
                                }
                            ],
                            "isError": False,
                            "resultType": "complete",
                            "structuredContent": {
                                "echoed": authorization,
                                "bare": credential,
                            },
                        }
                    else:
                        result = {
                            "content": [{"type": "text", "text": "ok"}],
                            "isError": False,
                            "resultType": "complete",
                            "structuredContent": {"ok": True},
                        }
                body = json.dumps(
                    {"jsonrpc": "2.0", "id": message_id, "result": result},
                    separators=(",", ":"),
                ).encode()
                if behavior == "oversized":
                    body += b" " * 1_048_576
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                try:
                    self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError):
                    pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return server, records

    def start_oauth_server(
        self,
        *,
        cimd_supported: bool,
        issuer_path: str = "",
        issue_client_credentials: bool = False,
    ) -> tuple[ThreadingHTTPServer, list[dict[str, object]]]:
        records: list[dict[str, object]] = []

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, _format: str, *_arguments: object) -> None:
                return

            def record(self, body: bytes = b"") -> None:
                records.append(
                    {
                        "method": self.command,
                        "path": self.path,
                        "body": body.decode("utf-8", errors="replace"),
                        "headers": {
                            key.lower(): value for key, value in self.headers.items()
                        },
                    }
                )

            def send_json(self, status: int, payload: dict[str, object]) -> None:
                body = json.dumps(payload, separators=(",", ":")).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self) -> None:
                self.record()
                origin = f"http://127.0.0.1:{self.server.server_port}"
                issuer = f"{origin}{issuer_path}"
                if self.path == "/.well-known/oauth-protected-resource/mcp":
                    self.send_json(
                        200,
                        {
                            "resource": f"{origin}/mcp",
                            "authorization_servers": [issuer],
                        },
                    )
                    return
                if self.path in {
                    "/.well-known/oauth-authorization-server",
                    f"/.well-known/oauth-authorization-server{issuer_path}",
                }:
                    self.send_json(
                        200,
                        {
                            "issuer": issuer,
                            "authorization_endpoint": f"{origin}/authorize",
                            "token_endpoint": f"{origin}/token",
                            "registration_endpoint": f"{origin}/register",
                            "response_types_supported": ["code"],
                            "grant_types_supported": [
                                "authorization_code",
                                "refresh_token",
                                *(
                                    ["client_credentials"]
                                    if issue_client_credentials
                                    else []
                                ),
                            ],
                            "code_challenge_methods_supported": ["S256"],
                            "client_id_metadata_document_supported": cimd_supported,
                            "authorization_response_iss_parameter_supported": True,
                        },
                    )
                    return
                self.send_json(404, {"error": "not_found"})

            def do_POST(self) -> None:
                length = int(self.headers.get("Content-Length", "0"))
                body = self.rfile.read(length)
                self.record(body)
                origin = f"http://127.0.0.1:{self.server.server_port}"
                if self.path == "/mcp":
                    if (
                        issue_client_credentials
                        and self.headers.get("Authorization")
                        == "Bearer persisted-access-token"
                    ):
                        request = json.loads(body)
                        method = request.get("method")
                        if method == "server/discover":
                            result: dict[str, object] = {
                                "_meta": {
                                    "io.modelcontextprotocol/serverInfo": {
                                        "name": "fake-oauth",
                                        "version": "2.0.0",
                                    }
                                },
                                "cacheScope": "private",
                                "capabilities": {"tools": {"listChanged": False}},
                                "resultType": "complete",
                                "supportedVersions": ["2026-07-28"],
                                "ttlMs": 0,
                            }
                        elif method == "tools/list":
                            result = {
                                "cacheScope": "private",
                                "resultType": "complete",
                                "tools": [
                                    {
                                        "name": "echo",
                                        "description": "Echo text.",
                                        "inputSchema": {
                                            "type": "object",
                                            "properties": {
                                                "text": {"type": "string"}
                                            },
                                        },
                                    }
                                ],
                                "ttlMs": 0,
                            }
                        else:
                            authorization = self.headers.get("Authorization", "")
                            _, _, credential = authorization.partition(" ")
                            result = {
                                "content": [
                                    {
                                        "type": "text",
                                        "text": f"secure {authorization}",
                                    }
                                ],
                                "isError": False,
                                "resultType": "complete",
                                "structuredContent": {
                                    "ok": True,
                                    "echoed": authorization,
                                    "bare": credential,
                                },
                            }
                        self.send_json(
                            200,
                            {
                                "jsonrpc": "2.0",
                                "id": request.get("id"),
                                "result": result,
                            },
                        )
                        return
                    payload = b'{"error":"unauthorized"}'
                    self.send_response(401)
                    self.send_header(
                        "WWW-Authenticate",
                        f'Bearer resource_metadata="{origin}/.well-known/oauth-protected-resource/mcp"',
                    )
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(payload)))
                    self.end_headers()
                    self.wfile.write(payload)
                    return
                if self.path == "/token" and issue_client_credentials:
                    self.send_json(
                        200,
                        {
                            "access_token": "persisted-access-token",
                            "token_type": "Bearer",
                            "scope": "read",
                        },
                    )
                    return
                if self.path == "/register":
                    self.send_json(
                        201,
                        {
                            "client_id": "dcr-client",
                            "redirect_uris": ["http://127.0.0.1:8766/callback"],
                            "grant_types": ["authorization_code", "refresh_token"],
                            "response_types": ["code"],
                            "token_endpoint_auth_method": "none",
                        },
                    )
                    return
                self.send_json(400, {"error": "unexpected_request"})

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return server, records

    def write_http_manifest(self, server: ThreadingHTTPServer, mode: str = "modern_only") -> Path:
        path = self.directory / "mcp.json"
        path.write_text(
            json.dumps(
                {
                    "manifest_version": 2,
                    "id": "fake-http",
                    "transport": "streamable_http",
                    "url": f"http://127.0.0.1:{server.server_port}/mcp",
                    "headers": {"X-Test-Header": "present"},
                    "protocol": {"mode": mode},
                }
            ),
            encoding="utf-8",
        )
        return path

    def run_client(self, *arguments: str) -> tuple[subprocess.CompletedProcess[str], dict[str, object]]:
        environment = dict(os.environ)
        environment["LINUX_AGENT_MCP_SELECTION_CACHE_DIR"] = os.fspath(
            self.directory / "selection-cache"
        )
        completed = subprocess.run(
            [sys.executable, os.fspath(CLIENT), *arguments],
            cwd=ROOT,
            env=environment,
            check=False,
            capture_output=True,
            text=True,
            timeout=30,
        )
        try:
            payload = json.loads(completed.stdout)
        except json.JSONDecodeError as exc:
            self.fail(f"adapter returned invalid JSON: {completed.stdout!r}; stderr={completed.stderr!r}; {exc}")
        return completed, payload

    def write_arguments(self) -> Path:
        path = self.directory / "arguments.json"
        path.write_text('{"text":"hello"}', encoding="utf-8")
        os.chmod(path, 0o600)
        return path

    def write_input_responses(self, name: str = "responses.json") -> Path:
        path = self.directory / name
        path.write_text(
            json.dumps(
                {
                    "email": {
                        "action": "accept",
                        "content": {"email": "user@example.test"},
                    }
                }
            ),
            encoding="utf-8",
        )
        os.chmod(path, 0o600)
        return path

    def run_oauth_profile(
        self,
        server: ThreadingHTTPServer,
        profile: dict[str, object],
    ) -> tuple[dict[str, object], dict[str, str], list[str]]:
        data_dir = self.directory / f"data-{profile['id']}"
        mcp_dir = self.directory / f"mcp-{profile['id']}"
        runner_tmp = data_dir / "runner-tmp"
        credential_dir = data_dir / "mcp" / "credentials"
        user_skills = data_dir / "skills"
        server_dir = mcp_dir / "fake-oauth"
        for directory in (runner_tmp, credential_dir, user_skills, server_dir):
            directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        profile_path = credential_dir / f"{profile['id']}.json"
        if not profile_path.exists():
            profile_path.write_text(json.dumps(profile), encoding="utf-8")
            os.chmod(profile_path, 0o600)
        manifest = server_dir / "mcp.json"
        manifest.write_text(
            json.dumps(
                {
                    "manifest_version": 2,
                    "id": "fake-oauth",
                    "transport": "streamable_http",
                    "url": f"http://127.0.0.1:{server.server_port}/mcp",
                    "credential_profile": profile["id"],
                    "protocol": {"mode": "modern_then_legacy"},
                }
            ),
            encoding="utf-8",
        )
        arguments = runner_tmp / "arguments.json"
        arguments.write_text('{"text":"secure"}', encoding="utf-8")
        os.chmod(arguments, 0o600)
        params = {
            "kind": "mcp",
            "argv": [
                "python3",
                os.fspath(CLIENT),
                "call-tool",
                os.fspath(manifest),
                "echo",
                os.fspath(arguments),
            ],
            "timeout_sec": 30,
            "max_output_bytes": 1_048_576,
        }
        environment = {
            "LINUX_AGENT_ROOT": os.fspath(ROOT),
            "LINUX_AGENT_DATA_DIR": os.fspath(data_dir),
            "LINUX_AGENT_MCP_DIR": os.fspath(mcp_dir),
            "LINUX_AGENT_TMP_ROOT": os.fspath(runner_tmp),
            "LINUX_AGENT_USER_SKILLS_DIR": os.fspath(user_skills),
        }
        with mock.patch.dict(os.environ, environment, clear=False):
            _kind, command, timeout, output_limit, overrides = runner.validate_execution(
                params
            )
            result = runner.execute(command, timeout, output_limit, overrides)
        payload = json.loads(str(result["stdout"]))
        return payload, overrides, command

    def wire_messages(self) -> list[dict[str, object]]:
        return [json.loads(line) for line in self.log_path.read_text(encoding="utf-8").splitlines()]

    def test_modern_list_uses_discover_without_legacy_handshake(self) -> None:
        manifest = self.write_manifest("modern_only")

        completed, payload = self.run_client("list-tools", os.fspath(manifest))

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertTrue(payload["ok"])
        self.assertEqual(payload["protocol_version"], "2026-07-28")
        self.assertFalse(payload["fallback_used"])
        self.assertEqual(payload["server_info"], {"name": "fake-mcp", "version": "2.0.0"})
        self.assertEqual([item["name"] for item in payload["tools"]], ["echo"])
        methods = [message.get("method") for message in self.wire_messages()]
        self.assertEqual(methods, ["server/discover", "tools/list"])

    def test_modern_list_follows_all_pages_and_sorts_tools(self) -> None:
        server, records = self.start_http_server("paginated")
        manifest = self.write_http_manifest(server, "modern_only")

        completed, payload = self.run_client("list-tools", os.fspath(manifest))

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual([tool["name"] for tool in payload["tools"]], ["alpha", "zeta"])
        list_requests = [
            record["request"]
            for record in records
            if record.get("request", {}).get("method") == "tools/list"
        ]
        self.assertEqual(len(list_requests), 2)
        self.assertEqual(list_requests[1]["params"]["cursor"], "page-2")

    def test_modern_list_rejects_a_repeated_cursor(self) -> None:
        server, records = self.start_http_server("repeated_cursor")
        manifest = self.write_http_manifest(server, "modern_only")

        completed, payload = self.run_client("list-tools", os.fspath(manifest))

        self.assertEqual(completed.returncode, 1)
        self.assertEqual(payload["status"], "mcp_pagination_invalid")
        self.assertFalse(payload["fallback_used"])
        self.assertEqual(
            sum(
                record.get("request", {}).get("method") == "tools/list"
                for record in records
            ),
            2,
        )

    def test_tool_list_rejects_non_object_entries(self) -> None:
        with self.assertRaisesRegex(
            mcp_client.McpAdapterError,
            "must contain only objects",
        ):
            mcp_client.normalize_tools(
                [
                    {
                        "name": "valid",
                        "description": "valid",
                        "inputSchema": {"type": "object"},
                    },
                    "invalid",
                ]
            )

    def test_modern_call_preserves_structured_content(self) -> None:
        manifest = self.write_manifest("modern_only")
        arguments_path = self.directory / "arguments.json"
        arguments_path.write_text('{"text":"hello"}', encoding="utf-8")
        os.chmod(arguments_path, 0o600)

        completed, payload = self.run_client(
            "call-tool",
            os.fspath(manifest),
            "echo",
            os.fspath(arguments_path),
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(payload["status"], "executed")
        self.assertEqual(payload["result"]["structuredContent"], {"echo": "hello"})
        self.assertEqual(payload["result"]["resultType"], "complete")
        methods = [message.get("method") for message in self.wire_messages()]
        self.assertEqual(methods, ["server/discover", "tools/list", "tools/call"])

    def test_modern_call_preserves_all_content_and_structured_json_types(self) -> None:
        server, records = self.start_http_server("content_blocks")
        manifest = self.write_http_manifest(server, "modern_only")
        variants = [
            ["array"],
            "string",
            17,
            True,
            None,
            {"object": True},
        ]

        for index, structured in enumerate(variants):
            arguments = self.directory / f"content-arguments-{index}.json"
            arguments.write_text(
                json.dumps({"structured": structured}),
                encoding="utf-8",
            )
            os.chmod(arguments, 0o600)
            completed, payload = self.run_client(
                "call-tool",
                os.fspath(manifest),
                "echo",
                os.fspath(arguments),
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIn("structuredContent", payload["result"])
            self.assertEqual(payload["result"]["structuredContent"], structured)
            self.assertEqual(
                [item["type"] for item in payload["result"]["content"]],
                ["text", "image", "audio", "resource", "resource_link"],
            )

        self.assertFalse(any(record.get("method") == "GET" for record in records))

    def test_method_not_found_falls_back_on_fresh_legacy_connection(self) -> None:
        manifest = self.write_manifest("modern_then_legacy", "discover_method_not_found")

        completed, payload = self.run_client("list-tools", os.fspath(manifest))

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertTrue(payload["fallback_used"])
        self.assertEqual(payload["protocol_version"], "2025-11-25")
        methods = [message.get("method") for message in self.wire_messages()]
        self.assertEqual(
            methods,
            ["server/discover", "initialize", "notifications/initialized", "tools/list"],
        )

    def test_protocol_selection_cache_and_manual_refresh(self) -> None:
        modern_manifest = self.write_manifest("modern_then_legacy")

        first, first_payload = self.run_client(
            "list-tools", os.fspath(modern_manifest)
        )
        first_count = len(self.wire_messages())
        second, second_payload = self.run_client(
            "list-tools", os.fspath(modern_manifest)
        )
        second_messages = self.wire_messages()[first_count:]

        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertFalse(first_payload["fallback_used"])
        self.assertFalse(second_payload["fallback_used"])
        self.assertEqual(
            [message.get("method") for message in second_messages],
            ["tools/list"],
        )

        self.log_path.unlink()
        legacy_manifest = self.write_manifest(
            "modern_then_legacy", "discover_method_not_found"
        )
        legacy_first, legacy_first_payload = self.run_client(
            "list-tools", os.fspath(legacy_manifest)
        )
        legacy_first_count = len(self.wire_messages())
        legacy_second, legacy_second_payload = self.run_client(
            "list-tools", os.fspath(legacy_manifest)
        )
        cached_messages = self.wire_messages()[legacy_first_count:]
        refresh_count = len(self.wire_messages())
        refreshed, refreshed_payload = self.run_client(
            "list-tools", os.fspath(legacy_manifest), "--refresh"
        )
        refreshed_messages = self.wire_messages()[refresh_count:]

        self.assertEqual(legacy_first.returncode, 0, legacy_first.stderr)
        self.assertEqual(legacy_second.returncode, 0, legacy_second.stderr)
        self.assertEqual(refreshed.returncode, 0, refreshed.stderr)
        self.assertTrue(legacy_first_payload["fallback_used"])
        self.assertTrue(legacy_second_payload["fallback_used"])
        self.assertTrue(refreshed_payload["fallback_used"])
        self.assertNotIn(
            "server/discover",
            [message.get("method") for message in cached_messages],
        )
        self.assertIn(
            "server/discover",
            [message.get("method") for message in refreshed_messages],
        )

    def test_disjoint_modern_versions_do_not_fall_back(self) -> None:
        manifest = self.write_manifest("modern_then_legacy", "discover_future_only")

        completed, payload = self.run_client("list-tools", os.fspath(manifest))

        self.assertEqual(completed.returncode, 1)
        self.assertFalse(payload["fallback_used"])
        methods = [message.get("method") for message in self.wire_messages()]
        self.assertEqual(methods, ["server/discover"])

    def test_incompatible_modern_tool_probe_falls_back_for_listing(self) -> None:
        manifest = self.write_manifest("modern_then_legacy", "invalid_tool_list")

        completed, payload = self.run_client("list-tools", os.fspath(manifest))

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertTrue(payload["fallback_used"])
        self.assertEqual(payload["protocol_version"], "2025-11-25")
        methods = [message.get("method") for message in self.wire_messages()]
        self.assertEqual(
            methods,
            [
                "server/discover",
                "tools/list",
                "initialize",
                "notifications/initialized",
                "tools/list",
            ],
        )

    def test_incompatible_modern_tool_probe_falls_back_before_call(self) -> None:
        manifest = self.write_manifest("modern_then_legacy", "invalid_tool_list")
        arguments_path = self.directory / "arguments.json"
        arguments_path.write_text('{"text":"legacy"}', encoding="utf-8")
        os.chmod(arguments_path, 0o600)

        completed, payload = self.run_client(
            "call-tool",
            os.fspath(manifest),
            "echo",
            os.fspath(arguments_path),
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertTrue(payload["fallback_used"])
        self.assertEqual(payload["protocol_version"], "2025-11-25")
        methods = [message.get("method") for message in self.wire_messages()]
        self.assertEqual(
            methods,
            [
                "server/discover",
                "tools/list",
                "initialize",
                "notifications/initialized",
                "tools/call",
            ],
        )

    def test_disconnect_after_call_is_unknown_and_never_replayed(self) -> None:
        manifest = self.write_manifest("modern_then_legacy", "disconnect_on_call")
        arguments_path = self.directory / "arguments.json"
        arguments_path.write_text('{"text":"once"}', encoding="utf-8")
        os.chmod(arguments_path, 0o600)

        completed, payload = self.run_client(
            "call-tool",
            os.fspath(manifest),
            "echo",
            os.fspath(arguments_path),
        )

        self.assertEqual(completed.returncode, 1)
        self.assertEqual(payload["status"], "mcp_outcome_unknown")
        self.assertFalse(payload["outcome_known"])
        self.assertFalse(payload["fallback_used"])
        self.assertEqual(payload["server_id"], "fake-modern")
        self.assertEqual(payload["tool"], "echo")
        self.assertEqual(payload["protocol_version"], "2026-07-28")
        methods = [message.get("method") for message in self.wire_messages()]
        self.assertEqual(methods, ["server/discover", "tools/list", "tools/call"])

    def test_rpc_error_after_call_is_known_and_never_replayed(self) -> None:
        manifest = self.write_manifest("modern_then_legacy", "rpc_error_on_call")
        arguments_path = self.directory / "arguments.json"
        arguments_path.write_text('{"text":"once"}', encoding="utf-8")
        os.chmod(arguments_path, 0o600)

        completed, payload = self.run_client(
            "call-tool",
            os.fspath(manifest),
            "echo",
            os.fspath(arguments_path),
        )

        self.assertEqual(completed.returncode, 1)
        self.assertEqual(payload["status"], "mcp_rpc_error")
        self.assertTrue(payload["outcome_known"])
        self.assertFalse(payload["fallback_used"])
        self.assertEqual(payload["server_id"], "fake-modern")
        self.assertEqual(payload["tool"], "echo")
        self.assertEqual(payload["protocol_version"], "2026-07-28")
        self.assertEqual(
            payload["rpc_error"],
            {"code": -32602, "message": "invalid test arguments"},
        )
        self.assertNotIn("must-not-be-returned", json.dumps(payload))
        methods = [message.get("method") for message in self.wire_messages()]
        self.assertEqual(methods, ["server/discover", "tools/list", "tools/call"])

    def test_input_required_round_trip_uses_private_continuation(self) -> None:
        manifest = self.write_manifest("modern_only", "input_required")
        arguments_path = self.write_arguments()

        first, required = self.run_client(
            "call-tool",
            os.fspath(manifest),
            "echo",
            os.fspath(arguments_path),
        )

        self.assertEqual(first.returncode, 3, first.stderr)
        self.assertEqual(required["status"], "mcp_input_required")
        self.assertNotIn("requestState", json.dumps(required))
        continuation = Path(required["continuation_file"])
        self.assertEqual(continuation.stat().st_mode & 0o777, 0o600)
        responses = self.write_input_responses()

        second, completed = self.run_client(
            "call-tool",
            os.fspath(manifest),
            "echo",
            os.fspath(arguments_path),
            "--continuation",
            os.fspath(continuation),
            "--input-responses",
            os.fspath(responses),
        )

        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(completed["status"], "executed")
        self.assertEqual(
            completed["result"]["structuredContent"]["inputResponses"]["email"]["action"],
            "accept",
        )
        self.assertFalse(continuation.exists())
        call_ids = [
            message["id"]
            for message in self.wire_messages()
            if message.get("method") == "tools/call"
        ]
        self.assertEqual(len(call_ids), 2)
        self.assertNotEqual(call_ids[0], call_ids[1])

    def test_input_continuation_can_cross_runner_exchange_directories(self) -> None:
        manifest = self.write_manifest("modern_only", "input_required")
        first_stage = self.directory / "first-stage"
        first_output = first_stage / ".mcp-output"
        first_output.mkdir(parents=True)
        arguments = first_stage / "arguments.json"
        arguments.write_text('{"text":"hello"}', encoding="utf-8")
        os.chmod(arguments, 0o600)
        with mock.patch.dict(
            os.environ,
            {
                "LINUX_AGENT_MCP_STATE_DIR": os.fspath(first_output),
                "LINUX_AGENT_MCP_FLOW_ID": "managed-flow",
            },
        ):
            first, required = self.run_client(
                "call-tool",
                os.fspath(manifest),
                "echo",
                os.fspath(arguments),
            )
        self.assertEqual(3, first.returncode, first.stderr)

        state_root = self.directory / ".mcp-state"
        state_root.mkdir()
        continuation = Path(required["continuation_file"])
        preserved = state_root / "continuation.json"
        continuation.rename(preserved)
        second_stage = self.directory / "second-stage"
        second_output = second_stage / ".mcp-output"
        second_output.mkdir(parents=True)
        second_arguments = second_stage / "arguments.json"
        second_arguments.write_text('{"text":"hello"}', encoding="utf-8")
        os.chmod(second_arguments, 0o600)
        responses = second_stage / "responses.json"
        responses.write_text(
            json.dumps(
                {
                    "email": {
                        "action": "accept",
                        "content": {"email": "managed@example.test"},
                    }
                }
            ),
            encoding="utf-8",
        )
        os.chmod(responses, 0o600)
        with mock.patch.dict(
            os.environ,
            {
                "LINUX_AGENT_EXECUTION_ISOLATION": "runner_uid",
                "LINUX_AGENT_MCP_STATE_DIR": os.fspath(second_output),
                "LINUX_AGENT_MCP_CONTINUATION_ROOT": os.fspath(state_root),
                "LINUX_AGENT_MCP_FLOW_ID": "managed-flow",
            },
        ):
            second, completed = self.run_client(
                "call-tool",
                os.fspath(manifest),
                "echo",
                os.fspath(second_arguments),
                "--continuation",
                os.fspath(preserved),
                "--input-responses",
                os.fspath(responses),
            )
        self.assertEqual(0, second.returncode, second.stderr)
        self.assertEqual("executed", completed["status"])
        self.assertFalse(preserved.exists())

    def test_input_continuation_is_bound_to_flow_and_expiry(self) -> None:
        manifest = self.write_manifest("modern_only", "input_required")
        arguments = self.write_arguments()
        responses = self.write_input_responses()
        with mock.patch.dict(os.environ, {"LINUX_AGENT_MCP_FLOW_ID": "flow-one"}):
            first, required = self.run_client(
                "call-tool", os.fspath(manifest), "echo", os.fspath(arguments)
            )
        self.assertEqual(3, first.returncode)
        continuation = Path(required["continuation_file"])
        with mock.patch.dict(os.environ, {"LINUX_AGENT_MCP_FLOW_ID": "flow-two"}):
            mismatched, mismatch_payload = self.run_client(
                "call-tool",
                os.fspath(manifest),
                "echo",
                os.fspath(arguments),
                "--continuation",
                os.fspath(continuation),
                "--input-responses",
                os.fspath(responses),
            )
        self.assertEqual(1, mismatched.returncode)
        self.assertEqual("mcp_input_invalid", mismatch_payload["status"])
        self.assertFalse(mismatch_payload["fallback_used"])
        state = json.loads(continuation.read_text(encoding="utf-8"))
        state["expires_at"] = 0
        continuation.write_text(json.dumps(state), encoding="utf-8")
        os.chmod(continuation, 0o600)
        with mock.patch.dict(os.environ, {"LINUX_AGENT_MCP_FLOW_ID": "flow-one"}):
            expired, expired_payload = self.run_client(
                "call-tool",
                os.fspath(manifest),
                "echo",
                os.fspath(arguments),
                "--continuation",
                os.fspath(continuation),
                "--input-responses",
                os.fspath(responses),
            )
        self.assertEqual(1, expired.returncode)
        self.assertEqual("mcp_input_expired", expired_payload["status"])
        self.assertFalse(expired_payload["fallback_used"])

    def test_input_rounds_and_item_count_are_hard_limited(self) -> None:
        manifest = self.write_manifest("modern_only", "input_required_always")
        arguments = self.write_arguments()
        responses = self.write_input_responses()
        completed, payload = self.run_client(
            "call-tool", os.fspath(manifest), "echo", os.fspath(arguments)
        )
        self.assertEqual(3, completed.returncode)
        self.assertEqual(1, payload["round"])
        continuation = Path(payload["continuation_file"])
        for expected_round in (2, 3):
            completed, payload = self.run_client(
                "call-tool",
                os.fspath(manifest),
                "echo",
                os.fspath(arguments),
                "--continuation",
                os.fspath(continuation),
                "--input-responses",
                os.fspath(responses),
            )
            self.assertEqual(3, completed.returncode)
            self.assertEqual(expected_round, payload["round"])
            continuation = Path(payload["continuation_file"])
        exceeded, exceeded_payload = self.run_client(
            "call-tool",
            os.fspath(manifest),
            "echo",
            os.fspath(arguments),
            "--continuation",
            os.fspath(continuation),
            "--input-responses",
            os.fspath(responses),
        )
        self.assertEqual(1, exceeded.returncode)
        self.assertEqual("mcp_input_rounds_exceeded", exceeded_payload["status"])
        self.assertFalse(exceeded_payload["fallback_used"])
        continuation.unlink(missing_ok=True)

        oversized_manifest = self.write_manifest("modern_only", "input_items_exceeded")
        limited, limited_payload = self.run_client(
            "call-tool", os.fspath(oversized_manifest), "echo", os.fspath(arguments)
        )
        self.assertEqual(1, limited.returncode)
        self.assertEqual("mcp_resource_limit", limited_payload["status"])
        self.assertFalse(limited_payload["fallback_used"])

    def test_input_bytes_are_cumulative_across_rounds(self) -> None:
        manifest = self.write_manifest("modern_only", "input_required_always")
        arguments = self.write_arguments()
        first, required = self.run_client(
            "call-tool", os.fspath(manifest), "echo", os.fspath(arguments)
        )
        self.assertEqual(3, first.returncode)

        large_response = self.directory / "large-response.json"
        large_response.write_text(
            json.dumps(
                {
                    "email": {
                        "action": "accept",
                        "content": {"email": "x" * 35_000},
                    }
                }
            ),
            encoding="utf-8",
        )
        os.chmod(large_response, 0o600)
        second, required_again = self.run_client(
            "call-tool",
            os.fspath(manifest),
            "echo",
            os.fspath(arguments),
            "--continuation",
            required["continuation_file"],
            "--input-responses",
            os.fspath(large_response),
        )
        self.assertEqual(3, second.returncode, second.stderr)

        third, limited = self.run_client(
            "call-tool",
            os.fspath(manifest),
            "echo",
            os.fspath(arguments),
            "--continuation",
            required_again["continuation_file"],
            "--input-responses",
            os.fspath(large_response),
        )
        self.assertEqual(1, third.returncode)
        self.assertEqual("mcp_resource_limit", limited["status"])
        call_count = sum(
            message.get("method") == "tools/call"
            for message in self.wire_messages()
        )
        self.assertEqual(2, call_count)

    def test_invalid_manifest_is_rejected_before_server_start(self) -> None:
        manifest = self.write_manifest("modern_only")
        payload = json.loads(manifest.read_text(encoding="utf-8"))
        payload["unexpected"] = True
        manifest.write_text(json.dumps(payload), encoding="utf-8")

        completed, result = self.run_client("list-tools", os.fspath(manifest))

        self.assertEqual(completed.returncode, 1)
        self.assertEqual(result["status"], "invalid_manifest")
        self.assertFalse(self.log_path.exists())

    def test_streamable_http_uses_modern_headers_without_resume_headers(self) -> None:
        server, records = self.start_http_server()
        manifest = self.write_http_manifest(server)

        completed, payload = self.run_client("list-tools", os.fspath(manifest))

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(payload["protocol_version"], "2026-07-28")
        self.assertEqual(len(records), 2)
        for record in records:
            headers = record["headers"]
            self.assertEqual(headers["mcp-protocol-version"], "2026-07-28")
            self.assertNotIn("mcp-session-id", headers)
            self.assertNotIn("last-event-id", headers)
            self.assertEqual(headers["x-test-header"], "present")
        self.assertEqual(records[0]["headers"]["mcp-method"], "server/discover")
        self.assertEqual(records[1]["headers"]["mcp-method"], "tools/list")

    def test_streamable_http_derives_reviewed_tool_parameter_header(self) -> None:
        server, records = self.start_http_server("derived_header")
        manifest = self.write_http_manifest(server)
        arguments = self.write_arguments()

        completed, payload = self.run_client(
            "call-tool",
            os.fspath(manifest),
            "echo",
            os.fspath(arguments),
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(payload["status"], "executed")
        self.assertEqual(len(records), 3)
        call_headers = records[-1]["headers"]
        self.assertEqual(call_headers["mcp-param-region"], "hello")
        self.assertEqual(call_headers["mcp-name"], "echo")

    def test_modern_catalog_cache_mode_defaults_to_use_and_refreshes(self) -> None:
        class Model:
            def __init__(self, payload: dict[str, object]) -> None:
                self.payload = payload

            def model_dump(self, **_options: object) -> dict[str, object]:
                return self.payload

        class FakeClient:
            protocol_version = "2026-07-28"
            server_info = Model({"name": "cache-test", "version": "1"})
            server_capabilities = Model({"tools": {}})

            def __init__(self) -> None:
                self.cache_modes: list[str] = []

            async def list_tools(
                self, *, cursor: str | None, cache_mode: str
            ) -> Model:
                self.cache_modes.append(cache_mode)
                return Model(
                    {
                        "tools": [],
                        "ttlMs": 1000,
                        "cacheScope": "private",
                        "resultType": "complete",
                    }
                )

            async def __aexit__(self, *_arguments: object) -> None:
                return None

        regular = FakeClient()
        refreshed = FakeClient()
        with mock.patch.object(
            mcp_client, "connect_modern", mock.AsyncMock(return_value=regular)
        ):
            asyncio.run(mcp_client.modern_list({}, "manifest", None))
        with mock.patch.object(
            mcp_client, "connect_modern", mock.AsyncMock(return_value=refreshed)
        ):
            asyncio.run(
                mcp_client.modern_list({}, "manifest", None, refresh=True)
            )

        self.assertEqual(regular.cache_modes, ["use"])
        self.assertEqual(refreshed.cache_modes, ["refresh"])

    def test_streamable_http_redirect_does_not_fallback(self) -> None:
        server, records = self.start_http_server("redirect")
        manifest = self.write_http_manifest(server, "modern_then_legacy")

        completed, payload = self.run_client("list-tools", os.fspath(manifest))

        self.assertEqual(completed.returncode, 1)
        self.assertFalse(payload["fallback_used"])
        self.assertEqual(len(records), 1)

    def test_streamable_http_response_limit_is_fail_closed(self) -> None:
        server, records = self.start_http_server("oversized")
        manifest = self.write_http_manifest(server, "modern_then_legacy")

        completed, payload = self.run_client("list-tools", os.fspath(manifest))

        self.assertEqual(completed.returncode, 1)
        self.assertEqual(payload["status"], "mcp_client_error")
        self.assertFalse(payload["fallback_used"])
        self.assertEqual(len(records), 1)

    def test_streamable_http_request_limit_rejects_before_call_is_sent(self) -> None:
        server, records = self.start_http_server()
        manifest = self.write_http_manifest(server, "modern_only")
        arguments = self.directory / "oversized-request.json"
        arguments.write_text(
            json.dumps(
                {"text": "x" * (mcp_client.MAX_ARGUMENT_BYTES - 32)},
                separators=(",", ":"),
            ),
            encoding="utf-8",
        )
        self.assertLessEqual(arguments.stat().st_size, mcp_client.MAX_ARGUMENT_BYTES)

        completed, payload = self.run_client(
            "call-tool",
            os.fspath(manifest),
            "echo",
            os.fspath(arguments),
        )

        self.assertEqual(completed.returncode, 1)
        self.assertEqual(payload["status"], "mcp_resource_limit")
        self.assertTrue(payload["outcome_known"])
        self.assertFalse(payload["fallback_used"])
        self.assertEqual(len(records), 2)

    def test_tool_schema_preserves_external_ref_without_resolving_it(self) -> None:
        schema = {
            "$ref": "https://schema.example.test/tool.json",
            "$defs": {"local": {"type": "string"}},
        }

        mcp_client.inspect_schema(schema)

        self.assertEqual(schema["$ref"], "https://schema.example.test/tool.json")

    def test_mrtr_schema_external_ref_fails_without_network_access(self) -> None:
        server, records = self.start_http_server()
        external_ref = f"http://127.0.0.1:{server.server_port}/schema.json"
        runtime = mcp_client.mcp_runtime.runtime_status(ensure=True)
        script = """
import sys
import mcp_client

requests = {
    "form": {
        "method": "elicitation/create",
        "params": {
            "mode": "form",
            "requestedSchema": {"$ref": sys.argv[1]},
        },
    }
}
responses = {"form": {"action": "accept", "content": {}}}
try:
    mcp_client.validate_input_responses(requests, responses)
except mcp_client.McpAdapterError as exc:
    if "does not match its schema" in str(exc):
        raise SystemExit(0)
    raise
raise SystemExit("external schema unexpectedly validated")
"""
        environment = dict(os.environ)
        environment["PYTHONPATH"] = os.fspath(ROOT / "lib")
        completed = subprocess.run(
            [str(runtime["python_path"]), "-c", script, external_ref],
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=15,
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(records, [])

    def test_runner_transfers_static_credentials_only_in_sealed_fd(self) -> None:
        server, records = self.start_http_server("echo_authorization")
        data_dir = self.directory / "data"
        mcp_dir = self.directory / "mcp"
        runner_tmp = data_dir / "runner-tmp"
        credential_dir = data_dir / "mcp" / "credentials"
        user_skills = data_dir / "skills"
        server_dir = mcp_dir / "fake-http"
        for directory in (runner_tmp, credential_dir, user_skills, server_dir):
            directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        secret = "runner-only-secret"
        profile_id = "static-auth"
        profile_path = credential_dir / f"{profile_id}.json"
        profile_path.write_text(
            json.dumps(
                {
                    "profile_version": 1,
                    "id": profile_id,
                    "type": "static_headers",
                    "server_id": "fake-http",
                    "server_url": f"http://127.0.0.1:{server.server_port}/mcp",
                    "headers": {"Authorization": f"Bearer {secret}"},
                }
            ),
            encoding="utf-8",
        )
        os.chmod(profile_path, 0o600)
        manifest = server_dir / "mcp.json"
        manifest.write_text(
            json.dumps(
                {
                    "manifest_version": 2,
                    "id": "fake-http",
                    "transport": "streamable_http",
                    "url": f"http://127.0.0.1:{server.server_port}/mcp",
                    "credential_profile": profile_id,
                    "protocol": {"mode": "modern_only"},
                }
            ),
            encoding="utf-8",
        )
        arguments_path = runner_tmp / "arguments.json"
        arguments_path.write_text('{"text":"secure"}', encoding="utf-8")
        os.chmod(arguments_path, 0o600)
        params = {
            "kind": "mcp",
            "argv": [
                "python3",
                os.fspath(CLIENT),
                "call-tool",
                os.fspath(manifest),
                "echo",
                os.fspath(arguments_path),
            ],
            "timeout_sec": 30,
            "max_output_bytes": 1_048_576,
        }
        environment = {
            "LINUX_AGENT_ROOT": os.fspath(ROOT),
            "LINUX_AGENT_DATA_DIR": os.fspath(data_dir),
            "LINUX_AGENT_MCP_DIR": os.fspath(mcp_dir),
            "LINUX_AGENT_TMP_ROOT": os.fspath(runner_tmp),
            "LINUX_AGENT_USER_SKILLS_DIR": os.fspath(user_skills),
        }

        with mock.patch.dict(os.environ, environment, clear=False):
            kind, command, timeout, output_limit, overrides = runner.validate_execution(params)
            transfer_metadata = json.dumps(overrides, sort_keys=True)
            self.assertNotIn(secret, json.dumps(params, sort_keys=True))
            self.assertNotIn(secret, json.dumps(command))
            self.assertNotIn(secret, transfer_metadata)
            result = runner.execute(command, timeout, output_limit, overrides)

        self.assertEqual(kind, "mcp")
        self.assertTrue(result["ok"], result)
        payload = json.loads(result["stdout"])
        self.assertEqual(payload["status"], "executed")
        self.assertNotIn(secret, result["stdout"])
        self.assertNotIn(secret, result["stderr"])
        self.assertEqual(
            "[REDACTED]",
            payload["output"]["structuredContent"]["echoed"],
        )
        self.assertEqual(
            "[REDACTED]",
            payload["output"]["structuredContent"]["bare"],
        )
        self.assertEqual(len(records), 3)
        self.assertTrue(
            all(record["headers"].get("authorization") == f"Bearer {secret}" for record in records)
        )

    def test_runner_lists_protected_tools_and_shell_catalog_keeps_them_available(
        self,
    ) -> None:
        server, records = self.start_http_server()
        data_dir = self.directory / "protected-data"
        mcp_dir = self.directory / "protected-mcp"
        runner_tmp = data_dir / "runner-tmp"
        credential_dir = data_dir / "mcp" / "credentials"
        user_skills = data_dir / "skills"
        server_dir = mcp_dir / "fake-http"
        for directory in (runner_tmp, credential_dir, user_skills, server_dir):
            directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        secret = "protected-catalog-secret"
        profile_id = "protected-catalog"
        profile_path = credential_dir / f"{profile_id}.json"
        profile_path.write_text(
            json.dumps(
                {
                    "profile_version": 1,
                    "id": profile_id,
                    "type": "static_headers",
                    "server_id": "fake-http",
                    "server_url": f"http://127.0.0.1:{server.server_port}/mcp",
                    "headers": {"Authorization": f"Bearer {secret}"},
                }
            ),
            encoding="utf-8",
        )
        os.chmod(profile_path, 0o600)
        manifest = server_dir / "mcp.json"
        manifest.write_text(
            json.dumps(
                {
                    "manifest_version": 2,
                    "id": "fake-http",
                    "transport": "streamable_http",
                    "url": f"http://127.0.0.1:{server.server_port}/mcp",
                    "credential_profile": profile_id,
                    "protocol": {"mode": "modern_only"},
                }
            ),
            encoding="utf-8",
        )
        environment = {
            "LINUX_AGENT_ROOT": os.fspath(ROOT),
            "LINUX_AGENT_DATA_DIR": os.fspath(data_dir),
            "LINUX_AGENT_MCP_DIR": os.fspath(mcp_dir),
            "LINUX_AGENT_TMP_ROOT": os.fspath(runner_tmp),
            "LINUX_AGENT_USER_SKILLS_DIR": os.fspath(user_skills),
        }
        params = {
            "kind": "mcp",
            "argv": [
                "python3",
                os.fspath(CLIENT),
                "list-tools",
                os.fspath(manifest),
                "--refresh",
            ],
            "timeout_sec": 30,
            "max_output_bytes": 1_048_576,
        }

        with mock.patch.dict(os.environ, environment, clear=False):
            kind, command, timeout, output_limit, overrides = runner.validate_execution(
                params
            )
            result = runner.execute(command, timeout, output_limit, overrides)

        self.assertEqual("mcp", kind)
        self.assertTrue(result["ok"], result)
        listing = json.loads(str(result["stdout"]))
        self.assertEqual(["echo"], [tool["name"] for tool in listing["tools"]])
        serialized = json.dumps(
            {"params": params, "command": command, "overrides": overrides}
        )
        self.assertNotIn(secret, serialized)
        self.assertNotIn(secret, str(result["stdout"]))
        self.assertNotIn(secret, str(result["stderr"]))

        shell = f"""
set -euo pipefail
source {ROOT / 'lib' / 'common.sh'}
source {ROOT / 'lib' / 'policy.sh'}
source {ROOT / 'lib' / 'mcp.sh'}
LINUX_AGENT_ROOT=$1
LINUX_AGENT_DATA_DIR=$2
LINUX_AGENT_MCP_DIR=$3
LINUX_AGENT_TMP_ROOT=$4
LINUX_AGENT_TMP_DIR=$4
LINUX_AGENT_USER_SKILLS_DIR=$5
LINUX_AGENT_BUILTIN_SKILLS_DIR=$1/skills
LINUX_AGENT_BUILTIN_POLICIES_DIR=$1/policies
LINUX_AGENT_USER_POLICIES_DIR=$2/policies
LINUX_AGENT_MANAGED_MODE=0
linux_agent_mcp_tool_catalog
"""
        completed = subprocess.run(
            [
                "bash",
                "-c",
                shell,
                "mcp-catalog-test",
                os.fspath(ROOT),
                os.fspath(data_dir),
                os.fspath(mcp_dir),
                os.fspath(runner_tmp),
                os.fspath(user_skills),
            ],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertEqual(0, completed.returncode, completed.stderr)
        catalog = json.loads(completed.stdout)
        self.assertEqual(
            ["fake-http/echo"],
            [tool["ref"] for tool in catalog["tools"]],
            catalog,
        )
        self.assertNotIn(secret, completed.stdout)
        self.assertNotIn(secret, completed.stderr)
        self.assertTrue(
            all(
                record.get("headers", {}).get("authorization")
                == f"Bearer {secret}"
                for record in records
                if "headers" in record
            )
        )

    def test_static_credentials_allow_auth_but_reject_trace_headers(self) -> None:
        profile = {
            "profile_version": 1,
            "id": "static-test",
            "type": "static_headers",
            "server_id": "fake-http",
            "server_url": "https://example.test/mcp",
            "headers": {"Authorization": "Bearer local-test"},
        }

        validated = mcp_credentials.validate_profile(profile, "static-test")
        self.assertEqual(validated["headers"]["Authorization"], "Bearer local-test")
        profile["headers"] = {"traceparent": "00-test-test-01"}
        with self.assertRaisesRegex(
            mcp_credentials.McpCredentialError,
            "credential profile is invalid",
        ):
            mcp_credentials.validate_profile(profile, "static-test")

    def oauth_authorization_profile(
        self,
        server: ThreadingHTTPServer,
        *,
        issuer_path: str = "",
        allow_dynamic_registration: bool = False,
        client_metadata_url: str | None = "https://client.example.test/mcp.json",
    ) -> dict[str, object]:
        server_url = f"http://127.0.0.1:{server.server_port}/mcp"
        profile: dict[str, object] = {
            "profile_version": 1,
            "id": f"oauth-{len(list(self.directory.iterdir()))}",
            "type": "oauth_authorization_code",
            "server_id": "fake-oauth",
            "server_url": server_url,
            "authorization_server_issuer": (
                f"http://127.0.0.1:{server.server_port}{issuer_path}"
            ),
            "client_metadata": {
                "redirect_uris": ["http://127.0.0.1:8766/callback"],
                "application_type": "native",
                "grant_types": ["authorization_code", "refresh_token"],
                "response_types": ["code"],
                "token_endpoint_auth_method": "none",
            },
            "allow_dynamic_registration": allow_dynamic_registration,
        }
        if client_metadata_url is not None:
            profile["client_metadata_url"] = client_metadata_url
        return profile

    def test_oauth_cimd_is_preferred_and_never_attempts_dcr(self) -> None:
        server, records = self.start_oauth_server(cimd_supported=True)
        profile = self.oauth_authorization_profile(server)

        payload, overrides, command = self.run_oauth_profile(server, profile)

        self.assertEqual("mcp_authorization_required", payload["status"], payload)
        self.assertFalse(payload["fallback_used"])
        self.assertNotIn("/register", [record["path"] for record in records])
        serialized = json.dumps({"overrides": overrides, "command": command})
        self.assertNotIn("client.example.test", serialized)

    def test_oauth_dcr_is_forbidden_unless_explicitly_enabled(self) -> None:
        server, records = self.start_oauth_server(cimd_supported=False)
        forbidden_profile = self.oauth_authorization_profile(server)

        forbidden, _overrides, _command = self.run_oauth_profile(
            server, forbidden_profile
        )

        self.assertEqual(
            "mcp_oauth_registration_forbidden", forbidden["status"], forbidden
        )
        self.assertFalse(forbidden["fallback_used"])
        self.assertNotIn("/register", [record["path"] for record in records])

        allowed_profile = self.oauth_authorization_profile(
            server,
            allow_dynamic_registration=True,
            client_metadata_url=None,
        )
        allowed, _overrides, _command = self.run_oauth_profile(server, allowed_profile)

        self.assertEqual("mcp_authorization_required", allowed["status"], allowed)
        self.assertEqual(
            1, len([record for record in records if record["path"] == "/register"])
        )
        persisted = json.loads(
            (
                self.directory
                / f"data-{allowed_profile['id']}"
                / "mcp"
                / "credentials"
                / f"{allowed_profile['id']}.json"
            ).read_text(encoding="utf-8")
        )
        self.assertEqual("dcr-client", persisted["client_info"]["client_id"])
        self.assertEqual(
            allowed_profile["authorization_server_issuer"],
            persisted["client_info"]["issuer"],
        )
        self.assertEqual(0o600, os.stat(
            self.directory
            / f"data-{allowed_profile['id']}"
            / "mcp"
            / "credentials"
            / f"{allowed_profile['id']}.json"
        ).st_mode & 0o777)

    def test_client_credentials_tokens_persist_and_are_reused_without_reissue(
        self,
    ) -> None:
        server, records = self.start_oauth_server(
            cimd_supported=False,
            issue_client_credentials=True,
        )
        secret = "client-secret-never-in-runner-contract"
        profile: dict[str, object] = {
            "profile_version": 1,
            "id": "persisted-client-credentials",
            "type": "oauth_client_credentials",
            "server_id": "fake-oauth",
            "server_url": f"http://127.0.0.1:{server.server_port}/mcp",
            "authorization_server_issuer": (
                f"http://127.0.0.1:{server.server_port}"
            ),
            "client_id": "machine-client",
            "client_secret": secret,
            "application_type": "web",
            "token_endpoint_auth_method": "client_secret_basic",
            "scope": "read",
        }

        first, first_overrides, first_command = self.run_oauth_profile(
            server, profile
        )
        second, second_overrides, second_command = self.run_oauth_profile(
            server, profile
        )

        self.assertEqual("executed", first["status"], first)
        self.assertEqual("executed", second["status"], second)
        token_requests = [record for record in records if record["path"] == "/token"]
        self.assertEqual(1, len(token_requests), records)
        profile_path = (
            self.directory
            / f"data-{profile['id']}"
            / "mcp"
            / "credentials"
            / f"{profile['id']}.json"
        )
        persisted = json.loads(profile_path.read_text(encoding="utf-8"))
        self.assertEqual(
            "persisted-access-token", persisted["tokens"]["access_token"]
        )
        self.assertEqual(
            profile["authorization_server_issuer"], persisted["token_issuer"]
        )
        self.assertEqual(0o600, os.stat(profile_path).st_mode & 0o777)
        public_material = json.dumps(
            {
                "first": first,
                "second": second,
                "first_overrides": first_overrides,
                "second_overrides": second_overrides,
                "first_command": first_command,
                "second_command": second_command,
            }
        )
        self.assertNotIn(secret, public_material)
        self.assertNotIn("persisted-access-token", public_material)
        self.assertEqual(
            "Bearer [REDACTED]",
            first["output"]["structuredContent"]["echoed"],
        )
        self.assertEqual(
            "[REDACTED]",
            first["output"]["structuredContent"]["bare"],
        )

    def test_oauth_update_memfd_is_finalized_and_concurrent_profile_change_wins(
        self,
    ) -> None:
        descriptor = mcp_credentials.oauth_update_memfd()
        update = {
            "version": 1,
            "profile_id": "concurrent-oauth",
            "authorization_server_issuer": "https://issuer.example.test",
            "tokens": {"access_token": "new-token", "token_type": "Bearer"},
        }
        try:
            mcp_credentials.write_oauth_update(descriptor, update)
            self.assertEqual(update, mcp_credentials.read_oauth_update(descriptor))
            with self.assertRaises(OSError):
                os.pwrite(descriptor, b"x", 8)
        finally:
            os.close(descriptor)

        profile_path = self.directory / "concurrent-oauth.json"
        baseline_profile = {
            "profile_version": 1,
            "id": "concurrent-oauth",
            "type": "oauth_client_credentials",
            "server_id": "fake-oauth",
            "server_url": "https://mcp.example.test/mcp",
            "authorization_server_issuer": "https://issuer.example.test",
            "client_id": "machine-client",
            "client_secret": "profile-secret",
            "application_type": "web",
            "token_endpoint_auth_method": "client_secret_basic",
            "scope": "read",
        }
        profile_path.write_text(json.dumps(baseline_profile), encoding="utf-8")
        os.chmod(profile_path, 0o600)
        baseline, baseline_sha256 = mcp_credentials.load_profile_snapshot(
            profile_path, "concurrent-oauth"
        )
        changed_profile = dict(baseline_profile)
        changed_profile["scope"] = "read write"
        profile_path.write_text(json.dumps(changed_profile), encoding="utf-8")
        os.chmod(profile_path, 0o600)

        with self.assertRaisesRegex(
            mcp_credentials.McpCredentialError,
            "changed during OAuth execution",
        ):
            mcp_credentials.persist_oauth_update(
                profile_path,
                "concurrent-oauth",
                baseline,
                update,
                baseline_sha256,
            )
        self.assertEqual(
            changed_profile,
            json.loads(profile_path.read_text(encoding="utf-8")),
        )

    def test_oauth_issuer_mismatch_fails_before_registration_or_token(self) -> None:
        server, records = self.start_oauth_server(
            cimd_supported=False, issuer_path="/unexpected"
        )
        profile = self.oauth_authorization_profile(
            server,
            issuer_path="/expected",
            allow_dynamic_registration=True,
            client_metadata_url=None,
        )
        secret = "must-never-leave-profile"
        profile["tokens"] = {"access_token": secret}
        profile["token_issuer"] = profile["authorization_server_issuer"]

        payload, overrides, command = self.run_oauth_profile(server, profile)

        self.assertEqual("mcp_oauth_issuer_mismatch", payload["status"], payload)
        self.assertFalse(payload["fallback_used"])
        self.assertNotIn(secret, json.dumps(payload))
        self.assertNotIn(secret, json.dumps(overrides))
        self.assertNotIn(secret, json.dumps(command))
        self.assertFalse(
            any(record["path"] in {"/register", "/token"} for record in records)
        )

    def test_oauth_profile_binding_redirects_and_stale_issuer_state(self) -> None:
        server, _records = self.start_oauth_server(cimd_supported=False)
        profile = self.oauth_authorization_profile(
            server,
            allow_dynamic_registration=True,
            client_metadata_url=None,
        )
        profile.update(
            {
                "client_info": {
                    "client_id": "old-client",
                    "issuer": "https://old-issuer.example.test",
                    "redirect_uris": ["http://127.0.0.1:8766/callback"],
                },
                "tokens": {"access_token": "old-token"},
                "token_issuer": "https://old-issuer.example.test",
            }
        )

        validated = mcp_credentials.validate_profile(profile, str(profile["id"]))

        self.assertNotIn("client_info", validated)
        self.assertNotIn("tokens", validated)
        self.assertNotIn("token_issuer", validated)
        with self.assertRaisesRegex(
            mcp_credentials.McpCredentialError, "not bound to this MCP server"
        ):
            mcp_credentials.validate_binding(
                validated, "other-server", str(profile["server_url"])
            )

        bad_redirect = dict(profile)
        bad_redirect.pop("client_info")
        bad_redirect.pop("tokens")
        bad_redirect.pop("token_issuer")
        bad_redirect["client_metadata"] = {
            "redirect_uris": ["http://127.0.0.1:8766/callback"],
            "application_type": "web",
        }
        with self.assertRaisesRegex(
            mcp_credentials.McpCredentialError, "require HTTPS redirect_uris"
        ):
            mcp_credentials.validate_profile(bad_redirect, str(profile["id"]))

    def test_client_credentials_secret_never_reaches_mismatched_issuer(self) -> None:
        server, records = self.start_oauth_server(
            cimd_supported=False, issuer_path="/advertised"
        )
        secret = "client-secret-must-stay-local"
        profile: dict[str, object] = {
            "profile_version": 1,
            "id": "client-credentials",
            "type": "oauth_client_credentials",
            "server_id": "fake-oauth",
            "server_url": f"http://127.0.0.1:{server.server_port}/mcp",
            "authorization_server_issuer": (
                f"http://127.0.0.1:{server.server_port}/expected"
            ),
            "client_id": "machine-client",
            "client_secret": secret,
            "application_type": "web",
            "token_endpoint_auth_method": "client_secret_basic",
            "scope": "read",
        }

        payload, overrides, command = self.run_oauth_profile(server, profile)

        self.assertEqual("mcp_oauth_issuer_mismatch", payload["status"], payload)
        self.assertNotIn(secret, json.dumps(payload))
        self.assertNotIn(secret, json.dumps(overrides))
        self.assertNotIn(secret, json.dumps(command))
        self.assertNotIn(secret, json.dumps(records))
        self.assertFalse(any(record["path"] == "/token" for record in records))

    def test_sdk_rfc9207_issuer_validation_and_error_redaction(self) -> None:
        runtime = json.loads(
            subprocess.run(
                [sys.executable, os.fspath(ROOT / "lib" / "mcp_runtime.py"), "status"],
                cwd=ROOT,
                check=True,
                capture_output=True,
                text=True,
            ).stdout
        )
        probe = subprocess.run(
            [
                runtime["python_path"],
                "-c",
                (
                    "from mcp.client.auth.utils import validate_authorization_response_iss;"
                    "from mcp.shared.auth import OAuthMetadata;"
                    "m=OAuthMetadata(issuer='https://issuer.example.test',"
                    "authorization_endpoint='https://issuer.example.test/authorize',"
                    "token_endpoint='https://issuer.example.test/token',"
                    "authorization_response_iss_parameter_supported=True);"
                    "validate_authorization_response_iss('https://other.example.test',m)"
                ),
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(0, probe.returncode)
        self.assertIn("iss mismatch", probe.stderr)
        self.assertNotIn(
            "super-secret",
            mcp_client.clean_error(
                "client_secret='super-secret' access_token=token-value"
            ),
        )


if __name__ == "__main__":
    unittest.main()
