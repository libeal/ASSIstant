#!/usr/bin/env python3
import json
import math
import os
import re
import shutil
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import time
import hashlib
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from ipaddress import collapse_addresses, ip_address, ip_interface, ip_network
from pathlib import Path

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if _SCRIPT_DIR not in sys.path:
    sys.path.insert(0, _SCRIPT_DIR)
import _snmp  # noqa: E402  sibling helper module (SNMP v1/v2c/v3 codec)
import _dns  # noqa: E402  sibling helper module (pure-Python DNS resolver)


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
    "tls-inspect": "medium",
    "http-check": "medium",
    "public-ip": "medium",
    "service-discovery": "medium",
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
    "info": "whois.nic.info",
    "biz": "whois.nic.biz",
    "io": "whois.nic.io",
    "co": "whois.nic.co",
    "dev": "whois.nic.google",
    "app": "whois.nic.google",
    "ai": "whois.nic.ai",
    "us": "whois.nic.us",
    "uk": "whois.nic.uk",
    "de": "whois.denic.de",
    "eu": "whois.eu",
    "cn": "whois.cnnic.cn",
    "jp": "whois.jprs.jp",
    "ca": "whois.cira.ca",
    "au": "whois.auda.org.au",
    "nl": "whois.domain-registry.nl",
    "fr": "whois.nic.fr",
    "ru": "whois.tcinet.ru",
    "xyz": "whois.nic.xyz",
    "me": "whois.nic.me",
    "cloud": "whois.nic.cloud",
}
WHOIS_REFERRAL_PATTERNS = [
    r"(?im)^\s*refer:\s*(\S+)",
    r"(?im)^\s*whois:\s*(\S+)",
    r"(?im)^\s*ReferralServer:\s*(?:whois://)?(\S+)",
    r"(?im)^\s*Registrar WHOIS Server:\s*(\S+)",
]


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


def validate_http_target(url, args, reason):
    parsed = urllib.parse.urlparse(str(url or ""))
    if parsed.scheme.lower() not in {"http", "https"}:
        raise ToolError("invalid_url", "url must use http:// or https://")
    if not parsed.hostname:
        raise ToolError("invalid_url", "url has no host component")
    require_authorized_scope(args, [parsed.hostname], reason)
    return parsed


class AuthorizedRedirectHandler(urllib.request.HTTPRedirectHandler):
    def __init__(self, args, chain, reason):
        self.args = args
        self.chain = chain
        self.reason = reason

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        validate_http_target(newurl, self.args, self.reason)
        self.chain.append({"status": code, "location": newurl})
        return super().redirect_request(req, fp, code, msg, headers, newurl)


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


def resolve_udp_target(host, port):
    infos = socket.getaddrinfo(host, port, socket.AF_UNSPEC, socket.SOCK_DGRAM)
    if not infos:
        raise OSError(f"could not resolve {host}")
    family, _type, _proto, _canon, sockaddr = infos[0]
    return family, sockaddr


def service_name(port, protocol="tcp"):
    try:
        return socket.getservbyport(int(port), protocol)
    except (OSError, ValueError):
        return ""


def tcp_banner(target, port, timeout):
    try:
        with socket.create_connection((target, port), timeout=timeout) as sock:
            sock.settimeout(timeout)
            try:
                data = sock.recv(256)
            except socket.timeout:
                data = b""
    except OSError:
        return ""
    return short_text(data.decode("latin-1", errors="replace").strip(), 256)


def udp_payload(port):
    if port == 53:
        return _dns.build_query("example.com", 1)[1]
    if port == 123:
        return b"\x23" + b"\x00" * 47
    return b""


def udp_probe(target, port, timeout):
    try:
        family, sockaddr = resolve_udp_target(target, port)
        with socket.socket(family, socket.SOCK_DGRAM) as sock:
            sock.settimeout(timeout)
            sock.sendto(udp_payload(port), sockaddr)
            try:
                data, _address = sock.recvfrom(2048)
                return {"port": port, "protocol": "udp", "state": "open", "bytes": len(data), "service": service_name(port, "udp")}
            except socket.timeout:
                return {"port": port, "protocol": "udp", "state": "open|filtered", "service": service_name(port, "udp")}
    except ConnectionRefusedError:
        return {"port": port, "protocol": "udp", "state": "closed"}
    except OSError as exc:
        return {"port": port, "protocol": "udp", "state": "error", "error": str(exc)}


def read_neighbor_macs():
    macs = {}
    if not command_exists("ip"):
        return macs
    result = run_command(["ip", "-j", "neigh", "show"], timeout=5, max_chars=40000)
    if result["stdout"].strip():
        try:
            for entry in json.loads(result["stdout"]):
                if entry.get("dst") and entry.get("lladdr"):
                    macs[entry["dst"]] = entry["lladdr"]
        except (json.JSONDecodeError, TypeError, AttributeError):
            pass
    return macs


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
    resolve_hostnames = bool_arg(args, "resolve_hostnames", True)

    def scan_one(target):
        ping = ping_once(target, timeout) if bool_arg(args, "ping", True) else {"available": False, "up": None, "raw": ""}
        tcp = [tcp_probe(target, port, timeout) for port in ports]
        for probe in tcp:
            if probe["state"] == "open":
                probe["service"] = service_name(probe["port"], "tcp")
        open_ports = [item["port"] for item in tcp if item["state"] == "open"]
        up = is_loopback_literal(target) or ping.get("up") is True or bool(open_ports)
        item = {"target": target, "up": up, "ping": ping, "tcp": tcp, "open_ports": open_ports}
        item["hostname"] = ""
        if resolve_hostnames:
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
    if bool_arg(args, "resolve_mac", False):
        macs = read_neighbor_macs()
        for item in results:
            mac = macs.get(item["target"])
            if mac:
                item["mac"] = mac
                try:
                    item["vendor"] = lookup_oui(mac).get("vendor", "")
                except ToolError:
                    item["vendor"] = ""
    results.sort(key=lambda item: ip_address(item["target"]))
    success("ip-scanner", "scanned", scanned_hosts=len(targets), returned_hosts=len(results), alive_count=sum(1 for item in results if item["up"]), ports=ports, results=results)


def handle_port_scanner(args):
    target = safe_host(args.get("target"), "target")
    protocol = str(args.get("protocol") or "tcp").lower()
    if protocol not in {"tcp", "udp"}:
        raise ToolError("invalid_protocol", "protocol must be tcp or udp")
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
    require_authorized_scope(args, [target], "Port scanning opens connections to the target")
    timeout = timeout_arg(args, default_ms=750, maximum_ms=5000)
    grab_banner = bool_arg(args, "banner", False)
    workers = int_arg(args, "workers", min(128, len(ports)), 1, 256)

    def probe(port):
        if protocol == "udp":
            return udp_probe(target, port, timeout)
        result = tcp_probe(target, port, timeout)
        if result["state"] == "open":
            result["service"] = service_name(port, "tcp")
            if grab_banner:
                banner = tcp_banner(target, port, timeout)
                if banner:
                    result["banner"] = banner
        return result

    results = []
    with ThreadPoolExecutor(max_workers=workers) as executor:
        futures = {executor.submit(probe, port): port for port in ports}
        for future in as_completed(futures):
            results.append(future.result())
    results.sort(key=lambda item: item["port"])
    open_ports = [item["port"] for item in results if item["state"] in {"open", "open|filtered"}]
    success("port-scanner", "scanned", target=target, protocol=protocol, scanned_ports=len(ports), open_ports=open_ports, results=results)


