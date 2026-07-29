---
name: ops-change
description: 固定边界的系统查询、变更计划和受管主机变更能力。
---

# Ops Change

所有脚本只接受一个 JSON object 参数并只输出一个 JSON object。包管理查询只使用已有缓存；账户审计不读取 shadow；计划类操作不修改主机。

## 参数契约

| Ref | 参数 |
| --- | --- |
| `package-query` | `action:"installed"|"upgradable"`，可选 `packages:string[]`（最多 64）和 `limit:1..500`。 |
| `package-upgrade-plan` | `packages:string[]`，1..64 个合法包名。 |
| `account-audit` | 可选 `limit:1..2000`。 |
| `schedule-audit` | 可选 `limit:1..1000`；仅读取 `/etc/crontab`、`/etc/cron.d` 和 systemd timers。 |
| `schedule-edit-plan` | `kind:"cron"` 时需要固定范围 `path` 和 `content`；`kind:"timer"` 时需要既有 `.timer` `unit` 和固定调度 `properties`。永不 apply。 |
| `service-restart` | `action:"read"|"plan"|"apply"` 和精确 `.service` `unit`。apply 需要 `apply:true`、`confirm:"RESTART_SERVICE"` 及 plan 摘要。 |
| `systemd-dropin` | `action:"plan"|"apply"`、精确 `.service` `unit`、`resources` 中至少一项：`cpu_percent`、`memory_bytes`、`tasks`、`restart_sec`。apply 需要 plan 摘要。 |

未知字段、错误 JSON 类型和含糊的 apply 参数会被拒绝。`service-restart` 与 `systemd-dropin` 的 apply 只在 managed systemd 安装中经 root host helper 执行；源码、Remote 和 `--no-systemd` 不降级为同 UID 写入。

## Scripts

- `scripts/package-query.sh`: 查询已安装或可升级包。
- `scripts/package-upgrade-plan.sh`: 生成无下载升级模拟。
- `scripts/account-audit.sh`: 审计 passwd/group 和当前可见登录。
- `scripts/schedule-audit.sh`: 审计固定 cron 路径和 systemd timers。
- `scripts/schedule-edit-plan.sh`: 生成 cron 或 timer 调度 diff。
- `scripts/service-restart.sh`: 读取、计划或经 host helper 重启服务。
- `scripts/systemd-dropin.sh`: 计划或经 host helper 原子应用资源 drop-in。
