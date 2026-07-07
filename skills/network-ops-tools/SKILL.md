---
name: network-ops-tools
description: Network and operations engineering tools inspired by NETworkManager. These tools are registered for script mode and work mode; each script declares at least medium risk so active network actions are never treated as low-risk auto-run steps.
---

# Network Ops Tools

Use these scripts for network administration, diagnostics, lookup, and calculation workflows. Every script accepts one JSON object as its first argument and writes one JSON object to stdout.

## Safety

- All scripts are declared as `medium` or `high`; none should be represented as `low` in policy review or the Web skill catalog.
- Active probes and change-capable actions require explicit scope acknowledgement or confirmation arguments.
- Scanner scripts enforce target, host, port, timeout, and result-size limits.
- Change-capable tools default to read, plan, or dry-run behavior unless `apply: true` plus the documented confirmation string is supplied.

## Scripts

- `scripts/ip-scanner.sh` (risk: high): Scan an IPv4/IPv6 CIDR or explicit targets with bounded ping and optional TCP probes. Args: `cidr`, `targets`, `ports`, `timeout_ms`, `max_hosts`, `only_up`, `acknowledge_authorized_scope`.
- `scripts/port-scanner.sh` (risk: high): Scan bounded TCP ports on one host. Args: `target`, `ports`, `start_port`, `end_port`, `timeout_ms`, `acknowledge_authorized_scope`.
- `scripts/discovery-protocol.sh` (risk: medium): Read LLDP/CDP-style neighbor information from local discovery tools when available. Args: `interface`, `limit`.
- `scripts/wake-on-lan.sh` (risk: high): Send or preview a Wake-on-LAN magic packet. Args: `mac`, `broadcast`, `port`, `dry_run`, `acknowledge_authorized_scope`.
- `scripts/network-interface.sh` (risk: medium): Inspect network interfaces, addresses, routes, MTU, MAC and operstate. Args: `interface`.
- `scripts/wifi.sh` (risk: medium): Inspect wireless interfaces and list/scan Wi-Fi networks using local tools when available. Args: `interface`, `scan`, `acknowledge_authorized_scope`.
- `scripts/connections.sh` (risk: medium): Inspect active TCP/UDP connections through `ss`. Args: `protocol`, `state`, `limit`, `include_process`.
- `scripts/listeners.sh` (risk: medium): Inspect listening TCP/UDP sockets through `ss`. Args: `protocol`, `port`, `limit`, `include_process`.
- `scripts/neighbor-table.sh` (risk: medium): Read the local neighbor/ARP/NDP table. Args: `interface`, `limit`.
- `scripts/ping-monitor.sh` (risk: medium): Run a bounded ping monitor and summarize packet loss and latency. Args: `target`, `count`, `timeout_ms`, `interval_sec`, `acknowledge_authorized_scope`.
- `scripts/traceroute.sh` (risk: medium): Run traceroute/tracepath when available, with safe fallback for loopback targets. Args: `target`, `max_hops`, `timeout_ms`, `acknowledge_authorized_scope`.
- `scripts/dns-lookup.sh` (risk: medium): Resolve DNS records with system resolver or DNS CLI tools when present. Args: `query`, `record_type`, `server`, `timeout_ms`.
- `scripts/sntp-lookup.sh` (risk: medium): Query or dry-run an SNTP request. Args: `server`, `port`, `timeout_ms`, `dry_run`.
- `scripts/whois.sh` (risk: medium): Query or dry-run WHOIS over TCP/43 with public-server validation. Args: `query`, `server`, `timeout_ms`, `dry_run`.
- `scripts/ip-geolocation.sh` (risk: medium): Query or dry-run IP geolocation for public IPs only. Args: `ip`, `provider`, `timeout_ms`, `dry_run`.
- `scripts/hosts-file-editor.sh` (risk: high): Read, search, plan, add, or remove hosts entries; writes require `confirm:"APPLY_HOSTS_CHANGE"`. Args: `action`, `path`, `ip`, `hostnames`, `hostname`, `apply`, `confirm`.
- `scripts/lookup.sh` (risk: medium): Look up ports/services and MAC OUI vendors from local data. Args: `category`, `query`, `protocol`.
- `scripts/snmp.sh` (risk: high): Dry-run or perform bounded SNMP v2c GET requests without echoing community values. Args: `host`, `oid`, `community`, `port`, `timeout_ms`, `dry_run`, `acknowledge_authorized_scope`.
- `scripts/firewall.sh` (risk: high): Inspect firewall state or produce/apply guarded UFW rule plans; applies require `confirm:"APPLY_FIREWALL_CHANGE"`. Args: `action`, `rule`, `apply`, `confirm`.
- `scripts/subnet-calculator.sh` (risk: medium): Calculate IPv4/IPv6 subnet details, optional subnetting and supernetting. Args: `cidr`, `new_prefix`, `limit`.
- `scripts/bit-calculator.sh` (risk: medium): Convert and operate on bounded integer bit values. Args: `value`, `values`, `operation`, `width`, `shift`.

## Workflow

For active probes, first narrow the target range and include `acknowledge_authorized_scope:true` only when the user has confirmed authorization for that scope. For change-capable scripts, use read or plan actions first, then execute with `apply:true` and the exact confirmation string only after review.
