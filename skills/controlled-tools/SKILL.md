---
name: controlled-tools
description: 受控文件与工具能力。用于文件匹配、原子补丁、安全下载和本地文本分析；文件修改必须优先使用这里登记的脚本。
---

# Controlled Tools

这些脚本提供比自由 shell 更窄的能力边界。所有脚本接收一个 JSON 字符串作为第一个参数，并输出 JSON。

## Scripts

- `scripts/file-match.sh`: 参数 `path`、`find`、`context_lines`、`max_matches`；只读确认文本出现次数和上下文。
- `scripts/file-patch.sh`: 参数 `path`、`find`、`replacement`、`expected_count`、`apply`、`backup`；按字面量替换并在计数匹配时原子写入。
- `scripts/file-download.sh`: 参数 `url`、`output_path`、`expected_sha256`、`max_bytes`、`overwrite`、`create_parent`；仅允许 HTTPS、公网地址和大小受限的文件下载。
- `scripts/local-analyze.sh`: 参数 `text` 或 `path`、`max_bytes`；本地分析文本行数、关键词和错误样本，不修改文件。

## Workflow

修改文件前先调用 `file-match.sh`，确认 `find` 文本、上下文和出现次数。随后调用 `file-patch.sh`，并把 `expected_count` 设置为上一步返回的 `match_count`。如果需要先拉取外部文件，使用 `file-download.sh`，不要用 `curl -o`、`wget -O` 或 shell 重定向。
