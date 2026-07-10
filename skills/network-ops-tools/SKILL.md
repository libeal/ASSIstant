---
name: network-ops-tools
description: 面向运维工程师和网络工程师的常用网络工具集，参考 NETworkManager 的工具边界；所有脚本同时登记给 script 模式和 work 模式，且最低声明为 medium 风险，避免主动网络行为被当作 low 风险自动执行。
---

# 网络运维工具集

这些脚本用于网络管理、诊断、查询和计算流程。每个脚本都以一个 JSON object 作为第一个参数，并向 stdout 输出一个 JSON object。

## 安全边界

- 所有脚本都声明为 `medium` 或 `high`，不能在 policy review 或 Web skill catalog 中显示为 `low`。
- 主动探测和可能修改系统状态的动作必须传入明确的授权范围确认或确认字符串。
- 扫描类脚本会限制目标、主机数量、端口范围、超时时间和结果规模。
- 具备修改能力的工具默认只读、只生成计划或 dry-run；只有同时传入 `apply: true` 和文档要求的确认字符串时才会应用变更。

## Scripts

- `scripts/ip-scanner.sh` (risk: high): 在授权范围内有界扫描 IPv4/IPv6 CIDR 或显式目标，支持 ping 和可选 TCP 探测。参数：`cidr`、`targets`、`ports`、`timeout_ms`、`max_hosts`、`only_up`、`acknowledge_authorized_scope`。
- `scripts/port-scanner.sh` (risk: high): 对单个目标主机执行有界 TCP 端口扫描。参数：`target`、`ports`、`start_port`、`end_port`、`timeout_ms`、`acknowledge_authorized_scope`。
- `scripts/discovery-protocol.sh` (risk: medium): 在本机工具可用时读取 LLDP/CDP 风格的邻居发现信息。参数：`interface`、`limit`。
- `scripts/wake-on-lan.sh` (risk: high): 预览或发送 Wake-on-LAN magic packet。参数：`mac`、`broadcast`、`port`、`dry_run`、`acknowledge_authorized_scope`。
- `scripts/network-interface.sh` (risk: medium): 检查网络接口、地址、路由、MTU、MAC 和 operstate。参数：`interface`。
- `scripts/wifi.sh` (risk: medium): 查看无线接口，并在本机工具可用时列出或扫描 Wi-Fi 网络。参数：`interface`、`scan`、`acknowledge_authorized_scope`。
- `scripts/connections.sh` (risk: medium): 通过 `ss` 查看活动 TCP/UDP 连接。参数：`protocol`、`state`、`limit`、`include_process`。
- `scripts/listeners.sh` (risk: medium): 通过 `ss` 查看监听中的 TCP/UDP socket。参数：`protocol`、`port`、`limit`、`include_process`。
- `scripts/neighbor-table.sh` (risk: medium): 读取本机 neighbor/ARP/NDP 表。参数：`interface`、`limit`。
- `scripts/ping-monitor.sh` (risk: medium): 执行有界 ping 监控并汇总丢包率和延迟。参数：`target`、`count`、`timeout_ms`、`interval_sec`、`acknowledge_authorized_scope`。
- `scripts/traceroute.sh` (risk: medium): 在工具可用时执行 traceroute/tracepath；对 loopback 目标使用安全回退。参数：`target`、`max_hops`、`timeout_ms`、`acknowledge_authorized_scope`。
- `scripts/dns-lookup.sh` (risk: medium): 使用系统解析器或可用 DNS CLI 工具解析 DNS 记录。参数：`query`、`record_type`、`server`、`timeout_ms`。
- `scripts/sntp-lookup.sh` (risk: medium): 执行或 dry-run SNTP 查询。参数：`server`、`port`、`timeout_ms`、`dry_run`。
- `scripts/whois.sh` (risk: medium): 通过 TCP/43 执行或 dry-run WHOIS 查询，并校验 WHOIS server 为公网地址。参数：`query`、`server`、`timeout_ms`、`dry_run`。
- `scripts/ip-geolocation.sh` (risk: medium): 仅对公网 IP 执行或 dry-run IP 地理位置查询。参数：`ip`、`provider`、`timeout_ms`、`dry_run`。
- `scripts/hosts-file-editor.sh` (risk: high): 读取、搜索、规划、添加或移除 hosts 记录；写入必须传入 `confirm:"APPLY_HOSTS_CHANGE"`。参数：`action`、`path`、`ip`、`hostnames`、`hostname`、`apply`、`confirm`。
- `scripts/lookup.sh` (risk: medium): 从本地数据查询端口/服务名和 MAC OUI 厂商。参数：`category`、`query`、`protocol`。
- `scripts/snmp.sh` (risk: high): dry-run 或执行有界 SNMP v2c GET，输出中不会回显 community 值。参数：`host`、`oid`、`community`、`port`、`timeout_ms`、`dry_run`、`acknowledge_authorized_scope`。
- `scripts/firewall.sh` (risk: high): 查看 firewall 状态，或生成/应用受控 UFW 规则计划；应用必须传入 `confirm:"APPLY_FIREWALL_CHANGE"`。参数：`action`、`rule`、`apply`、`confirm`。
- `scripts/subnet-calculator.sh` (risk: medium): 计算 IPv4/IPv6 子网信息，并支持可选子网拆分和 supernet 计算。参数：`cidr`、`new_prefix`、`limit`。
- `scripts/bit-calculator.sh` (risk: medium): 转换受限整数值并执行位运算。参数：`value`、`values`、`operation`、`width`、`shift`。

## 使用流程

主动探测前先收窄目标范围；只有用户确认对该范围拥有授权时，才传入 `acknowledge_authorized_scope:true`。具备修改能力的脚本应先执行 read 或 plan 动作；审查通过后，才使用 `apply:true` 和精确确认字符串执行变更。