def parse_lldp_json(text):
    neighbors = []
    try:
        data = json.loads(text)
    except (json.JSONDecodeError, TypeError):
        return neighbors
    lldp = data.get("lldp", data) if isinstance(data, dict) else {}
    interfaces = lldp.get("interface", []) if isinstance(lldp, dict) else []
    if isinstance(interfaces, dict):
        interfaces = [interfaces]
    for entry in interfaces:
        if not isinstance(entry, dict):
            continue
        for ifname, body in entry.items():
            if not isinstance(body, dict):
                continue
            chassis_name, mgmt_ip = "", ""
            chassis = body.get("chassis", {})
            if isinstance(chassis, dict):
                for name, cbody in chassis.items():
                    if isinstance(cbody, dict):
                        chassis_name = name
                        mgmt = cbody.get("mgmt-ip")
                        mgmt_ip = ", ".join(str(m) for m in mgmt) if isinstance(mgmt, list) else str(mgmt or "")
                        break
            port = body.get("port", {})
            port_id, port_descr = "", ""
            if isinstance(port, dict):
                pid = port.get("id")
                port_id = str(pid.get("value") or "") if isinstance(pid, dict) else str(pid or "")
                port_descr = str(port.get("descr") or "")
            vlan = body.get("vlan", "")
            neighbors.append({
                "interface": ifname,
                "chassis": chassis_name,
                "mgmt_ip": mgmt_ip,
                "port_id": port_id,
                "port_descr": port_descr,
                "vlan": vlan if isinstance(vlan, (str, int)) else "",
            })
    return neighbors


def handle_discovery_protocol(args):
    interface = safe_interface(args.get("interface"))
    limit = int_arg(args, "limit", 80, 1, 300)
    protocol = str(args.get("protocol") or "lldp").lower()
    if protocol not in {"lldp", "cdp", "all"}:
        raise ToolError("invalid_protocol", "protocol must be lldp, cdp, or all")
    observations = []
    neighbors = []

    if protocol in {"lldp", "all"}:
        commands = []
        if command_exists("lldpcli"):
            commands.append(["lldpcli", "-f", "json", "show", "neighbors"])
        if command_exists("networkctl"):
            commands.append(["networkctl", "lldp", interface] if interface else ["networkctl", "lldp"])
        for command in commands:
            result = run_command(command, timeout=5, max_chars=10000)
            observations.append(result)
            if result["ok"] and result["stdout"].strip():
                if command[0] == "lldpcli":
                    neighbors.extend(parse_lldp_json(result["stdout"]))
                break

    if protocol in {"cdp", "all"}:
        if command_exists("cdpr"):
            require_authorized_scope(args, [interface or "cdp-capture"], "CDP capture listens on an interface")
            cdp_cmd = ["cdpr", "-d", interface] if interface else ["cdpr"]
            observations.append(run_command(cdp_cmd, timeout=8, max_chars=8000))
        else:
            observations.append({"command": ["cdpr"], "exit_code": 127, "stdout": "", "stderr": "cdpr not available; CDP capture skipped", "ok": False})

    if not observations:
        success("discovery-protocol", "unsupported", interface=interface, protocol=protocol, neighbors=[], message="No LLDP/CDP discovery command is available.")
        return
    text = "\n".join(item.get("stdout") or item.get("stderr") or "" for item in observations)
    lines = [line for line in text.splitlines() if line.strip()][:limit]
    success("discovery-protocol", "inspected", interface=interface, protocol=protocol, neighbors=neighbors, commands=observations, lines=lines)


def normalize_mac(value):
    text = re.sub(r"[^0-9A-Fa-f]", "", str(value or ""))
    if len(text) != 12:
        raise ToolError("invalid_mac", "mac must contain 12 hexadecimal characters")
    return ":".join(text[index:index + 2] for index in range(0, 12, 2)).lower()


def handle_wake_on_lan(args):
    mac = normalize_mac(args.get("mac"))
    broadcast = str(args.get("broadcast") or args.get("target") or "255.255.255.255").strip()
    port = int_arg(args, "port", 9, 1, 65535)
    repeat = int_arg(args, "repeat", 1, 1, 10)
    dry_run = bool_arg(args, "dry_run", False)
    mac_hex = re.sub(r"[^0-9A-Fa-f]", "", mac)
    packet = bytes.fromhex("ff" * 6 + mac_hex * 16)
    secure_on = str(args.get("secure_on") or "").strip()
    if secure_on:
        secure_hex = re.sub(r"[^0-9A-Fa-f]", "", secure_on)
        if len(secure_hex) != 12:
            raise ToolError("invalid_secure_on", "secure_on password must contain 12 hexadecimal characters (6 bytes)")
        packet += bytes.fromhex(secure_hex)
    if dry_run:
        success("wake-on-lan", "planned", mac=mac, broadcast=broadcast, port=port, repeat=repeat, secure_on=bool(secure_on), packet_bytes=len(packet))
        return
    require_authorized_scope(args, [broadcast], "Wake-on-LAN sends a magic packet")
    try:
        family, sockaddr = resolve_udp_target(broadcast, port)
        sent = 0
        with socket.socket(family, socket.SOCK_DGRAM) as sock:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
            for _ in range(repeat):
                sent += sock.sendto(packet, sockaddr)
    except OSError as exc:
        raise ToolError("send_failed", str(exc), mac=mac, broadcast=broadcast, port=port)
    success("wake-on-lan", "sent", mac=mac, broadcast=broadcast, port=port, repeat=repeat, secure_on=bool(secure_on), sent_bytes=sent)


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
        stats_dir = child / "statistics"
        statistics = {}
        if stats_dir.is_dir():
            for counter in ("rx_bytes", "tx_bytes", "rx_packets", "tx_packets", "rx_errors", "tx_errors", "rx_dropped", "tx_dropped"):
                value = read_sysfs(stats_dir / counter)
                if value:
                    statistics[counter] = int(value)
        sysfs.append({
            "name": child.name,
            "operstate": read_sysfs(child / "operstate"),
            "address": read_sysfs(child / "address"),
            "mtu": int(read_sysfs(child / "mtu") or 0),
            "speed": read_sysfs(child / "speed"),
            "carrier": read_sysfs(child / "carrier"),
            "wireless": (child / "wireless").exists(),
            "statistics": statistics,
        })

    gateways = []
    for route_entry in routes:
        if isinstance(route_entry, dict) and route_entry.get("dst") == "default" and route_entry.get("gateway"):
            gateways.append({"gateway": route_entry["gateway"], "dev": route_entry.get("dev", ""), "metric": route_entry.get("metric")})

    dns_servers = []
    try:
        for line in Path("/etc/resolv.conf").read_text(encoding="utf-8", errors="replace").splitlines():
            parts = line.split()
            if len(parts) >= 2 and parts[0] == "nameserver":
                dns_servers.append(parts[1])
    except OSError:
        pass

    success("network-interface", "inspected", interface=selected, interfaces=interfaces, routes=routes,
            default_gateways=gateways, dns_servers=dns_servers, sysfs=sysfs, commands={"address": addr, "routes": route if command_exists("ip") else {}})


NMCLI_WIFI_FIELDS = "IN-USE,SSID,BSSID,CHAN,FREQ,RATE,SIGNAL,SECURITY"


def split_nmcli_terse(line):
    fields = re.split(r"(?<!\\):", line)
    return [field.replace("\\:", ":").replace("\\\\", "\\") for field in fields]


def parse_nmcli_wifi(text):
    rows = []
    for line in text.splitlines():
        if not line.strip():
            continue
        fields = split_nmcli_terse(line)
        fields += [""] * (8 - len(fields))
        rows.append({
            "in_use": fields[0].strip() in {"*", "yes"},
            "ssid": fields[1],
            "bssid": fields[2],
            "channel": fields[3],
            "freq": fields[4],
            "rate": fields[5],
            "signal": fields[6],
            "security": fields[7],
        })
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
        command = ["nmcli", "-t", "-f", NMCLI_WIFI_FIELDS, "dev", "wifi", "list", "--rescan", "yes" if scan else "no"]
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


