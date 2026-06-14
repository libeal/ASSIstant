# Linux 运维 Agent

这是一个 Bash 实现的 CLI 版 Linux 运维助手。它围绕“结构化计划、人工审批、可审计执行”设计，适合在 Linux 节点上做保守的诊断、巡检、脚本化运维辅助。

## 模式

- `work`: 根据自然语言请求生成 `answer` 或 `work_plan`，计划会逐步展示、审查、审批、执行。
- `edit`: 生成或修改 skill，打开编辑器让用户确认脚本内容，再保存到 `skills/`。
- `script`: 直接执行已登记的 skill 脚本。
- `terminal`: 直接执行本机 shell 命令，输出原样给用户，并写入审计。
- `plan`: 只生成计划，不执行步骤。

## 快速开始

```bash
cp config/config.example.json config/config.json
bash bin/agent
```

常用命令：

```bash
bash bin/agent work "帮我检查磁盘空间是否异常"
bash bin/agent plan "帮我检查磁盘空间是否异常"
bash bin/agent edit "创建一个检查 nginx 日志的 skill"
bash bin/agent script ops-basic/process-inspect '{"pattern":"systemd"}'
bash bin/agent terminal "printf hello"
bash bin/agent doctor
bash bin/agent sense disk
bash bin/agent tools list
bash bin/agent skills validate
bash bin/agent audit <session-id>
bash test_config.sh
```

REPL 内部命令：

```text
/work
/edit
/script
/terminal
/mode
/help
/exit
```

输入 `/` 或 `/前缀` 后回车会打开命令菜单；`/mode` 会打开模式选择菜单。`/exit`、Ctrl+D 和 Ctrl+Z 都会结束本次运行级会话。

## 配置

首次运行时，如果 `config/config.json` 不存在，`lib/config.sh` 会从 `config/config.example.json` 复制一份。

| 字段 | 默认值 | 作用 |
| --- | --- | --- |
| `provider` | `OpenAI-Compatible` | 配置说明字段。 |
| `api_url` | OpenAI Chat Completions URL | Chat Completions 兼容接口地址。 |
| `api_key` | 占位值 | API 密钥；本地 `config/config.json` 被 `.gitignore` 忽略。 |
| `model` | `gpt-4.1-mini` | 调用的模型名。 |
| `request_timeout_sec` | `90` | AI 请求超时时间。 |
| `context_turns` | `6` | 上传给 AI 的历史会话轮数；`0` 表示不带历史。 |
| `audit_mode` | `safe_summary` | 审计写入模式：`safe_summary` 或 `redacted_verbose`。 |
| `audit_text_limit` | `1000` | 审计自由文本截断长度。 |
| `observer.enabled` | `auto` | observer 开关：`auto` 或 `disabled`。 |
| `observer.lifecycle` | `session` | observer 生命周期；当前按会话启动和汇总。 |
| `observer.privilege` | `sudo_interactive` | observer 提权策略：`sudo_interactive`、`passwordless`、`none`。 |
| `observer.max_events` | `200` | observer 会话报告中的事件样本上限。 |
| `skills_dir` | 空字符串 | 自定义 skill 目录；留空使用项目内 `skills/`。 |
| `remote_script_policy` | `download_review` | 远程脚本策略：`download_review` 或 `disabled`。 |

环境变量：

| 变量 | 作用 |
| --- | --- |
| `LINUX_AGENT_OUTPUT_JSON=1` | 将 work、script、terminal、edit 的最终输出切换为机器可读 JSON。 |
| `LINUX_AGENT_MOCK=1` | 不调用真实 AI API，使用内置 mock 响应验证流程。 |
| `EDITOR=<命令>` | 编辑模式打开脚本确认/修改时使用的编辑器。 |

## 总体运行逻辑

1. `bin/agent` 加载 `lib/*.sh`，初始化目录、配置和全局状态。
2. 除 `agent audit` 外，每次运行都会创建一个 JSONL 审计会话。
3. 会话开始后生成独立的 `tmp/<session-id>/` 临时目录，进程结束时只清理自己的临时目录。
4. observer 在会话启动时尝试启用 auditd syscall 观察；不可用时降级为审计事件，不影响业务命令。
5. 业务输入进入对应模式：work、edit、script 或 terminal。
6. 所有进入 AI、审计日志、失败修复上下文的文本都会走脱敏。
7. 进程退出时写入 `command_finished`、`ai_files_manifest`、`observer_session_finished` 和 `session_finished`。

## 上下文与 AI 请求

上下文分成三层：

- 动态 `request_context`: 由 `lib/context.sh` 构造，只包含 `mode`、`conversation_context` 和 `current_request`。
- 运行时 `environment_context`: 由 `lib/sense.sh` 采集并脱敏，不存入动态上下文本体，只在 `lib/ai.sh` 组装最终请求体时临时合并。
- 固定提示材料: `prompts/system.txt` 和 `skills/INDEX.md`，作为 system prompt 发送。

最终发送给 AI 的 Chat Completions messages 包含：

