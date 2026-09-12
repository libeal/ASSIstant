# Linux 运维 Agent

**Linux 运维 Agent** 是一个保守、可审计的本地Linux运维AI助手。它将自然语言请求转换为结构化执行计划，通过策略审查、人工审批、最小权限执行和完整审计日志，实现安全可控的运维自动化。

核心设计理念：**AI 提议，策略审查，人工批准，系统执行。**

## 特性

-  **安全优先**：所有高风险操作都需经过策略检查和人工确认
-  **完整审计**：JSONL审计链，SHA-256哈希验证，支持离线证据导出
-  **权限隔离**：systemd模式下Web用户、Runner、root helper三层隔离
-  **可扩展**：Skill系统 + MCP 2.0协议集成外部工具
-  **多入口**：CLI交互式/单命令、Web控制台、Remote临时运行
-  **零依赖前端**：纯ES模块，无npm、webpack，无外部CDN

## 快速开始

### 前置要求

- **必需**：`bash` (≥4.0)、`jq`、`python3` (≥3.8)、`curl`
- **可选**：`auditd`（系统调用观察）、`flock`（并发锁，`util-linux`包）

### 本地运行（源码方式）

```bash
# 1. 克隆项目
git clone https://github.com/libeal/ASSIstant.git
cd ASSIstant

# 2. 配置
cp config/config.example.json config/config.json
# 编辑 config.json，至少配置 api_provider 和 api_key

# 3. 验证配置
bash test_config.sh          # 离线校验
bash test_config.sh --live   # 在线测试API连接

# 4. 运行
bash bin/agent               # 交互式REPL
bash bin/agent-web           # Web控制台（http://127.0.0.1:8765）
```

**环境变量优先级高于配置文件**：
```bash
export LINUX_AGENT_API_KEY="sk-..."  # 推荐用环境变量保护密钥
```

### 远程临时运行（推荐用于诊断）

**CLI模式**：
```bash
curl -fsSL https://github.com/libeal/ASSIstant/releases/download/v1.0.0/linux-agent-cli.sh \
  | LINUX_AGENT_VERSION=v1.0.0 bash
```

**Web模式**（强制绑定127.0.0.1，通过SSH端口转发访问）：
```bash
# 目标机上执行
curl -fsSL https://github.com/libeal/ASSIstant/releases/download/v1.0.0/linux-agent-web.sh \
  | LINUX_AGENT_VERSION=v1.0.0 bash

# 运维机上建立SSH隧道
ssh -L 8765:127.0.0.1:8765 user@target-host
# 浏览器访问 http://localhost:8765
```

**安全说明**：
-  Runtime物化到`/dev/shm`或`$XDG_RUNTIME_DIR`（内存文件系统）
-  退出时自动清理，不留痕迹
-  `curl | bash`方式仅适合临时诊断，生产环境请使用systemd安装

### 生产部署（systemd）

```bash
sudo bash linux-agent-install.sh install \
  --version v1.0.0 \
  --require-signature \
  --provider-cidr 203.0.113.0/24  # 替换为实际的Provider CIDR

# 查看服务状态
sudo systemctl status linux-agent-web.service

# 访问 http://127.0.0.1:8765
```

**systemd安装特性**：
- 三层权限隔离（Web进程、Runner UID、root helper）
- Unix socket通信（`SO_PEERCRED`身份验证）
- systemd socket激活
- Prometheus指标（`/metrics`）

详细安装文档见 [`packaging/权限边界.md`](packaging/权限边界.md)

## 主要功能

### CLI模式

| 模式 | 命令 | 说明 |
|------|------|------|
| **Work** | `bash bin/agent work "任务描述"` | 自然语言运维任务，AI返回执行计划 |
| **Terminal** | `bash bin/agent terminal "命令"` | 执行shell命令，策略审查 |
| **Edit** | `bash bin/agent edit "需求"` | AI生成Skill脚本 |
| **Script** | `bash bin/agent script skill/script [json]` | 执行已注册Skill |
| **Doctor** | `bash bin/agent doctor` | 环境健康检查 |
| **Audit** | `bash bin/agent audit verify <session-id>` | 审计链完整性验证 |