SS_NETIDS = {"tcp", "udp", "raw", "unix", "packet", "sctp", "dccp", "tipc", "vsock", "xdp", "nl", "icmp", "p_raw", "p_dgr"}


def split_host_port(value):
    text = str(value or "").strip()
    if not text:
        return "", ""
    if text.startswith("[") and "]" in text:  # [ipv6]:port
        host, _, port = text.rpartition(":")
        return host.strip("[]"), port
    host, sep, port = text.rpartition(":")
    if sep and re.fullmatch(r"\d{1,5}|\*|%[A-Za-z0-9]+", port):
        return host, port
    return text, ""


def parse_ss_process(text):
    procs = []
    for match in re.finditer(r'"([^"]+)",pid=(\d+)', text):
        procs.append({"name": match.group(1), "pid": int(match.group(2))})
    return procs


def parse_ss_lines(text, limit):
    rows = []
    for line in text.splitlines():
        if not line.strip():
            continue
        fields = line.split()
        row = {"raw": line}
        netid = ""
        if fields and fields[0].lower() in SS_NETIDS:
            netid = fields.pop(0)
        if len(fields) >= 5:
            local_host, local_port = split_host_port(fields[3])
            peer_host, peer_port = split_host_port(fields[4])
            row.update({
                "netid": netid,
                "state": fields[0],
                "recv_q": fields[1],
                "send_q": fields[2],
                "local": fields[3],
                "local_address": local_host,
                "local_port": local_port,
                "peer": fields[4],
                "peer_address": peer_host,
                "peer_port": peer_port,
            })
            process_text = " ".join(fields[5:])
            procs = parse_ss_process(process_text) if process_text else []
            if procs:
                row["processes"] = procs
        rows.append(row)
        if len(rows) >= limit:
            break
    return rows


def ss_state_summary(rows):
    summary = {}
    for row in rows:
        state = row.get("state", "")
        if state:
            summary[state] = summary.get(state, 0) + 1
    return summary


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
    all_rows = parse_ss_lines(result["stdout"], 5000)
    matched = [row for row in all_rows if row.get("state", "").lower() == state] if state else all_rows
    rows = matched[:limit]
    success("connections", "inspected", protocol=protocol, state=state, limit=limit, total=len(matched), summary=ss_state_summary(matched), connections=rows, command=result)


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
    all_rows = parse_ss_lines(result["stdout"], 5000)
    matched = [row for row in all_rows if row.get("local_port") == port_filter] if port_filter else all_rows
    rows = matched[:limit]
    success("listeners", "inspected", protocol=protocol, port=port_filter, limit=limit, total=len(matched), summary=ss_state_summary(matched), listeners=rows, command=result)


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
    series = [float(value) for value in re.findall(r"time[=<]\s*([0-9.]+)\s*ms", stdout)]
    transmitted = received = None
    loss = ""
    match = re.search(r"(\d+)\s+packets transmitted,\s+(\d+)\s+(?:packets )?received,\s+([^,\n]+?)\s+packet loss", stdout)
    if match:
        transmitted, received, loss = int(match.group(1)), int(match.group(2)), match.group(3)
    elif series:
        transmitted, received, loss = count, len(series), f"{round((count - len(series)) / count * 100)}%"
    rtt = {}
    match = re.search(r"(?:rtt|round-trip)[^=]*=\s*([0-9.]+)/([0-9.]+)/([0-9.]+)(?:/([0-9.]+))?", stdout)
    if match:
        rtt = {"min_ms": float(match.group(1)), "avg_ms": float(match.group(2)), "max_ms": float(match.group(3))}
        if match.group(4):
            rtt["mdev_ms"] = float(match.group(4))
    elif series:
        rtt = {"min_ms": min(series), "avg_ms": round(sum(series) / len(series), 3), "max_ms": max(series)}
    if len(series) > 1 and "jitter_ms" not in rtt:
        diffs = [abs(series[index] - series[index - 1]) for index in range(1, len(series))]
        rtt["jitter_ms"] = round(sum(diffs) / len(diffs), 3)
    success("ping-monitor", "completed", target=target, transmitted=transmitted, received=received, packet_loss=loss, rtt=rtt, samples=series, command=result)


def parse_traceroute_hops(text):
    hops = []
    for line in text.splitlines():
        stripped = line.strip()
        match = re.match(r"^(\d+)[:?]?\s+(.*)$", stripped)
        if not match:
            continue
        rest = match.group(2)
        addresses, hostnames = [], []
        for token in re.split(r"\s+", rest):
            cleaned = token.strip("()[]")
            if not cleaned:
                continue
            try:
                ip_address(cleaned)
                if cleaned not in addresses:
                    addresses.append(cleaned)
                continue
            except ValueError:
                pass
            if "." in cleaned and re.fullmatch(r"[A-Za-z][A-Za-z0-9.-]+", cleaned) and cleaned not in hostnames:
                hostnames.append(cleaned)
        rtts = [float(value) for value in re.findall(r"([0-9]+(?:\.[0-9]+)?)\s*ms", rest)]
        hops.append({"hop": int(match.group(1)), "addresses": addresses, "hostnames": hostnames, "rtt_ms": rtts, "raw": stripped})
    return hops


def build_traceroute_command(target, mode, has_traceroute, has_tracepath, max_hops, timeout):
    if has_traceroute:
        command = ["traceroute", "-n", "-m", str(max_hops), "-w", str(timeout)]
        command.extend({"icmp": ["-I"], "tcp": ["-T"], "udp": ["-U"]}.get(mode, []))
        command.append(target)
        return command
    if has_tracepath:
        if mode != "default":
            raise ToolError("unsupported_mode", "tracepath fallback supports only default mode")
        return ["tracepath", "-m", str(max_hops), target]
    raise ToolError("missing_dependency", "tracepath or traceroute is required for non-loopback targets")


def handle_traceroute(args):
    target = safe_host(args.get("target"), "target")
    require_authorized_scope(args, [target], "Traceroute sends TTL-limited probes")
    if is_loopback_literal(target):
        success("traceroute", "completed", target=target, hops=[{"hop": 1, "addresses": [target], "hostnames": [], "rtt_ms": [], "raw": "loopback"}], command=None)
        return
    max_hops = int_arg(args, "max_hops", 30, 1, 64)
    timeout = max(1, int(math.ceil(timeout_arg(args, default_ms=2000, maximum_ms=10000))))
    mode = str(args.get("mode") or "default").lower()
    if mode not in {"default", "icmp", "tcp", "udp"}:
        raise ToolError("invalid_mode", "mode must be default, icmp, tcp, or udp")
    command = build_traceroute_command(
        target,
        mode,
        has_traceroute=command_exists("traceroute"),
        has_tracepath=command_exists("tracepath"),
        max_hops=max_hops,
        timeout=timeout,
    )
    result = run_command(command, timeout=max_hops * (timeout + 1), max_chars=16000)
    hops = parse_traceroute_hops(result["stdout"])
    success("traceroute", "completed" if result["ok"] else "command_failed", target=target, mode=mode, hops=hops, command=result)


