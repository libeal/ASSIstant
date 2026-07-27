#!/usr/bin/env python3
"""Structured shell command guard.

The project intentionally stays dependency-light, so this is a small shell
token AST built on Python's standard-library shlex rather than tree-sitter.
It is not a full Bash interpreter. It is a fail-closed risk classifier for the
command shapes this agent is allowed to execute.
"""

from __future__ import annotations

import argparse
import json
import re
import shlex
import subprocess
import sys
from dataclasses import dataclass
from pathlib import PurePosixPath
from typing import Iterable

from subprocess_env import build_subprocess_env


SEPARATORS = {";", "&&", "||", "&"}
PIPE_OPERATORS = {"|", "|&"}
SHELL_CONDITION_PREFIXES = {"if", "elif", "while", "until"}
SHELL_BODY_PREFIXES = {"then", "do", "else", "!", "{"}
SHELL_DECLARATION_PREFIXES = {"for", "select", "case", "function"}
SHELL_TERMINATORS = {"fi", "done", "esac", "}"}
REDIRECT_OPERATORS = {
    ">",
    ">>",
    ">|",
    "&>",
    ">&",
    "<>",
    "<",
    "<<",
    "<<-",
    "<<<",
}
SHELLS = {"bash", "sh", "zsh", "dash", "ksh", "mksh", "ash"}
WRAPPERS = {"sudo", "doas", "env", "busybox", "command", "builtin"}
SUDO_FLAGS_WITH_ARG = {"-u", "-g", "-U", "-C", "-h", "-T", "-D", "-p", "-r", "-t"}
ENV_FLAGS_WITH_ARG = {"-u", "--unset", "-C", "--chdir"}
FORWARDERS = {
    "xargs",
    "parallel",
    "nice",
    "time",
    "timeout",
    "nohup",
    "stdbuf",
    "setsid",
    "ionice",
    "flock",
    "taskset",
    "chrt",
}
TRANSPARENT_FORWARDERS = {"nice", "time", "nohup", "stdbuf", "setsid", "ionice", "taskset", "chrt"}
FORWARDER_OPTIONS_WITH_ARG = {
    "nice": {"-n", "--adjustment"},
    "time": {"-f", "--format", "-o", "--output"},
    "nohup": set(),
    "stdbuf": {"-i", "--input", "-o", "--output", "-e", "--error"},
    "setsid": set(),
    "ionice": {"-c", "--class", "-n", "--classdata"},
    "taskset": {"-c", "--cpu-list"},
    "chrt": set(),
}
INTERACTIVE = {"htop", "watch", "less", "more", "vi", "vim", "nano", "tmux", "screen", "iotop"}
COUNTED_LOOP = {"vmstat", "iostat", "pidstat", "mpstat", "sar", "jstat"}
DEFERRED_EXEC = {"eval", "source", "."}
# Bash builtins are command heads, but are not external programs.  Keeping
# these in the known set prevents the lightweight lexer from treating normal
# loop/condition plumbing as an unknown executable.
SHELL_BUILTINS = {
    "alias",
    "bg",
    "bind",
    "break",
    "builtin",
    "caller",
    "command",
    "compgen",
    "complete",
    "compopt",
    "continue",
    "declare",
    "dirs",
    "disown",
    "enable",
    "eval",
    "exec",
    "exit",
    "export",
    "fc",
    "fg",
    "getopts",
    "hash",
    "help",
    "history",
    "jobs",
    "let",
    "local",
    "logout",
    "mapfile",
    "popd",
    "pushd",
    "read",
    "readarray",
    "readonly",
    "return",
    "set",
    "shift",
    "shopt",
    "source",
    "suspend",
    "times",
    "trap",
    "type",
    "typeset",
    "ulimit",
    "umask",
    "unalias",
    "unset",
    "wait",
}
INTERPRETERS = {"python", "python2", "python3", "perl", "ruby", "node", "nodejs", "lua", "php"}
# Inline-code-execution flags per interpreter. These run code supplied on the
# command line (like `sh -c`) rather than from a file. Kept per-interpreter on
# purpose to avoid false positives: ruby's -E is an encoding flag (not eval), and
# node's --port must never be caught by a naive `-p` prefix match.
INTERPRETER_EVAL_FLAGS = {
    "python": ("-c",),
    "python2": ("-c",),
    "python3": ("-c",),
    "perl": ("-e", "-E"),
    "ruby": ("-e",),
    "node": ("-e", "-p", "--eval", "--print"),
    "nodejs": ("-e", "-p", "--eval", "--print"),
    "lua": ("-e",),
    "php": ("-r",),
}
INTERPRETER_OPTIONS_WITH_ARG = {
    "python": {"-W", "-X", "-m", "--check-hash-based-pycs"},
    "python2": {"-W", "-X", "-m", "--check-hash-based-pycs"},
    "python3": {"-W", "-X", "-m", "--check-hash-based-pycs"},
    "perl": {"-I", "-M", "-m", "-C", "-0", "-F", "-i"},
    "ruby": {"-C", "-E", "-I", "-r", "-W"},
    "node": {
        "-r",
        "--conditions",
        "--env-file",
        "--experimental-loader",
        "--import",
        "--inspect",
        "--inspect-brk",
        "--inspect-port",
        "--loader",
        "--port",
        "--require",
        "--title",
    },
    "nodejs": {
        "-r",
        "--conditions",
        "--env-file",
        "--experimental-loader",
        "--import",
        "--inspect",
        "--inspect-brk",
        "--inspect-port",
        "--loader",
        "--port",
        "--require",
        "--title",
    },
    "lua": {"-l"},
    "php": {"-c", "-d", "-f", "-z", "--define", "--php-ini", "--zend-extension"},
}
INTERPRETER_SHORT_OPTIONS_WITH_ARG = {
    "python": {"W", "X", "m"},
    "python2": {"W", "X", "m"},
    "python3": {"W", "X", "m"},
    "perl": {"I", "M", "m", "C", "0", "F", "i"},
    "ruby": {"C", "E", "I", "r", "W"},
    "node": {"r"},
    "nodejs": {"r"},
    "lua": {"l"},
    "php": {"c", "d", "f", "z"},
}
HELP_FLAGS = {"--help", "--usage", "--version", "-?"}
DESTRUCTIVE = {
    "rm",
    "unlink",
    "dd",
    "mkfs",
    "mkfs.ext2",
    "mkfs.ext3",
    "mkfs.ext4",
    "mkfs.xfs",
    "iptables",
    "ip6tables",
    "shutdown",
    "reboot",
    "halt",
    "poweroff",
    "kill",
    "pkill",
    "killall",
    "mount",
    "umount",
    "exec",
}
WRITE_VERBS = {
    "tee",
    "cp",
    "mv",
    "ln",
    "install",
    "truncate",
    "ed",
    "patch",
    "tar",
    "unzip",
    "cpio",
    "mkdir",
    "rmdir",
    "touch",
    "rsync",
    "scp",
}
PERMISSION_VERBS = {"chmod", "chown", "chgrp", "setfacl", "setcap"}
FILE_MUTATION_COMMANDS = {"rm", "unlink", "dd", "mount", "umount"}
ALIASES = {
    "gsed": "sed",
    "gcp": "cp",
    "gmv": "mv",
    "gln": "ln",
    "gtar": "tar",
    "gtruncate": "truncate",
    "gtee": "tee",
    "ginstall": "install",
    "grm": "rm",
    "gxargs": "xargs",
    "gchmod": "chmod",
    "gchown": "chown",
    "gchgrp": "chgrp",
    "gtouch": "touch",
    "gtail": "tail",
    "gtimeout": "timeout",
    "gnice": "nice",
    "gnohup": "nohup",
    "gstdbuf": "stdbuf",
    "gtime": "time",
    "gawk": "awk",
    "mawk": "awk",
    "nawk": "awk",
    "nvim": "vi",
    "neovim": "vi",
    "view": "vi",
    "vimdiff": "vi",
}

