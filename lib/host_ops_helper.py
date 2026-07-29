#!/usr/bin/env python3
"""Generic root dispatcher for signed builtin Skill host capabilities."""

from __future__ import annotations

import argparse
import hashlib
import hmac
import importlib.util
import json
import os
import re
import socket
import stat
import sys
from pathlib import Path
from types import ModuleType

from helper_protocol import (
    PROTOCOL_VERSION,
    ProtocolError,
    allowed_peer_uid,
    build_request,
    client_request,
    receive_json,
    require_peer_uid,
    runtime_shared_lock,
    send_json,
    systemd_listener,
    validate_request,
)
from skill_package import (
    contract_digest,
    validate_builtin_root,
)


CAPABILITY_PATTERN = re.compile(
    r"^[a-z][a-z0-9-]*(?:\.[a-z][a-z0-9-]*)+$"
)


class HostHelperError(ProtocolError):
    """Raised when a package cannot safely register a host capability."""


def _strict_json(path: Path) -> dict[str, object]:
    def reject_duplicates(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f"duplicate JSON key: {key}")
            result[key] = value
        return result

    try:
        value = json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=reject_duplicates,
            parse_constant=lambda item: (_ for _ in ()).throw(ValueError(item)),
        )
    except (OSError, UnicodeError, ValueError, json.JSONDecodeError) as exc:
        raise HostHelperError(f"signed release manifest is invalid: {exc}") from exc
    if not isinstance(value, dict):
        raise HostHelperError("signed release manifest must be an object")
    return value


def _trusted_tree(root: Path) -> None:
    """Require an immutable tree owned by root in production.

    Source-mode tests run the helper module as an ordinary user, so that user's
    UID is accepted only when the helper itself is not privileged.
    """

    accepted_uid = 0 if os.geteuid() == 0 else os.geteuid()
    for path in (root, *root.rglob("*")):
        try:
            metadata = path.lstat()
        except OSError as exc:
            raise HostHelperError(f"host component path is unavailable: {path}") from exc
        if stat.S_ISLNK(metadata.st_mode):
            raise HostHelperError("host component tree cannot contain symbolic links")
        if not (stat.S_ISDIR(metadata.st_mode) or stat.S_ISREG(metadata.st_mode)):
            raise HostHelperError("host component tree contains an unsafe file type")
        if metadata.st_uid != accepted_uid:
            raise HostHelperError("host component tree has an untrusted owner")
        if metadata.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
            raise HostHelperError("host component tree must not be group/world writable")


def _manifest_contracts() -> tuple[dict[str, object] | None, Path | None]:
    raw = os.environ.get("LINUX_AGENT_RELEASE_MANIFEST", "").strip()
    if not raw:
        return None, None
    path = Path(raw)
    if path.is_symlink() or not path.is_file():
        raise HostHelperError("signed release manifest is unavailable")
    metadata = path.stat()
    accepted_uid = 0 if os.geteuid() == 0 else os.geteuid()
    if metadata.st_uid != accepted_uid or metadata.st_mode & (
        stat.S_IWGRP | stat.S_IWOTH
    ):
        raise HostHelperError("signed release manifest metadata is untrusted")
    manifest = _strict_json(path)
    if manifest.get("schema_version") != 2 or not isinstance(
        manifest.get("skills"), dict
    ):
        raise HostHelperError("signed release manifest schema v2 is required")
    return manifest, path


def _verify_contract_digest(
    package: Path, name: str, manifest: dict[str, object] | None
) -> None:
    if manifest is None:
        return
    skills = manifest["skills"]
    entry = skills.get(name) if isinstance(skills, dict) else None
    expected = entry.get("contract_digest") if isinstance(entry, dict) else None
    if not isinstance(expected, str) or re.fullmatch(r"[0-9a-f]{64}", expected) is None:
        raise HostHelperError(f"host Skill {name} has no signed contract digest")
    if not hmac.compare_digest(contract_digest(package, "builtin"), expected):
        raise HostHelperError(f"host Skill {name} contract digest mismatch")


def _builtin_skills_root() -> Path:
    configured = os.environ.get("LINUX_AGENT_BUILTIN_SKILLS_DIR", "").strip()
    if configured:
        return Path(configured)
    root = Path(os.environ.get("LINUX_AGENT_ROOT", "/opt/linux-agent/current"))
    return root / "skills"