**交互式REPL**：
```bash
bash bin/agent
> /work 检查CPU使用率最高的10个进程
> /terminal df -h
> /mode terminal
> /exit
```

### Web控制台

启动：`bash bin/agent-web`（默认端口8765）

**功能视图**：
- **Work工作台**：自然语言任务、执行时间线、实时审批
- **Skill库**：浏览/运行/编辑内置和用户Skill
- **MCP**：管理外部工具（MCP 2.0协议）
- **Policy**：策略规则管理（风险规则、文件保险箱）
- **Audit**：审计日志查询、完整性验证、证据导出
- **Config**：配置管理、运行时快照

### 内置Skill

| Skill | 说明 |
|-------|------|
| `ops-basic` | 常规巡检、日志搜索、清理任务 |
| `os-deep-inspect` | 深度系统快照、网络诊断 |
| `controlled-tools` | 受控文件修改、安全下载 |
| `network-ops-tools` | IP/端口扫描、DNS、防火墙、SNMP |
| `container-inspect` | 容器运行时、镜像检查 |
| `ops-change` | 账户、软件包、服务变更 |
| `database-inspect` | 数据库健康检查、只读查询 |

完整能力矩阵见 [`docs/SKILL_CAPABILITY_MATRIX.md`](docs/SKILL_CAPABILITY_MATRIX.md)

## 核心架构

### 设计原则

1. **分离关注点**：`bin/`（入口）→ `lib/`（核心）→ `skills/`（能力扩展）
2. **CLI-as-Library**：Web后端通过`bash bin/agent api`调用CLI核心，避免逻辑重复
3. **渐进披露**：AI初始只看到Skill索引，按需加载详细文档
4. **故障安全**：Helper缺失时fail-closed（managed模式），降级时记录标记

### 执行流程

```
用户请求 → AI生成计划 → 策略审查 → 风险评估 → 人工审批（高风险）→ 执行 → 审计记录
```

**策略层**：
- `lib/command_guard.py`：AST分析（管道、重定向、命令替换）
- `policies/risk-rules.json`：正则匹配（高危命令、保护路径）
- `policies/file-vault.json`：文件保险箱（禁止修改的路径）

**审计层**：
- JSONL格式，逐行追加
- SHA-256链式哈希（跨日志轮转验证）
- `fsync`持久化（防止掉电丢失）
- 支持离线证据导出（`agent audit export --all`）

### 模块职责

| 模块 | 职责 |
|------|------|
| `lib/ai.sh` | OpenAI兼容API调用，响应校验 |
| `lib/executor.sh` | 执行计划状态机，步骤编排 |
| `lib/policy.sh` | 策略合并（command_guard + risk-rules） |
| `lib/skills.sh` | Skill注册表、白名单校验 |
| `lib/mcp.sh` | MCP工具发现、调用 |
| `lib/audit_chain.py` | 审计链管理、完整性验证 |
| `lib/observer.sh` | auditd系统调用观察 |
| `web/server.py` | Web后端（Python stdlib only） |

加载顺序即依赖顺序：
```
common → config → audit → backup → context → sense → skills → mcp → 
doctor → provider_resilience → ai → policy → protocol → observer → 
executor → editor → workflow → api → interactive → orchestrator
```

## 安全模型

### 权限隔离（systemd模式）

| 组件 | 用户 | 职责 | 通信方式 |
|------|------|------|----------|
| `linux-agent-web.service` | `linux-agent` | Web服务、Job管理 | HTTP |
| `linux-agent-runner.socket` | `linux-agent-runner` | 执行Terminal/Skill/MCP | Unix socket |
| `observer_helper.py` | `root` | auditd观察 | Unix socket |
| `host_ops_helper.py` | `root` | 防火墙/hosts变更 | Unix socket |
| `policy_helper.py` | `root` | 策略文件写入 | Unix socket |

