---
name: session-history
description: 读取本项目审计 session 中上一轮或指定轮次的命令、步骤和 shell/stdout/stderr 输出预览。用于 agent 需要回看上一轮执行了什么命令、终端返回了什么、审批前已完成哪些步骤，或需要从 logs/session_*.jsonl 恢复最近输出上下文时。
---

# Session History

使用这个 skill 从 `logs/*.jsonl` 审计流中读取上一轮或指定轮次的执行上下文。脚本只读访问审计日志，输出 JSON，不执行被记录的命令。

## 传参规范

调用形式为 `bash scripts/last-command-output.sh '<json-object>'`。唯一位置参数必须是 JSON object；stdout 只输出一个 JSON object，并以 `ok` 表示业务结果。

| 字段 | 类型 | 必填 | 默认与约束 |
| --- | --- | --- | --- |
| `session_id` | string | 条件必填 | 当前进程有 `LINUX_AGENT_SESSION_ID` 时默认用当前 session；否则必填。只允许安全文件名，不能含路径分隔符 |
| `turn_offset` | integer | 否 | 当前 session 默认 1，显式历史 session 默认 0；必须 >=0 |
| `limit` | integer | 否 | 默认 20；1..100，限制返回的命令和输出条目 |

示例：`bash scripts/last-command-output.sh '{"session_id":"session_...","turn_offset":0,"limit":20}'`。

## Scripts

- `scripts/last-command-output.sh`: 参数 `session_id`、`turn_offset`、`limit`；读取目标 session 中某一轮的命令、计划步骤和输出预览。

## Workflow

当 agent 需要知道“上一轮执行了什么”时，优先调用 `session-history/last-command-output`。

- 在当前 Web/CLI session 内回看上一轮：不传 `session_id`，脚本会使用当前 `LINUX_AGENT_SESSION_ID`，默认读取当前轮之前的一轮。
- 回看指定历史 session 的最后一轮：传 `session_id`，并设置 `turn_offset: 0`。
- 回看更早轮次：增大 `turn_offset`，例如 `1` 表示倒数第二轮。

返回中的 `commands` 包含入口命令、terminal 命令、计划步骤命令或 skill；`outputs` 包含 `terminal_executed`、`script_executed`、`step_succeeded`、`step_failed` 等事件中的输出和错误预览。
