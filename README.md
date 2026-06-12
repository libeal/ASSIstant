# Linux 运维 Agent

这是一个 Bash 实现的 CLI 版 Linux 运维助手。它以四模式 REPL 为核心：工作模式用于 AI 辅助运维执行，编辑模式用于创建或修改 skill，脚本模式用于直接运行已登记的 skill 脚本，终端模式用于临时直接控制本机 shell。

项目设计重点是安全和可审计：

- AI 只能返回结构化 `work_plan`，每个步骤逐条展示、审查、审批、执行。
- 优先执行 `skills/` 中登记的脚本；原始 shell 和远程脚本属于例外路径，必须经过正则审查和人工审批。
- 环境信息上传前会脱敏。
- 本地终端默认展示完整执行输出；脱敏摘要只用于 AI 上下文、审计日志和会话摘要。
- 每次会话写入 JSONL 审计日志和 Markdown 摘要。
- 任一步失败后中断当前计划，标记未执行步骤，并请求 AI 生成回滚或修复建议，但不会自动执行修复计划。

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
bash test_config.sh --live
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

在 REPL 中输入 `/` 或 `/前缀` 后回车会打开内置命令菜单。菜单带中文说明，可用上下键选择，回车确认，Esc 取消。`/mode` 会在所有模式中打开模式选择菜单。

## 可选开关

这些开关分为一次性环境变量、命令行开关和 `config/config.json` 持久配置。默认情况下，本地终端展示人类可读输出，日志和 AI 上下文仍写入脱敏摘要。

### 环境变量

| 开关 | 默认值 | 作用 | 示例 |
| --- | --- | --- | --- |
| `LINUX_AGENT_OUTPUT_JSON=1` | 关闭 | 将 work、script、terminal、edit 的最终输出切回机器可读 JSON。适合自动化脚本或回归测试；默认关闭时会隐藏 `ok`、`tool` 等协议字段并保留表格换行。 | `LINUX_AGENT_OUTPUT_JSON=1 bash bin/agent work "查看cpu占用"` |
| `LINUX_AGENT_MOCK=1` | 关闭 | 不调用真实 AI API，使用内置 mock 响应验证流程。适合开发、测试和无网络环境。 | `LINUX_AGENT_MOCK=1 bash bin/agent work "帮我检查磁盘空间是否异常"` |
| `EDITOR=<命令>` | 系统 `vi` | 编辑模式打开脚本确认/修改时使用的编辑器。 | `EDITOR=nano bash bin/agent edit "创建一个 skill"` |

`LINUX_AGENT_OUTPUT_JSON=1` 可以用于所有会产生执行结果的入口：

```bash
LINUX_AGENT_OUTPUT_JSON=1 bash bin/agent work "帮我检查磁盘空间是否异常"
LINUX_AGENT_OUTPUT_JSON=1 bash bin/agent script ops-basic/process-inspect '{"pattern":"systemd"}'
LINUX_AGENT_OUTPUT_JSON=1 bash bin/agent terminal "printf hello"
LINUX_AGENT_OUTPUT_JSON=1 bash bin/agent edit "创建一个检查 nginx 日志的 skill"
```

### 命令行开关和模式

| 开关/命令 | 作用 |
| --- | --- |
| `bash bin/agent plan "<需求>"` | 只生成并展示工作计划，不执行任何步骤。 |
| `bash test_config.sh --live` | 本地配置校验通过后，发送一次最小 Chat Completions 请求，验证 API URL、模型和密钥。默认 `bash test_config.sh` 不访问网络。 |
| `bash bin/agent -h` / `--help` / `help` | 显示 CLI 帮助。 |
| REPL 中的 `/mode` | 打开模式选择菜单，在 work、edit、script、terminal 之间切换。 |

### `config/config.json` 配置开关