# Commands which the AST guard understands as ordinary, non-wrapper command
# heads.  A command outside this set is not necessarily unsafe, but it must
# never be silently auto-approved: callers receive an approval finding (or a
# hard block for a dynamic head) and can make the decision with context.
KNOWN_COMMANDS = {
    "[",
    "awk",
    "basename",
    "bash",
    "cat",
    "cd",
    "chmod",
    "chown",
    "chgrp",
    "cp",
    "cut",
    "date",
    "df",
    "diff",
    "dirname",
    "du",
    "echo",
    "env",
    "false",
    "find",
    "free",
    "findmnt",
    "getent",
    "getconf",
    "grep",
    "head",
    "hostname",
    "id",
    "install",
    "ip",
    "journalctl",
    "jq",
    "kill",
    "killall",
    "less",
    "ln",
    "ls",
    "lsof",
    "mkdir",
    "mktemp",
    "mount",
    "mv",
    "netstat",
    "nproc",
    "od",
    "paste",
    "perl",
    "pgrep",
    "printf",
    "ps",
    "pwd",
    "readlink",
    "realpath",
    "rm",
    "rmdir",
    "rsync",
    "sed",
    "seq",
    "set",
    "sha256sum",
    "sh",
    "sleep",
    "sort",
    "stat",
    "ss",
    "systemctl",
    "tail",
    "tar",
    "tee",
    "test",
    "timeout",
    "top",
    "touch",
    "tr",
    "true",
    "uname",
    "uniq",
    "unzip",
    "uptime",
    "wc",
    "wget",
    "which",
    "xargs",
    "zcat",
    "zsh",
} | SHELLS | WRAPPERS | FORWARDERS | INTERPRETERS | DESTRUCTIVE | WRITE_VERBS | PERMISSION_VERBS | SHELL_BUILTINS
SERVICE_ACTIONS = {"restart", "stop", "disable"}
PROTECTED_SERVICES = {
    "sshd",
    "systemd",
    "containerd",
    "docker",
    "kubelet",
    "mysqld",
    "mysql",
    "mariadb",
    "postgresql",
}
XARGS_FLAGS_WITH_ARG = {
    "-a",
    "--arg-file",
    "-d",
    "--delimiter",
    "-E",
    "-e",
    "-I",
    "-i",
    "-L",
    "-l",
    "-n",
    "-P",
    "-s",
    "--eof",
    "--max-args",
    "--max-chars",
    "--max-lines",
    "--max-procs",
    "--replace",
}


@dataclass
class CommandNode:
    head: str
    argv: list[str]
    tokens: list[str]
    pipeline_id: int
    wrapper_chain: list[str]


@dataclass
class HeredocNode:
    """One parsed here-document and the command redirect that consumes it."""

    delimiter: str
    quoted: bool
    strip_tabs: bool
    body: str
    declaration: str
    command: CommandNode | None = None
    error: str = ""


def finding(
    severity: str,
    code: str,
    message: str,
    *,
    category: str,
    action: str | None = None,
    command_head: str | None = None,
    node: str | None = None,
    text: str | None = None,
    source: str = "ast",
) -> dict:
    return {
        "severity": severity,
        "code": code,
        "message": message,
        "source": source,
        "category": category,
        "action": action or ("block" if severity == "critical" else "approve"),
        **({"command_head": command_head} if command_head else {}),
        **({"node": node} if node else {}),
        **({"text": text[:500]} if text else {}),
    }


def file_mutation_requires_skill(
    *,
    command_head: str | None = None,
    node: str | None = None,
    text: str | None = None,
) -> dict:
    return finding(
        "critical",
        "AST_FILE_MUTATION_REQUIRES_SKILL",
        "File modifications must use a registered controlled skill instead of free-form shell.",
        category="controlled_file_modification",
        command_head=command_head,
        node=node,
        text=text,
    )


def canonical(head: str) -> str:
    base = PurePosixPath(head).name if "/" in head else head
    return ALIASES.get(base, base)


def is_assignment(token: str) -> bool:
    return re.match(r"^[A-Za-z_][A-Za-z0-9_]*\+?=", token) is not None


FUNCTION_DECLARATION = re.compile(
    r"(?m)(^|[;\n][ \t]*)(?:function[ \t]+)?"
    r"([A-Za-z_][A-Za-z0-9_]*)[ \t]*(?:\([ \t]*\))?[ \t]*\{"
)


def shell_function_names(text: str) -> set[str]:
    """Return statically declared Bash function names."""

    return {match.group(2) for match in FUNCTION_DECLARATION.finditer(text)}


def strip_function_declaration_headers(text: str) -> str:
    """Keep function bodies visible while removing non-command headers."""

    return FUNCTION_DECLARATION.sub(lambda match: f"{match.group(1)}{{", text)


def is_dynamic_command_head(token: str) -> bool:
    """Return whether a command head depends on shell runtime expansion."""

    return (
        not token
        or "__SUBSTITUTION__" in token
        or "__PROCESS_SUBSTITUTION__" in token
        or "__ARITHMETIC__" in token
        or "$" in token
        or token.startswith("<(")
        or token.startswith(">(")
    )


def dynamic_command_head_findings(text: str) -> list[dict]:
    """Find runtime-expanded command heads at unambiguous shell boundaries.

    The lightweight shlex AST cannot model Bash ``if``/``[[``/``case`` syntax,
    so command-node inspection produces false positives for whole Skill files.
    This scanner intentionally recognizes only explicit command boundaries and
    optional assignments/wrappers before the expanded head.
    """

    segments: list[str] = []
    current: list[str] = []
    quote = ""
    escaped = False
    conditional_depth = 0
    substitution_depth = 0
    index = 0
    while index < len(text):
        char = text[index]
        pair = text[index : index + 2]
        if escaped:
            current.append(char)
            escaped = False
            index += 1
            continue
        if char == "\\" and quote != "'":
            current.append(char)
            escaped = True
            index += 1
            continue
        if pair == "$(":
            current.extend(pair)
            substitution_depth += 1
            index += 2
            continue
        if char == ")" and substitution_depth:
            current.append(char)
            substitution_depth -= 1
            index += 1
            continue
        if quote:
            current.append(char)
            if char == quote:
                quote = ""
            index += 1
            continue
        if char in {"'", '"', "`"}:
            quote = char
            current.append(char)
            index += 1
            continue
        if pair == "[[":
            conditional_depth += 1
            current.extend(pair)
            index += 2
            continue
        if pair == "]]" and conditional_depth:
            conditional_depth -= 1
            current.extend(pair)
            index += 2
            continue
        if conditional_depth == 0 and substitution_depth == 0 and (
            char in {"\n", ";"} or pair in {"&&", "||"} or char == "|"
        ):
            segments.append("".join(current))
            current = []
            index += 2 if pair in {"&&", "||"} else 1
            continue
        current.append(char)
        index += 1
    segments.append("".join(current))

    results = []
    control_words = {"for", "case", "select", "function"}
    prefix_words = {"then", "do", "else", "!", "{"}
    for raw_segment in segments:
        segment = raw_segment.strip()
        if not segment or segment.startswith("#"):
            continue
        # A case pattern is data, not an executable command head.
        if segment.endswith(")") and not segment.startswith("$("):
            continue
        normalized, _substitution_findings, _fragments = strip_and_collect_substitutions(
            segment, 2
        )
        try:
            tokens = shlex.split(normalized, comments=False, posix=True)
        except ValueError:
            continue
        if not tokens:
            continue
        while tokens and tokens[0] in prefix_words:
            tokens.pop(0)
        # ``if``/``elif``/``while``/``until`` introduce an executable test
        # command.  They are command boundaries for this scanner, not inert
        # control words: a runtime-expanded command in that position must be
        # blocked just like one after a semicolon.  Declarations and case
        # syntax still require the specialised parser and are skipped here.
        if tokens and tokens[0] in {"if", "elif", "while", "until"}:
            tokens.pop(0)
            while tokens and tokens[0] in prefix_words:
                tokens.pop(0)
        if not tokens or tokens[0] in control_words or tokens[0] in {"[[", "((", "fi", "done", "esac", "}"}:
            continue
        while tokens and is_assignment(tokens[0]):
            tokens.pop(0)
        while tokens and canonical(tokens[0]) in WRAPPERS:
            wrapper_head = canonical(tokens.pop(0))
            if wrapper_head == "env":
                while tokens and (tokens[0].startswith("-") or is_assignment(tokens[0])):
                    tokens.pop(0)
            else:
                while tokens and tokens[0].startswith("-"):
                    tokens.pop(0)
        if not tokens:
            continue
        head = tokens[0]
        if is_dynamic_command_head(head):
            results.append(
                finding(
                    "critical",
                    "AST_DYNAMIC_COMMAND_HEAD",
                    "命令头依赖变量或命令替换，无法安全确定实际执行程序。",
                    category="dynamic_execution",
                    node="command_head",
                    text=segment[:500],
                )
            )
    return results


