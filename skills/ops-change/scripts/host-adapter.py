#!/usr/bin/env python3
"""Build fixed host-helper requests for ops-change."""

from __future__ import annotations

import argparse
import json
import re


UNIT_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9:_.@-]{0,254}\.service$")
DIGEST_PATTERN = re.compile(r"^[0-9a-f]{64}$")


def reject(message: str) -> dict:
    return {"ok": False, "status": "helper_rejected", "error": message}


def service_restart(arguments: dict) -> dict:
    action = arguments.get("action", "read")
    apply = arguments.get("apply", False)
    if not isinstance(action, str) or not isinstance(apply, bool):
        return reject("service restart action/apply types are invalid")
    action = action.casefold()
    if not apply and action in {"read", "plan"}:
        return {"ok": True, "dispatch": "runner"}
    allowed = {"action", "unit", "apply", "confirm", "preflight_sha256"}
    if set(arguments) - allowed:
        return reject("service restart arguments contain unsupported fields")
    unit = arguments.get("unit")
    digest = arguments.get("preflight_sha256")
    if (
        action != "apply"
        or not apply
        or arguments.get("confirm") != "RESTART_SERVICE"
        or not isinstance(unit, str)
        or UNIT_PATTERN.fullmatch(unit) is None
        or not isinstance(digest, str)
        or DIGEST_PATTERN.fullmatch(digest) is None
    ):
        return reject("service restart apply contract is invalid")
    return {
        "ok": True,
        "dispatch": "helper",
        "operation": "service.restart",
        "params": {
            "unit": unit,
            "apply": True,
            "confirm": "RESTART_SERVICE",
            "preflight_sha256": digest,
        },
    }


def systemd_dropin(arguments: dict) -> dict:
    action = arguments.get("action", "plan")
    apply = arguments.get("apply", False)
    if not isinstance(action, str) or not isinstance(apply, bool):
        return reject("systemd drop-in action/apply types are invalid")
    action = action.casefold()
    if not apply and action == "plan":
        return {"ok": True, "dispatch": "runner"}
    allowed = {"action", "unit", "resources", "apply", "preflight_sha256"}
    resources = arguments.get("resources")
    unit = arguments.get("unit")
    digest = arguments.get("preflight_sha256")
    if (
        set(arguments) - allowed
        or action != "apply"
        or not apply
        or not isinstance(unit, str)
        or UNIT_PATTERN.fullmatch(unit) is None
        or not isinstance(digest, str)
        or DIGEST_PATTERN.fullmatch(digest) is None
        or not isinstance(resources, dict)
        or not resources
        or set(resources) - {"cpu_percent", "memory_bytes", "tasks", "restart_sec"}
    ):
        return reject("systemd drop-in apply contract is invalid")
    return {
        "ok": True,
        "dispatch": "helper",
        "operation": "systemd.dropin.apply",
        "params": {
            "unit": unit,
            "resources": resources,
            "apply": True,
            "preflight_sha256": digest,
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("tool", choices=("service-restart", "systemd-dropin"))
    parser.add_argument("arguments")
    options = parser.parse_args()
    try:
        arguments = json.loads(options.arguments)
    except json.JSONDecodeError:
        arguments = None
    if not isinstance(arguments, dict):
        result = reject("Skill arguments must be a JSON object")
    elif options.tool == "service-restart":
        result = service_restart(arguments)
    else:
        result = systemd_dropin(arguments)
    print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
