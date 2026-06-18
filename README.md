# Linux 运维 Agent

这是一个 Bash 实现的 CLI 版 Linux 运维助手。它围绕“结构化计划、人工审批、可审计执行”设计，适合在 Linux 节点上做保守的诊断、巡检、脚本化运维辅助。

## 模式

- `work`: 根据自然语言请求生成 `answer` 或 `work_plan`，并可在执行后基于观察结果受控迭代；低风险已登记 skill 可自动执行。
- `edit`: 生成或修改 skill，打开编辑器让用户确认脚本内容，再保存到 `skills/`。
- `script`: 审查并在确认后执行已登记的 skill 脚本。
- `terminal`: 对本机 shell 命令做策略审查，低风险直接执行，高风险或需权限命令请求确认，并写入审计。

## 快速开始

```bash
cp config/config.example.json config/config.json
bash bin/agent
```

常用命令：

```bash
bash bin/agent work "帮我检查磁盘空间是否异常"
bash bin/agent edit "创建一个检查 nginx 日志的 skill"
bash bin/agent script ops-basic/process-inspect '{"pattern":"systemd"}'
bash bin/agent terminal "printf hello"
bash bin/agent doctor
bash bin/agent sense disk
bash bin/agent tools list
bash bin/agent skills validate
bash bin/agent audit <session-id>
bash bin/agent-web
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

首次运行时，如果 `config/config.json` 不存在，`lib/config.sh` 会从 `config/config.example.json` 复制一份。实际运行只读取 `config/config.json`，示例文件只作为模板。

最小可用配置通常只需要改三项：

```json
{
  "api_url": "https://api.openai.com/v1/chat/completions",
  "api_key": "你的密钥",
  "model": "gpt-4.1-mini"
}
```

### 配置文件开关

| 字段 | 默认值 | 有效值 | 作用 |
| --- | --- | --- | --- |
| `api_url` | `https://api.openai.com/v1/chat/completions` | Chat Completions 兼容 URL | AI 请求地址。支持 OpenAI-compatible 接口。 |
| `api_key` | `please-set-your-api-key` | 非空字符串 | API 密钥。本地 `config/config.json` 被 `.gitignore` 忽略；占位值会让 AI 调用失败并返回明确错误。 |
| `model` | `gpt-4.1-mini` | 接口支持的模型名 | AI 请求中的 `model`。 |
| `request_timeout_sec` | `90` | 正整数 | `curl --max-time` 超时时间；请求失败会返回明确错误。 |
| `context_turns` | `6` | 非负整数 | 发送给 AI 的历史轮数窗口；`0` 表示不带历史。 |
| `agent_loop.enabled_for_work` | `true` | `true`、`false` | 是否让 `work` 模式在计划执行后进入反思/续写循环。 |
| `agent_loop.auto_execute_low_risk` | `true` | `true`、`false` | 是否自动执行 policy 判定为 clean low-risk 的步骤。默认只自动执行已登记 skill。 |
| `agent_loop.auto_execute_shell_low_risk` | `false` | `true`、`false` | 是否允许 clean low-risk shell 步骤自动执行；默认关闭，shell 仍需人工确认。 |
| `agent_loop.observation_text_limit` | `4000` | 正整数 | 每轮 observation 中字符串摘要的最大长度。 |
| `agent_loop.thinking_trace_enabled` | `false` | `true`、`false` | 是否允许模型返回简短 `thinking_summary` 并保存到 `/tmp/<session-id>/thinking/`；不进入上下文和审计。 |
| `agent_loop.checkpoint_turns` | `0` | 非负整数 | 大于 0 时每隔该轮数请求继续授权；`0` 表示使用 `context_turns`，非法或小于 1 时回退到 `6`。 |
| `audit_mode` | `safe_summary` | `safe_summary`、`redacted_verbose` | JSONL 审计写入模式。未知值会按 `safe_summary` 处理；`policies/audit-boundaries.json` 中的合法 `observing.audit_payload_mode` 会覆盖该默认值。 |
| `audit_text_limit` | `1000` | 正整数 | 审计、上下文、输出预览的脱敏后文本截断长度；`policies/audit-boundaries.json` 中的合法 `observing.audit_text_limit` 会覆盖该默认值。 |
| `observer.enabled` | `auto` | `auto`、`disabled` | observer 总开关。`auto` 会尝试启用 auditd；失败只记录降级事件。 |
| `observer.privilege` | `sudo_interactive` | `sudo_interactive`、`passwordless`、`none` | 非 root 用户启用 auditd observer 时的 sudo 策略。 |
| `observer.max_events` | `200` | 正整数 | `ausearch` 结果解析后保留的事件样本上限；非法值回退到 `200`。 |
| `skills_dir` | 空字符串 | 目录路径或空字符串 | 自定义 skill 根目录；留空使用项目内 `skills/`。 |
| `remote_script_policy` | `download_review` | `download_review`、`disabled` | 远程脚本步骤策略。`download_review` 表示只允许 HTTPS 下载后预览、哈希和审批；`disabled` 表示完全禁用。 |
| `web.enabled` | `true` | `true`、`false` | 是否允许 `bin/agent-web` 启动本机 Web 控制台。 |
| `web.host` | `127.0.0.1` | 主机名或 IP | Web 控制台监听地址。默认只监听本机，外部访问建议走 SSH 隧道或反向代理。 |
| `web.port` | `8765` | `1`-`65535` | Web 控制台监听端口。 |
| `web.token` | 空字符串 | 字符串 | Web API Bearer token。留空时 `bin/agent-web` 会为本次运行生成临时 token 并打印到终端。 |
| `web.job_retention_hours` | `24` | 正整数 | Web job 状态文件在 `tmp/web/jobs/` 中的保留小时数。 |

