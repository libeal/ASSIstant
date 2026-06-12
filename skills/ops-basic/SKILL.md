---
name: ops-basic
description: Linux 基础运维诊断与安全维护脚本。用于磁盘、日志、进程、服务、备份和低风险清理场景；工作模式和脚本模式可调用其中登记的脚本。
---

# Ops Basic

优先把 Linux 基础运维任务落到这些受控脚本，而不是自由拼接 shell 命令。所有脚本接收一个 JSON 字符串作为第一个参数，并输出 JSON。

## Scripts

- `scripts/disk-hotspots.sh`: 参数 `path`、`top_n`；只读采集磁盘热点。
- `scripts/log-search.sh`: 参数 `path`、`keyword`、`lines`、`include_journal`；仅检索 `/var/log` 下的日志，默认不读取 journal。
- `scripts/log-cleanup-plan.sh`: 参数 `root_path`、`min_size_mb`、`max_depth`、`limit`；只生成清理候选。
- `scripts/resource-inspect.sh`: 参数 `top_n`；只读查看 CPU 负载、内存概况和高 CPU/内存进程。
- `scripts/process-inspect.sh`: 参数 `pattern`；只读检查进程。
- `scripts/service-inspect.sh`: 参数 `service`；只读检查 systemd 服务。
- `scripts/config-backup.sh`: 参数 `path`、`backup_root`；生成 tar.gz 备份。
- `scripts/safe-log-cleanup.sh`: 参数 `path`、`max_size_mb`、`dry_run`；仅允许安全范围内的日志截断。
- `scripts/service-restart-plan.sh`: 参数 `service`；生成重启预检，不直接重启。

## Workflow

清理磁盘或日志时，先调用 `disk-hotspots.sh` 和 `log-cleanup-plan.sh`。真实清理前必须先调用 `config-backup.sh`，再调用 `safe-log-cleanup.sh`。