def handle_dns_lookup(args):
    query = safe_host(args.get("query") or args.get("host"), "query")
    raw_types = args.get("record_types") or args.get("record_type") or args.get("type") or "A"
    if isinstance(raw_types, list):
        types = [str(item).upper() for item in raw_types if str(item).strip()]
    else:
        types = [item.strip().upper() for item in re.split(r"[,\s]+", str(raw_types)) if item.strip()]
    types = types or ["A"]
    server = str(args.get("server") or "").strip()
    port = int_arg(args, "port", 53, 1, 65535)
    timeout_ms = int_arg(args, "timeout_ms", 3000, 100, 10000)
    if server and not re.fullmatch(r"[A-Za-z0-9_.:-]{1,253}", server):
        raise ToolError("invalid_server", "server contains unsupported characters")
    have_dig = command_exists("dig")
    records = []
    commands = []
    for record_type in types:
        lookup_name = query
        if record_type == "PTR":
            try:
                lookup_name = ip_address(query).reverse_pointer
            except ValueError:
                pass
        if have_dig:
            command = ["dig", "+time=" + str(max(1, math.ceil(timeout_ms / 1000))), "+tries=1"]
            if server:
                command.append("@" + server)
            if port != 53:
                command.extend(["-p", str(port)])
            command.extend([lookup_name, record_type, "+short"])
            command_result = run_command(command, timeout=timeout_ms / 1000 + 2, max_chars=12000)
            commands.append(command_result)
            records.extend({"type": record_type, "value": line.strip()} for line in command_result["stdout"].splitlines() if line.strip())
        elif record_type in {"A", "AAAA", "ANY"} and not server:
            family = socket.AF_UNSPEC if record_type == "ANY" else socket.AF_INET if record_type == "A" else socket.AF_INET6
            try:
                for item in socket.getaddrinfo(lookup_name, None, family, socket.SOCK_STREAM):
                    address = item[4][0]
                    record = {"type": "AAAA" if ":" in address else "A", "value": address}
                    if record not in records:
                        records.append(record)
            except OSError as exc:
                raise ToolError("query_failed", str(exc))
            commands.append({"resolver": "getaddrinfo", "record_type": record_type})
        elif record_type == "PTR" and not server:
            try:
                records.append({"type": "PTR", "value": socket.gethostbyaddr(query)[0]})
            except OSError as exc:
                raise ToolError("query_failed", str(exc))
            commands.append({"resolver": "gethostbyaddr"})
        else:
            try:
                resolved = _dns.query(lookup_name, record_type, server or None, port, timeout_ms / 1000.0)
            except _dns.DnsError as exc:
                raise ToolError(exc.status, exc.message)
            except OSError as exc:
                raise ToolError("query_failed", str(exc))
            commands.append({"resolver": "builtin", "server": resolved.get("server"), "rcode": resolved.get("rcode_text")})
            records.extend({"type": answer["type"], "value": answer["value"], "ttl": answer["ttl"]} for answer in resolved["answers"])
    success("dns-lookup", "resolved", query=query, record_types=types, server=server, records=records, commands=commands)


def handle_sntp_lookup(args):
    server = safe_host(args.get("server") or "pool.ntp.org", "server")
    port = int_arg(args, "port", 123, 1, 65535)
    timeout = timeout_arg(args, default_ms=3000, maximum_ms=10000)
    if bool_arg(args, "dry_run", False):
        success("sntp-lookup", "planned", server=server, port=port, timeout_ms=int(timeout * 1000))
        return
    try:
        family, sockaddr = resolve_udp_target(server, port)
    except OSError as exc:
        raise ToolError("dns_error", str(exc), server=server)
    ntp_epoch = 2208988800
    packet = bytearray(48)
    packet[0] = 0x23  # LI=0, VN=4, Mode=3 (client)
    t1 = time.time()
    struct.pack_into("!Q", packet, 40, (int(t1) + ntp_epoch << 32) | int((t1 - int(t1)) * 2**32))
    try:
        with socket.socket(family, socket.SOCK_DGRAM) as sock:
            sock.settimeout(timeout)
            started = time.monotonic()
            sock.sendto(bytes(packet), sockaddr)
            data, address = sock.recvfrom(512)
            t4 = time.time()
            latency_ms = round((time.monotonic() - started) * 1000, 2)
    except socket.timeout:
        raise ToolError("timeout", "no SNTP response before timeout", server=server, port=port)
    except OSError as exc:
        raise ToolError("query_failed", str(exc), server=server, port=port)
    if len(data) < 48:
        raise ToolError("invalid_response", "SNTP response is shorter than 48 bytes", size_bytes=len(data))

    def from_ntp(value):
        return (value >> 32) - ntp_epoch + (value & 0xFFFFFFFF) / 2**32

    li_vn_mode = data[0]
    stratum = data[1]
    poll = struct.unpack("!b", data[2:3])[0]
    precision = struct.unpack("!b", data[3:4])[0]
    root_delay = struct.unpack("!I", data[4:8])[0] / 2**16
    root_dispersion = struct.unpack("!I", data[8:12])[0] / 2**16
    ref_id = data[12:16]
    reference_ts = from_ntp(struct.unpack("!Q", data[16:24])[0])
    recv_ts = from_ntp(struct.unpack("!Q", data[32:40])[0])   # T2
    xmit_ts = from_ntp(struct.unpack("!Q", data[40:48])[0])   # T3
    offset = ((recv_ts - t1) + (xmit_ts - t4)) / 2
    delay = (t4 - t1) - (xmit_ts - recv_ts)
    if stratum <= 1:
        reference_id = ref_id.rstrip(b"\x00").decode("ascii", errors="replace")
    else:
        reference_id = ".".join(str(byte) for byte in ref_id)

    def iso(value):
        return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(value))

    success("sntp-lookup", "resolved", server=server, address=address[0], port=port,
            leap=(li_vn_mode >> 6) & 0x3, version=(li_vn_mode >> 3) & 0x7, mode=li_vn_mode & 0x7,
            stratum=stratum, poll=poll, precision=precision,
            root_delay_ms=round(root_delay * 1000, 3), root_dispersion_ms=round(root_dispersion * 1000, 3),
            reference_id=reference_id, reference_time=iso(reference_ts),
            unix_time=xmit_ts, utc=iso(xmit_ts), server_time=iso(xmit_ts),
            offset_ms=round(offset * 1000, 3), delay_ms=round(delay * 1000, 3), latency_ms=latency_ms)


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


def initial_whois_server(query):
    text = query.strip()
    if re.fullmatch(r"(?i)as\d+", text):
        return "whois.iana.org"
    try:
        ip_address(text)
        return "whois.iana.org"
    except ValueError:
        pass
    suffix = text.rsplit(".", 1)[-1].lower() if "." in text else ""
    return WHOIS_TLD_SERVERS.get(suffix, "whois.iana.org")


def find_whois_referral(response):
    for pattern in WHOIS_REFERRAL_PATTERNS:
        match = re.search(pattern, response)
        if match:
            referral = re.sub(r"^whois://", "", match.group(1).strip()).strip(".")
            referral = referral.split("/")[0].split(":")[0]
            if re.fullmatch(r"[A-Za-z0-9.-]+", referral):
                return referral
    return ""


