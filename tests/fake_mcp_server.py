#!/usr/bin/env python3

import json
import sys


TOOLS = [
    {
        "name": "echo",
        "description": "Echo text through a fake MCP tool.",
        "inputSchema": {
            "type": "object",
            "properties": {"text": {"type": "string"}},
            "required": ["text"],
        },
        "annotations": {"readOnlyHint": True},
    }
]


def response(message_id, result=None, error=None):
    payload = {"jsonrpc": "2.0", "id": message_id}
    if error is not None:
        payload["error"] = error
    else:
        payload["result"] = result if result is not None else {}
    return payload


def handle(message):
    method = message.get("method")
    message_id = message.get("id")
    if method == "initialize":
        return response(
            message_id,
            {
                "protocolVersion": message.get("params", {}).get("protocolVersion", "2025-11-25"),
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": {"name": "fake-mcp", "version": "1.0.0"},
            },
        )
    if method == "notifications/initialized":
        return None
    if method == "tools/list":
        return response(message_id, {"tools": TOOLS})
    if method == "tools/call":
        params = message.get("params", {})
        name = params.get("name")
        arguments = params.get("arguments") if isinstance(params.get("arguments"), dict) else {}
        if name != "echo":
            return response(message_id, error={"code": -32601, "message": "unknown tool"})
        text = str(arguments.get("text", ""))
        return response(
            message_id,
            {
                "content": [{"type": "text", "text": f"echo:{text}"}],
                "structuredContent": {"echo": text},
                "isError": False,
            },
        )
    return response(message_id, error={"code": -32601, "message": "unknown method"})


def stdio_main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            continue
        result = handle(message)
        if result is not None:
            sys.stdout.write(json.dumps(result, separators=(",", ":")) + "\n")
            sys.stdout.flush()


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "stdio"
    if mode == "stdio":
        stdio_main()
        return
    raise SystemExit(f"unsupported fake MCP mode: {mode}")


if __name__ == "__main__":
    main()
