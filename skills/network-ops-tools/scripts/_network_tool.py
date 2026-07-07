#!/usr/bin/env python3
import json
import math
import os
import re
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from ipaddress import ip_address, ip_interface, ip_network
from pathlib import Path


TOOL_RISK = {
    "ip-scanner": "high",
    "port-scanner": "high",
    "discovery-protocol": "medium",
    "wake-on-lan": "high",
    "network-interface": "medium",
    "wifi": "medium",
    "connections": "medium",
    "listeners": "medium",
    "neighbor-table": "medium",
    "ping-monitor": "medium",
    "traceroute": "medium",
    "dns-lookup": "medium",
    "sntp-lookup": "medium",
    "whois": "medium",
    "ip-geolocation": "medium",
    "hosts-file-editor": "high",
    "lookup": "medium",
    "snmp": "high",
    "firewall": "high",
    "subnet-calculator": "medium",
    "bit-calculator": "medium",
}

COMMON_PORTS = [20, 21, 22, 25, 53, 80, 110, 123, 143, 161, 389, 443, 445, 587, 993, 995, 3389, 5432, 6379, 8080]
OUI_BUILTINS = {
    "00005E": "IANA",
    "000C29": "VMware",
    "00163E": "Xensource",
    "001C42": "Parallels",
    "005056": "VMware",
    "080027": "Oracle VirtualBox",
    "525400": "QEMU/KVM",
}
WHOIS_TLD_SERVERS = {
    "com": "whois.verisign-grs.com",
    "net": "whois.verisign-grs.com",
    "org": "whois.pir.org",
    "io": "whois.nic.io",
    "dev": "whois.nic.google",
    "app": "whois.nic.google",
}


class ToolError(Exception):
    def __init__(self, status, message, **extra):
        super().__init__(message)
        self.status = status
        self.message = message
        self.extra = extra


def emit(payload):
    print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))


def fail(tool, status, message, **extra):
    payload = {"ok": False, "tool": f"network.ops.{tool}", "status": status, "risk": TOOL_RISK.get(tool, "medium"), "error": message}
    payload.update(extra)
    emit(payload)


def success(tool, status="ok", **extra):
    payload = {"ok": True, "tool": f"network.ops.{tool}", "status": status, "risk": TOOL_RISK.get(tool, "medium")}
    payload.update(extra)
    emit(payload)


def parse_args(raw):
    if not raw:
        return {}
    try:
        value = json.loads(raw)
        if isinstance(value, str):
            value = json.loads(value)
    except json.JSONDecodeError as exc:
        raise ToolError("invalid_arguments", f"arguments must be a JSON object: {exc}")
    if not isinstance(value, dict):
        raise ToolError("invalid_arguments", "arguments must be a JSON object")
    return value


def bool_arg(args, key, default=False):
    value = args.get(key, default)
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return value.strip().lower() in {"1", "true", "yes", "y", "on"}
    return bool(value)


def int_arg(args, key, default, minimum=None, maximum=None):
    value = args.get(key, default)
    try:
        number = int(value)
    except (TypeError, ValueError):
        number = default
    if minimum is not None and number < minimum:
        number = minimum
    if maximum is not None and number > maximum:
        number = maximum
    return number


def timeout_arg(args, default_ms=1000, maximum_ms=10000):
    return int_arg(args, "timeout_ms", default_ms, 100, maximum_ms) / 1000.0


def short_text(text, limit=8000):
    text = str(text or "")
    if len(text) > limit:
        return text[:limit] + "\n[TRUNCATED]"
    return text


def command_exists(name):
    return shutil.which(name) is not None


def run_command(command, timeout=5, max_chars=12000):
    try:
        completed = subprocess.run(
            command,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            check=False,
        )
        return {
            "command": command,
            "exit_code": completed.returncode,
            "stdout": short_text(completed.stdout, max_chars),
            "stderr": short_text(completed.stderr, max_chars),
            "ok": completed.returncode == 0,
        }
    except FileNotFoundError:
        return {"command": command, "exit_code": 127, "stdout": "", "stderr": "command not found", "ok": False}
    except subprocess.TimeoutExpired as exc:
        return {
            "command": command,
            "exit_code": 124,
            "stdout": short_text(exc.stdout or "", max_chars),
            "stderr": "command timed out",
            "ok": False,
        }


def safe_host(value, field="host"):
    host = str(value or "").strip()
    if not host or len(host) > 253:
        raise ToolError("invalid_target", f"{field} is required and must be shorter than 254 characters")
    if not re.fullmatch(r"[A-Za-z0-9_.:-]+", host):
        raise ToolError("invalid_target", f"{field} contains unsupported characters")
    return host


def safe_interface(value):
    if value in (None, ""):
        return ""
    interface = str(value).strip()
    if not re.fullmatch(r"[A-Za-z0-9_.:@-]{1,64}", interface):
        raise ToolError("invalid_interface", "interface contains unsupported characters")
    return interface


def is_loopback_literal(target):
    text = str(target or "").strip().lower()
    if text in {"localhost", "localhost.localdomain"}:
        return True
    try:
        return ip_address(text).is_loopback
    except ValueError:
        return False


def require_authorized_scope(args, targets, reason):
    if bool_arg(args, "acknowledge_authorized_scope", False):
        return
    if all(is_loopback_literal(target) for target in targets):
        return
    raise ToolError(
        "authorization_required",
        f"{reason}; set acknowledge_authorized_scope=true after confirming authorization for the target scope.",
        targets=list(targets)[:20],
    )


def parse_ports(value, max_count=256, allow_empty=False):
    if value in (None, "", []):
        if allow_empty:
            return []
        raise ToolError("invalid_ports", "ports are required")
    parts = value if isinstance(value, list) else re.split(r"[,\s]+", str(value).strip())
    ports = []
    for part in parts:
        if part in (None, ""):
            continue
        text = str(part).strip()
        if re.fullmatch(r"\d{1,5}-\d{1,5}", text):
            start, end = [int(item) for item in text.split("-", 1)]
            if start > end:
                start, end = end, start
            for port in range(start, end + 1):
                ports.append(port)
        elif re.fullmatch(r"\d{1,5}", text):
            ports.append(int(text))
        else:
            raise ToolError("invalid_ports", f"invalid port token: {text}")
    unique = []
    for port in ports:
        if port < 1 or port > 65535:
            raise ToolError("invalid_ports", "ports must be between 1 and 65535")
        if port not in unique:
            unique.append(port)
    if len(unique) > max_count:
        raise ToolError("too_many_ports", f"at most {max_count} ports are allowed", port_count=len(unique))
    if not unique and not allow_empty:
        raise ToolError("invalid_ports", "ports are required")
    return unique


