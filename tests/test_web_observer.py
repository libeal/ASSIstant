#!/usr/bin/env python3

import sys
import unittest
from pathlib import Path
from types import SimpleNamespace


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "web"))

from observer import ObserverService  # noqa: E402


class ObserverServiceTests(unittest.TestCase):
    def service(
        self,
        *,
        config=None,
        helper=True,
        runner=None,
        managed_execution=False,
        allow_sudo_password=True,
        effective_uid=1000,
        which=None,
    ):
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
            env_builder=lambda include_api_key=False: {"PATH": "/usr/bin"},
            lib_root=ROOT / "lib",
            server_started_at="2026-07-18T00:00:00Z",
            process_runner=run,
            effective_uid=lambda: effective_uid,
            which=which or (lambda name: f"/usr/bin/{name}"),
            managed_execution=managed_execution,
            allow_sudo_password=allow_sudo_password,
            helper_socket_checker=lambda _path: helper,
            now_iso=lambda: "2026-07-18T00:01:00Z",
        )
        return service, events, calls

    def test_helper_success_uses_fixed_protocol_without_sudo(self):
        service, events, calls = self.service(helper=True)

        result = service.enable("managed-password-must-be-ignored")

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

    def test_missing_helper_fails_closed_without_sudo_fallback(self):
        service, _events, calls = self.service(
            helper=False,
            managed_execution=True,
        )

        result = service.enable("managed-password-must-be-ignored")

        self.assertEqual(result["status"], "observer_helper_unavailable")
        self.assertTrue(result["requires_permission"])
        self.assertTrue(result["managed_execution"])
        self.assertFalse(result["password_allowed"])
        self.assertEqual(calls, [])

    def test_source_web_validates_password_on_stdin_then_uses_cached_sudo(self):
        secret = "fixture-observer-password"

        def run(command, **kwargs):
            if command == ["sudo", "-n", "true"]:
                return SimpleNamespace(returncode=1, stdout="", stderr="")
            if command == ["sudo", "-S", "-p", "", "-v"]:
                self.assertEqual(kwargs.get("input"), f"{secret}\n")
                return SimpleNamespace(returncode=0, stdout="", stderr="")
            if command == ["sudo", "-n", "auditctl", "-s"]:
                return SimpleNamespace(returncode=0, stdout="enabled 1\n", stderr="")
            self.fail(f"unexpected command: {command}")

        service, events, calls = self.service(helper=False, runner=run)
        pending = service.public_state()

        self.assertTrue(pending["password_allowed"])
        self.assertEqual(pending["authorization_mode"], "sudo_interactive")
        result = service.enable(secret)

        self.assertTrue(result["ok"], result)
        self.assertEqual(result["method"], "sudo")
        self.assertEqual(len(calls), 3)
        for command, kwargs in calls:
            self.assertNotIn(secret, command)
            self.assertNotIn(secret, kwargs.get("env", {}).values())
        self.assertNotIn(secret, repr(events))

    def test_source_web_running_as_root_uses_auditctl_directly(self):
        service, _events, calls = self.service(
            helper=False,
            effective_uid=0,
        )

        result = service.enable("")

        self.assertTrue(result["ok"], result)
        self.assertEqual(result["method"], "root")
        self.assertEqual(calls[0][0], ["auditctl", "-s"])
        self.assertEqual(result["authorization_mode"], "root")
        self.assertFalse(result["password_allowed"])

    def test_non_loopback_source_web_does_not_accept_sudo_password(self):
        def no_cache(command, **_kwargs):
            self.assertEqual(command, ["sudo", "-n", "true"])
            return SimpleNamespace(returncode=1, stdout="", stderr="")

        service, events, calls = self.service(
            helper=False,
            runner=no_cache,
            allow_sudo_password=False,
        )

        result = service.enable("must-not-be-used")

        self.assertEqual(result["status"], "sudo_transport_disabled")
        self.assertFalse(result["password_allowed"])
        self.assertEqual(len(calls), 1)
        self.assertNotIn("must-not-be-used", repr(events))


if __name__ == "__main__":
    unittest.main()