def is_number(token: str) -> bool:
    return re.match(r"^[0-9]+$", token) is not None


def is_fd_dup_destination(token: str) -> bool:
    return is_number(token) or token in {"-", "&1", "&2"}


def normalize_shell_spacing_markers(text: str) -> tuple[str, bool]:
    normalized = re.sub(r"\$\{IFS[^}]*\}|\$IFS\b", " ", text)
    return normalized, normalized != text


MAX_HEREDOC_BODY_BYTES = 1_048_576
MAX_ANALYSIS_INPUT_BYTES = 4_194_304


def _heredoc_declarations(line: str) -> list[tuple[str, bool, bool]]:
    """Return delimiter, quote state and tab-stripping for redirects on a line.

    This is intentionally a small lexical pass rather than a regular
    expression.  It ignores redirect-looking text inside quotes and comments,
    accepts mixed quoted delimiter words, and leaves unsupported/dynamic forms
    to the fail-closed validation in :func:`extract_heredocs`.
    """

    declarations: list[tuple[str, bool, bool]] = []
    quote = ""
    escaped = False
    index = 0
    while index < len(line):
        char = line[index]
        if escaped:
            escaped = False
            index += 1
            continue
        if char == "\\" and quote != "'":
            escaped = True
            index += 1
            continue
        if quote:
            if char == quote:
                quote = ""
            index += 1
            continue
        if char in {"'", '"'}:
            quote = char
            index += 1
            continue
        if char == "#" and (index == 0 or line[index - 1].isspace()):
            break
        if line.startswith("<<<", index):
            index += 3
            continue
        if index > 0 and line[index - 1] == "<":
            index += 1
            continue
        if not line.startswith("<<", index):
            index += 1
            continue

        cursor = index + 2
        strip_tabs = False
        if cursor < len(line) and line[cursor] == "-":
            strip_tabs = True
            cursor += 1
        while cursor < len(line) and line[cursor] in " \t":
            cursor += 1
        raw: list[str] = []
        word_quote = ""
        word_escaped = False
        quoted = False
        while cursor < len(line):
            current = line[cursor]
            if word_escaped:
                raw.append(current)
                word_escaped = False
                quoted = True
                cursor += 1
                continue
            if current == "\\" and word_quote != "'":
                word_escaped = True
                quoted = True
                cursor += 1
                continue
            if word_quote:
                if current == word_quote:
                    word_quote = ""
                    quoted = True
                else:
                    raw.append(current)
                cursor += 1
                continue
            if current in {"'", '"'}:
                word_quote = current
                quoted = True
                cursor += 1
                continue
            if current.isspace() or current in ";|&()<>":
                break
            raw.append(current)
            cursor += 1
        delimiter = "".join(raw)
        if word_quote or word_escaped:
            delimiter = ""
        declarations.append((delimiter, quoted, strip_tabs))
        index = max(cursor, index + 2)
    return declarations


def extract_heredocs(text: str) -> tuple[str, list[HeredocNode]]:
    """Mask data lines while retaining executable heredoc semantics."""

    lines = text.splitlines(keepends=True)
    output: list[str] = []
    nodes: list[HeredocNode] = []
    pending: list[HeredocNode] = []
    body_parts: list[str] = []
    body_bytes = 0

    for line in lines:
        if pending:
            node = pending[0]
            candidate = line.rstrip("\r\n")
            if node.strip_tabs:
                candidate = candidate.lstrip("\t")
            if candidate == node.delimiter:
                node.body = "".join(body_parts)
                pending.pop(0)
                body_parts = []
                body_bytes = 0
            else:
                body_bytes += len(line.encode("utf-8", errors="replace"))
                if body_bytes <= MAX_HEREDOC_BODY_BYTES:
                    body_parts.append(line.lstrip("\t") if node.strip_tabs else line)
                elif not node.error:
                    node.error = "here-document body exceeds the analysis byte limit"
                    body_parts = []
            output.append("\n" if line.endswith(("\n", "\r")) else "")
            continue

        declarations = _heredoc_declarations(line)
        output.append(line)
        for delimiter, quoted, strip_tabs in declarations:
            node = HeredocNode(
                delimiter=delimiter,
                quoted=quoted,
                strip_tabs=strip_tabs,
                body="",
                declaration=line.strip(),
            )
            if not delimiter or len(delimiter.encode("utf-8", errors="replace")) > 256:
                node.error = "here-document delimiter is missing or unsupported"
            nodes.append(node)
            pending.append(node)

    if pending:
        pending[0].body = "".join(body_parts)
        for node in pending:
            if not node.error:
                node.error = "here-document delimiter was not found"
    return "".join(output), nodes


def _redirect_heredoc_count(tokens: Iterable[str]) -> int:
    values = list(tokens)
    count = 0
    for index, token in enumerate(values):
        if token in {"<<", "<<-"}:
            count += 1
        elif token.isdigit() and index + 1 < len(values) and values[index + 1] in {"<<", "<<-"}:
            # The following redirect token is counted in its own iteration.
            continue
    return count


def _uses_stdin_as_program(head: str, argv: Iterable[str]) -> bool:
    args = list(argv)
    if head in SHELLS and any(
        token == "--command"
        or (token.startswith("-") and not token.startswith("--") and "c" in token[1:])
        for token in args
    ):
        return False
    if head in INTERPRETERS and interpreter_inline_exec(head, args):
        return False

    options_with_arg = INTERPRETER_OPTIONS_WITH_ARG.get(head, set())
    index = 0
    while index < len(args):
        token = args[index]
        if token == "--":
            index += 1
            break
        if token == "-":
            return True
        if not token.startswith("-"):
            return False
        if head in SHELLS and token in {"-O", "+O", "--rcfile", "--init-file"}:
            index += 2
            continue
        if option_takes_value(token, options_with_arg):
            index += 1 if token.startswith("--") and "=" in token else 2
            continue
        index += 1
    return index >= len(args) or (index < len(args) and args[index] == "-")


def executable_policy_text(text: str, depth: int = 0) -> str:
    """Return only text whose shell/interpreter semantics can execute it.

    Regex and file-vault policies consume this projection so quoted data
    heredocs do not become false commands, while shell stdin and unquoted
    expansion fragments remain visible to those policy layers.
    """

    if depth >= 3:
        return text
    shell_text, heredocs = extract_heredocs(text)
    if any(node.error for node in heredocs):
        return text
    normalized, _substitution_findings, _fragments = strip_and_collect_substitutions(
        shell_text, depth
    )
    tokens, token_error = tokenize(strip_function_declaration_headers(normalized))
    if token_error:
        return text
    commands = split_commands(tokens, [])
    heredoc_index = 0
    for command in commands:
        for _unused in range(_redirect_heredoc_count(command.tokens)):
            if heredoc_index >= len(heredocs):
                return text
            heredocs[heredoc_index].command = command
            heredoc_index += 1
    if heredoc_index != len(heredocs):
        return text

    executable = [shell_text]
    for node in heredocs:
        if not node.quoted:
            _cleaned, _findings, fragments = strip_and_collect_substitutions(
                node.body, depth
            )
            executable.extend(
                executable_policy_text(fragment, depth + 1) for fragment in fragments
            )
        if node.command is None or not _uses_stdin_as_program(
            node.command.head, node.command.argv
        ):
            continue
        if node.command.head in SHELLS:
            executable.append(executable_policy_text(node.body, depth + 1))
        elif node.command.head in INTERPRETERS:
            executable.append(node.body)
    return "\n".join(executable)


def protected_path(value: str) -> bool:
    if not value:
        return False
    path = value.strip("'\"")
    if path in {"/", "~/.ssh"}:
        return True
    if path.startswith("/etc/") or path == "/etc":
        return True
    if path.startswith("/boot/") or path == "/boot":
        return True
    if path.startswith("/usr/") or path == "/usr":
        return True
    if path.startswith("/var/lib/") or path == "/var/lib":
        return True
    if path.startswith("/root/") or path == "/root":
        return True
    if re.match(r"^/home/[^/]+/\.ssh(/|$)", path):
        return True
    return False


