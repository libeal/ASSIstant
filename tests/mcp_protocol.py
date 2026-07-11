#!/usr/bin/env python3

import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("mcp_client", ROOT / "lib" / "mcp_client.py")
assert SPEC and SPEC.loader
mcp_client = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(mcp_client)


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
    def test_rejects_server_protocol_version_the_client_does_not_support(self):
        client = FakeClient("2099-01-01")

        with self.assertRaisesRegex(mcp_client.McpError, "unsupported protocol version"):
            client.initialize()

        self.assertEqual(client.sent[-1]["method"], "initialize")

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