def _capability_registry() -> dict[str, tuple[Path, str]]:
    skills_root = _builtin_skills_root()
    if skills_root.is_symlink() or not skills_root.is_dir():
        raise HostHelperError("builtin Skill root is unavailable")
    index_path = skills_root / "INDEX.md"
    _trusted_tree(index_path)
    validation = validate_builtin_root(skills_root)
    release_manifest, _manifest_path = _manifest_contracts()
    registry: dict[str, tuple[Path, str]] = {}
    conflicts: set[str] = set()
    for skill in validation["skills"]:
        if skill.get("state") != "installed":
            continue
        name = skill["name"]
        package = Path(skill["package"])
        component = skill["components"].get("host_helper")
        if not isinstance(component, dict):
            continue
        try:
            _verify_contract_digest(package, name, release_manifest)
            _trusted_tree(package)
        except HostHelperError:
            continue
        handler = package / component["handler"]
        for tool in skill["package_tools"]:
            execution = tool["execution"]
            if execution["class"] != "host_helper":
                continue
            capability = execution["capability"]
            if capability in conflicts:
                continue
            if capability in registry:
                registry.pop(capability)
                conflicts.add(capability)
                continue
            registry[capability] = (handler, name)
    return registry


def _load_handler(path: Path, package_name: str) -> ModuleType:
    module_name = (
        "linux_agent_host_component_"
        + package_name.replace("-", "_")
        + "_"
        + hashlib.sha256(os.fspath(path).encode("utf-8")).hexdigest()[:12]
    )
    spec = importlib.util.spec_from_file_location(module_name, path)
    if spec is None or spec.loader is None:
        raise HostHelperError("host component loader is unavailable")
    module = importlib.util.module_from_spec(spec)
    package_scripts = os.fspath(path.parent)
    sys.path.insert(0, package_scripts)
    try:
        spec.loader.exec_module(module)
    except Exception as exc:
        raise HostHelperError("host component could not be loaded") from exc
    finally:
        try:
            sys.path.remove(package_scripts)
        except ValueError:
            pass
    if not callable(getattr(module, "dispatch", None)):
        raise HostHelperError("host component has no dispatch function")
    return module


def dispatch_capability(
    operation: str, params: dict[str, object]
) -> dict[str, object]:
    if CAPABILITY_PATTERN.fullmatch(operation) is None:
        raise HostHelperError("host helper capability is invalid")
    try:
        handler_path, package_name = _capability_registry()[operation]
    except KeyError as exc:
        raise HostHelperError("unsupported host helper capability") from exc
    module = _load_handler(handler_path, package_name)
    response = module.dispatch(operation, params)
    if (
        not isinstance(response, dict)
        or response.get("operation") != operation
        or not isinstance(response.get("ok"), bool)
    ):
        raise HostHelperError("host component returned an invalid result")
    return response


def _error_response(exc: Exception, request_id: str) -> dict[str, object]:
    code = getattr(exc, "code", "")
    if not isinstance(code, str) or re.fullmatch(r"[a-z][a-z0-9_]{0,63}", code) is None:
        code = "helper_rejected" if isinstance(exc, ProtocolError) else "helper_failed"
    return {
        "ok": False,
        "status": code,
        "code": code,
        "error": str(exc),
        "protocol_version": PROTOCOL_VERSION,
        "request_id": request_id,
    }


def handle_connection(connection: socket.socket, expected_uid: int) -> None:
    request_id = ""
    try:
        require_peer_uid(connection, expected_uid)
        request = receive_json(connection)
        operation, params, _summary, request_id = validate_request(request)
        if operation == "ping":
            if params:
                raise HostHelperError("host helper ping does not accept params")
            response = {"ok": True, "status": "ready", "helper": "host-dispatcher"}
        else:
            with runtime_shared_lock():
                response = dispatch_capability(operation, params)
        response.update(
            {"protocol_version": PROTOCOL_VERSION, "request_id": request_id}
        )
    except Exception as exc:
        response = _error_response(exc, request_id)
    send_json(connection, response)


def serve() -> int:
    expected_uid = allowed_peer_uid("linux-agent")
    listener = systemd_listener()
    while True:
        connection, _ = listener.accept()
        with connection:
            connection.settimeout(15.0)
            handle_connection(connection, expected_uid)


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("serve")
    request_parser = subparsers.add_parser("request")
    request_parser.add_argument("--socket", required=True)
    request_parser.add_argument("operation")
    request_parser.add_argument("--params", required=True)
    request_parser.add_argument("--summary", required=True)
    arguments = parser.parse_args()
    if arguments.command == "serve":
        if os.geteuid() != 0:
            raise SystemExit("host helper must run as root")
        return serve()
    if (
        arguments.operation != "ping"
        and CAPABILITY_PATTERN.fullmatch(arguments.operation) is None
    ):
        print("invalid host helper capability", file=sys.stderr)
        return 125
    try:
        params = json.loads(arguments.params)
        request = build_request(
            arguments.operation, params, summary=arguments.summary
        )
        response = client_request(arguments.socket, request)
    except (OSError, ProtocolError, json.JSONDecodeError) as exc:
        print(str(exc), file=sys.stderr)
        return 125
    print(json.dumps(response, ensure_ascii=False, separators=(",", ":")))
    return 0 if response.get("ok") else 1


if __name__ == "__main__":
    raise SystemExit(main())
