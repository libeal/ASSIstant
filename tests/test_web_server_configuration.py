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
