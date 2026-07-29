---
name: container-inspect
description: Docker、Podman 与 CRI 的固定只读容器巡检能力。
---

# Container Inspect

该 Skill 只执行固定只读 CLI，不接受 socket、endpoint、自定义 argv 或环境覆盖。不会安装客户端，也不会扩大 Runner 对容器 socket 的权限。

## 参数契约

| Ref | 参数 |
| --- | --- |
| `runtime-summary` | 无参数；列出已安装客户端、可达性及是否需要显式选择。 |
| `container-list` | 可选 `runtime:"docker"|"podman"|"cri"`、`all:boolean`、`limit:1..500`。 |
| `container-inspect` | `id:string`，可选 `runtime`；环境只返回键名，标签和挂载敏感字段会过滤。 |
| `image-inventory` | 可选 `runtime`、`limit:1..500`。 |
| `resource-snapshot` | 可选 `runtime`、`limit:1..500`；只执行单次 stats 采样。 |

检测到多个客户端时，除 `runtime-summary` 外必须显式提供 `runtime`。工具缺失、socket 不可达或权限不足会返回明确错误，不尝试修复权限。

## Scripts

- `scripts/runtime-summary.sh`: 运行时客户端与可达性总览。
- `scripts/container-list.sh`: 有界列出容器。
- `scripts/container-inspect.sh`: 脱敏读取单个容器配置和状态。
- `scripts/image-inventory.sh`: 有界读取镜像清单。
- `scripts/resource-snapshot.sh`: 单次读取资源快照。
