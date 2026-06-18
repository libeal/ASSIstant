# Linux 运维 Agent

Linux 运维 Agent 是一个以 Bash CLI 为核心的本机运维助手。它把自然语言请求、结构化计划、人工审批、策略审查、最小权限执行、审计日志和 Web 控制台串在一起，适合在 Linux 节点上做保守的诊断、巡检、脚本化辅助和 skill 生成。

项目的核心原则是：CLI 可以独立运行，Web 只是同一套能力的本机前端外壳；所有高风险操作都必须经过明确策略边界和人工确认。

## 项目功能

### CLI 模式

| 模式 | 命令 | 功能 |
| --- | --- | --- |
| Work | `bash bin/agent work "<需求>"` | 让模型返回 `answer` 或 `work_plan`，执行计划步骤，并按配置进行反思续写。 |
| Edit | `bash bin/agent edit "<需求>"` | 生成或修改 skill，打开 `$EDITOR` 或 `vi` 让用户确认脚本内容，再写入 `skills/`。 |
| Script | `bash bin/agent script <skill>/<script> [json]` | 执行已登记 skill 脚本，执行前校验登记、参数和策略。 |
| Terminal | `bash bin/agent terminal "<命令>"` | 对本机 shell 命令做策略审查，低风险执行，高风险或提权命令请求确认。 |
| Doctor | `bash bin/agent doctor` | 检查依赖、配置 JSON、skill 目录和基础运行环境。 |
| Sense | `bash bin/agent sense <topic>` | 按主题采集环境信息，支持 `all`、`disk`、`resource`、`process`、`network`、`service`、`logs`、`privilege`、`minimal`。 |
| Tools | `bash bin/agent tools list` | 输出 `skills/INDEX.md` 中登记的可执行 skill 索引。 |
| Skills | `bash bin/agent skills validate` | 校验 skill 目录、`SKILL.md`、脚本和索引登记一致性。 |
| Audit | `bash bin/agent audit <session-id>` | 读取历史 JSONL 审计会话并生成摘要报告。 |
| API | `bash bin/agent api <resource> <action> [json]` | 给 Web 后端调用的机器可读 JSON 接口。 |

交互式 REPL 支持 `/work`、`/edit`、`/script`、`/terminal`、`/mode`、`/help`、`/exit`。输入 `/` 或 `/前缀` 后回车会打开命令菜单。

### Web 控制台

Web 控制台通过 `bash bin/agent-web` 启动，后端只使用 Python 标准库，不依赖 npm、pip 或数据库。它通过 `bash bin/agent api ...` 调用 CLI 核心能力。

Web 视图包括：

- Work 工作台：自然语言任务、terminal 命令、执行时间线、审批抽屉、环境主题刷新。
- Skill 库：script 运行、script 审查、edit 生成、edit 审查、保存、skill 树、Markdown 预览、`skills validate`。
- Policy：查看和编辑 `policies/` 下的 JSON 策略文件，写入前需要 sudo 校验。
- Audit：查看 JSONL 审计 session、事件筛选、指标统计和报告导出。
- Config：读取和保存白名单配置项，运行 Doctor，展示运行时配置快照。

### 内置 Skill

- `ops-basic`: 常用只读巡检、日志搜索、清理计划、备份和安全日志截断。
- `os-deep-inspect`: 更深入的系统快照、网络、文件描述符和 journal 检查。

## 快速开始

```bash
cp config/config.example.json config/config.json
bash test_config.sh
bash bin/agent
```

配置最少需要修改：

```json
{
  "api_url": "https://api.openai.com/v1/chat/completions",
  "api_key": "你的密钥",
  "model": "gpt-4.1-mini"
}
```

启动 Web：

```bash
bash bin/agent-web
```

默认访问 `http://127.0.0.1:8765/`。静态页面不需要认证，所有 `/api/` 请求都需要 `Authorization: Bearer <token>`。如果 `web.token` 留空，启动时会生成本次运行的临时 token 并打印到终端。

