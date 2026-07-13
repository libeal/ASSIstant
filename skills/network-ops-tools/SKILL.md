---
name: network-ops-tools
description: 面向运维工程师和网络工程师的常用网络工具集；所有脚本同时登记给 script 模式和 work 模式，且最低声明为 medium 风险，避免主动网络行为被当作 low 风险自动执行。
---

# 网络运维工具集

这些脚本用于网络管理、诊断、查询和计算流程。每个脚本都以一个 JSON object 作为第一个参数，并向 stdout 输出一个 JSON object。实现共享 `scripts/_network_tool.py`（调度器与通用工具），SNMP 与 DNS 的底层编解码分别位于同目录的 `scripts/_snmp.py` 和 `scripts/_dns.py` 辅助模块。

## 统一传参规范

- 调用形式：`bash scripts/<name>.sh '<json-object>'`；只能传一个位置参数，内容必须是 JSON object。stdout 只输出一个 JSON object，调用方以 `ok`、`status`、`error` 判断业务结果。
- `timeout_ms` 均为整数毫秒，脚本会限制在各工具允许的区间；`ports` 可为整数数组或逗号/范围字符串。主机、接口、CIDR、端口和枚举值会在边界处校验。
- 主动探测非 loopback 目标时，`acknowledge_authorized_scope:boolean` 必须为 `true`；此值只表示调用方已确认授权，不替代 policy 和人工审批。
- `dry_run`、`apply` 必须是 JSON boolean。修改型工具必须同时满足 `apply:true`、精确 `confirm` 字符串和外层审批，缺一不可。
- SNMP community、SNMPv3 认证口令等敏感值不会在输出中回显。

## 参数契约补充