**Helper协议**：
- 版本化帧协议（`lib/helper_protocol.py`）
- `SO_PEERCRED`身份验证
- 白名单环境变量（API key/token不传递）

### 凭据隔离

- **API key**：环境变量 > 配置文件（0600权限）
- **MCP凭据**：sealed memfd传递，只读一次
- **sudo密码**：stdin输入，不保存

### 策略边界

**保护路径**（默认拒绝写入）：
```
/ /etc /boot /usr /var/lib /root ~/.ssh
```

**禁止命令**（risk-rules.json）：
```json
{
  "block": [
    {"pattern": "rm -rf /", "reason": "破坏性命令"},
    {"pattern": "curl.*\\|.*sh", "reason": "远程代码执行"}
  ]
}
```

**自由shell文件修改被拒绝**，必须使用`controlled-tools` Skill：
- `controlled-tools/literal-patch`：精确行替换
- `controlled-tools/safe-download`：HTTPS下载并校验
- `controlled-tools/text-analysis`：只读分析

## 配置

配置文件：`config/config.json`（优先使用环境变量 `LINUX_AGENT_*`）

### 最小配置

```json
{
  "api_provider": "openai",
  "api_endpoint": "https://api.openai.com/v1",
  "api_key": "sk-...",
  "api_model": "gpt-4o"
}
```

### 关键配置项

```json
{
  "agent_loop": {
    "enabled_for_work": true,
    "max_iterations": 12
  },
  "approvals": {
    "auto": {
      "low_risk_skills": true,
      "shell_readonly": false,
      "mcp_tools": false
    }
  },
  "observer": {
    "require": false,
    "auditd_timeout_ms": 5000
  },
  "web": {
    "host": "127.0.0.1",
    "port": 8765,
    "auth_token": "your-secret-token"
  }
}
```

详细配置说明见原README第592-688行。

## 开发与测试

### 测试套件

```bash
# 单个测试
bash tests/smoke.sh

# 完整回归测试（按CI顺序）
for t in policy tools context security workflow workflow_unit observer \
         audit_integrity smoke contract web_api web_server interactive \
         remote_release remote_runtime remote_web_security backup \
         install install_packages; do 
    bash "tests/$t.sh"
done

# Python单元测试
python3 -m unittest discover -s tests -p 'test_*.py' -v

# 前端测试
bash tests/web_frontend.sh

# 语法检查
bash scripts/lint.sh
```

### 添加Skill

1. 在`skills/<skill-name>/`创建目录
2. 编写`SKILL.md`（能力说明）
3. 编写`linux-agent.json`（manifest）
4. 编写脚本（接受单个JSON参数，输出JSON）
5. 在`skills/INDEX.md`中注册
6. 运行`bash bin/agent skills validate`

示例Skill结构：
```
skills/my-skill/
├── SKILL.md
├── linux-agent.json
├── check.sh
└── references/
    └── examples.md
```

### 添加MCP工具

1. 在`mcp/<server-id>/`创建目录
2. 编写`mcp.json`（transport配置）
3. 放置wheelhouse（如需离线安装）
4. 运行`bash bin/agent mcp validate`

## 故障排查

| 问题 | 检查 | 解决方案 |
|------|------|----------|
| API调用失败 | `bash test_config.sh --live` | 检查endpoint/key/网络 |
| 命令被拒绝 | `bash bin/agent policy validate` | 调整risk-rules.json |
| 审计链损坏 | `bash bin/agent audit verify <id>` | 查看完整性报告 |
| Helper失败 | `bash bin/agent doctor` | 检查systemd socket状态 |
| Skill未发现 | `bash bin/agent skills validate` | 检查INDEX.md注册 |

**日志位置**：
- 审计：`logs/session_*.jsonl`
- Web：`tmp/web/linux-agent-web.log`
- systemd：`journalctl -u linux-agent-web.service`

