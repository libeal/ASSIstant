#!/usr/bin/env python3

import json
import os
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "web"))

from configuration import (  # noqa: E402
    ConfigStore,
    normalize_config_value,
    provider_failover_api_key_envs,
    validate_config_relationships,
    write_nested_config_value,
)


class ConfigStoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.config_path = Path(self.temp.name) / "config" / "config.json"
        self.store = ConfigStore(self.config_path)

    def tearDown(self):
        self.temp.cleanup()

    def test_concurrent_updates_are_serialized_without_lost_fields(self):
        self.store.write({"updates": {}})
        failures = []
        start = threading.Barrier(33)

        def worker(index):
            try:
                start.wait()

                def mutate(config):
                    updates = config.setdefault("updates", {})
                    time.sleep(0.001)
                    updates[str(index)] = index

                self.store.update(mutate)
            except Exception as exc:  # pragma: no cover - asserted below
                failures.append(exc)

        threads = [threading.Thread(target=worker, args=(index,)) for index in range(32)]
        for thread in threads:
            thread.start()
        start.wait()
        for thread in threads:
            thread.join(timeout=10)

        self.assertEqual([], failures)
        self.assertFalse(any(thread.is_alive() for thread in threads))
        self.assertEqual(32, len(self.store.read()["updates"]))
        self.assertEqual(0o600, self.config_path.stat().st_mode & 0o777)
        self.assertEqual([], list(self.config_path.parent.glob(".config.json.*.tmp")))

    def test_update_preserves_valid_json_when_mutator_raises(self):
        original = {"safe": True}
        self.store.write(original)

        def fail(_config):
            raise RuntimeError("stop")

        with self.assertRaisesRegex(RuntimeError, "stop"):
            self.store.update(fail)

        self.assertEqual(original, json.loads(self.config_path.read_text(encoding="utf-8")))

    def test_symbolic_link_target_is_rejected(self):
        self.config_path.parent.mkdir(parents=True)
        outside = Path(self.temp.name) / "outside.json"
        outside.write_text('{"outside":true}\n', encoding="utf-8")
        os.symlink(outside, self.config_path)

        with self.assertRaisesRegex(OSError, "symbolic link"):
            self.store.write({"outside": False})

        self.assertEqual({"outside": True}, json.loads(outside.read_text(encoding="utf-8")))

    def test_normalization_and_nested_updates_stay_in_configuration_module(self):
        value, error = normalize_config_value("web.max_active_jobs", "8")
        self.assertEqual((8, ""), (value, error))
        self.assertEqual((None, "web.max_active_jobs must be integer."), normalize_config_value("web.max_active_jobs", True))
        config = {}
        write_nested_config_value(config, "web.max_active_jobs", value)
        self.assertEqual({"web": {"max_active_jobs": 8}}, config)

        attempts, error = normalize_config_value("provider_resilience.max_attempts", 5)
        self.assertEqual((5, ""), (attempts, error))
        self.assertIsNotNone(normalize_config_value("provider_resilience.max_attempts", 6)[1])
        resilience = {
            "provider_resilience": {
                "backoff_initial_ms": 1000,
                "backoff_max_ms": 500,
            }
        }
        self.assertIn("backoff_max_ms", validate_config_relationships(resilience))
        resilience["provider_resilience"]["backoff_max_ms"] = 1000
        self.assertEqual("", validate_config_relationships(resilience))

        failover_config = {
            "provider_resilience": {
                "failover": [
                    {"provider": "one", "api_key_env": "BACKUP_ONE_API_KEY"},
                    {"provider": "two", "api_key_env": "PATH"},
                    {"provider": "three", "api_key_env": "LINUX_AGENT_API_KEY"},
                    {"provider": "four", "api_key_env": "BACKUP_ONE_API_KEY"},
                    {"provider": "five", "reuse_primary_api_key": True, "api_key_env": "IGNORED_API_KEY"},
                ]
            }
        }
        self.assertEqual(["BACKUP_ONE_API_KEY"], provider_failover_api_key_envs(failover_config))


if __name__ == "__main__":
    unittest.main()