| 字段 | 默认值 | 可选值/格式 | 作用 |
| --- | --- | --- | --- |
| `request_timeout_sec` | `90` | 正整数秒数 | AI 请求超时时间。 |
| `context_turns` | `6` | 非负整数 | 上传给 AI 的历史会话轮数；`0` 表示不带历史。 |
| `audit_mode` | `safe_summary` | `safe_summary`、`redacted_verbose` | 审计写入模式。`safe_summary` 只保存结构化摘要；`redacted_verbose` 保存更完整但仍脱敏的内容。 |
| `audit_text_limit` | `1000` | 正整数字符数 | 审计自由文本预览长度。 |
| `skills_dir` | 项目内 `skills/` | 目录路径或空字符串 | 自定义 skill 目录；留空使用项目内 `skills/`。 |
| `remote_script_policy` | `download_review` | `download_review`、`disabled` | 远程脚本策略。`download_review` 会先下载并展示校验信息再审批；`disabled` 直接禁用远程脚本。 |

## 运行流程

工作模式流程：

1. `bin/agent` 进入 `linux_agent_process_work_request`。
2. `lib/sense.sh` 根据用户输入采集最小必要的环境摘要；无法识别主题时只上传最小上下文。
3. `lib/context.sh` 调用 `lib/common.sh` 的统一净化器，对当前输入、历史会话、环境信息和 `skills/INDEX.md` 脱敏后构造请求上下文。
4. `lib/ai.sh` 调用 OpenAI-compatible API，请求 `answer` 或 `work_plan`。
5. `lib/executor.sh` 展示总体计划，并逐步骤执行。
6. 每个步骤先由 `lib/policy.sh` 正则审查，再请求人工选择：`y` 执行、`n` 拒绝当前计划、`s` 跳过或提供修改需求、`t` 终止当前计划。
7. `skill_script` 步骤由 `lib/skills.sh` 校验登记状态后运行。
8. `lib/audit.sh` 按审计模式写入脱敏后的 `logs/` 和 `sessions/`。
9. 如果步骤失败，执行器中断计划，并只把脱敏后的失败摘要发给 AI 生成修复建议。
10. 如果用户在步骤审批中选择 `s` 并填写修改需求，当前计划中断，AI 会基于已执行步骤、当前步骤和剩余步骤续写新的工作计划；如果修改需求为空，则仅跳过当前步骤并继续后续步骤。

编辑模式流程：

1. 用户提出 skill 创建或修改需求。
2. `lib/ai.sh` 生成 `skill_edit` JSON。
3. `lib/editor.sh` 展示 AI 生成的待保存脚本内容。
4. 系统总是打开 `$EDITOR` 或 `vi`，由用户确认或手动修改脚本。
5. 如果用户修改了脚本，会按审计模式记录 diff 统计或脱敏后的 diff 片段。
6. 编辑器保存并正常退出即视为人工审核通过；修改后的最终脚本仍必须通过 `lib/policy.sh` 审查后才会写入 `skills/<name>/scripts/`。
7. 系统自动更新 `skills/<name>/SKILL.md` 和 `skills/INDEX.md`。
8. `lib/skills.sh` 校验 skill 结构和脚本登记状态。
9. 如果用户在编辑器中未保存退出（例如 `vi` 的 `:q!`），系统会提示输入修改需求；直接回车会取消保存，填写需求则让 AI 重新生成 `skill_edit` 并再次进入编辑流程。

脚本模式流程：

1. 用户指定 `skill/script` 和 JSON 参数。
2. `lib/skills.sh` 确认脚本同时登记在 `skills/INDEX.md` 和对应 `SKILL.md`。
3. `lib/policy.sh` 审查脚本文本和参数上下文。
4. 用户审批后执行脚本。

终端模式流程：

1. 用户通过 `/terminal` 进入终端模式，或使用 `agent terminal "<shell命令>"` 单次执行。
2. 普通输入会直接交给 `bash -lc` 执行，不经过正则阻断或审批。
3. `/mode`、`/work`、`/edit`、`/script`、`/exit` 等命令仍由 CLI 优先捕获，不会传给 shell。
4. 终端命令的 stdout/stderr 会原样呈现给本地用户；会话日志只写入命令文本、退出码和脱敏后的 stdout/stderr 摘要。

工作模式、脚本模式、终端模式和编辑模式的本地呈现会把工具返回的 JSON 转成人类可读输出，保留表格换行和制表符，并隐藏 `ok`、`tool` 等协议字段；编辑模式会以摘要展示 skill 编辑计划、脚本审查和保存结果，脚本正文仍按真实文件内容展示。需要兼容旧的机器可读输出时，使用上文的 `LINUX_AGENT_OUTPUT_JSON=1`。