`test_config.sh` 可以检查这些配置：

```bash
bash test_config.sh
bash test_config.sh --live
```

默认检查不会访问网络；`--live` 会用 `config.json` 中的 `api_url`、`model` 和 `api_key` 发送一次最小请求。

### 环境变量开关

| 变量 | 示例 | 作用 |
| --- | --- | --- |
| `EDITOR` | `EDITOR=nano` | 编辑模式打开脚本确认文件时使用的编辑器。未设置时只回退到 `vi`；当前不读取 `VISUAL`。 |
| `LINUX_AGENT_OUTPUT_JSON` | `LINUX_AGENT_OUTPUT_JSON=1` | 将 `work`、`script`、`terminal`、`edit` 的最终输出切换为机器可读 JSON。 |

内部运行状态变量如 `LINUX_AGENT_TMP_DIR`、`LINUX_AGENT_SESSION_ID`、`LINUX_AGENT_AUDIT_LOG` 由程序自己设置，不建议作为外部配置入口。

## Web 控制台

Web 控制台是 CLI 的本机前端外壳，默认只管理当前服务器，不做多节点控制：

```bash
bash bin/agent-web
```

启动后访问 `http://127.0.0.1:8765/`，在页面右上角输入启动日志中打印的 token。Web API 使用 `Authorization: Bearer <token>`，静态页面不需要认证，所有 `/api/` 请求都需要认证。

Web 后端只使用 Python 标准库，不引入 npm、pip 或数据库。它通过 `bash bin/agent api ...` 调用同一套 Bash 核心能力，长任务状态写入 `tmp/web/jobs/`。CLI 仍可独立运行，不依赖 Web 服务。

如果启动时报端口已被占用，说明已有进程正在监听 `web.host:web.port`。停止旧的 `agent-web` 进程，或修改 `config/config.json` 的 `web.port` 后重试
```bash
ss -ltnp 'sport = :8765'
kill -CONT <PID>
kill -TERM <PID>
```

Web 覆盖的主要视图：

- Work: 输入自然语言请求并执行；如果步骤需要人工审批，页面会展示计划和决策控件，用户确认后继续执行同一份计划。
- Script: 选择已登记 skill，审查参数和脚本后执行。
- Terminal: 执行本机命令并查看 stdout/stderr 预览。
- Edit: 生成 skill，在浏览器中编辑脚本，审查后保存。
- Policy: 查看 `policies/` 下的 JSON 策略文件、风险规则概览和 audit 检测边界；保存策略文件前必须完成 sudo 校验。
- Audit: 查看 JSONL 审计会话和报告。
- Doctor: 检查依赖、配置和 skill 目录。

### CLI、API 与 Web 功能对照

CLI 是项目核心；Web 通过 `bash bin/agent api ...` 调用同一套 Bash 能力，只额外提供浏览器中的状态展示、异步 job、筛选和编辑体验。

