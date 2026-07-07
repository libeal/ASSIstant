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

## network-ops-tools

- `network-ops-tools/ip-scanner`: 有界扫描授权范围内的 IP/CIDR，支持 ping 与少量 TCP 探测。
- `network-ops-tools/port-scanner`: 有界扫描单个目标主机的 TCP 端口。
- `network-ops-tools/discovery-protocol`: 读取本机 LLDP/CDP 风格邻居发现信息。
- `network-ops-tools/wake-on-lan`: 预览或发送 Wake-on-LAN magic packet。
- `network-ops-tools/network-interface`: 查看网络接口、地址、路由、MTU、MAC 与 operstate。
- `network-ops-tools/wifi`: 查看无线接口和可用 Wi-Fi 网络信息。
- `network-ops-tools/connections`: 查看活动 TCP/UDP 连接。
- `network-ops-tools/listeners`: 查看监听中的 TCP/UDP socket。
- `network-ops-tools/neighbor-table`: 查看本机 ARP/NDP neighbor table。
- `network-ops-tools/ping-monitor`: 执行有界 ping 监控并汇总丢包和延迟。
- `network-ops-tools/traceroute`: 执行 traceroute/tracepath 或 loopback 安全回退。
- `network-ops-tools/dns-lookup`: 执行 DNS 查询，优先使用本机解析器或可用 DNS 工具。
- `network-ops-tools/sntp-lookup`: 执行或 dry-run SNTP 时间查询。
- `network-ops-tools/whois`: 执行或 dry-run WHOIS 查询，并校验 WHOIS server 为公网地址。
- `network-ops-tools/ip-geolocation`: 查询或 dry-run 公网 IP 地理位置。
- `network-ops-tools/hosts-file-editor`: 读取、搜索、规划或确认修改 hosts 文件。
- `network-ops-tools/lookup`: 查询端口/服务名和 MAC OUI 厂商。
- `network-ops-tools/snmp`: dry-run 或执行有界 SNMP v2c GET。
- `network-ops-tools/firewall`: 查看 firewall 状态、生成规则计划或确认应用 UFW 规则。
- `network-ops-tools/subnet-calculator`: 计算 IPv4/IPv6 子网、可用地址和拆分子网。
- `network-ops-tools/bit-calculator`: 转换二进制/十六进制/十进制并执行位运算。
