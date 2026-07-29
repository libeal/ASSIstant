#!/usr/bin/env python3
"""Strict read/plan implementation shared by the ops-change Skill and host helper."""

from __future__ import annotations

import difflib
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
from pathlib import Path


MAX_OUTPUT = 65_536
ACCOUNT_FILE_LIMIT = 1024 * 1024
PASSWD_PATH = Path("/etc/passwd")
GROUP_PATH = Path("/etc/group")
PACKAGE_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9+._:@-]{0,127}$")
UNIT_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9:_.@-]{0,254}\.service$")
CRON_NAME_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")
TIMER_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9:_.@-]{0,254}\.timer$")
MARKER_LIMIT = 2 * 1024 * 1024
TOOL_PATHS = {
    "systemctl": ("/usr/bin/systemctl", "/bin/systemctl"),
    "apt-get": ("/usr/bin/apt-get",),
    "apt": ("/usr/bin/apt",),
    "dpkg-query": ("/usr/bin/dpkg-query",),
    "dnf": ("/usr/bin/dnf", "/bin/dnf"),
    "rpm": ("/usr/bin/rpm", "/bin/rpm"),
    "who": ("/usr/bin/who", "/bin/who"),
}
SYSTEMD_SHOW_PROPERTIES = (
    "LoadState",
    "ActiveState",
    "SubState",
    "UnitFileState",
    "FragmentPath",
    "NeedDaemonReload",
    "ExecMainPID",
    "ActiveEnterTimestampMonotonic",
)
TIMER_PROPERTIES = frozenset(
    {
        "OnCalendar",
        "OnBootSec",
        "OnStartupSec",
        "OnUnitActiveSec",
        "OnUnitInactiveSec",
        "RandomizedDelaySec",
        "AccuracySec",
        "Persistent",
    }
)
RESOURCE_KEYS = {
    "cpu_percent": ("CPUQuota", 1, 1000),
    "memory_bytes": ("MemoryMax", 1024 * 1024, 9_007_199_254_740_991),
    "tasks": ("TasksMax", 1, 1_000_000),
    "restart_sec": ("RestartSec", 0, 3600),
}


class OpsChangeError(ValueError):
    """A request falls outside the fixed ops-change contract."""


def emit(payload: dict[str, object]) -> None:
    print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))


def _tool(name: str) -> str | None:
    for candidate in TOOL_PATHS[name]:
        path = Path(candidate)
        try:
            metadata = path.stat()
        except OSError:
            continue
        if stat.S_ISREG(metadata.st_mode) and os.access(path, os.X_OK):
            return candidate
    return None


