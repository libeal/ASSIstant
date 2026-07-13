#!/usr/bin/env python3

import importlib.util
import signal
import socket
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT_DIR = ROOT / "skills" / "network-ops-tools" / "scripts"


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


network_tool = load_module("network_tool", SCRIPT_DIR / "_network_tool.py")
snmp = load_module("snmp", SCRIPT_DIR / "_snmp.py")
dns = load_module("dns", SCRIPT_DIR / "_dns.py")


class NetworkOpsUnitTests(unittest.TestCase):
    def test_firewalld_plan_preserves_deny_and_source(self):
        command = network_tool.firewalld_rule_command("deny", "tcp", 8080, "10.0.0.0/8")

        self.assertEqual(command[:3], ["firewall-cmd", "--permanent", "--add-rich-rule"])
        self.assertIn('source address="10.0.0.0/8"', command[3])
        self.assertIn('port port="8080" protocol="tcp" drop', command[3])

    def test_redirect_target_requires_its_own_authorization(self):
        with self.assertRaises(network_tool.ToolError) as raised:
            network_tool.validate_http_target(
                "http://example.com/redirected", {}, "HTTP redirect opens a connection"
            )

        self.assertEqual(raised.exception.status, "authorization_required")

    def test_public_ip_rejects_plain_http(self):
        with self.assertRaisesRegex(network_tool.ToolError, "method must be stun or https"):
            network_tool.handle_public_ip({"method": "http", "dry_run": True})

    def test_tracepath_fallback_rejects_unsupported_mode(self):
        with self.assertRaisesRegex(network_tool.ToolError, "tracepath fallback supports only default mode"):
            network_tool.build_traceroute_command(
                "target.example", "tcp", has_traceroute=False, has_tracepath=True, max_hops=30, timeout=1
            )

    def test_mdns_socket_joins_group_on_port_5353(self):
        class FakeSocket:
            def __init__(self):
                self.options = []
                self.bound = None

            def setsockopt(self, *args):
                self.options.append(args)

            def bind(self, address):
                self.bound = address

        fake = FakeSocket()
        network_tool.configure_mdns_socket(fake)

        self.assertEqual(fake.bound, ("", 5353))
        self.assertIn(
            (socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP),
            [(args[0], args[1]) for args in fake.options],
        )

    def test_dns_rejects_compression_pointer_loop(self):
        def timeout_handler(_signum, _frame):
            raise AssertionError("DNS name parser did not terminate")

        previous = signal.signal(signal.SIGALRM, timeout_handler)
        signal.alarm(1)
        try:
            with self.assertRaises(dns.DnsError):
                dns.read_name(b"\xc0\x00", 0)
        finally:
            signal.alarm(0)
            signal.signal(signal.SIGALRM, previous)

    def test_snmp_enforces_oid_limit(self):
        with self.assertRaisesRegex(snmp.SnmpError, "at most 64 OIDs"):
            snmp.validate_oid_limit([".1.3.6.1.2.1.1.5.0"] * 65, 64)

    def test_snmp_v3_authentication_rejects_tampered_response(self):
        engine_id = b"\x80\x00\x1f\x88\x80\x12\x34\x56"
        auth_key = b"01234567890123456789"
        pdu = snmp.build_pdu(snmp.GET, 7, [".1.3.6.1.2.1.1.5.0"])
        scoped = snmp.build_scoped_pdu(engine_id, pdu)
        packet = snmp.build_v3_message(7, engine_id, 1, 42, "test-user", auth_key, "sha1", scoped, True)
        security = snmp.parse_v3_security(packet)

        snmp.verify_v3_auth(packet, security, auth_key, "sha1")
        tampered = bytearray(packet)
        tampered[-1] ^= 1
        with self.assertRaisesRegex(snmp.SnmpError, "authentication failed"):
            snmp.verify_v3_auth(bytes(tampered), security, auth_key, "sha1")

    def test_snmp_v3_auth_priv_remains_unsupported(self):
        with self.assertRaisesRegex(network_tool.ToolError, "authPriv"):
            network_tool.handle_snmp(
                {
                    "host": "127.0.0.1",
                    "version": "3",
                    "user": "test-user",
                    "priv_password": "must-not-be-implemented",
                    "dry_run": True,
                }
            )


if __name__ == "__main__":
    unittest.main()
