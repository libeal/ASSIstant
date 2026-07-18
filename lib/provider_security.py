#!/usr/bin/env python3

"""Provider URL policy shared by the Web adapter and the Bash core."""

import ipaddress
import json
import socket
import sys
from urllib.parse import urlparse


MAX_PROVIDER_URL_LENGTH = 2048
METADATA_ADDRESSES = {"169.254.169.254", "100.100.100.200", "fd00:ec2::254"}


def validate_http_url(raw_url):
    value = str(raw_url or "").strip()
    if len(value) > MAX_PROVIDER_URL_LENGTH:
        return "", "url_too_long"
    try:
        parsed = urlparse(value)
        hostname = parsed.hostname
        _ = parsed.port
    except ValueError:
        return "", "invalid_url"
    if (
        parsed.scheme not in {"http", "https"}
        or not parsed.netloc
        or not hostname
        or parsed.username is not None
        or parsed.password is not None
    ):
        return "", "invalid_url"
    return value, ""


def provider_security_policy(config):
    if isinstance(config, dict) and "providers_security" in config:
        raw = config.get("providers_security")
    else:
        raw = config
    policy = raw if isinstance(raw, dict) else {}
    allowed = policy.get("allowed_hosts")
    allowed_hosts = [
        str(host).strip().lower()
        for host in (allowed if isinstance(allowed, list) else [])
        if isinstance(host, str) and str(host).strip()
    ]
    return {
        # Preserve pre-policy local configs; remote bootstrap explicitly sets
        # require_https=true before launching either entrypoint.
        "require_https": bool(policy.get("require_https", False)),
        "block_internal_addresses": bool(policy.get("block_internal_addresses", True)),
        "allowed_hosts": allowed_hosts,
    }


def resolve_host_addresses(host):
    """Resolve a host once and return numeric addresses for request pinning."""

    normalized = (host or "").strip().strip("[]")
    if not normalized:
        return []
    addresses = []
    try:
        addresses.append(str(ipaddress.ip_address(normalized)))
    except ValueError:
        try:
            infos = socket.getaddrinfo(normalized, None, proto=socket.IPPROTO_TCP)
        except (OSError, UnicodeError):
            return []
        for info in infos:
            addr = info[4][0].split("%")[0]
            try:
                normalized_addr = str(ipaddress.ip_address(addr))
            except ValueError:
                continue
            if normalized_addr not in addresses:
                addresses.append(normalized_addr)
    return addresses


def address_is_internal(host):
    """Return whether host is or resolves to a private/internal address."""

    candidates = resolve_host_addresses(host)
    if not candidates:
        return True
    for address in candidates:
        ip = ipaddress.ip_address(address)
        if str(ip) in METADATA_ADDRESSES:
            return True
        if (
            ip.is_private
            or ip.is_loopback
            or ip.is_link_local
            or ip.is_reserved
            or ip.is_multicast
            or ip.is_unspecified
        ):
            return True
    return False


def inspect_provider_url(raw_url, security):
    value, error = validate_http_url(raw_url)
    if error:
        return "", error, []
    parsed = urlparse(value)
    host = (parsed.hostname or "").lower()
    if security["require_https"] and parsed.scheme.lower() != "https":
        return "", "https_required", []
    addresses = resolve_host_addresses(host)
    if not addresses:
        return "", "provider_dns_unavailable", []
    if host in security["allowed_hosts"]:
        return value, "", addresses
    if security["block_internal_addresses"] and (
        not addresses or any(address_is_internal(address) for address in addresses)
    ):
        return "", "blocked_internal_address", []
    return value, "", addresses


def validate_provider_url(raw_url, security):
    value, error, _addresses = inspect_provider_url(raw_url, security)
    return value, error


def provider_url_error_message(status):
    return {
        "url_too_long": "Provider URL is too long.",
        "invalid_url": "Provider URL must be a valid http(s) URL.",
        "https_required": "Provider URL must use HTTPS in this runtime.",
        "provider_dns_unavailable": "Provider hostname could not be resolved safely.",
        "blocked_internal_address": "Provider URL resolves to a blocked internal/metadata address.",
        "provider_host_not_allowed": "Provider URL host is not in the trusted host set for credentialed requests.",
        "provider_url_override_blocked": "Request body cannot override api_url to an untrusted host when an API key is sent.",
    }.get(status, "Provider URL is not allowed.")




def provider_url_host(raw_url):
    """Return the lower-case hostname from a provider URL, or empty string."""

    value = str(raw_url or "").strip()
    if not value:
        return ""
    try:
        parsed = urlparse(value)
    except ValueError:
        return ""
    return (parsed.hostname or "").lower()


def trusted_provider_hosts(security, *urls):
    """Hosts allowed to receive Provider credentials.

    ``providers_security.allowed_hosts`` is always trusted.  Configured and
    registry URLs expand the set so operators can use stock Providers without
    an explicit allowlist, while still blocking arbitrary body.api_url overrides
    that would exfiltrate API keys to an attacker-controlled HTTPS host.
    """

    hosts = set()
    for host in security.get("allowed_hosts") or []:
        normalized = str(host or "").strip().lower()
        if normalized:
            hosts.add(normalized)
    for raw in urls:
        host = provider_url_host(raw)
        if host:
            hosts.add(host)
    return hosts


def host_is_trusted(host, trusted_hosts):
    """Return whether host is present in the trusted set."""

    normalized = str(host or "").strip().lower().strip("[]")
    if not normalized:
        return False
    return normalized in {str(item).strip().lower().strip("[]") for item in trusted_hosts}


def validate_command(url, policy_json):
    try:
        config = json.loads(policy_json)
    except (TypeError, json.JSONDecodeError):
        return {"ok": False, "status": "provider_security_unavailable", "error": "Provider security policy is invalid."}
    value, status, addresses = inspect_provider_url(url, provider_security_policy(config))
    if status:
        return {"ok": False, "status": status, "error": provider_url_error_message(status)}
    parsed = urlparse(value)
    host = parsed.hostname or ""
    port = parsed.port or (443 if parsed.scheme.lower() == "https" else 80)
    resolve_entries = []
    for address in addresses:
        resolve_host = f"[{host}]" if ":" in host else host
        resolve_address = f"[{address}]" if ":" in address else address
        resolve_entries.append(f"{resolve_host}:{port}:{resolve_address}")
    return {
        "ok": True,
        "status": "allowed",
        "url": value,
        "resolved_addresses": addresses,
        "curl_resolve": resolve_entries,
    }


def main():
    if len(sys.argv) != 4 or sys.argv[1] != "validate":
        print(json.dumps({"ok": False, "status": "provider_security_unavailable", "error": "Invalid provider security invocation."}))
        return 2
    print(json.dumps(validate_command(sys.argv[2], sys.argv[3]), ensure_ascii=False, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
