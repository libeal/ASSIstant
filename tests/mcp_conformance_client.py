#!/usr/bin/env python3
"""Drive the MCP adapter against one official client conformance scenario."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import urllib.parse
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CLIENT = ROOT / "lib" / "mcp_client.py"
LOOPBACK_HOSTS = {"localhost", "127.0.0.1", "::1"}
CALL_SCENARIOS: dict[str, tuple[str, dict[str, object]]] = {
    "http-standard-headers": ("test_headers", {}),
    "tools_call": ("add_numbers", {"a": 20, "b": 22}),
}
LIST_SCENARIOS = {
    "json-schema-ref-no-deref",
    "request-metadata",
}


def conformance_url(value: str) -> str:
    try:
        parsed = urllib.parse.urlsplit(value)
        port = parsed.port
    except ValueError as exc:
        raise ValueError("conformance server URL is invalid") from exc
    if (
        parsed.scheme != "http"
        or parsed.hostname not in LOOPBACK_HOSTS
        or parsed.username is not None
        or parsed.password is not None
        or port is None
    ):
        raise ValueError("conformance server must be an explicit loopback HTTP URL")
    return value


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: mcp_conformance_client.py <server-url>", file=sys.stderr)
        return 2
    scenario = os.environ.get("MCP_CONFORMANCE_SCENARIO", "")
    if scenario not in CALL_SCENARIOS and scenario not in LIST_SCENARIOS:
        print(f"unsupported MCP conformance scenario: {scenario}", file=sys.stderr)
        return 2
    try:
        server_url = conformance_url(sys.argv[1])
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 2

    with tempfile.TemporaryDirectory(prefix="linux-agent-mcp-conformance.") as temporary:
        directory = Path(temporary)
        manifest = directory / "mcp.json"
        manifest.write_text(
            json.dumps(
                {
                    "manifest_version": 2,
                    "id": "official-conformance",
                    "transport": "streamable_http",
                    "url": server_url,
                    "timeout_sec": 20,
                    "protocol": {"mode": "modern_only", "require_modern": True},
                },
                separators=(",", ":"),
            ),
            encoding="utf-8",
        )
        if scenario in LIST_SCENARIOS:
            command = [sys.executable, os.fspath(CLIENT), "list-tools", os.fspath(manifest)]
        else:
            tool, arguments = CALL_SCENARIOS[scenario]
            arguments_file = directory / "arguments.json"
            arguments_file.write_text(
                json.dumps(arguments, separators=(",", ":")),
                encoding="utf-8",
            )
            os.chmod(arguments_file, 0o600)
            command = [
                sys.executable,
                os.fspath(CLIENT),
                "call-tool",
                os.fspath(manifest),
                tool,
                os.fspath(arguments_file),
            ]
        completed = subprocess.run(command, check=False, timeout=60)
        return completed.returncode


if __name__ == "__main__":
    raise SystemExit(main())
