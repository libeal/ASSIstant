---
name: network-ops-tools
description: 面向运维工程师和网络工程师的常用网络工具集，参考 NETworkManager 的工具边界；所有脚本同时登记给 script 模式和 work 模式，且最低声明为 medium 风险，避免主动网络行为被当作 low 风险自动执行。
---

# 网络运维工具集

这些脚本用于网络管理、诊断、查询和计算流程。每个脚本都以一个 JSON object 作为第一个参数，并向 stdout 输出一个 JSON object。

## 统一传参规范

- 调用形式：`bash scripts/<name>.sh '<json-object>'`；只能传一个位置参数，内容必须是 JSON object。stdout 只输出一个 JSON object，调用方以 `ok`、`status`、`error` 判断业务结果。
- `timeout_ms` 均为整数毫秒，脚本会限制在各工具允许的区间；`ports` 可为整数数组或逗号/范围字符串。主机、接口、CIDR、端口和枚举值会在边界处校验。
- 主动探测非 loopback 目标时，`acknowledge_authorized_scope:boolean` 必须为 `true`；此值只表示调用方已确认授权，不替代 policy 和人工审批。
- `dry_run`、`apply` 必须是 JSON boolean。修改型工具必须同时满足 `apply:true`、精确 `confirm` 字符串和外层审批，缺一不可。

## 参数契约补充

| Script | 必填与互斥条件 | 默认值与硬限制 |
| --- | --- | --- |
| `ip-scanner.sh` | `cidr:string` 或 `targets:string[]` 二选一 | `ports:[]`（最多 32）、`timeout_ms:750`（100..5000）、`max_hosts:256`（1..1024）、`ping:true`、`only_up:false`、`workers<=128` |
| `port-scanner.sh` | `target:string`；`ports`、`common_ports:true`、`start_port/end_port` 三选一 | 默认 1..100，最多 512 端口；`timeout_ms:750`（100..5000）、`workers<=256` |
| `discovery-protocol.sh` | 无 | `interface:""`、`limit:80`（1..300） |
| `wake-on-lan.sh` | `mac:string` | `broadcast:"255.255.255.255"`、`port:9`、`dry_run:false`；真实发送需授权确认 |
| `network-interface.sh` | 无 | `interface:""`；空值表示全部接口 |
| `wifi.sh` | 无 | `interface:""`、`scan:false`；`scan:true` 需授权确认 |
| `connections.sh` | 无 | `protocol:"all"`、`state:""`、`limit:100`（1..500）、`include_process:false` |
| `listeners.sh` | 无 | `protocol:"all"`、`port:""`（1..65535）、`limit:100`（1..500）、`include_process:false` |
| `neighbor-table.sh` | 无 | `interface:""`、`limit:200`（1..1000） |
| `ping-monitor.sh` | `target:string` | `count:4`（1..30）、`timeout_ms:1000`（100..10000）、`interval_sec:1`（1..10） |
| `traceroute.sh` | `target:string` | `max_hops:30`（1..64）、`timeout_ms:1000`（100..10000） |
| `dns-lookup.sh` | `query:string` | `record_type:"A"`、`server:""`、`timeout_ms:3000`（100..10000） |
| `sntp-lookup.sh` | 无 | `server:"pool.ntp.org"`、`port:123`、`timeout_ms:3000`（100..10000）、`dry_run:false` |
| `whois.sh` | `query:string` | `server` 按 TLD 推导、`timeout_ms:5000`（100..15000）、`dry_run:false`；server 必须解析到公网地址 |
| `ip-geolocation.sh` | `ip:string`（仅公网 IP） | `provider:"ipapi"`（`ipapi/ipwhois`）、`timeout_ms:5000`（100..15000）、`dry_run:false` |
| `hosts-file-editor.sh` | action 为 add/plan-add 时需 `ip` 与 `hostnames`; remove/search 时需 `hostname` | `action:"read"`、`path:"/etc/hosts"`、`limit:200`（1..1000）、`apply:false`；写入需 `confirm:"APPLY_HOSTS_CHANGE"` |
| `lookup.sh` | `query:string` | `category:"port"`（`port/oui`）、`protocol:"tcp"` |
| `snmp.sh` | `host:string` | `oid:".1.3.6.1.2.1.1.1.0"`、`community:"public"`、`port:161`、`timeout_ms:3000`（100..10000）、`dry_run:false`；community 不回显 |
| `firewall.sh` | plan/apply 需规则 `decision`、`protocol`、`port`，可放在 `rule` object | `action:"status"`、`decision:"allow"`、`protocol:"tcp"`、`source:"any"`、`apply:false`；写入需 `confirm:"APPLY_FIREWALL_CHANGE"` |
| `subnet-calculator.sh` | `cidr:string` | `new_prefix` 可选且不得小于原前缀，`limit:32`（1..512） |
| `bit-calculator.sh` | `value` 或 `values`；and/or/xor 至少两个值 | `operation:"convert"`、`width:32`（1..128）、`shift:1`（0..width） |

示例：`bash scripts/port-scanner.sh '{"target":"127.0.0.1","ports":[22,443],"timeout_ms":500}'`。

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
