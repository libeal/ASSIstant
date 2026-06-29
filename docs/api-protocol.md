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

## 工作台协议

所有执行类响应统一包含：

- `timeline`: array，展示计划、审查、审批、执行、失败、observer、审计事件。
- `approval_card`: object|null，当前待审批对象；没有待审批事项时为 `null`。
- `output_blocks`: array，顶层分块结果，适合终端、脚本、工作流摘要和审计回放展示。

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
- `api_key_source`: `env`、`config`、`missing`。
- `api_key_configured_in_config`: boolean。

Web 写入 `api_key` 时，后端必须写入 `config.api_key`；响应中只能返回 `"configured"`，不能返回明文。

## Web Observer Bootstrap

Web 后端提供 `/api/observer/bootstrap`：

- `GET`: 返回当前 observer bootstrap 状态、observer 配置和是否需要权限。
- `POST {"action":"enable","password":"..."}`: 用服务器密码刷新 sudo 凭据并验证 `auditctl -s`，响应不得回显密码。
- `POST {"action":"skip"}`: 记录 `observer_bootstrap_skipped` 审计事件并返回 `logged:true`。

该接口只负责让无 TTY 的 Web 进程取得后续 observer 预检所需的 sudo 凭据；每个执行 session 仍由 CLI core 安装和清理 auditd 规则。
