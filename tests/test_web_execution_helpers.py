#!/usr/bin/env python3

import hashlib
import importlib.util
import json
import os
import signal
import socket
import struct
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))

import helper_protocol  # noqa: E402
import host_ops_helper as host_dispatcher  # noqa: E402
import policy_helper  # noqa: E402
import runner  # noqa: E402


def _load_network_host_handler():
    path = (
        ROOT
        / "skills"
        / "network-ops-tools"
        / "scripts"
        / "host_handler.py"
    )
    spec = importlib.util.spec_from_file_location(
        "network_ops_host_handler_test", path
    )
    if spec is None or spec.loader is None:
        raise RuntimeError("network-ops-tools host handler cannot be loaded")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


host_ops_helper = _load_network_host_handler()


class MemoryConnection:
    def __init__(self, request, peer_uid=None):
        self.inbound = bytearray(
            helper_protocol.canonical_json(request) + b"\n" if request is not None else b""
        )
        self.outbound = bytearray()
        self.peer_uid = os.getuid() if peer_uid is None else peer_uid
        self.timeouts = []

    def recv(self, size):
        chunk = bytes(self.inbound[:size])
        del self.inbound[:size]
        return chunk

    def sendall(self, payload):
        self.outbound.extend(payload)

    def getsockopt(self, level, option, size):
        self.assert_socket_option(level, option, size)
        return struct.pack("3i", os.getpid(), self.peer_uid, os.getgid())

    @staticmethod
    def assert_socket_option(level, option, size):
        if (level, option, size) != (socket.SOL_SOCKET, socket.SO_PEERCRED, 12):
            raise AssertionError("unexpected peer credential socket option")

    def settimeout(self, value):
        self.timeouts.append(value)


def socket_exchange(handler, request, expected_uid=None, peer_uid=None):
    connection = MemoryConnection(request, peer_uid=peer_uid)
    expected_uid = os.getuid() if expected_uid is None else expected_uid
    handler(connection, expected_uid)
    return json.loads(connection.outbound.decode("utf-8"))


class HelperProtocolTests(unittest.TestCase):
    def test_client_transfers_one_descriptor_with_the_versioned_request(self):
        with tempfile.TemporaryFile() as credential:
            credential.write(b"credential-payload")
            credential.flush()
            request = helper_protocol.build_request(
                "database.health",
                {"profile_id": "primary", "credential_ref": "a" * 32},
                summary="fixed database query",
            )
            response = helper_protocol.canonical_json(
                {
                    "ok": True,
                    "status": "checked",
                    "protocol_version": helper_protocol.PROTOCOL_VERSION,
                    "request_id": request["request_id"],
                }
            ) + b"\n"

            class ConnectedSocket:
                def __init__(self):
                    self.sent = bytearray()
                    self.ancillary = []
                    self.response = bytearray(response)

                def __enter__(self):
                    return self

                def __exit__(self, _kind, _value, _traceback):
                    return None

                def settimeout(self, _timeout):
                    return None

                def connect(self, _path):
                    return None

                def sendmsg(self, buffers, ancillary):
                    payload = b"".join(buffers)
                    self.sent.extend(payload)
                    self.ancillary.extend(ancillary)
                    return len(payload)

                def sendall(self, payload):
                    self.sent.extend(payload)

                def shutdown(self, _direction):
                    return None

                def recv(self, size):
                    chunk = bytes(self.response[:size])
                    del self.response[:size]
                    return chunk

            connection = ConnectedSocket()
            with mock.patch.object(
                helper_protocol.socket,
                "socket",
                return_value=connection,
            ):
                result = helper_protocol.client_request(
                    "/unused/helper.sock",
                    request,
                    descriptor=credential.fileno(),
                )

            self.assertTrue(result["ok"])
            self.assertEqual(helper_protocol.canonical_json(request) + b"\n", connection.sent)
            self.assertEqual(1, len(connection.ancillary))
            level, kind, rights = connection.ancillary[0]
            self.assertEqual((socket.SOL_SOCKET, socket.SCM_RIGHTS), (level, kind))
            (sent_descriptor,) = struct.unpack("i", rights)
            self.assertEqual(credential.fileno(), sent_descriptor)

            received_descriptor = os.dup(sent_descriptor)

            class DescriptorConnection:
                calls = 0

                def recvmsg(self, _size, _ancillary_size, _flags):
                    self.calls += 1
                    if self.calls == 1:
                        return (
                            bytes(connection.sent),
                            [(level, kind, struct.pack("i", received_descriptor))],
                            0,
                            None,
                        )
                    return b"", [], 0, None

            received, descriptors = helper_protocol.receive_json_with_descriptors(
                DescriptorConnection()
            )
            try:
                self.assertEqual(request, received)
                self.assertEqual(1, len(descriptors))
                self.assertEqual(b"credential-payload", os.pread(descriptors[0], 4096, 0))
            finally:
                for descriptor in descriptors:
                    os.close(descriptor)

        with self.assertRaises(OSError):
            os.fstat(received_descriptor)

    def test_request_digest_detects_parameter_or_summary_changes(self):
        request = helper_protocol.build_request(
            "ping",
            {},
            summary="readiness",
            request_id="a" * 32,
        )
        self.assertEqual(helper_protocol.validate_request(request)[0], "ping")

        for mutated in (
            {**request, "params": {"extra": True}},
            {**request, "plan": {**request["plan"], "summary": "changed"}},
        ):
            with self.subTest(mutated=mutated), self.assertRaises(
                helper_protocol.ProtocolError
            ):
                helper_protocol.validate_request(mutated)

    def test_request_schema_rejects_unknown_top_level_and_plan_fields(self):
        request = helper_protocol.build_request("ping", {}, summary="readiness")

        for mutated in (
            {**request, "credential": "must-not-be-accepted"},
            {**request, "plan": {**request["plan"], "argv": ["/bin/sh"]}},
        ):
            with self.subTest(mutated=mutated), self.assertRaisesRegex(
                helper_protocol.ProtocolError,
                "fields do not match",
            ):
                helper_protocol.validate_request(mutated)

    def test_request_decoder_rejects_duplicate_keys_and_non_finite_numbers(self):
        payloads = (
            b'{"operation":"ping","operation":"execute"}\n',
            b'{"value":NaN}\n',
            b'{"value":Infinity}\n',
        )
        for payload in payloads:
            connection = MemoryConnection(None)
            connection.inbound.extend(payload)
            with self.subTest(payload=payload), self.assertRaises(
                helper_protocol.ProtocolError
            ):
                helper_protocol.receive_json(connection)

    def test_request_decoder_rejects_a_second_frame_split_after_newline(self):
        connection = mock.MagicMock()
        connection.recv.side_effect = [b'{"operation":"ping"}\n', b'{"extra":true}\n', b""]
        with self.assertRaisesRegex(
            helper_protocol.ProtocolError,
            "exactly one newline-terminated",
        ):
            helper_protocol.receive_json(connection)

    def test_client_rejects_malformed_or_mismatched_response_frames(self):
        request = helper_protocol.build_request("ping", {}, summary="readiness")
        request_id = request["request_id"]
        payloads = (
            b'{"ok":true}\n{}\n',
            (
                '{"ok":true,"ok":false,"status":"ready",'
                f'"protocol_version":"{helper_protocol.PROTOCOL_VERSION}",'
                f'"request_id":"{request_id}"}}\n'
            ).encode(),
            (
                '{"ok":true,"status":"ready","value":NaN,'
                f'"protocol_version":"{helper_protocol.PROTOCOL_VERSION}",'
                f'"request_id":"{request_id}"}}\n'
            ).encode(),
            helper_protocol.canonical_json(
                {
                    "ok": True,
                    "status": "ready",
                    "protocol_version": helper_protocol.PROTOCOL_VERSION,
                    "request_id": "f" * 32,
                }
            )
            + b"\n",
        )
        for payload in payloads:
            with self.subTest(payload=payload):
                connection = mock.MagicMock()
                connection.__enter__.return_value = connection
                connection.recv.side_effect = [payload, b""]
                with mock.patch.object(
                    helper_protocol.socket,
                    "socket",
                    return_value=connection,
                ), self.assertRaises(helper_protocol.ProtocolError):
                    helper_protocol.client_request("/run/test.sock", request)

    def test_peer_uid_is_enforced_by_each_socket_service(self):
        request = helper_protocol.build_request("ping", {}, summary="readiness")
        wrong_uid = os.getuid() + 1
        for handler in (
            runner.handle_connection,
            host_dispatcher.handle_connection,
            policy_helper.handle_connection,
        ):
            with self.subTest(handler=handler.__module__):
                response = socket_exchange(
                    handler,
                    request,
                    expected_uid=wrong_uid,
                    peer_uid=os.getuid(),
                )
                self.assertFalse(response["ok"])
                expected_code = (
                    "runner_rejected" if handler is runner.handle_connection else "helper_rejected"
                )
                self.assertEqual(response["code"], expected_code)
                self.assertIn("not authorized", response["error"])

    def test_ping_responses_use_the_versioned_protocol(self):
        request = helper_protocol.build_request("ping", {}, summary="readiness")
        expected = {
            runner.handle_connection: "runner_uid",
            host_dispatcher.handle_connection: "host-dispatcher",
            policy_helper.handle_connection: "policy-writer",
        }
        for handler, marker in expected.items():
            with self.subTest(handler=handler.__module__):
                response = socket_exchange(handler, request)
                self.assertTrue(response["ok"])
                self.assertEqual(
                    response["protocol_version"],
                    helper_protocol.PROTOCOL_VERSION,
                )
                self.assertIn(marker, response.values())


