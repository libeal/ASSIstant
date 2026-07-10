# 审计与安全审查报告

## 结论

本次审查确认 `logs/session_web_66030d29cedd464a.jsonl` 中核心执行链路只发生了 1 次 `agent_loop_iteration_started`，没有发现 work plan 被固定执行两轮。误判来源是 Web 审计呈现把多个 `agent_*` 生命周期事件都概括为“Agent 循环”，用户容易把“循环开始 / 迭代开始 / 循环结束”理解为多次执行。

已修复：

- `web/static/modules/audit.js` 现在区分 `agent_loop_started`、`agent_loop_iteration_started`、`agent_reflection_requested`、`agent_reflection_planned`、`agent_loop_finished` 等阶段。
- `web/server.py` 中 `observer.privilege` 的公开默认值已与 `lib/observer.sh` 的实际默认值对齐为 `sudo_interactive`。
- Web 和 API 测试已覆盖新增展示和默认值行为。

## 当前安全链路

项目的安全执行链路由四层叠加：

- 人工审批：`lib/executor.sh` 根据 risk、approval_required 和 `approvals.auto.*` 决定自动执行或暂停审批。
- AST 守卫：`lib/command_guard.py` 负责识别 shell 结构风险，包括远程管道、文件写入、提权、隐藏执行等。
- 正则策略：`policies/risk-rules.json` 负责项目可调的 block/warn 规则、保护路径和保护服务。
- 审计/observer：`lib/audit.sh` 记录脱敏 JSONL，`lib/observer.sh` 尝试用 auditd 观察执行过程，不可用时记录降级事件。

这个组合整体方向正确：模型输出不直接执行，执行层独立做 policy review、approval、observer 和 audit。

## 发现的问题

### 1. Agent loop 呈现不清晰

状态：已修复。

问题：审计事件里 `agent_loop_started`、`agent_loop_iteration_started`、`agent_loop_finished` 都显示为“Agent 循环”，在 session 列表里看起来像重复循环。

影响：用户难以判断是“生命周期事件”还是“真实执行轮次”，尤其在只执行一轮时也会看到多个 agent 相关事件。

修复：前端审计标签现在显示具体阶段，并补充 iteration、iterations、plan_step_count、auto_executed_count、checkpoint_turns 等细节。

### 2. Observer 配置中心默认值与运行时不一致

状态：已修复。

问题：`lib/observer.sh` 缺省使用 `observer.privilege = sudo_interactive`，但 Web 配置中心在字段缺失时显示空字符串。

影响：用户可能以为空值代表禁用或未配置，实际 Web observer 仍按交互 sudo 策略尝试。

修复：`web/server.py` 的 `config_public_state()` 默认值已改为 `sudo_interactive`。

### 3. AST/正则/审批的审查结果仍偏“技术原始”

状态：仍建议优化。

当前 `review.findings[]` 已有 `severity`、`code`、`source`、`category`、`action`，但 Web 侧在审批抽屉和审计列表里更多展示的是摘要文本。对非开发用户而言，不容易快速知道：

- 是 AST 阻断还是正则策略阻断；
- 是必须拒绝、必须人工批准，还是低风险可自动执行；
- 哪条配置开关影响了这次自动批准决策；
- 如果被阻断，应改用哪个受控能力，例如 `controlled-tools/file-patch`。

建议增加一个稳定的 `review.explanation` 或 `review.decision_summary`：

```json
{
  "decision": "approval_required",
  "primary_source": "ast",
  "primary_reason": "命令包含服务重启",
  "recommended_action": "人工确认服务名、影响窗口和回滚方式后批准",
  "auto_approval_capability": "shell_readonly",
  "auto_approval_enabled": false
}
```

### 4. 审计回放是 Web 派生视图，不是审计事实本身

状态：已记录边界，建议在 UI 文案继续强调。

`web_timeline` 是 `web/server.py` 从 JSONL 事件恢复出的 Web 工作台视图，方便点击回放，但它会合成计划、轮次和输出块。真实审计事实仍是 JSONL 原始事件和 `agent audit <session-id>` 报告。

建议：

- 在回放详情里持续显示 `source: audit` 和原始 `session_id`。
- 对合成轮次显示“由审计事件恢复”，避免与 live session 混淆。
- 不把 `web_timeline` 写回 JSONL，这一点当前实现是正确的。

### 5. 自动批准开关有效，但语义依赖 policy 结果

状态：配置有效，建议增强说明。

配置中心里的 `approvals.auto.*` 都已接到 `lib/executor.sh`：

- `skill_readonly`
- `shell_readonly`
- `file_match`
- `file_patch`
- `file_download`
- `local_analyze`
- `remote_script`

这些开关只有在 review 为 approved、approval_required=false 且 risk_level=low 时才可能生效。也就是说，开关不是“强制自动执行”，而是“允许低风险且审查干净的能力自动执行”。

建议在配置中心中把注释统一成“允许自动执行”，避免用户误解为可绕过策略。

## MCP 安全边界

MCP registry 读取 `mcp/<id>/mcp.json`，校验/展示三种 transport，并可通过 MCP lifecycle 执行 `tools/list` 生成 work/edit 可见的 tool catalog：

- `stdio`
- `sse`
- `streamable_http`

项目没有从 Web 或普通 API 暴露任意 `tools/call` 入口。实际 MCP 调用只能由 work 模式计划生成 `executor_type:"mcp_tool"` 步骤；执行前会校验 tool 存在于 `tools/list`，再进入 policy、人工审批、observer 和 audit。edit 模式只使用 MCP catalog 作为参考，不直接执行 MCP。API/Web 响应会对 `Authorization`、`token`、`secret`、`password`、`api_key` 等字段脱敏。

MCP 官方稳定规范说明当前标准 transport 是 `stdio` 和 `Streamable HTTP`，且 `Streamable HTTP` 替代了 2024-11-05 的 HTTP+SSE；为了兼容外部旧 server，本项目 registry 同时接受 legacy `sse` manifest。参考：[Model Context Protocol transports 2025-11-25](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports) 和 [Model Context Protocol transports 2024-11-05](https://modelcontextprotocol.io/specification/2024-11-05/basic/transports)。

## 推荐后续顺序

1. 为 `review` 增加面向用户的决策摘要字段，并在审批抽屉、审计事件和 output_blocks 里复用。
2. 给 Web 审计回放增加“审计事实 / Web 恢复视图”的显式标识。
3. 把配置中心所有自动批准开关文案统一为“允许低风险自动执行”，减少绕过策略的误解。
4. 为 MCP tool catalog 增加缓存与失效策略，避免 work/edit 每次构建上下文时重复启动同一 server。
