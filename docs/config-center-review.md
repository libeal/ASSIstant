# Web 配置中心审查记录

## 结论

Web 配置中心当前暴露的可写配置项都能追踪到后端写入白名单和运行时消费点，没有发现仍展示但完全无效的开关。

本次发现并修复 1 个一致性问题：`observer.privilege` 在运行时默认值为 `sudo_interactive`，但 Web 配置中心缺省显示为空字符串。现在 `web/server.py` 的公开配置状态已与 `lib/observer.sh` 对齐。

## 字段映射

| 配置项 | Web 定义 | 后端写入 | 运行时消费 |
| --- | --- | --- | --- |
| `provider` | `web/static/modules/policy-config.js` | `web/server.py` `CONFIG_WRITABLE_FIELDS` | `web/server.py` provider/model endpoints, `lib/ai.sh` 请求配置 |
| `api_url` | 同上 | 同上 | `lib/ai.sh`, Web model list |
| `api_key` | 同上，write-only | `web/server.py` `write_api_key_secret()` | `lib/config.sh`, `lib/ai.sh` |
| `model` | 同上 | `CONFIG_WRITABLE_FIELDS` | `lib/ai.sh` |
| `request_timeout_sec` | 同上 | 同上 | `lib/ai.sh`, Web model list timeout |
| `context_turns` | 同上 | 同上 | `lib/context.sh`, `web/server.py` session context |
| `agent_loop.enabled_for_work` | 同上 | 同上 | work 入口是否启用 agent loop |
| `agent_loop.observation_text_limit` | 同上 | 同上 | `lib/orchestrator.sh` observation 摘要 |
| `agent_loop.checkpoint_turns` | 同上 | 同上 | `lib/orchestrator.sh` checkpoint 频率 |
| `agent_loop.thinking_trace_enabled` | 同上 | 同上 | `lib/orchestrator.sh`, Web thinking summary 展示 |
| `approvals.auto.*` | 同上 | 同上 | `lib/executor.sh` 低风险自动批准能力判断 |
| `audit_mode` | 同上 | 同上 | `lib/common.sh`, `lib/audit.sh` |
| `audit_text_limit` | 同上 | 同上 | `lib/common.sh`, `lib/audit.sh` |
| `observer.enabled` | 同上 | 同上 | `lib/observer.sh`, Web observer bootstrap |
| `observer.privilege` | 同上 | 同上 | `lib/observer.sh`, Web observer bootstrap |
| `observer.max_events` | 同上 | 同上 | `lib/observer.sh` |
| `execution.min_privilege_proxy` | 同上 | 同上 | `lib/executor.sh` |
| `execution.least_privilege_user` | 同上 | 同上 | `lib/executor.sh` |
| `remote_script_policy` | 同上 | 同上 | `lib/executor.sh` remote script path |
| `remote.allow_api_key_transmission` | 同上，仅 remote runtime 有效 | 同上 | `lib/ai.sh`、Web model list 与 remote 子进程密钥注入门禁 |
| `skills_dir` | 同上 | 同上 | `lib/skills.sh`, `lib/editor.sh` |

## 语义边界

`approvals.auto.*` 不是绕过策略的开关。它们只在策略审查通过、风险为 low、且步骤本身不强制审批时，允许对应能力自动执行。critical/high/medium 或任何被 policy/AST 阻断的步骤仍会暂停或失败。

旧字段 `agent_loop.auto_execute_low_risk` 和 `agent_loop.auto_execute_shell_low_risk` 不再作为配置中心开关暴露；测试覆盖了这些遗留字段不会从 Web 配置状态泄漏回 UI。

## 验证

- `tests/web_server.sh` 覆盖配置读取、密钥不回显、`observer.privilege` 缺省值、布尔开关更新、审计文本限制更新和自动批准开关更新。
- `rg` 检查确认配置中心字段能追踪到 `web/server.py` 写入白名单和 `lib/` 运行时消费点。
- `config/config.example.json` 与 Web 默认值保持一致。
