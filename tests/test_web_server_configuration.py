#!/usr/bin/env python3

import os
import sys
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))
sys.path.insert(0, str(ROOT / "web"))

# Importing the server initializes authentication. Keep that initialization
# independent from untracked runtime state in a source checkout.
with mock.patch.dict(os.environ, {"LINUX_AGENT_WEB_TOKEN": "unit-test-token"}):
    import server  # noqa: E402


class ServerConfigurationTests(unittest.TestCase):
    @staticmethod
    def database_registry():
        return server.SkillWebRegistry(
            server.SkillService(ROOT / "skills"),
            remote_mode=True,
            managed_execution=False,
        )

    def test_session_restore_and_leave_destroy_database_credentials(self):
        registry = self.database_registry()
        store = registry.components["database"]["instance"].secret_store
        self.addCleanup(store.clear)
        with mock.patch.object(server, "SKILL_WEB_COMPONENTS", registry), mock.patch.object(
            server, "count_active_jobs", return_value=0
        ), mock.patch.object(
            server,
            "SESSION_STORE",
        ) as sessions:
            sessions.read_persisted_turns.return_value = []
            sessions.restore.return_value = {
                "ok": True,
                "session": {"session_id": "session_web_restored"},
                "turns": [],
            }
            restored_reference = store.put(
                "database-user",
                "database-password",
                {"mode": "remote"},
            )
            restored = server.restore_web_agent_session("session_web_restored")
            self.assertTrue(restored["ok"])
            with self.assertRaises(ValueError):
                store.consume(restored_reference)

            sessions.leave.return_value = {"ok": True, "status": "left"}
            leave_reference = store.put(
                "database-user",
                "database-password",
                {"mode": "remote"},
            )
            left = server.leave_web_agent_session()
            self.assertTrue(left["ok"])
            with self.assertRaises(ValueError):
                store.consume(leave_reference)

    def test_audit_restore_source_rejects_broken_integrity(self):
        audit_result = {
            "ok": True,
            "schema_version": server.DOMAIN_CONTRACT.schema_version,
            "protocol_version": server.DOMAIN_CONTRACT.protocol_version,
            "status": "read",
            "session_id": "session_web_broken",
            "report": "broken",
            "integrity": {
                "ok": False,
                "status": "integrity_broken",
                "breaks": [{"line": 2, "reason": "hash_mismatch"}],
            },
            "integrity_ok": False,
            "events": [],
        }
        with mock.patch.object(server, "run_agent_api", return_value=audit_result):
            result = server.audit_restore_source_error(
                "session_web_broken",
                request_id="request-audit-restore",
            )

        self.assertFalse(result["ok"])
        self.assertEqual("audit_integrity_broken", result["code"])
        self.assertEqual(
            [{"line": 2, "reason": "hash_mismatch"}],
            result["details"]["breaks"],
        )

    def test_audit_read_does_not_attach_timeline_when_integrity_is_broken(self):
        audit_result = {
            "ok": True,
            "schema_version": server.DOMAIN_CONTRACT.schema_version,
            "protocol_version": server.DOMAIN_CONTRACT.protocol_version,
            "status": "read",
            "session_id": "session_web_broken",
            "report": "broken",
            "integrity": {"ok": False, "status": "integrity_broken", "breaks": []},
            "integrity_ok": False,
            "events": [],
        }
        handler = mock.Mock(request_id="request-audit-read")
        with mock.patch.object(
            server.SKILL_WEB_COMPONENTS,
            "handle_web_action",
            return_value=None,
        ), mock.patch.object(
            server,
            "run_agent_api",
            return_value=audit_result,
        ), mock.patch.object(
            server.SESSION_STORE,
            "read_persisted_turns",
        ) as read_turns, mock.patch.object(server, "json_response") as respond:
            server.Handler.handle_api_post(
                handler,
                "/api/audit/read",
                {"session_id": "session_web_broken"},
            )

        response = respond.call_args.args[2]
        self.assertIsNone(response["web_timeline"])
        self.assertEqual(
            "audit_integrity_broken",
            response["timeline_unavailable_reason"],
        )
        read_turns.assert_not_called()

    def test_policy_list_failure_returns_structured_error(self):
        handler = mock.Mock(request_id="request-policy-list")
        with mock.patch.object(
            server.SKILL_WEB_COMPONENTS,
            "handle_web_action",
            return_value=None,
        ), mock.patch.object(
            server,
            "list_policy_files",
            side_effect=ValueError("policy overlay is invalid"),
        ), mock.patch.object(server, "json_response") as respond:
            server.Handler.handle_api_get(handler, "/api/policies")

        status, response = respond.call_args.args[1:]
        self.assertEqual(500, status)
        self.assertFalse(response["ok"])
        self.assertEqual("read_failed", response["code"])
        self.assertEqual("request-policy-list", response["request_id"])

    def test_config_update_returns_durable_cleanup_warning(self):
        with mock.patch.object(server, "CONFIG_STORE") as store, mock.patch.object(
            server,
            "config_public_state",
            return_value={"ok": True, "status": "read", "config": {}},
        ):
            store.update_with_warning.return_value = (
                {"web": {"metrics_enabled": False}},
                "config_cleanup_pending",
            )
            result = server.update_config_values({"web.metrics_enabled": False})

        self.assertTrue(result["ok"])
        self.assertEqual("updated", result["status"])
        self.assertEqual("config_cleanup_pending", result["warning"])

    def test_mcp_continuation_restores_trusted_source_job_state(self):
        source_job_id = "c" * 32
        source = {
            "resource": "work",
            "action": "run",
            "payload": {"input": "trusted original input"},
            "result": {
                "status": "awaiting_mcp_input",
                "response": {"response_type": "work_plan"},
                "context": {"topic": "trusted"},
                "execution_state": {"status": "awaiting_mcp_input"},
            },
        }
        attacker_payload = {
            "mcp_source_job_id": source_job_id,
            "input": "replaced input",
            "response": {"attacker": True},
            "execution_state": {"attacker": True},
            "mcp_input_responses": {"email": {"action": "decline"}},
        }
        with mock.patch.object(server, "read_job", return_value=source):
            prepared = server.prepare_mcp_work_job_payload("work", "run", attacker_payload)

        self.assertEqual("trusted original input", prepared["input"])
        self.assertEqual(source["result"]["response"], prepared["response"])
        self.assertEqual(source["result"]["execution_state"], prepared["execution_state"])
        self.assertEqual(source_job_id, prepared["mcp_flow_id"])
        self.assertEqual(attacker_payload["mcp_input_responses"], prepared["mcp_input_responses"])
        self.assertNotIn("mcp_source_job_id", prepared)

    def test_mcp_continuation_rejects_unknown_or_completed_source_job(self):
        source_job_id = "d" * 32
        with mock.patch.object(server, "read_job", return_value=None):
            with self.assertRaises(server.McpInputJobError):
                server.prepare_mcp_work_job_payload(
                    "work", "run", {"mcp_source_job_id": source_job_id}
                )
        completed = {
            "resource": "work",
            "action": "run",
            "payload": {"input": "done"},
            "result": {"status": "executed", "execution_state": {}},
        }
        with mock.patch.object(server, "read_job", return_value=completed):
            with self.assertRaises(server.McpInputJobError):
                server.prepare_mcp_work_job_payload(
                    "work", "run", {"mcp_source_job_id": source_job_id}
                )

    def test_config_write_error_uses_structured_contract(self):
        with mock.patch.object(server, "CONFIG_STORE") as store:
            store.update_with_warning.side_effect = OSError("injected persistence failure")
            result = server.update_config_values({"web.metrics_enabled": False})

        self.assertFalse(result["ok"])
        self.assertEqual("config_write_failed", result["status"])
        self.assertEqual("config_write_failed", result["code"])
        self.assertTrue(result["retryable"])

    def test_approval_scopes_are_discovered_from_skill_contracts(self):
        config = {
            "approvals": {
                "auto": {
                    "configured_scope": True,
                    "invalid-scope": True,
                    "wrong_type": "true",
                }
            }
        }
        packages = [
            {
                "state": "installed",
                "tools": [{"approval_scope": "package_scope"}],
            },
            {
                "state": "invalid",
                "tools": [{"approval_scope": "ignored_scope"}],
            },
        ]
        with mock.patch.object(server, "read_config", return_value=config), mock.patch.object(
            server.SKILL_SERVICE,
            "list_packages",
            return_value=packages,
        ), mock.patch.object(server, "REMOTE_MODE", False):
            result = server.config_public_state()

        approvals = result["config"]["approvals"]
        self.assertTrue(approvals["auto"]["configured_scope"])
        self.assertFalse(approvals["auto"]["package_scope"])
        self.assertIn("skill_readonly", approvals["scope_catalog"])
        self.assertNotIn("invalid-scope", approvals["scope_catalog"])
        self.assertNotIn("wrong_type", approvals["auto"])
        self.assertNotIn("ignored_scope", approvals["scope_catalog"])

    def test_database_job_uses_job_id_as_query_id(self):
        job_id = "a" * 32
        state = {"status": "queued", "phase": "queued"}
        registry = self.database_registry()

        def update(_job_id, mutator):
            self.assertEqual(job_id, _job_id)
            mutator(state)
            return dict(state)

        result = {
            "ok": True,
            "status": "checked",
            "timeline": [],
            "approval_card": None,
            "output_blocks": [],
        }
        with mock.patch.object(server, "SKILL_WEB_COMPONENTS", registry), mock.patch.object(
            server, "update_job", side_effect=update
        ), mock.patch.object(
            registry,
            "run_job",
            return_value=result,
        ) as inspect, mock.patch.object(
            server.SESSION_STORE,
            "complete_job",
            return_value={"audit_state": "complete"},
        ), mock.patch.object(server, "record_job_completion"):
            server.run_job.__wrapped__(
                job_id,
                {},
                "database",
                "health",
                {"profile_id": "primary"},
                mock.Mock(job_id=job_id),
            )

        inspect.assert_called_once_with(
            "database", "health", {"profile_id": "primary"}, job_id
        )
        self.assertEqual("succeeded", state["status"])

    def test_database_cancel_routes_to_database_service(self):
        job_id = "b" * 32
        registry = self.database_registry()
        running = {
            "job_id": job_id,
            "resource": "database",
            "action": "health",
            "status": "running",
            "phase": "executing",
        }
        cancelled = {
            **running,
            "status": "cancelled",
            "phase": "terminal",
            "cancel_requested_at": "2026-07-29T00:00:00Z",
        }
        with mock.patch.object(server, "SKILL_WEB_COMPONENTS", registry), mock.patch.object(
            server,
            "read_job",
            side_effect=[running, cancelled],
        ), mock.patch.object(
            server.JOB_STORE,
            "update",
            return_value={**running, "cancel_requested_at": "2026-07-29T00:00:00Z"},
        ), mock.patch.object(
            registry,
            "cancel_job",
            return_value={"ok": True, "status": "cancel_requested"},
        ) as cancel_query, mock.patch.object(server, "execution_service") as execution:
            result = server.cancel_job(job_id)

        self.assertTrue(result["ok"])
        self.assertEqual("cancelled", result["status"])
        cancel_query.assert_called_once_with("database", job_id)
        execution.assert_not_called()


if __name__ == "__main__":
    unittest.main()
