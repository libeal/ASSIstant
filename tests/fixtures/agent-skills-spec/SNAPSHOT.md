# Agent Skills specification fixture snapshot

Source: <https://agentskills.io/specification>

Snapshot date: 2026-07-29

This fixture set freezes the open Agent Skills package surface used by Linux
Agent's parser conformance tests:

- `SKILL.md` is the only required package file.
- YAML frontmatter requires `name` and `description`.
- `license`, `compatibility`, `metadata`, and `allowed-tools` are optional.
- `metadata` is a string-to-string mapping and `allowed-tools` is a
  space-delimited string.
- A package may contain `scripts/`, `references/`, and `assets/` directories.
- `name` is 1-64 lowercase alphanumeric/hyphen characters, cannot start or end
  with a hyphen, cannot contain consecutive hyphens, and matches its directory.
- `description` is at most 1024 characters and `compatibility` at most 500.

The valid fixtures intentionally omit Linux Agent's optional
`linux-agent.json`, proving that standard instruction-only packages remain
installable. The invalid fixtures freeze rejection of duplicate keys and
invalid names. Path-escape and symlink cases are generated in the test because
they require filesystem object types rather than portable text fixtures.
