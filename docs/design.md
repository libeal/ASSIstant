# Linux 运维 Agent 设计文档

本文说明项目的设计目标、核心边界、主要数据流和扩展约束。架构分层的历史背景见 [`architecture.md`](architecture.md)，CLI/Web 机器协议见 [`api-protocol.md`](api-protocol.md)。

## 设计目标

- 让 CLI 在没有 Web、数据库、npm/pip 依赖的情况下独立完成本机诊断和保守执行。
- 让 Web 只作为本机控制台外壳，通过同一套 CLI/API 能力工作，不复制核心业务逻辑。
- 让 AI 只生成结构化建议，所有执行都经过策略审查、人工审批或显式自动批准。
- 让 skill 成为可审计、可登记、可校验的能力扩展，而不是任意 shell 片段。
- 让审计日志记录事实，并且默认脱敏、截断、按边界输出。
- 让 observer 在 auditd 可用时提供运行时事实补充，不把内核观察降级当成业务失败。

## 非目标

- 不提供任意第三方 `curl | sh` 运行能力；只支持仓库 Release 中受 manifest 约束的官方 bootstrap。
- 不把 Web 做成多用户服务或公网 SaaS。
- 不绕过本机策略直接执行模型输出。
- 不把运行时日志、临时文件、secret 或本地配置提交进仓库。
- 不要求浏览器前端构建链路；当前前端是无构建 ES modules。

## 核心组件

| 组件 | 主要文件 | 责任 |
| --- | --- | --- |
| CLI adapter | `bin/agent` | 初始化环境、加载 core、创建审计 session、分发子命令和 REPL。 |
| Web adapter | `bin/agent-web`、`web/server.py` | 启动本机 HTTP 服务、处理 token、静态文件、job 和文件 API。 |
| 编排层 | `lib/orchestrator.sh`、`lib/ai.sh`、`lib/context.sh` | 构造上下文、调用模型、校验响应、执行 work/edit/script/terminal 主流程。 |
| 执行层 | `lib/executor.sh`、`lib/policy.sh`、`lib/command_guard.py`、`lib/observer.sh` | 审查、审批、执行、观察、失败处理和协议化输出。 |
| 能力层 | `lib/skills.sh`、`skills/` | 管理本地 skill registry，校验并执行已登记脚本。 |
| Remote 发布层 | `remote/`、release build、GitHub workflow | 构建并校验 CLI/Web bootstrap、core/Web 归档和独立 skill 包。 |
| 协议层 | `lib/protocol.sh`、`docs/api-protocol.md` | 统一 `timeline`、`approval_card` 和 `output_blocks`。 |
| 审计层 | `lib/audit.sh`、`policies/audit-boundaries.json` | 写入 JSONL session，控制审计范围、脱敏和摘要。 |

## 运行时数据流

### Work

1. CLI 或 Web API 接收自然语言请求。
2. `sense` 按主题采集最小必要上下文。
3. `context` 组装当前请求、环境摘要、历史窗口和 skill 索引。
4. `ai` 调用 Chat Completions 兼容接口并规范化模型响应。
5. `orchestrator` 判断响应是 `answer` 还是 `work_plan`。
6. `executor` 对每个步骤做 skill 登记校验、策略审查、自动批准判断或人工审批。
7. 执行结果通过 `observer` 包裹，写入审计，并转成 `timeline` / `output_blocks`。
8. 若计划要求继续反思，`orchestrator` 发送脱敏 observation，再决定继续、停止或 checkpoint。

### Script

1. 用户提供 `skill/script` 和 JSON 参数。
2. `skills` 校验索引、manifest 和脚本文件一致。
3. `policy` 审查脚本文本和参数。
4. 用户批准后，`executor` 运行脚本并生成结构化输出。

### Terminal

1. 用户命令先进入 `command_guard.py` 和 JSON 风险规则。
2. 低风险且允许自动执行的命令可直接执行；高风险、提权、保护路径或策略命中需要审批或阻断。
3. 结果写入审计并转换为工作台协议。

### Edit

1. 模型返回 `skill_edit`。
2. CLI 打开编辑器或 Web 内联编辑，用户确认脚本内容。
3. 编辑包经过策略审查和 staging 校验。
4. 校验通过后替换目标 skill 并更新 `skills/INDEX.md`。

