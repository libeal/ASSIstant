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
| Terminal | `bash bin/agent terminal "<命令>"` | 对本机 shell 命令做策略审查；低风险命令是否自动执行由 `approvals.auto.shell_readonly` 控制，高风险或提权命令请求确认。 |
| Doctor | `bash bin/agent doctor` | 检查依赖、配置 JSON、skill 目录和基础运行环境。 |
| Sense | `bash bin/agent sense <topic>` | 按主题采集环境信息，支持 `all`、`disk`、`resource`、`process`、`network`、`service`、`logs`、`privilege`、`minimal`。 |
| Tools | `bash bin/agent tools list` | 输出 `skills/INDEX.md` 中登记的可执行 skill 索引。 |
| Skills | `bash bin/agent skills validate` | 校验 skill 目录、`SKILL.md`、脚本和索引登记一致性。 |
| MCP | `bash bin/agent mcp list` / `bash bin/agent mcp validate` / `bash bin/agent mcp tools` | 列出、校验并发现 `mcp/` 下安装的外部 MCP server tools。 |
| Policy | `bash bin/agent policy validate [file]` | 校验 `policies/` 下策略 JSON、正则和审计边界。 |
| Audit | `bash bin/agent audit <session-id>` / `bash bin/agent audit verify <session-id>` / `bash bin/agent audit export <session-id>\|--all [--output <目录>]` | 读取历史 JSONL 审计会话、校验跨轮转 SHA-256 hash chain，或导出带完整性证明的离线证据包。 |
| Backup | `bash bin/agent backup <output.tar.gz>` | 导出脱敏配置、运行日志和用户 skill，用于诊断或迁移。 |
| API | `bash bin/agent api <resource> <action> [json]` | 给 Web 后端调用的机器可读 JSON 接口。 |

交互式 REPL 支持 `/work`、`/edit`、`/script`、`/terminal`、`/mode`、`/help`、`/exit`。输入 `/` 或 `/前缀` 后回车会打开命令菜单。

### Web 控制台

Web 控制台通过 `bash bin/agent-web` 启动，后端只使用 Python 标准库，不依赖 npm、pip 或外部数据库；Job 状态使用标准库 `sqlite3` 的本机 SQLite WAL。它通过 `bash bin/agent api ...` 调用 CLI 核心能力。

Web 视图包括：

- Work 工作台：自然语言任务、terminal 命令、执行时间线、审批抽屉、环境主题刷新。
- Skill 库：script 运行、script 审查、edit 生成、edit 审查、保存、skill 树、Markdown 预览、`skills validate`。
- MCP：读取 `mcp/<id>/mcp.json` 外部 MCP server manifest，校验 stdio、legacy SSE 和 Streamable HTTP 三种传输配置，并在 work/edit 上下文暴露可用 tools。
- Policy：以运维视角查看命令安全检查、校验和编辑 `policies/` 下的 JSON 策略文件（含风险规则、审计边界和文件保险箱）；策略文件通过“查阅文件”弹窗查看，解锁后可编辑保存；命令安全检查默认开启，只有 sudo 核对后才能从 Web 切换。
- Audit：查看 JSONL 审计 session、完整性结果、事件筛选、指标统计和报告导出。新会话可从持久化的权威 protocol turns 恢复工作台；没有 turns 的旧会话只显示只读事件，不再从审计事件推导业务状态。
- Config：读取和保存白名单配置项，运行 Doctor，展示运行时配置快照。

### 内置 Skill

- `ops-basic`: 常用只读巡检、日志搜索、清理计划、备份和安全日志截断。
- `os-deep-inspect`: 更深入的系统快照、网络、文件描述符和 journal 检查。
- `controlled-tools`: 受控文件匹配、字面量补丁、安全下载和本地文本分析；自由 shell 文件修改会被审查拒绝，应使用这些脚本。
- `session-history`: 只读回看审计 session 中上一轮或指定轮次的命令、计划步骤和输出预览。
- `network-ops-tools`: 运维/网络工程工具箱，覆盖 IP Scanner、Port Scanner、Discovery Protocol、Wake on LAN、Network Interface、WiFi、Connections、Listeners、Neighbor Table、Ping Monitor、Traceroute、DNS Lookup、SNTP Lookup、Whois、IP Geolocation、Hosts File Editor、Lookup、SNMP、Firewall、Subnet Calculator、Bit Calculator，以及 TLS Inspect、HTTP Check、Public IP 和 Service Discovery；SNMP 支持 v1/v2c/v3-auth 与 walk/bulk，DNS 内置纯 Python 解析器覆盖全部常见记录类型；所有脚本声明为 `medium` 或 `high`，不能作为 low 风险自动执行。

## 快速开始

### 部署语义说明：`remote` 是「本地 Runtime 分发」

本项目是「单机 Agent + 远程运维客户端」模型，不是集中控制面。请区分两种含义：

- **目标机本地执行**：Agent 的命令执行、审计、配置与 AI 调用都发生在运行它的那台主机本地。
- **客户端控制目标机**：从机器 B 直接控制机器 A 上已运行的 Agent —— 当前版本**不提供**这种远程控制协议。

因此 `curl | bash` 的 `remote` 指的是**把版本化 Runtime 分发（物化）到执行该命令的机器并本地启动**，而不是远程接管另一台已部署主机。支持的访问方式：

1. SSH 登录目标主机后执行 `curl | bash`，Agent 在目标主机本地运行；
2. 目标主机运行 Remote Web（强制 `127.0.0.1`），运维机器通过 SSH 端口转发访问；
3. 在运维机器直接执行 `curl | bash`，则 Agent 运行在运维机器本身。

若未来需要「机器 B 控制机器 A 上已运行的 Agent」，需另行新增经认证的 SSH/RPC 远程适配层（见路线图）。

### 远程临时运行

CLI 固定版本：

```bash
curl -fsSL https://github.com/libeal/ASSIstant/releases/download/vX.Y.Z/linux-agent-cli.sh \
  | LINUX_AGENT_VERSION=vX.Y.Z bash
```

Web 固定版本：

```bash
curl -fsSL https://github.com/libeal/ASSIstant/releases/download/vX.Y.Z/linux-agent-web.sh \
  | LINUX_AGENT_VERSION=vX.Y.Z bash
```

仅临时诊断时可使用浮动 `latest`；bootstrap 会在 stderr 显示实际解析版本和生产环境警告：

```bash
curl -fsSL https://github.com/libeal/ASSIstant/releases/latest/download/linux-agent-cli.sh | bash
```

两条命令都只从同一个 GitHub Release 获取 manifest 和已登记资产。Bootstrap 不保存到本机；core、Web 和按需加载的完整 skill 包优先物化到 `$XDG_RUNTIME_DIR` 或 `/dev/shm`，必要时回退权限为 `0700` 的 `/tmp` 子目录，并在退出或收到信号时清理。

`curl | bash` 只适合临时诊断：管道中的首段脚本尚未取得签名信任，不能靠脚本内部的验证证明自身。生产或敏感主机必须先在非特权目录验证签名 manifest 和入口脚本，再执行：

```bash
version=vX.Y.Z
asset_key=bootstrap_cli                 # Web 改为 bootstrap_web
asset=linux-agent-cli.sh                # Web 改为 linux-agent-web.sh
release_url="https://github.com/libeal/ASSIstant/releases/download/${version}"
verify_dir="$(mktemp -d)"
umask 077
curl -fsSLO --output-dir "${verify_dir}" "${release_url}/release-manifest.json"
curl -fsSLO --output-dir "${verify_dir}" "${release_url}/release-manifest.json.sigstore.json"
curl -fsSLO --output-dir "${verify_dir}" "${release_url}/${asset}"
cosign verify-blob \
  --bundle "${verify_dir}/release-manifest.json.sigstore.json" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github.com/libeal/ASSIstant/\.github/workflows/remote-release\.yml@refs/tags/v.*$' \
  "${verify_dir}/release-manifest.json"
expected_sha="$(jq -er --arg key "${asset_key}" '.assets[$key].sha256' "${verify_dir}/release-manifest.json")"
expected_size="$(jq -er --arg key "${asset_key}" '.assets[$key].size_bytes' "${verify_dir}/release-manifest.json")"
test "$(stat -c '%s' "${verify_dir}/${asset}")" -eq "${expected_size}"
test "$(sha256sum "${verify_dir}/${asset}" | awk '{print $1}')" = "${expected_sha}"
LINUX_AGENT_VERSION="${version}" LINUX_AGENT_REQUIRE_SIGNATURE=1 bash "${verify_dir}/${asset}"
```