def handle_whois(args):
    query = safe_host(args.get("query") or args.get("domain"), "query")
    timeout = timeout_arg(args, default_ms=5000, maximum_ms=15000)
    explicit_server = str(args.get("server") or "").strip()
    server = explicit_server or initial_whois_server(query)
    if bool_arg(args, "dry_run", False):
        success("whois", "planned", query=query, server=safe_host(server, "server"))
        return
    max_referrals = int_arg(args, "max_referrals", 3, 0, 5)
    started = time.monotonic()
    chain = []
    visited = set()
    response = ""
    for _ in range(max_referrals + 1):
        response = whois_query(query, server, timeout)
        chain.append(server)
        visited.add(server)
        if explicit_server:
            break
        referral = find_whois_referral(response)
        if not referral or referral in visited:
            break
        server = referral
    success("whois", "resolved", query=query, server=server, referral_chain=chain,
            latency_ms=round((time.monotonic() - started) * 1000, 2), response=short_text(response, 60000))


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
        merge = bool_arg(args, "merge", False)
        new_lines = list(lines)
        note = ""
        existing_index = next((index for index, line in enumerate(new_lines)
                               if line.split("#", 1)[0].split()[:1] == [host_ip]), None)
        if merge and existing_index is not None:
            body = new_lines[existing_index].split("#", 1)[0].split()
            merged = body[1:] + [name for name in hostnames if name not in body[1:]]
            new_line = f"{host_ip}\t{' '.join(merged)}"
            new_lines[existing_index] = new_line
            note = "merged into existing entry"
        else:
            new_line = f"{host_ip}\t{' '.join(hostnames)}"
            if any(line.split("#", 1)[0].split() == [host_ip, *hostnames] for line in new_lines):
                note = "entry already present"
            else:
                new_lines.append(new_line)
        apply_change = bool_arg(args, "apply", False) and action == "add"
        if not apply_change:
            success("hosts-file-editor", "planned", path=str(path), action="add", line=new_line, note=note)
            return
        if str(args.get("confirm") or "") != "APPLY_HOSTS_CHANGE":
            raise ToolError("confirmation_required", "set confirm to APPLY_HOSTS_CHANGE to modify hosts file")
        backup = write_hosts(path, new_lines)
        success("hosts-file-editor", "updated", path=str(path), action="add", line=new_line, note=note, backup_path=backup)
        return
    if action in {"remove", "plan-remove"}:
        target_host = str(args.get("hostname") or args.get("query") or "").strip()
        target_ip = str(args.get("ip") or "").strip()
        if not target_host and not target_ip:
            raise ToolError("missing_target", "remove requires hostname or ip")
        if target_host:
            target_host = safe_host(target_host, "hostname")
        kept, removed = [], []
        for line in lines:
            body = line.split("#", 1)[0].split()
            match = len(body) >= 2 and ((target_host and target_host in body[1:]) or (target_ip and body[0] == target_ip))
            (removed if match else kept).append(line)
        apply_change = bool_arg(args, "apply", False) and action == "remove"
        if not apply_change:
            success("hosts-file-editor", "planned", path=str(path), action="remove", hostname=target_host, ip=target_ip, removed=removed)
            return
        if str(args.get("confirm") or "") != "APPLY_HOSTS_CHANGE":
            raise ToolError("confirmation_required", "set confirm to APPLY_HOSTS_CHANGE to modify hosts file")
        backup = write_hosts(path, kept)
        success("hosts-file-editor", "updated", path=str(path), action="remove", hostname=target_host, ip=target_ip, removed=removed, backup_path=backup)
        return
    raise ToolError("invalid_action", "action must be read, search, plan-add, add, plan-remove, or remove")


_OUI_CACHE = {}


def lookup_oui(prefix):
    normalized = re.sub(r"[^0-9A-Fa-f]", "", prefix).upper()[:6]
    if len(normalized) < 6:
        raise ToolError("invalid_oui", "OUI lookup requires at least 6 hexadecimal characters")
    if normalized in _OUI_CACHE:
        return _OUI_CACHE[normalized]
    if normalized in OUI_BUILTINS:
        result = {"oui": normalized, "vendor": OUI_BUILTINS[normalized], "source": "builtin"}
        _OUI_CACHE[normalized] = result
        return result
    for path in ["/usr/share/misc/oui.txt", "/var/lib/ieee-data/oui.txt"]:
        file_path = Path(path)
        if not file_path.exists():
            continue
        try:
            for line in file_path.read_text(encoding="utf-8", errors="replace").splitlines():
                compact = re.sub(r"[^0-9A-Fa-f]", "", line[:16]).upper()
                if compact.startswith(normalized):
                    vendor = re.split(r"\s{2,}|\t", line, maxsplit=1)[-1].strip()
                    result = {"oui": normalized, "vendor": vendor, "source": path}
                    _OUI_CACHE[normalized] = result
                    return result
        except OSError:
            continue
    result = {"oui": normalized, "vendor": "", "source": "not_found"}
    _OUI_CACHE[normalized] = result
    return result


ICMP_TYPES = {
    0: "echo-reply", 3: "destination-unreachable", 4: "source-quench", 5: "redirect",
    8: "echo-request", 9: "router-advertisement", 10: "router-solicitation",
    11: "time-exceeded", 12: "parameter-problem", 13: "timestamp", 14: "timestamp-reply",
    17: "address-mask-request", 18: "address-mask-reply",
}


def lookup_protocol(query):
    number = None
    name = ""
    try:
        if query.isdigit():
            number = int(query)
        else:
            number = socket.getprotobyname(query.lower())
            name = query.lower()
    except OSError:
        number = None
    try:
        for line in Path("/etc/protocols").read_text(encoding="utf-8", errors="replace").splitlines():
            body = line.split("#", 1)[0].split()
            if len(body) >= 2 and body[1].isdigit():
                if (number is not None and int(body[1]) == number) or body[0].lower() == query.lower():
                    return {"protocol": body[0], "number": int(body[1])}
    except OSError:
        pass
    return {"protocol": name, "number": number}


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
    if category == "protocol":
        success("lookup", "resolved", category=category, query=query, results=[lookup_protocol(query)])
        return
    if category == "icmp":
        if query.isdigit():
            results = [{"type": int(query), "name": ICMP_TYPES.get(int(query), "")}]
        else:
            results = [{"type": number, "name": name} for number, name in ICMP_TYPES.items() if query.lower() in name]
        success("lookup", "resolved", category=category, query=query, results=results)
        return
    raise ToolError("invalid_category", "category must be port, service, oui, protocol, or icmp")


def handle_snmp(args):
    host = safe_host(args.get("host"), "host")
    version = str(args.get("version") or "2c").lower()
    action = str(args.get("action") or "get").lower()
    community = str(args.get("community") or "public")
    port = int_arg(args, "port", 161, 1, 65535)
    timeout = timeout_arg(args, default_ms=3000, maximum_ms=10000)
    max_oids = int_arg(args, "max_oids", 64, 1, 512)
    max_repetitions = int_arg(args, "max_repetitions", 10, 1, 100)

    raw_oids = args.get("oids")
    if raw_oids:
        oids = [str(item) for item in (raw_oids if isinstance(raw_oids, list) else [raw_oids])]
    else:
        oids = [str(args.get("oid") or ".1.3.6.1.2.1.1.1.0")]
    try:
        _snmp.validate_oid_limit(oids, max_oids)
    except _snmp.SnmpError as exc:
        raise ToolError(exc.status, exc.message, **exc.extra)

    is_v3 = version in {"3", "v3"}
    v3 = {}
    level = None
    if is_v3:
        if str(args.get("priv_password") or args.get("priv_protocol") or ""):
            raise ToolError("unsupported", "SNMPv3 authPriv (encryption) is not supported by this stdlib-only tool")
        v3 = {
            "user": args.get("user") or args.get("username") or "",
            "auth_protocol": args.get("auth_protocol") or "sha",
            "auth_password": args.get("auth_password") or args.get("auth_key") or "",
        }
        level = "authNoPriv" if v3["auth_password"] else "noAuthNoPriv"

    try:
        resolved_oids = [_snmp.resolve_oid(item) for item in oids]
    except _snmp.SnmpError as exc:
        raise ToolError(exc.status, exc.message, **exc.extra)

    if bool_arg(args, "dry_run", False):
        success("snmp", "planned", host=host, port=port, version=version, action=action,
                oids=resolved_oids, community_provided=bool(community),
                v3_user=(v3.get("user") if is_v3 else None), v3_level=level)
        return

    require_authorized_scope(args, [host], "SNMP query sends UDP packets to the target")
    try:
        family, sockaddr = resolve_udp_target(host, port)
    except OSError as exc:
        raise ToolError("dns_error", str(exc), host=host)
    params = {
        "host": sockaddr[0], "port": port, "family": family, "version": version,
        "action": action, "community": community, "timeout": timeout,
        "oids": oids, "max_oids": max_oids, "max_repetitions": max_repetitions, "v3": v3,
    }
    try:
        result, address, latency = _snmp.snmp_execute(params)
    except _snmp.SnmpError as exc:
        raise ToolError(exc.status, exc.message, **exc.extra)
    except socket.timeout:
        raise ToolError("timeout", "no SNMP response before timeout", host=host, port=port)
    except OSError as exc:
        raise ToolError("query_failed", str(exc), host=host, port=port)
    success("snmp", "resolved", host=host, address=(address[0] if address else host), port=port, latency_ms=latency, response=result)