def tokenize(text: str) -> tuple[list[str], str | None]:
    # Newlines are converted to explicit separators below, so shlex's comment
    # mode would let a shebang/comment consume the rest of the script. Remove
    # whole-line shell comments first and keep inline ``#`` characters as argv.
    text = re.sub(r"(?m)^[ \t]*#.*(?:\n|$)", "\n", text)
    text = preserve_command_newlines(text)
    try:
        lexer = shlex.shlex(text, posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        lexer.commenters = ""
        return list(lexer), None
    except ValueError as exc:
        return [], str(exc)


def preserve_command_newlines(text: str) -> str:
    """Turn shell command newlines into separators before ``shlex`` runs.

    ``shlex`` treats every newline as ordinary whitespace, which can fold a
    later command into the preceding command's argv.  Keep newlines inside
    quotes and escaped line continuations intact, and ignore a newline after a
    list/pipeline operator because the following line is still the same shell
    command list.
    """

    output: list[str] = []
    quote = ""
    segment_has_content = False
    index = 0
    while index < len(text):
        char = text[index]
        pair = text[index : index + 2]

        if char == "\\" and quote != "'":
            if index + 1 < len(text) and text[index + 1] == "\n":
                output.append(" ")
                index += 2
                continue
            output.append(char)
            if index + 1 < len(text):
                output.append(text[index + 1])
                segment_has_content = True
                index += 2
            else:
                index += 1
            continue

        if quote:
            output.append(char)
            if char == quote:
                quote = ""
            index += 1
            continue

        if char in {"'", '"', "`"}:
            quote = char
            output.append(char)
            segment_has_content = True
            index += 1
            continue

        if char == "\n":
            output.append(" ; " if segment_has_content else " ")
            segment_has_content = False
            index += 1
            continue

        if pair in {"&&", "||", "|&"}:
            output.extend(pair)
            segment_has_content = False
            index += 2
            continue
        if char in {";", "|", "&"} and pair != "&>":
            output.append(char)
            segment_has_content = False
            index += 1
            continue

        output.append(char)
        if not char.isspace():
            segment_has_content = True
        index += 1

    return "".join(output)


def matching_paren(text: str, start: int) -> int:
    depth = 0
    quote = ""
    escape = False
    for idx in range(start, len(text)):
        ch = text[idx]
        if escape:
            escape = False
            continue
        if ch == "\\":
            escape = True
            continue
        if quote:
            if ch == quote:
                quote = ""
            continue
        if ch in {"'", '"'}:
            quote = ch
            continue
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return idx
    return -1


def strip_and_collect_substitutions(text: str, depth: int) -> tuple[str, list[dict], list[str]]:
    findings: list[dict] = []
    fragments: list[str] = []
    out: list[str] = []
    i = 0
    while i < len(text):
        if text.startswith("$((", i):
            end = text.find("))", i + 3)
            out.append("__ARITHMETIC__")
            i = (end + 2) if end != -1 else len(text)
            continue
        if text.startswith("$(", i) or text.startswith("<(", i) or text.startswith(">(", i):
            kind = "command_substitution" if text.startswith("$(", i) else "process_substitution"
            open_idx = i + 1
            end = matching_paren(text, open_idx)
            if end == -1:
                findings.append(
                    finding(
                        "high",
                        "AST_SUBSTITUTION_PARSE_FAILED",
                        "Shell substitution is not balanced and requires review.",
                        category="substitution",
                        node=kind,
                        text=text[i:],
                    )
                )
                out.append("__SUBSTITUTION__")
                break
            inner = text[open_idx + 1 : end]
            code = "AST_COMMAND_SUBSTITUTION" if kind == "command_substitution" else "AST_PROCESS_SUBSTITUTION"
            findings.append(
                finding(
                    "high",
                    code,
                    "Command contains shell substitution; review hidden execution flow.",
                    category="substitution",
                    node=kind,
                    text=inner,
                )
            )
            if depth < 2:
                fragments.append(inner)
            out.append("__SUBSTITUTION__")
            i = end + 1
            continue
        if text[i] == "`":
            j = text.find("`", i + 1)
            body = text[i + 1 : j] if j != -1 else text[i + 1 :]
            findings.append(
                finding(
                    "high",
                    "AST_COMMAND_SUBSTITUTION",
                    "Command contains backtick substitution; review hidden execution flow.",
                    category="substitution",
                    node="backtick",
                    text=body,
                )
            )
            if depth < 2 and body:
                fragments.append(body)
            out.append("__SUBSTITUTION__")
            i = (j + 1) if j != -1 else len(text)
            continue
        out.append(text[i])
        i += 1
    return "".join(out), findings, fragments


def command_without_redirects(tokens: list[str], findings: list[dict]) -> list[str]:
    args: list[str] = []
    i = 0
    while i < len(tokens):
        tok = tokens[i]
        op = ""
        dest = ""
        consumed = 0

        if tok in REDIRECT_OPERATORS:
            op = tok
            dest = tokens[i + 1] if i + 1 < len(tokens) else ""
            consumed = 2
        elif is_number(tok) and i + 1 < len(tokens) and tokens[i + 1] in REDIRECT_OPERATORS:
            op = tokens[i + 1]
            dest = tokens[i + 2] if i + 2 < len(tokens) else ""
            consumed = 3
        elif re.match(r"^[0-9]*>{1,2}.+", tok):
            op = ">"
            dest = re.sub(r"^[0-9]*>{1,2}", "", tok)
            consumed = 1

        if op:
            if op in {"<<", "<<-", "<<<"}:
                findings.append(
                    finding(
                        "high",
                        "AST_HEREDOC",
                        "Command contains here-doc or here-string; review embedded input and side effects.",
                        category="substitution",
                        node="redirect",
                        text=" ".join(tokens),
                    )
                )
            if ">" in op:
                if not dest:
                    findings.append(
                        finding(
                            "high",
                            "AST_REDIRECT_DYNAMIC",
                            "Output redirect has no static destination.",
                            category="write",
                            node="redirect",
                            text=" ".join(tokens),
                        )
                    )
                elif dest == "/dev/null" or is_fd_dup_destination(dest):
                    pass
                elif protected_path(dest):
                    findings.append(
                        finding(
                            "critical",
                            "AST_PROTECTED_REDIRECT",
                            "Command writes to a protected path.",
                            category="protected_path",
                            node="redirect",
                            text=dest,
                        )
                    )
                else:
                    findings.append(file_mutation_requires_skill(node="redirect", text=dest))
            i += max(consumed, 1)
            continue

        args.append(tok)
        i += 1
    return args


def split_commands(tokens: list[str], findings: list[dict]) -> list[CommandNode]:
    commands: list[CommandNode] = []
    current: list[str] = []
    pipeline_id = 0
    compound_state = ""
    case_phases: list[str] = []

    def flush() -> None:
        nonlocal current
        if not current:
            return
        args = command_without_redirects(current, findings)
        head_index = 0
        while head_index < len(args) and is_assignment(args[head_index]):
            head_index += 1
        if head_index >= len(args):
            current = []
            return

        raw_syntax_head = args[head_index]
        if raw_syntax_head in SHELL_DECLARATION_PREFIXES:
            current = []
            return
        if raw_syntax_head in SHELL_TERMINATORS or raw_syntax_head in {"[[", "(("}:
            current = []
            return
        if raw_syntax_head in SHELL_CONDITION_PREFIXES | SHELL_BODY_PREFIXES:
            head_index += 1
            while head_index < len(args) and args[head_index] in SHELL_BODY_PREFIXES:
                head_index += 1
            while head_index < len(args) and is_assignment(args[head_index]):
                head_index += 1
            if head_index >= len(args):
                current = []
                return
        raw_head = args[head_index]
        argv = args[head_index + 1 :]
        head, argv, wrappers = strip_wrappers(raw_head, argv, findings)
        if head:
            commands.append(CommandNode(head=canonical(head), argv=argv, tokens=current[:], pipeline_id=pipeline_id, wrapper_chain=wrappers))
        current = []

    for tok in tokens:
        # ``shlex`` exposes Bash compound syntax as punctuation, so keep
        # condition and arithmetic expressions out of the command stream.  A
        # condition can contain ``||`` and regex alternation without creating
        # new executable command heads.
        if compound_state:
            if compound_state == "[[" and tok == "]]":
                compound_state = ""
            elif compound_state == "((" and (tok == "))" or tok.endswith("));")):
                compound_state = ""
            continue
        if tok in {"[[", "(("}:
            current = []
            compound_state = tok
            continue

        # Case labels are data, while commands between a label's ``)`` and
        # ``;;`` remain executable and must still be inspected.
        if case_phases:
            phase = case_phases[-1]
            if phase == "header":
                if tok == "in":
                    case_phases[-1] = "pattern"
                continue
            if phase == "pattern":
                if tok == ")":
                    case_phases[-1] = "body"
                continue
            if tok in {";;", ";&", ";;&"}:
                flush()
                case_phases[-1] = "pattern"
                continue
            if tok == "esac":
                flush()
                case_phases.pop()
                continue
            if tok == "case" and not current:
                case_phases.append("header")
                continue

        if tok == "case" and (not current or all(item in SHELL_BODY_PREFIXES for item in current)):
            current = []
            case_phases.append("header")
            continue
        if tok in PIPE_OPERATORS:
            flush()
            continue
        if tok in SEPARATORS:
            flush()
            pipeline_id += 1
            continue
        if tok in {"(", ")"}:
            continue
        current.append(tok)
    flush()
    return commands


def strip_wrappers(raw_head: str, argv: list[str], findings: list[dict]) -> tuple[str, list[str], list[str]]:
    head = canonical(raw_head)
    args = argv[:]
    wrappers: list[str] = []
    while head in WRAPPERS and args:
        # `command` and `builtin` are execution wrappers, not opaque commands.
        # Keep command lookup (`command -v/-V`) as a read-only query, but unwrap
        # every execution form so the real command receives the normal rules.
        if head == "command" and any(t in {"-v", "-V"} for t in args):
            break
        wrappers.append(head)
        if head in {"sudo", "doas"}:
            findings.append(
                finding(
                    "high",
                    "AST_PRIVILEGE_ESCALATION",
                    "Command requests privilege escalation.",
                    category="privilege",
                    command_head=head,
                )
            )
        i = 0
        while i < len(args):
            t = args[i]
            if head == "env" and (t.startswith("-S") or t == "--split-string" or t.startswith("--split-string=")):
                findings.append(
                    finding(
                        "high",
                        "AST_DEFERRED_EXEC",
                        "env -S hides another command line from the guard.",
                        category="wrapper",
                        command_head=head,
                        text=" ".join(args),
                    )
                )
                return head, args, wrappers
            if t.startswith("-"):
                if t == "--":
                    i += 1
                    break
                i += 1
                if head in {"sudo", "doas"} and t in SUDO_FLAGS_WITH_ARG and i < len(args):
                    i += 1
                elif head == "env" and t in ENV_FLAGS_WITH_ARG and i < len(args):
                    i += 1
                continue
            if head == "env" and "=" in t:
                i += 1
                continue
            break
        if i >= len(args):
            break
        head = canonical(args[i])
        args = args[i + 1 :]
    return head, args, wrappers


def has_recursive_flag(argv: Iterable[str]) -> bool:
    return any(t == "--recursive" or t.startswith("-R") for t in argv)


def target_paths(argv: Iterable[str]) -> list[str]:
    out = []
    for t in argv:
        if not t.startswith("-") and "=" not in t:
            out.append(t)
    return out


def archive_write_targets(argv: list[str]) -> list[str]:
    """Return tar paths that can receive writes.

    ``tar`` mixes archive names, source members, and ``-C`` directories in
    one argv.  Treating every non-option token as a write target makes a
    normal backup such as ``tar -czf archive -C / etc`` look like a write to
    ``/``.  Only the archive file is a destination for create/update modes;
    extraction mode writes below an explicit ``-C`` directory.
    """

    operation = ""
    archive: list[str] = []
    directories: list[str] = []
    index = 0
    while index < len(argv):
        token = argv[index]
        if token in {"--create", "--append", "--update", "--concatenate"}:
            operation = "write_archive"
        elif token in {"--extract", "--get"}:
            operation = "extract"
        elif token in {"--list", "--diff"}:
            operation = "read_archive"
        elif token in {"--file", "--directory"}:
            if index + 1 < len(argv):
                value = argv[index + 1]
                if token == "--file":
                    archive.append(value)
                else:
                    directories.append(value)
                index += 1
        elif token.startswith("--file="):
            archive.append(token.split("=", 1)[1])
        elif token.startswith("--directory="):
            directories.append(token.split("=", 1)[1])
        elif token.startswith("-") and token != "-":
            flags = token[1:]
            if "x" in flags:
                operation = "extract"
            elif any(flag in flags for flag in "cruA"):
                operation = "write_archive"
            elif "t" in flags:
                operation = "read_archive"
            if "f" in flags:
                suffix = flags.split("f", 1)[1]
                if suffix:
                    archive.append(suffix)
                elif index + 1 < len(argv):
                    archive.append(argv[index + 1])
                    index += 1
            if "C" in flags:
                suffix = flags.split("C", 1)[1]
                if suffix:
                    directories.append(suffix)
                elif index + 1 < len(argv):
                    directories.append(argv[index + 1])
                    index += 1
        index += 1

    if operation == "extract":
        return directories
    if operation == "write_archive":
        return archive
    return []


def mutation_target_paths(head: str, argv: list[str]) -> list[str]:
    if head == "tar":
        return archive_write_targets(argv)
    return target_paths(argv)


def has_protected_target(argv: Iterable[str], head: str | None = None) -> bool:
    values = list(argv)
    paths = mutation_target_paths(head, values) if head else target_paths(values)
    return any(protected_path(t) for t in paths)


def archive_command_is_readonly(head: str, argv: list[str]) -> bool:
    if head == "tar":
        for arg in argv:
            if arg == "--list":
                return True
            if arg.startswith("-") and "t" in arg and not any(flag in arg for flag in "xcruA"):
                return True
        return False
    if head == "unzip":
        return any(arg in {"-l", "-Z"} or arg.startswith("-l") for arg in argv)
    if head == "cpio":
        return any(arg == "-t" or (arg.startswith("-") and "t" in arg and "i" not in arg and "o" not in arg) for arg in argv)
    return False


def rsync_is_dry_run(argv: list[str]) -> bool:
    for arg in argv:
        if arg == "--dry-run":
            return True
        if arg.startswith("-") and not arg.startswith("--") and "n" in arg:
            return True
    return False


def add_file_write_finding(findings: list[dict], head: str, argv: list[str], text: str) -> None:
    severity = "critical" if has_protected_target(argv, head) else "high"
    if severity == "critical" and head == "tee":
        code = "AST_PROTECTED_REDIRECT"
    elif severity == "critical":
        code = "AST_PROTECTED_WRITE"
    else:
        code = "AST_FILE_MUTATION_REQUIRES_SKILL"
    findings.append(
        finding(
            "critical" if code == "AST_FILE_MUTATION_REQUIRES_SKILL" else severity,
            code,
            "File modifications must use a registered controlled skill instead of free-form shell."
            if code == "AST_FILE_MUTATION_REQUIRES_SKILL"
            else "Command writes filesystem state.",
            category="protected_path" if severity == "critical" and code != "AST_FILE_MUTATION_REQUIRES_SKILL" else "controlled_file_modification",
            command_head=head,
            text=text,
        )
    )


def add_permission_write_finding(findings: list[dict], head: str, argv: list[str], text: str) -> None:
    severity = "critical" if has_protected_target(argv) else "high"
    code = "AST_PROTECTED_WRITE" if severity == "critical" else "AST_FILE_MUTATION_REQUIRES_SKILL"
    findings.append(
        finding(
            "critical" if code == "AST_FILE_MUTATION_REQUIRES_SKILL" else severity,
            code,
            "Permission, ownership, ACL, or capability changes must use a registered controlled skill."
            if code == "AST_FILE_MUTATION_REQUIRES_SKILL"
            else "Command changes protected file permissions or ownership.",
            category="protected_path" if severity == "critical" and code != "AST_FILE_MUTATION_REQUIRES_SKILL" else "controlled_file_modification",
            command_head=head,
            text=text,
        )
    )


def xargs_subcommand(argv: list[str]) -> tuple[str, list[str]] | None:
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--":
            i += 1
            break
        if not arg.startswith("-"):
            break
        if "=" in arg:
            i += 1
            continue
        if arg in XARGS_FLAGS_WITH_ARG and i + 1 < len(argv):
            i += 2
            continue
        i += 1
    if i >= len(argv):
        return None
    return canonical(argv[i]), argv[i + 1 :]


def timeout_subcommand(argv: list[str]) -> list[str]:
    """Return the command portion of GNU timeout arguments."""
    options_with_arg = {"-s", "--signal", "-k", "--kill-after"}
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--":
            i += 1
            break
        if arg in options_with_arg:
            i += 2
            continue
        if arg.startswith("--signal=") or arg.startswith("--kill-after="):
            i += 1
            continue
        if arg.startswith("-"):
            i += 1
            continue
        break
    if i >= len(argv):
        return []
    # The first positional operand is DURATION; the rest is COMMAND [ARG]...
    return argv[i + 1 :]


def has_curl_upload(argv: list[str]) -> bool:
    for idx, arg in enumerate(argv):
        if arg in {"-T", "--upload-file", "--data-binary", "--data-raw", "--data"} and idx + 1 < len(argv):
            return True
        if arg.startswith("--upload-file=") or arg.startswith("--data-binary=") or arg.startswith("--data-raw=") or arg.startswith("--data="):
            return True
        if arg.startswith("-T") and arg != "-T":
            return True
    return False


def has_wget_upload(argv: list[str]) -> bool:
    for idx, arg in enumerate(argv):
        if arg in {"--post-file", "--body-file"} and idx + 1 < len(argv):
            return True
        if arg.startswith("--post-file=") or arg.startswith("--body-file="):
            return True
    return False


def has_file_url(argv: list[str]) -> bool:
    return any(arg.startswith("file://") for arg in argv)


def option_takes_value(token: str, options: set[str]) -> bool:
    if token in options:
        return True
    return any(token.startswith(option + "=") for option in options if option.startswith("--"))


def short_option_takes_value(token: str, option_chars: set[str]) -> bool:
    if not token.startswith("-") or token.startswith("--") or len(token) < 2:
        return False
    return token[1] in option_chars


def short_option_has_inline_exec(head: str, token: str) -> bool:
    if not token.startswith("-") or token.startswith("--") or len(token) < 2:
        return False
    eval_chars = {flag[1] for flag in INTERPRETER_EVAL_FLAGS.get(head, ()) if len(flag) == 2 and flag.startswith("-")}
    option_chars = INTERPRETER_SHORT_OPTIONS_WITH_ARG.get(head, set())
    for char in token[1:]:
        if char in eval_chars:
            return True
        if char in option_chars:
            return False
    return False


def interpreter_inline_exec(head: str, argv: Iterable[str]) -> bool:
    """True if an interpreter evaluates code before its script argument."""
    flags = INTERPRETER_EVAL_FLAGS.get(head, ("-c",))
    options_with_arg = INTERPRETER_OPTIONS_WITH_ARG.get(head, set())
    option_chars_with_arg = INTERPRETER_SHORT_OPTIONS_WITH_ARG.get(head, set())
    args = list(argv)
    index = 0
    while index < len(args):
        token = args[index]
        if token == "--" or not token.startswith("-") or token == "-":
            break
        if any(token == flag or token.startswith(flag + "=") for flag in flags if flag.startswith("--")):
            return True
        if short_option_has_inline_exec(head, token):
            return True
        if option_takes_value(token, options_with_arg):
            index += 1 if token.startswith("--") and "=" in token else 2
            continue
        if short_option_takes_value(token, option_chars_with_arg):
            index += 1 if len(token) > 2 else 2
            continue
        index += 1
    return False


def command_requests_help(argv: Iterable[str]) -> bool:
    """True when a command requests informational output instead of doing work."""
    for token in argv:
        if token == "--":
            return False
        if token in HELP_FLAGS:
            return True
    return False


def signal_command_is_non_mutating(argv: Iterable[str]) -> bool:
    """True for signal-tool forms that only query or test a process."""
    args = list(argv)
    index = 0
    while index < len(args):
        token = args[index]
        if token == "--":
            return False
        if token in {"-0", "--signal=0", "-l", "--list", "--table"}:
            return True
        if token in {"-s", "--signal"}:
            return index + 1 < len(args) and args[index + 1] == "0"
        if token.startswith("--signal="):
            return token.split("=", 1)[1] == "0"
        if not token.startswith("-") or token == "-":
            return False
        return False
    return False


def forwarder_subcommand(head: str, argv: Iterable[str]) -> list[str]:
    """Return the wrapped command for a transparent forwarder."""
    options_with_arg = FORWARDER_OPTIONS_WITH_ARG.get(head, set())
    args = list(argv)
    if head in {"ionice", "taskset", "chrt"} and any(
        token == "-p" or token == "--pid" or token.startswith("--pid=") or token.startswith("-p")
        for token in args
    ):
        return []
    index = 0
    while index < len(args):
        token = args[index]
        if token == "--":
            index += 1
            break
        if not token.startswith("-") or token == "-":
            break
        if option_takes_value(token, options_with_arg):
            index += 1 if token.startswith("--") and "=" in token else 2
            continue
        if any(token.startswith(option) and len(token) > len(option) for option in options_with_arg if option.startswith("-")):
            index += 1
            continue
        index += 1
    if head == "chrt" and index < len(args):
        index += 1
    return args[index:]


def check_command_rules(
    cmd: CommandNode,
    findings: list[dict],
    declared_functions: set[str] | None = None,
) -> None:
    head = cmd.head
    argv = cmd.argv
    text = " ".join(cmd.tokens)

    if head not in KNOWN_COMMANDS and head not in (declared_functions or set()):
        findings.append(
            finding(
                "high",
                "AST_UNKNOWN_COMMAND",
                "命令不在静态守卫登记表中，禁止自动批准；非交互执行必须阻止。",
                category="unknown_command",
                command_head=head,
                text=text,
            )
        )

    if head in DESTRUCTIVE | WRITE_VERBS | PERMISSION_VERBS and command_requests_help(argv):
        return

    if head == "command":
        if any(t in {"-v", "-V"} for t in argv):
            return
        findings.append(
            finding(
                "high",
                "AST_COMMAND_FORWARDER",
                "command without -v/-V executes an argument as a command.",
                category="wrapper",
                command_head=head,
                text=text,
            )
        )
        return

    if head in SHELLS and any(t == "--command" or (t.startswith("-") and not t.startswith("--") and "c" in t[1:]) for t in argv):
        findings.append(
            finding(
                "high",
                "AST_WRAPPER_EXEC",
                "Shell -c executes an embedded command string.",
                category="wrapper",
                command_head=head,
                text=text,
            )
        )

    if head in DEFERRED_EXEC:
        findings.append(
            finding(
                "critical",
                "AST_WRAPPER_EXEC",
                "Deferred execution is blocked because it can hide arbitrary mutation.",
                category="wrapper",
                command_head=head,
                text=text,
            )
        )

    if head in FORWARDERS:
        forwarded = forwarder_subcommand(head, argv) if head in TRANSPARENT_FORWARDERS else []
        if not (head in TRANSPARENT_FORWARDERS and (forwarded or command_requests_help(argv))):
            findings.append(
                finding(
                    "high" if head == "timeout" else "critical",
                    "AST_COMMAND_FORWARDER",
                    "Command forwarder requires review; opaque forwarders are blocked because they can hide mutation."
                    if head == "timeout"
                    else "Opaque command forwarders are blocked because they can hide file mutation or nested execution.",
                    category="wrapper",
                    command_head=head,
                    text=text,
                )
            )

    if head in INTERPRETERS and interpreter_inline_exec(head, argv):
        findings.append(
            finding(
                "high",
                "AST_WRAPPER_EXEC",
                "Interpreter inline-eval flag executes embedded code.",
                category="wrapper",
                command_head=head,
                text=text,
            )
        )

    if head in {"reboot", "shutdown", "halt", "poweroff"} or head.startswith("mkfs"):
        findings.append(
            finding(
                "critical",
                "AST_DESTRUCTIVE_COMMAND",
                "Command can stop the host or destroy filesystems.",
                category="destructive",
                command_head=head,
                text=text,
            )
        )
    elif head in DESTRUCTIVE and not (
        head in {"kill", "pkill", "killall"} and signal_command_is_non_mutating(argv)
    ):
        severity = (
            "critical"
            if (
                head in FILE_MUTATION_COMMANDS
                or has_protected_target(argv)
                or (head == "rm" and any(t in {"/", "--no-preserve-root"} for t in argv))
            )
            else "high"
        )
        findings.append(
            finding(
                severity,
                "AST_FILE_MUTATION_REQUIRES_SKILL" if head in FILE_MUTATION_COMMANDS and not has_protected_target(argv) else "AST_DESTRUCTIVE_COMMAND",
                "File modifications must use a registered controlled skill instead of free-form shell."
                if head in FILE_MUTATION_COMMANDS and not has_protected_target(argv)
                else "Command can mutate or disrupt system state.",
                category="controlled_file_modification" if head in FILE_MUTATION_COMMANDS and not has_protected_target(argv) else ("destructive" if severity == "high" else "protected_path"),
                command_head=head,
                text=text,
            )
        )

    if head in WRITE_VERBS:
        if archive_command_is_readonly(head, argv):
            return
        if head == "rsync" and rsync_is_dry_run(argv):
            return
        add_file_write_finding(findings, head, argv, text)

    if head in PERMISSION_VERBS:
        add_permission_write_finding(findings, head, argv, text)

    if head in {"chmod", "chown"} and has_recursive_flag(argv):
        severity = "critical" if has_protected_target(argv) else "high"
        findings.append(
            finding(
                "critical",
                "AST_RECURSIVE_PERMISSION_CHANGE" if severity == "critical" else "AST_FILE_MUTATION_REQUIRES_SKILL",
                "Recursive permission or ownership changes require review."
                if severity == "critical"
                else "File modifications must use a registered controlled skill instead of free-form shell.",
                category="protected_path" if severity == "critical" else "controlled_file_modification",
                command_head=head,
                text=text,
            )
        )

    if head == "sed" and any(t == "-i" or t.startswith("-i") or t.startswith("--in-place") for t in argv):
        severity = "critical" if has_protected_target(argv) else "high"
        findings.append(
            finding(
                "critical",
                "AST_IN_PLACE_EDIT" if severity == "critical" else "AST_FILE_MUTATION_REQUIRES_SKILL",
                "sed in-place editing writes files."
                if severity == "critical"
                else "File modifications must use a registered controlled skill instead of free-form shell.",
                category="protected_path" if severity == "critical" else "controlled_file_modification",
                command_head=head,
                text=text,
            )
        )

    if head == "awk":
        for idx, arg in enumerate(argv[:-1]):
            if arg == "-i" and argv[idx + 1] == "inplace":
                findings.append(
                    file_mutation_requires_skill(command_head=head, text=text)
                )

    if head == "find" and any(t in {"-exec", "-execdir", "-delete"} for t in argv):
        findings.append(
            finding(
                "critical",
                "AST_FILE_MUTATION_REQUIRES_SKILL" if "-delete" in argv else "AST_FIND_EXEC",
                "File modifications must use a registered controlled skill instead of free-form shell."
                if "-delete" in argv
                else "find executes through arguments.",
                category="controlled_file_modification" if "-delete" in argv else "destructive",
                command_head=head,
                text=text,
            )
        )

    if head == "xargs":
        forwarded = xargs_subcommand(argv)
        if forwarded:
            forwarded_head, forwarded_argv = forwarded
            if forwarded_head in FILE_MUTATION_COMMANDS or forwarded_head in WRITE_VERBS:
                add_file_write_finding(findings, forwarded_head, forwarded_argv, text)
            elif forwarded_head in PERMISSION_VERBS:
                add_permission_write_finding(findings, forwarded_head, forwarded_argv, text)

    if head == "curl":
        for idx, arg in enumerate(argv):
            if arg in {"-O", "--remote-name", "--remote-name-all"}:
                findings.append(file_mutation_requires_skill(command_head=head, text=text))
            if arg in {"-o", "--output"} and idx + 1 < len(argv) and argv[idx + 1] not in {"-", "/dev/null"}:
                findings.append(file_mutation_requires_skill(command_head=head, text=argv[idx + 1]))
            if arg.startswith("--output=") and arg.split("=", 1)[1] not in {"-", "/dev/null"}:
                findings.append(file_mutation_requires_skill(command_head=head, text=arg))
        if has_curl_upload(argv):
            findings.append(
                finding(
                    "high",
                    "AST_NETWORK_UPLOAD",
                    "Command uploads local data to a remote endpoint and requires review.",
                    category="information_disclosure",
                    command_head=head,
                    text=text,
                )
            )
        if has_file_url(argv):
            findings.append(
                finding(
                    "high",
                    "AST_LOCAL_FILE_URL",
                    "Command reads local file URLs and requires review.",
                    category="information_disclosure",
                    command_head=head,
                    text=text,
                )
            )

    if head == "wget":
        for idx, arg in enumerate(argv):
            if arg in {"-O", "--output-document"} and idx + 1 < len(argv) and argv[idx + 1] not in {"-", "/dev/null"}:
                findings.append(file_mutation_requires_skill(command_head=head, text=argv[idx + 1]))
            if arg.startswith("--output-document=") and arg.split("=", 1)[1] not in {"-", "/dev/null"}:
                findings.append(file_mutation_requires_skill(command_head=head, text=arg))
        if has_wget_upload(argv):
            findings.append(
                finding(
                    "high",
                    "AST_NETWORK_UPLOAD",
                    "Command uploads local data to a remote endpoint and requires review.",
                    category="information_disclosure",
                    command_head=head,
                    text=text,
                )
            )
        if has_file_url(argv):
            findings.append(
                finding(
                    "high",
                    "AST_LOCAL_FILE_URL",
                    "Command reads local file URLs and requires review.",
                    category="information_disclosure",
                    command_head=head,
                    text=text,
                )
            )

    if head in INTERACTIVE:
        findings.append(
            finding(
                "high",
                "AST_INTERACTIVE_COMMAND",
                "Interactive screen command is not suitable for agent execution.",
                category="interactive",
                command_head=head,
                text=text,
            )
        )
    if head == "top" and not any(t.startswith("-b") or t.startswith("-l") for t in argv):
        findings.append(
            finding(
                "high",
                "AST_INTERACTIVE_COMMAND",
                "top requires batch-style flags.",
                category="interactive",
                command_head=head,
                text=text,
            )
        )
    if head == "tail" and any(t in {"-f", "-F"} for t in argv):
        findings.append(
            finding(
                "high",
                "AST_INTERACTIVE_COMMAND",
                "tail -f does not terminate on its own.",
                category="interactive",
                command_head=head,
                text=text,
            )
        )

    if head in COUNTED_LOOP:
        consecutive = 0
        best = 0
        for arg in argv:
            if is_number(arg):
                consecutive += 1
                best = max(best, consecutive)
            else:
                consecutive = 0
        if best < 2:
            findings.append(
                finding(
                    "high",
                    "AST_UNBOUNDED_SAMPLING",
                    "Sampling command must include interval and count.",
                    category="sampling",
                    command_head=head,
                    text=text,
                )
            )

    if head == "systemctl" and argv and argv[0] in SERVICE_ACTIONS:
        service = argv[1] if len(argv) > 1 else ""
        findings.append(
            finding(
                "high",
                "AST_SERVICE_CONTROL",
                "Service control can interrupt workloads.",
                category="service",
                command_head=head,
                text=text,
            )
        )
        if service in PROTECTED_SERVICES:
            findings.append(
                finding(
                    "high",
                    "PROTECTED_SERVICE",
                    "Command targets a protected service.",
                    category="protected_service",
                    command_head=head,
                    text=service,
                )
            )


def check_remote_pipe(commands: list[CommandNode], findings: list[dict]) -> None:
    by_pipeline: dict[int, list[CommandNode]] = {}
    for cmd in commands:
        by_pipeline.setdefault(cmd.pipeline_id, []).append(cmd)
    for group in by_pipeline.values():
        if len(group) < 2:
            continue
        for idx, cmd in enumerate(group[:-1]):
            if cmd.head not in {"curl", "wget"}:
                continue
            for later in group[idx + 1 :]:
                if later.head in SHELLS or (later.wrapper_chain and later.head in SHELLS):
                    findings.append(
                        finding(
                            "critical",
                            "AST_REMOTE_PIPE",
                            "Remote download is piped directly into a shell.",
                            category="remote_execution",
                            command_head=cmd.head,
                            text=" | ".join(" ".join(c.tokens) for c in group),
                        )
                    )
                    break


def bash_syntax_check(text: str) -> str | None:
    if not text.strip():
        return None
    try:
        result = subprocess.run(
            ["bash", "-n"],
            input=text,
            text=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            env=build_subprocess_env(include_api_key=False),
            timeout=3,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return result.stderr.strip()[:500] or "bash -n failed"
    return None


def analyze(
    text: str,
    mode: str = "local",
    depth: int = 0,
    syntax_check: bool = True,
    declared_functions: set[str] | None = None,
) -> list[dict]:
    findings: list[dict] = []
    if len(text) > MAX_ANALYSIS_INPUT_BYTES or len(
        text.encode("utf-8", errors="replace")
    ) > MAX_ANALYSIS_INPUT_BYTES:
        return [
            finding(
                "critical",
                "AST_INPUT_TOO_LARGE",
                "Command text exceeds the structured analysis byte limit.",
                category="syntax",
                node="input",
            )
        ]
    shell_text, heredocs = extract_heredocs(text)
    for node in heredocs:
        if node.error:
            findings.append(
                finding(
                    "critical",
                    "AST_HEREDOC_PARSE_FAILED",
                    "Here-document could not be analysed safely.",
                    category="syntax",
                    node="heredoc",
                    text=node.error,
                )
            )
    findings.extend(dynamic_command_head_findings(shell_text))
    if depth == 0 and ":(){:|:&};:" in re.sub(r"\s+", "", shell_text):
        findings.append(finding("critical", "AST_DESTRUCTIVE_COMMAND", "Fork bomb pattern is blocked.", category="destructive", text="fork bomb"))

    if syntax_check and depth == 0:
        syntax_error = bash_syntax_check(text)
        if syntax_error:
            findings.append(
                finding(
                    "high",
                    "POLICY_PARSE_FAILED",
                    "Command text does not pass Bash syntax checking.",
                    category="syntax",
                    node="bash",
                    text=syntax_error,
                )
            )

    normalized_text, used_spacing_markers = normalize_shell_spacing_markers(shell_text)
    if used_spacing_markers:
        findings.append(
            finding(
                "high",
                "AST_SHELL_OBFUSCATION",
                "Command uses shell word-splitting markers such as IFS; review obfuscated command flow.",
                category="obfuscation",
                text=text,
            )
        )

    cleaned, sub_findings, fragments = strip_and_collect_substitutions(normalized_text, depth)
    findings.extend(sub_findings)
    visible_functions = set(declared_functions or ()) | shell_function_names(cleaned)
    for fragment in fragments:
        findings.extend(
            analyze(
                fragment,
                mode=mode,
                depth=depth + 1,
                syntax_check=False,
                declared_functions=visible_functions,
            )
        )

    cleaned = strip_function_declaration_headers(cleaned)
    tokens, token_error = tokenize(cleaned)
    if token_error:
        findings.append(
            finding(
                "high",
                "POLICY_TOKENIZE_FAILED",
                "Command text could not be tokenized safely.",
                category="syntax",
                node="shlex",
                text=token_error,
            )
        )
        return dedupe(findings)
    commands = split_commands(tokens, findings)
    heredoc_index = 0
    for command in commands:
        for _unused in range(_redirect_heredoc_count(command.tokens)):
            if heredoc_index >= len(heredocs):
                findings.append(
                    finding(
                        "critical",
                        "AST_HEREDOC_PARSE_FAILED",
                        "Here-document redirect could not be matched to its body.",
                        category="syntax",
                        node="heredoc",
                        text=" ".join(command.tokens),
                    )
                )
                break
            heredocs[heredoc_index].command = command
            heredoc_index += 1
    if heredoc_index != len(heredocs):
        findings.append(
            finding(
                "critical",
                "AST_HEREDOC_PARSE_FAILED",
                "Here-document body could not be matched to an executable command.",
                category="syntax",
                node="heredoc",
                text=heredocs[heredoc_index].declaration if heredoc_index < len(heredocs) else text,
            )
        )

    for node in heredocs:
        if node.error:
            continue
        if not node.quoted:
            _cleaned_body, expansion_findings, expansion_fragments = strip_and_collect_substitutions(
                node.body, depth
            )
            findings.extend(expansion_findings)
            for fragment in expansion_fragments:
                findings.extend(
                    analyze(
                        fragment,
                        mode=mode,
                        depth=depth + 1,
                        syntax_check=False,
                        declared_functions=visible_functions,
                    )
                )
        if node.command is None or not _uses_stdin_as_program(
            node.command.head, node.command.argv
        ):
            continue
        if node.command.head in SHELLS and depth < 3:
            findings.extend(
                analyze(
                    node.body,
                    mode=mode,
                    depth=depth + 1,
                    syntax_check=False,
                    declared_functions=visible_functions,
                )
            )
        elif node.command.head in SHELLS:
            findings.append(
                finding(
                    "critical",
                    "AST_RECURSION_LIMIT",
                    "Nested shell input exceeds the structured analysis depth limit.",
                    category="syntax",
                    command_head=node.command.head,
                    node="heredoc",
                )
            )
        elif node.command.head in INTERPRETERS:
            findings.append(
                finding(
                    "high",
                    "AST_INTERPRETER_STDIN",
                    "Interpreter executes program text supplied through a here-document.",
                    category="wrapper",
                    command_head=node.command.head,
                    node="heredoc",
                    text=node.declaration,
                )
            )
    for cmd in commands:
        check_command_rules(cmd, findings, visible_functions)
        if depth < 3 and cmd.head in TRANSPARENT_FORWARDERS:
            forwarded = forwarder_subcommand(cmd.head, cmd.argv)
            if forwarded:
                findings.extend(
                    analyze(
                        shlex.join(forwarded),
                        mode=mode,
                        depth=depth + 1,
                        syntax_check=False,
                        declared_functions=visible_functions,
                    )
                )
        if depth < 3 and cmd.head == "timeout":
            forwarded = timeout_subcommand(cmd.argv)
            if forwarded:
                findings.extend(
                    analyze(
                        shlex.join(forwarded),
                        mode=mode,
                        depth=depth + 1,
                        syntax_check=False,
                        declared_functions=visible_functions,
                    )
                )
        if depth < 3 and cmd.head in SHELLS:
            for index, arg in enumerate(cmd.argv):
                if (arg == "--command" or (arg.startswith("-") and not arg.startswith("--") and "c" in arg[1:])) and index + 1 < len(cmd.argv):
                    findings.extend(
                        analyze(
                            cmd.argv[index + 1],
                            mode=mode,
                            depth=depth + 1,
                            syntax_check=False,
                            declared_functions=visible_functions,
                        )
                    )
                    break
    check_remote_pipe(commands, findings)

    if mode == "remote" and not any(f["severity"] == "critical" for f in findings):
        findings.append(
            finding(
                "high",
                "REMOTE_SCRIPT_REVIEW",
                "Remote script content requires explicit approval after download review.",
                category="remote_execution",
                source="policy",
            )
        )
    return dedupe(findings)


def dedupe(findings: list[dict]) -> list[dict]:
    seen: set[tuple[str, str, str, str]] = set()
    out: list[dict] = []
    for item in findings:
        key = (
            item.get("code", ""),
            item.get("severity", ""),
            item.get("command_head", ""),
            item.get("text", ""),
        )
        if key in seen:
            continue
        seen.add(key)
        out.append(item)
    return out


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", default="local", choices=["local", "remote"])
    parser.add_argument("--no-syntax-check", action="store_true")
    parser.add_argument("--policy-text", action="store_true")
    args = parser.parse_args()
    text = sys.stdin.read()
    if args.policy_text:
        sys.stdout.write(executable_policy_text(text))
        return 0
    findings = analyze(text, mode=args.mode, syntax_check=not args.no_syntax_check)
    json.dump(findings, sys.stdout, ensure_ascii=False, separators=(",", ":"))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