| 功能 | CLI 入口 | API 入口 | Web 对应 | 关系 |
| --- | --- | --- | --- | --- |
| work 自然语言任务 | `agent work` / REPL `/work` | `api work run` | Work 工作台 | 同一套计划、审批、执行、反思循环；Web 增加时间线、审批抽屉、挂起轮询和 thinking 摘要展示。 |
| script 执行 | `agent script` / REPL `/script` | `api script review/run` | Skill 库 > script 运行 | 同一套 skill 登记校验、参数 JSON 校验、策略审查和 observer 执行；Web 增加脚本选择器、单独审查按钮和异步中止。 |
| terminal 命令 | `agent terminal` / REPL `/terminal` | `api terminal review/run` | Work 工作台 > terminal 直接命令 | 同一套 `risk-rules.json` 审查、阻断和人工确认规则；Web 增加预审结果展示和审批抽屉。 |
| edit 生成 skill | `agent edit` / REPL `/edit` | `api edit plan/review/apply` | Skill 库 > edit 编辑 | CLI 使用 `$EDITOR` 或 `vi` 人工确认脚本；Web 使用浏览器内联编辑器，但保存前仍走同一套策略审查、staging 和 skill 校验。 |
| tools / skills | `agent tools list`、`agent skills validate` | `api tools list`、`api skills validate` | Skill 目录、脚本详情、Markdown 预览 | Web 只做浏览和可视化，不改变 CLI 的登记依据。 |
| audit | `agent audit <session-id>` | `api audit list/read` | 审计与回放 | 同读 `logs/*.jsonl`；Web 增加筛选、指标和报告导出。 |
| doctor / sense | `agent doctor`、`agent sense` | `api doctor run`、`api sense get` | 配置中心、环境概览 | Web 调用 CLI 诊断能力并展示摘要。 |
| config / policy | `test_config.sh`、手工编辑配置/策略 | Web 后端专用 API | 配置中心、策略编辑器 | Web 独立提供浏览器编辑体验；写策略前需 sudo 校验，CLI 运行不依赖 Web。 |

Web 的策略编辑器默认只读。它只允许访问 `policies/` 下的 JSON 文件，写入时后端会先校验 sudo 权限，sudo 密码只保存在当前浏览器页面内存中，不写入 `localStorage`、配置文件或日志。

机器可读 API 也可直接调用：

```bash
bash bin/agent api health
bash bin/agent api tools list
bash bin/agent api work run '{"input":"查看cpu占用"}'
bash bin/agent api script review '{"ref":"ops-basic/resource-inspect","arguments":{"top_n":1}}'
```

## curl | bash 可行性

`curl | bash` 技术上可行：curl 输出会通过 pipe buffer 流式送入 bash，bash 可以边读边执行。更稳妥的实现方式是把第一阶段 bootstrap 控制得很小，只负责版本选择、manifest 下载、hash 校验和安装入口。

渐进式 skills 也可行：先下载 `skills/INDEX.md` 和必要 manifest，需要执行某个 skill 时再按引用下载对应 `SKILL.md`、脚本和校验信息。该分发机制尚未实现；当前远程脚本仍遵循 `remote_script_policy`，不允许绕过“下载、预览、哈希、审批”的安全边界。





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

- 动态 `request_context`: 由 `lib/context.sh` 构造，包含 `mode`、`conversation_context`、`current_request` 和 agent loop 开关摘要。
- 运行时 `environment_context`: 由 `lib/sense.sh` 采集并脱敏，不存入动态上下文本体，只在 `lib/ai.sh` 组装最终请求体时临时合并。
- 迭代 observation: `work_reflect` 阶段会临时附加本轮计划、步骤结果、skill 返回摘要和失败信息，不写入会话历史。
- 固定提示材料: `prompts/system.txt` 和 `skills/INDEX.md`，作为 system prompt 发送。

最终发送给 AI 的 Chat Completions messages 包含：

- 系统提示：基础规则和 skill 索引。
- `purpose=<work_plan|work_reflect|edit|repair>`。
- `request_context=<JSON 字符串>`，其中按需带有运行时 `environment_context`。
- 用户消息：当前请求文本。

`ai_files_manifest` 会记录本次会话中进入 AI 请求的本地文件元数据，例如 `prompts/system.txt` 和 `skills/INDEX.md` 的路径、用途、大小和 SHA256；不记录文件正文。

## Work 模式

