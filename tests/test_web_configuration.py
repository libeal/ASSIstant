#!/usr/bin/env python3

import json
import fcntl
import os
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "web"))

from configuration import (  # noqa: E402
    CONFIG_CLEANUP_WARNING,
    CONFIG_READONLY_FIELDS,
    ConfigStore,
    normalize_config_value,
    provider_failover_api_key_envs,
    sensitive_edits_enabled,
    validate_config_relationships,
    write_nested_config_value,
)
import configuration as configuration_module  # noqa: E402


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

    def test_runtime_barrier_blocks_config_transactions_during_restore(self):
        runtime_lock = Path(self.temp.name) / ".runtime.lock"
        runtime_lock.touch(mode=0o600)
        store = ConfigStore(self.config_path, runtime_lock)
        descriptor = os.open(runtime_lock, os.O_RDONLY)
        completed = threading.Event()
        failures = []

        def write_config():
            try:
                store.write({"version": 2})
            except Exception as exc:  # pragma: no cover - asserted below
                failures.append(exc)
            finally:
                completed.set()

        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX)
            thread = threading.Thread(target=write_config)
            thread.start()
            self.assertFalse(completed.wait(0.05))
            fcntl.flock(descriptor, fcntl.LOCK_UN)
            thread.join(timeout=5)
        finally:
            os.close(descriptor)

        self.assertEqual([], failures)
        self.assertTrue(completed.is_set())
        self.assertEqual({"version": 2}, store.read())

    def test_update_preserves_valid_json_when_mutator_raises(self):
        original = {"safe": True}
        self.store.write(original)

        def fail(_config):
            raise RuntimeError("stop")

        with self.assertRaisesRegex(RuntimeError, "stop"):
            self.store.update(fail)

        self.assertEqual(original, json.loads(self.config_path.read_text(encoding="utf-8")))

    def test_existing_file_is_restored_when_post_rename_persistence_fails(self):
        original = {"version": 1}
        self.store.write(original)
        real_fsync_directory = configuration_module._fsync_directory
        calls = 0

        def fail_after_replace(path):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise OSError("injected directory fsync failure")
            return real_fsync_directory(path)

        with mock.patch.object(
            configuration_module,
            "_fsync_directory",
            side_effect=fail_after_replace,
        ), self.assertRaisesRegex(OSError, "injected directory fsync failure"):
            self.store.write({"version": 2})

        self.assertEqual(original, json.loads(self.config_path.read_text(encoding="utf-8")))
        self.assertEqual([], list(self.config_path.parent.glob(".config.json.rollback.*.tmp")))

    def test_new_file_is_removed_when_post_rename_persistence_fails(self):
        real_fsync_directory = configuration_module._fsync_directory
        calls = 0

        def fail_after_replace(path):
            nonlocal calls
            calls += 1
            if calls == 1:
                raise OSError("injected directory fsync failure")
            return real_fsync_directory(path)

        with mock.patch.object(
            configuration_module,
            "_fsync_directory",
            side_effect=fail_after_replace,
        ), self.assertRaisesRegex(OSError, "injected directory fsync failure"):
            self.store.write({"new": True})

        self.assertFalse(self.config_path.exists())
        self.assertEqual([], list(self.config_path.parent.glob(".config.json.rollback.*.tmp")))

    def test_recovery_snapshot_is_retained_when_rollback_fails(self):
        original = {"version": 1}
        self.store.write(original)
        real_fsync_directory = configuration_module._fsync_directory
        real_replace = os.replace
        fsync_calls = 0

        def fail_commit_fsync(path):
            nonlocal fsync_calls
            fsync_calls += 1
            if fsync_calls == 2:
                raise OSError("injected directory fsync failure")
            return real_fsync_directory(path)

        def fail_snapshot_restore(source, target):
            if ".rollback." in Path(source).name:
                raise OSError("injected rollback rename failure")
            return real_replace(source, target)

        with mock.patch.object(
            configuration_module,
            "_fsync_directory",
            side_effect=fail_commit_fsync,
        ), mock.patch.object(
            configuration_module.os,
            "replace",
            side_effect=fail_snapshot_restore,
        ), self.assertRaisesRegex(OSError, "recovery snapshot retained"):
            self.store.write({"version": 2})

        snapshots = list(self.config_path.parent.glob(".config.json.rollback.*.tmp"))
        self.assertEqual(1, len(snapshots))
        self.assertEqual(original, json.loads(snapshots[0].read_text(encoding="utf-8")))

    def test_cleanup_failure_does_not_report_a_durable_update_as_failed(self):
        self.store.write({"version": 1})
        real_unlink = Path.unlink

        def fail_snapshot_cleanup(path, *args, **kwargs):
            if ".rollback." in path.name:
                raise PermissionError("injected snapshot cleanup failure")
            return real_unlink(path, *args, **kwargs)

        with mock.patch.object(Path, "unlink", fail_snapshot_cleanup):
            warning = self.store.write({"version": 2})

        self.assertEqual(CONFIG_CLEANUP_WARNING, warning)
        self.assertEqual(CONFIG_CLEANUP_WARNING, self.store.last_warning)
        self.assertEqual({"version": 2}, self.store.read())
        self.assertEqual(1, len(list(self.config_path.parent.glob(".config.json.rollback.*.tmp"))))

    def test_update_with_warning_returns_warning_with_same_transaction(self):
        self.store.write({"version": 1})
        real_unlink = Path.unlink

        def fail_snapshot_cleanup(path, *args, **kwargs):
            if ".rollback." in path.name:
                raise PermissionError("injected snapshot cleanup failure")
            return real_unlink(path, *args, **kwargs)

        def mutate(config):
            config["version"] = 2

        with mock.patch.object(Path, "unlink", fail_snapshot_cleanup):
            updated, warning = self.store.update_with_warning(mutate)

        self.assertEqual({"version": 2}, updated)
        self.assertEqual(CONFIG_CLEANUP_WARNING, warning)
        self.assertEqual({"version": 2}, self.store.read())

    def test_symbolic_link_target_is_rejected(self):
        self.config_path.parent.mkdir(parents=True)
        outside = Path(self.temp.name) / "outside.json"
        outside.write_text('{"outside":true}\n', encoding="utf-8")
        os.symlink(outside, self.config_path)

        with self.assertRaisesRegex(OSError, "symbolic link"):
            self.store.write({"outside": False})

        self.assertEqual({"outside": True}, json.loads(outside.read_text(encoding="utf-8")))

    def test_read_rejects_symbolic_link_target(self):
        self.config_path.parent.mkdir(parents=True)
        outside = Path(self.temp.name) / "outside-read.json"
        outside.write_text('{"outside":true}\n', encoding="utf-8")
        os.symlink(outside, self.config_path)

        with self.assertRaises(OSError):
            self.store.read()

    def test_read_rejects_duplicate_keys_and_non_finite_numbers(self):
        invalid_documents = (
            '{"web":{"enabled":true,"enabled":false}}\n',
            '{"value":NaN}\n',
            '{"value":Infinity}\n',
            '{"value":-Infinity}\n',
        )
        self.config_path.parent.mkdir(parents=True)

        for document in invalid_documents:
            with self.subTest(document=document):
                self.config_path.write_text(document, encoding="utf-8")
                with self.assertRaises(ValueError):
                    self.store.read()

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

    def test_sensitive_edits_default_enabled_and_invalid_values_fail_closed(self):
        self.assertTrue(sensitive_edits_enabled({}))
        self.assertTrue(sensitive_edits_enabled({"web": {}}))
        self.assertTrue(sensitive_edits_enabled({"web": {"sensitive_edits_enabled": True}}))
        self.assertFalse(sensitive_edits_enabled({"web": {"sensitive_edits_enabled": False}}))
        self.assertFalse(sensitive_edits_enabled({"web": {"sensitive_edits_enabled": "true"}}))
        self.assertFalse(sensitive_edits_enabled({"web": None}))
        self.assertFalse(sensitive_edits_enabled({"web": "malformed"}))
        self.assertIn("web.sensitive_edits_enabled", CONFIG_READONLY_FIELDS)
        self.assertIsNotNone(normalize_config_value("web.sensitive_edits_enabled", True)[1])


if __name__ == "__main__":
    unittest.main()
