# CLI/Web API 协议

本文定义 `bash bin/agent api ...` 与 Web 工作台之间的稳定机器协议。执行类响应只暴露工作台协议字段，不再返回旧的 preview/result/execution 兼容结构。

## 通用响应

所有机器接口响应必须是 JSON object，并至少包含：

- `ok`: boolean，表示请求是否已经完成预期动作。
- `status`: string，机器可读状态码。
- `error`: string，可选，失败或阻断时的人类可读原因。

常见状态：

- `ok`、`listed`、`read`、`updated`、`validated`、`approved`、`executed`: 请求成功。
- `invalid_json`、`invalid_payload`、`missing_input`: 调用方输入错误。
- `ai_config_missing`、`ai_request_failed`、`ai_invalid_response`: AI 配置或响应错误。
- `approval_required`: 执行前需要用户确认。
- `validation_failed`、`blocked`、`rejected`、`failed`、`cancelled`: 执行或保存未完成。
- `secret_transmission_disabled`: Remote runtime 未允许向 AI Provider 发送 API key。
- `skill_materialized`、`skill_download_failed`、`skill_digest_mismatch`、`skill_package_invalid`: Remote skill 整包物化结果。
- `backup_created`、`backup_ready`、`backup_unavailable`: CLI/Web runtime 备份状态。

## 工作台协议

所有执行类响应统一包含：

- `timeline`: array，展示计划、审查、审批、执行、失败、observer、审计事件。
- `approval_card`: object|null，当前待审批对象；没有待审批事项时为 `null`。
- `output_blocks`: array，顶层分块结果，适合终端、脚本、工作流摘要和审计回放展示。

Remote 会话的审计时间线额外记录 `remote_bootstrap_verified`、`skill_materialized` 和 `runtime_backup_created`；bootstrap 事件只包含 Release 版本、入口、临时存储后端和已校验资产名，不包含 URL 查询参数、token 或密钥。

示例：

```json
{
  "ok": true,
  "status": "executed",
  "timeline": [
    {
      "id": "step-1",
      "kind": "execution",
      "status": "executed",
      "title": "查看 CPU 与内存资源概况",
      "summary": "system.resource.inspect",
      "output_blocks": [
        {"kind": "json", "title": "执行输出", "json": {"tool": "system.resource.inspect"}}
      ]
    }
  ],
  "approval_card": null,
  "output_blocks": [
    {"kind": "meta", "title": "工作流摘要", "json": {"status": "executed", "auto_executed_count": 1}}
  ]
}
```

## Approval Card

需要人工确认时，响应仍为 `ok:false` 和 `status:"approval_required"`，并提供 `approval_card`：

```json
{
  "ok": false,
  "status": "approval_required",
  "approval_card": {
    "id": "terminal-approval",
    "type": "terminal",
    "subject": "终端命令",
    "title": "终端命令需要审批",
    "risk_level": "high",
    "review": {"engine": "ast+rules", "approval_required": true, "findings": []},
    "actions": ["approve", "reject"]
  },
  "timeline": [],
  "output_blocks": []
}
```

## Review 对象

`review` 是策略审查的稳定对象：

- `engine`: 审查引擎，例如 `ast+rules`。
- `subject`: 被审查对象。
- `approved`: 是否允许继续进入审批或执行阶段。
- `approval_required`: 是否必须人工确认。
- `risk_level`: `low`、`medium`、`high`、`critical`。
- `findings`: finding 数组。

每个 finding 至少包含：

- `severity`: `low`、`medium`、`high`、`critical`。
- `code`: 机器可读代码，例如 `AST_REMOTE_PIPE`、`AST_PROTECTED_REDIRECT`、`REGEX_WARN`。
- `message`: 简短说明。
- `source`: `ast` 或 `policy`。
- `category`: 风险类别。
- `action`: `block` 或 `approve`。

有命令上下文时，finding 还可以包含 `command_head`、`node`、`text`。

## Output Blocks

`output_blocks[]` 使用以下常见形态：

- `stdout`、`stderr`、`markdown`: `{kind,title,text,truncated_bytes}`。
- `json`、`table`、`review`、`observer`、`meta`: `{kind,title,json}`。

调用方应优先按 `kind` 渲染；未知 `kind` 必须作为结构化 JSON 或纯文本安全展示。

## Web Job

Web 后端 job 外壳保留异步任务状态；`job.result` 内部仍是上述工作台协议响应。

```json
{
  "ok": true,
  "job_id": "hex",
  "resource": "terminal",
  "action": "run",
  "status": "succeeded",
  "result_status": "executed",
  "result_ok": true,
  "result": {
    "ok": true,
    "status": "executed",
    "timeline": [],
    "approval_card": null,
    "output_blocks": []
  }
}
```