## 配置

### `config/config.example.json`

配置模板。首次运行时，如果 `config/config.json` 不存在，`lib/config.sh` 会从此文件复制一份。

字段说明：

- `provider`: 提示当前 API 类型，默认是 OpenAI-compatible。
- `api_url`: Chat Completions 兼容接口地址。
- `api_key`: API 密钥；示例中是占位值。
- `model`: 调用的模型名。
- `request_timeout_sec`: AI 请求超时时间。
- `context_turns`: 上传给 AI 的历史会话轮次数。
- `audit_mode`: 审计模式，支持 `safe_summary` 和 `redacted_verbose`；默认 `safe_summary`，只持久化脱敏摘要。
- `audit_text_limit`: 审计自由文本截断长度；默认 `1000`。
- `skills_dir`: skill 目录；留空时使用项目内 `skills/`。
- `remote_script_policy`: 远程脚本策略，支持 `download_review` 或 `disabled`。`download_review` 会先下载、校验 HTTPS/大小/文本内容，展示 SHA256、行数和前 40 行脱敏预览后再审批。

### `config/config.json`

本地运行配置。它可能包含真实 API key，因此被 `.gitignore` 忽略。该文件不是多余文件，运行时由 `lib/config.sh` 读取。

## 文件说明

### 根目录

- `.gitignore`
  忽略本地配置和运行产物：`config/config.json`、`logs/`、`sessions/`、`tmp/`。

- `README.md`
  项目说明文档，描述运行方式、架构和每个文件的职责。

- `test_config.sh`
  配置校验脚本。默认只检查 `config/config.json` 是否存在、JSON 是否合法、关键字段是否配置、数值字段是否合理、skill 目录是否可用；不会打印 `api_key`，也不会访问网络。加 `--live` 时会发送一次最小 Chat Completions 请求，用于确认 API URL、模型和密钥是否真的可用。

### `bin/`

- `bin/agent`
  唯一 CLI 入口。负责加载所有 `lib/*.sh`，初始化环境和配置，提供 REPL、子命令路由、帮助信息。支持 `work`、`edit`、`script`、`terminal`、`plan`、`doctor`、`sense`、`tools list`、`skills validate`、`audit`。

### `lib/`

- `lib/common.sh`
  基础环境初始化、通用输出函数和统一净化器。定义项目根目录、日志目录、会话目录、配置路径、skill 目录、临时目录，并创建运行时目录；集中处理 token、password、secret、Authorization、Cookie、Bearer token、私钥片段等信息脱敏。

- `lib/config.sh`
  配置加载与读取。检查 `jq`，缺少 `config/config.json` 时从示例配置生成，并提供 `linux_agent_config_get` 和默认值读取函数。

- `lib/audit.sh`
  审计与会话日志系统。负责创建 session id、按 `safe_summary` 或 `redacted_verbose` 写入脱敏后的 JSONL 审计流和 Markdown 会话摘要、记录步骤状态、展示历史审计。

- `lib/context.sh`
  上下文系统。维护内存中的会话历史窗口，构造 AI 请求上下文，并在写入历史和发送模型前调用统一净化器。

- `lib/sense.sh`
  环境感知系统。根据用户输入识别主题，并采集最小必要的磁盘、进程、网络、日志、服务、权限摘要。工作模式会把采集结果脱敏后放入 AI 请求。

- `lib/skills.sh`
  skill 管理系统。解析 `skill/script` 引用，定位脚本路径，检查脚本是否同时登记在 `skills/INDEX.md` 和 `SKILL.md`，运行 skill 脚本，并校验整个 skill 目录。

- `lib/doctor.sh`
  自检系统。检查必需命令、可选命令、配置 JSON 和 skill 目录是否有效。`bash bin/agent doctor` 调用此文件。

- `lib/ai.sh`
  AI 接入层。构造系统提示词，调用 OpenAI-compatible Chat Completions API，校验 `work_plan` 和 `skill_edit` schema，并提供 mock 响应用于测试或未配置 API 时兜底。

