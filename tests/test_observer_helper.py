#!/usr/bin/env python3

import contextlib
import io
import json
import os
import socket
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))

import observer_helper  # noqa: E402


class ObserverHelperProtocolTests(unittest.TestCase):
    def setUp(self):
        observer_helper.configure_capability_state(None)

    def trusted_tools(self, name):
        return {"auditctl": "/usr/sbin/auditctl", "ausearch": "/usr/bin/ausearch"}[name]

    def build(self, request, *, peer_uid=1001, peer_pid=None):
        if peer_pid is None:
            peer_pid = os.getpid()
        with mock.patch.object(observer_helper, "_trusted_tool", side_effect=self.trusted_tools):
            return observer_helper.build_command(
                request,
                peer_pid=peer_pid,
                peer_uid=peer_uid,
            )

    def test_fixed_read_only_operations(self):
        self.assertEqual(
            self.build({"operation": "status"}),
            ["/usr/sbin/auditctl", "-s"],
        )
        self.assertEqual(
            self.build({"operation": "list_rules"}),
            ["/usr/sbin/auditctl", "-l"],
        )
        self.assertEqual(
            self.build({"operation": "search_key", "key": "linux_agent_session_1"}),
            ["/usr/bin/ausearch", "-k", "linux_agent_session_1"],
        )

    def test_rule_operation_is_structured_and_bound_to_peer_uid(self):
        command = self.build(
            {
                "operation": "add_rule",
                "audit_uid": 1001,
                "key": "linux_agent_session_exec_1",
                "syscall": "execve",
            },
            peer_pid=-1,
        )
        self.assertEqual(command[0:4], ["/usr/sbin/auditctl", "-a", "always,exit", "-F"])
        self.assertIn("auid=1001", command)
        self.assertEqual(command[-2:], ["-k", "linux_agent_session_exec_1"])

        with self.assertRaisesRegex(observer_helper.HelperRequestError, "requesting process"):
            self.build(
                {
                    "operation": "remove_rule",
                    "audit_uid": 2002,
                    "key": "linux_agent_session_exec_1",
                    "syscall": "execve",
                },
                peer_pid=-1,
            )

    def test_session_capability_protects_rule_readback_and_mutation(self):
        capability = "a" * 64
        key = "linux_agent_session_exec_capability"
        add = {
            "operation": "add_rule",
            "audit_uid": 1001,
            "key": key,
            "syscall": "execve",
            "capability": capability,
        }
        authorization = observer_helper.authorize_request(
            add,
            peer_pid=-1,
            peer_uid=1001,
        )
        observer_helper.finish_authorized_request(
            add,
            authorization,
            {"ok": True},
        )

        listed = {
            "operation": "list_rules",
            "key": key,
            "capability": capability,
        }
        self.assertEqual(
            observer_helper.authorize_request(
                listed,
                peer_pid=-1,
                peer_uid=1001,
            ),
            (key, False, False),
        )
        with self.assertRaisesRegex(observer_helper.HelperRequestError, "does not match"):
            observer_helper.authorize_request(
                {**listed, "capability": "b" * 64},
                peer_pid=-1,
                peer_uid=1001,
            )
        with self.assertRaisesRegex(observer_helper.HelperRequestError, "invalid observer capability"):
            observer_helper.authorize_request(
                {"operation": "search_key", "key": key},
                peer_pid=-1,
                peer_uid=1001,
            )

        failed_remove = {
            "operation": "remove_rule",
            "audit_uid": 1001,
            "key": key,
            "syscall": "execve",
            "capability": capability,
        }
        remove_authorization = observer_helper.authorize_request(
            failed_remove,
            peer_pid=-1,
            peer_uid=1001,
        )
        observer_helper.finish_authorized_request(
            failed_remove,
            remove_authorization,
            {"ok": False},
        )

        release = {
            "operation": "release_key",
            "key": key,
            "capability": capability,
        }
        release_authorization = observer_helper.authorize_request(
            release,
            peer_pid=-1,
            peer_uid=1001,
        )
        release_response = {
            "ok": True,
            "status": "released",
            "exit_code": 0,
            "stderr": "",
        }
        observer_helper.finish_authorized_request(
            release,
            release_authorization,
            release_response,
        )
        self.assertEqual(release_response["status"], "rules_pending_cleanup")
        self.assertEqual(release_response["exit_code"], 1)
        self.assertIn("execve", release_response["stderr"])
        self.assertEqual(
            observer_helper.authorize_request(
                listed,
                peer_pid=-1,
                peer_uid=1001,
            ),
            (key, False, False),
        )

        observer_helper.finish_authorized_request(
            failed_remove,
            remove_authorization,
            {"ok": True},
        )
        release_response = {
            "ok": True,
            "status": "released",
            "exit_code": 0,
            "stderr": "",
        }
        observer_helper.finish_authorized_request(
            release,
            release_authorization,
            release_response,
        )
        self.assertTrue(release_response["ok"])
        with self.assertRaisesRegex(observer_helper.HelperRequestError, "not registered"):
            observer_helper.authorize_request(
                listed,
                peer_pid=-1,
                peer_uid=1001,
            )

    def test_arbitrary_commands_keys_and_syscalls_are_rejected(self):
        invalid_requests = (
            {"operation": "run", "command": "id"},
            {
                "operation": "add_rule",
                "audit_uid": 1001,
                "key": "not-an-agent-key",
                "syscall": "execve",
            },
            {
                "operation": "add_rule",
                "audit_uid": 1001,
                "key": "linux_agent_valid",
                "syscall": "mount",
            },
        )
        for request in invalid_requests:
            with self.subTest(request=request), self.assertRaises(
                observer_helper.HelperRequestError
            ):
                self.build(request, peer_pid=-1)

    def test_command_output_is_bounded_and_process_is_reaped(self):
        command = [
            sys.executable,
            "-c",
            "import sys; sys.stdout.buffer.write(b'x' * 50000); sys.stdout.flush()",
        ]
        with mock.patch.object(observer_helper, "MAX_STREAM_BYTES", 4096):
            result = observer_helper.run_command(command)
        self.assertFalse(result["ok"])
        self.assertEqual(result["status"], "output_limit_exceeded")
        self.assertLessEqual(len(result["stdout"].encode()), 4096)
        self.assertGreater(result["stdout_truncated_bytes"], 0)

    def test_capability_state_survives_helper_restart(self):
        capability = "c" * 64
        key = "linux_agent_session_persisted"
        add = {
            "operation": "add_rule",
            "audit_uid": 1001,
            "key": key,
            "syscall": "execve",
            "capability": capability,
        }
        with tempfile.TemporaryDirectory() as directory:
            state_path = Path(directory) / "capabilities.json"
            observer_helper.configure_capability_state(state_path)
            authorization = observer_helper.authorize_request(
                add,
                peer_pid=-1,
                peer_uid=1001,
            )
            # Ownership is durable before auditctl runs, covering a helper
            # crash after the kernel accepts the rule but before the reply.
            observer_helper.configure_capability_state(state_path)
            self.assertEqual(
                observer_helper._SESSION_CAPABILITIES[key]["syscalls"],
                {"execve"},
            )
            observer_helper.finish_authorized_request(add, authorization, {"ok": True})
            self.assertEqual(state_path.stat().st_mode & 0o777, 0o600)

            # A helper restart clears process memory and reloads the root-owned
            # registry before accepting the next request.
            observer_helper.configure_capability_state(state_path)
            listed = {
                "operation": "list_rules",
                "key": key,
                "capability": capability,
            }
            self.assertEqual(
                observer_helper.authorize_request(
                    listed,
                    peer_pid=-1,
                    peer_uid=1001,
                ),
                (key, False, False),
            )

            remove = {
                **add,
                "operation": "remove_rule",
            }
            remove_authorization = observer_helper.authorize_request(
                remove,
                peer_pid=-1,
                peer_uid=1001,
            )
            observer_helper.finish_authorized_request(
                remove,
                remove_authorization,
                {"ok": True},
            )
            release = {
                "operation": "release_key",
                "key": key,
                "capability": capability,
            }
            release_authorization = observer_helper.authorize_request(
                release,
                peer_pid=-1,
                peer_uid=1001,
            )
            response = {"ok": True, "status": "released"}
            observer_helper.finish_authorized_request(
                release,
                release_authorization,
                response,
            )
            self.assertTrue(response["ok"])

    def test_disconnected_peer_does_not_escape_connection_handler(self):
        server, client = socket.socketpair()
        try:
            client.close()
            with mock.patch.object(
                observer_helper,
                "_peer_credentials",
                return_value=(os.getpid(), os.geteuid(), os.getegid()),
            ):
                with contextlib.redirect_stderr(io.StringIO()):
                    observer_helper.handle_connection(server)
        finally:
            server.close()

    def test_ping_proves_socket_transport_without_running_auditctl(self):
        connection = mock.MagicMock()
        connection.recv.return_value = b'{"operation":"ping"}\n'
        with mock.patch.object(
            observer_helper,
            "_peer_credentials",
            return_value=(os.getpid(), os.geteuid(), os.getegid()),
        ), mock.patch.object(observer_helper, "run_command") as run_command:
            with contextlib.redirect_stderr(io.StringIO()):
                observer_helper.handle_connection(connection)
        response = json.loads(
            connection.sendall.call_args.args[0].decode("utf-8")
        )

        self.assertEqual(
            response,
            {
                "ok": True,
                "status": "ready",
                "exit_code": 0,
                "stdout": "",
                "stderr": "",
            },
        )
        run_command.assert_not_called()

    def test_client_request_rejects_invalid_responses(self):
        responses = (
            (b"", "empty response"),
            (b"not-json", "invalid UTF-8 JSON"),
            (b"[]", "must be a JSON object"),
            (b'{"exit_code":true}', "exit_code is invalid"),
        )
        for payload, expected in responses:
            with self.subTest(payload=payload):
                connection = mock.MagicMock()
                connection.__enter__.return_value = connection
                connection.recv.side_effect = [payload, b""]
                with mock.patch.object(
                    observer_helper.socket,
                    "socket",
                    return_value=connection,
                ), self.assertRaisesRegex(
                    observer_helper.HelperRequestError,
                    expected,
                ):
                    observer_helper.client_request("/run/test.sock", {"operation": "status"})

    def test_request_transport_failure_returns_controlled_diagnostic(self):
        stderr = io.StringIO()
        with mock.patch.object(
            sys,
            "argv",
            [
                "observer_helper.py",
                "request",
                "--socket",
                "/run/test.sock",
                "status",
            ],
        ), mock.patch.object(
            observer_helper,
            "client_request",
            side_effect=ConnectionRefusedError("connection refused"),
        ), contextlib.redirect_stderr(stderr):
            exit_code = observer_helper.main()

        self.assertEqual(125, exit_code)
        self.assertIn("observer helper request failed: connection refused", stderr.getvalue())
        self.assertNotIn("Traceback", stderr.getvalue())

    def test_request_permission_failure_explains_socket_group_repair(self):
        stderr = io.StringIO()
        with mock.patch.object(
            sys,
            "argv",
            [
                "observer_helper.py",
                "request",
                "--socket",
                "/run/test.sock",
                "ping",
            ],
        ), mock.patch.object(
            observer_helper,
            "client_request",
            side_effect=PermissionError(13, "Permission denied"),
        ), contextlib.redirect_stderr(stderr):
            exit_code = observer_helper.main()

        output = stderr.getvalue()
        self.assertEqual(125, exit_code)
        self.assertIn("permission denied for socket /run/test.sock", output)
        self.assertIn("SocketGroup", output)
        self.assertIn("linux-agent-observer-helper.socket", output)
        self.assertNotIn("Traceback", output)


if __name__ == "__main__":
    unittest.main()