## Policy Validate

策略校验可通过 CLI 和 Web API 共用：

```bash
bash bin/agent policy validate [file]
bash bin/agent api policy validate '{"path":"risk-rules.json"}'
bash bin/agent api policy validate '{"path":"risk-rules.json","content":"{...}"}'
```

响应中的 `validation` 至少包含：

- `ok`: boolean，是否没有 critical finding。
- `status`: `valid`、`invalid` 或 `not_found`。
- `path`: 相对 `policies/` 的 JSON 文件名。
- `findings`: array，策略结构、正则编译、零宽匹配或审计边界问题。

Web `/api/policies/write` 保存前必须先运行同一套校验；失败时返回 `ok:false`、`status:"validation_failed"`，且不得写入目标策略文件。

## MCP Registry

MCP registry 读取项目根目录 `mcp/` 下的外部 MCP server manifest。推荐路径为：

```text
mcp/<server-id>/mcp.json
```

CLI/API：

```bash
bash bin/agent mcp list
bash bin/agent mcp validate
bash bin/agent mcp tools
bash bin/agent api mcp list
bash bin/agent api mcp validate
bash bin/agent api mcp tools
```

`mcp list` 响应：

```json
{
  "ok": true,
  "status": "listed",
  "root": "/path/to/project/mcp",
  "servers": [
    {
      "id": "filesystem",
      "name": "Filesystem MCP",
      "transport": "stdio",
      "enabled": true,
      "path": "filesystem/mcp.json",
      "valid": true,
      "config": {
        "id": "filesystem",
        "transport": "stdio",
        "command": "node",
        "args": ["server.js"],
        "env": {"API_TOKEN": "[REDACTED]"}
      },
      "findings": []
    }
  ],
  "findings": []
}
```

支持 transport：

- `stdio`
- `sse`
- `streamable_http`

API/Web 响应必须脱敏 Authorization、cookie、token、secret、password、api_key 等敏感字段。registry 只在发现工具时执行 MCP initialize 和 `tools/list`；不会从 API/Web 暴露任意 `tools/call` 直连入口。

`mcp tools` 会对有效且启用的 manifest 执行 MCP lifecycle 和 `tools/list`，返回 agent 在 work/edit 上下文中可见的 tool catalog：

```json
{
  "ok": true,
  "status": "listed",
  "tool_count": 1,
  "tools": [
    {
      "server_id": "filesystem",
      "name": "read_file",
      "ref": "filesystem/read_file",
      "transport": "stdio",
      "description": "Read a file",
      "inputSchema": {"type": "object"}
    }
  ]
}
```

MCP tool 调用没有独立 API/浏览器直连入口。模型只能在 work 模式返回：

```json
{
  "id": "step-1",
  "title": "调用外部 MCP 工具",
  "executor_type": "mcp_tool",
  "mcp_server": "filesystem",
  "mcp_tool": "read_file",
  "arguments": {"path": "README.md"},
  "reason": "读取用户要求的文件",
  "expected_effect": "返回文件内容",
  "risk_level": "medium",
  "rollback_hint": "只读调用无需回滚"
}
```

执行器会校验该 tool 存在于 `tools/list`，再进入 policy、人工审批、observer 和 audit。edit 模式只使用 MCP catalog 作为参考，响应仍必须是 `skill_edit`。

## Audit Replay

CLI 审计读取仍以 JSONL session 和报告为准。Web 后端可以在 `/api/audit/read` 响应中附加 `web_timeline`，用于把审计事件恢复成只属于 Web 工作台的时间线：

```json
{
  "ok": true,
  "events": [],
  "report": "...",
  "web_timeline": {
    "ok": true,
    "status": "executed",
    "source": "audit",
    "session_id": "20260101-000000-abc",
    "timeline": [],
    "response": {"response_type": "work_plan", "steps": []},
    "approval_card": null,
    "output_blocks": []
  }
}
```

`web_timeline` 是 Web 独占恢复视图，不应反向写回审计日志，也不要求 CLI `agent audit` 渲染相同结构。

## Secret 配置

API key 不应作为普通配置明文字段回显。配置状态只暴露：

- `api_key_configured`: boolean。
- `api_key_source`: `runtime`、`env`、`config`、`missing`。
- `api_key_configured_in_config`: boolean。

本地 Web 写入 `api_key` 时写入 `config.api_key`；Remote Web 只更新 Web 进程内存，并且只向需要 AI 的 Work/Edit CLI 子进程注入环境，Terminal、Skill、Doctor、备份等子进程不继承密钥。两种模式的响应都只能返回 `"configured"`，不能返回明文。

