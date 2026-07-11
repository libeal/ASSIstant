---
name: ops-basic
description: Linux 基础运维诊断与安全维护脚本。用于磁盘、日志、进程、服务、备份和低风险清理场景；工作模式和脚本模式可调用其中登记的脚本。
---

# Ops Basic

优先把 Linux 基础运维任务落到这些受控脚本，而不是自由拼接 shell 命令。所有脚本接收一个 JSON 字符串作为第一个参数，并输出 JSON。

## 统一传参规范

调用形式为 `bash scripts/<name>.sh '<json-object>'`。唯一位置参数必须是 JSON object；stdout 只输出一个 JSON object。调用方必须依据 `ok` 判断业务成功，不能仅检查进程退出码。布尔值必须使用 JSON `true/false`，整数不得用带单位字符串。

## 参数契约

| Script | 必填字段 | 可选字段（类型；默认；约束） |
| --- | --- | --- |
| `disk-hotspots.sh` | 无 | `path:string`（`/var`）、`top_n:integer`（10；正整数） |
| `log-search.sh` | 无 | `path:string`（`/var/log`；必须位于 `/var/log`）、`keyword:string`（`error`）、`lines:integer`（20；正整数）、`include_journal:boolean`（false） |
| `log-cleanup-plan.sh` | 无 | `root_path:string`（`/var/log`；仅 `/var/log` 或 `/tmp`）、`min_size_mb:integer`（100；>0）、`max_depth:integer`（2；>0）、`limit:integer`（20；>0） |
| `resource-inspect.sh` | 无 | `top_n:integer`（10；正整数） |
| `process-inspect.sh` | 无 | `pattern:string`（空；按进程文本过滤） |
| `service-inspect.sh` | 无 | `service:string`（空；非空时只查该 systemd unit） |
| `config-backup.sh` | `path:string` | `backup_root:string`（`/tmp/linux-agent-backups`） |
| `safe-log-cleanup.sh` | `path:string` | `max_size_mb:integer`（100；>=0）、`dry_run:boolean`（true）。只接受受控日志路径和普通非符号链接文件 |
| `service-restart-plan.sh` | `service:string` | 无；service 只能包含受支持的 unit 名字符，不执行重启 |

示例：`bash scripts/resource-inspect.sh '{"top_n":5}'`。

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
