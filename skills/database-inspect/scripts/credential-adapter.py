#!/usr/bin/env python3
"""Build fixed credential-helper requests for database-inspect."""

from __future__ import annotations

import argparse
import json
import re


PROFILE_PATTERN = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
REFERENCE_PATTERN = re.compile(r"^[0-9a-f]{32}$")
OPERATIONS = {
    "instance-health": "database.health",
    "instance-metrics": "database.metrics",
}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("tool", choices=tuple(OPERATIONS))
    parser.add_argument("arguments")
    options = parser.parse_args()
    try:
        arguments = json.loads(options.arguments)
    except json.JSONDecodeError:
        arguments = None
    if not isinstance(arguments, dict):
        result = {"ok": False, "status": "helper_rejected", "error": "Skill arguments must be a JSON object"}
    else:
        profile_id = arguments.get("profile_id")
        credential_ref = arguments.get("credential_ref", "")
        valid = (
            not (set(arguments) - {"profile_id", "credential_ref"})
            and isinstance(profile_id, str)
            and PROFILE_PATTERN.fullmatch(profile_id) is not None
            and isinstance(credential_ref, str)
            and (not credential_ref or REFERENCE_PATTERN.fullmatch(credential_ref) is not None)
        )
        if not valid:
            result = {"ok": False, "status": "helper_rejected", "error": "database helper arguments are invalid"}
        else:
            result = {
                "ok": True,
                "dispatch": "helper",
                "operation": OPERATIONS[options.tool],
                "params": {"profile_id": profile_id, "credential_ref": credential_ref},
                "summary": f"Run fixed {OPERATIONS[options.tool]} query for profile {profile_id}",
            }
    print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
