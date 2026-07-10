# ADR-001: 使用 GitHub Release 与临时物化提供 Remote 入口

## Status

Accepted

## Date

2026-07-10

## Context

项目需要以两条 `curl | bash` 命令提供完整 CLI/Web 能力，同时不能把完整仓库或全部 skill 安装到目标机。现有核心依赖多文件 Bash/Python，无法在完全不物化文件的情况下运行；skill registry 又要求 INDEX、manifest、脚本和 policy 一致校验。

Remote 模式还会处理 API key、审计日志和用户生成的 skill，因此必须区分短期运行状态与用户明确要求保存的备份。

## Decision

- 使用同一 GitHub Release 发布两个 bootstrap、CLI core、Web 增量包、manifest/checksums 和每个一级 skill 的完整独立归档。
- Bootstrap 通过标准输入执行；已验证资产只物化到 `$XDG_RUNTIME_DIR`、`/dev/shm` 或安全 `/tmp` 子目录，退出清理且不建立跨运行缓存。
- Skill 按一级包懒加载，在 staging 完成摘要、归档边界、manifest、INDEX 和 policy 校验后原子登记。
- `remote.allow_api_key_transmission` 默认关闭；Remote Web key 只驻留内存，CLI key 只驻留当前进程环境。
- 只有显式 backup 可以把脱敏 audit、报告、配置和用户 skill 保存到 runtime 之外。
- 官方入口不改变第三方 `remote_script` 和远程管道阻断策略。

## Alternatives Considered

### 下载完整仓库归档

实现简单，但会预下载全部 skill、测试和无关文档，违背懒加载与最小供应链暴露目标。

### 为每个脚本发布独立文件

下载量更小，但会遗漏 skill 的 agents/references/assets，且难以保证 `SKILL.md` 与所有脚本作为一个校验单元更新。

### 持久化到用户缓存目录

能减少重复下载，但产生版本漂移、残留敏感状态和缓存投毒边界。本功能更重视临时性与可复现校验。

### 严格只允许 tmpfs

磁盘边界最强，但部分 Linux 环境没有可用的用户 runtime tmpfs。采用内存目录优先、权限受控 `/tmp` 回退，并明确记录 storage backend。

## Consequences

- 目标机仍需预装项目已有的基础命令。
- 每次 Remote 运行会重新获取并校验 core，首次使用某 skill 时重新获取整包。
- GitHub Release 和仓库发布权限成为第一方信任根；SHA256 主要保证 manifest/asset 一致性。
- Web 必须通过回环地址和 SSH tunnel 使用，不能把当前无 TLS server 直接暴露公网。
- 发布前必须通过确定性构建、remote resolver、安全、Web 与发布后入口 smoke tests。
