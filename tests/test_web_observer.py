#!/usr/bin/env python3

import subprocess
import sys
import unittest
from pathlib import Path
from types import SimpleNamespace


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "web"))

from observer import ObserverService  # noqa: E402


class FakeInput:
    def __init__(self, *, write_error=None):
        self.value = ""
        self.closed = False
        self.write_error = write_error

    def write(self, value):
        if self.write_error is not None:
            raise self.write_error
        self.value += value

    def flush(self):
        return None

    def close(self):
        self.closed = True


class FakeProcess:
    def __init__(self, *, returncode=None):
        self.returncode = returncode
        self.input_stream = FakeInput()
        self.stdin = self.input_stream
        self.terminated = False
        self.killed = False

    def poll(self):
        return self.returncode

    def terminate(self):
        self.terminated = True
        self.returncode = -15

    def wait(self, timeout=None):
        return self.returncode

    def kill(self):
        self.killed = True
        self.returncode = -9


class ObserverServiceTests(unittest.TestCase):
    def service(
        self,
        *,
        config=None,
        helper=True,
        runner=None,
        launcher=None,
        managed_execution=False,
        allow_sudo_password=True,
        effective_uid=1000,
        which=None,
    ):
        events = []
        calls = []
        launches = []
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

        def launch(command, **kwargs):
            launches.append((command, kwargs))
            if launcher is not None:
                return launcher(command, **kwargs)
            self.fail(f"unexpected background process: {command}")

        if callable(helper):
            socket_checker = helper
        else:
            socket_checker = lambda _path: helper

        service = ObserverService(
            config_reader=lambda: config,
            audit=lambda stage, payload: events.append((stage, payload)),
            env_builder=lambda include_api_key=False: {"PATH": "/usr/bin"},
            lib_root=ROOT / "lib",
            server_started_at="2026-07-18T00:00:00Z",
            process_runner=run,
            process_launcher=launch,
            effective_uid=lambda: effective_uid,
            process_id=lambda: 4242,
            process_start_time=lambda _pid: "987654",
            which=which or (lambda name: f"/usr/bin/{name}"),
            token_factory=lambda: "0123456789abcdef01234567",
            sleeper=lambda _seconds: None,
            managed_execution=managed_execution,
            allow_sudo_password=allow_sudo_password,
            helper_socket_checker=socket_checker,
            now_iso=lambda: "2026-07-18T00:01:00Z",
        )
        service.launches = launches
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

    def test_source_web_starts_lifetime_helper_with_password_on_stdin(self):
        secret = "fixture-observer-password"
        background = FakeProcess()

        def run(command, **kwargs):
            if command[-1] == "status" and "observer_helper.py" in command[1]:
                return SimpleNamespace(returncode=0, stdout="enabled 1\n", stderr="")
            self.fail(f"unexpected command: {command}")

        def runtime_socket_ready(path):
            return path.name.startswith("linux-agent-observer-1000-4242-")

        service, events, calls = self.service(
            helper=runtime_socket_ready,
            runner=run,
            launcher=lambda _command, **_kwargs: background,
        )
        pending = service.public_state()

        self.assertTrue(pending["password_allowed"])
        self.assertEqual(pending["authorization_mode"], "sudo_interactive")
        result = service.enable(secret)

        self.assertTrue(result["ok"], result)
        self.assertEqual(result["method"], "helper")
        self.assertEqual(len(calls), 1)
        self.assertEqual(len(service.launches), 1)
        launch_command, launch_options = service.launches[0]
        self.assertEqual(launch_command[:5], ["sudo", "-S", "-p", "", "--"])
        self.assertIn("serve-local", launch_command)
        self.assertIn("--owner-start-time", launch_command)
        self.assertNotIn(secret, launch_command)
        self.assertNotIn(secret, launch_options.get("env", {}).values())
        self.assertEqual(background.input_stream.value, f"{secret}\n")
        self.assertTrue(background.input_stream.closed)
        override = service.child_env_override()
        self.assertRegex(
            override["LINUX_AGENT_OBSERVER_HELPER_SOCKET"],
            r"^/run/linux-agent-observer-1000-4242-[0-9a-f]{24}\.sock$",
        )
        for command, kwargs in calls:
            self.assertNotIn(secret, command)
            self.assertNotIn(secret, kwargs.get("env", {}).values())
        self.assertNotIn(secret, repr(events))
        service.close()
        self.assertTrue(background.terminated)

    def test_source_web_without_password_uses_noninteractive_helper_start(self):
        background = FakeProcess()

        def runtime_socket_ready(path):
            return path.name.startswith("linux-agent-observer-1000-4242-")

        service, _events, _calls = self.service(
            helper=runtime_socket_ready,
            launcher=lambda _command, **_kwargs: background,
        )

        result = service.enable("")

        self.assertTrue(result["ok"], result)
        command, options = service.launches[0]
        self.assertEqual(command[:3], ["sudo", "-n", "--"])
        self.assertIs(options["stdin"], subprocess.DEVNULL)

    def test_skip_revokes_web_lifetime_helper_only(self):
        background = FakeProcess()

        def runtime_socket_ready(path):
            return (
                path.name.startswith("linux-agent-observer-1000-4242-")
                and not background.terminated
            )

        service, events, _calls = self.service(
            helper=runtime_socket_ready,
            launcher=lambda _command, **_kwargs: background,
        )

        self.assertTrue(service.enable("")["ok"])
        result = service.skip()

        self.assertTrue(result["ok"])
        self.assertEqual(result["status"], "skipped")
        self.assertTrue(background.terminated)
        self.assertEqual(service.child_env_override(), {})
        self.assertEqual(events[-1][0], "observer_bootstrap_skipped")

        managed, _events, _calls = self.service(helper=True, managed_execution=True)
        managed_result = managed.skip()
        self.assertTrue(managed_result["ok"])
        self.assertTrue(managed.helper_available())

    def test_failed_runtime_helper_preflight_removes_privileged_channel(self):
        background = FakeProcess()

        def runtime_socket_ready(path):
            return (
                path.name.startswith("linux-agent-observer-1000-4242-")
                and not background.terminated
            )

        def failed_preflight(command, **_kwargs):
            if command[-1] == "status":
                return SimpleNamespace(
                    returncode=1,
                    stdout="",
                    stderr="auditctl unavailable",
                )
            self.fail(f"unexpected command: {command}")

        service, _events, _calls = self.service(
            helper=runtime_socket_ready,
            runner=failed_preflight,
            launcher=lambda _command, **_kwargs: background,
        )

        result = service.enable("")

        self.assertFalse(result["ok"])
        self.assertEqual("observer_helper_failed", result["status"])
        self.assertTrue(background.terminated)
        self.assertIsNone(service.runtime_helper_process)
        self.assertIsNone(service.runtime_helper_socket)
        self.assertEqual({}, service.child_env_override())

    def test_password_pipe_failure_reaps_started_helper(self):
        background = FakeProcess()
        background.input_stream = FakeInput(write_error=BrokenPipeError("sudo exited"))
        background.stdin = background.input_stream
        service, events, calls = self.service(
            helper=False,
            launcher=lambda _command, **_kwargs: background,
        )

        result = service.enable("fixture-observer-password")

        self.assertFalse(result["ok"])
        self.assertEqual(result["status"], "observer_helper_start_failed")
        self.assertTrue(background.terminated)
        self.assertEqual(calls, [])
        self.assertNotIn("fixture-observer-password", repr(events))

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
        service, events, calls = self.service(
            helper=False,
            allow_sudo_password=False,
        )

        result = service.enable("must-not-be-used")

        self.assertEqual(result["status"], "sudo_transport_disabled")
        self.assertFalse(result["password_allowed"])
        self.assertEqual(calls, [])
        self.assertEqual(service.launches, [])
        self.assertNotIn("must-not-be-used", repr(events))


if __name__ == "__main__":
    unittest.main()
