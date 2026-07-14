#!/usr/bin/env python3
"""Static file-vault access classifier.

Policy entries are exact absolute paths or a single trailing ``/*`` directory
pattern. Lexical path aliases are normalized before matching; unresolved path
expressions remain conservative and are classified as unknown. The auditd
observer records dynamically resolved file events after a process runs.
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import posixpath
import re
import shlex
import sys
from pathlib import PurePosixPath


READ_ONLY_COMMANDS = {
    "awk",
    "cat",
    "cmp",
    "diff",
    "du",
    "file",
    "find",
    "grep",
    "head",
    "less",
    "ls",
    "md5sum",
    "more",
    "od",
    "pg",
    "rg",
    "sed",
    "sha1sum",
    "sha256sum",
    "sort",
    "stat",
    "strings",
    "tail",
    "tar",
    "tee",
    "test",
    "tr",
    "uniq",
    "wc",
    "which",
}
MUTATE_ALL_COMMANDS = {
    "chmod",
    "chgrp",
    "chown",
    "ed",
    "ln",
    "mkdir",
    "mv",
    "patch",
    "rmdir",
    "rm",
    "setcap",
    "setfacl",
    "truncate",
    "touch",
    "unlink",
}
SHELL_COMMANDS = {"ash", "bash", "dash", "ksh", "mksh", "sh", "zsh"}
INTERPRETERS = {"lua", "node", "nodejs", "perl", "php", "python", "python2", "python3", "ruby"}
FILE_PATH_COMMANDS = READ_ONLY_COMMANDS | MUTATE_ALL_COMMANDS | {
    "cp",
    "curl",
    "install",
    "rsync",
    "scp",
    "source",
    "tar",
    "tee",
    "unzip",
    "wget",
}
COMMAND_SEPARATORS = {";", "&&", "||", "|", "|&", "&"}
OUTPUT_REDIRECTS = {">", ">>", ">|", "&>", ">>&", "<>"}
PATH_CHARACTERS = r"[A-Za-z0-9_./-]"
ABSOLUTE_PATH_PATTERN = re.compile(r"/(?:[A-Za-z0-9._~+${}*?\[\]-]+/)*[A-Za-z0-9._~+${}*?\[\]-]+")
UNRESOLVED_PATH_PATTERN = re.compile(r"(?<!\\)(?:\$\([^)]+\)|`[^`]+`|\$\{[^}]+\}|\$[A-Za-z_][A-Za-z0-9_]*|~(?:/|$))")


def canonical_head(value: str) -> str:
    return PurePosixPath(value).name if "/" in value else value


def validate_policy_path(path: str) -> None:
    if not isinstance(path, str) or not path.startswith("/") or path == "/":
        raise ValueError("file-vault paths must be absolute non-root paths")
    if any(character in path for character in "\x00\n\r"):
        raise ValueError("file-vault paths cannot contain control characters")
    if "//" in path or "/./" in f"/{path}/" or "/../" in f"/{path}/":
        raise ValueError("file-vault paths cannot contain non-canonical segments")
    if "*" in path and (
        path == "/*" or not path.endswith("/*") or "*" in path[:-2]
    ):
        raise ValueError("file-vault wildcard must be a single trailing /*")
    if any(character in path for character in "?[]"):
        raise ValueError("file-vault paths cannot contain glob characters other than trailing *")
    if path.endswith("/"):
        raise ValueError("file-vault paths cannot end with /")


def normalize_candidate_path(value: str) -> str | None:
    if not value.startswith("/"):
        return None
    return posixpath.normpath(value)


def policy_path_matches_candidate(policy_path: str, candidate: str) -> bool:
    normalized = normalize_candidate_path(candidate)
    if normalized is None:
        return False
    if policy_path.endswith("/*"):
        base = policy_path[:-2]
        return normalized == base or normalized.startswith(f"{base}/")
    if any(character in normalized for character in "*?[]"):
        return fnmatch.fnmatchcase(policy_path, normalized)
    return normalized == policy_path


def absolute_path_candidates(value: str) -> list[str]:
    return ABSOLUTE_PATH_PATTERN.findall(value)


def value_matches_policy(policy_path: str, value: str) -> bool:
    if re.search(rf"{re.escape(policy_path)}(?!{PATH_CHARACTERS})", value):
        return True
    return any(policy_path_matches_candidate(policy_path, candidate) for candidate in absolute_path_candidates(value))


def policy_path_referenced(policy_path: str, text: str, tokens: list[str]) -> bool:
    return value_matches_policy(policy_path, text) or any(
        value_matches_policy(policy_path, token) for token in tokens
    )


def tokenize(text: str) -> list[str]:
    lexer = shlex.shlex(text, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    lexer.commenters = ""
    return list(lexer)


def command_segments(tokens: list[str]) -> list[list[str]]:
    segments: list[list[str]] = []
    current: list[str] = []
    for token in tokens:
        if token in COMMAND_SEPARATORS:
            if current:
                segments.append(current)
                current = []
            continue
        current.append(token)
    if current:
        segments.append(current)
    return segments


def command_head(segment: list[str]) -> tuple[str, list[str]]:
    index = 0
    while index < len(segment):
        token = segment[index]
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", token):
            index += 1
            continue
        if token in {"sudo", "doas", "command", "builtin"}:
            index += 1
            while index < len(segment) and segment[index].startswith("-"):
                if segment[index] in {"-u", "-g", "-p", "-C", "-D", "-R", "--user", "--group"}:
                    index += 2
                else:
                    index += 1
            continue
        if token in {"env", "busybox"}:
            index += 1
            while index < len(segment) and (segment[index].startswith("-") or "=" in segment[index]):
                index += 2 if segment[index] in {"-u", "--unset", "-C", "--chdir"} else 1
            continue
        break
    if index >= len(segment):
        return "", []
    return canonical_head(segment[index]), segment[index + 1 :]


def non_option_args(args: list[str]) -> list[tuple[int, str]]:
    return [(index, value) for index, value in enumerate(args) if not value.startswith("-") and "=" not in value]


def argument_value_indices(args: list[str], flags: set[str]) -> set[int]:
    indices: set[int] = set()
    index = 0
    while index < len(args):
        token = args[index]
        if token in flags and index + 1 < len(args):
            indices.add(index + 1)
            index += 2
            continue
        if any(token.startswith(f"{flag}=") for flag in flags):
            indices.add(index)
        if any(
            flag.startswith("-")
            and not flag.startswith("--")
            and token.startswith(flag)
            and len(token) > len(flag)
            for flag in flags
        ):
            indices.add(index)
        index += 1
    return indices


def path_indexes(args: list[str], matched_path: str) -> set[int]:
    return {index for index, value in enumerate(args) if value_matches_policy(matched_path, value)}


def nested_shell_action(args: list[str], paths: list[str]) -> str | None:
    for index, value in enumerate(args):
        if value in {"-c", "-lc", "-ic", "-xc"} and index + 1 < len(args):
            return classify_text(args[index + 1], paths)
    return None


def code_writes_file(text: str, path: str) -> bool:
    if re.search(rf"(?:>|>>|\b(?:of|output|dest(?:ination)?)\s*=)\s*['\"]?{re.escape(path)}(?!{PATH_CHARACTERS})", text):
        return True
    if re.search(r"\b(?:unlink|remove|rename|replace|write|write_text|chmod|chown|mkdir|makedirs|rmdir)\s*\(", text):
        return True
    if re.search(r"\bopen\s*\([^\n)]*,\s*['\"][^'\"]*[wax+][^'\"]*['\"]", text):
        return True
    return False


def classify_segment(segment: list[str], matched_path: str) -> str:
    head, args = command_head(segment)
    if not head:
        return "unknown"

    matched = path_indexes(args, matched_path)
    if not matched and matched_path not in segment:
        return "read"

    if head in SHELL_COMMANDS:
        nested = nested_shell_action(args, [matched_path])
        if nested:
            return nested
        if any(token in OUTPUT_REDIRECTS for token in segment):
            return "modify"
        return "read"
    if head in INTERPRETERS:
        return "modify" if code_writes_file(" ".join(segment), matched_path) else "read"

    if head in MUTATE_ALL_COMMANDS:
        return "modify"
    if head == "sed" and any(token == "-i" or token.startswith("-i") or token.startswith("--in-place") for token in args):
        return "modify"
    if head == "awk" and any(token == "-i" and index + 1 < len(args) and args[index + 1] == "inplace" for index, token in enumerate(args)):
        return "modify"
    if head == "find":
        if "-delete" in args or any(token in {"-exec", "-execdir"} for token in args) and re.search(r"\b(?:rm|mv|truncate|chmod|chown|touch)\b", " ".join(args)):
            return "modify"
        return "read"
    if head == "cp":
        target_indices = argument_value_indices(args, {"-t", "--target-directory"})
        if matched & target_indices:
            return "modify"
        candidates = non_option_args(args)
        return "modify" if candidates and candidates[-1][0] in matched else "read"
    if head == "install":
        candidates = non_option_args(args)
        return "modify" if candidates and candidates[-1][0] in matched else "read"
    if head in {"rsync", "scp"}:
        candidates = non_option_args(args)
        return "modify" if candidates and candidates[-1][0] in matched else "read"
    if head == "curl":
        write_indices = argument_value_indices(args, {"-o", "--output", "-O", "--remote-name"})
        upload_indices = argument_value_indices(args, {"-T", "--upload-file"})
        if matched & write_indices:
            return "modify"
        if matched & upload_indices:
            return "read"
        return "read"
    if head == "wget":
        write_indices = argument_value_indices(args, {"-O", "--output-document", "-P", "--directory-prefix"})
        return "modify" if matched & write_indices else "read"
    if head == "dd":
        if any(index in matched and (value.startswith("of=") or value == "of") for index, value in enumerate(args)):
            return "modify"
        if any(value.startswith("of=") for value in args):
            return "modify"
        return "read"
    if head == "tar":
        if matched & argument_value_indices(args, {"-C"}):
            return "modify"
        flags = "".join(value.lstrip("-") for value in args if value.startswith("-") and not value.startswith("--"))
        return "read" if any(flag in flags for flag in "tx") and not any(flag in flags for flag in "cru") else "modify"
    if head == "unzip":
        return "modify" if matched & argument_value_indices(args, {"-d"}) else "read"
    if head == "tee":
        return "modify"
    if head in READ_ONLY_COMMANDS:
        return "read"
    return "unknown"


def unresolved_file_path_reference(tokens: list[str]) -> bool:
    for index, token in enumerate(tokens):
        if token in OUTPUT_REDIRECTS and index + 1 < len(tokens):
            if UNRESOLVED_PATH_PATTERN.search(tokens[index + 1]):
                return True

    for segment in command_segments(tokens):
        head, args = command_head(segment)
        if head in SHELL_COMMANDS:
            for index, value in enumerate(args):
                if value in {"-c", "-lc", "-ic", "-xc"} and index + 1 < len(args):
                    if unresolved_file_path_reference(tokenize(args[index + 1])):
                        return True
            continue
        if head in FILE_PATH_COMMANDS and any(UNRESOLVED_PATH_PATTERN.search(value) for value in args):
            return True
        if head in INTERPRETERS:
            code = " ".join(segment)
            if UNRESOLVED_PATH_PATTERN.search(code) and re.search(
                r"\b(?:open|Path|read_text|write_text|unlink|remove|rename|replace|mkdir|makedirs|rmdir)\b",
                code,
            ):
                return True
    return False


def classify_text(text: str, paths: list[str]) -> str:
    tokens = tokenize(text)
    segments = command_segments(tokens)
    actions: list[str] = []
    for path in paths:
        if not policy_path_referenced(path, text, tokens):
            continue
        if any(
            token in OUTPUT_REDIRECTS and index + 1 < len(tokens) and value_matches_policy(path, tokens[index + 1])
            for index, token in enumerate(tokens)
        ):
            return "modify"
        actions.extend(classify_segment(segment, path) for segment in segments)
        if any(action == "modify" for action in actions):
            return "modify"
    if not paths and unresolved_file_path_reference(tokens):
        return "unknown"
    if "read" in actions:
        return "read"
    if "unknown" in actions:
        return "unknown"
    return "read"


def load_paths(policy_path: str) -> list[str]:
    with open(policy_path, "r", encoding="utf-8") as handle:
        payload = json.load(handle)
    paths = payload.get("paths") if isinstance(payload, dict) else None
    if not isinstance(paths, list) or any(not isinstance(path, str) for path in paths):
        raise ValueError("file-vault paths must be an array of strings")
    for path in paths:
        validate_policy_path(path)
    return paths


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--policy", required=True)
    parser.add_argument("--mode", choices={"work", "terminal"}, default="work")
    args = parser.parse_args()
    try:
        paths = load_paths(args.policy)
        text = sys.stdin.read()
        matched_paths = [path for path in paths if policy_path_referenced(path, text, tokenize(text))]
        if matched_paths:
            action = classify_text(text, matched_paths)
            unresolved = False
        elif paths:
            # The vault has entries but none were matched literally; a dynamic or
            # non-statically-resolvable path may still resolve into a vault entry,
            # so stay conservative and surface it as unknown.
            action = classify_text(text, [])
            unresolved = action == "unknown"
        else:
            # An empty vault protects nothing and is inert: never flag a command.
            action = "read"
            unresolved = False
        json.dump({"ok": True, "matched": bool(matched_paths) or unresolved, "matched_paths": matched_paths, "action": action, "unresolved": unresolved}, sys.stdout, ensure_ascii=False, separators=(",", ":"))
        sys.stdout.write("\n")
        return 0
    except (OSError, ValueError, json.JSONDecodeError, shlex.Error) as exc:
        json.dump({"ok": False, "error": str(exc)}, sys.stdout, ensure_ascii=False, separators=(",", ":"))
        sys.stdout.write("\n")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