class RunnerTests(unittest.TestCase):
    def _write_skill_package(
        self,
        package,
        script_name="inspect.sh",
        *,
        category="system",
        execution_class="runner",
        capability="",
        runtime_inputs=None,
    ):
        package.mkdir(parents=True, exist_ok=True)
        (package / "SKILL.md").write_text(
            f"---\nname: {package.name}\ndescription: fixture\n---\n",
            encoding="utf-8",
        )
        execution = {
            "class": execution_class,
            "capability": capability,
            "dispatch": "always" if execution_class == "runner" else "apply_only",
        }
        guards = []
        if execution_class != "runner":
            adapter = package / "scripts" / "fixture-adapter.py"
            adapter.parent.mkdir(parents=True, exist_ok=True)
            adapter.write_text("#!/usr/bin/env python3\n", encoding="utf-8")
            execution["adapter"] = "scripts/fixture-adapter.py"
            guards = [
                {
                    "type": "runner_fallthrough",
                    "field": "action",
                    "default": "inspect",
                    "allowed": ["inspect", "plan"],
                    "boolean_flag": "apply",
                }
            ]
        origin_is_user = package.is_relative_to(self.data / "skills")
        (package / "linux-agent.json").write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "package_version": "1.0.0",
                    "core_api": 1,
                    "category": category,
                    "tools": [
                        {
                            "name": script_name.removesuffix(".sh"),
                            "description": "fixture tool",
                            "entrypoint": f"scripts/{script_name}",
                            "risk": "low",
                            "approval_scope": (
                                "skill_readonly" if origin_is_user else "fixture_scope"
                            ),
                            "execution": execution,
                            "runtime_inputs": runtime_inputs or [],
                            "guards": guards,
                        }
                    ],
                    "components": {},
                }
            ),
            encoding="utf-8",
        )
        if not origin_is_user:
            self._rewrite_builtin_index(package.parent)

    @staticmethod
    def _rewrite_builtin_index(skills_root):
        lines = ["# Builtin Skills", ""]
        for package in sorted(
            (path for path in skills_root.iterdir() if path.is_dir()),
            key=lambda path: path.name,
        ):
            extension_path = package / "linux-agent.json"
            if not extension_path.is_file():
                continue
            extension = json.loads(extension_path.read_text(encoding="utf-8"))
            lines.extend((f"## {package.name}", "", "> fixture", ""))
            for tool in extension["tools"]:
                lines.append(
                    f"- `{package.name}/{tool['name']}`: {tool['description']}"
                )
            lines.append("")
        (skills_root / "INDEX.md").write_text("\n".join(lines), encoding="utf-8")

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name) / "release"
        self.data = Path(self.temp.name) / "data"
        for path in (
            self.root / "skills" / "builtin" / "scripts",
            self.root / "lib",
            self.root / "mcp" / "server",
            self.data / "skills" / "user" / "scripts",
            self.data / "runner-tmp",
            self.data / "logs",
        ):
            path.mkdir(parents=True, exist_ok=True)
        (self.data / ".runtime.lock").touch(mode=0o600)
        self.environment = {
            "LINUX_AGENT_ROOT": str(self.root),
            "LINUX_AGENT_DATA_DIR": str(self.data),
            "LINUX_AGENT_BUILTIN_SKILLS_DIR": str(self.root / "skills"),
            "LINUX_AGENT_USER_SKILLS_DIR": str(self.data / "skills"),
            "LINUX_AGENT_MCP_DIR": str(self.root / "mcp"),
            "LINUX_AGENT_TMP_ROOT": str(self.data / "runner-tmp"),
            "LINUX_AGENT_LOG_DIR": str(self.data / "logs"),
        }
        self._write_skill_package(self.root / "skills" / "builtin")
        self._write_skill_package(
            self.data / "skills" / "user",
            category="custom",
        )

    def tearDown(self):
        self.temp.cleanup()

    def test_runner_environment_does_not_forward_agent_secrets_or_config(self):
        secrets = {
            "LINUX_AGENT_API_KEY": "provider-secret",
            "LINUX_AGENT_WEB_TOKEN": "web-secret",
            "LINUX_AGENT_CONFIG_FILE": "/protected/config.json",
            "BACKUP_PROVIDER_API_KEY": "backup-secret",
        }
        with mock.patch.dict(os.environ, {**self.environment, **secrets}, clear=False):
            environment = runner.runner_environment()

        for name, value in secrets.items():
            with self.subTest(name=name):
                self.assertNotIn(name, environment)
                self.assertNotIn(value, environment.values())
        self.assertNotIn("LINUX_AGENT_LOG_DIR", environment)
        self.assertEqual(environment["LINUX_AGENT_EXECUTION_ISOLATION"], "runner_uid")

    def test_user_skill_is_forced_through_the_fixed_script_contract(self):
        script = self.data / "skills" / "user" / "scripts" / "inspect.sh"
        script.write_text("#!/usr/bin/env bash\n", encoding="utf-8")
        outside = Path(self.temp.name) / "outside.sh"
        outside.write_text("#!/usr/bin/env bash\n", encoding="utf-8")

        with mock.patch.dict(os.environ, self.environment, clear=False), mock.patch.object(
            runner,
            "_trusted_executable",
            return_value="/usr/bin/bash",
        ):
            kind, command, timeout, output_limit, environment_overrides = (
                runner.validate_execution(
                    {
                        "kind": "skill",
                        "argv": ["bash", str(script), "{}"],
                        "timeout_sec": 5,
                        "max_output_bytes": 4096,
                    }
                )
            )
            with self.assertRaises(runner.RunnerRequestError):
                runner.validate_execution(
                    {
                        "kind": "skill",
                        "argv": ["bash", str(outside), "{}"],
                        "timeout_sec": 5,
                        "max_output_bytes": 4096,
                    }
                )

        self.assertEqual(kind, "skill")
        self.assertEqual(command[1:], [str(script), "{}"])
        self.assertEqual((timeout, output_limit), (5, 4096))
        self.assertEqual(environment_overrides, {})

    def test_release_pointer_symlink_resolves_inside_allowlisted_roots(self):
        install_root = Path(self.temp.name) / "install"
        release = install_root / "releases" / "v1"
        current = install_root / "current"
        data = install_root / "data"
        script = release / "skills" / "controlled-tools" / "scripts" / "local-analyze.sh"
        client = release / "lib" / "mcp_client.py"
        manifest = release / "mcp" / "server" / "manifest.json"
        arguments = data / "runner-tmp" / "arguments.json"
        for path in (script, client, manifest, arguments):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("{}\n", encoding="utf-8")
        (data / "skills").mkdir()
        self._write_skill_package(
            script.parent.parent,
            "local-analyze.sh",
            category="file",
        )
        current.symlink_to(release, target_is_directory=True)
        environment = {
            "LINUX_AGENT_ROOT": str(current),
            "LINUX_AGENT_DATA_DIR": str(data),
            "LINUX_AGENT_BUILTIN_SKILLS_DIR": str(current / "skills"),
            "LINUX_AGENT_USER_SKILLS_DIR": str(data / "skills"),
            "LINUX_AGENT_MCP_DIR": str(current / "mcp"),
            "LINUX_AGENT_TMP_ROOT": str(data / "runner-tmp"),
        }

        with mock.patch.dict(os.environ, environment, clear=False), mock.patch.object(
            runner,
            "_trusted_executable",
            side_effect=lambda name: f"/usr/bin/{name}",
        ):
            _kind, skill_command, *_rest = runner.validate_execution(
                {
                    "kind": "skill",
                    "argv": ["bash", str(current / script.relative_to(release)), "{}"],
                    "timeout_sec": 5,
                    "max_output_bytes": 4096,
                }
            )
            _kind, mcp_command, *_rest = runner.validate_execution(
                {
                    "kind": "mcp",
                    "argv": [
                        "python3",
                        str(current / client.relative_to(release)),
                        "call-tool",
                        str(current / manifest.relative_to(release)),
                        "inspect",
                        str(arguments),
                    ],
                    "timeout_sec": 5,
                    "max_output_bytes": 4096,
                }
            )

        self.assertEqual(Path(skill_command[1]), script.resolve())
        self.assertEqual(Path(mcp_command[1]), client.resolve())
        self.assertEqual(Path(mcp_command[3]), manifest.resolve())

    def test_runner_rejects_final_symlink_and_intermediate_escape(self):
        actual = self.data / "skills" / "user" / "scripts" / "actual.sh"
        linked = actual.with_name("linked.sh")
        outside = Path(self.temp.name) / "outside"
        escaped = self.data / "skills" / "escape"
        actual.write_text("#!/usr/bin/env bash\n", encoding="utf-8")
        outside.mkdir()
        (outside / "outside.sh").write_text("#!/usr/bin/env bash\n", encoding="utf-8")
        linked.symlink_to(actual)
        escaped.symlink_to(outside, target_is_directory=True)

        with mock.patch.dict(os.environ, self.environment, clear=False), mock.patch.object(
            runner,
            "_trusted_executable",
            return_value="/usr/bin/bash",
        ):
            for script in (linked, escaped / "outside.sh"):
                with self.subTest(script=script), self.assertRaises(
                    runner.RunnerRequestError
                ):
                    runner.validate_execution(
                        {
                            "kind": "skill",
                            "argv": ["bash", str(script), "{}"],
                            "timeout_sec": 5,
                            "max_output_bytes": 4096,
                        }
                    )

    def test_runner_rejects_symlinked_overlay_and_staging_roots(self):
        actual_skills = Path(self.temp.name) / "actual-skills"
        actual_skills.mkdir()
        linked_skills = self.data / "skills-link"
        linked_skills.symlink_to(actual_skills, target_is_directory=True)
        actual_tmp = Path(self.temp.name) / "actual-tmp"
        actual_tmp.mkdir()
        linked_tmp = self.data / "tmp-link"
        linked_tmp.symlink_to(actual_tmp, target_is_directory=True)
        script = actual_tmp / "remote.sh"
        script.write_text("#!/usr/bin/env bash\n", encoding="utf-8")
        with mock.patch.dict(
            os.environ,
            {**self.environment, "LINUX_AGENT_USER_SKILLS_DIR": str(linked_skills)},
            clear=False,
        ), mock.patch.object(
            runner,
            "_trusted_executable",
            return_value="/usr/bin/bash",
        ):
            with self.assertRaisesRegex(runner.RunnerRequestError, "User Skill root"):
                runner.validate_execution(
                    {
                        "kind": "skill",
                        "argv": ["bash", str(linked_skills / "missing.sh"), "{}"],
                        "timeout_sec": 5,
                        "max_output_bytes": 4096,
                    }
                )
        with mock.patch.dict(
            os.environ,
            {**self.environment, "LINUX_AGENT_TMP_ROOT": str(linked_tmp)},
            clear=False,
        ), mock.patch.object(
            runner,
            "_trusted_executable",
            return_value="/usr/bin/bash",
        ):
            with self.assertRaisesRegex(runner.RunnerRequestError, "Runner staging root"):
                runner.validate_execution(
                    {
                        "kind": "remote_script",
                        "argv": ["bash", str(script), "{}"],
                        "timeout_sec": 5,
                        "max_output_bytes": 4096,
                    }
                )

    def test_runner_rejects_writable_skill_directories(self):
        package = self.data / "skills" / "user"
        scripts = package / "scripts"
        script = scripts / "inspect.sh"
        script.write_text("#!/usr/bin/env bash\n", encoding="utf-8")
        with mock.patch.dict(os.environ, self.environment, clear=False), mock.patch.object(
            runner,
            "_trusted_executable",
            return_value="/usr/bin/bash",
        ):
            for directory in (package, scripts):
                directory.chmod(0o770)
                with self.subTest(directory=directory), self.assertRaisesRegex(
                    runner.RunnerRequestError,
                    "must not be group/world writable",
                ):
                    runner.validate_execution(
                        {
                            "kind": "skill",
                            "argv": ["bash", str(script), "{}"],
                            "timeout_sec": 5,
                            "max_output_bytes": 4096,
                        }
                    )
                directory.chmod(0o750)

    def test_runner_rejects_unknown_execute_parameters(self):
        with self.assertRaisesRegex(runner.RunnerRequestError, "unsupported fields"):
            runner.validate_execution(
                {
                    "kind": "terminal",
                    "argv": ["bash", "-lc", "true"],
                    "timeout_sec": 5,
                    "max_output_bytes": 4096,
                    "environment": {"LINUX_AGENT_API_KEY": "forged"},
                }
            )

    def test_only_builtin_session_history_receives_a_redacted_snapshot(self):
        session_skill = self.root / "skills" / "session-history" / "scripts"
        session_skill.mkdir(parents=True)
        script = session_skill / "last-command-output.sh"
        script.write_text(
            "#!/usr/bin/env bash\n"
            "jq -cn --arg file \"${LINUX_AGENT_AUDIT_SNAPSHOT_FILE:-}\" "
            "--arg session \"${LINUX_AGENT_AUDIT_SNAPSHOT_SESSION_ID:-}\" "
            "'{ok:true,file:$file,session:$session}'\n",
            encoding="utf-8",
        )
        self._write_skill_package(
            session_skill.parent,
            "last-command-output.sh",
            category="history",
            runtime_inputs=["audit_snapshot"],
        )
        snapshot = self.data / "runner-tmp" / "audit-snapshot.fixture.jsonl"
        snapshot.write_text('{"safe":true}\n', encoding="utf-8")
        snapshot.chmod(0o640)
        params = {
            "kind": "skill",
            "argv": [
                "bash",
                str(script),
                '{"session_id":"session_fixture"}',
            ],
            "timeout_sec": 5,
            "max_output_bytes": 4096,
            "audit_snapshot": str(snapshot),
            "audit_snapshot_session": "session_fixture",
        }

        with mock.patch.dict(os.environ, self.environment, clear=False), mock.patch.object(
            runner,
            "_trusted_executable",
            return_value="/usr/bin/bash",
        ):
            kind, command, timeout, output_limit, overrides = runner.validate_execution(
                params
            )
            result = runner.execute(command, timeout, output_limit, overrides)

        self.assertEqual(kind, "skill")
        self.assertTrue(result["ok"], result)
        output = json.loads(result["stdout"])
        self.assertEqual(output["file"], str(snapshot))
        self.assertEqual(output["session"], "session_fixture")

        user_script = self.data / "skills" / "user" / "scripts" / "inspect.sh"
        user_script.write_text("#!/usr/bin/env bash\n", encoding="utf-8")
        user_params = {
            **params,
            "argv": ["bash", str(user_script), "{}"],
        }
        with mock.patch.dict(os.environ, self.environment, clear=False), mock.patch.object(
            runner,
            "_trusted_executable",
            return_value="/usr/bin/bash",
        ), self.assertRaisesRegex(
            runner.RunnerRequestError, "signed builtin runtime-input"
        ):
            runner.validate_execution(user_params)

    def test_busy_runner_rejects_without_starting_a_process(self):
        slots = runner.threading.BoundedSemaphore(1)
        self.assertTrue(slots.acquire(blocking=False))
        request = helper_protocol.build_request(
            "execute",
            {
                "kind": "terminal",
                "argv": ["bash", "-lc", "exit 0"],
                "timeout_sec": 5,
                "max_output_bytes": 4096,
            },
            summary="execute",
        )
        try:
            response = socket_exchange(
                lambda connection, uid: runner.handle_connection(connection, uid, slots),
                request,
            )
        finally:
            slots.release()

        self.assertEqual(response["frame"], "result")
        self.assertFalse(response["result"]["ok"])
        self.assertEqual(response["result"]["status"], "runner_busy")
        self.assertEqual(response["result"]["exit_code"], 125)

    def test_runner_rejects_unregistered_or_privileged_user_skill_scripts(self):
        package = self.data / "skills" / "user"
        script = package / "scripts" / "inspect.sh"
        script.write_text("#!/usr/bin/env bash\n", encoding="utf-8")
        params = {
            "kind": "skill",
            "argv": ["bash", str(script), "{}"],
            "timeout_sec": 5,
            "max_output_bytes": 4096,
        }
        with mock.patch.dict(os.environ, self.environment, clear=False), mock.patch.object(
            runner,
            "_trusted_executable",
            return_value="/usr/bin/bash",
        ):
            extension_path = package / "linux-agent.json"
            extension = json.loads(extension_path.read_text(encoding="utf-8"))
            extension["tools"][0]["execution"]["class"] = "host_helper"
            extension["tools"][0]["execution"]["capability"] = "firewall.apply"
            extension["tools"][0]["execution"]["adapter"] = "scripts/inspect.sh"
            extension_path.write_text(json.dumps(extension), encoding="utf-8")
            with self.assertRaisesRegex(
                runner.RunnerRequestError, "unprivileged runner"
            ):
                runner.validate_execution(params)

            extension["tools"][0]["execution"] = {
                "class": "runner",
                "capability": "",
                "dispatch": "always",
            }
            extension["tools"][0]["entrypoint"] = "scripts/other.sh"
            (package / "scripts" / "other.sh").write_text(
                "#!/usr/bin/env bash\n", encoding="utf-8"
            )
            extension_path.write_text(json.dumps(extension), encoding="utf-8")
            with self.assertRaisesRegex(runner.RunnerRequestError, "not declared|does not match"):
                runner.validate_execution(params)

    def test_runner_allows_read_only_host_helper_skill_forms_but_rejects_apply(self):
        package = self.root / "skills" / "network-ops-tools"
        script = package / "scripts" / "firewall.sh"
        script.parent.mkdir(parents=True)
        script.write_text("#!/usr/bin/env bash\n", encoding="utf-8")
        self._write_skill_package(
            package,
            "firewall.sh",
            category="network",
            execution_class="host_helper",
            capability="firewall.apply",
        )
        params = {
            "kind": "skill",
            "argv": ["bash", str(script), "{}"],
            "timeout_sec": 5,
            "max_output_bytes": 4096,
        }
        with mock.patch.dict(os.environ, self.environment, clear=False), mock.patch.object(
            runner,
            "_trusted_executable",
            return_value="/usr/bin/bash",
        ):
            kind, command, timeout, output_limit, overrides = runner.validate_execution(params)
            self.assertEqual(kind, "skill")
            self.assertEqual(command[1:], [str(script), "{}"])
            self.assertEqual((timeout, output_limit, overrides), (5, 4096, {}))

            apply_params = {
                **params,
                "argv": [
                    "bash",
                    str(script),
                    '{"action":"apply","apply":true}',
                ],
            }
            with self.assertRaisesRegex(
                runner.RunnerRequestError, "dedicated helper"
            ):
                runner.validate_execution(apply_params)

            ambiguous_params = {
                **params,
                "argv": [
                    "bash",
                    str(script),
                    '{"action":"apply","apply":"yes"}',
                ],
            }
            with self.assertRaisesRegex(runner.RunnerRequestError, "must be boolean"):
                runner.validate_execution(ambiguous_params)

    def test_runner_rejects_group_writable_skill_files(self):
        script = self.root / "skills" / "builtin" / "scripts" / "inspect.sh"
        script.write_text("#!/usr/bin/env bash\n", encoding="utf-8")
        script.chmod(0o660)
        params = {
            "kind": "skill",
            "argv": ["bash", str(script), "{}"],
            "timeout_sec": 5,
            "max_output_bytes": 4096,
        }
        with mock.patch.dict(os.environ, self.environment, clear=False), mock.patch.object(
            runner,
            "_trusted_executable",
            return_value="/usr/bin/bash",
        ), self.assertRaisesRegex(runner.RunnerRequestError, "group/world writable"):
            runner.validate_execution(params)

    def test_runner_rejects_user_package_that_conflicts_with_builtin(self):
        builtin = self.root / "skills" / "conflict"
        user = self.data / "skills" / "conflict"
        for package in (builtin, user):
            (package / "scripts").mkdir(parents=True)
            (package / "scripts" / "inspect.sh").write_text(
                "#!/usr/bin/env bash\n",
                encoding="utf-8",
            )
            self._write_skill_package(package)
        params = {
            "kind": "skill",
            "argv": ["bash", str(user / "scripts" / "inspect.sh"), "{}"],
            "timeout_sec": 5,
            "max_output_bytes": 4096,
        }
        with mock.patch.dict(os.environ, self.environment, clear=False), mock.patch.object(
            runner,
            "_trusted_executable",
            return_value="/usr/bin/bash",
        ), self.assertRaisesRegex(runner.RunnerRequestError, "reserved built-in"):
            runner.validate_execution(params)

    def test_execution_caps_output_and_reaps_background_process_group(self):
        command = [
            "/usr/bin/bash",
            "-lc",
            "sleep 60 & child=$!; printf '%s\\n' \"$child\"; printf '%05000d' 0",
        ]
        child_pid = None
        with mock.patch.dict(os.environ, self.environment, clear=False):
            result = runner.execute(command, timeout_sec=5, max_output=4096)
        try:
            child_pid = int(result["stdout"].splitlines()[0])
            self.assertFalse(result["ok"])
            self.assertEqual(result["status"], "output_limit_exceeded")
            self.assertEqual(result["exit_code"], 125)
            self.assertTrue(result["output_capped"])
            self.assertGreater(result["stdout_truncated_bytes"], 0)
            for _ in range(40):
                status_path = Path(f"/proc/{child_pid}/stat")
                if not status_path.exists():
                    break
                fields = status_path.read_text(encoding="utf-8").split()
                if len(fields) > 2 and fields[2] == "Z":
                    break
                time.sleep(0.025)
            else:
                self.fail("background process remained alive after runner completion")
        finally:
            if child_pid:
                try:
                    os.kill(child_pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass

    def test_execution_cancels_the_process_group_when_the_peer_disappears(self):
        child_file = Path(self.temp.name) / "cancelled-child.pid"
        delayed_marker = Path(self.temp.name) / "must-not-exist"
        command = [
            "/usr/bin/bash",
            "-lc",
            f"(sleep 0.5; touch '{delayed_marker}') & child=$!; "
            f"printf '%s\\n' \"$child\" >'{child_file}'; wait",
        ]
        with mock.patch.dict(os.environ, self.environment, clear=False):
            result = runner.execute(
                command,
                timeout_sec=5,
                max_output=4096,
                peer_disconnected=child_file.exists,
            )

        child_pid = int(child_file.read_text(encoding="utf-8").strip())
        time.sleep(0.6)
        self.assertEqual(result["status"], "cancelled")
        self.assertEqual(result["exit_code"], 125)
        self.assertFalse(delayed_marker.exists())
        status_path = Path(f"/proc/{child_pid}/stat")
        if status_path.exists():
            self.assertEqual(status_path.read_text(encoding="utf-8").split()[2], "Z")

    def test_stream_client_rejects_bad_sequence_duplicate_or_missing_final(self):
        request = helper_protocol.build_request("execute", {}, summary="stream")
        request_id = request["request_id"]

        def encoded(sequence, result_request_id=request_id):
            return helper_protocol.canonical_json(
                {
                    "protocol_version": helper_protocol.PROTOCOL_VERSION,
                    "request_id": request_id,
                    "sequence": sequence,
                    "frame": "result",
                    "result": {
                        "protocol_version": helper_protocol.PROTOCOL_VERSION,
                        "request_id": result_request_id,
                        "ok": True,
                        "status": "executed",
                        "exit_code": 0,
                    },
                }
            ) + b"\n"

        payloads = (
            [encoded(1), b""],
            [encoded(0, "f" * 32), b""],
            [encoded(0), encoded(1), b""],
            [b""],
        )
        for chunks in payloads:
            with self.subTest(chunks=chunks):
                connection = mock.MagicMock()
                connection.__enter__.return_value = connection
                connection.recv.side_effect = chunks
                with mock.patch.object(
                    runner.socket, "socket", return_value=connection
                ), self.assertRaises(helper_protocol.ProtocolError):
                    runner._stream_request("/run/test.sock", request, 1, 4096)


class HostDispatcherTests(unittest.TestCase):
    def test_dispatch_uses_the_registered_package_handler(self):
        component = mock.Mock()
        component.dispatch.return_value = {
            "ok": True,
            "status": "applied",
            "operation": "sample.apply",
        }
        handler_path = Path("/trusted/skill/scripts/host_handler.py")
        with mock.patch.object(
            host_dispatcher,
            "_capability_registry",
            return_value={"sample.apply": (handler_path, "sample-skill")},
        ), mock.patch.object(
            host_dispatcher,
            "_load_handler",
            return_value=component,
        ) as loader:
            result = host_dispatcher.dispatch_capability(
                "sample.apply", {"value": 1}
            )

        self.assertTrue(result["ok"])
        loader.assert_called_once_with(handler_path, "sample-skill")
        component.dispatch.assert_called_once_with("sample.apply", {"value": 1})

    def test_dispatch_rejects_unknown_capabilities_and_mismatched_results(self):
        with mock.patch.object(
            host_dispatcher, "_capability_registry", return_value={}
        ), self.assertRaisesRegex(
            host_dispatcher.HostHelperError, "unsupported"
        ):
            host_dispatcher.dispatch_capability("sample.apply", {})

        component = mock.Mock()
        component.dispatch.return_value = {
            "ok": True,
            "status": "applied",
            "operation": "other.apply",
        }
        with mock.patch.object(
            host_dispatcher,
            "_capability_registry",
            return_value={"sample.apply": (Path("/handler.py"), "sample")},
        ), mock.patch.object(
            host_dispatcher, "_load_handler", return_value=component
        ), self.assertRaisesRegex(
            host_dispatcher.HostHelperError, "invalid result"
        ):
            host_dispatcher.dispatch_capability("sample.apply", {})

    def test_registry_disables_duplicate_package_capabilities(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "skills"
            names = ("first-skill", "second-skill")
            root.mkdir(parents=True)
            (root / "INDEX.md").write_text("# test catalog\n", encoding="utf-8")
            for name in names:
                scripts = root / name / "scripts"
                scripts.mkdir(parents=True)
                (scripts / "host_handler.py").write_text(
                    "def dispatch(operation, params):\n"
                    "    return {'ok': True, 'operation': operation}\n",
                    encoding="utf-8",
                )
            validation = {
                "ok": True,
                "skills": [
                    {
                        "name": name,
                        "state": "installed",
                        "package": str(root / name),
                    "components": {
                        "host_helper": {"handler": "scripts/host_handler.py"}
                    },
                        "package_tools": [
                        {
                            "name": "apply",
                            "description": "Apply sample operation.",
                            "execution": {
                                "class": "host_helper",
                                "capability": "sample.apply",
                            },
                        }
                    ],
                    }
                    for name in names
                ],
                "findings": [],
            }

            environment = {
                "LINUX_AGENT_BUILTIN_SKILLS_DIR": str(root),
                "LINUX_AGENT_RELEASE_MANIFEST": "",
            }
            with mock.patch.dict(
                os.environ, environment, clear=False
            ), mock.patch.object(
                host_dispatcher, "validate_builtin_root", return_value=validation
            ):
                self.assertEqual({}, host_dispatcher._capability_registry())


class HostOpsHelperTests(unittest.TestCase):
    def test_firewall_accepts_only_structured_allowlisted_parameters(self):
        params = {
            "backend": "ufw",
            "decision": "allow",
            "protocol": "tcp",
            "port": 443,
            "source": "203.0.113.0/24",
        }
        with mock.patch.object(host_ops_helper, "_trusted_tool", return_value="/usr/sbin/ufw"):
            backend, command, reload_command, normalized = host_ops_helper._firewall_params(params)

        self.assertEqual(backend, "ufw")
        self.assertEqual(command[0], "/usr/sbin/ufw")
        self.assertIsNone(reload_command)
        self.assertEqual(normalized["port"], 443)
        with self.assertRaises(host_ops_helper.HostHelperError):
            host_ops_helper._firewall_params({**params, "argv": ["/bin/sh"]})
        with self.assertRaises(host_ops_helper.HostHelperError):
            host_ops_helper._firewall_params({**params, "backend": "/tmp/tool"})

    def test_hosts_compare_and_swap_rejects_a_changed_target(self):
        with tempfile.TemporaryDirectory() as temporary:
            hosts = Path(temporary) / "hosts"
            hosts.write_text("127.0.0.1 localhost\n", encoding="utf-8")
            params = {
                "action": "add",
                "ip": "203.0.113.7",
                "hostnames": ["example.test"],
                "hostname": "",
                "merge": False,
                "expected_sha256": "0" * 64,
            }
            with mock.patch.object(host_ops_helper, "HOSTS_PATH", hosts), mock.patch.object(
                host_ops_helper,
                "_write_hosts",
            ) as write:
                result = host_ops_helper.apply_hosts(params)

        self.assertFalse(result["ok"])
        self.assertEqual(result["status"], "target_changed")
        write.assert_not_called()

    def test_hosts_add_and_remove_use_the_configured_parent_directory_atomically(self):
        with tempfile.TemporaryDirectory() as temporary:
            hosts = Path(temporary) / "hosts"
            hosts.write_text("127.0.0.1 localhost\n", encoding="utf-8")
            add_params = {
                "action": "add",
                "ip": "203.0.113.7",
                "hostnames": ["Example.Test", "example.test"],
                "hostname": "",
                "merge": False,
                "expected_sha256": hashlib.sha256(hosts.read_bytes()).hexdigest(),
            }
            with mock.patch.object(host_ops_helper, "HOSTS_PATH", hosts):
                added = host_ops_helper.apply_hosts(add_params)
                self.assertTrue(added["ok"], added)
                self.assertIn("203.0.113.7\texample.test\n", hosts.read_text())
                backup = Path(added["backup_path"])
                self.assertEqual(backup.parent, hosts.parent)
                self.assertEqual(backup.read_text(), "127.0.0.1 localhost\n")

                remove_params = {
                    "action": "remove",
                    "ip": "203.0.113.7",
                    "hostnames": [],
                    "hostname": "",
                    "merge": False,
                    "expected_sha256": hashlib.sha256(hosts.read_bytes()).hexdigest(),
                }
                removed = host_ops_helper.apply_hosts(remove_params)
                self.assertTrue(removed["ok"], removed)
                self.assertNotIn("203.0.113.7", hosts.read_text())
                Path(removed["backup_path"]).unlink()
                backup.unlink()

    def test_hosts_final_compare_and_swap_check_rejects_a_concurrent_change(self):
        with tempfile.TemporaryDirectory() as temporary:
            hosts = Path(temporary) / "hosts"
            hosts.write_text("127.0.0.1 localhost\n", encoding="utf-8")
            expected = hashlib.sha256(hosts.read_bytes()).hexdigest()
            real_copy2 = host_ops_helper.shutil.copy2

            def mutate_before_backup(source, target, *args, **kwargs):
                hosts.write_text("127.0.0.1 changed\n", encoding="utf-8")
                return real_copy2(source, target, *args, **kwargs)

            with mock.patch.object(host_ops_helper, "HOSTS_PATH", hosts), mock.patch.object(
                host_ops_helper.shutil, "copy2", side_effect=mutate_before_backup
            ):
                with self.assertRaisesRegex(host_ops_helper.HostHelperError, "changed"):
                    host_ops_helper._write_hosts(
                        ["127.0.0.1 localhost", "203.0.113.7\texample.test"],
                        expected,
                    )

            self.assertEqual(hosts.read_text(), "127.0.0.1 changed\n")
            self.assertEqual(list(Path(temporary).glob(".hosts.linux-agent.*")), [])

    def test_hosts_directory_fsync_failure_restores_the_previous_content(self):
        with tempfile.TemporaryDirectory() as temporary:
            hosts = Path(temporary) / "hosts"
            hosts.write_text("127.0.0.1 localhost\n", encoding="utf-8")
            expected = hashlib.sha256(hosts.read_bytes()).hexdigest()
            real_fsync = host_ops_helper.os.fsync
            calls = 0

            def fail_first_directory_fsync(descriptor):
                nonlocal calls
                calls += 1
                if calls == 2:  # temporary file fsync succeeds; directory fsync fails
                    raise OSError("injected directory fsync failure")
                return real_fsync(descriptor)

            with mock.patch.object(host_ops_helper, "HOSTS_PATH", hosts), mock.patch.object(
                host_ops_helper.os, "fsync", side_effect=fail_first_directory_fsync
            ):
                with self.assertRaisesRegex(host_ops_helper.HostHelperError, "restored"):
                    host_ops_helper._write_hosts(
                        ["127.0.0.1 localhost", "203.0.113.7\texample.test"],
                        expected,
                    )

            self.assertEqual(hosts.read_text(), "127.0.0.1 localhost\n")
            self.assertEqual(len(list(Path(temporary).glob("hosts.linux-agent.bak.*"))), 1)

    def test_hosts_replace_failure_leaves_target_unchanged_and_cleans_staging(self):
        with tempfile.TemporaryDirectory() as temporary:
            hosts = Path(temporary) / "hosts"
            hosts.write_text("127.0.0.1 localhost\n", encoding="utf-8")
            expected = hashlib.sha256(hosts.read_bytes()).hexdigest()
            with mock.patch.object(host_ops_helper, "HOSTS_PATH", hosts), mock.patch.object(
                host_ops_helper.os, "replace", side_effect=OSError("injected replace failure")
            ):
                with self.assertRaises(OSError):
                    host_ops_helper._write_hosts(
                        ["127.0.0.1 localhost", "203.0.113.7\texample.test"],
                        expected,
                    )

            self.assertEqual(hosts.read_text(), "127.0.0.1 localhost\n")
            self.assertEqual(list(Path(temporary).glob(".hosts.linux-agent.*")), [])


class PolicyHelperTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.release = Path(self.temp.name) / "release"
        self.defaults = self.release / "policies"
        self.overlay = Path(self.temp.name) / "data" / "policies"
        self.config = Path(self.temp.name) / "data" / "config" / "config.json"
        self.defaults.mkdir(parents=True)
        self.overlay.mkdir(parents=True)
        self.config.parent.mkdir(parents=True)
        (self.defaults / "registered.json").write_text("{}\n", encoding="utf-8")
        self.config.write_text(
            '{"web":{"sensitive_edits_enabled":true},"command_guard":{"enabled":true}}\n',
            encoding="utf-8",
        )
        self.environment = {
            "LINUX_AGENT_RELEASE_ROOT": str(self.release),
            "LINUX_AGENT_POLICY_DEFAULT_ROOT": str(self.defaults),
            "LINUX_AGENT_POLICY_OVERLAY_ROOT": str(self.overlay),
            "LINUX_AGENT_CONFIG_PATH": str(self.config),
        }

    def tearDown(self):
        self.temp.cleanup()

    def test_policy_write_rejects_unregistered_paths_and_disabled_gate(self):
        with mock.patch.dict(os.environ, self.environment, clear=False):
            with self.assertRaises(policy_helper.PolicyHelperError):
                policy_helper._write_policy({"path": "../other.json", "content": "{}"})
            self.config.write_text(
                '{"web":{"sensitive_edits_enabled":false}}\n',
                encoding="utf-8",
            )
            with mock.patch.object(policy_helper, "_run_validator") as validate, mock.patch.object(
                policy_helper,
                "_atomic_write",
            ) as write:
                result = policy_helper._write_policy(
                    {"path": "registered.json", "content": '{"enabled":true}'}
                )

        self.assertEqual(result["status"], "sensitive_edits_disabled")
        validate.assert_not_called()
        write.assert_not_called()

    def test_policy_helper_fails_closed_for_malformed_web_configuration(self):
        with mock.patch.dict(os.environ, self.environment, clear=False):
            for value in (None, "malformed", []):
                with self.subTest(value=value):
                    self.config.write_text(
                        json.dumps({"web": value}) + "\n",
                        encoding="utf-8",
                    )
                    self.assertFalse(
                        policy_helper._sensitive_edits_enabled(self.config)
                    )
            for document in (
                '{"web":{"sensitive_edits_enabled":true},"value":NaN}\n',
                '{"web":{"sensitive_edits_enabled":true,"sensitive_edits_enabled":false}}\n',
            ):
                with self.subTest(document=document):
                    self.config.write_text(document, encoding="utf-8")
                    self.assertFalse(
                        policy_helper._sensitive_edits_enabled(self.config)
                    )

    def test_policy_helper_rejects_overlay_and_config_symlinks_without_resolving_them(self):
        outside = Path(self.temp.name) / "outside"
        outside.mkdir()
        linked_overlay = Path(self.temp.name) / "linked-overlay"
        linked_config = Path(self.temp.name) / "linked-config.json"
        outside_config = outside / "config.json"
        outside_config.write_text(
            '{"web":{"sensitive_edits_enabled":true}}\n',
            encoding="utf-8",
        )
        linked_overlay.symlink_to(outside, target_is_directory=True)
        linked_config.symlink_to(outside_config)
        environment = {
            **self.environment,
            "LINUX_AGENT_POLICY_OVERLAY_ROOT": str(linked_overlay),
            "LINUX_AGENT_CONFIG_PATH": str(linked_config),
        }

        with mock.patch.dict(os.environ, environment, clear=False):
            with self.assertRaises(policy_helper.PolicyHelperError):
                policy_helper._write_policy(
                    {"path": "registered.json", "content": "{}"}
                )
            with self.assertRaises(policy_helper.PolicyHelperError):
                policy_helper._set_command_guard({"enabled": False})

        self.assertTrue(linked_overlay.is_symlink())
        self.assertTrue(linked_config.is_symlink())
        self.assertTrue(json.loads(outside_config.read_text())["web"]["sensitive_edits_enabled"])

    def test_policy_atomic_write_restores_existing_target_after_directory_fsync_failure(self):
        target = self.overlay / "registered.json"
        target.write_text('{"old":true}\n', encoding="utf-8")
        real_fsync_directory = policy_helper._fsync_directory
        calls = 0

        def fail_after_replace(path):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise OSError("injected policy directory fsync failure")
            return real_fsync_directory(path)

        with mock.patch.object(
            policy_helper,
            "_fsync_directory",
            side_effect=fail_after_replace,
        ):
            with self.assertRaises(OSError):
                policy_helper._atomic_write(target, '{"new":true}\n', 0o640)

        self.assertEqual(target.read_text(encoding="utf-8"), '{"old":true}\n')
        self.assertEqual(
            list(self.overlay.glob(".registered.json.rollback.*.tmp")),
            [],
        )

    def test_policy_atomic_write_removes_new_target_when_persistence_fails(self):
        target = self.overlay / "new.json"
        real_fsync_directory = policy_helper._fsync_directory
        calls = 0

        def fail_after_replace(path):
            nonlocal calls
            calls += 1
            if calls == 1:
                raise OSError("injected policy directory fsync failure")
            return real_fsync_directory(path)

        with mock.patch.object(
            policy_helper,
            "_fsync_directory",
            side_effect=fail_after_replace,
        ):
            with self.assertRaises(OSError):
                policy_helper._atomic_write(target, '{"new":true}\n', 0o640)

        self.assertFalse(target.exists())

    def test_policy_atomic_write_keeps_recovery_backup_when_rollback_fails(self):
        target = self.overlay / "registered.json"
        target.write_text('{"old":true}\n', encoding="utf-8")
        real_fsync_directory = policy_helper._fsync_directory
        calls = 0

        def fail_after_replace(path):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise OSError("injected policy directory fsync failure")
            return real_fsync_directory(path)

        with mock.patch.object(
            policy_helper,
            "_fsync_directory",
            side_effect=fail_after_replace,
        ), mock.patch.object(
            policy_helper,
            "_restore_snapshot",
            side_effect=OSError("injected rollback failure"),
        ):
            with self.assertRaisesRegex(
                policy_helper.PolicyHelperError,
                "recovery backup",
            ):
                policy_helper._atomic_write(target, '{"new":true}\n', 0o640)

        backups = list(self.overlay.glob(".registered.json.previous.*.tmp"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_text(encoding="utf-8"), '{"old":true}\n')
        self.assertEqual(target.read_text(encoding="utf-8"), '{"new":true}\n')

    def test_policy_atomic_write_reports_cleanup_warning_after_durable_replace(self):
        target = self.overlay / "registered.json"
        target.write_text('{"old":true}\n', encoding="utf-8")
        real_unlink = Path.unlink

        def fail_backup_cleanup(path, *args, **kwargs):
            if path.name.startswith(".registered.json.previous."):
                raise OSError("injected backup cleanup failure")
            return real_unlink(path, *args, **kwargs)

        with mock.patch.object(Path, "unlink", fail_backup_cleanup):
            warning = policy_helper._atomic_write(
                target,
                '{"new":true}\n',
                0o640,
            )

        self.assertEqual(warning, "policy_cleanup_pending")
        self.assertEqual(target.read_text(encoding="utf-8"), '{"new":true}\n')
        backups = list(self.overlay.glob(".registered.json.previous.*.tmp"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_text(encoding="utf-8"), '{"old":true}\n')

    def test_policy_write_and_guard_return_cleanup_warning(self):
        with mock.patch.dict(os.environ, self.environment, clear=False), mock.patch.object(
            policy_helper,
            "_run_validator",
        ), mock.patch.object(
            policy_helper,
            "_atomic_write",
            return_value="policy_cleanup_pending",
        ):
            policy_result = policy_helper._write_policy(
                {"path": "registered.json", "content": '{"enabled":true}'}
            )
            guard_result = policy_helper._set_command_guard({"enabled": False})

        self.assertTrue(policy_result["ok"])
        self.assertEqual(policy_result["warning"], "policy_cleanup_pending")
        self.assertTrue(guard_result["ok"])
        self.assertEqual(guard_result["warning"], "policy_cleanup_pending")

    def test_policy_write_rechecks_gate_inside_final_atomic_replace(self):
        original_atomic_write = policy_helper._atomic_write

        def disable_after_validation(target, content, mode, **kwargs):
            self.config.write_text(
                '{"web":{"sensitive_edits_enabled":false}}\n',
                encoding="utf-8",
            )
            return original_atomic_write(target, content, mode, **kwargs)

        with mock.patch.dict(os.environ, self.environment, clear=False), mock.patch.object(
            policy_helper,
            "_run_validator",
        ), mock.patch.object(
            policy_helper,
            "_atomic_write",
            side_effect=disable_after_validation,
        ):
            result = policy_helper._write_policy(
                {"path": "registered.json", "content": '{"enabled":true}'}
            )

        self.assertFalse(result["ok"])
        self.assertEqual(result["status"], "sensitive_edits_disabled")
        self.assertFalse((self.overlay / "registered.json").exists())
        self.assertEqual(list(self.overlay.glob(".*.tmp")), [])

    def test_command_guard_preserves_other_config_fields_under_shared_lock(self):
        with mock.patch.dict(os.environ, self.environment, clear=False):
            result = policy_helper._set_command_guard({"enabled": False})

        stored = json.loads(self.config.read_text(encoding="utf-8"))
        self.assertTrue(result["ok"])
        self.assertFalse(stored["command_guard"]["enabled"])
        self.assertTrue(stored["web"]["sensitive_edits_enabled"])
        self.assertEqual(self.config.stat().st_mode & 0o777, 0o600)
        self.assertTrue(self.config.with_name(".config.json.lock").is_file())


if __name__ == "__main__":
    unittest.main()