def tcp_probe(target, port, timeout):
    start = time.monotonic()
    try:
        with socket.create_connection((target, port), timeout=timeout):
            elapsed = round((time.monotonic() - start) * 1000, 2)
            return {"port": port, "state": "open", "latency_ms": elapsed}
    except socket.timeout:
        return {"port": port, "state": "filtered", "latency_ms": None}
    except ConnectionRefusedError:
        elapsed = round((time.monotonic() - start) * 1000, 2)
        return {"port": port, "state": "closed", "latency_ms": elapsed}
    except OSError as exc:
        return {"port": port, "state": "error", "latency_ms": None, "error": str(exc)}


def ping_once(target, timeout):
    if not command_exists("ping"):
        return {"available": False, "up": None, "raw": "ping command not available"}
    seconds = max(1, int(math.ceil(timeout)))
    result = run_command(["ping", "-n", "-c", "1", "-W", str(seconds), target], timeout=seconds + 2, max_chars=2000)
    return {"available": True, "up": result["exit_code"] == 0, "raw": result["stdout"] or result["stderr"]}


def handle_ip_scanner(args):
    max_hosts = int_arg(args, "max_hosts", 256, 1, 1024)
    timeout = timeout_arg(args, default_ms=750, maximum_ms=5000)
    only_up = bool_arg(args, "only_up", False)
    ports = parse_ports(args.get("ports", []), max_count=32, allow_empty=True)

    targets = []
    if args.get("targets"):
        raw_targets = args["targets"] if isinstance(args["targets"], list) else [args["targets"]]
        targets = [str(item).strip() for item in raw_targets if str(item).strip()]
    else:
        cidr = str(args.get("cidr") or args.get("network") or "").strip()
        if not cidr:
            raise ToolError("missing_target", "cidr or targets is required")
        network = ip_network(cidr, strict=False)
        if network.num_addresses > max_hosts:
            raise ToolError("scope_too_large", f"network contains more than max_hosts={max_hosts}", cidr=str(network), addresses=network.num_addresses)
        targets = [str(ip) for ip in network.hosts()]
        if network.num_addresses == 1:
            targets = [str(network.network_address)]
    if not targets:
        raise ToolError("missing_target", "no targets resolved")
    if len(targets) > max_hosts:
        raise ToolError("scope_too_large", f"target list contains more than max_hosts={max_hosts}", target_count=len(targets))

    require_authorized_scope(args, targets, "IP scanning sends packets to one or more hosts")

    def scan_one(target):
        ping = ping_once(target, timeout) if bool_arg(args, "ping", True) else {"available": False, "up": None, "raw": ""}
        tcp = [tcp_probe(target, port, timeout) for port in ports]
        open_ports = [item["port"] for item in tcp if item["state"] == "open"]
        up = is_loopback_literal(target) or ping.get("up") is True or bool(open_ports)
        item = {"target": target, "up": up, "ping": ping, "tcp": tcp}
        try:
            item["hostname"] = socket.gethostbyaddr(target)[0]
        except OSError:
            item["hostname"] = ""
        return item

    workers = int_arg(args, "workers", min(64, len(targets)), 1, 128)
    results = []
    with ThreadPoolExecutor(max_workers=workers) as executor:
        futures = {executor.submit(scan_one, target): target for target in targets}
        for future in as_completed(futures):
            item = future.result()
            if not only_up or item["up"]:
                results.append(item)
    results.sort(key=lambda item: ip_address(item["target"]))
    success("ip-scanner", "scanned", scanned_hosts=len(targets), returned_hosts=len(results), alive_count=sum(1 for item in results if item["up"]), ports=ports, results=results)


def handle_port_scanner(args):
    target = safe_host(args.get("target"), "target")
    if args.get("ports") not in (None, "", []):
        ports = parse_ports(args.get("ports"), max_count=512)
    elif args.get("common_ports"):
        ports = COMMON_PORTS
    else:
        start = int_arg(args, "start_port", 1, 1, 65535)
        end = int_arg(args, "end_port", min(start + 99, 65535), 1, 65535)
        if end < start:
            start, end = end, start
        ports = parse_ports(f"{start}-{end}", max_count=512)
    require_authorized_scope(args, [target], "Port scanning opens TCP connections to the target")
    timeout = timeout_arg(args, default_ms=750, maximum_ms=5000)
    workers = int_arg(args, "workers", min(128, len(ports)), 1, 256)
    results = []
    with ThreadPoolExecutor(max_workers=workers) as executor:
        futures = {executor.submit(tcp_probe, target, port, timeout): port for port in ports}
        for future in as_completed(futures):
            results.append(future.result())
    results.sort(key=lambda item: item["port"])
    success("port-scanner", "scanned", target=target, scanned_ports=len(ports), open_ports=[item["port"] for item in results if item["state"] == "open"], results=results)


def handle_discovery_protocol(args):
    interface = safe_interface(args.get("interface"))
    limit = int_arg(args, "limit", 80, 1, 300)
    commands = []
    if command_exists("lldpcli"):
        commands.append(["lldpcli", "-f", "json", "show", "neighbors"])
    if command_exists("networkctl"):
        if interface:
            commands.append(["networkctl", "lldp", interface])
        commands.append(["networkctl", "lldp"])
    if not commands:
        success("discovery-protocol", "unsupported", interface=interface, neighbors=[], message="No LLDP/CDP discovery command is available.")
        return
    observations = []
    for command in commands:
        result = run_command(command, timeout=5, max_chars=10000)
        observations.append(result)
        if result["ok"] and result["stdout"].strip():
            break
    text = "\n".join(item["stdout"] or item["stderr"] for item in observations)
    lines = [line for line in text.splitlines() if line.strip()][:limit]
    success("discovery-protocol", "inspected", interface=interface, commands=observations, lines=lines)


