#!/usr/bin/env python3
"""Bounded read-only Docker, Podman, and CRI inspection commands."""

from __future__ import annotations

import json
import os
import re
import stat
import subprocess
import sys
from pathlib import Path


MAX_CAPTURE = 4 * 1024 * 1024
MAX_ITEMS = 500
IDENTIFIER_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$")
SENSITIVE_PATTERN = re.compile(
    r"(?:pass(?:word)?|secret|token|credential|auth|private[_-]?key|api[_-]?key)",
    re.IGNORECASE,
)
COMMAND_LINE_FIELDS = frozenset(
    {
        "args",
        "arguments",
        "argv",
        "cmd",
        "command",
        "command_line",
        "commandline",
        "created_by",
        "createdby",
        "entrypoint",
    }
)
RUNTIME_PATHS = {
    "docker": ("/usr/bin/docker", "/usr/local/bin/docker"),
    "podman": ("/usr/bin/podman", "/usr/local/bin/podman"),
    "cri": ("/usr/bin/crictl", "/usr/local/bin/crictl"),
}


class ContainerInspectError(ValueError):
    def __init__(self, message: str, code: str = "invalid_arguments"):
        super().__init__(message)
        self.code = code


def emit(payload: dict[str, object]) -> None:
    print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))


def _reject_duplicates(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ContainerInspectError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _strict_json(raw: str) -> object:
    try:
        return json.loads(
            raw,
            object_pairs_hook=_reject_duplicates,
            parse_constant=lambda value: (_ for _ in ()).throw(
                ContainerInspectError(f"invalid JSON constant: {value}")
            ),
        )
    except json.JSONDecodeError as exc:
        raise ContainerInspectError(f"invalid JSON: {exc}") from exc


def _object(raw: str) -> dict[str, object]:
    if not isinstance(raw, str):
        raise ContainerInspectError("arguments must be valid JSON")
    value = _strict_json(raw)
    if not isinstance(value, dict):
        raise ContainerInspectError("arguments must be a JSON object")
    return value


def _fields(args: dict[str, object], allowed: set[str]) -> None:
    unknown = sorted(set(args) - allowed)
    if unknown:
        raise ContainerInspectError(f"unsupported fields: {', '.join(unknown)}")


def _integer(value: object, name: str, minimum: int, maximum: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not minimum <= value <= maximum:
        raise ContainerInspectError(f"{name} must be an integer in {minimum}..{maximum}")
    return value


def _bool(value: object, name: str) -> bool:
    if not isinstance(value, bool):
        raise ContainerInspectError(f"{name} must be boolean")
    return value


def _runtime_tools() -> dict[str, str]:
    result = {}
    for runtime, candidates in RUNTIME_PATHS.items():
        for candidate in candidates:
            path = Path(candidate)
            try:
                metadata = path.stat()
            except OSError:
                continue
            if (
                stat.S_ISREG(metadata.st_mode)
                and not metadata.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
                and os.access(path, os.X_OK)
            ):
                result[runtime] = candidate
                break
    return result


def _runtime(args: dict[str, object]) -> tuple[str, str]:
    available = _runtime_tools()
    requested = args.get("runtime")
    if requested is not None and requested not in RUNTIME_PATHS:
        raise ContainerInspectError("runtime must be docker, podman, or cri")
    if requested is not None:
        if requested not in available:
            raise ContainerInspectError(f"{requested} client is unavailable", "tool_unavailable")
        return str(requested), available[str(requested)]
    if not available:
        raise ContainerInspectError("no supported container client is installed", "tool_unavailable")
    if len(available) != 1:
        raise ContainerInspectError(
            "multiple container runtimes are installed; select runtime explicitly",
            "runtime_selection_required",
        )
    return next(iter(available.items()))


def _run(argv: list[str], timeout: int = 20) -> object:
    environment = {
        "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "HOME": "/nonexistent",
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
    }
    try:
        completed = subprocess.run(
            argv,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            check=False,
            timeout=timeout,
            env=environment,
        )
    except subprocess.TimeoutExpired as exc:
        raise ContainerInspectError("container runtime query timed out", "runtime_unreachable") from exc
    except OSError as exc:
        raise ContainerInspectError(str(exc), "tool_unavailable") from exc
    stdout = completed.stdout[:MAX_CAPTURE]
    stderr = completed.stderr[:65_536].decode("utf-8", errors="replace").strip()
    if completed.returncode != 0:
        lower = stderr.lower()
        code = (
            "permission_denied"
            if "permission denied" in lower or "access denied" in lower
            else "runtime_unreachable"
        )
        raise ContainerInspectError(stderr or "container runtime query failed", code)
    try:
        return stdout.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ContainerInspectError("container runtime returned non-UTF-8 output", "invalid_output") from exc


def _json(text: str) -> object:
    try:
        return _strict_json(text)
    except ContainerInspectError as exc:
        raise ContainerInspectError(
            "container runtime returned invalid JSON",
            "invalid_output",
        ) from exc


def _json_lines(text: str) -> list[object]:
    values = []
    for line in text.splitlines():
        if not line.strip():
            continue
        values.append(_json(line))
    return values


def _items(value: object, keys: tuple[str, ...]) -> list[object]:
    if isinstance(value, list):
        return value
    if isinstance(value, dict):
        for key in keys:
            candidate = value.get(key)
            if isinstance(candidate, list):
                return candidate
    return []


def _filtered_labels(value: object) -> dict[str, object]:
    if not isinstance(value, dict):
        return {}
    labels = {}
    for key, item in list(value.items())[:256]:
        name = str(key)[:256]
        rendered = str(item)[:2048]
        labels[name] = (
            "[REDACTED]"
            if SENSITIVE_PATTERN.search(name) or SENSITIVE_PATTERN.search(rendered)
            else rendered
        )
    return labels


def _env_keys(value: object) -> list[str]:
    if isinstance(value, list):
        values = value
    elif isinstance(value, dict):
        values = list(value)
    else:
        return []
    result = []
    for item in values[:1024]:
        name = str(item).split("=", 1)[0]
        if name and name not in result:
            result.append(name[:256])
    return result


def _mounts(value: object) -> list[dict[str, object]]:
    if not isinstance(value, list):
        return []
    result = []
    for mount in value[:256]:
        if not isinstance(mount, dict):
            continue
        destination = mount.get("Destination", mount.get("destination", mount.get("container_path", "")))
        destination_text = str(destination)[:4096]
        kind = mount.get("Type", mount.get("type", ""))
        read_only = mount.get("RW") is False or mount.get("readonly") is True
        result.append(
            {
                "type": str(kind)[:64],
                "destination": (
                    "[REDACTED]"
                    if SENSITIVE_PATTERN.search(destination_text)
                    else destination_text
                ),
                "read_only": read_only,
                "source_redacted": True,
            }
        )
    return result


def _safe_state(value: object) -> dict[str, object]:
    if not isinstance(value, dict):
        return {}
    allowed = {
        "Status",
        "Running",
        "Paused",
        "Restarting",
        "OOMKilled",
        "Dead",
        "Pid",
        "ExitCode",
        "StartedAt",
        "FinishedAt",
        "state",
        "createdAt",
        "startedAt",
        "finishedAt",
        "exitCode",
    }
    return {
        key: item
        for key, item in value.items()
        if key in allowed and isinstance(item, (str, int, bool, type(None)))
    }


def _sanitize_summary(value: object) -> object:
    if not isinstance(value, dict):
        raise ContainerInspectError("container summary must be an object", "invalid_output")
    result = {}
    for key, item in list(value.items())[:128]:
        name = str(key)
        lower = name.lower()
        if SENSITIVE_PATTERN.search(name):
            result[name] = "[REDACTED]"
        elif lower in COMMAND_LINE_FIELDS:
            result[name] = "[REDACTED]"
        elif lower in {"labels", "label"}:
            result[name] = _filtered_labels(item) if isinstance(item, dict) else "[FILTERED]"
        elif lower in {"mounts", "mount"}:
            result[name] = _mounts(item) if isinstance(item, list) else "[REDACTED]"
        elif lower in {"env", "envs", "environment"}:
            result[f"{name}Keys"] = _env_keys(item)
        elif isinstance(item, str):
            result[name] = item[:4096]
        elif isinstance(item, (int, float, bool, type(None))):
            result[name] = item
    return result


def _sanitize_inspect(value: object) -> dict[str, object]:
    if not isinstance(value, dict):
        raise ContainerInspectError("inspect result must be an object", "invalid_output")
    config = value.get("Config") if isinstance(value.get("Config"), dict) else {}
    if not config and isinstance(value.get("config"), dict):
        config = value["config"]
    status = value.get("State") if isinstance(value.get("State"), dict) else value.get("status", {})
    metadata = value.get("metadata") if isinstance(value.get("metadata"), dict) else {}
    labels = config.get("Labels", config.get("labels", metadata.get("labels", {})))
    environment = config.get("Env", config.get("envs", config.get("environment", [])))
    mounts = value.get("Mounts", value.get("mounts", []))
    if not mounts and isinstance(value.get("info"), dict):
        mounts = value["info"].get("runtimeSpec", {}).get("mounts", [])
    identifier = value.get("Id", value.get("ID", value.get("id", metadata.get("id", ""))))
    name = value.get("Name", value.get("name", metadata.get("name", "")))
    image = config.get("Image", config.get("image", value.get("image", "")))
    return {
        "id": str(identifier)[:256],
        "name": str(name).lstrip("/")[:256],
        "image": str(image)[:1024],
        "state": _safe_state(status),
        "environment_keys": _env_keys(environment),
        "labels": _filtered_labels(labels),
        "mounts": _mounts(mounts),
    }


def runtime_summary(args: dict[str, object]) -> dict[str, object]:
    _fields(args, set())
    available = _runtime_tools()
    summaries = []
    for runtime, tool in available.items():
        if runtime == "docker":
            argv = [tool, "version", "--format", "{{json .Server}}"]
        elif runtime == "podman":
            argv = [tool, "version", "--format", "json"]
        else:
            argv = [tool, "version"]
        try:
            output = str(_run(argv, timeout=10))
            summaries.append({"runtime": runtime, "client": tool, "reachable": True, "version": output[:8192]})
        except ContainerInspectError as exc:
            summaries.append(
                {"runtime": runtime, "client": tool, "reachable": False, "code": exc.code, "error": str(exc)}
            )
    return {
        "ok": True,
        "status": "listed",
        "tool": "container-inspect/runtime-summary",
        "runtimes": summaries,
        "selection_required": len(available) > 1,
        "client_install_attempted": False,
    }


def container_list(args: dict[str, object]) -> dict[str, object]:
    _fields(args, {"runtime", "all", "limit"})
    runtime, tool = _runtime(args)
    include_all = _bool(args.get("all", True), "all")
    limit = _integer(args.get("limit", 100), "limit", 1, MAX_ITEMS)
    if runtime == "docker":
        argv = [tool, "ps"] + (["--all"] if include_all else []) + ["--no-trunc", "--format", "{{json .}}"]
        values = _json_lines(str(_run(argv)))
    elif runtime == "podman":
        argv = [tool, "ps"] + (["--all"] if include_all else []) + ["--no-trunc", "--format", "json"]
        values = _items(_json(str(_run(argv))), ("containers",))
    else:
        argv = [tool, "ps"] + (["--all"] if include_all else []) + ["-o", "json"]
        values = _items(_json(str(_run(argv))), ("containers",))
    return {
        "ok": True,
        "status": "listed",
        "tool": "container-inspect/container-list",
        "runtime": runtime,
        "containers": [_sanitize_summary(value) for value in values[:limit]],
        "count": min(len(values), limit),
        "truncated": len(values) > limit,
    }


def container_inspect(args: dict[str, object]) -> dict[str, object]:
    _fields(args, {"runtime", "id"})
    runtime, tool = _runtime(args)
    identifier = args.get("id")
    if not isinstance(identifier, str) or IDENTIFIER_PATTERN.fullmatch(identifier) is None:
        raise ContainerInspectError("id must be a safe container identifier")
    if runtime == "docker":
        value = _json(str(_run([tool, "inspect", identifier])))
        values = _items(value, ())
        selected = values[0] if values else None
    elif runtime == "podman":
        value = _json(str(_run([tool, "inspect", identifier])))
        values = _items(value, ())
        selected = values[0] if values else None
    else:
        selected = _json(str(_run([tool, "inspect", "-o", "json", identifier])))
    return {
        "ok": True,
        "status": "read",
        "tool": "container-inspect/container-inspect",
        "runtime": runtime,
        "container": _sanitize_inspect(selected),
        "secrets_redacted": True,
    }


def image_inventory(args: dict[str, object]) -> dict[str, object]:
    _fields(args, {"runtime", "limit"})
    runtime, tool = _runtime(args)
    limit = _integer(args.get("limit", 100), "limit", 1, MAX_ITEMS)
    if runtime == "docker":
        values = _json_lines(
            str(_run([tool, "image", "ls", "--no-trunc", "--digests", "--format", "{{json .}}"]))
        )
    elif runtime == "podman":
        values = _items(_json(str(_run([tool, "images", "--no-trunc", "--format", "json"]))), ("images",))
    else:
        values = _items(_json(str(_run([tool, "images", "-o", "json"]))), ("images",))
    return {
        "ok": True,
        "status": "listed",
        "tool": "container-inspect/image-inventory",
        "runtime": runtime,
        "images": [_sanitize_summary(value) for value in values[:limit]],
        "count": min(len(values), limit),
        "truncated": len(values) > limit,
    }


def resource_snapshot(args: dict[str, object]) -> dict[str, object]:
    _fields(args, {"runtime", "limit"})
    runtime, tool = _runtime(args)
    limit = _integer(args.get("limit", 100), "limit", 1, MAX_ITEMS)
    if runtime == "docker":
        values = _json_lines(str(_run([tool, "stats", "--no-stream", "--format", "{{json .}}"])))
    elif runtime == "podman":
        values = _items(_json(str(_run([tool, "stats", "--no-stream", "--format", "json"]))), ("stats",))
    else:
        values = _items(_json(str(_run([tool, "stats", "-o", "json"]))), ("stats",))
    return {
        "ok": True,
        "status": "read",
        "tool": "container-inspect/resource-snapshot",
        "runtime": runtime,
        "sample_mode": "single",
        "stats": [_sanitize_summary(value) for value in values[:limit]],
        "count": min(len(values), limit),
        "truncated": len(values) > limit,
    }


COMMANDS = {
    "runtime-summary": runtime_summary,
    "container-list": container_list,
    "container-inspect": container_inspect,
    "image-inventory": image_inventory,
    "resource-snapshot": resource_snapshot,
}


def main(argv: list[str]) -> int:
    if len(argv) != 3 or argv[1] not in COMMANDS:
        emit({"ok": False, "status": "invalid_arguments", "code": "invalid_arguments", "error": "usage: container_inspect.py <operation> <json-object>"})
        return 0
    try:
        result = COMMANDS[argv[1]](_object(argv[2]))
    except ContainerInspectError as exc:
        emit(
            {
                "ok": False,
                "status": exc.code,
                "code": exc.code,
                "tool": f"container-inspect/{argv[1]}",
                "error": str(exc),
            }
        )
        return 0
    emit(result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