Remote CLI 会从 `/dev/tty` 读取审批和可选 API key，密钥不写入配置文件。Remote Web 强制监听 `127.0.0.1`，从其他机器访问时使用启动日志打印的 SSH 转发命令；本次运行的临时 token 写入运行时目录下权限 `0600` 的 `tmp/web/auth-token`（不在终端回显）。Remote 部署会自动把 `providers_security.require_https` 置为 `true`（仅允许 HTTPS Provider）。

Remote 模式默认禁止向 AI Provider 传输 API key。CLI 会在需要 AI 时询问；Web 需在配置中心开启“允许远程传输 API Key”。Terminal、Doctor、Audit 和不需要模型的 Skill 不受此开关影响。运行日志、脱敏配置和用户生成的 skill 可通过 `agent backup <output.tar.gz>` 或 Web“下载运行时备份”按钮显式保存。

### 生产部署（systemd）

生产环境必须先验证固定版本的 manifest，再按其中登记的摘要验证安装器，最后才允许授予 root 权限。安装器还会再次校验自身和下游资产。版本化代码放到 `/opt/linux-agent/releases/`，通过原子 `current` 符号链接切换版本；配置、日志和临时状态持久化在 `/opt/linux-agent/data/`。

```bash
version=vX.Y.Z
release_url="https://github.com/libeal/ASSIstant/releases/download/${version}"
umask 077
curl -fsSLO "${release_url}/release-manifest.json"
curl -fsSLO "${release_url}/release-manifest.json.sigstore.json"
curl -fsSLO "${release_url}/linux-agent-install.sh"
cosign verify-blob \
  --bundle release-manifest.json.sigstore.json \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github.com/libeal/ASSIstant/\.github/workflows/remote-release\.yml@refs/tags/v.*$' \
  release-manifest.json
expected_sha="$(jq -er '.assets.installer.sha256' release-manifest.json)"
expected_size="$(jq -er '.assets.installer.size_bytes' release-manifest.json)"
test "$(stat -c '%s' linux-agent-install.sh)" -eq "${expected_size}"
test "$(sha256sum linux-agent-install.sh | awk '{print $1}')" = "${expected_sha}"
sudo bash linux-agent-install.sh install --version "${version}" --require-signature \
  --provider-cidr 203.0.113.0/24 --provider-cidr 2001:db8:1234::/48
sudo bash linux-agent-install.sh upgrade --version vX.Y.NEW --require-signature
sudo bash linux-agent-install.sh rollback
sudo bash linux-agent-install.sh health
sudo bash linux-agent-install.sh status
```

### Prometheus 指标

Web 控制台提供 `GET /api/metrics`（Prometheus 文本格式，Bearer token 保护）。默认开启，可在配置中设置 `web.metrics_enabled=false` 关闭。

```bash
curl -fsS -H "Authorization: Bearer $LINUX_AGENT_WEB_TOKEN" \
  http://127.0.0.1:8765/api/metrics
```

Prometheus scrape 示例（自定义 Authorization header）：

```yaml
scrape_configs:
  - job_name: linux-agent-web
    metrics_path: /api/metrics
    authorization:
      type: Bearer
      credentials: <web-token>
    static_configs:
      - targets: ["127.0.0.1:8765"]
```

`upgrade` 切换后会重启 observer helper socket 与 Web 服务，并轮询认证后的 `/api/health`，失败时自动恢复旧版本。生产安装同时部署 root auditd helper 的 service/socket；主 Web 进程仍以专用非 root 用户运行，helper 只接受固定 JSON 协议和 syscall allowlist，不接受命令文本。默认保留最近两个版本，可用 `--keep` 调整；`uninstall` 默认保留 `data/`，只有 `uninstall --purge-data` 会删除持久数据。systemd 模式的自定义 `--prefix` 应位于 `/opt`、`/srv` 等系统服务目录，安装器会拒绝被 `ProtectHome` 或 `PrivateTmp` 隐藏的 `/home`、`/root`、`/run/user`、`/tmp` 和 `/var/tmp`。容器和测试环境可使用 `--no-systemd --prefix <目录>`，本地发布演练可增加 `--from-dist <目录>`。

首次 systemd 安装必须明确网络出口策略。重复传入 `--provider-cidr` 后，安装器会事务化生成 `IPAddressDeny=any`、放行 localhost 和所列 IPv4/IPv6 CIDR 的 drop-in；升级和回滚默认保留该策略，失败回滚也会恢复旧文件。CIDR 应覆盖主 Provider、所有 failover Provider，以及未使用本机 DNS stub 时的 DNS 服务地址；地址变化后重新运行 upgrade 并传入新列表。确实无法固定出口网段时必须显式使用 `--allow-unrestricted-provider-egress`，安装器会给出警告，不能以“未配置”静默获得无限制出口。

bootstrap 和 installer 的签名策略相同：系统存在 cosign 且 release 带 bundle 时必须验证成功；未安装 cosign 时默认提示并继续 SHA256 校验；`LINUX_AGENT_REQUIRE_SIGNATURE=1` 或 `--require-signature` 会在 cosign、bundle 或验证缺失时拒绝运行。私有部署可设置 `LINUX_AGENT_SIGNATURE_PUBKEY=<公钥路径>`，内部会以 `--offline --insecure-ignore-tlog` 验证未上传公共 Rekor 的本地密钥签名；fork 可通过 `LINUX_AGENT_SIGNATURE_IDENTITY` 和 `LINUX_AGENT_SIGNATURE_ISSUER` 收窄 keyless 身份。

Release 同时提供 SPDX 2.3 SBOM、Sigstore bundle 和 GitHub build provenance。签名 manifest 登记全部业务资产、SBOM 与 `SHA256SUMS`；`SHA256SUMS` 校验业务资产和 SBOM，manifest 本身由 cosign 验证，避免摘要自引用：

```bash
cosign verify-blob \
  --bundle release-manifest.json.sigstore.json \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github.com/libeal/ASSIstant/\.github/workflows/remote-release\.yml@refs/tags/v.*$' \
  release-manifest.json
sha256sum -c SHA256SUMS
gh attestation verify linux-agent-core.tar.gz --repo libeal/ASSIstant
jq '.packages, .files' sbom.spdx.json
```

### Debian 与 Fedora 安装包

项目可生成两个不携带第三方库的精简本地安装包。Debian/Ubuntu 包从 `apt` 软件源安装 `requirements/debian.txt`，Fedora/RHEL 包按 `requirements/fedora.txt` 调用 `yum install -y`：

```bash
SOURCE_DATE_EPOCH=0 bash scripts/build-install-packages.sh v1.1.2
tar -xzf linux-agent-v1.1.2-debian.tar.gz
cd linux-agent-v1.1.2-debian
sudo bash install.sh
```

Fedora 使用同名的 `linux-agent-v1.1.2-fedora.tar.gz`。两个包都只包含 core、Web、Skill、安装器、对应依赖清单和校验文件；不会包含测试、日志、缓存、Git 数据、Python site-packages 或 npm 模块。追加 `--with-optional-tools` 可安装网络与 audit Skill 的可选系统工具；依赖已由镜像或配置管理准备好时可使用 `--skip-dependencies`。

### 本地运行

```bash
cp config/config.example.json config/config.json
bash test_config.sh
bash bin/agent
```

配置最少需要修改：

```bash
export LINUX_AGENT_API_KEY="你的密钥"
```

`config/config.json` 中仍需配置 `api_url` 和 `model`。如果不想使用环境变量，也可以在 `config.json` 中设置 `api_key` 作为兜底。

如需启用文件保险箱，在 `policies/file-vault.json` 的 `paths` 中登记规范绝对路径；默认空数组表示不启用。建议先校验，再通过 Web Policy 页面或受保护的策略写入流程保存：