def normalize_mac(value):
    text = re.sub(r"[^0-9A-Fa-f]", "", str(value or ""))
    if len(text) != 12:
        raise ToolError("invalid_mac", "mac must contain 12 hexadecimal characters")
    return ":".join(text[index:index + 2] for index in range(0, 12, 2)).lower()


def handle_wake_on_lan(args):
    mac = normalize_mac(args.get("mac"))
    broadcast = str(args.get("broadcast") or "255.255.255.255").strip()
    port = int_arg(args, "port", 9, 1, 65535)
    dry_run = bool_arg(args, "dry_run", False)
    packet = bytes.fromhex("ff" * 6 + re.sub(r"[^0-9A-Fa-f]", "", mac) * 16)
    if dry_run:
        success("wake-on-lan", "planned", mac=mac, broadcast=broadcast, port=port, packet_bytes=len(packet))
        return
    require_authorized_scope(args, [broadcast], "Wake-on-LAN broadcasts a magic packet")
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
            sent = sock.sendto(packet, (broadcast, port))
    except OSError as exc:
        raise ToolError("send_failed", str(exc), mac=mac, broadcast=broadcast, port=port)
    success("wake-on-lan", "sent", mac=mac, broadcast=broadcast, port=port, sent_bytes=sent)


def read_sysfs(path):
    try:
        return Path(path).read_text(encoding="utf-8", errors="replace").strip()
    except OSError:
        return ""


def handle_network_interface(args):
    selected = safe_interface(args.get("interface"))
    interfaces = []
    if command_exists("ip"):
        addr_cmd = ["ip", "-j", "address", "show"]
        route_cmd = ["ip", "-j", "route", "show"]
        if selected:
            addr_cmd.extend(["dev", selected])
        addr = run_command(addr_cmd, timeout=5, max_chars=20000)
        route = run_command(route_cmd, timeout=5, max_chars=20000)
        if addr["ok"] and addr["stdout"].strip():
            try:
                interfaces = json.loads(addr["stdout"])
            except json.JSONDecodeError:
                interfaces = []
        routes = []
        if route["ok"] and route["stdout"].strip():
            try:
                routes = json.loads(route["stdout"])
            except json.JSONDecodeError:
                routes = []
    else:
        addr = {"ok": False, "stderr": "ip command not available"}
        route = {"ok": False, "stderr": "ip command not available"}
        routes = []

    sysfs = []
    for child in sorted(Path("/sys/class/net").glob("*")):
        if selected and child.name != selected:
            continue
        sysfs.append({
            "name": child.name,
            "operstate": read_sysfs(child / "operstate"),
            "address": read_sysfs(child / "address"),
            "mtu": int(read_sysfs(child / "mtu") or 0),
            "speed": read_sysfs(child / "speed"),
            "wireless": (child / "wireless").exists(),
        })
    success("network-interface", "inspected", interface=selected, interfaces=interfaces, routes=routes, sysfs=sysfs, commands={"address": addr, "routes": route})


def parse_nmcli_wifi(text):
    rows = []
    for line in text.splitlines():
        if not line.strip():
            continue
        parts = line.split(":")
        rows.append({"raw": line, "ssid": parts[0] if parts else "", "security": parts[-2] if len(parts) >= 2 else "", "signal": parts[-1] if parts else ""})
    return rows


def handle_wifi(args):
    interface = safe_interface(args.get("interface"))
    scan = bool_arg(args, "scan", False)
    if scan:
        require_authorized_scope(args, [interface or "wifi-scan"], "Wi-Fi scanning asks the adapter to refresh visible networks")
    wireless = [path.name for path in Path("/sys/class/net").glob("*") if (path / "wireless").exists()]
    observations = []
    networks = []
    if command_exists("nmcli"):
        command = ["nmcli", "-t", "-f", "SSID,BSSID,CHAN,FREQ,RATE,SIGNAL,SECURITY", "dev", "wifi", "list", "--rescan", "yes" if scan else "no"]
        if interface:
            command.extend(["ifname", interface])
        result = run_command(command, timeout=15, max_chars=20000)
        observations.append(result)
        networks = parse_nmcli_wifi(result["stdout"])
    elif command_exists("iw"):
        command = ["iw", "dev"]
        result = run_command(command, timeout=5, max_chars=12000)
        observations.append(result)
    success("wifi", "inspected", interface=interface, scan=scan, wireless_interfaces=wireless, networks=networks, commands=observations, supported=bool(observations))


def parse_ss_lines(text, limit):
    rows = []
    for line in text.splitlines():
        if not line.strip():
            continue
        parts = line.split()
        row = {"raw": line}
        if len(parts) >= 5:
            row.update({"state": parts[0], "recv_q": parts[1], "send_q": parts[2], "local": parts[3], "peer": parts[4]})
        rows.append(row)
        if len(rows) >= limit:
            break
    return rows


def ss_protocol_args(protocol):
    if protocol == "tcp":
        return ["-t"]
    if protocol == "udp":
        return ["-u"]
    return ["-t", "-u"]


def handle_connections(args):
    protocol = str(args.get("protocol") or "all").lower()
    if protocol not in {"all", "tcp", "udp"}:
        raise ToolError("invalid_protocol", "protocol must be all, tcp, or udp")
    state = str(args.get("state") or "").lower()
    limit = int_arg(args, "limit", 100, 1, 500)
    include_process = bool_arg(args, "include_process", False)
    if not command_exists("ss"):
        raise ToolError("missing_dependency", "ss command is required")
    command = ["ss", "-H", "-n", "-a"]
    command.extend(ss_protocol_args(protocol))
    if include_process:
        command.append("-p")
    result = run_command(command, timeout=8, max_chars=30000)
    rows = parse_ss_lines(result["stdout"], limit * 3)
    if state:
        rows = [row for row in rows if row.get("state", "").lower() == state][:limit]
    else:
        rows = rows[:limit]
    success("connections", "inspected", protocol=protocol, state=state, limit=limit, connections=rows, command=result)