def normalize_firewall_source(source):
    value = str(source or "any").strip()
    if value.lower() == "any":
        return "any", None
    try:
        network = ip_network(value, strict=False)
    except ValueError as exc:
        raise ToolError("invalid_rule", f"source must be any or an IP address/CIDR: {exc}")
    return str(network), network


def firewalld_rule_command(decision, protocol, port, source):
    normalized_source, network = normalize_firewall_source(source)
    if decision not in {"allow", "deny"}:
        raise ToolError("invalid_rule", "decision must be allow or deny")
    if protocol not in {"tcp", "udp"}:
        raise ToolError("invalid_rule", "protocol must be tcp or udp")
    if not 1 <= int(port) <= 65535:
        raise ToolError("invalid_rule", "port must be between 1 and 65535")
    family = f' family="ipv{network.version}"' if network else ""
    source_clause = f' source address="{normalized_source}"' if network else ""
    action = "accept" if decision == "allow" else "drop"
    rich_rule = f'rule{family}{source_clause} port port="{int(port)}" protocol="{protocol}" {action}'
    return ["firewall-cmd", "--permanent", "--add-rich-rule", rich_rule]


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
    source, source_network = normalize_firewall_source(source)
    rule_summary = {"decision": decision, "protocol": protocol, "port": port, "source": source}
    nft_source = []
    if source_network:
        nft_source = ["ip6" if source_network.version == 6 else "ip", "saddr", source]
    plans = {
        "ufw": ["ufw", decision, "proto", protocol, "from", source, "to", "any", "port", str(port)],
        "nft": ["nft", "add", "rule", "inet", "filter", "input"] + nft_source + [protocol, "dport", str(port), "counter", "accept" if decision == "allow" else "drop"],
        "iptables": ["iptables", "-A", "INPUT", "-p", protocol, "--dport", str(port)] + (["-s", source] if source != "any" else []) + ["-j", "ACCEPT" if decision == "allow" else "DROP"],
        "firewalld": firewalld_rule_command(decision, protocol, port, source),
    }
    backend = str(args.get("backend") or "ufw").lower()
    if backend not in {"ufw", "nft", "iptables", "firewalld"}:
        raise ToolError("unsupported_backend", "backend must be ufw, nft, iptables, or firewalld")
    if action == "plan" or not bool_arg(args, "apply", False):
        success("firewall", "planned", backend=backend, rule=rule_summary, commands=plans)
        return
    if str(args.get("confirm") or "") != "APPLY_FIREWALL_CHANGE":
        raise ToolError("confirmation_required", "set confirm to APPLY_FIREWALL_CHANGE to modify firewall rules")
    if backend not in {"ufw", "firewalld"}:
        raise ToolError("unsupported_backend", "guarded apply supports backend ufw or firewalld")
    binary = "ufw" if backend == "ufw" else "firewall-cmd"
    if not command_exists(binary):
        raise ToolError("missing_dependency", f"{binary} is required for guarded {backend} apply")
    result = run_command(plans["ufw"] if backend == "ufw" else plans["firewalld"], timeout=15, max_chars=12000)
    reload_result = None
    if backend == "firewalld" and result["ok"]:
        reload_result = run_command(["firewall-cmd", "--reload"], timeout=15, max_chars=4000)
    success("firewall", "applied" if result["ok"] else "apply_failed", backend=backend, rule=rule_summary, command=result, reload=reload_result)


def ipv4_class(address):
    first = int(str(address).split(".")[0])
    if first < 128:
        return "A"
    if first < 192:
        return "B"
    if first < 224:
        return "C"
    if first < 240:
        return "D (multicast)"
    return "E (reserved)"


def network_reverse_zone(network):
    labels = network.network_address.reverse_pointer.split(".")
    if network.version == 4:
        drop = (32 - network.prefixlen) // 8
        return ".".join(labels[drop:]) if 0 <= drop <= 4 else network.network_address.reverse_pointer
    drop = (128 - network.prefixlen) // 4
    return ".".join(labels[drop:]) if 0 <= drop <= 32 else network.network_address.reverse_pointer