配置状态包含 additive `remote` 对象：

```json
{
  "enabled": true,
  "release_version": "v1.0.0",
  "storage_backend": "dev_shm",
  "allow_api_key_transmission": false
}
```

Remote 模式下，如果 `allow_api_key_transmission` 不是 `true`，Work/Edit API 入口、AI Provider 请求和模型列表请求均返回 `ok:false`、`status:"secret_transmission_disabled"`，包括调用方直接附带预生成计划的 Work 请求。前端禁用按钮只是交互提示，后端检查才是安全边界。

## Remote Skill Materialization

`bash bin/agent api skills materialize '{"skill":"os-deep-inspect"}'` 和 `POST /api/skills/materialize` 按一级 skill 下载完整 Release 归档。成功响应：

```json
{
  "ok": true,
  "status": "skill_materialized",
  "skill": "os-deep-inspect",
  "files": [
    "skills/os-deep-inspect/SKILL.md",
    "skills/os-deep-inspect/agents/openai.yaml"
  ]
}
```

下载失败、摘要不匹配和包校验失败分别使用 `skill_download_failed`、`skill_digest_mismatch`、`skill_package_invalid`。失败不得把 staging 目录加入可执行 registry。

`tools list` 中每个脚本增加 `materialization`：本地模式为 `local`，Remote 模式为 `available` 或 `ready`。列出能力和 `skills validate` 不得为了改变该状态而下载全部 skill。

## Runtime Backup

`bash bin/agent backup <output.tar.gz>` 仅在 Remote 模式可用，输出路径必须不存在且位于临时 runtime root 之外。归档只包含二次脱敏的 audit、基于脱敏副本生成的报告、脱敏配置、没有官方远程校验标记的用户 skill，以及已物化官方 skill 的摘要台账。用户 skill 含符号链接、设备、FIFO 或 socket 时返回 `backup_unsafe_skill`，不生成不安全归档。

Web `GET /api/runtime/backup` 使用现有 Bearer token 认证，成功时返回 `application/gzip` 和 `Content-Disposition: attachment`，发送完成后删除服务器临时归档；失败使用普通 JSON 错误响应。该二进制接口不包装成工作台 JSON 协议。

## Provider 与模型列表

Web 配置中心通过 `/api/config/providers` 读取内置 provider 预设：

```json
{
  "ok": true,
  "status": "listed",
  "providers": [
    {
      "id": "openai",
      "label": "OpenAI",
      "api_url": "https://api.openai.com/v1/chat/completions",
      "default_model": "gpt-4.1-mini",
      "custom_url": false,
      "model_fetch_supported": true
    }
  ]
}
```

`POST /api/config/models` 使用已配置 API key，或请求体里的临时 `api_key`，向 provider 拉取模型列表：

```json
{
  "provider": "openai_compatible",
  "api_url": "http://127.0.0.1:24000/v1/chat/completions",
  "api_key": "write-only value"
}
```

成功响应只返回可展示模型 ID，不返回或记录 API key：

```json
{
  "ok": true,
  "status": "listed",
  "provider": "openai_compatible",
  "key_source": "request",
  "models": [{"id": "model-name"}],
  "model_count": 1
}
```

不支持模型列表的厂商返回 `ok:false`、`status:"model_list_unavailable"` 和可展示错误信息；前端必须保留手动输入模型名的能力。

## Web Observer Bootstrap

Web 后端提供 `/api/observer/bootstrap`：

- `GET`: 返回当前 observer bootstrap 状态、observer 配置和是否需要权限。
- `POST {"action":"enable","password":"..."}`: 用服务器密码刷新 sudo 凭据并验证 `auditctl -s`，响应不得回显密码。
- `POST {"action":"skip"}`: 记录 `observer_bootstrap_skipped` 审计事件并返回 `logged:true`。

该接口只负责让无 TTY 的 Web 进程取得后续 observer 预检所需的 sudo 凭据；每个执行 session 仍由 CLI core 安装和清理 auditd 规则。

执行类响应中的 `observer` output block 或 timeline observer 条目应按摘要字段渲染，不应展示原始 `ausearch` 行。常见字段包括：

- `status`: `recorded`、`observed`、`disabled`、`unavailable` 或 `failed`。
- `backend`: 当前为 `auditd`。
- `audit_key`: 本次 session 的 auditd key。
- `uid` / `audit_uid` / `identity_filter`: 当前进程 UID、用于 `auid` 过滤的 UID 和过滤类型。
- `exec_count` / `file_event_count`: 按 audit record id 去重后的执行和文件事件计数。
- `processes` / `file_events`: 受 `observer.max_events` 限制的样本。
- `reason_code` / `diagnostic`: observer 降级或失败原因。
