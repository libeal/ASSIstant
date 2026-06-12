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


