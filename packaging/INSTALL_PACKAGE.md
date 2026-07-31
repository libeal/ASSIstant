# linux-agent 发行版安装包

本归档包含运行所需的源码、配置、策略、Web 静态资源和已登记 Skill。包内不包含 Python/site-packages、npm 模块、测试、日志、临时目录或 Git 数据。

## Debian/Ubuntu

使用 `linux-agent-<version>-debian.tar.gz`。先在解压前通过可信制品渠道取得同名 `.sha256`，再校验归档；不要直接以 root 解压或执行未校验的 `install.sh`：

```bash
sha256sum -c linux-agent-<version>-debian.tar.gz.sha256
tar -xzf linux-agent-<version>-debian.tar.gz
cd linux-agent-<version>-debian
sudo bash install.sh --provider-cidr 203.0.113.0/24
```

安装入口会从 Debian 软件源安装 `requirements/debian.txt` 中的依赖，然后调用受包内 SHA256 校验保护的项目安装器。首次 systemd 安装必须提供一个或多个 `--provider-cidr`；无法固定出口时才显式使用 `--allow-unrestricted-provider-egress`。需要网络工具、auditd 等可选 Skill 时追加 `--with-optional-tools`。

## Fedora/RHEL/银河麒麟高级服务器 V11

使用 `linux-agent-<version>-fedora.tar.gz`，同样先校验外层归档：

```bash
sha256sum -c linux-agent-<version>-fedora.tar.gz.sha256
tar -xzf linux-agent-<version>-fedora.tar.gz
cd linux-agent-<version>-fedora
sudo bash install.sh --provider-cidr 203.0.113.0/24
```

该入口优先调用 `dnf install -y`，旧系统回退到 `yum install -y`，依赖来自 `requirements/fedora.txt`。麒麟 V11 按 Fedora/RPM 系识别，直接使用 `linux-agent-<version>-fedora.tar.gz`；`audit`、`policycoreutils` 和 `util-linux` 已列为必需依赖。可选网络工具使用 `--with-optional-tools`。如果系统已由其他方式准备依赖，可使用 `--skip-dependencies`。

安装器会要求 Bash 4.3+、Python 3.10+ 和 GNU coreutils/findutils/tar，并在启动前用 `systemd-analyze verify` 检查 unit。SELinux 已启用时会对安装目录、unit 和 helper runtime 执行 `restorecon`；Enforcing 模式缺少 `restorecon` 时安装失败，而不是留下只在服务启动后才暴露的 EACCES。安装包不是原生 `.rpm`，升级、回滚和卸载都使用包内 `release/linux-agent-install.sh`。

安装器默认安装到 `/opt/linux-agent` 并写入 Web、Runner、MCP stdio relay、observer、host-ops、policy-writer 全部 systemd unit。首次安装会先停止遗留实例，再临时启动新版本完成健康检查，检查结束后自动停止这些服务。升级与回滚也会临时启动新版本做认证健康检查，但检查后恢复操作前的运行状态：原本停止的 Web 保持停止，原本运行的 Web 保持运行。安装器不会修改原有开机启用状态；全新安装默认未启用。Runner socket 为 `0600`，MCP stdio relay socket 为 `0660` 且只允许 Runner 组连接，三个特权 helper socket 为 `0660` 且只允许 Web 服务组访问。需要正式运行时显式执行：

```bash
sudo systemctl enable --now linux-agent-observer-helper.socket linux-agent-runner.socket \
  linux-agent-mcp-stdio.socket \
  linux-agent-host-ops.socket linux-agent-policy-writer.socket \
  linux-agent-database-inspector.socket linux-agent-web.service
```

如果 Web 控制台报告 `observer_helper_failed` 且错误是 observer socket 权限不足，先用当前版本安装器重建 unit 和 socket：

```bash
sudo bash linux-agent-install.sh repair-observer
```

该操作会重新应用服务用户对应的 `SocketGroup`，停止并重建 `linux-agent-observer-helper.socket`，再以 Web 服务用户执行认证健康检查和真实 `auditctl -s` 预检；不会切换版本或修改持久配置。

源码 checkout 运行 Web 时，使用 `sudo bash scripts/install.sh repair-observer --prefix "$PWD" --service-user "$USER"`。源码模式还会安装 root 所有的 helper 运行副本并覆盖 helper service 的 `ExecStart`，避免 systemd 继续执行旧版 `/opt/linux-agent/current` 或被 `ProtectHome=yes` 隐藏的源码目录。

启动前应先编辑 `/opt/linux-agent/data/config/config.json` 设置 Provider 和 API key。示例 `web.token` 为空，启动时由 CSPRNG 生成临时 Bearer token；不要把真实 token 或 API key 写入发布目录。`web.sensitive_edits_enabled` 是配置中心展示的敏感只读开关，默认/缺失为 `true`，只能由本机管理员直接修改；关闭后 Web 仍可做 Skill/策略草稿、diff、review 和 validate，但最终写入返回 403。

安装边界分为四类：源码 checkout 和已验证 remote runtime 由当前 UID 持有本地 overlay；Remote 的内置 Skill 固定在 `skills/`、用户 Skill 固定在 `data/skills/`，只允许导出 backup，不允许就地 restore；`--no-systemd` 使用持久 release/data 布局，但仍是安装用户的 `degraded_same_uid`；managed systemd 则分离 Web、Runner 和 root helper。四类都把 `flock`（`util-linux`）作为硬依赖并使用 `data/.runtime.lock`：前三类当前 UID、`0600`，managed 为 Web:Runner 组、`0640`。普通业务持共享锁；source、`--no-systemd` 和 managed restore 与持久安装的升级/回滚切换持独占锁，managed restore 仅本机 root 可用，不会因此授予 Web root 写权限。

测试或无 systemd 环境可传 `--skip-dependencies --no-systemd --prefix <目录>`；该形态不要求不存在的 Runner/helper socket。loopback Web 可通过本机 sudo 标准输入密码启动一个仅服务当前 Web 进程、只接受固定 auditd 协议的临时 observer helper；非 loopback 监听不接受密码。卸载默认保留 `data/`；确认不再需要配置、Skill overlay、策略和审计数据时使用 `uninstall --purge-data`。