常用命令：

```bash
bash bin/agent work "帮我检查磁盘空间是否异常"
bash bin/agent script ops-basic/process-inspect '{"pattern":"systemd"}'
bash bin/agent terminal "printf hello"
bash bin/agent sense disk
bash bin/agent tools list
bash bin/agent skills validate
bash bin/agent audit <session-id>
```

机器可读 API 示例：

```bash
bash bin/agent api health
bash bin/agent api tools list
bash bin/agent api sense get '{"topic":"resource"}'
bash bin/agent api script review '{"ref":"ops-basic/resource-inspect","arguments":{"top_n":1}}'
bash bin/agent api terminal run '{"command":"printf api-ok"}'
```

## 项目架构

项目按“入口层 -> 核心 Bash 层 -> Web 外壳层 -> 策略与提示层 -> Skill 能力层 -> 配置层 -> 测试层 -> 运行时产物层”组织。CLI 是项目核心，Web 通过同一套 CLI/API 能力提供浏览器体验，测试层使用 fake AI 和脚本验证主流程，不参与项目主体运行。

```text
Linux 运维 Agent
├─ 入口层
│  ├─ bin/agent              CLI 主入口，加载 lib 并路由 work/edit/script/terminal/doctor/sense/tools/skills/api/audit
│  └─ bin/agent-web          Web 启动入口，读取 Web 配置并启动 Python 后端
├─ 核心 Bash 层 lib/
│  ├─ 基础设施
│  │  ├─ common.sh           根目录、临时目录、脱敏、JSON 参数规范化
│  │  ├─ config.sh           配置读取和默认值
│  │  ├─ audit.sh            JSONL 审计和审计报告
│  │  └─ context.sh          会话历史和模型上下文
│  ├─ 感知与校验
│  │  ├─ sense.sh            环境采集
│  │  ├─ doctor.sh           本地健康检查
│  │  ├─ skills.sh           skill 解析、登记和校验
│  │  └─ policy.sh           风险规则审查
│  ├─ AI 与编排
│  │  ├─ ai.sh               模型请求、响应规范化和 schema 校验
│  │  ├─ orchestrator.sh     work/edit/script/terminal 高层编排和反思循环
│  │  ├─ executor.sh         work plan 执行状态机
│  │  ├─ editor.sh           skill edit/staging/提交
│  │  ├─ observer.sh         auditd observer 和降级记录
│  │  ├─ api.sh              机器可读 API
│  │  └─ interactive.sh      REPL 菜单和模式选择
├─ Web 外壳层 web/
│  ├─ server.py              标准库 HTTP 后端，认证、静态文件、job、策略/配置/skill API
│  └─ static/
│     ├─ index.html          Web 页面结构
│     ├─ app.js              前端状态、轮询、审批、配置、审计和 skill 交互
│     ├─ styles.css          页面样式
│     └─ mark.svg            Web 图标
├─ 策略与提示层
│  ├─ prompts/system.txt     模型系统提示和输出约束
│  └─ policies/
│     ├─ risk-rules.json     阻断、警告、保护路径和保护服务规则
│     └─ audit-boundaries.json audit/observer 允许观察边界
├─ Skill 能力层 skills/
│  ├─ INDEX.md               可执行 skill 白名单
│  ├─ ops-basic/             基础巡检、日志、备份和安全清理 skill
│  └─ os-deep-inspect/       深度系统、网络、FD 和 journal 检查 skill
├─ 配置层
│  ├─ config/config.example.json 模板配置
│  └─ config/config.json     本地实际配置，忽略提交
├─ 测试层 tests/
│  ├─ fake_ai_server.py      测试用 Chat Completions 兼容服务
│  ├─ helpers.sh             测试辅助函数
│  └─ *.sh                   CLI、Web、策略、安全、observer、交互和工作流测试
└─ 运行时产物
   ├─ logs/                  JSONL 审计日志，忽略提交
   ├─ tmp/                   session 临时目录和 Web job 状态，忽略提交
   └─ __pycache__、*.pyc     Python 字节码缓存，忽略提交
```

