#!/usr/bin/env python3

import sys
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))
sys.path.insert(0, str(ROOT / "web"))

import server  # noqa: E402


class ServerConfigurationTests(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