| Script | 必填与互斥条件 | 默认值与硬限制 |
| --- | --- | --- |
| `ip-scanner.sh` | `cidr:string` 或 `targets:string[]` 二选一 | `ports:[]`（最多 32）、`timeout_ms:750`（100..5000）、`max_hosts:256`（1..1024）、`ping:true`、`only_up:false`、`resolve_mac:false`、`resolve_hostnames:true`、`workers<=128` |
| `port-scanner.sh` | `target:string`；`ports`、`common_ports:true`、`start_port/end_port` 三选一 | `protocol:"tcp"`（tcp/udp）、默认 1..100，最多 512 端口；`banner:false`、`timeout_ms:750`（100..5000）、`workers<=256` |
| `discovery-protocol.sh` | 无 | `protocol:"lldp"`（lldp/cdp/all）、`interface:""`、`limit:80`（1..300）；CDP 抓包需授权确认 |
| `wake-on-lan.sh` | `mac:string` | `broadcast:"255.255.255.255"`（或 `target`）、`port:9`、`repeat:1`（1..10）、`secure_on:""`（6 字节 hex）、`dry_run:false`；真实发送需授权确认 |
| `network-interface.sh` | 无 | `interface:""`；空值表示全部接口 |
| `wifi.sh` | 无 | `interface:""`、`scan:false`；`scan:true` 需授权确认 |
| `connections.sh` | 无 | `protocol:"all"`、`state:""`、`limit:100`（1..500）、`include_process:false` |
| `listeners.sh` | 无 | `protocol:"all"`、`port:""`（1..65535）、`limit:100`（1..500）、`include_process:false` |
| `neighbor-table.sh` | 无 | `interface:""`、`limit:200`（1..1000） |
| `ping-monitor.sh` | `target:string` | `count:4`（1..30）、`timeout_ms:1000`（100..10000）、`interval_sec:1`（1..10） |
| `traceroute.sh` | `target:string` | `mode:"default"`（default/icmp/tcp/udp）、`max_hops:30`（1..64）、`timeout_ms:1000`（100..10000） |
| `dns-lookup.sh` | `query:string` | `record_type:"A"` 或 `record_types:string[]`、`server:""`、`port:53`、`timeout_ms:3000`（100..10000） |
| `sntp-lookup.sh` | 无 | `server:"pool.ntp.org"`、`port:123`、`timeout_ms:3000`（100..10000）、`dry_run:false`；输出含 stratum/offset/delay |
| `whois.sh` | `query:string` | `server` 按 TLD/IP 推导、`max_referrals:3`（0..5）、`timeout_ms:5000`（100..15000）、`dry_run:false`；server 必须解析到公网地址 |
| `ip-geolocation.sh` | `ip:string`（仅公网 IP） | `provider:"ipapi"`（`ipapi/ipwhois`）、`timeout_ms:5000`（100..15000）、`dry_run:false` |
| `hosts-file-editor.sh` | add/plan-add 需 `ip` 与 `hostnames`；remove/plan-remove 需 `hostname` 或 `ip`；search 需 `hostname` | `action:"read"`、`path:"/etc/hosts"`、`merge:false`、`limit:200`（1..1000）、`apply:false`；写入需 `confirm:"APPLY_HOSTS_CHANGE"` |
| `lookup.sh` | `query:string` | `category:"port"`（`port/service/oui/protocol/icmp`）、`protocol:"tcp"` |
| `snmp.sh` | `host:string` | `version:"2c"`（1/2c/3）、`action:"get"`（get/getnext/walk/bulk）、`oid`/`oids[]`（默认 sysDescr，支持命名别名）、`community:"public"`、`port:161`、`max_repetitions:10`、`max_oids:64`、v3 需 `user`+可选 `auth_protocol`(md5/sha)+`auth_password`、`timeout_ms:3000`（100..10000）、`dry_run:false`；community/口令不回显；不支持 v3 authPriv |
| `firewall.sh` | plan/apply 需规则 `decision`、`protocol`、`port`，可放在 `rule` object | `action:"status"`、`backend:"ufw"`（apply 支持 ufw/firewalld）、`decision:"allow"`、`protocol:"tcp"`、`source:"any"`、`apply:false`；写入需 `confirm:"APPLY_FIREWALL_CHANGE"` |
| `subnet-calculator.sh` | `cidr:string` 或 `aggregate:string[]` | `new_prefix` 支持拆分或 supernet、`contains` 成员判断、`limit:32`（1..512） |
| `bit-calculator.sh` | `value` 或 `values`；and/or/xor 至少两个值 | `operation:"convert"`（convert/not/and/or/xor/shl/shr/rol/ror/setbit/clearbit/togglebit/testbit/byteswap）、`width:32`（1..128）、`shift:1`（0..width）、`index:0` |
| `tls-inspect.sh` | `host:string` | `port:443`、`servername:host`、`timeout_ms:5000`（100..15000）、`dry_run:false`；非 loopback 需授权 |
| `http-check.sh` | `url:string`（http(s)） | `method:"GET"`（GET/HEAD）、`timeout_ms:8000`（100..20000）、`dry_run:false`；非 loopback host 需授权 |
| `public-ip.sh` | 无 | `method:"stun"`（stun/https）、`server:"stun.l.google.com"`、`port:19302`、`url`、`timeout_ms:5000`（100..15000）、`dry_run:false` |
| `service-discovery.sh` | 无 | `protocol:"ssdp"`（ssdp/mdns/all）、`service`、`limit:50`（1..200）、`timeout_ms:3000`（100..8000）、`dry_run:false`；组播发现需授权 |

示例：`bash scripts/port-scanner.sh '{"target":"127.0.0.1","ports":[22,443],"timeout_ms":500}'`。

## 安全边界

