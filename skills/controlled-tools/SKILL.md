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
| `file-match.sh` | `path:string`、`find:string`（非空） | `context_lines:integer`（2；0..20）、`max_matches:integer`（20；1..100）、`max_file_bytes:integer`（2 MiB；正数） |
| `file-patch.sh` | `path:string`、`find:string`（非空）、`expected_count:integer`（>=1） | `replacement:string`（空串）、`apply:boolean`（true）、`backup:boolean`（true；`apply=true` 时必须为 true）、`max_file_bytes:integer`（2 MiB；正数）。实际匹配数必须严格等于 `expected_count` |
| `file-download.sh` | `url:string`、`output_path:string` | `expected_sha256:string`（空；64 位小写 hex）、`max_bytes:integer`（100 MiB；1..100 MiB）、`overwrite:boolean`（false）、`create_parent:boolean`（false）。URL 只能是无内嵌凭据的 HTTPS 且解析到公网地址 |
| `local-analyze.sh` | `text:string` 与 `path:string` 二选一 | `max_bytes:integer`（256 KiB；正数）。同时提供时优先使用 `text` |

示例：`bash scripts/file-match.sh '{"path":"/tmp/app.conf","find":"listen=","context_lines":1,"max_matches":10}'`。

## Scripts

- `scripts/file-match.sh`: 只读确认字面量出现次数和上下文。
- `scripts/file-patch.sh`: 按字面量替换并在计数匹配时原子写入。
- `scripts/file-download.sh`: 仅允许 HTTPS、公网地址和大小受限的文件下载。
- `scripts/local-analyze.sh`: 本地分析文本行数、关键词和错误样本，不修改文件。

## Workflow

修改文件前先调用 `file-match.sh`，确认 `find` 文本、上下文和出现次数。随后调用 `file-patch.sh`，并把 `expected_count` 设置为上一步返回的 `match_count`。如果需要先拉取外部文件，使用 `file-download.sh`，不要用 `curl -o`、`wget -O` 或 shell 重定向。