1. `lib/orchestrator.sh` 记录 `received`。
2. `lib/sense.sh` 根据用户输入识别主题，采集最小必要环境信息。
3. `lib/context.sh` 构造动态请求上下文。
4. `lib/ai.sh` 调用 AI，要求返回 `answer` 或 `work_plan`；配置缺失、请求失败或响应不合法时直接失败，不生成测试兜底计划。
5. 如果返回 `answer`，直接展示回答并记录本轮历史。
6. 如果返回 `work_plan`，`lib/executor.sh` 展示计划并逐步执行。
7. 每个步骤先经过 `lib/policy.sh` 正则审查。
8. clean low-risk 的已登记 `skill_script` 会自动批准执行；medium/high/critical、policy 告警、未登记 skill、remote_script 和默认 shell 仍需人工确认或阻断。
9. 用户可对需审批步骤选择执行、拒绝、跳过/修改或终止。
10. 步骤执行通过 observer 执行封装运行，写入 `execution_started` / `execution_finished`。
11. 每轮计划执行成功后，如果该 `work_plan` 的 `continue_decision.should_continue=false`，orchestrator 会直接结束，不再请求反思。
12. 如果 `continue_decision.should_continue=true`，orchestrator 会把环境信息、步骤结果、skill 返回摘要和失败信息整理成脱敏 observation，请 AI 用 `work_reflect` 判断下一步。
13. `work_reflect` 返回 `answer` 时结束；返回 `work_plan` 时执行这份续写计划，续写计划自己的 `continue_decision.should_continue` 决定执行后是否继续反思。
14. 循环轮次达到 `agent_loop.checkpoint_turns`（或默认 `context_turns`）时，会先请求用户允许继续。
15. 步骤失败时仍会生成修复建议；迭代模式还会把失败 observation 交给 AI 判断是否需要安全的下一轮诊断。

AI 的 work/reflection 响应必须包含显式继续判断：

```json
{
  "continue_decision": {
    "should_continue": false,
    "reason": "当前计划执行后为什么继续或停止"
  }
}
```

开启 `agent_loop.thinking_trace_enabled` 后，模型可额外返回简短 `thinking_summary`。程序会把它脱敏后写入 `/tmp/<session-id>/thinking/iteration-<n>.txt`，但不会把内容加入下一轮上下文、会话历史或审计 JSONL。

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
2. 执行前先走 `linux_agent_terminal_review`，用 `policies/risk-rules.json` 做阻断、警告、保护路径和保护服务审查。
3. clean low-risk 命令直接执行；阻断命令不会执行；需要人工确认的命令在 CLI 中请求确认，在 API/Web 中返回 `approval_required` 后由用户继续批准。
4. 执行通过 observer 封装运行，stdout/stderr 展示给用户；审计日志保存命令文本、退出码和脱敏后的输出预览。

## 安全边界

- AI 只能通过结构化 JSON 返回计划或 skill 编辑包。
- skill 脚本必须登记在 `skills/INDEX.md` 和对应 `SKILL.md` 中。
- 工作模式和脚本模式都会经过 `policies/risk-rules.json` 审查。
- Web 前端可以读取 `policies/` 下的 JSON 策略文件，但写入必须经过 sudo 校验；CLI 不依赖 Web，也不会因为 Web 存在而改变原有审批流程。
- `policies/audit-boundaries.json` 是 audit 运行时边界文件：`observing` 表示当前实际写入 JSONL 和 observer 实际安装的观察项，`allowed_to_observe` 表示允许加入观察的事件、syscall 和输出字段。
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

observer 可用时，会话开始按 `policies/audit-boundaries.json` 的 `observing.observer_syscalls` 安装带唯一 `audit_key` 的临时 auditd syscall 规则，会话结束清理规则并运行 `ausearch -k <audit_key>` 汇总事件。observer 不可用、边界未选择 syscall 或 sudo/auditctl 失败时写入 `observer_unavailable`，但不改变业务命令退出码。

修改 `policies/audit-boundaries.json` 可以控制 audit 具体观察内容：

- `observing.application_events`: 当前写入 JSONL 的应用层事件，支持精确事件名和 `step_*`、`observer_*` 这类前缀通配。
- `observing.observer_syscalls`: 当前 auditd observer 安装的 syscall 规则；只会安装同时存在于 `allowed_to_observe.observer_syscalls` 的项。
- `observing.observer_result_fields`: observer 汇总中保留的字段，例如 `exec_count`、`file_event_count`、`processes`、`file_events`。
- `allowed_to_observe`: Web 和人工编辑时可加入观察的候选范围；不在 allow-list 中的观察项会被运行时忽略。

## 文件职责

### 根目录

- `.gitignore`: 忽略本地配置和运行产物，如 `config/config.json`、`logs/`、`sessions/`、`tmp/`。
- `README.md`: 项目说明、运行方式、运行逻辑和文件职责。
- `test_config.sh`: 本地配置校验脚本；默认不访问网络，`--live` 才验证 API 连通性。

### `bin/`

- `bin/agent`: 唯一 CLI 入口。负责加载库文件、初始化环境、创建会话、安装 trap、路由子命令和 REPL。
- `bin/agent-web`: 本机 Web 控制台入口。读取 `config/config.json` 的 `web` 段并启动 Python 标准库后端。

### `config/`

- `config/config.example.json`: 配置模板。首次运行时会复制为本地 `config/config.json`。

### `prompts/`

- `prompts/system.txt`: AI 系统提示，定义输出 schema、执行约束、编辑模式和修复模式规则。

