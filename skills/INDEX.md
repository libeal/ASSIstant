# Skill Index

工作模式会把此文件作为可用 skill 摘要上传给 AI。脚本模式仅允许执行这里登记且在对应 `SKILL.md` 中说明的脚本。

## ops-basic

- `ops-basic/disk-hotspots`: 采集磁盘热点目录、大文件与日志占用情况。
- `ops-basic/log-search`: 检索 `/var/log` 下的日志文件；默认不读取 journal，可通过参数显式启用。
- `ops-basic/log-cleanup-plan`: 扫描 `/var/log` 或 `/tmp` 下的大日志并生成清理建议。
- `ops-basic/resource-inspect`: 查看 CPU 负载、内存概况和高 CPU/内存进程。
- `ops-basic/process-inspect`: 检查进程、僵尸进程与匹配模式进程状态。
- `ops-basic/service-inspect`: 查看 systemd 服务状态与失败服务。
- `ops-basic/config-backup`: 在变更或清理前为目标路径生成备份。
- `ops-basic/safe-log-cleanup`: 对允许范围内的非关键日志执行安全截断。
- `ops-basic/service-restart-plan`: 生成服务重启前的只读预检计划。

## os-deep-inspect

- `os-deep-inspect/os-snapshot`: 深度采集主机、负载、磁盘、网络、失败服务、近期告警日志和进程摘要。
- `os-deep-inspect/net-inspect`: 通过 `ss` 或 `netstat` 查看监听端口、连接状态和可选进程信息。
- `os-deep-inspect/fd-inspect`: 通过 `lsof` 或 `/proc/<pid>/fd` 检查打开文件、socket 和文件句柄占用。
- `os-deep-inspect/journal-inspect`: 通过 `journalctl` 按 unit、priority、时间窗口和关键词读取系统日志样本。

## controlled-tools

- `controlled-tools/file-match`: 只读匹配目标文件中的字面量文本，返回出现次数和上下文。
- `controlled-tools/file-patch`: 在 `expected_count` 匹配时对目标文件做字面量替换、diff 预览、备份和原子写入。
- `controlled-tools/file-download`: 安全下载 HTTPS 公网文件到本机路径，限制大小并可校验 sha256。
- `controlled-tools/local-analyze`: 对文本或本地文件做只读关键词和错误样本分析。

## session-history

- `session-history/last-command-output`: 从审计 session 中读取上一轮或指定轮次的命令、步骤和 shell/stdout/stderr 输出预览。