```bash
bash bin/agent policy validate file-vault.json
```

工作模式修改保险箱文件会被直接阻断，读取需要审批；终端模式访问或修改需要人工确认。末尾 `/*` 仅表示目录及其嵌套文件，不支持中间通配符。

启动 Web：

```bash
bash bin/agent-web
```

默认访问 `http://127.0.0.1:8765/`。静态页面不需要认证，业务 `/api/` 请求都需要 `Authorization: Bearer <token>`（认证使用常量时间比较，不再支持 `X-Agent-Token` 备用头）；仅启动器使用的一次性 `/api/auth/bootstrap` 凭据例外。如果 `web.token` 留空，启动时会用系统 CSPRNG 生成本次运行的临时 token，并写入权限 `0600` 的 `tmp/web/auth-token` 文件（不在终端回显），退出时清理；配置文件 `config/config.json` 写入时也会强制 `0600`。

在本机桌面会话中，`agent-web` 会自动打开前端外壳：启动器把一次性 bootstrap 凭据放在 URL fragment，前端换取 token 后立即清理地址栏并连接，真实 token 不会进入 URL、HTTP 日志或静态 HTML。无图形桌面、Remote 模式或不希望自动打开浏览器时，可设置 `LINUX_AGENT_WEB_AUTO_OPEN=0`，仍可在右上角手动输入 token；显式设为 `1` 可在受控桌面环境强制打开。
systemd 生产部署会通过 `/run/linux-agent/observer.sock` 自动使用独立 auditd helper，不向浏览器索取 sudo 密码；socket 存在但 helper 失败时不会降级回 sudo。本地手工启动且没有 helper 时，Web 才沿用一次性 sudo bootstrap。跳过或启用失败都会写入 Web 审计日志。默认 `observer.require=false` 时按降级模式继续；强合规环境设置为 `true` 后，observer 不可用或规则失效会拒绝真实执行。`observer.privilege=none` 会同时禁用 helper 与 sudo。

常用命令：

```bash
bash bin/agent work "帮我检查磁盘空间是否异常"
bash bin/agent script ops-basic/process-inspect '{"pattern":"systemd"}'
bash bin/agent terminal "printf hello"
bash bin/agent sense disk
bash bin/agent tools list
bash bin/agent skills validate
bash bin/agent mcp list
bash bin/agent mcp validate
bash bin/agent mcp tools
bash bin/agent policy validate
bash bin/agent audit <session-id>
bash bin/agent audit verify <session-id>
bash bin/agent audit export <session-id> --output /secure/evidence
bash bin/agent audit export --all --output /secure/evidence
```

审计 hash chain 是强制不变量，不能通过配置或 CLI 关闭；每个事件始终包含 `seq`、`prev_hash` 和 `hash`。升级配置如果仍含旧的 `audit.integrity_chain` 字段，CLI/Web 会要求删除该字段后再启动。追加只校验最后一个非空事件及其自身 hash，写入成本不随历史事件数增长。跨分段全链检查是显式职责：取证、导出或合规检查前运行 `audit verify`；中间事件或旧归档损坏会由该命令报告，但不会阻止后续追加。

`agent backup` 面向诊断和迁移，导出脱敏配置、运行日志与用户 skill；`agent audit export` 只导出审计 session、全部轮转段、逐 session 完整性报告、文件摘要 manifest 和 `SHA256SUMS`，适合交给 SIEM、对象存储或合规采集流程。导出先取得加锁快照，因此不会把写入中的不同链尾混入同一证据包。

机器可读 API 示例：

```bash
bash bin/agent api health
bash bin/agent api tools list
bash bin/agent api sense get '{"topic":"resource"}'
bash bin/agent api script review '{"ref":"ops-basic/resource-inspect","arguments":{"top_n":1}}'
bash bin/agent api policy validate '{"path":"risk-rules.json"}'
bash bin/agent api terminal run '{"command":"printf api-ok"}'
bash bin/agent api terminal run '{"command":"printf api-ok"}' | jq '.timeline, .approval_card, .output_blocks'
```

## 项目架构

项目按“入口层 -> 核心 Bash 层 -> Web 外壳层 -> 策略与提示层 -> 能力层 -> 配置层 -> 测试层 -> 运行时产物层”组织。CLI 是项目核心，Web 通过同一套 CLI/API 能力提供浏览器体验，测试层使用 fake AI 和脚本验证主流程，不参与项目主体运行。

从演进角度看，项目应始终保持“核心引擎 + 多入口适配器 + 可扩展能力系统”的边界：

- 入口层：`bin/agent`、`bin/agent-web`、Web API，以及 GitHub Release 中的 CLI/Web 官方 remote bootstrap。
- 编排层：任务解析、上下文采集、AI 调用、响应校验、work/edit/script/terminal 调度。
- 执行层：shell、skill_script、remote_script、文件编辑等执行器，以及 policy、approval、observer、audit。
- 能力层：skills、mcp、policies、prompts、config、audit、context 等可替换或可扩展资源。

不同入口共享同一套核心能力，AI 只提出计划，执行层独立审查、确认、执行和审计。

