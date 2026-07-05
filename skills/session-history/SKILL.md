---
name: session-history
description: 读取本项目审计 session 中上一轮或指定轮次的命令、步骤和 shell/stdout/stderr 输出预览。用于 agent 需要回看上一轮执行了什么命令、终端返回了什么、审批前已完成哪些步骤，或需要从 logs/session_*.jsonl 恢复最近输出上下文时。
---

# Session History

使用这个 skill 从 `logs/*.jsonl` 审计流中读取上一轮或指定轮次的执行上下文。脚本只读访问审计日志，输出 JSON，不执行被记录的命令。

## Scripts

- `scripts/last-command-output.sh`: 参数 `session_id`、`turn_offset`、`limit`；读取目标 session 中某一轮的命令、计划步骤和输出预览。

## Workflow

当 agent 需要知道“上一轮执行了什么”时，优先调用 `session-history/last-command-output`。

- 在当前 Web/CLI session 内回看上一轮：不传 `session_id`，脚本会使用当前 `LINUX_AGENT_SESSION_ID`，默认读取当前轮之前的一轮。
- 回看指定历史 session 的最后一轮：传 `session_id`，并设置 `turn_offset: 0`。
- 回看更早轮次：增大 `turn_offset`，例如 `1` 表示倒数第二轮。

返回中的 `commands` 包含入口命令、terminal 命令、计划步骤命令或 skill；`outputs` 包含 `terminal_executed`、`script_executed`、`step_succeeded`、`step_failed` 等事件中的输出和错误预览。
