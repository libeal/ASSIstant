#!/usr/bin/env python3

import contextlib
import hashlib
import importlib.util
import json
import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))
sys.path.insert(0, str(ROOT / "skills" / "ops-change" / "scripts"))

import ops_change  # noqa: E402


def _load_ops_host_handler():
    path = ROOT / "skills" / "ops-change" / "scripts" / "host_handler.py"
    spec = importlib.util.spec_from_file_location("ops_change_host_handler_test", path)
    if spec is None or spec.loader is None:
        raise RuntimeError("ops-change host handler cannot be loaded")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# Keep the existing test names while exercising the package-owned handler.
host_ops_helper = _load_ops_host_handler()


class HostOpsChangeTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)

    def policy(self, restart=(), dropin=()):
        return {
            "service_restart_units": frozenset(restart),
            "systemd_dropin_units": frozenset(dropin),
        }

    def test_host_policy_is_exact_root_owned_and_rejects_duplicates(self):
        path = Path(self.temporary.name) / "policy.json"
        path.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "service_restart_units": ["sshd.service"],
                    "systemd_dropin_units": [],
                }
            ),
            encoding="utf-8",
        )
        path.chmod(0o600)
        metadata = path.stat()
        root_metadata = os.stat_result(
            (
                metadata.st_mode,
                metadata.st_ino,
                metadata.st_dev,
                metadata.st_nlink,
                0,
                0,
                metadata.st_size,
                metadata.st_atime,
                metadata.st_mtime,
                metadata.st_ctime,
            )
        )
        with mock.patch.object(host_ops_helper, "HOST_OPS_POLICY_PATH", path), mock.patch.object(
            Path,
            "lstat",
            return_value=root_metadata,
        ):
            result = host_ops_helper._host_ops_policy()
        self.assertEqual(frozenset({"sshd.service"}), result["service_restart_units"])

        path.write_text(
            '{"schema_version":1,"schema_version":1,"service_restart_units":[],"systemd_dropin_units":[]}',
            encoding="utf-8",
        )
        duplicate_metadata = os.stat_result(
            tuple(root_metadata[:6])
            + (path.stat().st_size,)
            + tuple(root_metadata[7:])
        )
        with mock.patch.object(host_ops_helper, "HOST_OPS_POLICY_PATH", path), mock.patch.object(
            Path,
            "lstat",
            return_value=duplicate_metadata,
        ), self.assertRaises(host_ops_helper.HostOperationError):
            host_ops_helper._host_ops_policy()

        path.write_text(
            '{"schema_version":true,"service_restart_units":[],"systemd_dropin_units":[]}',
            encoding="utf-8",
        )
        with mock.patch.object(host_ops_helper, "HOST_OPS_POLICY_PATH", path), mock.patch.object(
            Path,
            "lstat",
            return_value=root_metadata,
        ), self.assertRaises(host_ops_helper.HostOperationError):
            host_ops_helper._host_ops_policy()

    def test_service_restart_requires_allowlist_confirmation_and_fresh_digest(self):
        state = {"LoadState": "loaded", "ActiveState": "active"}
        digest = "a" * 64
        params = {
            "unit": "sshd.service",
            "apply": True,
            "confirm": "RESTART_SERVICE",
            "preflight_sha256": digest,
        }
        with mock.patch.object(
            host_ops_helper,
            "_host_ops_policy",
            return_value=self.policy(restart=("sshd.service",)),
        ), mock.patch.object(
            host_ops_helper,
            "service_preflight",
            return_value=(state, digest),
        ), mock.patch.object(
            host_ops_helper,
            "_trusted_tool",
            return_value="/usr/bin/systemctl",
        ), mock.patch.object(
            host_ops_helper,
            "_run_fixed",
            return_value={"ok": True, "exit_code": 0, "stdout": "", "stderr": ""},
        ) as run:
            result = host_ops_helper.apply_service_restart(params)
        self.assertTrue(result["ok"])
        run.assert_called_once_with(["/usr/bin/systemctl", "restart", "sshd.service"])

        with mock.patch.object(
            host_ops_helper,
            "_host_ops_policy",
            return_value=self.policy(),
        ), self.assertRaises(host_ops_helper.HostOperationError) as denied:
            host_ops_helper.apply_service_restart(params)
        self.assertEqual("host_operation_not_allowed", denied.exception.code)

        with mock.patch.object(
            host_ops_helper,
            "_host_ops_policy",
            return_value=self.policy(restart=("sshd.service",)),
        ), mock.patch.object(
            host_ops_helper,
            "service_preflight",
            return_value=(state, "b" * 64),
        ), self.assertRaises(host_ops_helper.HostOperationError) as changed:
            host_ops_helper.apply_service_restart(params)
        self.assertEqual("target_changed", changed.exception.code)

        with self.assertRaises(host_ops_helper.HostHelperError):
            host_ops_helper.apply_service_restart({**params, "confirm": "yes"})
        with self.assertRaises(host_ops_helper.HostHelperError):
            host_ops_helper.apply_service_restart({**params, "argv": ["/bin/sh"]})

    def dropin_context(self, old_content=None, digest="c" * 64):
        systemd_root = Path(self.temporary.name) / "systemd"
        systemd_root.mkdir(exist_ok=True)
        target = systemd_root / "sshd.service.d" / "90-linux-agent-resources.conf"
        if old_content is not None:
            target.parent.mkdir(exist_ok=True)
            target.write_bytes(old_content)
            target.chmod(0o640)

        def preflight(_unit):
            try:
                content = target.read_bytes()
            except FileNotFoundError:
                content = None
            return (
                {
                    "state": {"LoadState": "loaded"},
                    "current_sha256": hashlib.sha256(content).hexdigest() if content is not None else None,
                },
                digest,
            )

        patches = [
            mock.patch.object(host_ops_helper, "_host_ops_policy", return_value=self.policy(dropin=("sshd.service",))),
            mock.patch.object(host_ops_helper, "_systemd_mutation_lock", return_value=contextlib.nullcontext()),
            mock.patch.object(host_ops_helper, "_systemd_directory", return_value=systemd_root),
            mock.patch.object(host_ops_helper, "_validate_dropin_directory"),
            mock.patch.object(host_ops_helper, "dropin_path", return_value=target),
            mock.patch.object(host_ops_helper, "dropin_preflight", side_effect=preflight),
            mock.patch.object(host_ops_helper, "_trusted_tool", return_value="/usr/bin/systemctl"),
        ]
        return target, digest, patches

    @staticmethod
    def params(digest, resources=None):
        return {
            "unit": "sshd.service",
            "resources": resources or {"cpu_percent": 75, "memory_bytes": 1048576},
            "apply": True,
            "preflight_sha256": digest,
        }

    def run_with_patches(self, patches, run_result, function):
        started = []
        try:
            for patcher in patches:
                patcher.start()
                started.append(patcher)
            with mock.patch.object(host_ops_helper, "_run_fixed", side_effect=run_result) as runner:
                return function(), runner
        finally:
            for patcher in reversed(started):
                patcher.stop()

    def test_dropin_applies_once_and_never_restarts_service(self):
        target, digest, patches = self.dropin_context()
        success = {"ok": True, "exit_code": 0, "stdout": "", "stderr": ""}
        result, runner = self.run_with_patches(
            patches,
            [success],
            lambda: host_ops_helper.apply_systemd_dropin(self.params(digest)),
        )
        self.assertEqual("updated", result["status"])
        self.assertFalse(result["restart_performed"])
        self.assertEqual(ops_change.render_dropin(self.params(digest)["resources"]), target.read_bytes())
        runner.assert_called_once_with(["/usr/bin/systemctl", "daemon-reload"])

    def test_unchanged_dropin_still_requires_fresh_cas(self):
        content = ops_change.render_dropin({"cpu_percent": 75, "memory_bytes": 1048576})
        target, digest, patches = self.dropin_context(content)
        result, runner = self.run_with_patches(
            patches,
            [],
            lambda: host_ops_helper.apply_systemd_dropin(self.params(digest)),
        )
        self.assertEqual("unchanged", result["status"])
        runner.assert_not_called()

        stale_target, stale_digest, stale_patches = self.dropin_context(content, "d" * 64)
        self.assertEqual(target, stale_target)
        with self.assertRaises(host_ops_helper.HostOperationError) as context:
            self.run_with_patches(
                stale_patches,
                [],
                lambda: host_ops_helper.apply_systemd_dropin(
                    self.params("e" * 64)
                ),
            )
        self.assertEqual("target_changed", context.exception.code)
        self.assertEqual("d" * 64, stale_digest)

    def test_reload_failure_restores_content_and_metadata(self):
        old = b"[Service]\nTasksMax=10\n"
        target, digest, patches = self.dropin_context(old)
        failed = {"ok": False, "exit_code": 1, "stdout": "", "stderr": "failed"}
        success = {"ok": True, "exit_code": 0, "stdout": "", "stderr": ""}
        with self.assertRaisesRegex(host_ops_helper.HostHelperError, "previous state was restored"):
            self.run_with_patches(
                patches,
                [failed, success],
                lambda: host_ops_helper.apply_systemd_dropin(self.params(digest)),
            )
        self.assertEqual(old, target.read_bytes())
        self.assertEqual(0o640, stat.S_IMODE(target.stat().st_mode))
        self.assertEqual(1, len(list(target.parent.glob("*.bak.*"))))

    def test_reload_rollback_failure_is_explicit(self):
        old = b"[Service]\nTasksMax=10\n"
        target, digest, patches = self.dropin_context(old)
        failed = {"ok": False, "exit_code": 1, "stdout": "", "stderr": "failed"}
        with self.assertRaisesRegex(host_ops_helper.HostHelperError, "rollback could not be confirmed"):
            self.run_with_patches(
                patches,
                [failed, failed],
                lambda: host_ops_helper.apply_systemd_dropin(self.params(digest)),
            )
        self.assertEqual(old, target.read_bytes())

    def test_replace_failure_does_not_modify_target_or_leave_backup(self):
        old = b"[Service]\nTasksMax=10\n"
        target, digest, patches = self.dropin_context(old)
        started = []
        try:
            for patcher in patches:
                patcher.start()
                started.append(patcher)
            with mock.patch.object(host_ops_helper.os, "replace", side_effect=OSError("replace failed")), self.assertRaises(OSError):
                host_ops_helper.apply_systemd_dropin(self.params(digest))
        finally:
            for patcher in reversed(started):
                patcher.stop()
        self.assertEqual(old, target.read_bytes())
        self.assertEqual([], list(target.parent.glob("*.bak.*")))

    def test_dropin_rejects_unknown_fields_and_out_of_range_values(self):
        digest = "a" * 64
        with self.assertRaises(host_ops_helper.HostHelperError):
            host_ops_helper.apply_systemd_dropin({**self.params(digest), "path": "/tmp/x"})
        with self.assertRaises(host_ops_helper.HostHelperError):
            host_ops_helper.apply_systemd_dropin(
                self.params(digest, {"cpu_percent": 0})
            )


if __name__ == "__main__":
    unittest.main()
