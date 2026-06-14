# Linux 运维 Agent

这是一个 Bash 实现的 CLI 版 Linux 运维助手。它以四模式 REPL 为核心：

- `work`: AI 生成结构化工作计划，逐步审查、审批、执行。
- `edit`: 创建或修改 skill，强制打开编辑器供人工确认。
- `script`: 直接运行已登记的 skill 脚本。
- `terminal`: 临时直接控制本机 shell，输出原样展示并写入审计。

## 安全与审计模型

项目的安全边界由四层组成：

1. **结构化计划**：AI 只能返回 `answer`、`work_plan` 或 `skill_edit`，工作模式按步骤执行。
2. **脚本登记**：优先使用 `skills/` 中登记的脚本；未登记脚本不能直接以 skill 方式执行。
3. **策略审查与人工确认**：工作模式和脚本模式会经过 `policies/risk-rules.json` 正则审查，并要求用户确认执行。
4. **Observer-first 审计**：每次 `bin/agent` 运行写入一个 `logs/<session-id>.jsonl`，并在进程启动时启动 auditd observer。observer 仅对 `auditctl` / `ausearch` 按需使用 sudo，主 Agent 和用户命令仍以普通权限运行。

脱敏是独立安全边界：用户输入、AI 上下文、环境感知、远程脚本预览、失败修复上下文、observer 错误输出和审计日志都会经过 `linux_agent_sanitize_text/json` 处理。

新会话不再生成 `sessions/*.md`。历史 `sessions/` 文件是旧版 Markdown 摘要产物，不迁移、不自动删除。

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

输入 `/` 或 `/前缀` 后回车会打开内置命令菜单；`/mode` 会打开模式选择菜单。

REPL 中 `/exit`、Ctrl+D 和 Ctrl+Z 都会结束本次运行级会话；Ctrl+Z 在本项目内按退出处理，不保留 shell 挂起语义。

## 配置与开关

### 环境变量

| 开关 | 默认值 | 作用 |
| --- | --- | --- |
| `LINUX_AGENT_OUTPUT_JSON=1` | 关闭 | 将 work、script、terminal、edit 的最终输出切换为机器可读 JSON。 |
| `LINUX_AGENT_MOCK=1` | 关闭 | 不调用真实 AI API，使用内置 mock 响应验证流程。 |
| `EDITOR=<命令>` | 系统 `vi` | 编辑模式打开脚本确认/修改时使用的编辑器。 |

示例：

```bash
LINUX_AGENT_OUTPUT_JSON=1 bash bin/agent terminal "printf hello"
LINUX_AGENT_MOCK=1 bash bin/agent work "帮我检查磁盘空间是否异常"
EDITOR=nano bash bin/agent edit "创建一个 skill"
```

### `config/config.json`

首次运行时，如果 `config/config.json` 不存在，`lib/config.sh` 会从 `config/config.example.json` 复制一份。

| 字段 | 默认值 | 作用 |
| --- | --- | --- |
| `provider` | `OpenAI-Compatible` | 配置说明字段。 |
| `api_url` | OpenAI Chat Completions URL | Chat Completions 兼容接口地址。 |
| `api_key` | 占位值 | API 密钥；本地 `config/config.json` 被 `.gitignore` 忽略。 |
| `model` | `gpt-4.1-mini` | 调用的模型名。 |
| `request_timeout_sec` | `90` | AI 请求超时时间。 |
| `context_turns` | `6` | 上传给 AI 的历史会话轮数；`0` 表示不带历史。 |
| `audit_mode` | `safe_summary` | 审计写入模式：`safe_summary` 或 `redacted_verbose`。两者都会脱敏。 |
| `audit_text_limit` | `1000` | 审计自由文本截断长度。 |
| `observer.enabled` | `auto` | observer 开关：`auto` 或 `disabled`。 |
| `observer.lifecycle` | `session` | observer 生命周期；当前按会话启动和汇总。 |
| `observer.privilege` | `sudo_interactive` | observer 提权策略：`sudo_interactive`、`passwordless`、`none`。 |
| `observer.max_events` | `200` | observer 会话报告中的进程/文件事件样本上限。 |
| `skills_dir` | 空字符串 | 自定义 skill 目录；留空使用项目内 `skills/`。 |
| `remote_script_policy` | `download_review` | 远程脚本策略：`download_review` 或 `disabled`。 |