## 策略模型

策略审查由两层组成：

- `command_guard.py` 识别 shell 结构风险，例如 redirect、wrapper、substitution、remote pipe、交互命令、文件写入和保护路径。
- `policies/risk-rules.json` 提供可配置正则规则，覆盖阻断模式、警告模式、远程脚本模式、保护路径和保护服务。

两层策略允许存在重叠，但语义必须一致。保护路径至少包括 `/`、`/etc`、`/boot`、`/usr`、`/var/lib`、`/root` 和 `/home/<user>/.ssh`。自由 shell 文件修改应被阻断，文件匹配、补丁、下载和本地分析应通过 `controlled-tools`。

## 审批与自动执行

自动批准只在以下条件同时成立时发生：

- 策略审查 `approved=true`。
- 策略审查 `approval_required=false`。
- 最终风险等级为 `low`。
- 对应 `approvals.auto.*` 能力开关启用；如果字段缺失，则使用该能力的新配置默认值。
- 对 skill 步骤，还必须通过本地 registry 登记校验。

## API 协议

执行类 API 面向 Web 返回统一工作台协议：

- `timeline`: 展示计划、审查、审批、执行、observer 和审计回放。
- `approval_card`: 当前待审批对象，无审批时为 `null`。
- `output_blocks`: 标准输出、错误输出、JSON、review、observer、meta 等分块结果。

新增 API 字段应优先 additive。前端不得依赖未文档化的临时字段；后端不应恢复旧的 `preview/result/execution` 响应结构。

## Web 设计

Web 后端使用 Python 标准库，负责：

- 静态文件服务和 Bearer token 校验。
- `/api/jobs` 异步任务外壳。
- 策略、配置、skill 文件读写。
- AI provider 预设读取和模型列表代理；临时 API key 只用于当次请求，不回显。
- Web observer bootstrap：在浏览器中申请一次服务器权限，验证 auditd 可用性；跳过或失败写入审计日志。
- 转发核心能力到 `bash bin/agent api ...`。

observer 的当前实现约束：

- 规则按 `policies/audit-boundaries.json` 中的 syscall 列表安装，默认只输出摘要字段。
- 身份过滤使用 audit `auid`，优先取 `/proc/self/loginuid`，否则回退到当前 `id -u`。
- `ausearch` 解析按 audit record id 去重，避免同一次 exec 的 `SYSCALL` 与 `EXECVE` 被重复计数。
- WSL、容器、无 auditd 或无权限时只记录 `observer_unavailable` / `observer_failed`，业务命令继续按 policy 和审批结果运行。

详细生命周期和排障见 [`observer-audit.md`](observer-audit.md)。

前端保持无构建模块化：

- `app.js` 负责页面编排和事件绑定。
- `modules/api.js` 负责请求。
- `modules/timeline.js` 负责执行条目规范化。
- `modules/output-blocks.js` 负责输出块渲染。
- `modules/audit.js` 负责审计事件解析。
- `modules/policy-config.js` 负责配置表单定义。

## 扩展规则

- 新 CLI 子命令应先判断是否需要审计 session，并接入 `bin/agent` 的统一生命周期。
- 新 Web 能力应优先增加 `agent api` 路由，再由 `web/server.py` 转发。
- 新 skill 必须更新 `skills/INDEX.md`、`SKILL.md` 和脚本文件，并通过 `bash bin/agent skills validate`。
- 新策略字段必须更新 `policy validate` 校验、README 配置说明和相关测试。
- 新输出结构必须经过 `lib/protocol.sh` 暴露为 `output_blocks` 或 `timeline`。
- Remote manifest 只允许相对资产名；skill 必须按一级目录整包发布并在 staging 校验后原子 materialize。

## 测试策略

- Bash 语法：`bash -n bin/agent bin/agent-web test_config.sh lib/*.sh tests/*.sh skills/*/scripts/*.sh`
- Python 语法：`python3 -m py_compile lib/command_guard.py web/server.py tests/fake_ai_server.py`
- 策略校验：`bash bin/agent policy validate`
- Skill 校验：`bash bin/agent skills validate`
- 完整回归：按 README 中的 `tests/*.sh` 顺序执行。

设计改动只有在相关回归通过后才算完成。