def handle_listeners(args):
    protocol = str(args.get("protocol") or "all").lower()
    if protocol not in {"all", "tcp", "udp"}:
        raise ToolError("invalid_protocol", "protocol must be all, tcp, or udp")
    port_filter = str(args.get("port") or "").strip()
    if port_filter and not re.fullmatch(r"\d{1,5}", port_filter):
        raise ToolError("invalid_port", "port must be numeric")
    limit = int_arg(args, "limit", 100, 1, 500)
    include_process = bool_arg(args, "include_process", False)
    if not command_exists("ss"):
        raise ToolError("missing_dependency", "ss command is required")
    command = ["ss", "-H", "-n", "-l"]
    command.extend(ss_protocol_args(protocol))
    if include_process:
        command.append("-p")
    result = run_command(command, timeout=8, max_chars=30000)
    rows = parse_ss_lines(result["stdout"], limit * 3)
    if port_filter:
        rows = [row for row in rows if re.search(rf"[:.]{re.escape(port_filter)}(\s|$)", row["raw"])][:limit]
    else:
        rows = rows[:limit]
    success("listeners", "inspected", protocol=protocol, port=port_filter, limit=limit, listeners=rows, command=result)


def handle_neighbor_table(args):
    interface = safe_interface(args.get("interface"))
    limit = int_arg(args, "limit", 200, 1, 1000)
    if not command_exists("ip"):
        raise ToolError("missing_dependency", "ip command is required")
    command = ["ip", "-j", "neigh", "show"]
    if interface:
        command.extend(["dev", interface])
    result = run_command(command, timeout=5, max_chars=30000)
    entries = []
    if result["stdout"].strip():
        try:
            entries = json.loads(result["stdout"])[:limit]
        except json.JSONDecodeError:
            entries = [{"raw": line} for line in result["stdout"].splitlines()[:limit]]
    success("neighbor-table", "inspected", interface=interface, entries=entries, command=result)


def handle_ping_monitor(args):
    target = safe_host(args.get("target"), "target")
    require_authorized_scope(args, [target], "Ping monitor sends ICMP probes")
    count = int_arg(args, "count", 4, 1, 30)
    timeout_seconds = max(1, int(math.ceil(timeout_arg(args, default_ms=1000, maximum_ms=10000))))
    interval = int_arg(args, "interval_sec", 1, 1, 10)
    if not command_exists("ping"):
        raise ToolError("missing_dependency", "ping command is required")
    command = ["ping", "-n", "-c", str(count), "-W", str(timeout_seconds), "-i", str(interval), target]
    result = run_command(command, timeout=(timeout_seconds + interval) * count + 3, max_chars=12000)
    stdout = result["stdout"]
    transmitted = received = None
    loss = ""
    match = re.search(r"(\d+)\s+packets transmitted,\s+(\d+)\s+(?:packets )?received,\s+([^,\n]+)\s+packet loss", stdout)
    if match:
        transmitted, received, loss = int(match.group(1)), int(match.group(2)), match.group(3)
    rtt = {}
    match = re.search(r"(?:rtt|round-trip).*=\s*([0-9.]+)/([0-9.]+)/([0-9.]+)/([0-9.]+)", stdout)
    if match:
        rtt = {"min_ms": float(match.group(1)), "avg_ms": float(match.group(2)), "max_ms": float(match.group(3)), "mdev_ms": float(match.group(4))}
    success("ping-monitor", "completed", target=target, transmitted=transmitted, received=received, packet_loss=loss, rtt=rtt, command=result)


def handle_traceroute(args):
    target = safe_host(args.get("target"), "target")
    require_authorized_scope(args, [target], "Traceroute sends TTL-limited probes")
    if is_loopback_literal(target):
        success("traceroute", "completed", target=target, hops=[{"hop": 1, "address": target, "rtt": "loopback"}], command=None)
        return
    max_hops = int_arg(args, "max_hops", 30, 1, 64)
    timeout = max(1, int(math.ceil(timeout_arg(args, default_ms=2000, maximum_ms=10000))))
    if command_exists("tracepath"):
        command = ["tracepath", "-m", str(max_hops), target]
    elif command_exists("traceroute"):
        command = ["traceroute", "-n", "-m", str(max_hops), "-w", str(timeout), target]
    else:
        raise ToolError("missing_dependency", "tracepath or traceroute is required for non-loopback targets")
    result = run_command(command, timeout=max_hops * (timeout + 1), max_chars=16000)
    hops = [{"raw": line} for line in result["stdout"].splitlines() if line.strip()]
    success("traceroute", "completed" if result["ok"] else "command_failed", target=target, hops=hops, command=result)


def handle_dns_lookup(args):
    query = safe_host(args.get("query") or args.get("host"), "query")
    record_type = str(args.get("record_type") or args.get("type") or "A").upper()
    server = str(args.get("server") or "").strip()
    timeout_ms = int_arg(args, "timeout_ms", 3000, 100, 10000)
    if server and not re.fullmatch(r"[A-Za-z0-9_.:-]{1,253}", server):
        raise ToolError("invalid_server", "server contains unsupported characters")
    command_result = None
    records = []
    if command_exists("dig"):
        command = ["dig", "+time=" + str(max(1, math.ceil(timeout_ms / 1000))), "+tries=1"]
        if server:
            command.append("@" + server)
        command.extend([query, record_type, "+short"])
        command_result = run_command(command, timeout=timeout_ms / 1000 + 2, max_chars=12000)
        records = [{"type": record_type, "value": line} for line in command_result["stdout"].splitlines() if line.strip()]
    elif record_type in {"A", "AAAA", "ANY"} and not server:
        family = socket.AF_UNSPEC if record_type == "ANY" else socket.AF_INET if record_type == "A" else socket.AF_INET6
        for item in socket.getaddrinfo(query, None, family, socket.SOCK_STREAM):
            address = item[4][0]
            row_type = "AAAA" if ":" in address else "A"
            record = {"type": row_type, "value": address}
            if record not in records:
                records.append(record)
    elif record_type == "PTR" and not server:
        records.append({"type": "PTR", "value": socket.gethostbyaddr(query)[0]})
    else:
        raise ToolError("unsupported_record_type", "dig is required for this record type or custom DNS server")
    success("dns-lookup", "resolved", query=query, record_type=record_type, server=server, records=records, command=command_result)


