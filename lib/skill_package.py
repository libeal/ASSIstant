#!/usr/bin/env python3
"""Parse and validate Agent Skills packages and Linux Agent extensions."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import sys
from pathlib import Path, PurePosixPath
from typing import Any


NAME_PATTERN = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$")
TOOL_NAME_PATTERN = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$")
CATEGORY_PATTERN = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$")
CAPABILITY_PATTERN = re.compile(r"^(?:|[a-z][a-z0-9-]*(?:\.[a-z][a-z0-9-]*)+)$")
APPROVAL_PATTERN = re.compile(r"^[a-z][a-z0-9_.-]{0,63}$")
ENVIRONMENT_NAME_PATTERN = re.compile(r"^[A-Z][A-Z0-9_]{0,127}$")
GUARD_FIELD_PATTERN = re.compile(r"^[a-z][a-z0-9_]{0,63}$")
ERROR_CODE_PATTERN = re.compile(r"^[a-z][a-z0-9_]{0,63}$")
WEB_ROUTE_PATTERN = re.compile(r"^/api/[a-z0-9][a-z0-9_./-]{0,190}$")
ALLOWED_FRONTMATTER = {
    "name",
    "description",
    "license",
    "compatibility",
    "metadata",
    "allowed-tools",
}
SCALAR_FRONTMATTER = ALLOWED_FRONTMATTER - {"metadata"}
RISK_LEVELS = frozenset({"low", "medium", "high", "critical"})
EXECUTION_CLASSES = frozenset({"runner", "host_helper", "credential_helper"})
DISPATCH_MODES = frozenset({"always", "apply_only"})
MAX_SKILL_MD_BYTES = 256 * 1024
MAX_DESCRIPTION_LENGTH = 1024
MAX_COMPATIBILITY_LENGTH = 500
INDEX_HEADING_PATTERN = re.compile(r"^## ([a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?)$")
INDEX_TOOL_PATTERN = re.compile(
    r"^- `([a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9]?)/"
    r"[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9]?))`: (.+)$"
)


class SkillPackageError(ValueError):
    """Raised when a Skill package does not satisfy its contract."""


class SkillPackageIncompatibleError(SkillPackageError):
    """Raised when a valid extension targets an unsupported core contract."""


def _reject_duplicate_json_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise SkillPackageError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _plain_scalar(value: str) -> str:
    value = value.strip()
    if not value:
        return ""
    if value[0] in "&*![]{}":
        raise SkillPackageError("YAML aliases, tags, anchors, and flow values are not allowed")
    if value.startswith('"'):
        try:
            parsed = json.loads(value)
        except json.JSONDecodeError as exc:
            raise SkillPackageError("invalid double-quoted YAML scalar") from exc
        if not isinstance(parsed, str):
            raise SkillPackageError("frontmatter scalar must be a string")
        return parsed
    if value.startswith("'"):
        if len(value) < 2 or not value.endswith("'"):
            raise SkillPackageError("invalid single-quoted YAML scalar")
        return value[1:-1].replace("''", "'")
    if " #" in value:
        value = value.split(" #", 1)[0].rstrip()
    return value


def _block_scalar(lines: list[str], start: int, indent: int, folded: bool) -> tuple[str, int]:
    values: list[str] = []
    position = start
    while position < len(lines):
        line = lines[position]
        stripped = line.lstrip(" ")
        current_indent = len(line) - len(stripped)
        if stripped and current_indent < indent:
            break
        if stripped:
            values.append(line[indent:])
        else:
            values.append("")
        position += 1
    if folded:
        output: list[str] = []
        for value in values:
            if not value:
                output.append("\n")
            elif output and not output[-1].endswith("\n"):
                output.append(" " + value)
            else:
                output.append(value)
        return "".join(output).rstrip("\n"), position
    return "\n".join(values).rstrip("\n"), position


def parse_frontmatter(skill_md: Path) -> tuple[dict[str, Any], str]:
    """Parse the bounded YAML subset used by the Agent Skills metadata schema."""

    try:
        metadata = skill_md.stat()
    except OSError as exc:
        raise SkillPackageError("SKILL.md is missing") from exc
    if not stat.S_ISREG(metadata.st_mode) or skill_md.is_symlink():
        raise SkillPackageError("SKILL.md must be a regular non-symlink file")
    if metadata.st_size > MAX_SKILL_MD_BYTES:
        raise SkillPackageError("SKILL.md exceeds the 256 KiB limit")
    try:
        text = skill_md.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        raise SkillPackageError("SKILL.md must be readable UTF-8") from exc
    normalized = text.replace("\r\n", "\n")
    if not normalized.startswith("---\n"):
        raise SkillPackageError("SKILL.md is missing YAML frontmatter")
    closing = normalized.find("\n---\n", 4)
    if closing < 0:
        raise SkillPackageError("SKILL.md frontmatter is not terminated")
    frontmatter_lines = normalized[4:closing].splitlines()
    body = normalized[closing + 5 :]
    parsed: dict[str, Any] = {}
    position = 0
    while position < len(frontmatter_lines):
        raw = frontmatter_lines[position]
        position += 1
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        if raw.startswith((" ", "\t")) or ":" not in raw:
            raise SkillPackageError("invalid top-level YAML frontmatter entry")
        key, value = raw.split(":", 1)
        key = key.strip()
        if key in parsed:
            raise SkillPackageError(f"duplicate frontmatter key: {key}")
        if key not in ALLOWED_FRONTMATTER:
            raise SkillPackageError(f"unsupported frontmatter key: {key}")
        if key == "metadata":
            if value.strip():
                raise SkillPackageError("metadata must be a string-to-string mapping")
            mapping: dict[str, str] = {}
            while position < len(frontmatter_lines):
                child = frontmatter_lines[position]
                if not child.strip():
                    position += 1
                    continue
                if not child.startswith("  ") or child.startswith("   ") or ":" not in child:
                    break
                child_key, child_value = child[2:].split(":", 1)
                child_key = child_key.strip()
                if not child_key or child_key in mapping:
                    raise SkillPackageError("metadata keys must be non-empty and unique")
                mapping[child_key] = _plain_scalar(child_value)
                position += 1
            parsed[key] = mapping
            continue
        value = value.strip()
        if value in {"|", "|-", "|+", ">", ">-", ">+"}:
            block, position = _block_scalar(
                frontmatter_lines, position, 2, value.startswith(">")
            )
            parsed[key] = block
        else:
            parsed[key] = _plain_scalar(value)
    for required in ("name", "description"):
        value = parsed.get(required)
        if not isinstance(value, str) or not value.strip():
            raise SkillPackageError(f"frontmatter {required} is required")
        parsed[required] = value.strip()
    name = parsed["name"]
    if not NAME_PATTERN.fullmatch(name) or "--" in name:
        raise SkillPackageError("frontmatter name must be 1-64 character hyphen-case")
    description = parsed["description"]
    if len(description) > MAX_DESCRIPTION_LENGTH or "<" in description or ">" in description:
        raise SkillPackageError("frontmatter description is invalid")
    compatibility = parsed.get("compatibility")
    if compatibility is not None and (
        not isinstance(compatibility, str) or len(compatibility) > MAX_COMPATIBILITY_LENGTH
    ):
        raise SkillPackageError("frontmatter compatibility is invalid")
    for key in SCALAR_FRONTMATTER:
        if key in parsed and not isinstance(parsed[key], str):
            raise SkillPackageError(f"frontmatter {key} must be a string")
    return parsed, body


def _regular_package_file(package: Path, relative: str, label: str) -> Path:
    path = PurePosixPath(relative)
    if path.is_absolute() or not path.parts or any(part in {"", ".", ".."} for part in path.parts):
        raise SkillPackageError(f"{label} must be a normalized relative path")
    candidate = package.joinpath(*path.parts)
    try:
        resolved_package = package.resolve(strict=True)
        resolved = candidate.resolve(strict=True)
        resolved.relative_to(resolved_package)
    except (OSError, ValueError) as exc:
        raise SkillPackageError(f"{label} escapes the Skill package") from exc
    if candidate.is_symlink() or not candidate.is_file():
        raise SkillPackageError(f"{label} must be a regular non-symlink file")
    return resolved


def _normalize_guard(guard: dict[str, Any], tool_name: str) -> dict[str, Any]:
    guard_type = guard.get("type")
    if guard_type == "risk_by_value":
        if set(guard) != {"type", "field", "values", "default"}:
            raise SkillPackageError(f"Skill tool {tool_name} risk guard is invalid")
        field = guard.get("field")
        values = guard.get("values")
        default = guard.get("default")
        if (
            not isinstance(field, str)
            or GUARD_FIELD_PATTERN.fullmatch(field) is None
            or not isinstance(values, dict)
            or not values
            or any(not isinstance(key, str) or value not in RISK_LEVELS for key, value in values.items())
            or default not in RISK_LEVELS
        ):
            raise SkillPackageError(f"Skill tool {tool_name} risk guard is invalid")
        return dict(guard)
    if guard_type == "runner_fallthrough":
        if set(guard) != {
            "type",
            "field",
            "default",
            "allowed",
            "boolean_flag",
        }:
            raise SkillPackageError(
                f"Skill tool {tool_name} runner fallthrough guard is invalid"
            )
        field = guard.get("field")
        default = guard.get("default")
        allowed = guard.get("allowed")
        boolean_flag = guard.get("boolean_flag")
        if (
            not isinstance(field, str)
            or GUARD_FIELD_PATTERN.fullmatch(field) is None
            or not isinstance(default, str)
            or not isinstance(allowed, list)
            or not allowed
            or len(allowed) != len(set(allowed))
            or not all(isinstance(value, str) and value for value in allowed)
            or default not in allowed
            or not isinstance(boolean_flag, str)
            or GUARD_FIELD_PATTERN.fullmatch(boolean_flag) is None
        ):
            raise SkillPackageError(
                f"Skill tool {tool_name} runner fallthrough guard is invalid"
            )
        return dict(guard)
    if guard_type != "backup_proof" or set(guard) - {
        "type",
        "mode",
        "condition",
        "proofs",
        "source",
        "message",
    }:
        raise SkillPackageError(f"Skill tool {tool_name} guard type is invalid")
    if guard.get("mode") not in {"transactional", "required_on_apply"}:
        raise SkillPackageError(f"Skill tool {tool_name} backup guard mode is invalid")
    condition = guard.get("condition")
    if not isinstance(condition, dict) or set(condition) != {"field", "equals", "default"}:
        raise SkillPackageError(f"Skill tool {tool_name} backup guard condition is invalid")
    if (
        not isinstance(condition.get("field"), str)
        or GUARD_FIELD_PATTERN.fullmatch(condition["field"]) is None
        or isinstance(condition.get("equals"), (dict, list))
        or isinstance(condition.get("default"), (dict, list))
        or type(condition.get("equals")) is not type(condition.get("default"))
    ):
        raise SkillPackageError(f"Skill tool {tool_name} backup guard condition is invalid")
    proofs = guard.get("proofs")
    if not isinstance(proofs, list) or not proofs:
        raise SkillPackageError(f"Skill tool {tool_name} backup proofs are invalid")
    proof_fields: set[str] = set()
    for proof in proofs:
        if not isinstance(proof, dict) or set(proof) - {"argument", "validation", "default"}:
            raise SkillPackageError(f"Skill tool {tool_name} backup proof is invalid")
        argument = proof.get("argument")
        if (
            not isinstance(argument, str)
            or GUARD_FIELD_PATTERN.fullmatch(argument) is None
            or argument in proof_fields
            or proof.get("validation") not in {"boolean_true", "nonempty_string", "sha256"}
        ):
            raise SkillPackageError(f"Skill tool {tool_name} backup proof is invalid")
        proof_fields.add(argument)
    message = guard.get("message")
    if not isinstance(message, str) or not message or len(message) > 512:
        raise SkillPackageError(f"Skill tool {tool_name} backup guard message is invalid")
    source = guard.get("source")
    if source is not None:
        if not isinstance(source, dict) or set(source) != {
            "tool",
            "target_argument",
            "target_output",
            "target_normalization",
            "values",
        }:
            raise SkillPackageError(f"Skill tool {tool_name} backup source is invalid")
        if (
            not isinstance(source.get("tool"), str)
            or not source["tool"]
            or not isinstance(source.get("target_argument"), str)
            or GUARD_FIELD_PATTERN.fullmatch(source["target_argument"]) is None
            or not isinstance(source.get("target_output"), str)
            or GUARD_FIELD_PATTERN.fullmatch(source["target_output"]) is None
            or source.get("target_normalization") not in {"exact", "realpath_existing"}
            or not isinstance(source.get("values"), list)
            or not source["values"]
        ):
            raise SkillPackageError(f"Skill tool {tool_name} backup source is invalid")
        mapped: set[str] = set()
        for value in source["values"]:
            if not isinstance(value, dict) or set(value) != {
                "argument",
                "output",
                "validation",
            }:
                raise SkillPackageError(f"Skill tool {tool_name} backup source is invalid")
            argument = value.get("argument")
            output = value.get("output")
            if (
                argument not in proof_fields
                or argument in mapped
                or not isinstance(output, str)
                or GUARD_FIELD_PATTERN.fullmatch(output) is None
                or value.get("validation") not in {"nonempty_string", "sha256"}
            ):
                raise SkillPackageError(f"Skill tool {tool_name} backup source is invalid")
            mapped.add(argument)
    elif guard.get("mode") == "required_on_apply":
        raise SkillPackageError(
            f"Skill tool {tool_name} required backup guard needs a source mapping"
        )
    return dict(guard)


def _load_extension(package: Path, origin: str) -> dict[str, Any] | None:
    extension_path = package / "linux-agent.json"
    if not extension_path.exists():
        return None
    if extension_path.is_symlink() or not extension_path.is_file():
        raise SkillPackageError("linux-agent.json must be a regular non-symlink file")
    try:
        extension = json.loads(
            extension_path.read_text(encoding="utf-8"),
            object_pairs_hook=_reject_duplicate_json_keys,
        )
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise SkillPackageError("linux-agent.json is invalid UTF-8 JSON") from exc
    if not isinstance(extension, dict) or set(extension) - {
        "schema_version",
        "package_version",
        "core_api",
        "category",
        "tools",
        "components",
    }:
        raise SkillPackageError("linux-agent.json has unsupported top-level fields")
    schema_version = extension.get("schema_version")
    if type(schema_version) is not int:
        raise SkillPackageError("linux-agent.json schema_version must be an integer")
    if schema_version != 1:
        raise SkillPackageIncompatibleError(
            "linux-agent.json schema_version is incompatible; this core requires version 1"
        )
    if not isinstance(extension.get("package_version"), str) or not extension["package_version"]:
        raise SkillPackageError("linux-agent.json package_version is required")
    core_api = extension.get("core_api")
    if type(core_api) is not int:
        raise SkillPackageError("linux-agent.json core_api must be an integer")
    if core_api != 1:
        raise SkillPackageIncompatibleError(
            "linux-agent.json core_api is incompatible; this core requires API 1"
        )
    category = extension.get("category", "custom")
    if not isinstance(category, str) or not CATEGORY_PATTERN.fullmatch(category):
        raise SkillPackageError("linux-agent.json category is invalid")
    tools = extension.get("tools", [])
    if not isinstance(tools, list) or not all(isinstance(item, dict) for item in tools):
        raise SkillPackageError("linux-agent.json tools must be an array of objects")
    normalized_tools: list[dict[str, Any]] = []
    names: set[str] = set()
    for tool in tools:
        allowed = {
            "name",
            "description",
            "entrypoint",
            "risk",
            "approval_scope",
            "execution",
            "runtime_inputs",
            "guards",
        }
        if set(tool) - allowed:
            raise SkillPackageError("Skill tool has unsupported fields")
        name = tool.get("name")
        if not isinstance(name, str) or not TOOL_NAME_PATTERN.fullmatch(name) or "--" in name:
            raise SkillPackageError("Skill tool name is invalid")
        if name in names:
            raise SkillPackageError(f"duplicate Skill tool: {name}")
        names.add(name)
        description = tool.get("description")
        if not isinstance(description, str) or not description.strip():
            raise SkillPackageError(f"Skill tool {name} description is required")
        entrypoint = tool.get("entrypoint")
        if not isinstance(entrypoint, str) or not entrypoint.startswith("scripts/"):
            raise SkillPackageError(f"Skill tool {name} entrypoint must be under scripts/")
        _regular_package_file(package, entrypoint, f"Skill tool {name} entrypoint")
        risk = tool.get("risk")
        if risk not in RISK_LEVELS:
            raise SkillPackageError(f"Skill tool {name} risk is invalid")
        approval_scope = tool.get("approval_scope", "skill_readonly")
        if not isinstance(approval_scope, str) or not APPROVAL_PATTERN.fullmatch(approval_scope):
            raise SkillPackageError(f"Skill tool {name} approval_scope is invalid")
        execution = tool.get("execution")
        if not isinstance(execution, dict) or set(execution) - {
            "class",
            "capability",
            "dispatch",
            "adapter",
        }:
            raise SkillPackageError(f"Skill tool {name} execution is invalid")
        execution_class = execution.get("class")
        capability = execution.get("capability", "")
        dispatch = execution.get("dispatch", "always")
        if execution_class not in EXECUTION_CLASSES:
            raise SkillPackageError(f"Skill tool {name} execution class is invalid")
        if not isinstance(capability, str) or not CAPABILITY_PATTERN.fullmatch(capability):
            raise SkillPackageError(f"Skill tool {name} capability is invalid")
        if dispatch not in DISPATCH_MODES:
            raise SkillPackageError(f"Skill tool {name} dispatch is invalid")
        adapter = execution.get("adapter")
        if adapter is not None:
            if not isinstance(adapter, str):
                raise SkillPackageError(f"Skill tool {name} adapter is invalid")
            _regular_package_file(package, adapter, f"Skill tool {name} adapter")
        if execution_class == "runner" and (capability or dispatch != "always" or adapter):
            raise SkillPackageError(f"runner tool {name} cannot declare privileged dispatch")
        if execution_class != "runner" and (not capability or not adapter):
            raise SkillPackageError(f"privileged tool {name} requires capability and adapter")
        runtime_inputs = tool.get("runtime_inputs", [])
        guards = tool.get("guards", [])
        if not isinstance(runtime_inputs, list) or not all(
            isinstance(value, str) and value for value in runtime_inputs
        ):
            raise SkillPackageError(f"Skill tool {name} runtime_inputs are invalid")
        if not isinstance(guards, list) or not all(isinstance(value, dict) for value in guards):
            raise SkillPackageError(f"Skill tool {name} guards are invalid")
        guards = [_normalize_guard(value, name) for value in guards]
        normalized_tools.append(
            {
                **tool,
                "approval_scope": approval_scope,
                "execution": {
                    "class": execution_class,
                    "capability": capability,
                    "dispatch": dispatch,
                    **({"adapter": adapter} if adapter else {}),
                },
                "runtime_inputs": runtime_inputs,
                "guards": guards,
            }
        )
    raw_components = extension.get("components", {})
    if not isinstance(raw_components, dict):
        raise SkillPackageError("linux-agent.json components must be an object")
    if set(raw_components) - {"host_helper", "credential_helper", "web"}:
        raise SkillPackageError("linux-agent.json declares an unsupported component")
    components: dict[str, Any] = {}
    host_helper = raw_components.get("host_helper")
    if host_helper is not None:
        if (
            not isinstance(host_helper, dict)
            or "handler" not in host_helper
            or set(host_helper) - {"handler", "policy_asset"}
        ):
            raise SkillPackageError("host_helper component is invalid")
        handler = host_helper.get("handler")
        if not isinstance(handler, str) or not handler.startswith("scripts/"):
            raise SkillPackageError("host_helper handler must be under scripts/")
        _regular_package_file(package, handler, "host_helper handler")
        policy_asset = host_helper.get("policy_asset")
        if policy_asset is not None:
            if not isinstance(policy_asset, str) or not policy_asset.startswith(
                "assets/"
            ):
                raise SkillPackageError(
                    "host_helper policy_asset must be under assets/"
                )
            _regular_package_file(
                package, policy_asset, "host_helper policy asset"
            )
        if not any(
            tool["execution"]["class"] == "host_helper" for tool in normalized_tools
        ):
            raise SkillPackageError("host_helper component has no host_helper tools")
        components["host_helper"] = {
            "handler": handler,
            **({"policy_asset": policy_asset} if policy_asset else {}),
        }
    credential_helper = raw_components.get("credential_helper")
    if credential_helper is not None:
        required_credential_fields = {
            "name", "client", "socket_env", "default_socket"
        }
        if (
            not isinstance(credential_helper, dict)
            or not required_credential_fields.issubset(credential_helper)
            or set(credential_helper)
            - required_credential_fields
            - {
                "service_asset",
                "socket_asset",
                "egress_dropin",
                "install",
                "admin",
                "owned_paths",
            }
        ):
            raise SkillPackageError("credential_helper component is invalid")
        helper_name = credential_helper.get("name")
        client = credential_helper.get("client")
        socket_env = credential_helper.get("socket_env")
        default_socket = credential_helper.get("default_socket")
        if not isinstance(helper_name, str) or not NAME_PATTERN.fullmatch(helper_name):
            raise SkillPackageError("credential_helper name is invalid")
        if not isinstance(client, str) or not client.startswith("scripts/"):
            raise SkillPackageError("credential_helper client must be under scripts/")
        _regular_package_file(package, client, "credential_helper client")
        if not isinstance(socket_env, str) or not ENVIRONMENT_NAME_PATTERN.fullmatch(socket_env):
            raise SkillPackageError("credential_helper socket_env is invalid")
        if not isinstance(default_socket, str):
            raise SkillPackageError("credential_helper default_socket is invalid")
        socket_path = PurePosixPath(default_socket)
        if (
            not socket_path.is_absolute()
            or ".." in socket_path.parts
            or not default_socket.startswith("/run/linux-agent/")
        ):
            raise SkillPackageError("credential_helper default_socket must be under /run/linux-agent")
        for field in ("service_asset", "socket_asset"):
            asset = credential_helper.get(field)
            if asset is None:
                continue
            expected_suffix = ".service" if field == "service_asset" else ".socket"
            if (
                not isinstance(asset, str)
                or not asset.startswith("assets/systemd/")
                or not asset.endswith(expected_suffix)
            ):
                raise SkillPackageError(
                    f"credential_helper {field} must be under assets/systemd/"
                )
            _regular_package_file(package, asset, f"credential_helper {field}")
        service_asset = credential_helper.get("service_asset")
        socket_asset = credential_helper.get("socket_asset")
        egress_dropin = credential_helper.get("egress_dropin")
        if (service_asset is None) != (socket_asset is None):
            raise SkillPackageError(
                "credential_helper service_asset and socket_asset must be declared together"
            )
        if service_asset is not None and (
            PurePosixPath(service_asset).name
            != f"linux-agent-{helper_name}.service"
            or PurePosixPath(socket_asset).name
            != f"linux-agent-{helper_name}.socket"
        ):
            raise SkillPackageError(
                "credential_helper unit asset names must match the component name"
            )
        if egress_dropin is not None and (
            not isinstance(egress_dropin, str)
            or re.fullmatch(r"[0-9]{2}-[a-z0-9][a-z0-9-]{0,61}[.]conf", egress_dropin)
            is None
        ):
            raise SkillPackageError("credential_helper egress_dropin is invalid")
        install = credential_helper.get("install")
        normalized_install = None
        if install is not None:
            if not isinstance(install, dict) or set(install) != {"commands"}:
                raise SkillPackageError("credential_helper install contract is invalid")
            commands = install.get("commands")
            if (
                not isinstance(commands, list)
                or not commands
                or len(commands) > 16
                or not all(isinstance(command, dict) for command in commands)
            ):
                raise SkillPackageError("credential_helper install commands are invalid")
            normalized_commands = []
            for command in commands:
                if set(command) != {"entrypoint", "arguments", "environment"}:
                    raise SkillPackageError(
                        "credential_helper install command is invalid"
                    )
                entrypoint = command.get("entrypoint")
                arguments = command.get("arguments")
                environment = command.get("environment")
                if (
                    not isinstance(entrypoint, str)
                    or not entrypoint.startswith("scripts/")
                    or not isinstance(arguments, list)
                    or len(arguments) > 16
                    or not all(
                        isinstance(argument, str)
                        and 0 < len(argument) <= 128
                        and not any(ord(character) < 32 for character in argument)
                        for argument in arguments
                    )
                    or not isinstance(environment, dict)
                    or len(environment) > 16
                    or any(
                        not isinstance(key, str)
                        or ENVIRONMENT_NAME_PATTERN.fullmatch(key) is None
                        or value
                        not in {"credential_group", "component_egress_dropin"}
                        for key, value in environment.items()
                    )
                    or (
                        "component_egress_dropin" in environment.values()
                        and egress_dropin is None
                    )
                ):
                    raise SkillPackageError(
                        "credential_helper install command is invalid"
                    )
                _regular_package_file(
                    package, entrypoint, "credential_helper install entrypoint"
                )
                normalized_commands.append(
                    {
                        "entrypoint": entrypoint,
                        "arguments": list(arguments),
                        "environment": dict(environment),
                    }
                )
            normalized_install = {"commands": normalized_commands}
        owned_paths = credential_helper.get("owned_paths", [])
        if (
            not isinstance(owned_paths, list)
            or len(owned_paths) > 16
            or not all(isinstance(item, dict) for item in owned_paths)
        ):
            raise SkillPackageError("credential_helper owned_paths are invalid")
        normalized_owned_paths = []
        owned_environments = set()
        for item in owned_paths:
            if set(item) != {"kind", "environment", "default"}:
                raise SkillPackageError("credential_helper owned path is invalid")
            kind = item.get("kind")
            environment = item.get("environment")
            default = item.get("default")
            default_path = PurePosixPath(default) if isinstance(default, str) else None
            if (
                kind != "directory"
                or not isinstance(environment, str)
                or ENVIRONMENT_NAME_PATTERN.fullmatch(environment) is None
                or environment in owned_environments
                or default_path is None
                or not default_path.is_absolute()
                or ".." in default_path.parts
                or not default.startswith(("/etc/linux-agent/", "/var/lib/linux-agent/"))
                or len(default_path.parts) < 4
                or NAME_PATTERN.fullmatch(default_path.name.removesuffix(".d")) is None
            ):
                raise SkillPackageError("credential_helper owned path is invalid")
            owned_environments.add(environment)
            normalized_owned_paths.append(dict(item))
        admin = credential_helper.get("admin")
        normalized_admin = None
        if admin is not None:
            if not isinstance(admin, dict) or set(admin) != {
                "name",
                "entrypoint",
                "environment",
                "commands",
            }:
                raise SkillPackageError("credential_helper admin contract is invalid")
            admin_name = admin.get("name")
            admin_entrypoint = admin.get("entrypoint")
            admin_environment = admin.get("environment")
            admin_commands = admin.get("commands")
            if (
                not isinstance(admin_name, str)
                or NAME_PATTERN.fullmatch(admin_name) is None
                or not isinstance(admin_entrypoint, str)
                or not admin_entrypoint.startswith("scripts/")
                or not isinstance(admin_environment, dict)
                or len(admin_environment) > 16
                or any(
                    not isinstance(key, str)
                    or ENVIRONMENT_NAME_PATTERN.fullmatch(key) is None
                    or value
                    not in {"credential_group", "component_egress_dropin"}
                    for key, value in admin_environment.items()
                )
                or (
                    "component_egress_dropin" in admin_environment.values()
                    and egress_dropin is None
                )
                or not isinstance(admin_commands, list)
                or not admin_commands
                or len(admin_commands) > 32
                or not all(isinstance(command, dict) for command in admin_commands)
            ):
                raise SkillPackageError("credential_helper admin contract is invalid")
            _regular_package_file(
                package, admin_entrypoint, "credential_helper admin entrypoint"
            )
            normalized_admin_commands = []
            admin_command_names = set()
            for command in admin_commands:
                if set(command) != {
                    "name",
                    "operands",
                    "stdin",
                    "activate_systemd",
                }:
                    raise SkillPackageError(
                        "credential_helper admin command is invalid"
                    )
                command_name = command.get("name")
                operands = command.get("operands")
                reads_stdin = command.get("stdin")
                activate_systemd = command.get("activate_systemd")
                if (
                    not isinstance(command_name, str)
                    or NAME_PATTERN.fullmatch(command_name) is None
                    or command_name in admin_command_names
                    or type(operands) is not int
                    or not 0 <= operands <= 4
                    or not isinstance(reads_stdin, bool)
                    or not isinstance(activate_systemd, bool)
                ):
                    raise SkillPackageError(
                        "credential_helper admin command is invalid"
                    )
                admin_command_names.add(command_name)
                normalized_admin_commands.append(dict(command))
            normalized_admin = {
                "name": admin_name,
                "entrypoint": admin_entrypoint,
                "environment": dict(admin_environment),
                "commands": normalized_admin_commands,
            }
        components["credential_helper"] = {
            **credential_helper,
            **({"install": normalized_install} if normalized_install else {}),
            "owned_paths": normalized_owned_paths,
            **({"admin": normalized_admin} if normalized_admin else {}),
        }
    web_component = raw_components.get("web")
    if web_component is not None:
        required_web_fields = {
            "resource",
            "backend",
            "frontend",
            "fragment",
            "navigation",
            "routes",
            "job_actions",
        }
        if (
            not isinstance(web_component, dict)
            or not required_web_fields.issubset(web_component)
            or set(web_component) - required_web_fields - {"error_codes"}
        ):
            raise SkillPackageError("web component is invalid")
        resource = web_component.get("resource")
        if not isinstance(resource, str) or not NAME_PATTERN.fullmatch(resource):
            raise SkillPackageError("web component resource is invalid")
        for field, suffix in (
            ("backend", ".py"),
            ("frontend", ".js"),
            ("fragment", ".html"),
        ):
            value = web_component.get(field)
            if (
                not isinstance(value, str)
                or not value.startswith("assets/web/")
                or not value.endswith(suffix)
            ):
                raise SkillPackageError(
                    f"web component {field} must be an assets/web/{suffix} file"
                )
            _regular_package_file(package, value, f"web component {field}")
        navigation = web_component.get("navigation")
        if not isinstance(navigation, dict) or set(navigation) != {
            "screen",
            "label",
            "icon",
            "key",
            "order",
        }:
            raise SkillPackageError("web component navigation is invalid")
        if (
            not isinstance(navigation.get("screen"), str)
            or not NAME_PATTERN.fullmatch(navigation["screen"])
            or not isinstance(navigation.get("label"), str)
            or not navigation["label"].strip()
            or len(navigation["label"]) > 64
            or not isinstance(navigation.get("icon"), str)
            or not navigation["icon"]
            or len(navigation["icon"]) > 8
            or not isinstance(navigation.get("key"), str)
            or re.fullmatch(r"[1-9]", navigation["key"]) is None
            or isinstance(navigation.get("order"), bool)
            or not isinstance(navigation.get("order"), int)
            or not 0 <= navigation["order"] <= 1000
        ):
            raise SkillPackageError("web component navigation is invalid")
        routes = web_component.get("routes")
        if not isinstance(routes, list) or not routes:
            raise SkillPackageError("web component routes must be a non-empty array")
        normalized_routes = []
        route_keys = set()
        for route in routes:
            if not isinstance(route, dict) or set(route) != {
                "method",
                "path",
                "action",
            }:
                raise SkillPackageError("web component route is invalid")
            method = route.get("method")
            path = route.get("path")
            action = route.get("action")
            if (
                method not in {"GET", "POST"}
                or not isinstance(path, str)
                or WEB_ROUTE_PATTERN.fullmatch(path) is None
                or not isinstance(action, str)
                or CAPABILITY_PATTERN.fullmatch(action) is None
                or not action
            ):
                raise SkillPackageError("web component route is invalid")
            route_key = (method, path)
            if route_key in route_keys:
                raise SkillPackageError("web component contains a duplicate route")
            route_keys.add(route_key)
            normalized_routes.append(dict(route))
        job_actions = web_component.get("job_actions")
        if (
            not isinstance(job_actions, list)
            or not job_actions
            or not all(
                isinstance(action, str) and NAME_PATTERN.fullmatch(action)
                for action in job_actions
            )
            or len(job_actions) != len(set(job_actions))
        ):
            raise SkillPackageError("web component job_actions are invalid")
        error_codes = web_component.get("error_codes", {})
        if (
            not isinstance(error_codes, dict)
            or len(error_codes) > 64
            or any(
                not isinstance(code, str)
                or ERROR_CODE_PATTERN.fullmatch(code) is None
                or not isinstance(spec, dict)
                or set(spec) != {"retryable", "http"}
                or not isinstance(spec.get("retryable"), bool)
                or isinstance(spec.get("http"), bool)
                or not isinstance(spec.get("http"), int)
                or not 400 <= spec["http"] <= 599
                for code, spec in error_codes.items()
            )
        ):
            raise SkillPackageError("web component error_codes are invalid")
        components["web"] = {
            **web_component,
            "navigation": dict(navigation),
            "routes": normalized_routes,
            "job_actions": list(job_actions),
            "error_codes": {code: dict(spec) for code, spec in error_codes.items()},
        }
    if origin == "user":
        if components:
            raise SkillPackageError("user Skills cannot declare components")
        for tool in normalized_tools:
            execution = tool["execution"]
            if (
                execution["class"] != "runner"
                or execution["capability"]
                or tool["approval_scope"] != "skill_readonly"
                or tool["runtime_inputs"]
                or tool["guards"]
            ):
                raise SkillPackageError("user Skill tools must use the unprivileged runner contract")
    return {
        **extension,
        "category": category,
        "tools": normalized_tools,
        "components": components,
    }


def load_package(package: Path, origin: str) -> dict[str, Any]:
    if origin not in {"builtin", "user"}:
        raise SkillPackageError("Skill origin is invalid")
    if package.is_symlink() or not package.is_dir():
        raise SkillPackageError("Skill package must be a real directory")
    legacy_manifest = package / "manifest.json"
    if legacy_manifest.exists() or legacy_manifest.is_symlink():
        raise SkillPackageError(
            "legacy_format_unsupported: manifest.json packages must be migrated with the previous major version"
        )
    for path in package.rglob("*"):
        if path.is_symlink():
            raise SkillPackageError("Skill packages cannot contain symbolic links")
        if not (path.is_file() or path.is_dir()):
            raise SkillPackageError("Skill packages may contain only regular files and directories")
    frontmatter, body = parse_frontmatter(package / "SKILL.md")
    if frontmatter["name"] != package.name:
        raise SkillPackageError("frontmatter name must match the Skill directory")
    extension = _load_extension(package, origin)
    return {
        "name": frontmatter["name"],
        "description": frontmatter["description"],
        "frontmatter": frontmatter,
        "body": body,
        "category": extension["category"] if extension else "custom",
        "tools": extension["tools"] if extension else [],
        "components": extension["components"] if extension else {},
        "extension": extension,
    }


def contract_digest(package: Path, origin: str) -> str:
    loaded = load_package(package, origin)
    contract = {
        "name": loaded["name"],
        "description": loaded["description"],
        "frontmatter": loaded["frontmatter"],
        "category": loaded["category"],
        "tools": loaded["tools"],
        "components": loaded["components"],
        "extension": loaded["extension"],
    }
    encoded = json.dumps(
        contract, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _index_sections(index_path: Path) -> dict[str, dict[str, Any]]:
    try:
        metadata = index_path.stat()
        text = index_path.read_text(encoding="utf-8").replace("\r\n", "\n")
    except (OSError, UnicodeDecodeError) as exc:
        raise SkillPackageError("skills/INDEX.md is missing or not readable UTF-8") from exc
    if index_path.is_symlink() or not stat.S_ISREG(metadata.st_mode):
        raise SkillPackageError("skills/INDEX.md must be a regular non-symlink file")
    sections: dict[str, dict[str, Any]] = {}
    current: str | None = None
    section_lines: list[str] = []

    def finish() -> None:
        nonlocal current, section_lines
        if current is None:
            return
        raw = "\n".join(section_lines).rstrip() + "\n"
        description = ""
        tools: list[dict[str, str]] = []
        refs: set[str] = set()
        for line in section_lines[1:]:
            if line.startswith("> ") and not description:
                description = line[2:].strip()
                continue
            match = INDEX_TOOL_PATTERN.fullmatch(line)
            if not match:
                continue
            ref, tool_description = match.groups()
            if ref.split("/", 1)[0] != current:
                raise SkillPackageError(f"INDEX ref {ref} is in the wrong section")
            if ref in refs:
                raise SkillPackageError(f"duplicate INDEX ref: {ref}")
            refs.add(ref)
            tools.append({"ref": ref, "description": tool_description.strip()})
        sections[current] = {
            "name": current,
            "description": description,
            "tools": tools,
            "section": raw,
            "section_digest": hashlib.sha256(raw.encode("utf-8")).hexdigest(),
        }

    for line in text.splitlines():
        heading = INDEX_HEADING_PATTERN.fullmatch(line)
        if heading:
            finish()
            current = heading.group(1)
            if current in sections:
                raise SkillPackageError(f"duplicate INDEX section: {current}")
            section_lines = [line]
        elif current is not None:
            if line.startswith("## "):
                raise SkillPackageError(f"invalid INDEX section heading: {line}")
            section_lines.append(line)
    finish()
    return sections


def load_index(index_path: Path) -> dict[str, dict[str, Any]]:
    return _index_sections(index_path)


def validate_builtin_root(root: Path, *, strict: bool = False) -> dict[str, Any]:
    findings: list[dict[str, str]] = []
    try:
        sections = load_index(root / "INDEX.md")
    except SkillPackageError as exc:
        severity = "critical" if strict else "warning"
        return {
            "ok": not strict,
            "status": "unavailable",
            "root": os.fspath(root),
            "skills": [],
            "findings": [
                {"severity": severity, "code": "SKILL_INDEX_INVALID", "message": str(exc)}
            ],
        }
    packages = {
        path.name: path
        for path in root.iterdir()
        if path.is_dir() and not path.is_symlink() and NAME_PATTERN.fullmatch(path.name)
    }
    skills: list[dict[str, Any]] = []
    for name, section in sections.items():
        package = packages.pop(name, None)
        if package is None:
            findings.append(
                {
                    "severity": "critical" if strict else "warning",
                    "code": "SKILL_PACKAGE_UNAVAILABLE",
                    "skill": name,
                    "message": "INDEX declares a builtin Skill whose package is not installed",
                }
            )
            skills.append({**section, "origin": "builtin", "state": "unavailable"})
            continue
        try:
            loaded = load_package(package, "builtin")
        except SkillPackageIncompatibleError as exc:
            findings.append(
                {
                    "severity": "critical" if strict else "warning",
                    "code": "SKILL_PACKAGE_INCOMPATIBLE",
                    "skill": name,
                    "message": str(exc),
                }
            )
            skills.append({**section, "origin": "builtin", "state": "incompatible"})
            continue
        except SkillPackageError as exc:
            findings.append(
                {
                    "severity": "critical" if strict else "warning",
                    "code": "SKILL_PACKAGE_INVALID",
                    "skill": name,
                    "message": str(exc),
                }
            )
            skills.append({**section, "origin": "builtin", "state": "invalid"})
            continue
        package_tools = {
            f"{name}/{tool['name']}": tool for tool in loaded["tools"]
        }
        index_tools = {tool["ref"]: tool for tool in section["tools"]}
        contract_valid = True
        if set(package_tools) != set(index_tools):
            contract_valid = False
            findings.append(
                {
                    "severity": "critical" if strict else "warning",
                    "code": "SKILL_INDEX_TOOL_MISMATCH",
                    "skill": name,
                    "message": "INDEX tool refs do not match linux-agent.json",
                }
            )
        for ref in sorted(set(package_tools) & set(index_tools)):
            if package_tools[ref]["description"] != index_tools[ref]["description"]:
                contract_valid = False
                findings.append(
                    {
                        "severity": "critical" if strict else "warning",
                        "code": "SKILL_INDEX_DESCRIPTION_MISMATCH",
                        "ref": ref,
                        "message": "INDEX tool description does not match linux-agent.json",
                    }
                )
        if section["description"] and section["description"] != loaded["description"]:
            contract_valid = False
            findings.append(
                {
                    "severity": "critical" if strict else "warning",
                    "code": "SKILL_INDEX_DESCRIPTION_MISMATCH",
                    "skill": name,
                    "message": "INDEX Skill description does not match SKILL.md",
                }
            )
        if not contract_valid:
            skills.append(
                {
                    **section,
                    "origin": "builtin",
                    "state": "invalid",
                    "package": os.fspath(package),
                }
            )
            continue
        skills.append(
            {
                **section,
                "description": loaded["description"],
                "origin": "builtin",
                "state": "installed",
                "category": loaded["category"],
                "package": os.fspath(package),
                "package_tools": loaded["tools"],
                "components": loaded["components"],
            }
        )
    for name in sorted(packages):
        findings.append(
            {
                "severity": "critical" if strict else "warning",
                "code": "SKILL_INDEX_ENTRY_MISSING",
                "skill": name,
                "message": "installed builtin Skill is not declared in INDEX",
            }
        )
    conflict_owners: dict[tuple[str, str], list[str]] = {}
    for skill in skills:
        if skill.get("state") != "installed":
            continue
        name = skill["name"]
        for tool in skill.get("package_tools", []):
            execution = tool.get("execution", {})
            if execution.get("class") in {"host_helper", "credential_helper"}:
                key = (
                    f"{execution['class']}_capability",
                    execution.get("capability", ""),
                )
                conflict_owners.setdefault(key, []).append(name)
        credential = skill.get("components", {}).get("credential_helper")
        if isinstance(credential, dict):
            for kind, value in (
                ("credential_name", credential.get("name")),
                ("credential_socket", credential.get("default_socket")),
                ("credential_socket_env", credential.get("socket_env")),
                ("credential_admin", credential.get("admin", {}).get("name")),
            ):
                if value:
                    conflict_owners.setdefault((kind, value), []).append(name)
        web = skill.get("components", {}).get("web")
        if isinstance(web, dict):
            for kind, value in (
                ("web_resource", web.get("resource")),
                ("web_screen", web.get("navigation", {}).get("screen")),
                ("web_key", web.get("navigation", {}).get("key")),
            ):
                if value:
                    conflict_owners.setdefault((kind, value), []).append(name)
            for route in web.get("routes", []):
                conflict_owners.setdefault(
                    ("web_route", f"{route['method']} {route['path']}"), []
                ).append(name)
    conflicted: set[str] = set()
    for (kind, value), owners in sorted(conflict_owners.items()):
        unique_owners = sorted(set(owners))
        if len(unique_owners) < 2:
            continue
        conflicted.update(unique_owners)
        findings.append(
            {
                "severity": "critical" if strict else "warning",
                "code": "SKILL_COMPONENT_CONFLICT",
                "skill": ",".join(unique_owners),
                "message": f"builtin Skills declare duplicate {kind}: {value}",
            }
        )
    if conflicted:
        skills = [
            (
                {
                    **skill,
                    "state": "invalid",
                    "package_tools": [],
                    "components": {},
                }
                if skill.get("name") in conflicted
                else skill
            )
            for skill in skills
        ]
    return {
        "ok": not any(item["severity"] == "critical" for item in findings),
        "status": "validated",
        "root": os.fspath(root),
        "skills": skills,
        "findings": findings,
    }


def catalog(builtin_root: Path, user_root: Path | None) -> dict[str, Any]:
    builtin = validate_builtin_root(builtin_root)
    skills = list(builtin["skills"])
    reserved = {skill["name"] for skill in skills}
    findings = list(builtin["findings"])
    if user_root is not None and user_root.exists():
        if user_root.is_symlink() or not user_root.is_dir():
            findings.append(
                {
                    "severity": "warning",
                    "code": "USER_SKILL_ROOT_INVALID",
                    "message": "user Skill root is not a real directory",
                }
            )
        else:
            for package in sorted(user_root.iterdir()):
                if (
                    package.name.startswith(".")
                    or not package.is_dir()
                    or package.is_symlink()
                ):
                    continue
                name = package.name
                if name in reserved:
                    findings.append(
                        {
                            "severity": "warning",
                            "code": "SKILL_NAME_RESERVED",
                            "skill": name,
                            "message": "user Skill conflicts with a reserved builtin name",
                        }
                    )
                    continue
                try:
                    loaded = load_package(package, "user")
                except SkillPackageIncompatibleError as exc:
                    findings.append(
                        {
                            "severity": "warning",
                            "code": "SKILL_PACKAGE_INCOMPATIBLE",
                            "skill": name,
                            "message": str(exc),
                        }
                    )
                    skills.append(
                        {"name": name, "origin": "user", "state": "incompatible", "tools": []}
                    )
                    continue
                except SkillPackageError as exc:
                    findings.append(
                        {
                            "severity": "warning",
                            "code": "SKILL_PACKAGE_INVALID",
                            "skill": name,
                            "message": str(exc),
                        }
                    )
                    skills.append(
                        {"name": name, "origin": "user", "state": "invalid", "tools": []}
                    )
                    continue
                skills.append(
                    {
                        "name": name,
                        "description": loaded["description"],
                        "origin": "user",
                        "state": "installed",
                        "category": "custom",
                        "package": os.fspath(package),
                        "tools": [
                            {
                                "ref": f"{name}/{tool['name']}",
                                "description": tool["description"],
                                **tool,
                            }
                            for tool in loaded["tools"]
                        ],
                    }
                )
    tools: list[dict[str, Any]] = []
    for skill in skills:
        if skill.get("state") != "installed":
            continue
        source_tools = skill.get("package_tools", skill.get("tools", []))
        for tool in source_tools:
            ref = tool.get("ref", f"{skill['name']}/{tool['name']}")
            tools.append(
                {
                    "ref": ref,
                    "skill": skill["name"],
                    "name": tool.get("name", ref.split("/", 1)[1]),
                    "description": tool["description"],
                    "risk": tool.get("risk", "unavailable"),
                    "approval_scope": tool.get("approval_scope", ""),
                    "execution": tool.get("execution", {}),
                    "runtime_inputs": tool.get("runtime_inputs", []),
                    "guards": tool.get("guards", []),
                    "origin": skill["origin"],
                    "state": skill["state"],
                    "category": skill.get("category", "custom"),
                }
            )
    return {
        "ok": not any(item["severity"] == "critical" for item in findings),
        "status": "listed",
        "skills": skills,
        "tools": sorted(tools, key=lambda item: item["ref"]),
        "findings": findings,
    }


def _tool_result(package: Path, origin: str, ref: str) -> dict[str, Any]:
    try:
        loaded = load_package(package, origin)
        skill_name, separator, tool_name = ref.partition("/")
        if not separator or skill_name != loaded["name"]:
            raise SkillPackageError("tool ref does not belong to this Skill")
        matches = [tool for tool in loaded["tools"] if tool["name"] == tool_name]
        if len(matches) != 1:
            raise SkillPackageError("tool ref is not declared by linux-agent.json")
        return {
            "ok": True,
            "status": "resolved",
            "ref": ref,
            "skill": loaded["name"],
            "origin": origin,
            "package": os.fspath(package),
            "components": loaded["components"],
            "tool": matches[0],
        }
    except SkillPackageIncompatibleError as exc:
        return {
            "ok": False,
            "status": "skill_package_incompatible",
            "code": "skill_package_incompatible",
            "ref": ref,
            "error": str(exc),
        }
    except SkillPackageError as exc:
        return {
            "ok": False,
            "status": "invalid",
            "code": "invalid_skill_package",
            "ref": ref,
            "error": str(exc),
        }


def _discovery_tokens(value: str) -> set[str]:
    lowered = value.casefold()
    tokens = set(re.findall(r"[a-z0-9][a-z0-9-]{2,}", lowered))
    for sequence in re.findall(r"[\u3400-\u9fff]+", lowered):
        if len(sequence) == 1:
            tokens.add(sequence)
        else:
            tokens.update(sequence[index : index + 2] for index in range(len(sequence) - 1))
    return tokens


def discover_catalog(available: dict[str, Any], request: str) -> dict[str, Any]:
    if not isinstance(available, dict) or not isinstance(available.get("skills"), list):
        raise SkillPackageError("Skill catalog must contain a skills array")
    request_lower = request.casefold()
    generic_tokens = {
        "使用",
        "只读",
        "固定",
        "工作",
        "工具",
        "执行",
        "支持",
        "文件",
        "查看",
        "检查",
        "状态",
        "系统",
        "脚本",
        "调用",
        "读取",
        "返回",
    }
    request_tokens = _discovery_tokens(request) - generic_tokens
    explicit_names = {
        skill["name"]
        for skill in available["skills"]
        if re.search(
            rf"(?<![a-z0-9-]){re.escape(skill['name'])}(?:/[a-z0-9-]+)?(?![a-z0-9-])",
            request_lower,
        )
    }
    candidates: list[dict[str, Any]] = []
    for skill in available["skills"]:
        name = skill["name"]
        tools = skill.get("tools", [])
        tool_coverage = max(
            (
                len(
                    request_tokens
                    & (_discovery_tokens(tool.get("description", "")) - generic_tokens)
                )
                for tool in tools
            ),
            default=0,
        )
        description_coverage = len(
            request_tokens
            & (_discovery_tokens(skill.get("description", "")) - generic_tokens)
        )
        coverage = tool_coverage if tools else description_coverage
        score = coverage
        if name in explicit_names:
            score += 100
        if coverage >= 2 or name in explicit_names:
            candidates.append(
                {
                    "name": name,
                    "state": skill.get("state", "unavailable"),
                    "score": score,
                    "coverage": coverage,
                }
            )
    if explicit_names:
        candidates = [item for item in candidates if item["name"] in explicit_names]
    elif candidates:
        best_coverage = max(item["coverage"] for item in candidates)
        candidates = [item for item in candidates if item["coverage"] == best_coverage]
    candidates.sort(key=lambda item: (-item["score"], item["name"]))
    for item in candidates:
        item.pop("coverage", None)
    return {"ok": True, "status": "discovered", "candidates": candidates}


def discover(builtin_root: Path, user_root: Path | None, request: str) -> dict[str, Any]:
    return discover_catalog(catalog(builtin_root, user_root), request)


def _result(package: Path, origin: str) -> dict[str, Any]:
    try:
        loaded = load_package(package, origin)
    except SkillPackageIncompatibleError as exc:
        return {
            "ok": False,
            "status": "skill_package_incompatible",
            "code": "skill_package_incompatible",
            "package": os.fspath(package),
            "error": str(exc),
        }
    except SkillPackageError as exc:
        return {
            "ok": False,
            "status": "invalid",
            "code": "invalid_skill_package",
            "package": os.fspath(package),
            "error": str(exc),
        }
    return {"ok": True, "status": "validated", "package": os.fspath(package), **loaded}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "command",
        choices=(
            "inspect",
            "validate",
            "validate-root",
            "catalog",
            "tool",
            "index",
            "discover",
            "discover-catalog",
            "digest",
        ),
    )
    parser.add_argument("package")
    parser.add_argument("ref", nargs="?")
    parser.add_argument("--origin", choices=("builtin", "user"), default="builtin")
    parser.add_argument("--user-root")
    parser.add_argument("--request", default="")
    parser.add_argument("--strict", action="store_true")
    arguments = parser.parse_args()
    package = Path(arguments.package)
    if arguments.command == "validate-root":
        result = validate_builtin_root(package, strict=arguments.strict)
        print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))
        return 0 if result["ok"] else 1
    if arguments.command == "catalog":
        result = catalog(package, Path(arguments.user_root) if arguments.user_root else None)
        print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))
        return 0 if result["ok"] else 1
    if arguments.command == "discover":
        result = discover(
            package,
            Path(arguments.user_root) if arguments.user_root else None,
            arguments.request,
        )
        print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))
        return 0
    if arguments.command == "discover-catalog":
        try:
            supplied_catalog = json.load(
                sys.stdin,
                object_pairs_hook=_reject_duplicate_json_keys,
            )
            result = discover_catalog(supplied_catalog, arguments.request)
        except (json.JSONDecodeError, SkillPackageError) as exc:
            result = {
                "ok": False,
                "status": "invalid",
                "code": "invalid_skill_package",
                "error": str(exc),
            }
        print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))
        return 0 if result["ok"] else 1
    if arguments.command == "digest":
        try:
            result = {
                "ok": True,
                "status": "digested",
                "name": package.name,
                "contract_digest": contract_digest(package, arguments.origin),
            }
        except SkillPackageError as exc:
            result = {"ok": False, "status": "invalid", "error": str(exc)}
        print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))
        return 0 if result["ok"] else 1
    if arguments.command == "index":
        try:
            result = {"ok": True, "status": "parsed", "skills": list(load_index(package).values())}
        except SkillPackageError as exc:
            result = {"ok": False, "status": "invalid", "error": str(exc)}
        print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))
        return 0 if result["ok"] else 1
    if arguments.command == "tool":
        result = _tool_result(package, arguments.origin, arguments.ref or "")
        print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))
        return 0 if result["ok"] else 1
    result = _result(package, arguments.origin)
    if arguments.command == "inspect" or not result["ok"]:
        print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))
    else:
        print(json.dumps({key: value for key, value in result.items() if key != "body"}, ensure_ascii=False, separators=(",", ":")))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