def _run(argv: list[str], timeout: int = 15) -> dict[str, object]:
    environment = {
        "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
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
    except (OSError, subprocess.TimeoutExpired) as exc:
        return {"ok": False, "exit_code": None, "stdout": "", "stderr": str(exc)}
    return {
        "ok": completed.returncode == 0,
        "exit_code": completed.returncode,
        "stdout": completed.stdout[:MAX_OUTPUT].decode("utf-8", errors="replace"),
        "stderr": completed.stderr[:MAX_OUTPUT].decode("utf-8", errors="replace"),
    }


def _object(raw: str) -> dict[str, object]:
    def reject_duplicates(pairs: list[tuple[str, object]]) -> dict[str, object]:
        result: dict[str, object] = {}
        for key, value in pairs:
            if key in result:
                raise OpsChangeError(f"duplicate JSON key: {key}")
            result[key] = value
        return result

    try:
        value = json.loads(
            raw,
            object_pairs_hook=reject_duplicates,
            parse_constant=lambda constant: (_ for _ in ()).throw(
                OpsChangeError(f"invalid JSON constant: {constant}")
            ),
        )
    except (json.JSONDecodeError, TypeError) as exc:
        raise OpsChangeError(f"arguments must be valid JSON: {exc}") from exc
    if not isinstance(value, dict):
        raise OpsChangeError("arguments must be a JSON object")
    return value


def _fields(args: dict[str, object], allowed: set[str]) -> None:
    unknown = sorted(set(args) - allowed)
    if unknown:
        raise OpsChangeError(f"unsupported fields: {', '.join(unknown)}")


def _integer(value: object, name: str, minimum: int, maximum: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not minimum <= value <= maximum:
        raise OpsChangeError(f"{name} must be an integer in {minimum}..{maximum}")
    return value


def _string(value: object, name: str, *, maximum: int = 4096) -> str:
    if not isinstance(value, str) or not value or len(value) > maximum or "\x00" in value:
        raise OpsChangeError(f"{name} must be a non-empty bounded string")
    return value


def _single_line_string(value: object, name: str, *, maximum: int = 4096) -> str:
    text = _string(value, name, maximum=maximum)
    if "\n" in text or "\r" in text:
        raise OpsChangeError(f"{name} must be a single-line string")
    return text


def normalize_unit(value: object, *, allow_timer: bool = False) -> str:
    unit = _string(value, "unit", maximum=256)
    pattern = TIMER_PATTERN if allow_timer else UNIT_PATTERN
    if pattern.fullmatch(unit) is None:
        suffix = ".timer" if allow_timer else ".service"
        raise OpsChangeError(f"unit must be an exact safe {suffix} name")
    return unit


def normalize_resources(value: object) -> dict[str, int]:
    if not isinstance(value, dict) or not value:
        raise OpsChangeError("resources must be a non-empty object")
    _fields(value, set(RESOURCE_KEYS))
    normalized: dict[str, int] = {}
    for key, (_property, minimum, maximum) in RESOURCE_KEYS.items():
        if key in value:
            normalized[key] = _integer(value[key], key, minimum, maximum)
    return normalized


def render_dropin(resources: dict[str, int]) -> bytes:
    lines = ["# Managed by linux-agent. Do not edit in place.", "[Service]"]
    for key, (property_name, _minimum, _maximum) in RESOURCE_KEYS.items():
        if key not in resources:
            continue
        value = resources[key]
        if key == "cpu_percent":
            rendered = f"{value}%"
        elif key == "restart_sec":
            rendered = f"{value}s"
        else:
            rendered = str(value)
        lines.append(f"{property_name}={rendered}")
    return ("\n".join(lines) + "\n").encode("utf-8")


def _systemctl_show(unit: str, properties: tuple[str, ...]) -> dict[str, str]:
    systemctl = _tool("systemctl")
    if systemctl is None:
        raise OpsChangeError("systemctl is unavailable")
    argv = [systemctl, "show", unit, "--no-pager"]
    argv.extend(f"--property={name}" for name in properties)
    result = _run(argv)
    if not result["ok"]:
        raise OpsChangeError(str(result["stderr"] or "systemctl show failed").strip())
    values: dict[str, str] = {}
    for line in str(result["stdout"]).splitlines():
        key, separator, value = line.partition("=")
        if separator and key in properties:
            values[key] = value
    for name in properties:
        values.setdefault(name, "")
    return values


def service_preflight(unit: str) -> tuple[dict[str, str], str]:
    state = _systemctl_show(unit, SYSTEMD_SHOW_PROPERTIES)
    payload = {"kind": "service-restart", "unit": unit, "state": state}
    digest = hashlib.sha256(
        json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()
    return state, digest


def dropin_path(unit: str) -> Path:
    return Path("/etc/systemd/system") / f"{unit}.d" / "90-linux-agent-resources.conf"


def dropin_preflight(unit: str) -> tuple[dict[str, object], str]:
    state = _systemctl_show(unit, ("LoadState", "FragmentPath", "NeedDaemonReload"))
    target = dropin_path(unit)
    if target.is_symlink():
        raise OpsChangeError("managed drop-in target must not be a symbolic link")
    try:
        content = target.read_bytes()
    except FileNotFoundError:
        content = None
    except OSError as exc:
        raise OpsChangeError(f"managed drop-in cannot be read: {exc}") from exc
    if content is not None and len(content) > MARKER_LIMIT:
        raise OpsChangeError("managed drop-in exceeds the size limit")
    current_sha = hashlib.sha256(content).hexdigest() if content is not None else None
    payload: dict[str, object] = {
        "kind": "systemd-dropin",
        "unit": unit,
        "state": state,
        "target": os.fspath(target),
        "current_sha256": current_sha,
    }
    digest = hashlib.sha256(
        json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()
    return payload, digest


def package_query(args: dict[str, object]) -> dict[str, object]:
    _fields(args, {"action", "packages", "limit"})
    action = args.get("action")
    if action not in {"installed", "upgradable"}:
        raise OpsChangeError("action must be installed or upgradable")
    limit = _integer(args.get("limit", 100), "limit", 1, 500)
    requested = args.get("packages", [])
    if not isinstance(requested, list) or len(requested) > 64:
        raise OpsChangeError("packages must be an array with at most 64 entries")
    packages = []
    for item in requested:
        name = _string(item, "package", maximum=128)
        if PACKAGE_PATTERN.fullmatch(name) is None:
            raise OpsChangeError(f"invalid package name: {name}")
        packages.append(name)

    dpkg_query = _tool("dpkg-query")
    dnf = _tool("dnf")
    rpm = _tool("rpm")
    if dpkg_query:
        if action == "installed":
            argv = [dpkg_query, "-W", "-f=${binary:Package}\t${Version}\t${db:Status-Abbrev}\\n"]
            argv.extend(packages)
        else:
            apt = _tool("apt")
            if apt is None:
                raise OpsChangeError("apt is unavailable")
            argv = [apt, "list", "--upgradable"]
            argv.extend(packages)
        result = _run(argv, timeout=20)
        backend = "apt"
    elif dnf and rpm:
        if action == "installed":
            argv = [rpm, "-qa", "--qf", "%{NAME}\t%{EPOCHNUM}:%{VERSION}-%{RELEASE}.%{ARCH}\\n"]
        else:
            argv = [dnf, "--cacheonly", "--quiet", "check-update"]
            argv.extend(packages)
        result = _run(argv, timeout=30)
        backend = "dnf"
        if action == "upgradable" and result["exit_code"] == 100:
            result["ok"] = True
    else:
        raise OpsChangeError("no supported package manager is available")
    lines = [line for line in str(result["stdout"]).splitlines() if line.strip()]
    if packages:
        requested_set = set(packages)
        lines = [line for line in lines if line.split("/", 1)[0].split("\t", 1)[0] in requested_set]
    return {
        "ok": bool(result["ok"]),
        "status": "listed" if result["ok"] else "query_failed",
        "tool": "ops-change/package-query",
        "backend": backend,
        "action": action,
        "items": lines[:limit],
        "count": min(len(lines), limit),
        "truncated": len(lines) > limit,
        "error": "" if result["ok"] else str(result["stderr"]).strip(),
    }


def package_upgrade_plan(args: dict[str, object]) -> dict[str, object]:
    _fields(args, {"packages"})
    requested = args.get("packages")
    if not isinstance(requested, list) or not 1 <= len(requested) <= 64:
        raise OpsChangeError("packages must contain 1..64 package names")
    packages = []
    for item in requested:
        name = _string(item, "package", maximum=128)
        if PACKAGE_PATTERN.fullmatch(name) is None:
            raise OpsChangeError(f"invalid package name: {name}")
        packages.append(name)
    apt_get = _tool("apt-get")
    dnf = _tool("dnf")
    if apt_get:
        argv = [apt_get, "--simulate", "--no-download", "install", "--only-upgrade", "--"]
        argv.extend(packages)
        result = _run(argv, timeout=45)
        backend = "apt"
        planned = []
        for line in str(result["stdout"]).splitlines():
            match = re.match(r"^Inst\s+(\S+)(?:\s+\[([^]]+)\])?\s+\((\S+)", line)
            if match:
                planned.append(
                    {"package": match.group(1), "from": match.group(2), "to": match.group(3)}
                )
    elif dnf:
        argv = [dnf, "--cacheonly", "--assumeno", "upgrade", "--"]
        argv.extend(packages)
        result = _run(argv, timeout=45)
        backend = "dnf"
        planned = []
    else:
        raise OpsChangeError("no supported package manager is available")
    output = (str(result["stdout"]) + str(result["stderr"]))[:MAX_OUTPUT]
    space_lines = [line for line in output.splitlines() if "disk space" in line.lower()]
    return {
        "ok": bool(result["ok"]),
        "status": "planned" if result["ok"] else "plan_failed",
        "tool": "ops-change/package-upgrade-plan",
        "backend": backend,
        "requested_packages": packages,
        "planned_versions": planned,
        "dependencies_and_actions": output,
        "space_estimate": space_lines[:4],
        "rollback": "Confirm package cache and repository rollback versions before applying outside this Skill.",
    }


def account_audit(args: dict[str, object]) -> dict[str, object]:
    _fields(args, {"limit"})
    limit = _integer(args.get("limit", 500), "limit", 1, 2000)
    passwd_source = _read_fixed_file(PASSWD_PATH, ACCOUNT_FILE_LIMIT)
    group_source = _read_fixed_file(GROUP_PATH, ACCOUNT_FILE_LIMIT)
    for source in (passwd_source, group_source):
        if not source["visible"]:
            raise OpsChangeError(
                f"account source is unavailable: {source['path']} ({source['reason']})"
            )

    accounts = []
    invalid_accounts = 0
    for line in str(passwd_source["content"]).splitlines():
        fields = line.split(":")
        if len(fields) != 7 or not fields[0]:
            invalid_accounts += 1
            continue
        try:
            uid = int(fields[2], 10)
            gid = int(fields[3], 10)
        except ValueError:
            invalid_accounts += 1
            continue
        if uid < 0 or gid < 0:
            invalid_accounts += 1
            continue
        accounts.append(
            {
                "name": fields[0],
                "uid": uid,
                "gid": gid,
                "home": fields[5],
                "shell": fields[6],
            }
        )

    groups = []
    invalid_groups = 0
    members_truncated = False
    for line in str(group_source["content"]).splitlines():
        fields = line.split(":")
        if len(fields) != 4 or not fields[0]:
            invalid_groups += 1
            continue
        try:
            gid = int(fields[2], 10)
        except ValueError:
            invalid_groups += 1
            continue
        if gid < 0:
            invalid_groups += 1
            continue
        members = [member for member in fields[3].split(",") if member]
        members_truncated = members_truncated or len(members) > 256
        groups.append({"name": fields[0], "gid": gid, "members": members[:256]})

    who = _tool("who")
    login_result = _run([who], timeout=5) if who else {"ok": False, "stdout": ""}
    return {
        "ok": True,
        "status": "read",
        "tool": "ops-change/account-audit",
        "accounts": accounts[:limit],
        "groups": groups[:limit],
        "visible_logins": str(login_result["stdout"]).splitlines()[:200],
        "shadow_read": False,
        "sources": [os.fspath(PASSWD_PATH), os.fspath(GROUP_PATH)],
        "invalid_entries": invalid_accounts + invalid_groups,
        "truncated": len(accounts) > limit or len(groups) > limit or members_truncated,
    }


def _read_fixed_file(path: Path, maximum: int = 262_144) -> dict[str, object]:
    descriptor = -1
    try:
        descriptor = os.open(
            os.fspath(path),
            os.O_RDONLY
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0),
        )
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            return {"path": os.fspath(path), "visible": False, "reason": "not_regular"}
        if metadata.st_size > maximum:
            return {"path": os.fspath(path), "visible": False, "reason": "too_large"}
        payload = bytearray()
        while len(payload) <= maximum:
            chunk = os.read(descriptor, min(65_536, maximum + 1 - len(payload)))
            if not chunk:
                break
            payload.extend(chunk)
        if len(payload) > maximum:
            return {"path": os.fspath(path), "visible": False, "reason": "too_large"}
        text = payload.decode("utf-8")
    except (OSError, UnicodeError) as exc:
        return {"path": os.fspath(path), "visible": False, "reason": str(exc)}
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    return {"path": os.fspath(path), "visible": True, "content": text}


def schedule_audit(args: dict[str, object]) -> dict[str, object]:
    _fields(args, {"limit"})
    limit = _integer(args.get("limit", 200), "limit", 1, 1000)
    entries = [_read_fixed_file(Path("/etc/crontab"))]
    cron_dir = Path("/etc/cron.d")
    try:
        children = sorted(cron_dir.iterdir(), key=lambda path: path.name)
    except OSError:
        children = []
    for child in children[:limit]:
        if CRON_NAME_PATTERN.fullmatch(child.name):
            entries.append(_read_fixed_file(child))
    systemctl = _tool("systemctl")
    timers = (
        _run([systemctl, "list-timers", "--all", "--no-pager", "--no-legend"], timeout=15)
        if systemctl
        else {"ok": False, "stdout": "", "stderr": "systemctl unavailable"}
    )
    return {
        "ok": True,
        "status": "read",
        "tool": "ops-change/schedule-audit",
        "cron": entries,
        "timers": str(timers["stdout"]).splitlines()[:limit],
        "timer_error": "" if timers["ok"] else str(timers.get("stderr", "")),
        "unreadable_items_recorded": True,
    }


def schedule_edit_plan(args: dict[str, object]) -> dict[str, object]:
    _fields(args, {"kind", "path", "content", "unit", "properties"})
    kind = args.get("kind")
    if kind == "cron":
        path_value = _string(args.get("path"), "path", maximum=256)
        if path_value == "/etc/crontab":
            target = Path(path_value)
        elif path_value.startswith("/etc/cron.d/"):
            name = path_value.removeprefix("/etc/cron.d/")
            if CRON_NAME_PATTERN.fullmatch(name) is None:
                raise OpsChangeError("cron.d name is invalid")
            target = Path(path_value)
        else:
            raise OpsChangeError("cron target must be /etc/crontab or /etc/cron.d/<name>")
        content = _string(args.get("content"), "content", maximum=262_144)
        current = _read_fixed_file(target)
        before = str(current.get("content", ""))
        diff = "\n".join(
            difflib.unified_diff(
                before.splitlines(), content.splitlines(), fromfile=path_value, tofile=path_value
            )
        )
        return {
            "ok": True,
            "status": "planned",
            "tool": "ops-change/schedule-edit-plan",
            "kind": kind,
            "target": path_value,
            "diff": diff,
            "apply_supported": False,
        }
    if kind == "timer":
        unit = normalize_unit(args.get("unit"), allow_timer=True)
        properties = args.get("properties")
        if not isinstance(properties, dict) or not properties:
            raise OpsChangeError("timer properties must be a non-empty object")
        _fields(properties, set(TIMER_PROPERTIES))
        normalized = {}
        for key, value in properties.items():
            if key == "Persistent":
                if not isinstance(value, bool):
                    raise OpsChangeError("Persistent must be boolean")
                normalized[key] = "yes" if value else "no"
            else:
                normalized[key] = _single_line_string(value, key, maximum=256)
        systemctl = _tool("systemctl")
        if systemctl is None:
            raise OpsChangeError("systemctl is unavailable")
        current = _run([systemctl, "cat", unit, "--no-pager"], timeout=10)
        if not current["ok"]:
            raise OpsChangeError("timer unit is not visible")
        proposed = ["[Timer]"] + [f"{key}={value}" for key, value in sorted(normalized.items())]
        diff = "\n".join(
            difflib.unified_diff(
                str(current["stdout"]).splitlines(), proposed, fromfile=unit, tofile=f"{unit} plan"
            )
        )
        return {
            "ok": True,
            "status": "planned",
            "tool": "ops-change/schedule-edit-plan",
            "kind": kind,
            "unit": unit,
            "properties": normalized,
            "diff": diff,
            "apply_supported": False,
            "service_command_generated": False,
        }
    raise OpsChangeError("kind must be cron or timer")


def service_restart(args: dict[str, object]) -> dict[str, object]:
    _fields(args, {"action", "unit", "apply"})
    action = args.get("action")
    if action not in {"read", "plan"}:
        raise OpsChangeError("action must be read or plan in the Runner")
    if args.get("apply", False) is not False:
        raise OpsChangeError("apply must be false for read and plan")
    unit = normalize_unit(args.get("unit"))
    state, digest = service_preflight(unit)
    result: dict[str, object] = {
        "ok": True,
        "status": "read" if action == "read" else "planned",
        "tool": "ops-change/service-restart",
        "action": action,
        "unit": unit,
        "state": state,
        "preflight_sha256": digest,
    }
    if action == "plan":
        systemctl = _tool("systemctl")
        dependencies = _run(
            [systemctl, "list-dependencies", "--reverse", unit, "--no-pager"], timeout=15
        )
        result["reverse_dependencies"] = str(dependencies["stdout"]).splitlines()[:200]
        result["apply_requirements"] = {
            "apply": True,
            "confirm": "RESTART_SERVICE",
            "preflight_sha256": digest,
        }
    return result


def systemd_dropin(args: dict[str, object]) -> dict[str, object]:
    _fields(args, {"action", "unit", "resources", "apply"})
    if args.get("action") != "plan":
        raise OpsChangeError("action must be plan in the Runner")
    if args.get("apply", False) is not False:
        raise OpsChangeError("apply must be false for plan")
    unit = normalize_unit(args.get("unit"))
    resources = normalize_resources(args.get("resources"))
    preflight, digest = dropin_preflight(unit)
    target = dropin_path(unit)
    try:
        current = target.read_text(encoding="utf-8")
    except FileNotFoundError:
        current = ""
    proposed = render_dropin(resources).decode("utf-8")
    diff = "\n".join(
        difflib.unified_diff(
            current.splitlines(), proposed.splitlines(), fromfile=os.fspath(target), tofile=os.fspath(target)
        )
    )
    return {
        "ok": True,
        "status": "planned",
        "tool": "ops-change/systemd-dropin",
        "action": "plan",
        "unit": unit,
        "resources": resources,
        "target": os.fspath(target),
        "preflight": preflight,
        "preflight_sha256": digest,
        "diff": diff,
        "restart_performed": False,
    }


COMMANDS = {
    "package-query": package_query,
    "package-upgrade-plan": package_upgrade_plan,
    "account-audit": account_audit,
    "schedule-audit": schedule_audit,
    "schedule-edit-plan": schedule_edit_plan,
    "service-restart": service_restart,
    "systemd-dropin": systemd_dropin,
}


def main(argv: list[str]) -> int:
    if len(argv) != 3 or argv[1] not in COMMANDS:
        emit({"ok": False, "status": "invalid_arguments", "code": "invalid_arguments", "error": "usage: ops_change.py <operation> <json-object>"})
        return 0
    try:
        result = COMMANDS[argv[1]](_object(argv[2]))
    except OpsChangeError as exc:
        emit(
            {
                "ok": False,
                "status": "invalid_arguments",
                "code": "invalid_arguments",
                "tool": f"ops-change/{argv[1]}",
                "error": str(exc),
            }
        )
        return 0
    emit(result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
