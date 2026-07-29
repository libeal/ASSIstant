---
name: database-inspect
description: PostgreSQL 与 MySQL/MariaDB 的发现及固定只读健康和指标巡检。
---

# Database Inspect

该 Skill 不接受 SQL、可执行路径、自定义 argv 或 managed endpoint。健康与指标查询来自发行版固定 SQL，并通过专用非 root helper 执行。

## 参数契约

| Ref | 参数 |
| --- | --- |
| `instance-discovery` | 无参数；只检查标准 Unix socket 与固定客户端路径，不读取凭据、不探测网络。 |
| `instance-health` | managed 使用 `profile_id:string`，可选一次性 `credential_ref:string`；不能覆盖 endpoint、port、database 或 TLS。 |
| `instance-metrics` | 参数同 health，执行固定的最小只读指标查询。 |

root profile 通过 `agent credentials database validate|install|list|remove|refresh-egress` 管理。profile 支持 PostgreSQL、MySQL/MariaDB、Unix socket 或精确 IP；`database` 仅接受由字母、数字、`_`、`.`、`$`、`-` 组成且不以符号开头的简单名称，不接受连接串或客户端选项；非 loopback TCP 必须使用证书身份校验。

## Scripts

- `scripts/instance-discovery.sh`: 发现标准本地 socket 和可用客户端。
- `scripts/instance-health.sh`: 通过 credential helper 执行固定健康查询。
- `scripts/instance-metrics.sh`: 通过 credential helper 执行固定指标查询。
