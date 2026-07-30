#!/usr/bin/env python3

import json
import os
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
    params = message.get("params", {})
    metadata = params.get("_meta", {}) if isinstance(params, dict) else {}
    modern = metadata.get("io.modelcontextprotocol/protocolVersion") == "2026-07-28"
    behavior = os.environ.get("FAKE_MCP_BEHAVIOR", "normal")
    if method == "server/discover":
        if behavior == "discover_method_not_found":
            return response(message_id, error={"code": -32601, "message": "unknown method"})
        if behavior == "discover_modern_only":
            supported = ["2026-07-28"]
        elif behavior == "discover_future_only":
            supported = ["2027-01-01"]
        elif behavior == "discover_legacy_only":
            supported = ["2025-11-25"]
        else:
            supported = ["2025-11-25", "2026-07-28"]
        return response(
            message_id,
            {
                "_meta": {
                    "io.modelcontextprotocol/serverInfo": {
                        "name": "fake-mcp",
                        "version": "2.0.0",
                    }
                },
                "cacheScope": "private",
                "capabilities": {"tools": {"listChanged": False}},
                "resultType": "complete",
                "supportedVersions": supported,
                "ttlMs": 0,
            },
        )
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
        if behavior == "invalid_tool_list" and modern:
            return response(
                message_id,
                {"tools": "invalid", "cacheScope": "private", "resultType": "complete", "ttlMs": 0},
            )
        result = {"tools": TOOLS}
        if modern:
            result.update({"cacheScope": "private", "resultType": "complete", "ttlMs": 0})
        return response(message_id, result)
    if method == "tools/call":
        name = params.get("name")
        arguments = params.get("arguments") if isinstance(params.get("arguments"), dict) else {}
        if name != "echo":
            return response(message_id, error={"code": -32601, "message": "unknown tool"})
        if behavior == "rpc_error_on_call":
            return response(
                message_id,
                error={
                    "code": -32602,
                    "message": "invalid test arguments",
                    "data": {"secret": "must-not-be-returned"},
                },
            )
        if behavior == "input_items_exceeded":
            return response(
                message_id,
                {
                    "resultType": "input_required",
                    "inputRequests": {
                        f"item-{index}": {
                            "method": "elicitation/create",
                            "params": {"mode": "url", "message": "Continue", "url": "https://example.test/"},
                        }
                        for index in range(17)
                    },
                    "requestState": "opaque-sensitive-state",
                },
            )
        if behavior in {"input_required", "input_required_always"} and (
            behavior == "input_required_always" or not params.get("inputResponses")
        ):
            return response(
                message_id,
                {
                    "resultType": "input_required",
                    "inputRequests": {
                        "email": {
                            "method": "elicitation/create",
                            "params": {
                                "mode": "form",
                                "message": "Enter an email address",
                                "requestedSchema": {
                                    "type": "object",
                                    "properties": {"email": {"type": "string"}},
                                    "required": ["email"],
                                },
                            },
                        }
                    },
                    "requestState": "opaque-sensitive-state",
                },
            )
        text = str(arguments.get("text", ""))
        input_responses = params.get("inputResponses")
        result = {
            "content": [{"type": "text", "text": f"echo:{text}"}],
            "structuredContent": {"echo": text},
            "isError": False,
        }
        if input_responses is not None:
            result["structuredContent"]["inputResponses"] = input_responses
        if modern:
            result["resultType"] = "complete"
        return response(message_id, result)
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
        log_path = os.environ.get("FAKE_MCP_LOG")
        if log_path:
            with open(log_path, "a", encoding="utf-8") as log_handle:
                log_handle.write(json.dumps(message, separators=(",", ":")) + "\n")
        if (
            os.environ.get("FAKE_MCP_BEHAVIOR") == "disconnect_on_call"
            and message.get("method") == "tools/call"
        ):
            return
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