### 分层职责

- 入口层只做环境准备、参数解析和模式分发。
- 核心 Bash 层承载 CLI 主流程、AI 调用、策略校验、执行、审计和本地感知，是 CLI 与 Web 共享的业务核心。
- Web 外壳层负责浏览器交互、HTTP API、job 状态和静态资源，不复制核心执行逻辑。
- 策略与提示层把模型约束、风险规则和观察边界外置，便于审计和独立调整。
- Skill 能力层提供经过登记的运维能力扩展，脚本通过白名单被 CLI 和 Web 间接使用。
- 配置层保存模板和本地运行配置，本地敏感配置不进入版本库。
- 测试层包含 fake AI 和回归脚本，只服务验证流程，不应被主流程依赖。
- 运行时产物层保存日志、临时状态和缓存，均为本地生成内容。

### 核心调用关系

1. `bin/agent` 加载 `lib/*.sh`，初始化根目录、配置、日志目录、临时目录和全局状态。
2. 除 `agent audit` 和部分无需会话的 `api` 入口外，运行开始会创建 JSONL 审计 session。
3. `lib/sense.sh` 按请求主题采集最小必要环境信息。
4. `lib/context.sh` 构造模型请求上下文，并按 `context_turns` 带入会话历史窗口。
5. `lib/ai.sh` 拼接 `prompts/system.txt`、`skills/INDEX.md`、动态上下文并调用 OpenAI-compatible Chat Completions 接口。
6. `lib/orchestrator.sh` 根据模式调度 work、edit、script、terminal。
7. `lib/policy.sh` 用 `policies/risk-rules.json` 做阻断、警告、保护路径和保护服务审查。
8. `lib/executor.sh` 执行计划步骤，处理自动批准、人工审批、跳过、修改、终止、远程脚本下载审查和失败修复建议。
9. `lib/observer.sh` 在可用时安装 auditd syscall 观察规则，执行结束后汇总 `ausearch` 事件；不可用时只记录降级事件。
10. `lib/audit.sh` 负责审计 JSONL 写入、脱敏摘要、session 收尾和 `agent audit` 报告。

### Web 调用关系

1. `bin/agent-web` 读取 `config/config.json` 的 `web` 段，导出环境变量并启动 `web/server.py`。
2. `web/server.py` 提供静态文件、token 校验、策略/配置/skill 文件 API、异步 job API。
3. 对 CLI 核心能力，Web 后端调用 `bash bin/agent api ...`，不复制业务逻辑。
4. 长任务通过 `/api/jobs` 启动，状态写入 `tmp/web/jobs/`，前端轮询 `/api/jobs/<job-id>`。
5. 前端 `web/static/app.js` 负责页面状态、审批抽屉、轮询、中止、配置编辑、策略编辑、审计筛选和输出渲染。

## 运行逻辑

### Work 模式

1. 接收用户自然语言请求并记录 `received`。
2. 检测主题并采集环境上下文。
3. 请求模型返回 `answer` 或 `work_plan`。
4. 如果是 `answer`，直接输出并记录会话历史。
5. 如果是 `work_plan`，逐步执行：
   - 校验 executor 类型。
   - 校验 skill 是否登记。
   - 对 shell、skill、remote script 做策略审查。
   - clean low-risk 的已登记 skill 可自动执行。
   - 默认 shell、remote script、medium/high/critical 或命中策略告警的步骤需要人工确认。
6. 每步通过 observer 封装执行，结果写入审计。
7. 失败时生成修复建议，但不会自动执行修复计划。
8. 如果计划要求继续反思，执行结果会整理成脱敏 observation，再请求模型判断下一步。
9. 达到 checkpoint 轮次时，请求用户确认是否继续。

模型响应必须包含：

```json
{
  "continue_decision": {
    "should_continue": false,
    "reason": "当前计划执行后为什么继续或停止"
  }
}
```