def handle_subnet_calculator(args):
    aggregate = args.get("aggregate")
    if aggregate:
        raw_items = aggregate if isinstance(aggregate, list) else [aggregate]
        nets = []
        for item in raw_items:
            text = str(item).strip()
            if not text:
                continue
            try:
                nets.append(ip_network(text, strict=False))
            except ValueError as exc:
                raise ToolError("invalid_cidr", f"invalid network in aggregate: {text} ({exc})")
        if not nets:
            raise ToolError("missing_cidr", "aggregate requires at least one network")
        collapsed = [str(net) for net in collapse_addresses([n for n in nets if n.version == 4])]
        collapsed += [str(net) for net in collapse_addresses([n for n in nets if n.version == 6])]
        success("subnet-calculator", "aggregated", input=[str(net) for net in nets], aggregated=collapsed, count=len(collapsed))
        return

    cidr = str(args.get("cidr") or args.get("network") or "").strip()
    if not cidr:
        raise ToolError("missing_cidr", "cidr or aggregate is required")
    try:
        network = ip_network(cidr, strict=False)
    except ValueError as exc:
        raise ToolError("invalid_cidr", str(exc))
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
        "wildcard": str(network.hostmask),
        "reverse_zone": network_reverse_zone(network),
        "is_private": network.is_private,
        "is_global": network.is_global,
        "num_addresses": network.num_addresses,
        "usable_hosts": max(network.num_addresses - 2, 0) if network.version == 4 and network.prefixlen <= 30 else (len(hosts) if hosts else None),
        "first_host": first_host,
        "last_host": last_host,
    }
    if network.version == 4:
        result["broadcast"] = str(network.broadcast_address)
        result["ip_class"] = ipv4_class(network.network_address)

    contains = str(args.get("contains") or "").strip()
    if contains:
        try:
            member = ip_address(contains)
        except ValueError as exc:
            raise ToolError("invalid_contains", str(exc))
        result["contains"] = {"address": str(member), "in_network": member in network}

    if args.get("new_prefix") is not None:
        limit = int_arg(args, "limit", 32, 1, 512)
        new_prefix = int_arg(args, "new_prefix", network.prefixlen, 0, network.max_prefixlen)
        result["new_prefix"] = new_prefix
        if new_prefix > network.prefixlen:
            result["operation"] = "split"
            result["subnets"] = [str(item) for _, item in zip(range(limit), network.subnets(new_prefix=new_prefix))]
        elif new_prefix < network.prefixlen:
            result["operation"] = "supernet"
            result["supernet"] = str(network.supernet(new_prefix=new_prefix))
        else:
            result["operation"] = "same"
            result["subnets"] = [str(network)]
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
    signed = normalized - (1 << width) if normalized & (1 << (width - 1)) else normalized
    byte_count = (width + 7) // 8
    return {
        "decimal": normalized,
        "signed": signed,
        "hex": "0x" + format(normalized, "0{}x".format(byte_count * 2)),
        "binary": format(normalized, f"0{width}b"),
        "octal": "0o" + format(normalized, "o"),
        "popcount": bin(normalized).count("1"),
        "parity": "even" if bin(normalized).count("1") % 2 == 0 else "odd",
        "bytes": [format((normalized >> (shift * 8)) & 0xFF, "02x") for shift in range(byte_count - 1, -1, -1)],
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
    first = values[0] & mask
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
    elif operation in {"rol", "ror"}:
        shift = int_arg(args, "shift", 1, 0, width) % width if width else 0
        result_value = ((first << shift) | (first >> (width - shift))) if operation == "rol" else ((first >> shift) | (first << (width - shift)))
    elif operation in {"setbit", "clearbit", "togglebit", "testbit"}:
        index = int_arg(args, "index", 0, 0, width - 1)
        if operation == "setbit":
            result_value = first | (1 << index)
        elif operation == "clearbit":
            result_value = first & ~(1 << index)
        elif operation == "togglebit":
            result_value = first ^ (1 << index)
        else:
            success("bit-calculator", "calculated", width=width, operation=operation, index=index,
                    inputs=[bit_repr(value, width) for value in values], bit_set=bool(first & (1 << index)))
            return
    elif operation == "byteswap":
        byte_count = (width + 7) // 8
        result_value = int.from_bytes(first.to_bytes(byte_count, "big"), "little")
    else:
        raise ToolError("invalid_operation", "operation must be convert, not, and, or, xor, shl, shr, rol, ror, setbit, clearbit, togglebit, testbit, or byteswap")
    success("bit-calculator", "calculated", width=width, operation=operation, inputs=[bit_repr(value, width) for value in values], result=bit_repr(result_value, width))


def parse_cert_dict(cert):
    def flatten(sequence):
        flat = {}
        for rdn in sequence or ():
            for key, value in rdn:
                flat[key] = value
        return flat

    subject = flatten(cert.get("subject"))
    issuer = flatten(cert.get("issuer"))
    not_after = cert.get("notAfter")
    days_until_expiry = None
    if not_after:
        try:
            days_until_expiry = round((ssl.cert_time_to_seconds(not_after) - time.time()) / 86400, 1)
        except ValueError:
            days_until_expiry = None
    return {
        "subject": subject,
        "issuer": issuer,
        "common_name": subject.get("commonName", ""),
        "issuer_cn": issuer.get("commonName", ""),
        "serial_number": cert.get("serialNumber", ""),
        "version": cert.get("version"),
        "not_before": cert.get("notBefore"),
        "not_after": not_after,
        "days_until_expiry": days_until_expiry,
        "subject_alt_names": [value for _type, value in cert.get("subjectAltName", ())],
    }


def tls_connect(host, port, servername, timeout, verify):
    if verify:
        context = ssl.create_default_context()
    else:
        context = ssl._create_unverified_context()
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
    with socket.create_connection((host, port), timeout=timeout) as raw:
        with context.wrap_socket(raw, server_hostname=servername) as tls:
            return tls.getpeercert(binary_form=True), tls.version(), tls.cipher()


def handle_tls_inspect(args):
    host = safe_host(args.get("host"), "host")
    port = int_arg(args, "port", 443, 1, 65535)
    servername = str(args.get("servername") or host)
    if not re.fullmatch(r"[A-Za-z0-9_.:-]{1,253}", servername):
        raise ToolError("invalid_servername", "servername contains unsupported characters")
    timeout = timeout_arg(args, default_ms=5000, maximum_ms=15000)
    if bool_arg(args, "dry_run", False):
        success("tls-inspect", "planned", host=host, port=port, servername=servername)
        return
    require_authorized_scope(args, [host], "TLS inspection opens a connection to the target")
    validated, validation_error = True, ""
    try:
        der, protocol, cipher = tls_connect(host, port, servername, timeout, verify=True)
    except ssl.SSLError as exc:
        validated, validation_error = False, str(exc)
        try:
            der, protocol, cipher = tls_connect(host, port, servername, timeout, verify=False)
        except ssl.SSLError as inner:
            raise ToolError("tls_error", str(inner), host=host, port=port)
        except OSError as inner:
            raise ToolError("connect_failed", str(inner), host=host, port=port)
    except socket.timeout:
        raise ToolError("timeout", "TLS handshake did not complete before timeout", host=host, port=port)
    except OSError as exc:
        raise ToolError("connect_failed", str(exc), host=host, port=port)
    certificate = None
    if der:
        handle = tempfile.NamedTemporaryFile("w", suffix=".pem", delete=False, encoding="utf-8")
        try:
            handle.write(ssl.DER_cert_to_PEM_cert(der))
            handle.close()
            certificate = parse_cert_dict(ssl._ssl._test_decode_cert(handle.name))
        except Exception as exc:  # noqa: BLE001  best-effort cert decode
            certificate = {"parse_error": str(exc)}
        finally:
            os.unlink(handle.name)
    success("tls-inspect", "inspected", host=host, port=port, servername=servername,
            protocol=protocol, cipher=({"name": cipher[0], "protocol": cipher[1], "bits": cipher[2]} if cipher else None),
            validated=validated, validation_error=validation_error, certificate=certificate)


def handle_http_check(args):
    url = str(args.get("url") or "").strip()
    parsed_url = urllib.parse.urlparse(url)
    if parsed_url.scheme.lower() not in {"http", "https"}:
        raise ToolError("invalid_url", "url must use http:// or https://")
    method = str(args.get("method") or "GET").upper()
    if method not in {"GET", "HEAD"}:
        raise ToolError("invalid_method", "method must be GET or HEAD")
    timeout = timeout_arg(args, default_ms=8000, maximum_ms=20000)
    if bool_arg(args, "dry_run", False):
        success("http-check", "planned", url=url, method=method)
        return
    validate_http_target(url, args, "HTTP check sends a request to the target URL")
    chain = []
    opener = urllib.request.build_opener(
        AuthorizedRedirectHandler(args, chain, "HTTP redirect opens a connection")
    )
    request = urllib.request.Request(url, method=method, headers={"User-Agent": "linux-agent-network-ops/1"})
    started = time.monotonic()
    try:
        with opener.open(request, timeout=timeout) as response:
            status = response.status
            final_url = response.geturl()
            resp_headers = {key: value for key, value in response.headers.items()}
            body = response.read(1048576) if method == "GET" else b""
    except urllib.error.HTTPError as exc:
        status = exc.code
        final_url = getattr(exc, "url", url) or url
        resp_headers = {key: value for key, value in (exc.headers.items() if exc.headers else [])}
        body = b""
    except urllib.error.URLError as exc:
        raise ToolError("request_failed", str(getattr(exc, "reason", exc)), url=url)
    except socket.timeout:
        raise ToolError("timeout", "request did not complete before timeout", url=url)
    elapsed = round((time.monotonic() - started) * 1000, 2)
    key_headers = {key: resp_headers[key] for key in ("Content-Type", "Content-Length", "Server", "Location", "Cache-Control") if key in resp_headers}
    payload = {
        "url": url, "final_url": final_url, "method": method, "status_code": status,
        "redirect_chain": chain, "elapsed_ms": elapsed, "headers": resp_headers, "key_headers": key_headers,
    }
    if method == "GET":
        payload["body_bytes"] = len(body)
        payload["body_sha256"] = hashlib.sha256(body).hexdigest()
    success("http-check", "checked", **payload)


def stun_public_ip(server, port, timeout):
    magic = 0x2112A442
    txid = os.urandom(12)
    request = struct.pack("!HHI", 0x0001, 0, magic) + txid
    family, sockaddr = resolve_udp_target(server, port)
    with socket.socket(family, socket.SOCK_DGRAM) as sock:
        sock.settimeout(timeout)
        sock.sendto(request, sockaddr)
        data, _address = sock.recvfrom(2048)
    if len(data) < 20:
        raise ToolError("invalid_response", "STUN response too short")
    _msg_type, msg_len, _magic = struct.unpack("!HHI", data[:8])
    offset = 20
    while offset + 4 <= 20 + msg_len:
        attr_type, attr_len = struct.unpack("!HH", data[offset:offset + 4])
        value = data[offset + 4:offset + 4 + attr_len]
        if attr_type in (0x0020, 0x0001) and len(value) >= 8:
            family_byte = value[1]
            if attr_type == 0x0020:
                mapped_port = struct.unpack("!H", value[2:4])[0] ^ (magic >> 16)
                if family_byte == 0x01:
                    address = socket.inet_ntoa(bytes(byte ^ mask for byte, mask in zip(value[4:8], struct.pack("!I", magic))))
                else:
                    key = struct.pack("!I", magic) + txid
                    address = socket.inet_ntop(socket.AF_INET6, bytes(byte ^ mask for byte, mask in zip(value[4:20], key)))
            else:
                mapped_port = struct.unpack("!H", value[2:4])[0]
                address = socket.inet_ntoa(value[4:8]) if family_byte == 0x01 else socket.inet_ntop(socket.AF_INET6, value[4:20])
            return address, mapped_port
        offset += 4 + attr_len + ((4 - attr_len % 4) % 4)
    raise ToolError("no_mapping", "STUN response contained no mapped address")


def handle_public_ip(args):
    method = str(args.get("method") or "stun").lower()
    if method not in {"stun", "https"}:
        raise ToolError("invalid_method", "method must be stun or https")
    timeout = timeout_arg(args, default_ms=5000, maximum_ms=15000)
    if bool_arg(args, "dry_run", False):
        success("public-ip", "planned", method=method)
        return
    if method == "stun":
        server = safe_host(args.get("server") or "stun.l.google.com", "server")
        port = int_arg(args, "port", 19302, 1, 65535)
        require_authorized_scope(args, [server], "STUN public IP lookup sends a UDP request to the target")
        try:
            address, mapped_port = stun_public_ip(server, port, timeout)
        except socket.timeout:
            raise ToolError("timeout", "no STUN response before timeout", server=server)
        except OSError as exc:
            raise ToolError("query_failed", str(exc), server=server)
        success("public-ip", "resolved", method="stun", server=server, public_ip=address, mapped_port=mapped_port)
        return
    url = str(args.get("url") or "https://api.ipify.org")
    parsed_url = urllib.parse.urlparse(url)
    if parsed_url.scheme.lower() != "https":
        raise ToolError("invalid_url", "public IP echo URL must use https://")
    validate_http_target(url, args, "HTTPS public IP lookup sends a request to the target")
    chain = []
    opener = urllib.request.build_opener(
        AuthorizedRedirectHandler(args, chain, "HTTPS public IP redirect opens a connection")
    )
    request = urllib.request.Request(url, headers={"User-Agent": "linux-agent-network-ops/1"})
    try:
        with opener.open(request, timeout=timeout) as response:
            body = response.read(64).decode("utf-8", "replace").strip()
    except (urllib.error.URLError, socket.timeout) as exc:
        raise ToolError("query_failed", str(getattr(exc, "reason", exc)), url=url)
    try:
        ip_address(body)
    except ValueError:
        raise ToolError("invalid_response", "echo endpoint did not return an IP address", body=short_text(body, 80))
    success("public-ip", "resolved", method="https", url=url, redirect_chain=chain, public_ip=body)


def ssdp_discover(timeout, limit):
    message = "\r\n".join(["M-SEARCH * HTTP/1.1", "HOST: 239.255.255.250:1900", 'MAN: "ssdp:discover"', "MX: 2", "ST: ssdp:all", "", ""]).encode("ascii")
    results = []
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.settimeout(timeout)
        sock.sendto(message, ("239.255.255.250", 1900))
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline and len(results) < limit:
            try:
                data, address = sock.recvfrom(4096)
            except socket.timeout:
                break
            headers = {}
            for line in data.decode("utf-8", "replace").splitlines()[1:]:
                if ":" in line:
                    key, value = line.split(":", 1)
                    headers[key.strip().upper()] = value.strip()
            results.append({"address": address[0], "server": headers.get("SERVER", ""), "st": headers.get("ST", ""), "location": headers.get("LOCATION", ""), "usn": headers.get("USN", "")})
    return results


def configure_mdns_socket(sock):
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    if hasattr(socket, "SO_REUSEPORT"):
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    sock.bind(("", 5353))
    membership = socket.inet_aton("224.0.0.251") + socket.inet_aton("0.0.0.0")
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, membership)


