import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from lib.layout_migration import MARKER_NAME, MigrationError, migrate
import lib.layout_migration as migration_module


class LayoutMigrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.legacy = self.root / "releases" / "v1"
        self.release = self.root / "releases" / "v2"
        self.data = self.root / "data"
        for path in (
            self.legacy / "skills",
            self.legacy / "policies",
            self.release / "skills",
            self.release / "policies",
            self.data / "skills",
            self.data / "policies",
        ):
            path.mkdir(parents=True)

    def tearDown(self):
        self.temp.cleanup()

    @staticmethod
    def write_skill(root, name, *, manifest=None):
        package = root / name
        scripts = package / "scripts"
        scripts.mkdir(parents=True)
        (package / "SKILL.md").write_text(
            "---\n"
            f"name: {name}\n"
            "description: Migrated fixture\n"
            "---\n\n"
            "## Arguments\n\n"
            "- `scripts/run.sh`: accepts one JSON object.\n",
            encoding="utf-8",
        )
        script = scripts / "run.sh"
        script.write_text("#!/usr/bin/env bash\nprintf '{}\\n'\n", encoding="utf-8")
        script.chmod(0o755)
        if manifest is not None:
            (package / "manifest.json").write_text(
                json.dumps(manifest), encoding="utf-8"
            )
        return package

    @staticmethod
    def write_policy(root, name, payload):
        (root / name).write_text(json.dumps(payload) + "\n", encoding="utf-8")

    def test_first_migration_generates_runner_manifest_and_copies_policy(self):
        self.write_skill(self.legacy / "skills", "custom-skill")
        self.write_skill(self.legacy / "skills", "built-in")
        self.write_skill(self.release / "skills", "built-in")
        self.write_policy(self.legacy / "policies", "risk-rules.json", {"legacy": True})
        self.write_policy(self.release / "policies", "risk-rules.json", {"legacy": False})

        result = migrate(self.legacy, self.release, self.data, "v2")

        self.assertEqual(result["status"], "migrated")
        manifest = json.loads(
            (self.data / "skills" / "custom-skill" / "manifest.json").read_text(
                encoding="utf-8"
            )
        )
        self.assertEqual(
            manifest["scripts"],
            [
                {
                    "name": "run.sh",
                    "risk": "high",
                    "execution_class": "runner",
                    "capability": "",
                }
            ],
        )
        self.assertFalse((self.data / "skills" / "built-in").exists())
        self.assertTrue((self.data / "skills" / "INDEX.md").is_file())
        policy = json.loads(
            (self.data / "policies" / "risk-rules.json").read_text(encoding="utf-8")
        )
        self.assertEqual(policy, {"legacy": True})
        self.assertTrue((self.data / MARKER_NAME).is_file())
        self.assertEqual(migrate(self.legacy, self.release, self.data, "v2")["status"], "already_migrated")

    def test_privileged_user_manifest_is_rewritten_to_runner(self):
        manifest = {
            "schema_version": 1,
            "name": "custom-skill",
            "description": "Forged helper",
            "scripts": [
                {
                    "name": "run.sh",
                    "risk": "critical",
                    "execution_class": "host_helper",
                    "capability": "firewall.apply",
                }
            ],
        }
        self.write_skill(self.legacy / "skills", "custom-skill", manifest=manifest)

        migrate(self.legacy, self.release, self.data, "v2")

        stored = json.loads(
            (self.data / "skills" / "custom-skill" / "manifest.json").read_text(
                encoding="utf-8"
            )
        )
        self.assertEqual(stored["scripts"][0]["execution_class"], "runner")
        self.assertEqual(stored["scripts"][0]["capability"], "")
        self.assertEqual(stored["scripts"][0]["risk"], "critical")

    def test_existing_builtin_conflict_is_quarantined_and_orphan_reported(self):
        self.write_skill(self.release / "skills", "built-in")
        self.write_skill(self.data / "skills", "built-in")
        self.write_policy(self.release / "policies", "active.json", {"active": True})
        self.write_policy(self.data / "policies", "orphan.json", {"orphan": True})

        result = migrate(None, self.release, self.data, "v2")

        self.assertFalse((self.data / "skills" / "built-in").exists())
        conflicts = result["summary"]["skill_conflicts"]
        self.assertEqual(conflicts[0]["reason"], "user_overlay_conflicts_with_builtin")
        quarantined = self.data / conflicts[0]["quarantined"]
        self.assertTrue(quarantined.is_dir())
        self.assertEqual(result["summary"]["orphaned_policies"], ["orphan.json"])

    def test_later_release_reconciles_new_builtin_and_policy_orphans(self):
        self.write_skill(self.legacy / "skills", "custom-skill")
        self.write_policy(self.legacy / "policies", "removed-later.json", {"v": 1})
        self.write_policy(self.release / "policies", "removed-later.json", {"v": 2})
        migrate(self.legacy, self.release, self.data, "v2")

        next_release = self.root / "releases" / "v3"
        (next_release / "skills").mkdir(parents=True)
        (next_release / "policies").mkdir(parents=True)
        self.write_skill(next_release / "skills", "custom-skill")
        self.write_skill(self.release / "skills", "removed-built-in")
        self.write_policy(next_release / "policies", "added.json", {"v": 3})

        result = migrate(self.release, next_release, self.data, "v3")

        self.assertEqual(result["status"], "reconciled")
        self.assertFalse((self.data / "skills" / "custom-skill").exists())
        self.assertFalse((self.data / "skills" / "removed-built-in").exists())
        self.assertEqual(
            result["summary"]["skill_conflicts"][0]["reason"],
            "user_overlay_conflicts_with_builtin",
        )
        self.assertEqual(
            result["summary"]["orphaned_policies"], ["removed-later.json"]
        )
        self.assertEqual(
            json.loads((self.data / MARKER_NAME).read_text(encoding="utf-8"))[
                "target_version"
            ],
            "v3",
        )
        self.assertEqual(
            migrate(self.release, next_release, self.data, "v3")["status"],
            "already_migrated",
        )

    def test_rollback_restores_a_digest_verified_quarantined_user_skill(self):
        self.write_skill(self.legacy / "skills", "custom-skill")
        v1_release = self.root / "releases" / "v1-target"
        (v1_release / "skills").mkdir(parents=True)
        (v1_release / "policies").mkdir()
        migrate(self.legacy, v1_release, self.data, "v1")
        original_digest = migration_module._directory_digest(
            self.data / "skills" / "custom-skill"
        )

        self.write_skill(self.release / "skills", "custom-skill")
        upgraded = migrate(v1_release, self.release, self.data, "v2")
        conflict = upgraded["summary"]["skill_conflicts"][0]
        self.assertEqual(conflict["source_version"], "v1")
        self.assertEqual(conflict["target_version"], "v2")
        self.assertEqual(conflict["sha256"], original_digest)
        self.assertFalse((self.data / "skills" / "custom-skill").exists())

        rolled_back = migrate(self.release, v1_release, self.data, "v1-rollback")

        restored = self.data / "skills" / "custom-skill"
        self.assertTrue(restored.is_dir())
        self.assertEqual(migration_module._directory_digest(restored), original_digest)
        self.assertEqual(
            rolled_back["summary"]["skills_restored"],
            [
                {
                    "name": "custom-skill",
                    "from": conflict["quarantined"],
                    "sha256": original_digest,
                }
            ],
        )
        self.assertIn(
            "`custom-skill/run`",
            (self.data / "skills" / "INDEX.md").read_text(encoding="utf-8"),
        )

    def test_rollback_fails_closed_if_quarantined_skill_changed(self):
        self.write_skill(self.legacy / "skills", "custom-skill")
        v1_release = self.root / "releases" / "v1-target"
        (v1_release / "skills").mkdir(parents=True)
        (v1_release / "policies").mkdir()
        migrate(self.legacy, v1_release, self.data, "v1")
        self.write_skill(self.release / "skills", "custom-skill")
        upgraded = migrate(v1_release, self.release, self.data, "v2")
        quarantined = self.data / upgraded["summary"]["skill_conflicts"][0][
            "quarantined"
        ]
        (quarantined / "SKILL.md").write_text("changed\n", encoding="utf-8")

        with self.assertRaisesRegex(MigrationError, "digest changed"):
            migrate(self.release, v1_release, self.data, "v1-rollback")

        self.assertFalse((self.data / "skills" / "custom-skill").exists())

    def test_symlink_in_legacy_skill_fails_closed(self):
        package = self.write_skill(self.legacy / "skills", "custom-skill")
        os.symlink("/etc/passwd", package / "external")

        with self.assertRaises(MigrationError):
            migrate(self.legacy, self.release, self.data, "v2")

    def test_policy_and_marker_json_must_be_unambiguous_and_finite(self):
        self.write_policy(self.release / "policies", "active.json", {"enabled": True})

        cases = (
            (self.legacy / "policies" / "active.json", '{"enabled":true,"enabled":false}', "legacy policy"),
            (self.data / "policies" / "active.json", '{"value":NaN}', "existing policy overlay"),
            (
                self.data / MARKER_NAME,
                '{"schema_version":1,"target_version":"v1","target_version":"v2"}',
                "overlay layout marker",
            ),
        )
        for index, (path, payload, message) in enumerate(cases):
            with self.subTest(message=message):
                path.write_text(payload, encoding="utf-8")
                with self.assertRaisesRegex(MigrationError, message):
                    migrate(self.legacy, self.release, self.data, f"v2-{index}")
                path.unlink()

    def test_ambiguous_legacy_manifest_is_not_trusted(self):
        package = self.write_skill(self.legacy / "skills", "custom-skill")
        (package / "manifest.json").write_text(
            '{"scripts":[{"name":"run.sh","risk":"low","risk":"critical"}]}',
            encoding="utf-8",
        )

        migrate(self.legacy, self.release, self.data, "v2")

        stored = json.loads(
            (self.data / "skills" / "custom-skill" / "manifest.json").read_text(
                encoding="utf-8"
            )
        )
        self.assertEqual(stored["scripts"][0]["risk"], "high")

    def test_atomic_replacement_recovers_after_directory_fsync_failure(self):
        target = self.data / "policies" / "recovery.json"
        target.write_text('{"version":1}\n', encoding="utf-8")
        temp = self.data / "policies" / ".recovery.tmp"
        temp.write_text('{"version":2}\n', encoding="utf-8")
        real_fsync_directory = migration_module._fsync_directory
        calls = 0

        def fail_once(path):
            nonlocal calls
            calls += 1
            if calls == 1:
                raise OSError("injected migration fsync failure")
            return real_fsync_directory(path)

        with mock.patch.object(
            migration_module,
            "_fsync_directory",
            side_effect=fail_once,
        ), self.assertRaisesRegex(OSError, "injected migration fsync failure"):
            migration_module._replace_with_recovery(temp, target)

        self.assertEqual('{"version":1}\n', target.read_text(encoding="utf-8"))
        self.assertFalse(temp.exists())
        self.assertEqual([], list(target.parent.glob(".recovery.json.previous.*.tmp")))

    def test_atomic_replacement_removes_new_target_after_fsync_failure(self):
        target = self.data / "policies" / "new.json"
        temp = self.data / "policies" / ".new.tmp"
        temp.write_text('{"new":true}\n', encoding="utf-8")
        real_fsync_directory = migration_module._fsync_directory
        calls = 0

        def fail_once(path):
            nonlocal calls
            calls += 1
            if calls == 1:
                raise OSError("injected migration fsync failure")
            return real_fsync_directory(path)

        with mock.patch.object(
            migration_module,
            "_fsync_directory",
            side_effect=fail_once,
        ), self.assertRaisesRegex(OSError, "injected migration fsync failure"):
            migration_module._replace_with_recovery(temp, target)

        self.assertFalse(target.exists())
        self.assertFalse(temp.exists())


if __name__ == "__main__":
    unittest.main()
