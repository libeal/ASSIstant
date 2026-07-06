# MCP Registry

Place external MCP server manifests under this directory as:

```text
mcp/<server-id>/mcp.json
```

The project reads these manifests as capability metadata. It validates and
displays them in the CLI/Web registry, but it does not execute external MCP
servers directly from the browser.

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