def mdns_discover(service, timeout, limit):
    header = struct.pack("!HHHHHH", 0, 0, 1, 0, 0, 0)
    packet = header + _dns.encode_name(service) + struct.pack("!HH", _dns.RECORD_TYPES["PTR"], 1)
    results = []
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        configure_mdns_socket(sock)
        sock.settimeout(timeout)
        sock.sendto(packet, ("224.0.0.251", 5353))
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline and len(results) < limit:
            try:
                data, address = sock.recvfrom(4096)
            except socket.timeout:
                break
            try:
                parsed = _dns.parse_response(data)
            except (IndexError, struct.error):
                continue
            for answer in parsed["answers"]:
                results.append({"address": address[0], "name": answer["name"], "type": answer["type"], "value": answer["value"]})
    return results


def handle_service_discovery(args):
    protocol = str(args.get("protocol") or args.get("action") or "ssdp").lower()
    if protocol not in {"ssdp", "mdns", "all"}:
        raise ToolError("invalid_protocol", "protocol must be ssdp, mdns, or all")
    timeout = timeout_arg(args, default_ms=3000, maximum_ms=8000)
    limit = int_arg(args, "limit", 50, 1, 200)
    if bool_arg(args, "dry_run", False):
        success("service-discovery", "planned", protocol=protocol)
        return
    require_authorized_scope(args, ["multicast-lan"], "Service discovery sends multicast queries on the local network")
    ssdp, mdns, errors = [], [], []
    completed = 0
    if protocol in {"ssdp", "all"}:
        try:
            ssdp = ssdp_discover(timeout, limit)
            completed += 1
        except OSError as exc:
            errors.append(f"SSDP discovery failed: {exc}")
    if protocol in {"mdns", "all"}:
        service = str(args.get("service") or "_services._dns-sd._udp.local")
        try:
            mdns = mdns_discover(service, timeout, limit)
            completed += 1
        except OSError as exc:
            errors.append(f"mDNS discovery failed: {exc}")
    if errors and completed == 0:
        raise ToolError("discovery_failed", "; ".join(errors))
    success("service-discovery", "partial" if errors else "inspected", protocol=protocol,
            ssdp=ssdp, mdns=mdns, count=len(ssdp) + len(mdns), errors=errors)


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
    "tls-inspect": handle_tls_inspect,
    "http-check": handle_http_check,
    "public-ip": handle_public_ip,
    "service-discovery": handle_service_discovery,
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
