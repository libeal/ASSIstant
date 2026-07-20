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

## Fedora/RHEL

使用 `linux-agent-<version>-fedora.tar.gz`，同样先校验外层归档：

```bash
sha256sum -c linux-agent-<version>-fedora.tar.gz.sha256
tar -xzf linux-agent-<version>-fedora.tar.gz
cd linux-agent-<version>-fedora
sudo bash install.sh --provider-cidr 203.0.113.0/24
```

该入口只调用 `yum install -y`，依赖来自 `requirements/fedora.txt`；可选工具使用 `--with-optional-tools`。如果系统已由其他方式准备依赖，可使用 `--skip-dependencies`。包不是 `.deb`/`.rpm`，升级、回滚和卸载都使用包内 `release/linux-agent-install.sh`，不使用 `apt remove` 或 `dnf remove`。

安装器默认安装到 `/opt/linux-agent` 并写入 systemd unit。安装期间会先停止遗留实例，再临时启动新版本完成健康检查，检查结束后自动停止 Web、observer socket 和 helper。安装器不会修改原有开机启用状态；全新安装默认未启用。需要正式运行时显式执行：

```bash
sudo systemctl enable --now linux-agent-observer-helper.socket linux-agent-web.service
```

如果 Web 控制台报告 `observer_helper_failed` 且错误是 observer socket 权限不足，先用当前版本安装器重建 unit 和 socket：

```bash
sudo bash linux-agent-install.sh repair-observer
```

该操作会重新应用服务用户对应的 `SocketGroup`，停止并重建 `linux-agent-observer-helper.socket`，再以 Web 服务用户执行认证健康检查；不会切换版本或修改持久配置。

启动前应先编辑 `/opt/linux-agent/data/config/config.json` 设置 Provider 和 API key。测试或无 systemd 环境可传 `--skip-dependencies --no-systemd --prefix <目录>`。卸载默认保留 `data/`；确认不再需要配置和审计数据时使用 `uninstall --purge-data`，该选项也会删除安装器创建的服务用户。