- 系统提示：基础规则和 skill 索引。
- `purpose=<work_plan|edit|repair>`。
- `request_context=<JSON 字符串>`，其中按需带有运行时 `environment_context`。
- 用户消息：当前请求文本。

`ai_files_manifest` 会记录本次会话中进入 AI 请求的本地文件元数据，例如 `prompts/system.txt` 和 `skills/INDEX.md` 的路径、用途、大小和 SHA256；不记录文件正文。

## Work 模式

1. `lib/orchestrator.sh` 记录 `received`。
2. `lib/sense.sh` 根据用户输入识别主题，采集最小必要环境信息。
3. `lib/context.sh` 构造动态请求上下文。
4. `lib/ai.sh` 调用 AI，要求返回 `answer` 或 `work_plan`。
5. 如果返回 `answer`，直接展示回答并记录本轮历史。
6. 如果返回 `work_plan`，`lib/executor.sh` 展示计划并逐步执行。
7. 每个步骤先经过 `lib/policy.sh` 正则审查。
8. 用户可选择执行、拒绝、跳过/修改或终止。
9. 步骤执行通过 observer wrapper 运行，写入 `execution_started` / `execution_finished`。
10. 步骤失败时中断当前计划，请 AI 生成修复建议；修复建议不会自动执行。

支持的步骤执行器：

- `skill_script`: 执行 `skills/` 中登记的脚本。
- `shell`: 执行本机 shell 命令，适合 skill 无法覆盖的只读场景。
- `remote_script`: 只允许 HTTPS 下载，先校验大小、文本类型、SHA256 和预览，再按高风险审批。

## Edit 模式

1. AI 返回 `skill_edit` JSON。
2. `lib/editor.sh` 展示 skill 名称、说明和脚本计划。
3. 每个脚本写入临时编辑文件，并打开 `$EDITOR` 或 `vi`。
4. 用户必须保存后才会继续；未保存可输入修改需求重新生成。
5. 最终脚本再次经过 `lib/policy.sh` 审查。
6. 通过后写入 `skills/<name>/scripts/`，生成 `SKILL.md`，并更新 `skills/INDEX.md`。
7. 提交前在临时目录中 staging，校验通过后再替换正式 skill。

## Script 模式

1. 用户指定 `skill/script` 和 JSON 参数。
2. `lib/skills.sh` 确认脚本同时登记在 `skills/INDEX.md` 和对应 `SKILL.md`。
3. `lib/policy.sh` 审查脚本文本和参数上下文。
4. 用户确认后执行脚本。
5. 执行结果和 observer marker 写入 JSONL。

## Terminal 模式

1. 用户输入会交给 `bash -lc`。
2. 终端模式不走正则阻断或审批。
3. stdout/stderr 原样展示给用户。
4. 审计日志只保存命令文本、退出码和脱敏后的输出预览。

## 安全边界

- AI 只能通过结构化 JSON 返回计划或 skill 编辑包。
- skill 脚本必须登记在 `skills/INDEX.md` 和对应 `SKILL.md` 中。
- 工作模式和脚本模式都会经过 `policies/risk-rules.json` 审查。
- 远程脚本只允许 HTTPS 下载审查，不允许 `curl | sh` 或 `wget | sh`。
- 日志真实清理必须先生成备份建议，再由用户审批。
- `skills/ops-basic/scripts/safe-log-cleanup.sh` 只允许清理真实路径位于 `/var/log` 或 `/tmp` 下的普通文件，拒绝符号链接和关键日志名。
- 项目临时目录按会话隔离，进程结束时只清理当前会话自己的临时目录。

## 审计与 Observer

`logs/<session-id>.jsonl` 是唯一新的持久审计源。`agent audit <session-id>` 只读历史 JSONL，不会递归创建新会话或触发 observer。

审计内容包括：

- 会话 ID、开始时间、最终状态。
- 用户请求、模式切换、计划生成和步骤状态。
- 策略审查结果和风险发现。
- AI 文件清单 `ai_files_manifest`。
- observer 状态、backend、`audit_key`、`reason_code`、`diagnostic`。
- `exec_count`、`file_event_count`、`execution_finished` 等计数。

observer 可用时，会话开始安装带唯一 `audit_key` 的临时 auditd syscall 规则，会话结束清理规则并运行 `ausearch -k <audit_key>` 汇总事件。observer 不可用或 sudo/auditctl 失败时写入 `observer_unavailable`，但不改变业务命令退出码。

## 文件职责

### 根目录

- `.gitignore`: 忽略本地配置和运行产物，如 `config/config.json`、`logs/`、`sessions/`、`tmp/`。
- `README.md`: 项目说明、运行方式、运行逻辑和文件职责。
- `test_config.sh`: 本地配置校验脚本；默认不访问网络，`--live` 才验证 API 连通性。

### `bin/`

- `bin/agent`: 唯一 CLI 入口。负责加载库文件、初始化环境、创建会话、安装 trap、路由子命令和 REPL。

### `config/`

- `config/config.example.json`: 配置模板。首次运行时会复制为本地 `config/config.json`。

