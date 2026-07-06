# MCP Registry

Place external MCP server manifests under this directory as:

```text
mcp/<server-id>/mcp.json
```

The project reads these manifests as external capability metadata. It validates
and displays them in the CLI/Web registry, can discover `tools/list`, and exposes
the resulting MCP tools to work/edit model context. Actual `tools/call`
execution is only allowed through a `work_plan` step with
`executor_type: "mcp_tool"`; it goes through policy review, manual approval,
observer, and audit. The browser never calls external MCP tools directly.

Supported transports:

- `stdio`: local subprocess transport.
- `sse`: legacy HTTP + Server-Sent Events transport.
- `streamable_http`: current single-endpoint HTTP transport.

Example `stdio` manifest:

```json
{
  "id": "filesystem",
  "name": "Filesystem MCP",
  "description": "Local filesystem MCP server",
  "enabled": true,
  "transport": "stdio",
  "command": "node",
  "args": ["server.js"],
  "env": {
    "API_TOKEN": "set-real-values-locally"
  }
}
```

Example `streamable_http` manifest:

```json
{
  "id": "remote-tools",
  "name": "Remote tools MCP",
  "transport": "streamable_http",
  "url": "https://example.com/mcp",
  "headers": {
    "Authorization": "Bearer set-real-values-locally"
  }
}
```

Secret-like fields such as `Authorization`, `token`, `password`, `secret` and
`api_key` are redacted from API/Web responses.

Useful commands:

```bash
bash bin/agent mcp list
bash bin/agent mcp validate
bash bin/agent mcp tools
```
