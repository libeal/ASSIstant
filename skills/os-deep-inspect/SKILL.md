---
name: os-deep-inspect
description: Linux OS 环境深度感知与只读诊断脚本。用于排查端口占用、网络连接、打开文件、进程文件句柄、journalctl 日志、系统快照、异常服务和现场状态采集；工作模式和脚本模式可调用其中登记的脚本，尤其适合需要 lsof、netstat、ss、journalctl 等系统观察命令的场景。
---

# OS Deep Inspect

面向 Linux 节点做深度现场感知。优先调用这些受控脚本，而不是自由拼接 shell 命令。所有脚本接收一个 JSON 字符串作为第一个参数，并输出 JSON。

## Scripts

- `scripts/os-snapshot.sh`: 参数 `top_n`、`journal_lines`；采集主机、负载、内存、磁盘、网络接口、路由、失败服务、近期告警日志和进程摘要。
- `scripts/net-inspect.sh`: 参数 `port`、`protocol`、`state`、`limit`、`include_process`；通过 `ss` 或 `netstat` 只读查看监听端口和连接状态。
- `scripts/fd-inspect.sh`: 参数 `pid`、`pattern`、`limit`；通过 `lsof` 或 `/proc/<pid>/fd` 检查打开文件、socket、目录和匹配项。
- `scripts/journal-inspect.sh`: 参数 `unit`、`priority`、`since`、`until`、`boot`、`lines`、`grep`；通过 `journalctl` 读取受限行数的系统日志样本。

## Workflow

先用 `os-snapshot.sh` 获取全局状态，再按问题分流：

- 端口占用、外连异常、监听面暴露：调用 `net-inspect.sh`，必要时按 `port` 或 `protocol` 收窄。
- 文件句柄泄漏、进程占用文件、删除文件仍被占用：调用 `fd-inspect.sh`，优先传 `pid`，没有 PID 时再传 `pattern`。
- 服务启动失败、内核或系统错误、时间窗口内故障：调用 `journal-inspect.sh`，优先传 `unit`、`priority`、`since` 缩小范围。

## Safety

保持只读，不重启服务、不杀进程、不清理文件、不修改配置。输出可能包含路径、命令行和日志片段，脚本会走项目脱敏函数并限制行数；若需要完整日志或 root 权限下的隐藏信息，应让用户确认后再用更高权限的终端命令补采。