### `prompts/`

- `prompts/system.txt`: AI 系统提示，定义输出 schema、执行约束、编辑模式和修复模式规则。

### `policies/`

- `policies/risk-rules.json`: 正则风险规则，包含阻断规则、警告规则、远程脚本规则、保护路径和保护服务。

### `lib/`

- `lib/common.sh`: 根目录、日志目录、skill 目录和临时目录初始化；通用输出；临时目录清理；文本和 JSON 脱敏。
- `lib/config.sh`: 加载 `config/config.json`，提供配置读取和默认值读取。
- `lib/audit.sh`: 创建审计会话、写入 JSONL、记录命令/turn/步骤状态、渲染审计报告。
- `lib/context.sh`: 维护内存会话历史窗口；构造动态请求上下文；合并最终 AI payload 上下文。
- `lib/sense.sh`: 根据主题采集最小必要环境信息，包括磁盘、资源、进程、网络、服务、日志和权限。
- `lib/skills.sh`: 解析 skill 引用、定位脚本、校验登记状态、执行 skill 脚本、校验 skill 目录。
- `lib/doctor.sh`: 检查必需命令、可选命令、配置 JSON 和 skill 目录。
- `lib/ai.sh`: 构造系统提示、记录 AI 文件清单、调用 OpenAI-compatible API、校验和 mock 模型响应。
- `lib/policy.sh`: 读取风险规则，对命令、脚本、远程脚本和步骤做审查。
- `lib/observer.sh`: auditd observer 预检、规则安装/清理、`ausearch` 汇总和执行 marker。
- `lib/executor.sh`: 工作计划执行状态机；审批、远程脚本下载审查、步骤执行、失败修复、计划修改。
- `lib/editor.sh`: skill 编辑模式；打开编辑器、记录用户 diff、staging、校验和提交 skill。
- `lib/interactive.sh`: REPL 输入、斜杠菜单和模式选择菜单。
- `lib/orchestrator.sh`: 四种业务模式的高层编排。

### `skills/`

- `skills/INDEX.md`: 可用 skill 索引，作为 AI 固定提示附录，也是脚本模式的登记依据。
- `skills/ops-basic/SKILL.md`: 内置基础运维 skill 的说明。
- `skills/ops-basic/scripts/disk-hotspots.sh`: 采集指定路径的磁盘使用、一级目录占用和大文件。
- `skills/ops-basic/scripts/resource-inspect.sh`: 查看负载、CPU、内存和高占用进程。
- `skills/ops-basic/scripts/process-inspect.sh`: 查看进程列表、匹配进程和僵尸进程。
- `skills/ops-basic/scripts/service-inspect.sh`: 查看 systemd 服务状态和失败服务。
- `skills/ops-basic/scripts/service-restart-plan.sh`: 生成服务重启前的只读预检计划，不直接重启。
- `skills/ops-basic/scripts/log-search.sh`: 检索 `/var/log` 下日志，可选读取 journal 样本。
- `skills/ops-basic/scripts/log-cleanup-plan.sh`: 扫描 `/var/log` 或 `/tmp` 下的大日志，生成清理候选和排除项。
- `skills/ops-basic/scripts/safe-log-cleanup.sh`: 对允许范围内的非关键普通日志文件做 dry-run 或截断。
- `skills/ops-basic/scripts/config-backup.sh`: 为目标路径生成 tar.gz 备份。

### `tests/`

- `tests/smoke.sh`: 覆盖主要 CLI 入口、mock 工作流、JSON 输出和 AI 文件清单。
- `tests/security.sh`: 覆盖脱敏、审计摘要、上下文边界、远程脚本审查和临时目录清理。
- `tests/workflow.sh`: 覆盖失败中断、拒绝、跳过、修改需求、终止和输出渲染。
- `tests/policy.sh`: 覆盖风险规则、保护路径、远程脚本阻断和风险合并。
- `tests/tools.sh`: 覆盖本地工具、skill 登记、日志清理边界和 doctor。
- `tests/observer.sh`: 覆盖 observer 禁用、mock auditd、事件汇总和失败降级。
- `tests/interactive.sh`: 覆盖 REPL 菜单、模式切换、终端模式和编辑模式。

### 运行时目录

- `logs/`: JSONL 审计日志。
- `tmp/`: 会话级临时目录根；每次 `bin/agent` 运行使用 `tmp/<session-id>/`。
- `sessions/`: 旧版 Markdown 摘要目录；新会话不再生成。

## 测试

```bash
bash tests/smoke.sh
bash tests/security.sh
bash tests/workflow.sh
bash tests/policy.sh
bash tests/tools.sh
bash tests/observer.sh
bash tests/interactive.sh
bash bin/agent doctor
bash test_config.sh
```

完整回归可以串联运行：

```bash
bash tests/smoke.sh &&
bash tests/security.sh &&
bash tests/workflow.sh &&
bash tests/policy.sh &&
bash tests/tools.sh &&
bash tests/observer.sh &&
bash tests/interactive.sh
```
