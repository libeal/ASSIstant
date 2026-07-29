#!/usr/bin/env python3
"""Build fixed host-helper requests for network-ops-tools."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


def reject(message: str) -> dict:
    return {"ok": False, "status": "helper_rejected", "error": message}


def firewall(arguments: dict) -> dict:
    action = arguments.get("action", "status")
    apply = arguments.get("apply", False)
    if not isinstance(action, str) or not isinstance(apply, bool):
        return reject("firewall action/apply types are invalid")
    action = action.casefold()
    if not apply and action in {"status", "plan", "apply"}:
        return {"ok": True, "dispatch": "runner"}
    if action != "apply" or not apply or arguments.get("confirm") != "APPLY_FIREWALL_CHANGE":
        return reject("firewall apply requires apply=true and its confirmation token")
    rule = arguments.get("rule", {})
    if not isinstance(rule, dict):
        return reject("firewall rule must be an object")
    params = {
        "backend": arguments.get("backend", "ufw"),
        "decision": rule.get("decision", arguments.get("decision", "allow")),
        "protocol": rule.get("protocol", arguments.get("protocol", "tcp")),
        "port": rule.get("port", arguments.get("port", 0)),
        "source": rule.get("source", arguments.get("source", "any")),
    }
    return {"ok": True, "dispatch": "helper", "operation": "firewall.apply", "params": params}


def hosts(arguments: dict) -> dict:
    action = arguments.get("action", "read")
    apply = arguments.get("apply", False)
    if not isinstance(action, str) or not isinstance(apply, bool):
        return reject("hosts action/apply types are invalid")
    action = action.casefold()
    runner_actions = {"read", "search", "plan-add", "plan-remove", "add", "remove"}
    if not apply and action in runner_actions:
        return {"ok": True, "dispatch": "runner"}
    if action not in {"add", "remove"} or not apply or arguments.get("confirm") != "APPLY_HOSTS_CHANGE":
        return reject("hosts apply requires apply=true and its confirmation token")
    target = Path(arguments.get("path", "/etc/hosts"))
    if target != Path("/etc/hosts") or target.is_symlink() or not target.is_file():
        return reject("host helper only permits the regular /etc/hosts target")
    hostnames = arguments.get("hostnames")
    if not isinstance(hostnames, list):
        hostname = arguments.get("hostname")
        hostnames = [hostname] if isinstance(hostname, str) and hostname else []
    params = {
        "action": action,
        "ip": arguments.get("ip", ""),
        "hostnames": hostnames,
        "hostname": arguments.get("hostname", arguments.get("query", "")),
        "merge": arguments.get("merge", False),
        "expected_sha256": hashlib.sha256(target.read_bytes()).hexdigest(),
    }
    return {"ok": True, "dispatch": "helper", "operation": "hosts.apply", "params": params}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("tool", choices=("firewall", "hosts-file-editor"))
    parser.add_argument("arguments")
    options = parser.parse_args()
    try:
        arguments = json.loads(options.arguments)
    except json.JSONDecodeError:
        arguments = None
    if not isinstance(arguments, dict):
        result = reject("Skill arguments must be a JSON object")
    elif options.tool == "firewall":
        result = firewall(arguments)
    else:
        result = hosts(arguments)
    print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