### Edit 模式

1. 模型返回 `skill_edit` JSON。
2. 展示 skill 名称、说明和脚本计划。
3. 每个脚本写入临时文件并打开 `$EDITOR` 或 `vi`。
4. 用户保存后，脚本再次经过策略审查。
5. 生成 `SKILL.md` 和脚本文件，在临时 staging 目录中校验。
6. 校验通过后替换正式 `skills/<name>/` 并更新 `skills/INDEX.md`。

Web 版 edit 使用浏览器内联编辑器，但保存前仍调用同一套 `edit review/apply` API。

### Script 模式

1. 用户提供 `skill/script` 和 JSON 参数。
2. 校验引用格式、`skills/INDEX.md` 登记、对应 `SKILL.md` 声明和脚本文件存在。
3. 对脚本文本和参数做策略审查。
4. 用户确认后执行脚本。
5. 返回脚本 JSON 输出、退出码、observer 摘要和审计事件。

### Terminal 模式

1. 用户输入交给 `bash -lc`。
2. 执行前调用 `linux_agent_terminal_review`。
3. 阻断命令不会执行。
4. 需要审批的命令在 CLI 中请求确认，在 API/Web 中返回 `approval_required`。
5. 执行结果展示 stdout/stderr，并写入脱敏后的审计预览。

### Remote Script

`remote_script` 不允许 `curl | sh`。它只支持 HTTPS 下载后审查：

1. 校验 URL 必须是 `https://`。
2. 下载到当前 session 的 `tmp/<session-id>/`。
3. 校验非空、大小不超过 256KB、文本类型、SHA256、行数和预览。
4. 风险等级提升为 high 或 critical。
5. 用户审批后才执行下载后的脚本。

## 配置

`config/config.example.json` 是模板，`config/config.json` 是本地配置文件并被 `.gitignore` 忽略。

关键字段：

| 字段 | 作用 |
| --- | --- |
| `provider` | 供应商展示名。 |
| `api_url` | Chat Completions 兼容接口地址。 |
| `api_key` | 模型 API 密钥，本地保存，不提交。 |
| `model` | 模型名称。 |
| `request_timeout_sec` | AI 请求超时时间。 |
| `context_turns` | 会话历史窗口大小。 |
| `agent_loop.enabled_for_work` | 是否启用 work 反思续写循环。 |
| `agent_loop.auto_execute_low_risk` | 是否自动执行 clean low-risk skill 步骤。 |
| `agent_loop.auto_execute_shell_low_risk` | 是否允许自动执行 clean low-risk shell 步骤，默认关闭。 |
| `agent_loop.observation_text_limit` | observation 文本摘要上限。 |
| `agent_loop.thinking_trace_enabled` | 是否保存并展示简短 `thinking_summary`。 |
| `agent_loop.checkpoint_turns` | 强制 checkpoint 轮次，`0` 表示使用默认窗口。 |
| `audit_mode` | 审计写入模式。 |
| `audit_text_limit` | 审计和输出预览文本截断长度。 |
| `observer.enabled` | observer 开关，默认 `auto`。 |
| `observer.privilege` | auditd observer 的 sudo 策略。 |
| `observer.max_events` | observer 汇总事件上限。 |
| `execution.min_privilege_proxy` | root 运行时是否尽量降权执行普通命令。 |
| `execution.least_privilege_user` | 降权执行使用的目标用户。 |
| `skills_dir` | 自定义 skill 根目录，空值使用项目内 `skills/`。 |
| `remote_script_policy` | 远程脚本策略，支持 `download_review` 和 `disabled`。 |
| `web.enabled` | 是否允许启动 Web。 |
| `web.host` | Web 监听地址。 |
| `web.port` | Web 监听端口。 |
| `web.token` | Web Bearer token，空值则启动时生成临时 token。 |
| `web.job_retention_hours` | Web job 状态文件保留小时数。 |

环境变量：