- 所有脚本都声明为 `medium` 或 `high`，不能在 policy review 或 Web skill catalog 中显示为 `low`。
- 主动探测和可能修改系统状态的动作必须传入明确的授权范围确认或确认字符串。
- 扫描类脚本会限制目标、主机数量、端口范围、超时时间和结果规模。
- 具备修改能力的工具默认只读、只生成计划或 dry-run；只有同时传入 `apply: true` 和文档要求的确认字符串时才会应用变更。
- `tls-inspect`、`http-check`、`public-ip`、`service-discovery` 会发起主动网络外连或组播，声明为 `medium` 风险；探测非 loopback/局域网目标需要授权确认，并进入 policy、审批与审计链路。
- SNMPv3 仅支持 noAuthNoPriv 与 authNoPriv；authPriv（加密）因标准库无对应加密算法而不支持。

## Scripts

- `scripts/ip-scanner.sh` (risk: high): 在授权范围内有界扫描 IPv4/IPv6 CIDR 或显式目标，支持 ping、可选 TCP 探测、开放端口服务名提示与可选 MAC/厂商解析。参数：`cidr`、`targets`、`ports`、`timeout_ms`、`max_hosts`、`only_up`、`resolve_mac`、`resolve_hostnames`、`acknowledge_authorized_scope`。
- `scripts/port-scanner.sh` (risk: high): 对单个目标主机执行有界 TCP/UDP 端口扫描，标注服务名并可抓取 banner。参数：`target`、`protocol`、`ports`、`start_port`、`end_port`、`banner`、`timeout_ms`、`acknowledge_authorized_scope`。
- `scripts/discovery-protocol.sh` (risk: medium): 解析本机 LLDP 结构化邻居信息，并可在工具可用且授权时进行 CDP 抓包。参数：`protocol`、`interface`、`limit`、`acknowledge_authorized_scope`。
- `scripts/wake-on-lan.sh` (risk: high): 预览或发送 Wake-on-LAN magic packet，支持 SecureON 密码与重复发送。参数：`mac`、`broadcast`、`target`、`port`、`repeat`、`secure_on`、`dry_run`、`acknowledge_authorized_scope`。
- `scripts/network-interface.sh` (risk: medium): 检查网络接口、地址、路由、逐接口统计计数、默认网关、DNS、MTU、MAC 和 operstate。参数：`interface`。
- `scripts/wifi.sh` (risk: medium): 查看无线接口，并在本机工具可用时列出或扫描 Wi-Fi 网络（结构化 SSID/BSSID/信道/信号/加密）。参数：`interface`、`scan`、`acknowledge_authorized_scope`。
- `scripts/connections.sh` (risk: medium): 通过 `ss` 查看活动 TCP/UDP 连接，拆分本地/对端地址与端口、进程信息并按状态汇总。参数：`protocol`、`state`、`limit`、`include_process`。
- `scripts/listeners.sh` (risk: medium): 通过 `ss` 查看监听中的 TCP/UDP socket，拆分地址/端口/进程。参数：`protocol`、`port`、`limit`、`include_process`。
- `scripts/neighbor-table.sh` (risk: medium): 读取本机 neighbor/ARP/NDP 表。参数：`interface`、`limit`。
- `scripts/ping-monitor.sh` (risk: medium): 执行有界 ping 监控并汇总丢包率、延迟、抖动与逐包 RTT 序列。参数：`target`、`count`、`timeout_ms`、`interval_sec`、`acknowledge_authorized_scope`。
- `scripts/traceroute.sh` (risk: medium): 在工具可用时执行 traceroute/tracepath（可选 ICMP/TCP/UDP 模式），解析逐跳地址与 RTT；对 loopback 目标使用安全回退。参数：`target`、`mode`、`max_hops`、`timeout_ms`、`acknowledge_authorized_scope`。
- `scripts/dns-lookup.sh` (risk: medium): 使用 `dig` 或内置纯 Python 解析器解析 DNS 记录，支持 A/AAAA/MX/TXT/NS/SOA/CNAME/SRV/CAA/PTR 与自定义 server。参数：`query`、`record_type`、`record_types`、`server`、`port`、`timeout_ms`。
- `scripts/sntp-lookup.sh` (risk: medium): 执行或 dry-run SNTP 查询，解析 leap/version/stratum/root-delay 并计算时钟 offset 与往返 delay。参数：`server`、`port`、`timeout_ms`、`dry_run`。
- `scripts/whois.sh` (risk: medium): 通过 TCP/43 执行或 dry-run WHOIS 查询，跟随注册商与 RIR 引用链，并校验每个 WHOIS server 为公网地址。参数：`query`、`server`、`max_referrals`、`timeout_ms`、`dry_run`。
- `scripts/ip-geolocation.sh` (risk: medium): 仅对公网 IP 执行或 dry-run IP 地理位置查询。参数：`ip`、`provider`、`timeout_ms`、`dry_run`。
- `scripts/hosts-file-editor.sh` (risk: high): 读取、搜索、规划、添加或移除 hosts 记录，支持合并去重与按主机名/IP 移除；写入必须传入 `confirm:"APPLY_HOSTS_CHANGE"`。参数：`action`、`path`、`ip`、`hostnames`、`hostname`、`merge`、`apply`、`confirm`。
- `scripts/lookup.sh` (risk: medium): 从本地数据查询端口/服务名、MAC OUI 厂商、协议号和 ICMP 类型。参数：`category`、`query`、`protocol`。
- `scripts/snmp.sh` (risk: high): dry-run 或执行有界 SNMP get/getnext/walk/bulk，支持 v1/v2c/v3-auth、多 OID 与命名别名，输出中不会回显 community 或口令。参数：`host`、`version`、`action`、`oid`、`oids`、`community`、`user`、`auth_protocol`、`auth_password`、`port`、`max_repetitions`、`max_oids`、`timeout_ms`、`dry_run`、`acknowledge_authorized_scope`。
- `scripts/firewall.sh` (risk: high): 查看 firewall 状态，或生成 ufw/nft/iptables/firewalld 规则计划并可确认应用 ufw/firewalld 规则；应用必须传入 `confirm:"APPLY_FIREWALL_CHANGE"`。参数：`action`、`backend`、`rule`、`apply`、`confirm`。
- `scripts/subnet-calculator.sh` (risk: medium): 计算 IPv4/IPv6 子网信息，支持子网拆分、supernet、网络聚合、通配符掩码、反向 DNS 区域和成员判断。参数：`cidr`、`aggregate`、`new_prefix`、`contains`、`limit`。
- `scripts/bit-calculator.sh` (risk: medium): 转换受限整数值并执行位运算、移位、循环移位、置/清/翻/测位和字节序转换。参数：`value`、`values`、`operation`、`width`、`shift`、`index`。
- `scripts/tls-inspect.sh` (risk: medium): 检查目标 TLS 端点的协议、加密套件与证书（有效期、SAN、颁发者、校验状态）。参数：`host`、`port`、`servername`、`timeout_ms`、`dry_run`、`acknowledge_authorized_scope`。
- `scripts/http-check.sh` (risk: medium): 检查 HTTP(S) 端点的状态码、跳转链、响应头与耗时，可选 body 摘要。参数：`url`、`method`、`timeout_ms`、`dry_run`、`acknowledge_authorized_scope`。
- `scripts/public-ip.sh` (risk: medium): 通过 STUN 或 HTTPS echo 查询本机公网/反射地址。参数：`method`、`server`、`port`、`url`、`timeout_ms`、`dry_run`。
- `scripts/service-discovery.sh` (risk: medium): 通过 mDNS/SSDP 组播发现局域网服务。参数：`protocol`、`service`、`limit`、`timeout_ms`、`dry_run`、`acknowledge_authorized_scope`。

## 使用流程

主动探测前先收窄目标范围；只有用户确认对该范围拥有授权时，才传入 `acknowledge_authorized_scope:true`。具备修改能力的脚本应先执行 read 或 plan 动作；审查通过后，才使用 `apply:true` 和精确确认字符串执行变更。TLS/HTTP/公网 IP/服务发现等外连与组播工具也应先在明确授权和最小范围下调用。
