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
import os
import re
import shlex
import subprocess
import sys
from dataclasses import dataclass
from pathlib import PurePosixPath
from typing import Iterable


SEPARATORS = {";", "&&", "||", "&"}
PIPE_OPERATORS = {"|", "|&"}
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
WRAPPERS = {"sudo", "doas", "env", "busybox"}
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
INTERACTIVE = {"htop", "watch", "less", "more", "vi", "vim", "nano", "tmux", "screen", "iotop"}
COUNTED_LOOP = {"vmstat", "iostat", "pidstat", "mpstat", "sar", "jstat"}
DEFERRED_EXEC = {"eval", "source", "."}
INTERPRETERS = {"python", "python2", "python3", "perl", "ruby", "node", "nodejs", "lua", "php"}
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
    return re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", token) is not None


def is_number(token: str) -> bool:
    return re.match(r"^[0-9]+$", token) is not None


def is_fd_dup_destination(token: str) -> bool:
    return is_number(token) or token in {"-", "&1", "&2"}


def normalize_shell_spacing_markers(text: str) -> tuple[str, bool]:
    normalized = re.sub(r"\$\{IFS[^}]*\}|\$IFS\b", " ", text)
    return normalized, normalized != text


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
    try:
        lexer = shlex.shlex(text, posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        lexer.commenters = ""
        return list(lexer), None
    except ValueError as exc:
        return [], str(exc)


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
        raw_head = args[head_index]
        argv = args[head_index + 1 :]
        head, argv, wrappers = strip_wrappers(raw_head, argv, findings)
        if head:
            commands.append(CommandNode(head=canonical(head), argv=argv, tokens=current[:], pipeline_id=pipeline_id, wrapper_chain=wrappers))
        current = []

    for tok in tokens:
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


def has_protected_target(argv: Iterable[str]) -> bool:
    return any(protected_path(t) for t in target_paths(argv))


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
    severity = "critical" if has_protected_target(argv) else "high"
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


def check_command_rules(cmd: CommandNode, findings: list[dict]) -> None:
    head = cmd.head
    argv = cmd.argv
    text = " ".join(cmd.tokens)

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

    if head in SHELLS and any(t == "-c" or t == "--command" or t.startswith("-c") for t in argv):
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
                "high",
                "AST_WRAPPER_EXEC",
                "Deferred execution hides additional shell text.",
                category="wrapper",
                command_head=head,
                text=text,
            )
        )

    if head in FORWARDERS:
        findings.append(
            finding(
                "high",
                "AST_COMMAND_FORWARDER",
                "Command forwarder passes the real command as arguments.",
                category="wrapper",
                command_head=head,
                text=text,
            )
        )

    if head in INTERPRETERS and any(t == "-c" or t.startswith("-c") for t in argv):
        findings.append(
            finding(
                "high",
                "AST_WRAPPER_EXEC",
                "Interpreter -c executes embedded code.",
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
    elif head in DESTRUCTIVE:
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
                "critical" if "-delete" in argv else "high",
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
            timeout=3,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return result.stderr.strip()[:500] or "bash -n failed"
    return None


def analyze(text: str, mode: str = "local", depth: int = 0, syntax_check: bool = True) -> list[dict]:
    findings: list[dict] = []
    if depth == 0 and ":(){:|:&};:" in re.sub(r"\s+", "", text):
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

    normalized_text, used_spacing_markers = normalize_shell_spacing_markers(text)
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
    for fragment in fragments:
        findings.extend(analyze(fragment, mode=mode, depth=depth + 1, syntax_check=False))

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
    for cmd in commands:
        check_command_rules(cmd, findings)
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
    args = parser.parse_args()
    text = sys.stdin.read()
    findings = analyze(text, mode=args.mode, syntax_check=not args.no_syntax_check)
    json.dump(findings, sys.stdout, ensure_ascii=False, separators=(",", ":"))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