| 变量 | 作用 |
| --- | --- |
| `EDITOR` | Edit 模式打开脚本确认文件的编辑器，未设置时使用 `vi`。 |
| `LINUX_AGENT_OUTPUT_JSON=1` | 将 CLI 业务输出切换为机器可读 JSON。 |

内部变量如 `LINUX_AGENT_TMP_DIR`、`LINUX_AGENT_SESSION_ID`、`LINUX_AGENT_AUDIT_LOG` 由程序设置，不建议外部手工使用。

## 安全边界

- AI 只能返回结构化 JSON，不能直接执行命令。
- Skill 脚本必须同时登记在 `skills/INDEX.md` 和对应 `SKILL.md`。
- Work 和 Script 都经过 `policies/risk-rules.json`。
- Terminal 也会执行策略审查，高风险命令需要确认。
- Remote script 只能 HTTPS 下载后审查，不允许流式管道执行。
- Web `/api/` 全部需要 Bearer token。
- Web 策略编辑只允许 `policies/` 下 JSON 文件，写入前做 sudo 校验。
- 审计文本和上下文会脱敏并截断。
- 当前 session 的临时目录只在当前进程结束时清理。

## 测试与验证

本地配置检查：

```bash
bash test_config.sh
bash test_config.sh --live
```

常用测试：

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
```

完整回归：

```bash
for test in \
  tests/smoke.sh \
  tests/security.sh \
  tests/workflow.sh \
  tests/policy.sh \
  tests/tools.sh \
  tests/observer.sh \
  tests/interactive.sh \
  tests/web_api.sh \
  tests/web_server.sh
do
  bash "$test"
