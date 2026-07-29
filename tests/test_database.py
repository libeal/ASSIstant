#!/usr/bin/env python3

import json
import importlib.util
import os
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))
sys.path.insert(0, str(ROOT / "skills" / "database-inspect" / "scripts"))
sys.path.insert(0, str(ROOT / "web"))

import database_inspector  # noqa: E402
import database_profiles  # noqa: E402
from helper_protocol import ProtocolError, build_request  # noqa: E402
from jobs import JobStore  # noqa: E402
from sessions import SessionStore, append_turn  # noqa: E402


def _load_web_database():
    path = ROOT / "skills" / "database-inspect" / "assets" / "web" / "database.py"
    spec = importlib.util.spec_from_file_location("database_skill_web_test", path)
    if spec is None or spec.loader is None:
        raise RuntimeError("database-inspect Web backend cannot be loaded")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


web_database = _load_web_database()


def profile(profile_id="primary", **overrides):
    value = {
        "schema_version": 1,
        "id": profile_id,
        "engine": "postgresql",
        "endpoint": "127.0.0.1",
        "port": 5432,
        "database": "app",
        "tls": "disable",
        "credential_mode": "temporary",
    }
    value.update(overrides)
    return value


class SecretStoreTest(unittest.TestCase):
    def test_store_is_bounded_expires_and_consumes_once(self):
        now = [100.0]
        store = web_database.WorkspaceSecretStore(
            maximum=1,
            idle_ttl=10,
            absolute_ttl=20,
            clock=lambda: now[0],
        )
        reference = store.put("operator", "secret", {"mode": "managed"})
        with self.assertRaisesRegex(web_database.SecretStoreError, "capacity"):
            store.put("other", "secret", {})
        self.assertEqual(("operator", "secret"), store.consume(reference)[:2])
        with self.assertRaises(web_database.SecretStoreError):
            store.consume(reference)

        expired = store.put("operator", "secret", {})
        now[0] = 121.0
        with self.assertRaises(web_database.SecretStoreError) as context:
            store.consume(expired)
        self.assertEqual("credential_expired", context.exception.code)

    def test_public_metadata_masks_username_and_never_contains_profile(self):
        store = web_database.WorkspaceSecretStore()
        service = web_database.DatabaseService(
            store,
            remote_mode=True,
            managed_execution=False,
            helper_socket="/missing",
        )
        result = service.create_credential(
            {
                "engine": "postgresql",
                "endpoint": "127.0.0.1",
                "port": 5432,
                "database": "app",
                "tls": "disable",
                "username": "database-owner",
                "password": "top-secret",
                "acknowledge_authorized_scope": True,
            }
        )
        serialized = json.dumps(result, sort_keys=True)
        self.assertNotIn("top-secret", serialized)
        self.assertNotIn("database-owner", serialized)
        self.assertNotIn('"profile"', serialized)
        listed = json.dumps(service.credentials(), sort_keys=True)
        self.assertNotIn("top-secret", listed)
        self.assertNotIn("database-owner", listed)

    def test_remote_endpoint_requires_scope_and_verified_non_loopback_tls(self):
        service = web_database.DatabaseService(
            web_database.WorkspaceSecretStore(),
            remote_mode=True,
            managed_execution=False,
            helper_socket="/missing",
        )
        request = {
            "engine": "mysql",
            "endpoint": "192.0.2.10",
            "port": 3306,
            "database": "app",
            "tls": "require",
            "username": "reader",
            "password": "secret",
            "acknowledge_authorized_scope": True,
        }
        with self.assertRaisesRegex(web_database.SecretStoreError, "verify-full"):
            service.create_credential(request)
        with self.assertRaisesRegex(web_database.SecretStoreError, "acknowledgement"):
            service.create_credential({**request, "tls": "verify-full", "acknowledge_authorized_scope": False})
        with self.assertRaisesRegex(web_database.SecretStoreError, "exact IP"):
            service.create_credential({**request, "endpoint": "db.example", "tls": "verify-full"})

    def test_remote_fixed_query_consumes_secret_without_persisting_it(self):
        store = web_database.WorkspaceSecretStore()
        service = web_database.DatabaseService(
            store,
            remote_mode=True,
            managed_execution=False,
            helper_socket="/missing",
        )
        created = service.create_credential(
            {
                "engine": "postgresql",
                "socket": "/run/postgresql",
                "database": "app",
                "tls": "disable",
                "username": "reader",
                "password": "secret",
                "acknowledge_authorized_scope": True,
            }
        )
        payload = service.sanitize_job_payload(
            "health",
            {"profile_id": "", "credential_ref": created["credential_ref"]},
        )
        self.assertNotIn("secret", json.dumps(payload))
        with mock.patch.object(web_database, "run_fixed_query", return_value={"rows": [["1"]]}) as runner:
            result = service.inspect("health", payload, query_id="b" * 32)
        self.assertTrue(result["ok"])
        self.assertEqual("reader", runner.call_args.args[1])
        self.assertEqual("secret", runner.call_args.args[2])
        self.assertEqual("b" * 32, runner.call_args.kwargs["query_id"])
        self.assertIs(service.query_registry, runner.call_args.kwargs["registry"])
        retry = service.inspect("health", payload)
        self.assertFalse(retry["ok"])
        self.assertEqual("credential_unavailable", retry["code"])

    def test_managed_query_transfers_credential_in_one_sealed_memfd(self):
        username = "database_owner_for_fd_test"
        password = "managed-password-for-fd-test"
        store = web_database.WorkspaceSecretStore()
        service = web_database.DatabaseService(
            store,
            remote_mode=False,
            managed_execution=True,
            helper_socket="/run/linux-agent/database-inspector.sock",
        )
        reference = store.put(
            username,
            password,
            {"mode": "managed", "profile_id": "primary"},
        )
        payload = service.sanitize_job_payload(
            "health",
            {"profile_id": "primary", "credential_ref": reference},
        )
        observed = {}

        def inspect_request(_socket, request, *, descriptor=None):
            observed["request"] = request
            observed["descriptor"] = descriptor
            observed["credential"] = database_inspector._credential_from_memfd(descriptor)
            return {"ok": True, "status": "checked", "rows": [["1"]]}

        with mock.patch.object(web_database.Path, "is_socket", return_value=True), mock.patch.object(
            web_database,
            "client_request",
            side_effect=inspect_request,
        ):
            result = service.inspect("health", payload, query_id="b" * 32)

        self.assertTrue(result["ok"])
        self.assertEqual((username, password), observed["credential"])
        request_json = json.dumps(observed["request"], sort_keys=True)
        self.assertNotIn(username, request_json)
        self.assertNotIn(password, request_json)
        self.assertEqual(
            {"profile_id": "primary", "credential_ref": reference},
            observed["request"]["params"],
        )
        self.assertEqual("b" * 32, observed["request"]["request_id"])
        with self.assertRaises(OSError):
            os.fstat(observed["descriptor"])

    def test_managed_cancel_targets_the_job_query_id(self):
        service = web_database.DatabaseService(
            web_database.WorkspaceSecretStore(),
            remote_mode=False,
            managed_execution=True,
            helper_socket="/run/linux-agent/database-inspector.sock",
        )
        observed = {}

        def cancel_request(_socket, request, *, descriptor=None):
            observed["request"] = request
            self.assertIsNone(descriptor)
            return {
                "ok": True,
                "status": "cancel_requested",
                "target_request_id": request["params"]["request_id"],
                "running": True,
            }

        with mock.patch.object(
            web_database.Path,
            "is_socket",
            return_value=True,
        ), mock.patch.object(
            web_database,
            "client_request",
            side_effect=cancel_request,
        ):
            response = service.cancel_query("c" * 32)

        self.assertTrue(response["ok"])
        self.assertEqual("database.cancel", observed["request"]["operation"])
        self.assertEqual({"request_id": "c" * 32}, observed["request"]["params"])
        self.assertNotEqual("c" * 32, observed["request"]["request_id"])

    def test_database_job_artifacts_never_persist_the_credential(self):
        username = "database_owner_for_persistence_test"
        password = "DATABASE_PASSWORD_MUST_NOT_PERSIST_9f4f"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            service = web_database.DatabaseService(
                web_database.WorkspaceSecretStore(),
                remote_mode=True,
                managed_execution=False,
                helper_socket="/missing",
            )
            created = service.create_credential(
                {
                    "engine": "postgresql",
                    "socket": "/run/postgresql",
                    "database": "app",
                    "tls": "disable",
                    "username": username,
                    "password": password,
                    "acknowledge_authorized_scope": True,
                }
            )
            payload = service.sanitize_job_payload(
                "health",
                {"credential_ref": created["credential_ref"]},
            )
            jobs = JobStore(root / "tmp" / "web" / "jobs.db")
            job = {
                "ok": True,
                "schema_version": 1,
                "job_id": "abc123",
                "resource": "database",
                "action": "health",
                "status": "queued",
                "version": 0,
                "created_at": "2026-07-28T00:00:00Z",
                "updated_at": "2026-07-28T00:00:00Z",
                "request_id": "request-abc123",
                "session_id": "job_abc123",
                "payload": payload,
                "result": None,
                "result_ok": None,
                "result_status": None,
            }
            jobs.create(job)
            with mock.patch.object(
                web_database,
                "run_fixed_query",
                return_value={"ok": True, "status": "checked", "rows": [["1"]]},
            ):
                result = service.inspect("health", payload)

            def publish(record):
                record["status"] = "succeeded"
                record["result"] = result
                record["result_ok"] = True
                record["result_status"] = "checked"
                return None

            jobs.update("abc123", publish)

            def audit_writer(path, session_id, stage, event_payload):
                append_turn(
                    path,
                    {
                        "session_id": session_id,
                        "stage": stage,
                        "payload": event_payload,
                    },
                )

            sessions = SessionStore(
                root,
                "database-test",
                lambda: {"context_turns": 4, "audit_mode": "safe_summary"},
                audit_writer,
            )
            sessions.initialize()
            context = sessions.create_job_context("abc123", "request-abc123")
            sessions.complete_job(context, "database", "", result, merge_history=False)

            retry = service.inspect("health", payload)
            self.assertFalse(retry["ok"])
            self.assertEqual("credential_unavailable", retry["code"])
            artifacts = b"\n".join(
                path.read_bytes() for path in root.rglob("*") if path.is_file()
            )
            self.assertIn(created["credential_ref"].encode("ascii"), artifacts)
            self.assertNotIn(password.encode("utf-8"), artifacts)
            self.assertNotIn(username.encode("utf-8"), artifacts)


class DatabaseProfileTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name) / "profiles"
        self.egress = Path(self.temporary.name) / "systemd" / "20-egress.conf"
        self.patchers = [
            mock.patch.object(database_profiles, "PROFILE_ROOT", self.root),
            mock.patch.object(database_profiles, "EGRESS_DROPIN", self.egress),
            mock.patch.object(database_profiles, "_ensure_root"),
            mock.patch.object(database_profiles, "_helper_gid", return_value=os.getgid()),
            mock.patch.object(database_profiles.os, "chown"),
            mock.patch.object(database_profiles.os, "fchown"),
        ]
        for patcher in self.patchers:
            patcher.start()

    def tearDown(self):
        for patcher in reversed(self.patchers):
            patcher.stop()
        self.temporary.cleanup()

    def write_existing(self, value):
        self.root.mkdir(parents=True, exist_ok=True)
        path = self.root / f"{value['id']}.json"
        path.write_text(json.dumps(value, sort_keys=True) + "\n", encoding="utf-8")
        path.chmod(0o640)
        return path

    def test_profile_validation_rejects_noncanonical_socket_and_weak_remote_tls(self):
        with self.assertRaisesRegex(database_profiles.DatabaseProfileError, "schema_version"):
            database_profiles.validate_profile(profile(schema_version=True))
        with self.assertRaisesRegex(database_profiles.DatabaseProfileError, "canonical"):
            database_profiles.validate_profile(
                profile(endpoint=None, socket="/run//postgresql", tls="disable")
            )
        with self.assertRaisesRegex(database_profiles.DatabaseProfileError, "verify-full"):
            database_profiles.validate_profile(
                profile(endpoint="192.0.2.5", tls="require")
            )

    def test_profile_validation_rejects_connection_strings_and_client_options(self):
        invalid_names = (
            "--execute=SELECT 1",
            "hostaddr=192.0.2.10 sslmode=disable",
            "postgresql://127.0.0.1/app",
            "mysql://127.0.0.1/app",
        )
        for database in invalid_names:
            with self.subTest(database=database), self.assertRaisesRegex(
                database_profiles.DatabaseProfileError,
                "simple name",
            ):
                database_profiles.validate_profile(profile(database=database))

    def test_install_rolls_back_new_and_existing_profile_on_egress_failure(self):
        old = profile(database="old")
        path = self.write_existing(old)
        original = path.read_bytes()
        with mock.patch.object(
            database_profiles,
            "refresh_egress",
            side_effect=[database_profiles.DatabaseProfileError("failed"), self.egress],
        ) as refresh:
            with self.assertRaisesRegex(database_profiles.DatabaseProfileError, "was restored"):
                database_profiles.install_profile(
                    profile(database="new"),
                    activate_systemd=True,
                )
        self.assertEqual(original, path.read_bytes())
        self.assertEqual(2, refresh.call_count)
        self.assertEqual(
            [mock.call(activate_systemd=True), mock.call(activate_systemd=True)],
            refresh.call_args_list,
        )

        path.unlink()
        with mock.patch.object(
            database_profiles,
            "refresh_egress",
            side_effect=[database_profiles.DatabaseProfileError("failed"), self.egress],
        ):
            with self.assertRaises(database_profiles.DatabaseProfileError):
                database_profiles.install_profile(profile())
        self.assertFalse(path.exists())

    def test_remove_restores_profile_on_egress_failure(self):
        password = "profile-password-must-not-be-backed-up"
        path = self.write_existing(
            profile(
                credential_mode="stored",
                credentials={"username": "reader", "password": password},
            )
        )
        original = path.read_bytes()
        with mock.patch.object(
            database_profiles,
            "refresh_egress",
            side_effect=[database_profiles.DatabaseProfileError("failed"), self.egress],
        ) as refresh:
            with self.assertRaisesRegex(database_profiles.DatabaseProfileError, "was restored"):
                database_profiles.remove_profile("primary", activate_systemd=True)
        self.assertEqual(original, path.read_bytes())
        self.assertEqual([], list(self.root.glob(".*.remove.*")))
        self.assertEqual(
            [mock.call(activate_systemd=True), mock.call(activate_systemd=True)],
            refresh.call_args_list,
        )

    def test_remove_never_leaves_secret_backup_artifacts(self):
        password = "profile-password-must-disappear"
        path = self.write_existing(
            profile(
                credential_mode="stored",
                credentials={"username": "reader", "password": password},
            )
        )
        with mock.patch.object(database_profiles, "refresh_egress", return_value=self.egress):
            database_profiles.remove_profile("primary")

        self.assertFalse(path.exists())
        artifacts = b"\n".join(
            candidate.read_bytes() for candidate in self.root.rglob("*") if candidate.is_file()
        )
        self.assertNotIn(password.encode("utf-8"), artifacts)
        self.assertEqual([], list(self.root.glob(".*.remove.*")))

    def test_refresh_egress_contains_only_exact_non_loopback_addresses(self):
        profiles = [
            profile("local"),
            profile("remote4", endpoint="192.0.2.7", tls="verify-full"),
            profile("remote6", endpoint="2001:db8::7", tls="verify-full"),
        ]
        with mock.patch.object(database_profiles, "list_profiles", return_value=profiles):
            database_profiles.refresh_egress()
        content = self.egress.read_text(encoding="utf-8")
        self.assertIn("IPAddressDeny=any", content)
        self.assertIn("IPAddressAllow=localhost", content)
        self.assertIn("IPAddressAllow=192.0.2.7/32", content)
        self.assertIn("IPAddressAllow=2001:db8::7/128", content)
        self.assertNotIn("127.0.0.1/32", content)

    def test_refresh_egress_activates_systemd_when_requested(self):
        with mock.patch.object(
            database_profiles,
            "list_profiles",
            return_value=[profile()],
        ), mock.patch.object(database_profiles, "_activate_systemd_egress") as activate:
            database_profiles.refresh_egress(activate_systemd=True)
        activate.assert_called_once_with()

    def test_systemd_activation_reloads_then_restarts_the_running_helper(self):
        completed = mock.Mock(returncode=0, stderr=b"")
        with mock.patch.object(
            database_profiles,
            "_trusted_systemctl",
            return_value="/usr/bin/systemctl",
        ), mock.patch.object(
            database_profiles.subprocess,
            "run",
            return_value=completed,
        ) as run:
            database_profiles._activate_systemd_egress()

        self.assertEqual(
            [
                ["/usr/bin/systemctl", "daemon-reload"],
                [
                    "/usr/bin/systemctl",
                    "try-restart",
                    "linux-agent-database-inspector.service",
                ],
            ],
            [call.args[0] for call in run.call_args_list],
        )

    def test_profile_root_symlink_is_rejected(self):
        actual = Path(self.temporary.name) / "actual"
        actual.mkdir()
        self.root.symlink_to(actual, target_is_directory=True)
        with self.assertRaisesRegex(database_profiles.DatabaseProfileError, "symbolic link"):
            database_profiles.install_profile(profile())


