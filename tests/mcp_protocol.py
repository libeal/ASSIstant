#!/usr/bin/env python3

import importlib.util
import io
import queue
import sys
import threading
import time
import types
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("mcp_client", ROOT / "lib" / "mcp_client.py")
assert SPEC and SPEC.loader
mcp_client = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(mcp_client)


class FakeHttpResponse(io.BytesIO):
    def __init__(self, body, headers=None):
        super().__init__(body)
        self.headers = headers or {}

    def __enter__(self):
        return self

    def __exit__(self, _exc_type, _exc_value, _traceback):
        self.close()


class FakeClient(mcp_client.BaseClient):
    def __init__(self, protocol_version="2025-11-25"):
        super().__init__({}, "fake.json")
        self.protocol_version = protocol_version
        self.sent = []

    def send(self, message):
        self.sent.append(message)

    def read_response(self, message_id):
        method = self.sent[-1]["method"]
        if method == "initialize":
            return {
                "jsonrpc": "2.0",
                "id": message_id,
                "result": {
                    "protocolVersion": self.protocol_version,
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "fake", "version": "1.0"},
                },
            }
        return {"jsonrpc": "2.0", "id": message_id, "result": {"tools": []}}


class McpLifecycleTests(unittest.TestCase):
    def test_stdio_close_terminates_descendants_holding_stderr(self):
        client = mcp_client.StdioClient(
            {
                "transport": "stdio",
                "command": sys.executable,
                "args": [
                    "-c",
                    (
                        "import subprocess, sys; "
                        "subprocess.Popen([sys.executable, '-c', "
                        "'import time; time.sleep(30)']); sys.exit(0)"
                    ),
                ],
            },
            "fake.json",
        )
        try:
            deadline = time.monotonic() + 2
            while client.process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.01)
            started = time.monotonic()
            client.close()
            self.assertLess(time.monotonic() - started, 2)
            self.assertFalse(client.stderr_thread.is_alive())
        finally:
            client.close()

    def test_legacy_sse_close_interrupts_reader_without_cross_thread_close(self):
        client = mcp_client.LegacySseClient.__new__(mcp_client.LegacySseClient)
        client.stop_event = threading.Event()
        release = threading.Event()

        class InterruptSocket:
            @staticmethod
            def shutdown(_how):
                release.set()

        client.stream_response = types.SimpleNamespace(
            fp=types.SimpleNamespace(
                raw=types.SimpleNamespace(_sock=InterruptSocket()),
            )
        )
        client.stream_thread = threading.Thread(target=release.wait, daemon=True)
        client.stream_thread.start()
        client.close()
        self.assertFalse(client.stream_thread.is_alive())

    def test_rejects_server_protocol_version_the_client_does_not_support(self):
        client = FakeClient("2099-01-01")

        with self.assertRaisesRegex(mcp_client.McpError, "unsupported protocol version"):
            client.initialize()
        self.assertEqual(client.sent[-1]["method"], "initialize")

    def test_finite_http_body_is_hard_limited(self):
        self.assertEqual(mcp_client.read_limited_body(io.BytesIO(b"abcd"), 4), b"abcd")
        with self.assertRaisesRegex(mcp_client.McpError, "exceeds 4 bytes"):
            mcp_client.read_limited_body(io.BytesIO(b"abcde"), 4)

    def test_streamable_http_request_uses_response_limit(self):
        client = mcp_client.StreamableHttpClient(
            {"transport": "streamable_http", "url": "https://mcp.example/rpc"},
            "fake.json",
        )
        response = FakeHttpResponse(b"x" * (mcp_client.MAX_HTTP_RESPONSE_BYTES + 1))

        with mock.patch.object(mcp_client, "open_http_request", return_value=response):
            with self.assertRaisesRegex(mcp_client.McpError, "HTTP response exceeds"):
                client.request("tools/list")

    def test_legacy_sse_post_uses_response_limit(self):
        client = mcp_client.LegacySseClient.__new__(mcp_client.LegacySseClient)
        client.manifest = {}
        client.message_url = "https://mcp.example/messages"
        client.timeout = 1
        response = FakeHttpResponse(b"x" * (mcp_client.MAX_HTTP_RESPONSE_BYTES + 1))

        with mock.patch.object(mcp_client, "open_http_request", return_value=response):
            with self.assertRaisesRegex(mcp_client.McpError, "HTTP response exceeds"):
                client.send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def test_stdio_request_is_hard_limited(self):
        self.assertEqual(
            mcp_client.encode_limited_message({"id": 1}, 20),
            '{"id":1}\n',
        )
        with self.assertRaisesRegex(mcp_client.McpError, "exceeds 8 bytes"):
            mcp_client.encode_limited_message({"payload": "too-large"}, 8)

    def test_legacy_sse_queue_is_bounded(self):
        client = mcp_client.LegacySseClient.__new__(mcp_client.LegacySseClient)
        client.message_url = "https://mcp.example/messages"
        client.responses = queue.Queue(maxsize=1)
        client._handle_event("message", '{"jsonrpc":"2.0","id":1}')
        with self.assertRaisesRegex(mcp_client.McpError, "queue limit"):
            client._handle_event("message", '{"jsonrpc":"2.0","id":2}')

    def test_legacy_sse_stream_rejects_oversized_line(self):
        client = mcp_client.LegacySseClient.__new__(mcp_client.LegacySseClient)
        client.manifest = {}
        client.url = "https://mcp.example/events"
        client.timeout = 1
        client.stop_event = mcp_client.threading.Event()
        client.stream_error = ""
        client.stream_response = None
        response = FakeHttpResponse(b"data: oversized\n\n")

        with (
            mock.patch.object(mcp_client, "MAX_SSE_EVENT_BYTES", 4),
            mock.patch.object(mcp_client, "open_http_request", return_value=response),
        ):
            client._read_stream()

        self.assertIn("SSE line exceeds 4 bytes", client.stream_error)

    def test_http_requests_are_hard_limited(self):
        self.assertEqual(
            mcp_client.encode_limited_http_message({"id": 1}, 8),
            b'{"id":1}',
        )
        with self.assertRaisesRegex(mcp_client.McpError, "request exceeds 8 bytes"):
            mcp_client.encode_limited_http_message({"payload": "too-large"}, 8)

    def test_legacy_sse_endpoint_must_remain_same_origin(self):
        self.assertEqual(
            mcp_client.legacy_message_url(
                "https://mcp.example/events",
                "/messages?id=1",
            ),
            "https://mcp.example/messages?id=1",
        )
        for candidate in (
            "https://attacker.example/messages",
            "http://mcp.example/messages",
            "https://mcp.example:444/messages",
            "https://user:pass@mcp.example/messages",
        ):
            with self.subTest(candidate=candidate), self.assertRaises(mcp_client.McpError):
                mcp_client.legacy_message_url(
                    "https://mcp.example/events",
                    candidate,
                )

    def test_mcp_http_opener_disables_proxies_and_redirects(self):
        with mock.patch.object(mcp_client.urllib.request, "build_opener") as build:
            opener = build.return_value
            opener.open.return_value = FakeHttpResponse(b"{}")
            mcp_client.open_http_request(
                mcp_client.urllib.request.Request("https://mcp.example/rpc"),
                1,
            )

        handlers = build.call_args.args
        self.assertTrue(any(isinstance(item, mcp_client.urllib.request.ProxyHandler) for item in handlers))
        proxy = next(item for item in handlers if isinstance(item, mcp_client.urllib.request.ProxyHandler))
        self.assertEqual(proxy.proxies, {})
        self.assertTrue(any(isinstance(item, mcp_client._NoRedirectHandler) for item in handlers))

    def test_list_tools_preserves_initialize_server_metadata(self):
        client = FakeClient()

        result = client.list_tools()

        self.assertEqual(result["serverInfo"], {"name": "fake", "version": "1.0"})
        self.assertEqual(result["tools"], [])
        self.assertEqual(client.sent[-1]["method"], "tools/list")

    def test_legacy_sse_get_stream_includes_manifest_auth_headers(self):
        client = mcp_client.LegacySseClient.__new__(mcp_client.LegacySseClient)
        client.manifest = {"headers": {"Authorization": "Bearer local-test"}}

        headers = client._headers("text/event-stream")

        self.assertEqual(headers["Accept"], "text/event-stream")
        self.assertEqual(headers["Authorization"], "Bearer local-test")


if __name__ == "__main__":
    unittest.main()
