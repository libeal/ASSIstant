---
name: controlled-tools
description: 受控文件与工具能力。用于文件匹配、原子补丁、安全下载和本地文本分析；文件修改必须优先使用这里登记的脚本。
---

# Controlled Tools

这些脚本提供比自由 shell 更窄的能力边界。所有脚本接收一个 JSON 字符串作为第一个参数，并输出 JSON。

## 统一传参规范

- 调用形式：`bash scripts/<name>.sh '<json-object>'`；只能传一个位置参数，内容必须是 JSON object，不能传数组、裸字符串或 shell 参数列表。
- 字段名区分大小写；未声明字段不得用于改变安全边界。路径必须是普通非符号链接文件；文本文件按 UTF-8 处理。
- stdout 只输出一个 JSON object。调用方先检查 `ok`，失败时再读取 `status`、`error`；不得把进程退出码 `0` 等同于业务成功。

## 参数契约

| Script | 必填字段 | 可选字段（类型；默认；约束） |
| --- | --- | --- |
| `file-match.sh` | `path:string`、`find:string`（非空） | `context_lines:integer`（2；0..20）、`max_matches:integer`（20；1..100）、`max_file_bytes:integer`（2 MiB；正数）；返回文件 SHA-256 |
| `file-patch.sh` | `path:string`；旧调用仍接受 `find/replacement/expected_count` | `action:"patch"` 需要 `operations[]` 与 `expected_sha256`；`append_block` 需要安全 marker、comment prefix、content、摘要及显式 `apply`；`create` 需要 content 与显式 `apply`，`mode` 默认 `0600` |
| `file-download.sh` | `url:string`、`output_path:string` | `expected_sha256:string`（空；64 位小写 hex）、`max_bytes:integer`（100 MiB；1..100 MiB）、`overwrite:boolean`（false）、`create_parent:boolean`（false）。URL 只能是无内嵌凭据的 HTTPS 且解析到公网地址 |
| `local-analyze.sh` | `text:string` 与 `path:string` 二选一 | `max_bytes:integer`（256 KiB；正数）。同时提供时优先使用 `text` |

示例：`bash scripts/file-match.sh '{"path":"/tmp/app.conf","find":"listen=","context_lines":1,"max_matches":10}'`。

## Scripts

- `scripts/file-match.sh`: 只读确认字面量出现次数和上下文。
- `scripts/file-patch.sh`: 按摘要执行多项字面量补丁、幂等 managed block 或排他新建；现有文件使用同目录锁、单份备份和一次原子提交。
- `scripts/file-download.sh`: 仅允许 HTTPS、公网地址和大小受限的文件下载。
- `scripts/local-analyze.sh`: 本地分析文本行数、关键词和错误样本，不修改文件。

## Workflow

修改文件前先调用 `file-match.sh`，确认文本、上下文、出现次数和 SHA-256。新调用把该摘要作为 `expected_sha256`；任何摘要或计数变化都会零写入失败。旧单次 `find/replacement/expected_count` 调用继续兼容。如果需要先拉取外部文件，使用 `file-download.sh`，不要用 `curl -o`、`wget -O` 或 shell 重定向。
