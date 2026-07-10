# `curl | bash` Remote 运行与 Skill 懒加载

## 正式入口

CLI：

```bash
curl -fsSL https://github.com/libeal/ASSIstant/releases/latest/download/linux-agent-cli.sh | bash
```

Web：

```bash
curl -fsSL https://github.com/libeal/ASSIstant/releases/latest/download/linux-agent-web.sh | bash
```

固定版本使用 tag URL，并在管道右侧设置相同版本，例如：

```bash
curl -fsSL https://github.com/libeal/ASSIstant/releases/download/v1.2.3/linux-agent-cli.sh | LINUX_AGENT_VERSION=v1.2.3 bash
curl -fsSL https://github.com/libeal/ASSIstant/releases/download/v1.2.3/linux-agent-web.sh | LINUX_AGENT_VERSION=v1.2.3 bash
```

`latest` 面向易用性，tag URL 面向可复现运行。

## 信任与发布边界

Remote 入口只信任 `libeal/ASSIstant` 当前 GitHub Release：

- 两个 bootstrap 是独立 Release asset。
- `release-manifest.json` 只包含相对 asset 名、大小、最大允许大小和 SHA256，不提供可执行命令或任意下载 URL。CLI/Web bootstrap、core、Web 增量包和每个一级 skill 归档都必须登记；每个 skill 同时记录 description、聚合 risk 以及逐脚本 ref/description/risk。
- CLI core 与 Web 增量包独立；CLI core 包含核心代码、prompt、policy、provider/MCP 配置和 `skills/INDEX.md`，不包含一级 skill 目录。
- 每个 `skills/<name>/` 被打成独立完整归档，`SKILL.md`、scripts、agents、references 和 assets 一起发布。
- Git tag workflow 运行回归、确定性构建、发布和两个入口的发布后 smoke test。

SHA256 能发现传输损坏和 manifest/asset 不一致，但不能替代对 GitHub 仓库与 Release 发布权限的信任。高安全场景应使用固定 tag，并在仓库设置中启用 immutable releases。

## 临时运行目录

Bootstrap 本身由标准输入执行，不保存脚本文件。多文件 Bash/Python 项目仍需物化已校验字节，目录选择顺序为：

1. 当前用户 `$XDG_RUNTIME_DIR`。
2. `/dev/shm`。
3. 权限设为 `0700` 的 `/tmp/linux-agent-remote.XXXXXX`。

候选目录必须存在、可写、不是符号链接且所有者符合预期。Bootstrap 注册 EXIT、INT、TERM 和 HUP 清理；Web 入口会把终止信号转发给 server 子进程后再删除 runtime。

Remote 模式忽略并拒绝外部 `skills_dir`，所有 Skill 读取、编辑和物化都固定派生自当前临时 runtime root；本地安装模式继续支持自定义 `skills_dir`。

不建立 `~/.cache` 或安装目录。只有用户主动执行 backup 时，数据才会写到 runtime root 之外。

## Bootstrap 校验流程

1. 检查 `bash`、`curl`、`python3`、`jq`、`tar`、`sha256sum` 等现有依赖，不执行包管理器或 `sudo`。
2. 从固定 Release base 下载不超过 1MiB 的 manifest 并校验 schema/repository/version。
3. 按 manifest 下载 core，Web 入口再下载 Web 增量包。
4. 校验 asset 文件名、实际大小和 SHA256。
5. 用 Python `tarfile` 检查绝对路径、`..`、符号/硬链接、设备文件、FIFO 和成员数量。
6. 使用 `--no-same-owner --no-same-permissions` 解压到临时 root。
7. 写入不含密钥的临时配置和已验证 manifest，再启动现有 `bin/agent` 或 `bin/agent-web`。

CLI 从 `/dev/tty` 恢复 REPL/审批输入。需要 Work/Edit 时，CLI 会明确询问是否允许向 Provider 发送 API key，并使用隐藏输入把 key 放入当前进程环境。

Web 强制监听 `127.0.0.1` 并输出临时 Bearer token 与 SSH 转发提示，不允许官方 bootstrap 默认把无 TLS 的控制台暴露到公网。从本地工作站访问远端默认端口时使用：

```bash
ssh -L 8765:127.0.0.1:8765 <user>@<remote-host>
```

随后只在本地浏览器打开 `http://127.0.0.1:8765/` 并输入远端终端显示的 token。

## Skill 整包懒加载

Remote registry 初始只读取本地已验证的 `INDEX.md` 和 release manifest 元数据。`tools list`、Doctor、模型上下文和 `skills validate` 不会下载全部 skill。

执行或显式加载 `skill/script` 时：

1. resolver 从 ref 得到一级 skill 名，并确认 ref 在 manifest 中唯一登记。
2. 使用每个 skill 的锁避免并发 Web job 重复下载。
3. 从当前 Release 下载 `linux-agent-skill-<name>.tar.gz`。
4. 校验大小、SHA256、归档边界和文件类型。
5. 在 staging 要求 Release manifest refs、`INDEX.md` refs 与包内 `.sh` 集合完全一致，再运行单 skill manifest 和 policy 校验。
6. 写入 `.remote-verified.json` 台账并原子移动到 runtime `skills/<name>`。
7. 继续现有 `policy -> approval -> observer -> audit` 执行链路。

摘要错误返回 `skill_digest_mismatch`，网络错误返回 `skill_download_failed`，归档或 registry 错误返回 `skill_package_invalid`。任何失败都不会把 staging 注册为可执行能力。

## API Key 边界

`remote.allow_api_key_transmission` 默认 `false`，只在 Remote runtime 生效：

- 关闭时，AI 调用和 Web 模型列表返回 `secret_transmission_disabled`。
- Terminal、Doctor、Audit、backup 和不需要模型的能力仍可运行。
- Remote CLI key 只来自环境或隐藏 TTY 输入。
- Remote Web key 只保存在 Web 进程内存，仅向需要 AI 的 Work/Edit CLI 子进程注入环境；Terminal、Skill、Doctor 和 backup 子进程不会继承。
- API 响应、config、manifest、审计和 backup 都不包含 key 明文。

Config 页开启开关时有二次确认；前端按钮禁用只提供用户提示，后端门禁始终重复检查。

## 用户备份

CLI：

```bash
agent backup ./linux-agent-runtime-backup.tar.gz
```

Web Audit 页提供“下载运行时备份”。归档只包含：

- 已脱敏 JSONL audit 和渲染报告。
- 脱敏配置。
- 用户在当前 runtime 创建或修改的 skill。
- 已物化官方 skill 的名称、Release 版本和 SHA256 台账，不包含可重新下载的包内容。
- 不含敏感值的导出 manifest。

归档排除 API key、Web token、Web job 原始输出、官方 core 和带远程校验标记的可重新下载 skill。用户 skill 含符号链接、设备、FIFO 或 socket 时拒绝创建备份。CLI 拒绝覆盖已有路径，Web 在响应完成后删除服务器临时归档。

## 与 `remote_script` 的区别

官方 bootstrap 是仓库入口适配器，不是通用执行机制。Agent 内部遇到第三方 URL 时仍执行现有 `remote_script` 规则：只允许 HTTPS 下载、大小/文本/策略审查和人工审批，继续阻断任意 `curl | sh`、`curl | bash` 和等价包装。