### `policies/`

- `policies/risk-rules.json`: 正则风险规则，包含阻断规则、警告规则、远程脚本规则、保护路径和保护服务。
- `policies/audit-boundaries.json`: audit 运行时边界。`observing` 控制当前 JSONL 事件、observer syscall 和汇总字段，`allowed_to_observe` 控制允许加入观察的候选范围。

### `lib/`

- `lib/common.sh`: 根目录、日志目录、skill 目录和临时目录初始化；通用输出；临时目录清理；文本和 JSON 脱敏。
- `lib/config.sh`: 加载 `config/config.json`，提供配置读取和默认值读取。
- `lib/audit.sh`: 创建审计会话、写入 JSONL、记录命令/turn/步骤状态、渲染审计报告。
- `lib/context.sh`: 维护内存会话历史窗口；构造动态请求上下文；合并最终 AI payload 上下文。
- `lib/sense.sh`: 根据主题采集最小必要环境信息，包括磁盘、资源、进程、网络、服务、日志和权限。
- `lib/skills.sh`: 解析 skill 引用、定位脚本、校验登记状态、执行 skill 脚本、校验 skill 目录。
- `lib/doctor.sh`: 检查必需命令、可选命令、配置 JSON 和 skill 目录。
- `lib/ai.sh`: 构造系统提示、记录 AI 文件清单、调用 OpenAI-compatible API，并把调用失败或非法响应转换成明确错误。
- `lib/policy.sh`: 读取风险规则，对命令、脚本、远程脚本和步骤做审查。
- `lib/observer.sh`: auditd observer 预检、规则安装/清理、`ausearch` 汇总和执行 marker。
- `lib/executor.sh`: 工作计划执行状态机；低风险自动审批、人工审批、远程脚本下载审查、步骤执行、失败修复、计划修改。
- `lib/editor.sh`: skill 编辑模式；打开编辑器、记录用户 diff、staging、校验和提交 skill。
- `lib/api.sh`: 机器可读 JSON API；为 Web 提供 health、work、script、terminal、edit、audit 等入口。
- `lib/interactive.sh`: REPL 输入、斜杠菜单和模式选择菜单。
- `lib/orchestrator.sh`: 四种业务模式的高层编排；work 模式的观察、反思、checkpoint 和续写循环。

### `web/`

- `web/server.py`: Python 标准库 Web 后端，负责静态文件、token 校验、API 转发和 job 状态。
- `web/static/index.html`: Web 控制台页面。
- `web/static/styles.css`: Web 控制台样式。
- `web/static/app.js`: Web 控制台交互逻辑。
- `web/static/mark.svg`: Web 控制台图标资源。

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

- `tests/smoke.sh`: 覆盖主要 CLI 入口、fake AI 工作流、JSON 输出、AI 文件清单、checkpoint 和 thinking trace。
- `tests/security.sh`: 覆盖脱敏、审计摘要、上下文边界、远程脚本审查和临时目录清理。
- `tests/workflow.sh`: 覆盖失败中断、自动低风险执行、反思续写、拒绝、跳过、修改需求、终止和输出渲染。
- `tests/policy.sh`: 覆盖风险规则、保护路径、远程脚本阻断和风险合并。
- `tests/tools.sh`: 覆盖本地工具、skill 登记、日志清理边界和 doctor。
- `tests/observer.sh`: 覆盖 observer 禁用、mock auditd、事件汇总和失败降级。
- `tests/interactive.sh`: 覆盖 REPL 菜单、模式切换、终端模式和编辑模式。
- `tests/web_api.sh`: 覆盖机器可读 API、work/script/terminal/edit 路径。
- `tests/web_server.sh`: 覆盖 Web token 拦截、health、静态页面、policy API 和 job 轮询。
- `tests/fake_ai_server.py`: 测试专用 Chat Completions 兼容服务，用于复刻工作流场景；不进入运行库。

### 运行时目录

- `logs/`: JSONL 审计日志。
- `tmp/`: 会话级临时目录根；每次 `bin/agent` 运行使用 `tmp/<session-id>/`。
- `/tmp/<session-id>/thinking/`: 开启 thinking trace 后保存每轮简短推理摘要，不进入审计或上下文。

## 测试

```bash
bash tests/smoke.sh
bash tests/security.sh
bash tests/workflow.sh
bash tests/policy.sh
bash tests/tools.sh
bash tests/observer.sh
bash tests/interactive.sh
bash tests/web_api.sh
bash tests/web_server.sh
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
bash tests/interactive.sh &&
bash tests/web_api.sh &&
bash tests/web_server.sh
```
