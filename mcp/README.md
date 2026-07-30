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

`MCP 2026-07-28` is the protocol revision. `mcp==2.0.0` is the pinned
official Python SDK version; they are separate version concepts. The default
client is modern-first: it uses the isolated SDK runtime for
`server/discover`, the complete paginated `tools/list`, and `tools/call`. The
frozen legacy client is used only when a compatibility failure occurs before a
tool call is sent. Once `tools/call` is sent, it is never replayed or
downgraded; an indeterminate disconnect returns `mcp_outcome_unknown`.

Supported transports:

- `stdio`: local subprocess transport.
- `sse`: frozen legacy HTTP + Server-Sent Events transport; manifest v2 must
  opt in with `compatibility.allow_legacy_sse=true`.
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
  "credential_profile": "remote-tools-prod",
  "protocol": {"mode": "modern_then_legacy"}
}
```

Credential profiles are stored outside the registry at
`$LINUX_AGENT_DATA_DIR/mcp/credentials/<profile-id>.json`. The directory is
mode `0700` and each profile is mode `0600`; managed installs assign both to
the dedicated Runner user. A profile is bound to one exact `server_id`
and `server_url`; OAuth profiles are additionally bound to one exact
`authorization_server_issuer`. The supported profile types are:

- `static_headers`, for compatibility with existing bearer/cookie headers;
- `oauth_client_credentials`;
- `oauth_authorization_code`, with Client ID Metadata Documents (CIMD)
  preferred. Dynamic Client Registration (DCR) is denied unless the profile
  explicitly sets `allow_dynamic_registration:true`.

OAuth is implemented by the pinned SDK, including RFC 9207 authorization
response `iss` validation, authorization-server metadata issuer validation,
CIMD selection, and issuer-bound DCR state. The Agent also binds profiles,
tokens and redirect URIs to the configured resource/issuer. An issuer change
discards stale DCR credentials and tokens. Web OAuth clients require HTTPS
redirect URIs; native clients may use loopback HTTP. Protected `tools/list` and
`tools/call` operations both use the Runner's fixed adapter contract. The
Runner transfers the validated profile through a read-only sealed memfd. SDK
token and DCR client updates return through a separate bounded anonymous memfd;
the Runner validates the issuer and original profile digest, atomically writes
mode `0600`, and rejects concurrent profile changes. Secrets never enter the
manifest, argv, ordinary environment values, temporary argument files, Job
results, or verbose audit fields.

Managed STDIO servers do not run as the Runner. The adapter connects to
`linux-agent-mcp-stdio.socket`, and the socket-activated relay launches each
server under a systemd `DynamicUser` service with the persistent data tree
hidden. The relay socket is accessible only to the Runner group, so STDIO
servers cannot open credential profiles or reconnect to the launch boundary.
Source and explicit `--no-systemd` modes retain the documented same-UID
development path.

MRTR `InputRequiredResult` is returned as `mcp_input_required`. Only a user can
provide the response; it goes through another policy review and confirmation.
The opaque continuation is mode `0600`, remains owned by the Runner in managed
installs, and is bound to the flow, server, tool and arguments. Web stores the
flow/step/expiry binding in a separate private metadata file without reading or
rewriting the continuation. It expires after 15 minutes and permits at most 3
rounds, 16 items per round and 64 KiB total input. Cancelling deletes both
files.

Protocol modes:

- `modern_then_legacy` (default): modern probe first, frozen fallback only
  before `tools/call`;
- `modern_only`: require `2026-07-28`;
- `legacy_only`: emergency rollback only.

Secret-like fields such as `Authorization`, `token`, `password`, `secret` and
`api_key` are redacted from API/Web responses. Inline secret headers remain
read-compatible but should be migrated to credential profiles.

The SDK wheelhouse is under `third_party/mcp-python-sdk/` and is installed with
`--no-index --require-hashes`. Source checkouts share an ignored venv under
`tmp/.shared/mcp-venvs/`; managed releases use
`releases/<version>/.mcp-venv`; Remote uses `<verified-runtime>/agent/.mcp-venv`.
Run `bash bin/agent doctor` to inspect platform, wheelhouse and venv readiness.
Tool schemas retain valid JSON Schema 2020-12 `$ref` values as untrusted data,
but neither catalog processing nor MRTR validation retrieves external schemas.
The pinned official conformance gate can be run with
`bash tests/mcp_conformance.sh` after installing
`@modelcontextprotocol/conformance@0.2.0-alpha.10`.

Useful commands:

```bash
bash bin/agent mcp list
bash bin/agent mcp validate
bash bin/agent mcp tools
```