class DatabaseInspectorTest(unittest.TestCase):
    def test_cli_params_reject_duplicate_keys_and_non_finite_numbers(self):
        for raw in ('{"profile_id":"a","profile_id":"b"}', '{"value":NaN}'):
            with self.subTest(raw=raw), self.assertRaises(database_inspector.DatabaseInspectorError):
                database_inspector._strict_params(raw)

    def test_postgresql_password_is_only_in_child_environment(self):
        with mock.patch.object(database_inspector, "_client", return_value="/usr/bin/psql"), mock.patch.object(
            database_inspector,
            "_run_client",
            return_value=(0, b"1\n", b""),
        ) as run:
            database_inspector._run_postgresql(profile(), "reader", "secret", "health")
        argv = run.call_args.args[0]
        self.assertNotIn("secret", argv)
        self.assertEqual("secret", run.call_args.args[2]["PGPASSWORD"])
        self.assertEqual(
            database_inspector.FIXED_SQL[("postgresql", "health")].encode(),
            run.call_args.args[1],
        )

    def test_mysql_password_is_only_in_anonymous_memfd(self):
        observed = {}

        def fake_run(argv, payload, environment, **kwargs):
            observed["argv"] = argv
            observed["env"] = environment
            descriptor = kwargs["pass_fds"][0]
            os.lseek(descriptor, 0, os.SEEK_SET)
            observed["config"] = os.read(descriptor, 4096).decode("utf-8")
            observed["input"] = payload
            return 0, b"1\n", b""

        with mock.patch.object(database_inspector, "_client", return_value="/usr/bin/mysql"), mock.patch.object(
            database_inspector,
            "_run_client",
            side_effect=fake_run,
        ):
            database_inspector._run_mysql(
                profile(engine="mysql", port=3306),
                'read"er',
                "sec\\ret#value",
                "metrics",
            )
        self.assertNotIn("sec\\ret#value", "\0".join(observed["argv"]))
        self.assertNotIn("sec\\ret#value", json.dumps(observed["env"]))
        self.assertIn('password="sec\\\\ret#value"', observed["config"])
        self.assertEqual(database_inspector.FIXED_SQL[("mysql", "metrics")].encode(), observed["input"])
        separator = observed["argv"].index("--")
        self.assertEqual("app", observed["argv"][separator + 1])
        self.assertTrue(
            all(not argument.startswith("--") for argument in observed["argv"][separator + 1 :])
        )

    def test_query_output_and_errors_redact_the_supplied_credential(self):
        username = "database_owner_for_redaction"
        password = "password-for-redaction"
        leaked = f"user={username} password={password}".encode("utf-8")
        with mock.patch.object(
            database_inspector,
            "_run_postgresql",
            return_value=(0, leaked + b"\n", b""),
        ):
            result = database_inspector.run_fixed_query(
                profile(), username, password, "health"
            )
        serialized = json.dumps(result, sort_keys=True)
        self.assertNotIn(username, serialized)
        self.assertNotIn(password, serialized)
        self.assertIn("[REDACTED]", serialized)

        with mock.patch.object(
            database_inspector,
            "_run_postgresql",
            return_value=(1, b"", leaked),
        ), self.assertRaises(database_inspector.DatabaseInspectorError) as context:
            database_inspector.run_fixed_query(profile(), username, password, "health")
        self.assertNotIn(username, str(context.exception))
        self.assertNotIn(password, str(context.exception))

    def test_health_queries_do_not_return_the_login_identity(self):
        for engine in ("postgresql", "mysql"):
            with self.subTest(engine=engine):
                self.assertNotIn(
                    "CURRENT_USER",
                    database_inspector.FIXED_SQL[(engine, "health")].upper(),
                )

    def helper_request(self, request, *, peer_error=None, descriptors=(), registry=None):
        responses = []
        connection = mock.Mock()
        with mock.patch.object(
            database_inspector,
            "require_peer_uid",
            side_effect=peer_error,
        ), mock.patch.object(
            database_inspector,
            "receive_json_with_descriptors",
            return_value=(request, descriptors),
        ), mock.patch.object(
            database_inspector,
            "send_json",
            side_effect=lambda _connection, response: responses.append(response),
        ):
            database_inspector.handle_connection(connection, os.getuid(), registry)
        self.assertEqual(1, len(responses))
        return responses[0]

    def test_helper_rejects_wrong_peer_and_unknown_operation(self):
        request = build_request("ping", {}, summary="ping")
        wrong_peer = self.helper_request(
            request,
            peer_error=ProtocolError("unexpected peer uid"),
        )
        self.assertFalse(wrong_peer["ok"])
        self.assertEqual("failed", wrong_peer["status"])
        self.assertEqual("helper_rejected", wrong_peer["code"])

        forged = build_request("database.raw-sql", {}, summary="raw")
        rejected = self.helper_request(forged)
        self.assertFalse(rejected["ok"])
        self.assertEqual("failed", rejected["status"])
        self.assertEqual("helper_rejected", rejected["code"])

    def test_helper_consumes_one_sealed_credential_fd_for_a_fixed_query(self):
        username = "database_reader"
        password = "database-password"
        descriptor = web_database._credential_memfd(username, password)
        request = build_request(
            "database.health",
            {"profile_id": "primary", "credential_ref": "a" * 32},
            summary="fixed health query",
        )
        with mock.patch.object(
            database_inspector,
            "load_profile",
            return_value=profile(),
        ), mock.patch.object(
            database_inspector,
            "run_fixed_query",
            return_value={"ok": True, "status": "checked", "rows": [["1"]]},
        ) as run:
            response = self.helper_request(request, descriptors=(descriptor,))

        self.assertTrue(response["ok"])
        self.assertEqual((profile(), username, password, "health"), run.call_args.args)
        with self.assertRaises(OSError):
            os.fstat(descriptor)

        missing = self.helper_request(request)
        self.assertFalse(missing["ok"])
        self.assertEqual("failed", missing["status"])
        self.assertEqual("credential_unavailable", missing["code"])

    def test_query_registry_cancels_active_and_pending_queries(self):
        registry = database_inspector.DatabaseQueryRegistry()
        query_id = "c" * 32
        process = mock.Mock(pid=321)
        with mock.patch.object(database_inspector, "_signal_query_process") as signal_process:
            cancellation = registry.register(query_id, process)
            self.assertTrue(registry.cancel(query_id))
        self.assertTrue(cancellation.is_set())
        signal_process.assert_called_once_with(process, database_inspector.signal.SIGTERM)
        registry.unregister(query_id, process)

        pending_id = "d" * 32
        self.assertFalse(registry.cancel(pending_id))
        with mock.patch.object(database_inspector.subprocess, "Popen") as popen:
            with self.assertRaises(database_inspector.DatabaseInspectorError) as context:
                database_inspector._run_client(
                    ["/usr/bin/psql"],
                    b"SELECT 1",
                    {},
                    query_id=pending_id,
                    registry=registry,
                )
        self.assertEqual("database_query_cancelled", context.exception.code)
        popen.assert_not_called()

    def test_duplicate_query_id_reaps_the_unregistered_client(self):
        registry = database_inspector.DatabaseQueryRegistry()
        query_id = "f" * 32
        existing = mock.Mock(pid=100)
        duplicate = mock.Mock(pid=101)
        registry.register(query_id, existing)
        with mock.patch.object(
            database_inspector.subprocess,
            "Popen",
            return_value=duplicate,
        ), mock.patch.object(
            database_inspector,
            "_terminate_query_process",
            return_value=(b"", b""),
        ) as terminate:
            with self.assertRaisesRegex(
                database_inspector.DatabaseInspectorError,
                "already active",
            ):
                database_inspector._run_client(
                    ["/usr/bin/psql"],
                    b"SELECT 1",
                    {},
                    query_id=query_id,
                    registry=registry,
                )
        terminate.assert_called_once_with(duplicate)
        self.assertIs(existing, registry.processes[query_id][0])

    def test_running_client_is_terminated_and_unregistered_on_cancel(self):
        registry = database_inspector.DatabaseQueryRegistry()
        query_id = "9" * 32
        errors = []

        def run_client():
            try:
                database_inspector._run_client(
                    [sys.executable, "-c", "import time; time.sleep(30)"],
                    b"",
                    database_inspector._base_environment(),
                    query_id=query_id,
                    registry=registry,
                )
            except Exception as exc:  # noqa: BLE001 - asserted by the test thread.
                errors.append(exc)

        thread = threading.Thread(target=run_client)
        thread.start()
        deadline = time.monotonic() + 2
        process = None
        while time.monotonic() < deadline:
            with registry.lock:
                current = registry.processes.get(query_id)
                process = current[0] if current is not None else None
            if process is not None:
                break
            time.sleep(0.01)
        if process is None:
            registry.cancel(query_id)
            thread.join(2)
            self.fail("database client did not register before the test deadline")
        self.assertTrue(registry.cancel(query_id))
        thread.join(2)

        self.assertFalse(thread.is_alive())
        self.assertEqual(1, len(errors))
        self.assertIsInstance(errors[0], database_inspector.DatabaseInspectorError)
        self.assertEqual("database_query_cancelled", errors[0].code)
        self.assertIsNotNone(process.poll())
        with registry.lock:
            self.assertNotIn(query_id, registry.processes)

    def test_query_capacity_reserves_a_worker_for_cancel_requests(self):
        request = build_request(
            "database.health",
            {"profile_id": "primary", "credential_ref": ""},
            summary="fixed health query",
        )
        capacity = mock.Mock()
        capacity.acquire.return_value = False
        responses = []
        connection = mock.Mock()
        with mock.patch.object(database_inspector, "require_peer_uid"), mock.patch.object(
            database_inspector,
            "receive_json_with_descriptors",
            return_value=(request, ()),
        ), mock.patch.object(
            database_inspector,
            "send_json",
            side_effect=lambda _connection, response: responses.append(response),
        ), mock.patch.object(database_inspector, "inspect_database") as inspect:
            database_inspector.handle_connection(
                connection,
                os.getuid(),
                database_inspector.DatabaseQueryRegistry(),
                capacity,
            )
        self.assertEqual("helper_unavailable", responses[0]["code"])
        capacity.acquire.assert_called_once_with(blocking=False)
        capacity.release.assert_not_called()
        inspect.assert_not_called()

    def test_helper_cancel_uses_the_query_registry(self):
        registry = database_inspector.DatabaseQueryRegistry()
        target_request_id = "e" * 32
        request = build_request(
            "database.cancel",
            {"request_id": target_request_id},
            summary="cancel fixed query",
        )
        response = self.helper_request(request, registry=registry)
        self.assertTrue(response["ok"])
        self.assertEqual("cancel_requested", response["status"])
        self.assertEqual(target_request_id, response["target_request_id"])
        self.assertFalse(response["running"])
        self.assertTrue(registry.consume_pending_cancellation(target_request_id))

        invalid = build_request(
            "database.cancel",
            {"request_id": "not-a-helper-request-id"},
            summary="reject invalid cancel target",
        )
        rejected = self.helper_request(invalid, registry=registry)
        self.assertFalse(rejected["ok"])
        self.assertEqual("database_query_failed", rejected["code"])


if __name__ == "__main__":
    unittest.main()