done
```

`tests/web_api.sh` 和 `tests/web_server.sh` 需要绑定 `127.0.0.1` 本地端口。如果沙箱或 CI 禁止监听本地端口，这两项会因环境权限失败。

## 文件职责

### 根目录

| 文件 | 功能 |
| --- | --- |
| `.gitignore` | 忽略本地配置、日志、session、临时目录和 Python 字节码。 |
| `AGENTS.md` | 本地协作和开发原则说明，被 `.gitignore` 忽略，不属于运行核心。 |
| `README.md` | 项目说明文档。 |
| `test_config.sh` | 本地配置校验脚本，默认不访问网络，`--live` 才发送最小模型请求。 |

### `bin/`

| 文件 | 功能 |
| --- | --- |
| `bin/agent` | 唯一 CLI 主入口，加载 `lib/*.sh`、初始化配置、创建审计 session、安装 signal trap、路由子命令和 REPL。 |
| `bin/agent-web` | Web 控制台启动入口，读取 `config/config.json` 的 `web` 段，校验依赖，生成或读取 token，并启动 `web/server.py`。 |

### `config/`

| 文件 | 功能 |
| --- | --- |
| `config/config.example.json` | 配置模板。 |
| `config/config.json` | 本地实际配置，由用户创建或首次运行复制模板生成，被 `.gitignore` 忽略。 |

### `lib/`

| 文件 | 功能 |
| --- | --- |
| `lib/common.sh` | 根目录、日志目录、临时目录初始化，通用输出函数，临时目录清理，文本和 JSON 脱敏，JSON 参数规范化。 |
| `lib/config.sh` | 加载 `config/config.json`，提供配置读取、默认值读取、布尔和正整数读取。 |
| `lib/audit.sh` | 审计边界读取、审计 payload 脱敏摘要、JSONL session 创建和写入、命令/turn/步骤状态记录、审计报告渲染。 |
| `lib/context.sh` | 维护会话历史窗口，构造动态请求上下文，合并最终 AI payload 上下文。 |
| `lib/sense.sh` | 采集磁盘、资源、进程、网络、日志、服务、权限等环境信息。 |
| `lib/skills.sh` | 解析 skill 引用、定位脚本、读取索引、校验登记状态、执行 skill 脚本、校验 skill 目录。 |
| `lib/doctor.sh` | 检查必需命令、可选命令、配置和 skill 目录。 |
| `lib/ai.sh` | 构造系统提示，记录 AI 输入文件清单，调用 Chat Completions 兼容接口，规范化和校验模型响应。 |
| `lib/policy.sh` | 加载风险规则，对命令、脚本、参数、远程脚本、保护路径和保护服务做审查。 |
| `lib/observer.sh` | auditd observer 预检、规则安装和清理、`ausearch` 解析、执行过程 marker 和降级记录。 |
| `lib/executor.sh` | Work 计划执行状态机，包含自动审批、人工审批、跳过/修改/终止、远程脚本下载审查、步骤执行、失败修复建议和输出渲染。 |
| `lib/editor.sh` | Edit 模式实现，生成 `SKILL.md`，打开编辑器，记录人工修改 diff，staging 校验并提交 skill。 |
| `lib/api.sh` | 机器可读 JSON API，给 Web 提供 health、config、doctor、sense、tools、skills、audit、work、script、terminal、edit 等入口。 |
| `lib/interactive.sh` | REPL 输入、斜杠菜单、命令补全菜单和模式选择菜单。 |
| `lib/orchestrator.sh` | 高层业务编排，负责 work/edit/script/terminal 分发、work 反思循环、checkpoint 和 thinking summary。 |

### `web/`

| 文件 | 功能 |
| --- | --- |
| `web/server.py` | Python 标准库 Web 后端，提供静态文件、认证、配置 API、策略 API、skill 文件 API、job API，并转发 CLI API。 |
| `web/static/index.html` | Web 控制台 HTML 页面，包含 Work、Skill、Policy、Audit、Config 五个主视图。 |
| `web/static/app.js` | Web 前端交互逻辑，包含认证、API 调用、job 轮询、审批抽屉、输出渲染、配置编辑、策略编辑、审计筛选、skill 校验和环境刷新。 |
| `web/static/styles.css` | Web 控制台样式。 |
| `web/static/mark.svg` | Web 控制台图标资源。 |

### `prompts/`

| 文件 | 功能 |
| --- | --- |
| `prompts/system.txt` | 发送给模型的系统提示，定义角色、输出 schema、执行边界、work/edit/repair 规则。 |

### `policies/`

| 文件 | 功能 |
| --- | --- |
| `policies/risk-rules.json` | 风险规则文件，包含阻断模式、警告模式、远程脚本阻断模式、保护路径和保护服务。 |
| `policies/audit-boundaries.json` | audit 和 observer 边界文件，定义当前观察项、允许观察项、payload 模式、文本限制、observer syscall 和结果字段。 |

### `skills/`

| 文件 | 功能 |
| --- | --- |
| `skills/INDEX.md` | Skill 白名单索引，会进入模型 system prompt，也是 script 模式可执行入口的登记依据。 |
| `skills/ops-basic/SKILL.md` | `ops-basic` skill 说明和脚本清单。 |
| `skills/ops-basic/scripts/disk-hotspots.sh` | 采集指定路径磁盘使用、一级目录占用和大文件。 |
| `skills/ops-basic/scripts/resource-inspect.sh` | 查看负载、CPU、内存和高占用进程。 |
| `skills/ops-basic/scripts/process-inspect.sh` | 查看进程列表、匹配进程和僵尸进程。 |
| `skills/ops-basic/scripts/service-inspect.sh` | 查看 systemd 服务状态和失败服务。 |
| `skills/ops-basic/scripts/service-restart-plan.sh` | 生成服务重启前只读预检计划，不直接重启。 |
| `skills/ops-basic/scripts/log-search.sh` | 检索 `/var/log` 日志，可选读取 journal 样本。 |
| `skills/ops-basic/scripts/log-cleanup-plan.sh` | 扫描 `/var/log` 或 `/tmp` 下的大日志并生成清理候选和排除项。 |
| `skills/ops-basic/scripts/safe-log-cleanup.sh` | 对允许范围内的非关键普通日志文件做 dry-run 或截断。 |
| `skills/ops-basic/scripts/config-backup.sh` | 为目标路径生成 tar.gz 备份。 |
| `skills/os-deep-inspect/SKILL.md` | `os-deep-inspect` skill 说明和脚本清单。 |
| `skills/os-deep-inspect/agents/openai.yaml` | `os-deep-inspect` 的可选 agent 配置示例。 |
| `skills/os-deep-inspect/scripts/os-snapshot.sh` | 深度采集主机、负载、磁盘、网络、失败服务、日志和进程摘要。 |
| `skills/os-deep-inspect/scripts/net-inspect.sh` | 通过 `ss` 或 `netstat` 查看监听端口、连接状态和可选进程信息。 |
| `skills/os-deep-inspect/scripts/fd-inspect.sh` | 通过 `lsof` 或 `/proc/<pid>/fd` 检查打开文件、socket 和文件句柄占用。 |
| `skills/os-deep-inspect/scripts/journal-inspect.sh` | 通过 `journalctl` 按 unit、priority、时间窗口和关键词读取日志样本。 |

### `tests/`

| 文件 | 功能 |
| --- | --- |
| `tests/helpers.sh` | 测试辅助函数，启动/停止 fake AI server，写入测试配置。 |
| `tests/fake_ai_server.py` | 测试专用 Chat Completions 兼容服务，用于复刻 answer、work_plan、edit、repair 等响应。 |
| `tests/smoke.sh` | 覆盖主要 CLI 入口、fake AI 工作流、JSON 输出、AI 文件清单、checkpoint 和 thinking trace。 |
| `tests/security.sh` | 覆盖脱敏、审计摘要、上下文边界、远程脚本审查和临时目录清理。 |
| `tests/workflow.sh` | 覆盖失败中断、自动低风险执行、反思续写、拒绝、跳过、修改需求、终止和输出渲染。 |
| `tests/policy.sh` | 覆盖风险规则、保护路径、远程脚本阻断和风险合并。 |
| `tests/tools.sh` | 覆盖本地工具、skill 登记、日志清理边界和 doctor。 |
| `tests/observer.sh` | 覆盖 observer 禁用、mock auditd、事件汇总和失败降级。 |
| `tests/interactive.sh` | 覆盖 REPL 菜单、模式切换、terminal 模式和 edit 模式。 |
| `tests/web_api.sh` | 覆盖机器可读 API 的 work、script、terminal、edit、audit 等路径。 |
| `tests/web_server.sh` | 覆盖 Web token 拦截、health、静态页面、config、skill、policy、job、shutdown 和新增 Web 入口。 |

### 运行时目录和生成文件

| 路径 | 功能 |
| --- | --- |
| `logs/` | JSONL 审计日志目录，被 `.gitignore` 忽略。 |
| `tmp/` | 项目内临时目录，被 `.gitignore` 忽略；Web job 状态位于 `tmp/web/jobs/`。 |
| `sessions/` | 预留的本地 session 产物目录，被 `.gitignore` 忽略。 |
| `/tmp/<session-id>/thinking/` | 开启 thinking trace 后保存简短思考摘要，不进入审计或上下文。 |
| `__pycache__/`、`*.pyc` | Python 运行生成的字节码缓存，被 `.gitignore` 忽略。 |

## 故障排查

- `config/config.json` 缺失：运行 `cp config/config.example.json config/config.json`。
- `api_key` 仍是占位值：`work` 和 `edit` 会返回明确的 AI 配置错误。
- Web 端口被占用：停止旧进程或修改 `web.port`。
- Web 认证失败：确认页面右上角 token 与 `agent-web` 启动日志一致。
- `skills validate` 失败：检查 `skills/INDEX.md`、对应 `SKILL.md` 和 `scripts/*.sh` 是否一致。
- observer 不可用：通常是系统没有 auditd、缺少 sudo 权限或策略禁用了 syscall 观察；业务命令仍可继续执行，只会记录降级事件。
