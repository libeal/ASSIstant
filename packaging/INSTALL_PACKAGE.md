# linux-agent 发行版安装包

本归档包含运行所需的源码、配置、策略、Web 静态资源和已登记 Skill。包内不包含 Python/site-packages、npm 模块、测试、日志、临时目录或 Git 数据。

## Debian/Ubuntu

使用 `linux-agent-<version>-debian.tar.gz`，解压后运行：

```bash
sudo bash install.sh
```

安装入口会从 Debian 软件源安装 `requirements/debian.txt` 中的依赖，然后调用受 SHA256 校验保护的项目安装器。需要网络工具、auditd 等可选 Skill 时追加 `--with-optional-tools`。

## Fedora/RHEL

使用 `linux-agent-<version>-fedora.tar.gz`，解压后运行：

```bash
sudo bash install.sh
```

该入口只调用 `yum install -y`，依赖来自 `requirements/fedora.txt`；可选工具使用 `--with-optional-tools`。如果系统已由其他方式准备依赖，可使用 `--skip-dependencies`。

安装器默认安装到 `/opt/linux-agent` 并注册 systemd 服务。测试或无 systemd 环境可传 `--no-systemd --prefix <目录>`。安装后编辑 `/opt/linux-agent/data/config/config.json` 设置 Provider 和 API key，再执行 `sudo systemctl restart linux-agent-web.service`。
