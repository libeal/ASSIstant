#!/usr/bin/env python3

import sys
import unittest
from pathlib import Path
from types import SimpleNamespace


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "web"))

from observer import ObserverService  # noqa: E402


class ObserverServiceTests(unittest.TestCase):
    def service(self, *, config=None, helper=True, runner=None, which=None):
        events = []
        calls = []
        config = config or {
            "observer": {
                "enabled": "auto",
                "privilege": "sudo_interactive",
                "require": False,
                "max_events": 200,
            }
        }

        def run(command, **kwargs):
            calls.append((command, kwargs))
            if runner is not None:
                return runner(command, **kwargs)
            return SimpleNamespace(returncode=0, stdout="enabled 1\n", stderr="")

        service = ObserverService(
            config_reader=lambda: config,
            audit=lambda stage, payload: events.append((stage, payload)),
            sudo_check=lambda _password: self.fail("helper path must not ask for sudo"),
            env_builder=lambda include_api_key=False: {"PATH": "/usr/bin"},
            lib_root=ROOT / "lib",
            server_started_at="2026-07-18T00:00:00Z",
            process_runner=run,
            effective_uid=lambda: 1001,
            which=which or (lambda name: f"/usr/bin/{name}"),
            helper_socket_checker=lambda _path: helper,
            now_iso=lambda: "2026-07-18T00:01:00Z",
        )
        return service, events, calls

    def test_helper_success_uses_fixed_protocol_without_sudo(self):
        service, events, calls = self.service(helper=True)

        result = service.enable("")

        self.assertTrue(result["ok"])
        self.assertEqual(result["method"], "helper")
        self.assertFalse(result["requires_permission"])
        self.assertEqual(events[0][0], "observer_bootstrap_enabled")
        self.assertEqual(calls[0][0][-1], "status")
        self.assertNotIn("sudo", calls[0][0])
        self.assertNotIn("LINUX_AGENT_API_KEY", calls[0][1]["env"])

    def test_helper_failure_is_fail_closed_without_sudo_fallback(self):
        def fail_helper(_command, **_kwargs):
            return SimpleNamespace(returncode=125, stdout="", stderr="helper failed")

        service, events, calls = self.service(helper=True, runner=fail_helper)

        result = service.enable("not-used")

        self.assertFalse(result["ok"])
        self.assertEqual(result["status"], "observer_helper_failed")
        self.assertEqual(len(calls), 1)
        self.assertEqual(events[0][0], "observer_bootstrap_failed")

    def test_privilege_none_disables_helper_and_sudo(self):
        config = {
            "observer": {
                "enabled": "auto",
                "privilege": "none",
                "require": True,
            }
        }
        service, events, calls = self.service(config=config, helper=True)

        result = service.enable("")

        self.assertFalse(result["ok"])
        self.assertEqual(result["method"], "none")
        self.assertEqual(calls, [])
        self.assertEqual(events[0][0], "observer_bootstrap_failed")

    def test_missing_helper_reports_missing_audit_tools(self):
        service, _events, calls = self.service(
            helper=False,
            which=lambda _name: None,
        )

        result = service.enable("")

        self.assertEqual(result["status"], "auditctl_not_found")
        self.assertTrue(result["requires_permission"])
        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
