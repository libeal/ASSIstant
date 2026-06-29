# Linux 运维 Agent 架构说明

本文记录项目的当前架构边界和演进方向。当前可用形态仍是本地 CLI 与 Web 控制台；远程 `curl | bash` 只作为未来设计空间保留，不是已实现能力。

## rssh 架构借鉴

rssh 对本项目最有价值的不是具体技术栈，而是边界设计：

- 多入口共享核心能力：桌面 UI、CLI、headless server 不各写一套业务逻辑。
- AI 只提出计划或命令建议，执行层负责审查、确认、执行和审计。
- 会话、配置、密钥、审计和能力扩展都有独立边界，避免入口层直接接触内部细节。
- 能力目录和运行协议保持稳定，使新入口可以接入同一套 core。
- 审计日志记录事实，Web 可以从审计事件恢复自己的工作时间线，但不把 UI 状态反写进审计层。

本项目对应的优化方向是：保持 Bash core 简单直接，但把“入口适配器”和“核心能力”区分清楚，避免以后新增 Web、API、远程 bootstrap 时出现分叉实现。

## 分层模型

项目按四层理解和维护：

| 层级 | 当前组成 | 职责 |
| --- | --- | --- |
| 入口层 | `bin/agent`、`bin/agent-web`、Web API、未来 remote bootstrap | 初始化运行环境、解析参数、选择模式、转发到 core。 |
| 编排层 | `lib/orchestrator.sh`、`lib/ai.sh`、`lib/context.sh`、`lib/sense.sh` | 理解用户请求、采集上下文、调用模型、校验模型响应、调度 work/edit/script/terminal 流程。 |
| 执行层 | `lib/executor.sh`、`lib/policy.sh`、`lib/observer.sh`、`lib/editor.sh` | 对 shell、skill、remote_script、编辑操作做策略审查、审批、执行、观察和失败处理。 |
| 能力层 | `lib/skills.sh`、`lib/audit.sh`、`lib/config.sh`、`prompts/`、`policies/`、`skills/` | 提供 skill registry、配置读取、审计记录、提示词、风险规则和可扩展运维能力。 |

维护规则：

- 入口层不复制业务逻辑，只调用 core。
- Web 继续通过 `bash bin/agent api ...` 使用核心能力。
- 新入口必须接入同一套编排层和执行层，不能绕过 policy、approval、observer 和 audit。
- 能力层只暴露稳定函数或文件契约，调用方不直接依赖未来可能变化的存储形态。

## 当前调用边界

`bin/agent` 是本地 CLI adapter。它负责：

- 定位项目根目录。
- 加载 `lib/*.sh`。
- 初始化目录、配置和审计状态。
- 为需要记录的命令创建审计 session。
- 安装 signal trap 并把子命令分发给 core。

`bin/agent-web` 是 Web adapter。它负责：

- 读取 Web 配置。
- 启动 `web/server.py`。
- 输出本次访问 token。

`web/server.py` 只做 HTTP、认证、静态资源、job 状态和文件 API。对核心业务能力，它通过 `bash bin/agent api ...` 调用 CLI API，不直接执行 work plan 或 skill。

CLI/Web 的稳定机器协议记录在 `docs/api-protocol.md`。新增字段应优先 additive，不应让 Web 前端依赖未文档化的临时输出。

## Skill Registry 契约

当前 skill registry 是本地目录实现：

- `skills/INDEX.md` 是可执行 skill 白名单。
- `skills/<name>/SKILL.md` 是 skill manifest。
- `skills/<name>/scripts/*.sh` 是实际脚本。
- `controlled-tools` 提供受控文件匹配、补丁、下载和本地分析；自由 shell 文件修改应被 policy 阻断，而不是在入口层特判放行。

调用方应通过 `lib/skills.sh` 的函数访问 skill，而不是手工拼路径：

- `linux_agent_skill_index_text`：返回当前可用 skill 索引文本。
- `linux_agent_skill_is_registered <skill>/<script>`：确认引用同时存在于索引、manifest 和脚本文件中。
- `linux_agent_skill_script_content <skill>/<script>`：读取脚本文本用于审查。
- `linux_agent_run_skill_script <skill>/<script> <json>`：执行已登记脚本。
- `linux_agent_validate_skills`：校验本地 skill registry 一致性。

未来远程 skill 懒加载应保持同一语义：

- 首次只获取 skill 索引摘要。
- 真正执行某个 skill 时才 materialize 脚本。
- materialize 过程必须校验来源、digest 和 manifest。
- 执行前仍走现有 policy review、approval、observer 和 audit。

这意味着未来可以把 registry 后端从本地目录扩展为“远程 manifest + 临时缓存”，但 `orchestrator`、`executor`、Web API 不应该感知这种变化。

## 安全执行模型

AI 输出是未受信任的计划，不是命令授权。当前执行链路必须保持：

1. `lib/ai.sh` 校验模型响应 schema。
2. `lib/orchestrator.sh` 把响应分发到具体模式。
3. `lib/policy.sh` 审查 shell、skill 脚本、参数、remote_script、保护路径和保护服务。
4. `lib/executor.sh` 按能力级自动批准配置决定自动执行、人工审批、跳过、终止或失败。
5. `lib/observer.sh` 在可用时记录 syscall 观察结果，不可用时记录降级。
6. `lib/audit.sh` 写入脱敏审计事件。

`remote_script` 当前只允许 HTTPS 下载后审查，再由用户确认执行。它不是流式远程执行能力，也不允许模型输出任意 `curl | sh` 或 `curl | bash`。

模型 API key 的来源优先级是 `LINUX_AGENT_API_KEY`、`config.api_key`。缺少可选配置时使用程序默认值，但不会读取未登记配置字段作为回退。

## 未来远程运行方向

远程运行是未来目标，不属于当前实现。预留设计如下：

- 官方 bootstrap 作为新的入口 adapter 接入 core。
- bootstrap 只加载最小核心模块，不首次下载完整项目。
- 远程模块、prompt、policy、skill index 由 manifest 描述。
- manifest 记录 SHA256，bootstrap 下载后必须校验再加载。
- skill 按需加载：只有被计划选中的 skill 才下载、校验和执行。
- 默认使用临时目录保存已校验字节，退出后清理。
- API key、token、私钥和本地密钥不写入 bootstrap、manifest 或 skill 包。
- 任意第三方远程脚本继续走 `remote_script` 的下载审查流程，不因官方 bootstrap 存在而放宽。

这个方向要求当前代码继续保持 adapter/core 分离、skill registry 抽象和统一安全执行链路。实现远程 bootstrap 时，新增入口只能复用这些边界，而不是绕过它们。