```text
Linux 运维 Agent
├─ 入口层
│  ├─ bin/agent              CLI 主入口，加载 lib 并路由 work/edit/script/terminal/doctor/sense/tools/skills/mcp/policy/api/audit/backup
│  └─ bin/agent-web          Web 启动入口，读取 Web 配置并启动 Python 后端
├─ 核心 Bash 层 lib/
│  ├─ 基础设施
│  │  ├─ common.sh           根目录、临时目录、脱敏、JSON 参数规范化
│  │  ├─ config.sh           配置读取和默认值
│  │  ├─ audit.sh            JSONL 审计和审计报告
│  │  ├─ audit_chain.py      hash chain、fsync、轮转、磁盘策略与校验器
│  │  ├─ backup.sh            运行时脱敏备份
│  │  └─ context.sh          会话历史和模型上下文
│  ├─ 感知与校验
│  │  ├─ sense.sh            环境采集
│  │  ├─ doctor.sh           本地健康检查
│  │  ├─ skills.sh           skill 解析、登记和校验
│  │  ├─ mcp.sh              MCP manifest 发现、脱敏和校验
│  │  ├─ policy.sh           风险规则审查
│  │  └─ file_vault.py       文件保险箱静态访问分类器（读取/修改/未知）
│  ├─ AI 与编排
│  │  ├─ ai.sh               模型请求、响应规范化和 schema 校验
│  │  ├─ orchestrator.sh     work/edit/script/terminal 高层编排和反思循环
│  │  ├─ executor.sh         work plan 执行状态机、审批输入队列和自动批准判断
│  │  ├─ command_guard.py    Python 标准库 AST/Token 命令风险守卫
│  │  ├─ protocol.sh         timeline、approval_card、output_blocks 协议构造器
│  │  ├─ editor.sh           skill edit/staging/提交
│  │  ├─ observer.sh         auditd observer 和降级记录
│  │  ├─ api.sh              机器可读 API
│  │  ├─ mcp_client.py       MCP stdio/SSE/Streamable HTTP 客户端
│  │  ├─ provider_security.py Provider URL 校验、SSRF 防护与地址解析
│  │  ├─ workflow.sh         CLI/API 共用的 Work 准备与执行选择
│  │  └─ interactive.sh      REPL 菜单和模式选择
├─ Web 外壳层 web/
│  ├─ server.py              标准库 HTTP 路由、认证与服务编排
│  ├─ jobs.py                SQLite WAL JobStore、幂等、版本和恢复
│  ├─ sessions.py            工作台/Job 私有上下文、合并事务和持久化 turns
│  ├─ execution.py           子进程、超时、取消、输出与环境隔离
│  ├─ audit.py               Web 审计适配器（复用 audit_chain）
│  ├─ metrics.py             Prometheus 指标注册、低基数路由和文本渲染
│  ├─ domain.py              schema/domain.json 运行时契约校验
│  ├─ timeline.py            只消费持久化 protocol turns 的时间线视图
│  ├─ provider.py            Provider 配置与模型服务
│  ├─ policy.py              Policy 文件与 sudo 写入服务
│  ├─ skills.py              Skill 文件树服务
│  └─ static/
│     ├─ index.html          Web 页面结构
│     ├─ app.js              前端工作台入口
│     ├─ modules/            无构建 ES modules：API、状态、布局、Job、Work/Skill/Policy/Audit/Config 视图及纯函数测试模块
│     ├─ styles.css          页面样式
│     └─ mark.svg            Web 图标
├─ 策略与提示层
│  ├─ prompts/system.txt     模型系统提示和输出约束
│  └─ policies/
│     ├─ risk-rules.json     阻断、警告、保护路径和保护服务规则
│     ├─ redaction-rules.json 脱敏规则集中配置
│     ├─ audit-boundaries.json audit/observer 允许观察边界
│     └─ file-vault.json     用户自定义的敏感文件保险箱路径，默认为空
├─ Skill 能力层 skills/
│  ├─ INDEX.md               可执行 skill 白名单
│  ├─ ops-basic/             基础巡检、日志、备份和安全清理 skill
│  ├─ os-deep-inspect/       深度系统、网络、FD 和 journal 检查 skill
│  ├─ controlled-tools/      受控文件匹配、补丁、下载和本地文本分析 skill
│  ├─ session-history/       只读审计 session 历史输出回看 skill
│  └─ network-ops-tools/     运维/网络工程常用诊断、查询、扫描和计算 skill
├─ MCP 能力层 mcp/
│  └─ <server-id>/mcp.json    外部 MCP server manifest，支持 stdio、sse、streamable_http
├─ 领域契约 schema/
│  └─ domain.json             API、Job、turn、步骤和错误状态的共享 JSON schema
├─ 配置层
│  ├─ config/config.example.json 模板配置
│  ├─ config/ai-providers.json AI 厂商预设、鉴权方式和模型列表规则
│  └─ config/config.json     本地实际配置，忽略提交
├─ 测试层 tests/
│  ├─ fake_ai_server.py      测试用 Chat Completions 兼容服务
│  ├─ helpers.sh             测试辅助函数
│  ├─ *.sh                   CLI、Web、策略、安全、observer、交互、安装和发布测试
│  ├─ test_web_*.py          Web 服务与领域模块单元测试
│  └─ web_*.mjs              无 npm 依赖的前端模块和协议测试
├─ 发布与部署 packaging/、remote/、scripts/
│  ├─ packaging/             systemd 单元和权限边界说明
│  ├─ remote/bootstrap.sh    CLI/Web 临时 Remote runtime bootstrap
│  └─ scripts/               发布构建、签名、发布、安装和 lint 工具
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
- MCP 能力层提供外部 MCP server manifest registry 和 tools/list 发现；实际 tools/call 只能作为 work_plan 的 `mcp_tool` 步骤进入审批执行。
- 配置层保存模板和本地运行配置，本地敏感配置不进入版本库。
- 测试层包含 fake AI 和回归脚本，只服务验证流程，不应被主流程依赖。
- 运行时产物层保存日志、临时状态和缓存，均为本地生成内容。

### Skill Registry 边界

skill registry 同时支持本地目录和 Remote Release manifest；`skills/INDEX.md`、`skills/<name>/SKILL.md`、包内脚本与 manifest refs 必须互相一致。调用方应通过 `lib/skills.sh` 提供的函数列出、检查、物化、读取和执行 skill，而不是绕过 registry 直接拼路径。

Remote runtime 首次只加载索引与 Release manifest 元数据，执行前按一级 skill 整包 materialize，校验来源、大小、摘要、归档边界、INDEX/包内脚本集合和 policy 后，再交给现有 approval、observer 与 audit 流程。

### MCP Registry 边界

`mcp/` 是外部 MCP server manifest 目录，推荐形态是 `mcp/<server-id>/mcp.json`。registry 负责发现、校验、脱敏展示和 `tools/list` 目录生成；实际 `tools/call` 不提供独立 CLI/Web 任意调用入口，只能由 work 模式计划生成 `executor_type:"mcp_tool"` 的步骤后，经 policy、人工审批、observer 和 audit 执行。edit 模式只能看到 MCP 目录作为生成 skill 的参考，不能直接执行 MCP。

支持的 manifest transport：

- `stdio`：本地子进程 stdin/stdout JSON-RPC。
- `sse`：兼容旧版 HTTP + Server-Sent Events 双端点模式。
- `streamable_http`：新版单一 HTTP endpoint，响应可为 JSON 或 SSE stream。

Web MCP 页和 `agent api mcp list|validate|tools` 会隐藏 Authorization、token、secret、password、api_key 等敏感字段。MCP tool 调用默认标记为需要人工审批，不随配置中心的自动审批开关静默执行。

### 核心调用关系

1. `bin/agent` 加载 `lib/*.sh`，初始化根目录、配置、日志目录、临时目录和全局状态。
2. 除 `agent audit` 和部分无需会话的 `api` 入口外，运行开始会创建 JSONL 审计 session。
3. `lib/sense.sh` 按请求主题采集最小必要环境信息。
4. `lib/context.sh` 构造模型请求上下文，并按 `context_turns` 带入会话历史窗口。
5. `lib/ai.sh` 拼接 `prompts/system.txt`、`skills/INDEX.md`、动态上下文并调用 OpenAI-compatible Chat Completions 接口。
6. `lib/orchestrator.sh` 根据模式调度 work、edit、script、terminal。
7. `lib/policy.sh` 用 `policies/risk-rules.json` 做阻断、警告、保护路径和保护服务审查。
8. `lib/executor.sh` 执行计划步骤，处理自动批准、人工审批、跳过、修改、终止、远程脚本下载审查和失败修复建议。
9. `lib/observer.sh` 在可用时安装 auditd syscall 观察规则，执行结束后汇总 `ausearch` 事件；`observer.require=true` 时每次真实执行前复核规则并 fail closed。
10. `lib/audit.sh` 与 `lib/audit_chain.py` 负责审计脱敏、0600 写入、hash chain、fsync、轮转、磁盘策略、session 收尾和校验/报告。

CLI 会话历史只在当前 `agent` 进程内有效，存放于该 session 的私有临时目录，并随进程退出清理；重新启动 CLI 不会自动继承上一轮会话。

### Web 调用关系

1. `bin/agent-web` 读取 `config/config.json` 的 `web` 段，导出环境变量并启动 `web/server.py`。
2. `web/server.py` 提供静态文件、token 校验、策略/配置/skill 文件 API、异步 Job API，并把状态服务委托给平级模块。
3. 对 CLI 核心能力，Web 后端调用 `bash bin/agent api ...`，不复制业务逻辑。
4. 长任务通过 `/api/jobs` 启动，状态事务化写入 `tmp/web/jobs.db`；每个 Job 使用独立 session、history、audit 和临时目录，完成后串行合并工作台历史/turn。`approval_required` turn 会持久化供界面和审计展示，但只有审批续跑得到最终 `answered` 或 `executed` 结果后才进入模型上下文。
5. 前端轮询 `/api/jobs/<job-id>`，终态后重新读取服务端持久化 turns；审计证据不参与业务状态重建。

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
   - 低风险且策略干净的步骤按 `approvals.auto.*` 能力开关决定是否自动执行。
   - 自由 shell 文件写入、重定向写入、`sed -i`、`cp`、`mv`、`rm`、`curl -o` 和 `wget -O` 会被阻断，应改用 `controlled-tools`。
   - 命中文件保险箱（`policies/file-vault.json`）中的路径时：工作模式修改一律阻断（critical），读取或调用一律需要人工审批（high）；保险箱为空则完全不生效。
   - 默认 shell、remote script、文件补丁、文件下载、medium/high/critical 或命中策略告警的步骤需要人工确认。
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
5. 返回 `timeline`、`approval_card`、`output_blocks`，其中脚本 JSON 输出、observer 摘要和执行元数据都放在分块结果中。

### Terminal 模式

1. 用户输入交给 `bash -lc`。
2. 执行前调用 `linux_agent_terminal_review`。
3. 阻断命令不会执行。
4. 需要审批的命令在 CLI 中请求确认，在 API/Web 中返回 `approval_required`。
5. 执行结果通过 `output_blocks` 展示 stdout/stderr，并写入脱敏后的审计摘要。

### Remote Script

`remote_script` 不允许 `curl | sh`。它只支持 HTTPS 下载后审查：

1. 校验 URL 必须是 `https://`。
2. 下载到当前 session 的 `tmp/<session-id>/`。
3. 校验非空、大小不超过 256KB、文本类型、SHA256、行数和预览。
4. 风险等级提升为 high 或 critical。
5. 用户审批后才执行下载后的脚本。

### 官方 Remote Bootstrap

官方 `curl | bash` 是独立入口适配器，不会放宽 Agent 对第三方远程管道的阻断。Release manifest 固定声明 core、Web 和每个一级 skill 的文件名、大小与 SHA256；下载地址只能从当前 `libeal/ASSIstant` Release 派生。

发布 Remote 版本时，先把包含发布 workflow 的提交推送到 GitHub，再创建并推送新的 `v*` tag：

    git push ASSIstant main
    git tag -a vX.Y.Z -m "Release vX.Y.Z"
    git push ASSIstant vX.Y.Z

GitHub Actions 会构建确定性资产与 SPDX 2.3 SBOM，使用 GitHub OIDC 对 manifest 做 cosign keyless 签名，为资产生成 build provenance，发布后再执行签名、provenance 和 CLI/Web bootstrap smoke test。若某次发布已经创建了同名 Release 但运行中断，可以在 Actions 的 `Remote Release` workflow 中手动输入该 tag 重跑；流程会复用并校验已有资产，只补齐缺失文件，不覆盖内容不一致的资产。

启动时只获取 core、策略、prompt 和 skill 索引。首次执行或在 Web 中点击加载某个 skill 时，resolver 才下载该 skill 的完整归档，拒绝路径穿越、链接、设备文件、摘要错误和登记不一致，再原子加入运行时 registry。`skills validate` 只校验目录和已经物化的包，不会偷偷下载全部 skill。

## 配置

`config/config.example.json` 是模板，`config/config.json` 是本地配置文件并被 `.gitignore` 忽略。

关键字段：

| 字段 | 作用 |
| --- | --- |
| `provider` | AI 厂商 ID；内置值来自 `config/ai-providers.json`，未知值按 OpenAI-compatible/custom 处理。 |
| `api_url` | 模型接口地址；内置 provider 会自动填充，其他服务商可使用 OpenAI-compatible/custom 地址。 |
| `api_key` | 可选的模型 API key；优先级低于 `LINUX_AGENT_API_KEY`，不会在 Web 响应中回显。 |
| `model` | 模型名称。 |
| `request_timeout_sec` | AI 请求超时时间。 |
| `provider_resilience.enabled` | 是否启用可重试故障的有界重试、共享熔断和显式 Provider 故障转移；关闭后主 Provider 仅调用一次。 |
| `provider_resilience.max_attempts` | 单个 Provider 的总尝试次数，范围 1–5。 |
| `provider_resilience.backoff_initial_ms` / `backoff_max_ms` | 指数退避初始值和上限，范围 0–60000 毫秒，且上限不得小于初始值。 |
| `provider_resilience.circuit_failure_threshold` / `circuit_open_sec` | 开启熔断前的连续故障阈值，以及进入半开探测前的秒数。 |
| `provider_resilience.failover` | 有序备用 Provider 数组；每项使用 `api_key_env` 或显式 `reuse_primary_api_key:true`，禁止内联密钥。仅在可重试故障或熔断时切换。 |
| `context_turns` | 会话历史窗口大小。 |
| `command_guard.enabled` | 是否启用 Python AST/Token 命令守卫；默认开启，关闭或重新开启需通过 Web Policy 页面完成 sudo 核对。 |
| `agent_loop.enabled_for_work` | 是否启用 work 反思续写循环。 |
| `agent_loop.observation_text_limit` | observation 文本摘要上限。 |
| `agent_loop.thinking_trace_enabled` | 是否保存并展示简短 `thinking_summary`。 |
| `agent_loop.max_iterations` | Work 反思续写的硬上限，默认 12，范围 1–100；达到后停止而不是继续占用资源。 |
| `agent_loop.checkpoint_turns` | 强制 checkpoint 轮次，`0` 表示使用默认窗口。 |
| `approvals.auto.skill_readonly` | 是否自动执行低风险且策略干净的普通只读 skill。 |
| `approvals.auto.shell_readonly` | 是否自动执行低风险且策略干净的 shell，默认关闭。 |
| `approvals.auto.file_match` | 是否自动执行 `controlled-tools/file-match`。 |
| `approvals.auto.file_patch` | 是否自动执行 `controlled-tools/file-patch`，默认关闭。 |
| `approvals.auto.file_download` | 是否自动执行 `controlled-tools/file-download`，默认关闭。 |
| `approvals.auto.local_analyze` | 是否自动执行 `controlled-tools/local-analyze`。 |
| `approvals.auto.remote_script` | 是否自动执行远程脚本，默认关闭。 |
| `audit_mode` | 审计写入模式。 |
| `audit_text_limit` | 审计和输出预览文本截断长度。 |
| `audit.fsync` | 是否在审计追加/轮转后执行 fsync。 |
| `audit.max_bytes` | 单个审计分段的轮转阈值；`0` 禁用轮转。 |
| `audit.min_free_bytes` | 审计目录最小可用空间阈值；`0` 禁用检查。 |
| `audit.on_full` | 空间不足时 `degrade`（写最小事件）或 `block`（拒绝操作）。 |
| `observer.enabled` | observer 开关，默认 `auto`。 |
| `observer.privilege` | auditd observer 的 sudo 策略。 |
| `observer.max_events` | observer 汇总事件上限。 |
| `observer.require` | 强合规开关；为 `true` 时 observer 未完整生效即拒绝真实执行。 |
| `execution.min_privilege_proxy` | root 运行时是否尽量降权执行普通命令。 |
| `execution.least_privilege_user` | 降权执行使用的目标用户。 |
| `execution.timeout_sec` | 单个执行步骤的硬超时，范围 1–3600 秒，默认 300 秒；超时会记录 `timed_out`。 |
| `execution.max_output_bytes` | stdout/stderr 各自的硬字节上限，范围 4096–104857600，默认 1 MiB；超限会终止进程组并返回 `output_limit_exceeded`。 |
| `skills_dir` | 自定义 skill 根目录，空值使用项目内 `skills/`。 |
| `remote_script_policy` | 远程脚本策略，支持 `download_review` 和 `disabled`。 |
| `providers_security.require_https` | 是否只允许 HTTPS Provider URL；Remote runtime 会强制为 `true`。 |
| `providers_security.block_internal_addresses` | 是否阻止 Provider 解析到本机、私网、回环、链路本地等内部地址。 |
| `providers_security.allowed_hosts` | Provider 显式可信主机列表。带凭据的模型列表请求只会发往该列表或配置/registry 已声明的 Provider 主机；请求体不能把 API key 改发到任意公网 HTTPS 地址。 |
| `remote.enabled` | 是否以 Remote runtime 语义运行。 |
| `remote.release_version` | Remote 运行时的固定 release 版本，用于 health、日志和指标元数据。 |
| `remote.storage_backend` | Remote 状态存储后端；当前支持 `local`。 |
| `remote.allow_api_key_transmission` | Remote runtime 是否允许向配置的 AI Provider 发送 API key；默认 `false`，本地模式不受影响。 |
| `web.enabled` | 是否允许启动 Web。 |
| `web.host` | Web 监听地址。 |
| `web.port` | Web 监听端口。 |
| `web.token` | Web Bearer token，空值则启动时生成临时 token。 |
| `web.job_retention_hours` | SQLite Job 历史保留小时数。 |
| `web.max_active_jobs` | 同时处于 queued/running 的 Job 上限。 |
| `web.job_timeout_sec` | 后台 Job 硬超时。 |
| `web.max_job_attempts` | Job 重试次数上限。 |
| `web.cancel_grace_sec` | 取消时从 SIGTERM 升级到 SIGKILL 的等待秒数。 |
| `web.metrics_enabled` | 是否开启带 Bearer token 保护的 `/api/metrics` Prometheus 文本端点，默认 `true`。 |

备用 Provider 只保存密钥来源，不在配置中保存备用密钥值：

```json
{
  "provider_resilience": {
    "failover": [
      {
        "provider": "openai_compatible",
        "api_url": "https://backup-provider.example/v1/chat/completions",
        "model": "backup-model",
        "api_key_env": "BACKUP_PROVIDER_API_KEY"
      }
    ]
  }
}
```

环境变量：

| 变量 | 作用 |
| --- | --- |
| `EDITOR` | Edit 模式打开脚本确认文件的编辑器，未设置时使用 `vi`。 |
| `LINUX_AGENT_API_KEY` | 推荐的模型 API 密钥来源，优先级高于 `config.api_key`。 |
| failover 条目中的 `api_key_env` | 备用 Provider 密钥的环境变量名，例如 `BACKUP_PROVIDER_API_KEY`；变量值不写入配置或审计。 |
| `LINUX_AGENT_OUTPUT_JSON=1` | 将 CLI 业务输出切换为机器可读 JSON。 |
| `LINUX_AGENT_VERSION` | Remote bootstrap 使用的固定版本；应与 release URL 中的 `vX.Y.Z` 一致。 |
| `LINUX_AGENT_REQUIRE_SIGNATURE=1` | 要求 Remote bootstrap 验证 release manifest 的 cosign/Sigstore 签名。 |
| `LINUX_AGENT_SIGNATURE_PUBKEY` | 私有部署的 cosign 公钥路径；使用离线 key 签名验证。 |
| `LINUX_AGENT_SIGNATURE_IDENTITY` / `LINUX_AGENT_SIGNATURE_ISSUER` | 收窄 keyless release 签名的证书身份和 OIDC issuer。 |
| `LINUX_AGENT_OBSERVER_HELPER_SOCKET` | 覆盖 observer helper Unix socket；默认 `/run/linux-agent/observer.sock`，主要用于受控测试或自定义打包。 |

内部变量如 `LINUX_AGENT_TMP_DIR`、`LINUX_AGENT_SESSION_ID`、`LINUX_AGENT_AUDIT_LOG`、`LINUX_AGENT_FILE_VAULT_POLICY_PATH` 由程序设置，不建议外部手工使用。

## 安全边界

- AI 只能返回结构化 JSON，不能直接执行命令。
- Skill 脚本必须同时登记在 `skills/INDEX.md` 和对应 `SKILL.md`。
- Work 和 Script 都经过 `policies/risk-rules.json`。
- Terminal 也会执行策略审查，高风险命令需要确认。
- 保护路径覆盖 `/`、`/etc`、`/boot`、`/usr`、`/var/lib`、`/root` 和用户 `.ssh`。
- 自由 shell 文件修改默认阻断；文件匹配、补丁、下载和本地文本分析应通过 `controlled-tools` 登记脚本执行。
- 文件保险箱：`policies/file-vault.json` 列出用户指定的敏感文件绝对路径（默认为空、不生效；支持末尾 `/*` 目录通配）。命中后工作模式修改被阻断（critical），读取及终端访问需要人工审批（high），命令实际运行后 auditd observer 还会记录保险箱路径的真实文件事件。
- `network-ops-tools` 中的扫描、SNMP、WOL、hosts/firewall 等工具即使由 work 模式调用，也按 `SKILL.md` 声明提升为 `medium` 或 `high` 风险，不能作为 low 风险自动执行。
- Remote script 只能 HTTPS 下载后审查，不允许流式管道执行。
- Web `/api/` 全部需要 Bearer token。
- `/api/metrics` 默认开启但同样需要 Bearer token；指标只使用低基数 route/status 标签，不记录 token、API key 或 Job ID。
- systemd Web 通过独立、socket 激活的 privileged helper 操作 auditd；helper 只允许固定操作、当前请求用户和 syscall allowlist，失败不回退 sudo。仅本地无 helper 模式会请求一次 sudo bootstrap；`observer.require=true` 时未观察到真实执行即阻断。
- Web、Terminal、Skill 与 MCP 子进程从空环境按白名单构造，不继承父进程中的云凭据、访问令牌或凭据代理；API key 只进入 AI 编排路径，执行步骤会再次清空环境。
- Bash 与 Web 执行层都在读取期间限制 stdout/stderr，达到 `execution.max_output_bytes` 时终止整个进程组，不依赖展示阶段截断；若命令退出后仍有脱离进程组的后代持有输出管道，limiter 在有界排空窗口后会以 `invalid_output` 失败关闭，不会无限等待或把不完整输出当成成功。
- Web 策略编辑只允许 `policies/` 下 JSON 文件，保存前做策略校验，写入前做 sudo 校验。
- 审计文本和上下文会脱敏并截断。
- Remote bootstrap 和 installer 先校验 release manifest、资产大小与 SHA-256；存在 cosign bundle 时验证签名，`LINUX_AGENT_REQUIRE_SIGNATURE=1` 或 `--require-signature` 时缺失签名会拒绝运行。
- systemd 生产安装使用专用非 root 用户、只读版本目录、独立持久数据目录和沙箱单元；升级健康检查失败会自动回滚，卸载默认保留 `data/`。
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
bash tests/context.sh
bash tests/security.sh
bash tests/workflow.sh
bash tests/policy.sh
bash tests/tools.sh
bash tests/observer.sh
bash tests/mcp.sh
bash tests/interactive.sh
bash tests/web_api.sh
bash tests/web_server.sh
bash tests/remote_release.sh
bash tests/remote_runtime.sh
bash tests/remote_web_security.sh
bash tests/backup.sh
bash tests/install.sh
bash tests/web_frontend.sh
```

完整回归：

```bash
for test in policy tools context security workflow workflow_unit observer audit_integrity \
            smoke mcp contract web_api web_server interactive remote_release remote_runtime \
            remote_web_security backup install; do
  bash "tests/$test.sh"
done
python3 -m unittest discover -s tests -p 'test_web_*.py' -v
bash tests/web_frontend.sh
bash scripts/lint.sh
```

`tests/web_api.sh`、`tests/web_server.sh` 和 `tests/install.sh` 的健康检查需要绑定 `127.0.0.1` 本地端口。如果沙箱或 CI 禁止监听本地端口，这些检查会因环境权限失败。`tests/web_frontend.sh` 只需要 Node.js，不需要 npm 或浏览器。

前端测试保持零 npm 依赖：纯函数和协议行为由 `tests/web_frontend.sh` 下的 Node 标准库单测覆盖，HTTP 端到端由 `tests/web_server.sh` 覆盖。本项目计划性不引入 Playwright、Puppeteer 等浏览器自动化框架。

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
| `config/ai-providers.json` | Web 配置中心的内置 AI 厂商预设，包含接口地址、默认模型、鉴权方式和模型列表解析规则。 |
| `config/config.json` | 本地实际配置，由用户创建或首次运行复制模板生成，被 `.gitignore` 忽略。 |

### `lib/`

| 文件 | 功能 |
| --- | --- |
| `lib/common.sh` | 根目录、日志目录、临时目录初始化，通用输出函数，临时目录清理，文本和 JSON 脱敏，JSON 参数规范化。 |
| `lib/config.sh` | 加载 `config/config.json`，提供配置读取、默认值读取、布尔和正整数读取。 |
| `lib/audit.sh` | 审计边界读取、payload 脱敏摘要、JSONL session、命令/turn/步骤事件和报告渲染。 |
| `lib/audit_chain.py` | 审计文件 0600、跨进程锁、SHA-256 链、fsync、轮转、磁盘策略和完整性校验。 |
| `lib/context.sh` | 维护会话历史窗口，构造动态请求上下文，合并最终 AI payload 上下文。 |
| `lib/sense.sh` | 采集磁盘、资源、进程、网络、日志、服务、权限等环境信息。 |
| `lib/skills.sh` | 解析 skill 引用、定位脚本、读取索引、校验登记状态、执行 skill 脚本、校验 skill 目录。 |
| `lib/doctor.sh` | 检查必需命令、可选命令、配置和 skill 目录。 |
| `lib/ai.sh` | 构造系统提示，记录 AI 输入文件清单，按 provider 适配鉴权和请求格式，执行有界重试/故障转移并校验模型响应。 |
| `lib/provider_resilience.sh` / `lib/provider_resilience.py` | Provider 退避策略、可重试错误分类和跨进程持久熔断状态。 |
| `lib/command_guard.py` | 标准库命令守卫，识别 pipeline、redirect、wrapper、substitution、remote pipe、保护路径写入和交互命令等风险形态。 |
| `lib/policy.sh` | 聚合 AST 守卫和项目风险规则，对命令、脚本、参数、远程脚本、保护路径和保护服务做审查。 |
| `lib/file_vault.py` | 文件保险箱静态访问分类器，把命令文本按保险箱路径判定为读取、修改或未知（保险箱为空时保持惰性），供 `policy.sh` 决定阻断或审批。 |
| `lib/protocol.sh` | 为 API/CLI 构造 `timeline`、`approval_card`、`output_blocks` 工作台协议。 |
| `lib/observer.sh` | auditd observer 预检、规则安装和清理、`ausearch` 解析、执行过程 marker 和降级记录。 |
| `lib/observer_helper.py` | systemd socket 激活的最小 auditd privileged helper，执行固定协议、peer uid 校验、输出/超时限制和工具所有权校验。 |
| `lib/output_limiter.py` / `lib/subprocess_env.py` | Bash 流式输出硬上限，以及 Web/MCP 不可信子进程的显式环境白名单。 |
| `lib/executor.sh` | Work 计划执行状态机，包含 API 审批输入队列、自动审批、人工审批、跳过/修改/终止、远程脚本下载审查、步骤执行、失败修复建议和输出渲染。 |
| `lib/editor.sh` | Edit 模式实现，生成 `SKILL.md`，打开编辑器，记录人工修改 diff，staging 校验并提交 skill。 |
| `lib/api.sh` | 机器可读 JSON API，给 Web 提供 health、config、doctor、sense、tools、skills、audit、work、script、terminal、edit 等入口。 |
| `lib/workflow.sh` | Work 请求准备和执行引擎选择的 CLI/API 共享边界。 |
| `lib/interactive.sh` | REPL 输入、斜杠菜单、命令补全菜单和模式选择菜单。 |
| `lib/orchestrator.sh` | 高层业务编排，负责 work/edit/script/terminal 分发、work 反思循环、checkpoint 和 thinking summary。 |

### `web/`

| 文件 | 功能 |
| --- | --- |
| `web/server.py` | Python 标准库 Web 路由、认证、错误映射和服务编排，并转发 CLI API。 |
| `web/configuration.py` | 配置字段校验、线程/进程锁和 fsync 原子读改写事务。 |
| `web/jobs.py` | SQLite WAL JobStore，负责幂等 admission、版本、查询、清理和重启恢复。 |
| `web/sessions.py` | 工作台 session、Job 快照/串行合并事务和不可变 protocol turns。 |
| `web/execution.py` | Agent 子进程环境隔离、并发管道读取、超时、取消和进程组回收。 |
| `web/audit.py` / `web/domain.py` / `web/timeline.py` | Web 审计适配、领域契约校验和持久化时间线读取。 |
| `web/metrics.py` | 仅使用 Python 标准库的线程安全 Prometheus counter/gauge 注册和文本渲染。 |
| `web/observer.py` | observer helper/sudo 预检和 Web bootstrap 状态机；helper 失败时 fail closed。 |
| `web/provider.py` / `web/policy.py` / `web/skills.py` | Provider、Policy 和 Skill 文件服务。 |
| `web/static/index.html` | Web 控制台 HTML 页面，包含 Workbench、Skill、MCP、Policy、Audit、Config 六个主视图。 |
| `web/static/app.js` | Web 前端入口，组合无构建 ES modules 并驱动工作台交互。 |
| `web/static/modules/` | 前端 API、状态、布局、Job 客户端、输出渲染、turn 处理及 Workbench/Skill/Policy/Audit/Config 视图模块；模块由 `tests/web_frontend.sh` 直接用 Node 检查。 |
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
| `policies/redaction-rules.json` | 脱敏规则文件，集中覆盖 Bearer、sk、AKIA、JWT、长 hex、私钥、敏感 key/value 和内网 IP。 |
| `policies/audit-boundaries.json` | audit 和 observer 边界文件，定义审计事件范围、payload 模式、文本限制、observer syscall、observer 字段和事件上限。 |
| `policies/file-vault.json` | 文件保险箱策略，列出用户自定义的敏感文件绝对路径（支持末尾 `/*` 目录通配），默认路径列表为空表示不启用。 |

### `mcp/` 与 `schema/`

| 文件 | 功能 |
| --- | --- |
| `mcp/README.md` | MCP manifest registry 的格式、传输方式和安全边界说明。 |
| `mcp/<server-id>/mcp.json` | 外部 MCP server 的 manifest；支持 stdio、legacy SSE 和 Streamable HTTP。 |
| `schema/domain.json` | CLI、Web/API 和前端共享的领域契约、状态展示、错误码及可编辑配置 schema。 |

### `packaging/`、`remote/` 与 `scripts/`

| 文件 | 功能 |
| --- | --- |
| `packaging/linux-agent-web.service` | 生产 Web systemd 单元，包含非 root 身份、只读代码、可写数据目录和资源沙箱。 |
| `packaging/linux-agent-observer-helper.service` / `.socket` | 仅持有 audit capability 的 root helper 与 `0660` Unix socket。 |
| `packaging/dropins/10-provider-egress.conf.example` | 默认拒绝网络出口、按 Provider CIDR 显式放行的 systemd drop-in 模板。 |
| `packaging/install-package.sh` / `INSTALL_PACKAGE.md` | Debian/Fedora 归档内的依赖安装入口与使用说明。 |
| `packaging/权限边界.md` | Terminal、Skill、MCP、远程脚本、文件编辑和 AI 调用的权限与密钥边界。 |
| `remote/bootstrap.sh` | CLI/Web Remote runtime 的自包含 bootstrap；固定版本下载 manifest 和资产并在本机临时运行。 |
| `scripts/build-install-packages.sh` | 构建精简、可复现的 Debian/Ubuntu 与 Fedora/RHEL 本地安装归档。 |
| `scripts/build-remote-release.sh` | 构建确定性 core/Web/skill/installer 资产、SPDX 2.3 SBOM、`SHA256SUMS` 和 release manifest。 |
| `scripts/install.sh` | systemd 安装、升级、自动回滚、健康检查、状态查询和卸载；支持本地 `--from-dist` 演练。 |
| `scripts/prepare-release-signature.sh` | 为 release manifest 准备 Sigstore/cosign bundle。 |
| `scripts/publish-remote-release.sh` | 发布并校验 Remote release 资产。 |
| `scripts/lint.sh` | 运行 Bash、Python、JavaScript、JSON、ShellCheck、格式和可选 JSDoc/TypeScript 检查。 |

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
| `skills/controlled-tools/SKILL.md` | `controlled-tools` skill 说明和受控工具工作流。 |
| `skills/controlled-tools/scripts/file-match.sh` | 只读字面量匹配目标文件，返回出现次数和上下文。 |
| `skills/controlled-tools/scripts/file-patch.sh` | 在匹配次数符合预期时生成 diff、可备份并原子替换文件。 |
| `skills/controlled-tools/scripts/file-download.sh` | 仅允许 HTTPS 公网下载到本机路径，限制大小并可校验 sha256。 |
| `skills/controlled-tools/scripts/local-analyze.sh` | 对文本或本地文件做只读关键词和错误样本分析。 |
| `skills/session-history/SKILL.md` | `session-history` skill 说明，用于只读回看审计 session 中上一轮或指定轮次的执行上下文。 |
| `skills/session-history/scripts/last-command-output.sh` | 从 JSONL 审计 session 读取命令、计划步骤和 stdout/stderr 输出预览。 |
| `skills/network-ops-tools/SKILL.md` | `network-ops-tools` skill 说明和安全边界，所有脚本声明为 `medium` 或 `high` 风险。 |
| `skills/network-ops-tools/scripts/_network_tool.py` | 网络工具集共享实现，负责参数校验、范围限制、dry-run、扫描、查询和计算逻辑。 |
| `skills/network-ops-tools/scripts/_snmp.py` | SNMP v1/v2c/v3 编解码与 get/getnext/walk/bulk 实现（标准库，不支持 authPriv）。 |
| `skills/network-ops-tools/scripts/_dns.py` | 纯 Python DNS 解析器（UDP + TCP 回退），供 dns-lookup 在无 `dig` 时使用。 |
| `skills/network-ops-tools/scripts/ip-scanner.sh` | 有界扫描授权范围内的 IP/CIDR，支持 ping 和可选 TCP 探测。 |
| `skills/network-ops-tools/scripts/port-scanner.sh` | 有界扫描单个目标主机的 TCP 端口。 |
| `skills/network-ops-tools/scripts/discovery-protocol.sh` | 读取本机 LLDP/CDP 风格邻居发现信息。 |
| `skills/network-ops-tools/scripts/wake-on-lan.sh` | 预览或发送 Wake-on-LAN magic packet。 |
| `skills/network-ops-tools/scripts/network-interface.sh` | 查看网络接口、地址、路由、MTU、MAC 和 operstate。 |
| `skills/network-ops-tools/scripts/wifi.sh` | 查看无线接口和 Wi-Fi 网络信息。 |
| `skills/network-ops-tools/scripts/connections.sh` | 查看活动 TCP/UDP 连接。 |
| `skills/network-ops-tools/scripts/listeners.sh` | 查看监听中的 TCP/UDP socket。 |
| `skills/network-ops-tools/scripts/neighbor-table.sh` | 查看本机 ARP/NDP neighbor table。 |
| `skills/network-ops-tools/scripts/ping-monitor.sh` | 执行有界 ping 监控并汇总丢包和延迟。 |
| `skills/network-ops-tools/scripts/traceroute.sh` | 执行 traceroute/tracepath 或 loopback 安全回退。 |
| `skills/network-ops-tools/scripts/dns-lookup.sh` | 执行 DNS 查询。 |
| `skills/network-ops-tools/scripts/sntp-lookup.sh` | 执行或 dry-run SNTP 时间查询。 |
| `skills/network-ops-tools/scripts/whois.sh` | 执行或 dry-run WHOIS 查询。 |
| `skills/network-ops-tools/scripts/ip-geolocation.sh` | 查询或 dry-run 公网 IP 地理位置。 |
| `skills/network-ops-tools/scripts/hosts-file-editor.sh` | 读取、搜索、规划或确认修改 hosts 文件。 |
| `skills/network-ops-tools/scripts/lookup.sh` | 查询端口/服务名和 MAC OUI 厂商。 |
| `skills/network-ops-tools/scripts/snmp.sh` | dry-run 或执行有界 SNMP v2c GET，输出不回显 community。 |
| `skills/network-ops-tools/scripts/firewall.sh` | 查看 firewall 状态、生成规则计划或确认应用 UFW 规则。 |
| `skills/network-ops-tools/scripts/subnet-calculator.sh` | 计算 IPv4/IPv6 子网、拆分、supernet、聚合、通配符掩码和反向 DNS 区域。 |
| `skills/network-ops-tools/scripts/bit-calculator.sh` | 转换二进制/十六进制/十进制并执行位运算、移位、循环移位、置/清/翻位和字节序转换。 |
| `skills/network-ops-tools/scripts/tls-inspect.sh` | 检查目标 TLS 端点的协议、加密套件与证书有效期、SAN 和颁发者。 |
| `skills/network-ops-tools/scripts/http-check.sh` | 检查 HTTP(S) 端点的状态码、跳转链、响应头与耗时。 |
| `skills/network-ops-tools/scripts/public-ip.sh` | 通过 STUN 或 HTTPS echo 查询本机公网/反射地址。 |
| `skills/network-ops-tools/scripts/service-discovery.sh` | 通过 mDNS/SSDP 组播发现局域网服务。 |
  
### `tests/`

| 文件 | 功能 |
| --- | --- |
| `tests/helpers.sh` | 测试辅助函数，启动/停止 fake AI server，写入测试配置。 |
| `tests/fake_ai_server.py` | 测试专用 Chat Completions 兼容服务，用于复刻 answer、work_plan、edit、repair 等响应。 |
| `tests/smoke.sh` | 覆盖主要 CLI 入口、fake AI 工作流、JSON 输出、AI 文件清单、checkpoint 和 thinking trace。 |
| `tests/security.sh` | 覆盖脱敏、审计摘要、上下文边界、远程脚本审查和临时目录清理。 |
| `tests/workflow.sh` | 覆盖失败中断、自动低风险执行、反思续写、拒绝、跳过、修改需求、终止和输出渲染。 |
| `tests/policy.sh` | 覆盖风险规则、保护路径、远程脚本阻断、文件保险箱访问判定和风险合并。 |
| `tests/tools.sh` | 覆盖本地工具、skill 登记、日志清理边界和 doctor。 |
| `tests/observer.sh` | 覆盖 observer 禁用、mock auditd、事件汇总和失败降级。 |
| `tests/audit_integrity.sh` | 覆盖审计链、篡改、权限、轮转、磁盘策略、并发写入和离线证据导出。 |
| `tests/install_packages.sh` | 覆盖 Debian/Fedora 包的确定性、内容隔离、校验和及无 systemd 安装。 |
| `tests/install.sh` | 无 root 覆盖发布物校验、安装、升级、回滚、持久数据、版本保留和健康检查。 |
| `tests/workflow_unit.sh` | 覆盖 CLI/API 共享 Work 工作流边界。 |
| `tests/contract.sh` | 覆盖 API/domain schema、状态和错误码契约。 |
| `tests/test_web_*.py` | 覆盖 JobStore、Session 事务、Execution、Domain 与拆分后的 Web 服务。 |
| `tests/interactive.sh` | 覆盖 REPL 菜单、模式切换、terminal 模式和 edit 模式。 |
| `tests/web_api.sh` | 覆盖机器可读 API 的 work、script、terminal、edit、audit 等路径。 |
| `tests/web_server.sh` | 覆盖 Web token 拦截、health、静态页面、config、skill、policy、job、shutdown、metrics 和新增 Web 入口。 |
| `tests/web_frontend.sh` | 按固定顺序执行全部 `tests/web_*.mjs` 前端模块、协议、XSS、Job、turn、配置和 JSDoc 测试。 |
| `tests/web_*.mjs` | 使用 Node 标准库覆盖前端纯函数和协议行为，不引入 Playwright/Puppeteer。 |

### 运行时目录和生成文件

| 路径 | 功能 |
| --- | --- |
| `logs/` | JSONL 审计日志目录，被 `.gitignore` 忽略。 |
| `tmp/` | 项目内临时目录，被 `.gitignore` 忽略；Job 数据库为 `tmp/web/jobs.db`，私有 history/completion 位于 `tmp/web/jobs/`。 |
| `sessions/` | 预留的本地 session 产物目录，被 `.gitignore` 忽略。 |
| `/tmp/<session-id>/thinking/` | 开启 thinking trace 后保存简短思考摘要，不进入审计或上下文。 |
| `__pycache__/`、`*.pyc` | Python 运行生成的字节码缓存，被 `.gitignore` 忽略。 |

## 故障排查

- `config/config.json` 缺失：运行 `cp config/config.example.json config/config.json`。
- API key 未配置：设置 `LINUX_AGENT_API_KEY`，或配置 `config.api_key`。
- Web 端口被占用：停止旧进程或修改 `web.port`。
- Web 认证失败：确认页面右上角 token 与 `agent-web` 启动日志一致。
- `skills validate` 失败：检查 `skills/INDEX.md`、对应 `SKILL.md` 和 `scripts/*.sh` 是否一致。
- observer 不可用：生产部署先检查 `linux-agent-observer-helper.socket/service`、socket 组权限和 journal；本地模式再检查 auditd/sudo。helper socket 存在但调用失败时不会回退 sudo。`observer.require=false` 时记录降级事件并继续，`true` 时修复 observer 后才能执行。