## 运行流程

### Work 模式

1. `bin/agent` 进程启动时创建 JSONL 审计会话并写入 `command_started`。
2. `lib/observer.sh` 立即尝试为当前运行启动 auditd observer；REPL 下不会等到第一条问题后才申请 sudo。
3. REPL 中每条业务输入写入 `turn_started` / `turn_finished`；一次性命令只写入本次命令的运行级会话。
4. `lib/sense.sh` 采集最小必要环境信息。
5. `lib/context.sh` 脱敏用户输入、历史和环境信息，构造动态 AI 请求上下文；固定的 `skills/INDEX.md` 不写入该上下文。
6. `lib/ai.sh` 将系统提示和 skill 索引作为固定提示材料发送，然后调用 OpenAI-compatible API 请求 `answer` 或 `work_plan`。
7. `lib/executor.sh` 展示计划；每个步骤先经 `lib/policy.sh` 审查，再由用户选择执行、拒绝、跳过/修改或终止。
8. 执行过程写入 `execution_started` / `execution_finished` marker。
9. 进程退出时 observer 汇总 auditd 事件，写入 `observer_session_finished`，然后写入 `session_finished`。
10. 若步骤失败，当前计划中断，失败摘要会脱敏后发送给 AI 生成修复建议；修复建议不会自动执行。

### Edit 模式

1. AI 生成 `skill_edit` JSON。
2. `lib/editor.sh` 展示候选脚本，并强制打开 `$EDITOR` 或 `vi`。
3. 用户保存后，最终脚本仍需通过 `lib/policy.sh` 审查。
4. 系统更新 `skills/<name>/SKILL.md` 和 `skills/INDEX.md`，并校验 skill 结构。
5. 用户修改 diff、保存结果、observer 会话报告都会进入 JSONL 审计。

### Script 模式

1. 用户指定 `skill/script` 和 JSON 参数。
2. `lib/skills.sh` 确认脚本同时登记在 `skills/INDEX.md` 和对应 `SKILL.md`。
3. `lib/policy.sh` 审查脚本文本和参数上下文。
4. 用户确认后执行脚本，执行结果和 observer marker 写入 JSONL。

### Terminal 模式

1. 用户通过 `/terminal` 或 `agent terminal "<shell命令>"` 执行本机 shell 命令。
2. 终端模式不经过正则阻断或审批。
3. stdout/stderr 原样呈现给本地用户。
4. 命令文本、退出码、脱敏后的输出预览和 observer marker 写入 JSONL。

## 审计与 Observer

`logs/<session-id>.jsonl` 是唯一新的持久审计源。除 `agent audit <session-id>` 外，每次启动 `bin/agent` 都会创建一个运行级会话；`agent audit` 只读历史 JSONL，不会递归创建新会话或触发 observer。

- 会话 ID、开始时间、最终状态。
- observer 状态、backend、`audit_key`。
- observer `reason_code` 和 `diagnostic`，用于区分 sudo 凭据失败、auditctl 权限失败、auditd 缺失等原因。
- `ai_files_manifest`：本次会话中进入 AI 请求的本地文件元数据，包括路径、用途、大小和 SHA256；不记录文件正文。
- `exec_count`、`file_event_count`。
- `execution_finished`、`observer_unavailable`、`observer_failed` 计数。
- 逐行脱敏后的 JSONL 审计流。

