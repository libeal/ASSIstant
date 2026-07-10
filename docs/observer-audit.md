# 审计与 Observer 运行说明

本文记录当前审计层和内核 observer 的真实行为，供 CLI、Web、skill 和测试维护时使用。执行前风险判断仍由 policy 完成；audit 负责记录事实，observer 负责在系统支持时补充运行时内核观察结果。

## 职责边界

- `lib/audit.sh` 写入 JSONL session，按 `policies/audit-boundaries.json` 控制可记录事件、payload 模式、文本截断和 observer 汇总字段。
- `lib/observer.sh` 在 auditd 可用时安装 syscall 规则，执行结束后用 `ausearch` 汇总实际观察到的执行和文件事件。
- `lib/policy.sh` 是执行前审查，不能替代 observer；observer 是执行时/执行后观察，不能替代 policy。
- Web 只通过 `/api/observer/bootstrap` 帮无 TTY 的后端刷新 sudo 凭据并验证 `auditctl -s`；每个 session 的规则安装和清理由 CLI core 完成。

## 生命周期

1. `linux_agent_start_session` 创建审计日志，写入 `session_started`。
2. 如果 observer 未禁用，`linux_agent_observer_session_start` 执行预检：检查 `auditctl`、`ausearch`、sudo 策略和 auditd 权限。
3. 预检可用时，observer 按审计边界中的 syscall 列表安装 auditd 规则，并写入 `observer_session_started`。
4. 每个实际执行过程由 `linux_agent_run_observed_process` 包裹，写入 `execution_started` 和 `execution_finished` marker。
5. `linux_agent_finish_session` 清理 auditd 规则，执行 `ausearch -k <audit_key>`，解析并写入 `observer_session_finished`。
6. 如果 auditd、sudo 或内核接口不可用，主业务流程继续执行，但写入 `observer_unavailable` 或 `observer_failed` 作为降级事实。

## 身份过滤

observer 规则使用 audit `auid` 过滤，优先读取 `/proc/self/loginuid`。该值有效且不是 `4294967295` 时用于 `-F auid=<loginuid>`；否则回退到当前进程的 `id -u`。

这样可以覆盖 `sudo` 启动为 root 时 `id -u=0`、但内核 audit 仍按原登录用户 `auid` 记录的场景。审计摘要会保留：

- `uid`: 当前进程有效 UID。
- `audit_uid`: 实际用于 auditd `auid` 过滤的 UID。
- `identity_filter`: 当前为 `auid`。

## 事件汇总

`ausearch` 输出里同一次 exec 通常包含同一 record id 的 `SYSCALL` 和 `EXECVE` 两类记录。解析逻辑按 `msg=audit(...:<record-id>)` 去重：

- `exec_count` 统计唯一 exec record，而不是原始行数。
- `file_event_count` 只统计 `PATH` 记录或明确的文件类 syscall，不把 `execve` 的 `SYSCALL` 行误算为文件事件。
- `processes` 和 `file_events` 只输出受 `observer.max_events` 限制的样本。

## 审计边界

`policies/audit-boundaries.json` 分为两层：

- `observing`: 当前实际记录和观察的字段。
- `allowed_to_observe`: 配置允许选择的最大边界。

默认记录包括 session、command、turn、work/edit/script/terminal、step、agent loop、`script_manual_edit`、execution marker 和 `observer_*` 事件。`script_manual_edit` 用于记录用户在 edit 模式中对 AI 原稿做过人工修改；payload 只保留 skill、script 和 diff 行数摘要，不把完整 diff 写入 safe summary。

## 环境限制

- WSL、容器、无 `CAP_AUDIT_CONTROL` 或没有 auditd 的系统通常会返回 `observer_unavailable`。
- `observer.enabled="disabled"` 会完全跳过 auditd 规则安装，但仍写入禁用状态。
- `observer.privilege="passwordless"` 只使用 `sudo -n`，不会交互式询问密码。
- `observer.privilege="sudo_interactive"` 在 CLI 有 TTY 时可以提示输入 sudo 密码；Web 需要先走 bootstrap。
- observer 降级不是业务失败；它说明当前 session 没有可用的内核级执行观察。

## 验证入口

- `bash tests/observer.sh`: 覆盖 observer 禁用、mock auditd、`auid` 选择、record id 去重、审计边界过滤和失败降级。
- `bash tests/security.sh`: 覆盖审计脱敏、`script_manual_edit` 边界、MCP 安全路径和远程脚本审查。
- `bash bin/agent policy validate audit-boundaries.json`: 校验审计边界策略文件。