- `lib/policy.sh`
  正则审查系统。读取 `policies/risk-rules.json`，对 shell 命令、skill 脚本文本、远程脚本文本和参数上下文做黑名单/警告审查，并合并步骤风险等级；远程脚本最低按 high 风险人工审批。

- `lib/executor.sh`
  执行状态机。展示工作计划，逐步展示步骤、审查、审批、执行；支持 `skill_script`、`shell`、`remote_script`；远程脚本会先展示下载校验信息和脱敏预览，失败时标记未执行步骤并请求 AI 生成修复建议。

- `lib/editor.sh`
  编辑模式实现。应用 AI 生成的 skill 变更包，展示脚本原稿，强制打开编辑器供用户确认或修改，对最终脚本重新审查和审批，记录用户修改 diff，自动生成或更新 `SKILL.md` 和 `skills/INDEX.md`，最后调用 skill 校验。

- `lib/interactive.sh`
  REPL 交互辅助层。实现 `/` 命令菜单、模式选择菜单、上下键读取、中文说明渲染，以及非 TTY 测试场景下的确定性菜单选择。

- `lib/orchestrator.sh`
  高层编排器。连接工作模式、编辑模式、脚本模式、终端模式，把环境感知、上下文构造、AI 响应、执行器、审计和历史记录串起来。

### `prompts/`

- `prompts/system.txt`
  系统提示词。定义 AI 的角色、请求上下文字段、`answer`/`work_plan`/`skill_edit` 输出 schema，以及安全约束。

### `policies/`

- `policies/risk-rules.json`
  正则审查规则。包含：
  - `blocked_patterns`: 命中后直接阻断的危险命令。
  - `warn_patterns`: 命中后提升风险并要求审批的命令。
  - `remote_script_blocked_patterns`: 远程脚本额外阻断规则。
  - `protected_paths`: 关键路径保护规则。
  - `protected_services`: 关键服务保护规则。
  - `risk_levels`: 风险等级说明。

### `skills/`

- `skills/INDEX.md`
  skill 总索引。工作模式会把它上传给 AI，脚本模式也用它确认脚本是否登记。新增 skill 时必须更新此文件。

- `skills/ops-basic/SKILL.md`
  内置基础运维 skill 的渐进式说明。描述 `ops-basic` 支持的脚本、参数和推荐工作流。

- `skills/ops-basic/scripts/disk-hotspots.sh`
  skill 包装脚本，调用 `tools/local/disk_hotspots.sh`。用于采集磁盘占用、热点目录和大文件。

- `skills/ops-basic/scripts/log-search.sh`
  skill 包装脚本，调用 `tools/local/log_inspect.sh`。用于检索 `/var/log` 下的日志文件；默认不读取 journal，可通过 `include_journal=true` 显式启用。

- `skills/ops-basic/scripts/log-cleanup-plan.sh`
  skill 包装脚本，调用 `tools/local/log_cleanup_plan.sh`。用于生成日志清理候选，不直接清理。

- `skills/ops-basic/scripts/resource-inspect.sh`
  skill 包装脚本，调用 `tools/local/resource_inspect.sh`。用于查看 CPU 负载、内存概况和高 CPU/内存进程。

- `skills/ops-basic/scripts/process-inspect.sh`
  skill 包装脚本，调用 `tools/local/process_inspect.sh`。用于查看进程、僵尸进程和匹配进程。

- `skills/ops-basic/scripts/service-inspect.sh`
  skill 包装脚本，调用 `tools/local/service_inspect.sh`。用于查看 systemd 服务状态和失败服务。

- `skills/ops-basic/scripts/config-backup.sh`
  skill 包装脚本，调用 `tools/local/config_backup.sh`。用于变更或清理前备份目标路径。

- `skills/ops-basic/scripts/safe-log-cleanup.sh`
  skill 包装脚本，调用 `tools/local/safe_log_cleanup.sh`。用于在限定路径内安全截断非关键日志。

- `skills/ops-basic/scripts/service-restart-plan.sh`
  skill 包装脚本，调用 `tools/local/service_restart_plan.sh`。用于生成服务重启前的只读预检计划，不直接重启。

### `tools/local/`

