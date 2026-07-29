import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "skills" / "ops-change" / "scripts"))

import ops_change  # noqa: E402


class OpsChangeTests(unittest.TestCase):
    def test_argument_json_rejects_duplicates_and_non_finite_numbers(self):
        for raw in ('{"action":"read","action":"plan"}', '{"limit":NaN}', '{"limit":Infinity}'):
            with self.subTest(raw=raw), self.assertRaises(ops_change.OpsChangeError):
                ops_change._object(raw)

    def test_account_audit_reads_only_bounded_fixed_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            passwd_path = Path(temporary) / "passwd"
            group_path = Path(temporary) / "group"
            passwd_path.write_text(
                "root:x:0:0:root:/root:/bin/sh\n"
                "invalid:x:not-a-uid:0::/:/bin/false\n"
                "operator:x:1000:1000::/home/operator:/bin/bash\n",
                encoding="utf-8",
            )
            group_path.write_text(
                "root:x:0:\noperators:x:1000:operator,reader\ninvalid:x:gid:user\n",
                encoding="utf-8",
            )
            with mock.patch.object(ops_change, "PASSWD_PATH", passwd_path), mock.patch.object(
                ops_change, "GROUP_PATH", group_path
            ), mock.patch.object(ops_change, "_tool", return_value=None):
                result = ops_change.account_audit({"limit": 1})

        self.assertEqual(["root"], [entry["name"] for entry in result["accounts"]])
        self.assertEqual(["root"], [entry["name"] for entry in result["groups"]])
        self.assertEqual(2, result["invalid_entries"])
        self.assertTrue(result["truncated"])
        self.assertFalse(result["shadow_read"])

    def test_account_audit_rejects_a_symbolic_link_source(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            actual = root / "actual-passwd"
            passwd_path = root / "passwd"
            group_path = root / "group"
            actual.write_text("root:x:0:0:root:/root:/bin/sh\n", encoding="utf-8")
            passwd_path.symlink_to(actual)
            group_path.write_text("root:x:0:\n", encoding="utf-8")
            with mock.patch.object(ops_change, "PASSWD_PATH", passwd_path), mock.patch.object(
                ops_change, "GROUP_PATH", group_path
            ), self.assertRaisesRegex(ops_change.OpsChangeError, "account source"):
                ops_change.account_audit({})

    def test_resource_contract_is_strict_and_bounded(self):
        self.assertEqual(
            ops_change.normalize_resources(
                {"cpu_percent": 250, "memory_bytes": 1_048_576, "tasks": 10, "restart_sec": 0}
            ),
            {"cpu_percent": 250, "memory_bytes": 1_048_576, "tasks": 10, "restart_sec": 0},
        )
        for value in ({}, {"cpu_percent": True}, {"cpu_percent": 1001}, {"unknown": 1}):
            with self.subTest(value=value), self.assertRaises(ops_change.OpsChangeError):
                ops_change.normalize_resources(value)

    def test_service_preflight_digest_is_deterministic_and_state_bound(self):
        state = {name: "value" for name in ops_change.SYSTEMD_SHOW_PROPERTIES}
        with mock.patch.object(ops_change, "_systemctl_show", return_value=state):
            first_state, first = ops_change.service_preflight("demo.service")
            second_state, second = ops_change.service_preflight("demo.service")
        self.assertEqual(first_state, second_state)
        self.assertEqual(first, second)
        with mock.patch.object(
            ops_change,
            "_systemctl_show",
            return_value={**state, "ActiveState": "failed"},
        ):
            _changed_state, changed = ops_change.service_preflight("demo.service")
        self.assertNotEqual(first, changed)

    def test_schedule_plan_rejects_caller_selected_paths_and_commands(self):
        with self.assertRaisesRegex(ops_change.OpsChangeError, "cron target"):
            ops_change.schedule_edit_plan(
                {"kind": "cron", "path": "/tmp/job", "content": "* * * * * root true\n"}
            )
        with self.assertRaisesRegex(ops_change.OpsChangeError, "unsupported fields"):
            ops_change.schedule_edit_plan(
                {
                    "kind": "timer",
                    "unit": "demo.timer",
                    "properties": {"OnCalendar": "daily"},
                    "command": "/bin/true",
                }
            )
        with self.assertRaisesRegex(ops_change.OpsChangeError, "single-line"):
            ops_change.schedule_edit_plan(
                {
                    "kind": "timer",
                    "unit": "demo.timer",
                    "properties": {"OnCalendar": "daily\n[Service]\nExecStart=/bin/true"},
                }
            )

    def test_read_and_plan_reject_apply_only_fields(self):
        with self.assertRaisesRegex(ops_change.OpsChangeError, "unsupported fields"):
            ops_change.service_restart(
                {
                    "action": "read",
                    "unit": "demo.service",
                    "confirm": "RESTART_SERVICE",
                }
            )
        with self.assertRaisesRegex(ops_change.OpsChangeError, "unsupported fields"):
            ops_change.systemd_dropin(
                {
                    "action": "plan",
                    "unit": "demo.service",
                    "resources": {"tasks": 10},
                    "preflight_sha256": "a" * 64,
                }
            )

    def test_dropin_plan_uses_only_fixed_resource_properties(self):
        with tempfile.TemporaryDirectory() as temporary:
            target = Path(temporary) / "dropin.conf"
            preflight = {
                "kind": "systemd-dropin",
                "unit": "demo.service",
                "state": {"LoadState": "loaded"},
                "target": str(target),
                "current_sha256": None,
            }
            with mock.patch.object(ops_change, "dropin_path", return_value=target), mock.patch.object(
                ops_change, "dropin_preflight", return_value=(preflight, "a" * 64)
            ):
                result = ops_change.systemd_dropin(
                    {
                        "action": "plan",
                        "unit": "demo.service",
                        "resources": {"cpu_percent": 50},
                    }
                )
            self.assertIn("CPUQuota=50%", result["diff"])
            self.assertFalse(result["restart_performed"])


if __name__ == "__main__":
    unittest.main()