observer 可用时，会话开始安装带唯一 `audit_key` 的临时 auditd syscall 规则，会话结束清理规则并运行 `ausearch -k <audit_key>` 汇总事件。observer 不可用或 sudo/auditctl 失败时会写入 `observer_unavailable`，但不会改变业务命令的退出码。如果 sudo 密码正确但 `auditctl -s` 返回 `Operation not permitted`，日志会记录 `reason_code="auditctl_permission_denied"`，通常表示容器、WSL、缺少 `CAP_AUDIT_CONTROL` 或内核 audit 接口不可用。

## 目录结构

### 根目录

- `.gitignore`: 忽略本地配置和运行产物：`config/config.json`、`logs/`、`sessions/`、`tmp/`。
- `README.md`: 项目说明。
- `test_config.sh`: 本地配置校验脚本；默认不访问网络，`--live` 才验证 API 连通性。

### `bin/`

- `bin/agent`: 唯一 CLI 入口，负责加载 `lib/*.sh`、初始化环境和配置、提供 REPL 与子命令路由。

### `lib/`

- `common.sh`: 环境初始化、输出函数、通用脱敏器。
- `config.sh`: 配置加载和默认值读取。
- `audit.sh`: JSONL 审计写入、session id 管理、`agent audit` 报告渲染。
- `observer.sh`: 会话级 auditd observer、execution marker、`ausearch` 汇总。
- `context.sh`: AI 请求上下文和内存历史窗口。
- `sense.sh`: 最小必要环境感知。
- `skills.sh`: skill 引用解析、登记校验和脚本执行。
- `doctor.sh`: 依赖、配置和 skill 自检。
- `ai.sh`: AI API 接入、schema 校验和 mock 响应。
- `policy.sh`: 正则风险审查。
- `executor.sh`: 工作计划执行状态机。
- `editor.sh`: skill 编辑模式。
- `interactive.sh`: REPL 菜单和输入辅助。
- `orchestrator.sh`: 四模式高层编排。

### `skills/` 与 `tools/local/`

- `skills/INDEX.md`: 可用 skill 索引，工作模式会作为固定提示材料上传给 AI，脚本模式也用它确认登记状态。
- `skills/ops-basic/SKILL.md`: 内置基础运维 skill 说明。
- `skills/ops-basic/scripts/*.sh`: skill 包装脚本。
- `tools/local/*.sh`: 本地确定性后端脚本，负责具体 Linux 检查和安全边界。

### 运行时目录

- `logs/`: JSONL 审计日志。新会话都会生成 `.jsonl` 文件。
- `tmp/`: 远程脚本下载、终端输出捕获和编辑模式临时文件。

## 测试

```bash
bash tests/smoke.sh
bash tests/policy.sh
bash tests/tools.sh
bash tests/security.sh
bash tests/observer.sh
bash tests/workflow.sh
bash tests/interactive.sh
bash bin/agent doctor
bash test_config.sh
```

测试覆盖：

- `tests/smoke.sh`: mock 工作模式、plan 模式、脚本模式和 skill 索引。
- `tests/policy.sh`: 关键路径阻断、远程管道执行阻断、警告级规则。
- `tests/tools.sh`: 本地工具和 skill 脚本边界。
- `tests/security.sh`: 脱敏、审计、远程脚本下载审查。
- `tests/observer.sh`: observer 禁用、无权限降级、会话级 mock auditd、execution marker、`ausearch` 摘要解析。
- `tests/workflow.sh`: 失败中断、修复建议、拒绝、跳过、修改需求和终止。
- `tests/interactive.sh`: `/` 菜单、终端模式、编辑模式和审计记录。

依赖：

- 必需：`bash`、`jq`、`curl`、`find`、`du`、`df`、`ps`、`grep`、`tar`
- 可选：`systemctl`、`journalctl`、`ss`、`ip`、`lsof`、`sudo`、`auditctl`、`ausearch`、`auditd`

缺少可选命令只会减少环境感知或 observer 能力，不会让 `doctor` 失败。