def handle_sntp_lookup(args):
    server = safe_host(args.get("server") or "pool.ntp.org", "server")
    port = int_arg(args, "port", 123, 1, 65535)
    timeout = timeout_arg(args, default_ms=3000, maximum_ms=10000)
    if bool_arg(args, "dry_run", False):
        success("sntp-lookup", "planned", server=server, port=port, timeout_ms=int(timeout * 1000))
        return
    request = b"\x1b" + 47 * b"\0"
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.settimeout(timeout)
            started = time.monotonic()
            sock.sendto(request, (server, port))
            data, address = sock.recvfrom(512)
            latency_ms = round((time.monotonic() - started) * 1000, 2)
    except OSError as exc:
        raise ToolError("query_failed", str(exc), server=server, port=port)
    if len(data) < 48:
        raise ToolError("invalid_response", "SNTP response is shorter than 48 bytes", size_bytes=len(data))
    words = struct.unpack("!12I", data[:48])
    seconds = words[10] - 2208988800
    fraction = words[11] / 2**32
    timestamp = seconds + fraction
    success("sntp-lookup", "resolved", server=server, address=address[0], port=address[1], unix_time=timestamp, utc=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(timestamp)), latency_ms=latency_ms)


def public_whois_server(server):
    host = safe_host(server, "server")
    try:
        addresses = socket.getaddrinfo(host, 43, type=socket.SOCK_STREAM)
    except OSError as exc:
        raise ToolError("dns_error", str(exc), server=host)
    resolved = sorted({item[4][0] for item in addresses})
    for raw in resolved:
        try:
            if not ip_address(raw).is_global:
                raise ToolError("unsafe_server", "whois server must resolve to public/global addresses", server=host, ip=raw)
        except ValueError:
            pass
    return host, resolved