这些文件是本地确定性后端脚本。它们不是旧架构残留；`skills/ops-basic/scripts/*` 会调用它们，以便 skill 层负责登记和审批，本地脚本层负责具体 Linux 检查逻辑。

- `tools/local/disk_hotspots.sh`
  接收 `path`、`top_n`，输出磁盘空间、一级目录占用和大文件列表。

- `tools/local/log_inspect.sh`
  接收 `path`、`keyword`、`lines`、`include_journal`，仅允许检索解析后仍位于 `/var/log` 下的日志路径；默认不读取 journal，输出内容会先脱敏并截断。

- `tools/local/log_cleanup_plan.sh`
  接收 `root_path`、`min_size_mb`、`max_depth`、`limit`，只扫描 `/var/log` 或 `/tmp`，输出候选日志、拒绝原因和推荐 skill 步骤。

- `tools/local/resource_inspect.sh`
  接收 `top_n`，输出 CPU 负载、CPU 型号/核心数、内存概况和高 CPU/内存进程。

- `tools/local/process_inspect.sh`
  接收 `pattern`，输出高 CPU 进程、僵尸进程和匹配进程。

- `tools/local/service_inspect.sh`
  接收 `service`，输出指定服务状态和失败服务列表。

- `tools/local/config_backup.sh`
  接收 `path`、`backup_root`，对目标文件或目录创建 tar.gz 备份。

- `tools/local/safe_log_cleanup.sh`
  接收 `path`、`max_size_mb`、`dry_run`，只允许处理 `/var/log` 或 `/tmp` 下的普通非关键日志，支持 dry run 和真实截断。

- `tools/local/service_restart_plan.sh`
  接收 `service`，输出服务重启预检信息。关键服务会标为高风险，不执行重启。

### `tests/`

- `tests/smoke.sh`
  冒烟测试。覆盖 mock 工作模式、plan 模式、脚本模式和 skill 索引输出。

- `tests/policy.sh`
  策略测试。覆盖关键路径阻断、远程管道执行阻断、写入/篡改类规则、远程脚本强制审批和警告级规则。

- `tests/tools.sh`
  工具和 skill 测试。直接运行 `tools/local` 后端脚本，检查日志检索边界、doctor、skill 校验和 skill 脚本执行。

- `tests/security.sh`
  安全测试。覆盖统一脱敏、审计模式、远程脚本下载审查、远程脚本强制高风险审批和远程脚本文件限制。

- `tests/workflow.sh`
  工作流测试。覆盖失败中断、修复建议展示、用户拒绝审批、跳过步骤、修改需求续写计划、终止计划和非法脚本路径阻断。

- `tests/interactive.sh`
  交互优化测试。覆盖 `/` 命令菜单、`/terminal` 模式、终端命令审计、编辑模式手动修改 diff 记录、未保存退出后的修改需求，以及修改后命中黑名单时阻断保存。

### 运行时目录

- `logs/`
  JSONL 审计日志目录。每个会话生成一个 `.jsonl` 文件，内容按审计模式脱敏和摘要化。属于运行产物，已在 `.gitignore` 中忽略，可按需清理。

- `sessions/`
  Markdown 会话摘要目录。每个会话生成一个 `.md` 文件，内容按审计模式脱敏和摘要化。属于运行产物，已在 `.gitignore` 中忽略，可按需清理。

- `tmp/`
  临时文件目录。远程脚本下载审查和编辑模式更新索引时会使用。已在 `.gitignore` 中忽略。



## 测试

```bash
bash tests/smoke.sh
bash tests/policy.sh
bash tests/tools.sh
bash tests/security.sh
bash tests/workflow.sh
bash tests/interactive.sh
bash bin/agent doctor
bash test_config.sh
```

也可以使用 mock 模式验证工作流：

```bash
LINUX_AGENT_MOCK=1 bash bin/agent work "帮我检查磁盘空间是否异常"
```

依赖：

- 必需：`bash`、`jq`、`curl`、`find`、`du`、`df`、`ps`、`grep`、`tar`
- 可选：`systemctl`、`journalctl`、`ss`、`ip`、`lsof`、`sudo`。缺少可选命令只会减少对应环境感知信息，不会让 `doctor` 失败。