def whois_query(query, server, timeout, max_bytes=65536):
    public_whois_server(server)
    with socket.create_connection((server, 43), timeout=timeout) as sock:
        sock.settimeout(timeout)
        sock.sendall((query + "\r\n").encode("utf-8"))
        chunks = []
        total = 0
        while total < max_bytes:
            chunk = sock.recv(min(4096, max_bytes - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
    return b"".join(chunks).decode("utf-8", errors="replace")


def handle_whois(args):
    query = safe_host(args.get("query") or args.get("domain"), "query")
    timeout = timeout_arg(args, default_ms=5000, maximum_ms=15000)
    server = str(args.get("server") or "").strip()
    if not server:
        suffix = query.rsplit(".", 1)[-1].lower() if "." in query else ""
        server = WHOIS_TLD_SERVERS.get(suffix, "whois.iana.org")
    if bool_arg(args, "dry_run", False):
        checked_server = safe_host(server, "server")
        success("whois", "planned", query=query, server=checked_server)
        return
    started = time.monotonic()
    response = whois_query(query, server, timeout)
    referral = ""
    if server == "whois.iana.org":
        match = re.search(r"(?im)^whois:\s*(\S+)", response)
        if match:
            referral = match.group(1)
            response = whois_query(query, referral, timeout)
            server = referral
    success("whois", "resolved", query=query, server=server, referral=referral, latency_ms=round((time.monotonic() - started) * 1000, 2), response=short_text(response, 60000))


def handle_ip_geolocation(args):
    raw_ip = str(args.get("ip") or "").strip()
    if not raw_ip:
        raise ToolError("missing_ip", "ip is required")
    parsed = ip_address(raw_ip)
    if not parsed.is_global:
        raise ToolError("unsupported_ip", "ip geolocation only accepts public/global IP addresses", ip=raw_ip)
    provider = str(args.get("provider") or "ipapi").lower()
    if provider == "ipapi":
        url = f"https://ipapi.co/{parsed}/json/"
    elif provider == "ipwhois":
        url = f"https://ipwho.is/{parsed}"
    else:
        raise ToolError("invalid_provider", "provider must be ipapi or ipwhois")
    timeout = timeout_arg(args, default_ms=5000, maximum_ms=15000)
    if bool_arg(args, "dry_run", False):
        success("ip-geolocation", "planned", ip=str(parsed), provider=provider, url=url)
        return
    request = urllib.request.Request(url, headers={"User-Agent": "linux-agent-network-ops/1"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        data = response.read(65536)
    payload = json.loads(data.decode("utf-8", errors="replace"))
    success("ip-geolocation", "resolved", ip=str(parsed), provider=provider, result=payload)


def parse_hosts_file(path):
    entries = []
    try:
        lines = Path(path).read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError as exc:
        raise ToolError("read_failed", str(exc), path=str(path))
    for index, line in enumerate(lines, start=1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        body = stripped.split("#", 1)[0].strip()
        parts = body.split()
        if len(parts) >= 2:
            entries.append({"line": index, "ip": parts[0], "hostnames": parts[1:], "raw": line})
    return lines, entries


def hosts_path(args):
    raw = str(args.get("path") or "/etc/hosts")
    path = Path(raw).expanduser()
    if path.is_symlink():
        raise ToolError("unsupported_path", "hosts path must not be a symlink", path=str(path))
    resolved = path.resolve()
    if str(resolved) != "/etc/hosts":
        if not bool_arg(args, "allow_custom_path", False):
            raise ToolError("custom_path_requires_ack", "custom hosts path requires allow_custom_path=true", path=str(resolved))
        if not str(resolved).startswith(("/tmp/", "/var/tmp/")):
            raise ToolError("unsupported_path", "custom hosts path is limited to /tmp or /var/tmp", path=str(resolved))
    return resolved


def validate_hostnames(values):
    raw_values = values if isinstance(values, list) else [values]
    hostnames = []
    for item in raw_values:
        host = safe_host(item, "hostname")
        if ":" in host:
            raise ToolError("invalid_hostname", "hostname must not contain ':'")
        hostnames.append(host)
    if not hostnames:
        raise ToolError("missing_hostname", "at least one hostname is required")
    return hostnames


def write_hosts(path, lines):
    stat = path.stat()
    backup = path.with_name(path.name + f".bak.{time.strftime('%Y%m%d_%H%M%S')}.{time.time_ns()}")
    shutil.copy2(path, backup)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=str(path.parent), prefix=f".{path.name}.", suffix=".tmp", delete=False) as handle:
        tmp_name = handle.name
        handle.write("\n".join(lines) + "\n")
    os.chmod(tmp_name, stat.st_mode & 0o777)
    os.replace(tmp_name, path)
    return str(backup)


def handle_hosts_file_editor(args):
    action = str(args.get("action") or "read").lower()
    path = hosts_path(args)
    lines, entries = parse_hosts_file(path)
    if action == "read":
        limit = int_arg(args, "limit", 200, 1, 1000)
        success("hosts-file-editor", "read", path=str(path), entries=entries[:limit], entry_count=len(entries))
        return
    if action == "search":
        hostname = safe_host(args.get("hostname") or args.get("query"), "hostname")
        matches = [entry for entry in entries if hostname == entry["ip"] or hostname in entry["hostnames"]]
        success("hosts-file-editor", "searched", path=str(path), query=hostname, matches=matches)
        return
    if action in {"add", "plan-add"}:
        host_ip = str(ip_address(str(args.get("ip") or "").strip()))
        hostnames = validate_hostnames(args.get("hostnames") or args.get("hostname"))
        new_line = f"{host_ip}\t{' '.join(hostnames)}"
        apply_change = bool_arg(args, "apply", False) and action == "add"
        if not apply_change:
            success("hosts-file-editor", "planned", path=str(path), action="add", line=new_line)
            return
        if str(args.get("confirm") or "") != "APPLY_HOSTS_CHANGE":
            raise ToolError("confirmation_required", "set confirm to APPLY_HOSTS_CHANGE to modify hosts file")
        backup = write_hosts(path, lines + [new_line])
        success("hosts-file-editor", "updated", path=str(path), action="add", line=new_line, backup_path=backup)
        return
    if action in {"remove", "plan-remove"}:
        hostname = safe_host(args.get("hostname") or args.get("query"), "hostname")
        kept = []
        removed = []
        for line in lines:
            stripped = line.strip()
            body = stripped.split("#", 1)[0].strip()
            parts = body.split()
            if len(parts) >= 2 and hostname in parts[1:]:
                removed.append(line)
            else:
                kept.append(line)
        apply_change = bool_arg(args, "apply", False) and action == "remove"
        if not apply_change:
            success("hosts-file-editor", "planned", path=str(path), action="remove", hostname=hostname, removed=removed)
            return
        if str(args.get("confirm") or "") != "APPLY_HOSTS_CHANGE":
            raise ToolError("confirmation_required", "set confirm to APPLY_HOSTS_CHANGE to modify hosts file")
        backup = write_hosts(path, kept)
        success("hosts-file-editor", "updated", path=str(path), action="remove", hostname=hostname, removed=removed, backup_path=backup)
        return
    raise ToolError("invalid_action", "action must be read, search, plan-add, add, plan-remove, or remove")


def lookup_oui(prefix):
    normalized = re.sub(r"[^0-9A-Fa-f]", "", prefix).upper()[:6]
    if len(normalized) < 6:
        raise ToolError("invalid_oui", "OUI lookup requires at least 6 hexadecimal characters")
    if normalized in OUI_BUILTINS:
        return {"oui": normalized, "vendor": OUI_BUILTINS[normalized], "source": "builtin"}
    for path in ["/usr/share/misc/oui.txt", "/var/lib/ieee-data/oui.txt"]:
        file_path = Path(path)
        if not file_path.exists():
            continue
        try:
            for line in file_path.read_text(encoding="utf-8", errors="replace").splitlines():
                compact = re.sub(r"[^0-9A-Fa-f]", "", line[:16]).upper()
                if compact.startswith(normalized):
                    vendor = re.split(r"\s{2,}|\t", line, maxsplit=1)[-1].strip()
                    return {"oui": normalized, "vendor": vendor, "source": path}
        except OSError:
            continue
    return {"oui": normalized, "vendor": "", "source": "not_found"}


def handle_lookup(args):
    category = str(args.get("category") or "port").lower()
    query = str(args.get("query") or "").strip()
    if not query:
        raise ToolError("missing_query", "query is required")
    if category in {"port", "service"}:
        protocol = str(args.get("protocol") or "tcp").lower()
        if protocol not in {"tcp", "udp"}:
            raise ToolError("invalid_protocol", "protocol must be tcp or udp")
        results = []
        if query.isdigit():
            port = int(query)
            if port < 1 or port > 65535:
                raise ToolError("invalid_port", "port must be between 1 and 65535")
            try:
                name = socket.getservbyport(port, protocol)
            except OSError:
                name = ""
            results.append({"port": port, "protocol": protocol, "service": name})
        else:
            try:
                port = socket.getservbyname(query, protocol)
            except OSError:
                port = None
            results.append({"service": query, "protocol": protocol, "port": port})
        success("lookup", "resolved", category=category, query=query, results=results)
        return
    if category == "oui":
        success("lookup", "resolved", category=category, query=query, results=[lookup_oui(query)])
        return
    raise ToolError("invalid_category", "category must be port, service, or oui")


def ber_len(length):
    if length < 0x80:
        return bytes([length])
    raw = length.to_bytes((length.bit_length() + 7) // 8, "big")
    return bytes([0x80 | len(raw)]) + raw


def ber_tlv(tag, value):
    return bytes([tag]) + ber_len(len(value)) + value


def ber_int(value):
    raw = int(value).to_bytes(4, "big", signed=True).lstrip(b"\x00") or b"\x00"
    if raw[0] & 0x80:
        raw = b"\x00" + raw
    return ber_tlv(0x02, raw)


def ber_octet(text):
    return ber_tlv(0x04, str(text).encode("utf-8"))


def ber_oid(oid):
    parts = [int(part) for part in str(oid).strip(".").split(".") if part != ""]
    if len(parts) < 2 or parts[0] > 2 or parts[1] > 39:
        raise ToolError("invalid_oid", "oid must be a numeric dotted OID")
    encoded = bytes([parts[0] * 40 + parts[1]])
    for part in parts[2:]:
        if part < 0:
            raise ToolError("invalid_oid", "oid arcs must be non-negative")
        stack = [part & 0x7F]
        part >>= 7
        while part:
            stack.append(0x80 | (part & 0x7F))
            part >>= 7
        encoded += bytes(reversed(stack))
    return ber_tlv(0x06, encoded)


def snmp_packet(oid, community, request_id):
    varbind = ber_tlv(0x30, ber_oid(oid) + ber_tlv(0x05, b""))
    varbinds = ber_tlv(0x30, varbind)
    pdu = ber_tlv(0xA0, ber_int(request_id) + ber_int(0) + ber_int(0) + varbinds)
    return ber_tlv(0x30, ber_int(1) + ber_octet(community) + pdu)


def read_len(data, offset):
    first = data[offset]
    offset += 1
    if first < 0x80:
        return first, offset
    count = first & 0x7F
    value = int.from_bytes(data[offset:offset + count], "big")
    return value, offset + count


def read_tlv(data, offset):
    tag = data[offset]
    length, value_offset = read_len(data, offset + 1)
    end = value_offset + length
    return tag, data[value_offset:end], end


def decode_oid(raw):
    if not raw:
        return ""
    first = raw[0]
    parts = [first // 40, first % 40]
    value = 0
    for byte in raw[1:]:
        value = (value << 7) | (byte & 0x7F)
        if not (byte & 0x80):
            parts.append(value)
            value = 0
    return "." + ".".join(str(part) for part in parts)


def decode_int(raw):
    return int.from_bytes(raw, "big", signed=bool(raw and raw[0] & 0x80))


def decode_snmp_value(tag, raw):
    if tag == 0x02:
        return {"type": "integer", "value": decode_int(raw)}
    if tag == 0x04:
        return {"type": "octet_string", "value": raw.decode("utf-8", errors="replace")}
    if tag == 0x05:
        return {"type": "null", "value": None}
    if tag == 0x06:
        return {"type": "oid", "value": decode_oid(raw)}
    if tag == 0x40 and len(raw) == 4:
        return {"type": "ip_address", "value": ".".join(str(part) for part in raw)}
    if tag in {0x41, 0x42, 0x43, 0x46}:
        return {"type": f"application_{tag}", "value": int.from_bytes(raw, "big")}
    if tag in {0x80, 0x81, 0x82}:
        return {"type": {0x80: "no_such_object", 0x81: "no_such_instance", 0x82: "end_of_mib_view"}[tag], "value": None}
    return {"type": f"tag_{tag}", "hex": raw.hex()}


def decode_snmp_response(data):
    try:
        tag, top, _ = read_tlv(data, 0)
        if tag != 0x30:
            raise ValueError("not a sequence")
        offset = 0
        _, version_raw, offset = read_tlv(top, offset)
        _, community_raw, offset = read_tlv(top, offset)
        pdu_tag, pdu, offset = read_tlv(top, offset)
        pdu_offset = 0
        _, request_id_raw, pdu_offset = read_tlv(pdu, pdu_offset)
        _, error_status_raw, pdu_offset = read_tlv(pdu, pdu_offset)
        _, error_index_raw, pdu_offset = read_tlv(pdu, pdu_offset)
        _, varbinds, pdu_offset = read_tlv(pdu, pdu_offset)
        _, varbind, _ = read_tlv(varbinds, 0)
        vb_offset = 0
        _, oid_raw, vb_offset = read_tlv(varbind, vb_offset)
        value_tag, value_raw, _ = read_tlv(varbind, vb_offset)
        return {
            "version": decode_int(version_raw) + 1,
            "community_length": len(community_raw),
            "pdu_tag": pdu_tag,
            "request_id": decode_int(request_id_raw),
            "error_status": decode_int(error_status_raw),
            "error_index": decode_int(error_index_raw),
            "oid": decode_oid(oid_raw),
            "value": decode_snmp_value(value_tag, value_raw),
        }
    except Exception as exc:
        return {"parse_error": str(exc), "response_hex": data.hex()[:4096]}


def handle_snmp(args):
    host = safe_host(args.get("host"), "host")
    oid = str(args.get("oid") or ".1.3.6.1.2.1.1.1.0").strip()
    community = str(args.get("community") or "public")
    port = int_arg(args, "port", 161, 1, 65535)
    timeout = timeout_arg(args, default_ms=3000, maximum_ms=10000)
    packet = snmp_packet(oid, community, int(time.time()) & 0x7FFFFFFF)
    if bool_arg(args, "dry_run", False):
        success("snmp", "planned", host=host, port=port, oid=oid, version="2c", community_provided=bool(community), request_bytes=len(packet))
        return
    require_authorized_scope(args, [host], "SNMP query sends UDP packets to the target")
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.settimeout(timeout)
            started = time.monotonic()
            sock.sendto(packet, (host, port))
            data, address = sock.recvfrom(65535)
            latency_ms = round((time.monotonic() - started) * 1000, 2)
    except OSError as exc:
        raise ToolError("query_failed", str(exc), host=host, port=port, oid=oid)
    success("snmp", "resolved", host=host, address=address[0], port=address[1], oid=oid, latency_ms=latency_ms, response=decode_snmp_response(data))


def handle_firewall(args):
    action = str(args.get("action") or "status").lower()
    if action == "status":
        commands = []
        if command_exists("nft"):
            commands.append(run_command(["nft", "list", "ruleset"], timeout=5, max_chars=20000))
        if command_exists("iptables"):
            commands.append(run_command(["iptables", "-S"], timeout=5, max_chars=12000))
        if command_exists("ufw"):
            commands.append(run_command(["ufw", "status", "verbose"], timeout=5, max_chars=12000))
        if command_exists("firewall-cmd"):
            commands.append(run_command(["firewall-cmd", "--state"], timeout=5, max_chars=4000))
        success("firewall", "inspected", commands=commands, supported=bool(commands))
        return
    if action not in {"plan", "apply"}:
        raise ToolError("invalid_action", "action must be status, plan, or apply")
    rule = args.get("rule") if isinstance(args.get("rule"), dict) else {}
    decision = str(rule.get("decision") or args.get("decision") or "allow").lower()
    protocol = str(rule.get("protocol") or args.get("protocol") or "tcp").lower()
    port = int(rule.get("port") or args.get("port") or 0)
    source = str(rule.get("source") or args.get("source") or "any")
    if decision not in {"allow", "deny"}:
        raise ToolError("invalid_rule", "decision must be allow or deny")
    if protocol not in {"tcp", "udp"}:
        raise ToolError("invalid_rule", "protocol must be tcp or udp")
    if port < 1 or port > 65535:
        raise ToolError("invalid_rule", "port must be between 1 and 65535")
    plans = {
        "ufw": ["ufw", decision, "proto", protocol, "from", source, "to", "any", "port", str(port)],
        "nft": ["nft", "add", "rule", "inet", "filter", "input", protocol, "dport", str(port), "counter", "accept" if decision == "allow" else "drop"],
    }
    if action == "plan" or not bool_arg(args, "apply", False):
        success("firewall", "planned", rule={"decision": decision, "protocol": protocol, "port": port, "source": source}, commands=plans)
        return
    if str(args.get("confirm") or "") != "APPLY_FIREWALL_CHANGE":
        raise ToolError("confirmation_required", "set confirm to APPLY_FIREWALL_CHANGE to modify firewall rules")
    if not command_exists("ufw"):
        raise ToolError("missing_dependency", "ufw is required for guarded apply")
    result = run_command(plans["ufw"], timeout=15, max_chars=12000)
    success("firewall", "applied" if result["ok"] else "apply_failed", rule={"decision": decision, "protocol": protocol, "port": port, "source": source}, command=result)


def handle_subnet_calculator(args):
    cidr = str(args.get("cidr") or args.get("network") or "").strip()
    if not cidr:
        raise ToolError("missing_cidr", "cidr is required")
    network = ip_network(cidr, strict=False)
    hosts = list(network.hosts()) if network.num_addresses <= 4096 else []
    first_host = str(hosts[0]) if hosts else ""
    last_host = str(hosts[-1]) if hosts else ""
    result = {
        "input": cidr,
        "network": str(network.network_address),
        "cidr": str(network),
        "version": network.version,
        "prefixlen": network.prefixlen,
        "netmask": str(network.netmask),
        "hostmask": str(network.hostmask),
        "num_addresses": network.num_addresses,
        "usable_hosts": max(network.num_addresses - 2, 0) if network.version == 4 and network.prefixlen <= 30 else len(hosts) if hosts else None,
        "first_host": first_host,
        "last_host": last_host,
    }
    if network.version == 4:
        result["broadcast"] = str(network.broadcast_address)
    if args.get("new_prefix") is not None:
        new_prefix = int_arg(args, "new_prefix", network.prefixlen, network.prefixlen, network.max_prefixlen)
        limit = int_arg(args, "limit", 32, 1, 512)
        result["subnets"] = [str(item) for _, item in zip(range(limit), network.subnets(new_prefix=new_prefix))]
    success("subnet-calculator", "calculated", result=result)


def parse_int_value(value):
    if isinstance(value, int):
        return value
    text = str(value).strip().lower().replace("_", "")
    if text.startswith("0b"):
        return int(text[2:], 2)
    if text.startswith("0x"):
        return int(text[2:], 16)
    if re.fullmatch(r"[01]{2,}", text):
        return int(text, 2)
    return int(text, 10)


def bit_repr(value, width):
    mask = (1 << width) - 1
    normalized = value & mask
    return {
        "decimal": normalized,
        "hex": hex(normalized),
        "binary": format(normalized, f"0{width}b"),
        "set_bits": [index for index in range(width) if normalized & (1 << index)],
        "clear_bits": [index for index in range(width) if not normalized & (1 << index)],
    }


def handle_bit_calculator(args):
    width = int_arg(args, "width", 32, 1, 128)
    operation = str(args.get("operation") or "convert").lower()
    mask = (1 << width) - 1
    values_arg = args.get("values")
    if values_arg is None:
        values = [parse_int_value(args.get("value", 0))]
    else:
        raw_values = values_arg if isinstance(values_arg, list) else [values_arg]
        values = [parse_int_value(item) for item in raw_values]
    if operation == "convert":
        result_value = values[0]
    elif operation == "not":
        result_value = (~values[0]) & mask
    elif operation in {"and", "or", "xor"}:
        if len(values) < 2:
            raise ToolError("missing_values", "and/or/xor require at least two values")
        result_value = values[0]
        for value in values[1:]:
            if operation == "and":
                result_value &= value
            elif operation == "or":
                result_value |= value
            else:
                result_value ^= value
    elif operation in {"shl", "shr"}:
        shift = int_arg(args, "shift", 1, 0, width)
        result_value = (values[0] << shift) if operation == "shl" else (values[0] >> shift)
    else:
        raise ToolError("invalid_operation", "operation must be convert, not, and, or, xor, shl, or shr")
    success("bit-calculator", "calculated", width=width, operation=operation, inputs=[bit_repr(value, width) for value in values], result=bit_repr(result_value, width))


HANDLERS = {
    "ip-scanner": handle_ip_scanner,
    "port-scanner": handle_port_scanner,
    "discovery-protocol": handle_discovery_protocol,
    "wake-on-lan": handle_wake_on_lan,
    "network-interface": handle_network_interface,
    "wifi": handle_wifi,
    "connections": handle_connections,
    "listeners": handle_listeners,
    "neighbor-table": handle_neighbor_table,
    "ping-monitor": handle_ping_monitor,
    "traceroute": handle_traceroute,
    "dns-lookup": handle_dns_lookup,
    "sntp-lookup": handle_sntp_lookup,
    "whois": handle_whois,
    "ip-geolocation": handle_ip_geolocation,
    "hosts-file-editor": handle_hosts_file_editor,
    "lookup": handle_lookup,
    "snmp": handle_snmp,
    "firewall": handle_firewall,
    "subnet-calculator": handle_subnet_calculator,
    "bit-calculator": handle_bit_calculator,
}


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in HANDLERS:
        emit({"ok": False, "tool": "network.ops", "status": "unknown_tool", "error": "unknown network ops tool"})
        return 0
    tool = sys.argv[1]
    try:
        args = parse_args(sys.argv[2] if len(sys.argv) > 2 else "{}")
        HANDLERS[tool](args)
    except ToolError as exc:
        fail(tool, exc.status, exc.message, **exc.extra)
    except Exception as exc:
        fail(tool, "unexpected_error", str(exc))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
