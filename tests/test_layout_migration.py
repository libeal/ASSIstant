import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import lib.layout_migration as migration_module
from lib.layout_migration import MARKER_NAME, MigrationError, migrate


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
        self.write_builtin_index(self.release)

    def tearDown(self):
        self.temp.cleanup()

    @staticmethod
    def write_builtin_index(release, *names):
        lines = ["# Builtin Skills", ""]
        for name in names:
            lines.extend((f"## {name}", "", f"> {name} fixture.", ""))
        (release / "skills" / "INDEX.md").write_text(
            "\n".join(lines), encoding="utf-8"
        )

    @staticmethod
    def write_skill(root, name, *, legacy=False):
        package = root / name
        scripts = package / "scripts"
        scripts.mkdir(parents=True)
        (package / "SKILL.md").write_text(
            "---\n"
            f"name: {name}\n"
            "description: Standard user fixture.\n"
            "---\n\n"
            f"# {name}\n",
            encoding="utf-8",
        )
        script = scripts / "run.sh"
        script.write_text("#!/usr/bin/env bash\nprintf '{}\\n'\n", encoding="utf-8")
        script.chmod(0o755)
        if legacy:
            (package / "manifest.json").write_text("{}\n", encoding="utf-8")
        return package

    @staticmethod
    def write_policy(root, name, payload):
        (root / name).write_text(json.dumps(payload) + "\n", encoding="utf-8")

    def test_first_migration_rejects_legacy_skill_import_and_copies_policy(self):
        self.write_skill(self.legacy / "skills", "old-custom", legacy=True)
        self.write_policy(self.legacy / "policies", "risk-rules.json", {"legacy": True})
        self.write_policy(self.release / "policies", "risk-rules.json", {"legacy": False})

        result = migrate(self.legacy, self.release, self.data, "v2")

        self.assertEqual(result["status"], "migrated")
        self.assertFalse((self.data / "skills" / "old-custom").exists())
        self.assertFalse((self.data / "skills" / "INDEX.md").exists())
        self.assertIn(
            {
                "name": "old-custom",
                "reason": "legacy_format_unsupported",
                "source": "legacy_release",
            },
            result["summary"]["skills_skipped"],
        )
        self.assertEqual(
            json.loads(
                (self.data / "policies" / "risk-rules.json").read_text(
                    encoding="utf-8"
                )
            ),
            {"legacy": True},
        )
        self.assertTrue((self.data / MARKER_NAME).is_file())
        self.assertEqual(
            migrate(self.legacy, self.release, self.data, "v2")["status"],
            "already_migrated",
        )

    def test_standard_user_package_is_preserved_without_user_index(self):
        package = self.write_skill(self.data / "skills", "custom-skill")
        before = migration_module._directory_digest(package)

        result = migrate(None, self.release, self.data, "v2")

        self.assertEqual(migration_module._directory_digest(package), before)
        self.assertEqual(result["summary"]["skills_skipped"], [])
        self.assertFalse((self.data / "skills" / "INDEX.md").exists())

    def test_legacy_user_package_and_index_are_reported_but_not_rewritten(self):
        package = self.write_skill(
            self.data / "skills", "legacy-user", legacy=True
        )
        user_index = self.data / "skills" / "INDEX.md"
        user_index.write_text("# Legacy user index\n", encoding="utf-8")

        result = migrate(None, self.release, self.data, "v2")

        self.assertTrue((package / "manifest.json").is_file())
        self.assertTrue(user_index.is_file())
        reasons = {
            item["name"]: item["reason"]
            for item in result["summary"]["skills_skipped"]
        }
        self.assertEqual(reasons["legacy-user"], "legacy_format_unsupported")
        self.assertEqual(reasons["INDEX.md"], "legacy_format_unsupported")

    def test_builtin_conflict_is_quarantined_from_signed_index(self):
        self.write_builtin_index(self.release, "built-in")
        self.write_skill(self.data / "skills", "built-in")
        self.write_policy(self.release / "policies", "active.json", {"active": True})
        self.write_policy(self.data / "policies", "orphan.json", {"orphan": True})

        result = migrate(None, self.release, self.data, "v2")

        self.assertFalse((self.data / "skills" / "built-in").exists())
        conflict = result["summary"]["skill_conflicts"][0]
        self.assertEqual(conflict["reason"], "user_overlay_conflicts_with_builtin")
        self.assertTrue((self.data / conflict["quarantined"]).is_dir())
        self.assertEqual(result["summary"]["orphaned_policies"], ["orphan.json"])

    def test_digest_verified_conflict_is_restored_on_rollback(self):
        package = self.write_skill(self.data / "skills", "custom-skill")
        original_digest = migration_module._directory_digest(package)
        v1_release = self.root / "releases" / "v1-target"
        (v1_release / "skills").mkdir(parents=True)
        (v1_release / "policies").mkdir()
        self.write_builtin_index(v1_release)
        migrate(None, v1_release, self.data, "v1")

        self.write_builtin_index(self.release, "custom-skill")
        upgraded = migrate(v1_release, self.release, self.data, "v2")
        conflict = upgraded["summary"]["skill_conflicts"][0]
        self.assertEqual(conflict["sha256"], original_digest)

        rolled_back = migrate(self.release, v1_release, self.data, "v1-rollback")

        restored = self.data / "skills" / "custom-skill"
        self.assertEqual(migration_module._directory_digest(restored), original_digest)
        self.assertEqual(rolled_back["summary"]["skills_restored"][0]["name"], "custom-skill")
        self.assertFalse((self.data / "skills" / "INDEX.md").exists())

    def test_tampered_quarantine_fails_closed(self):
        self.write_skill(self.data / "skills", "custom-skill")
        v1_release = self.root / "releases" / "v1-target"
        (v1_release / "skills").mkdir(parents=True)
        (v1_release / "policies").mkdir()
        self.write_builtin_index(v1_release)
        migrate(None, v1_release, self.data, "v1")
        self.write_builtin_index(self.release, "custom-skill")
        upgraded = migrate(v1_release, self.release, self.data, "v2")
        quarantined = self.data / upgraded["summary"]["skill_conflicts"][0]["quarantined"]
        (quarantined / "SKILL.md").write_text("changed\n", encoding="utf-8")

        with self.assertRaisesRegex(MigrationError, "digest changed"):
            migrate(self.release, v1_release, self.data, "v1-rollback")

    def test_invalid_user_package_is_isolated_without_stopping_migration(self):
        package = self.write_skill(self.data / "skills", "unsafe-skill")
        os.symlink("/etc/passwd", package / "external")

        result = migrate(None, self.release, self.data, "v2")

        self.assertEqual(result["status"], "migrated")
        skipped = result["summary"]["skills_skipped"]
        self.assertEqual(skipped[0]["name"], "unsafe-skill")
        self.assertEqual(skipped[0]["reason"], "invalid_package")

    def test_policy_and_marker_json_must_be_unambiguous_and_finite(self):
        self.write_policy(self.release / "policies", "active.json", {"enabled": True})
        cases = (
            (
                self.legacy / "policies" / "active.json",
                '{"enabled":true,"enabled":false}',
                "legacy policy",
            ),
            (
                self.data / "policies" / "active.json",
                '{"value":NaN}',
                "existing policy overlay",
            ),
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
            migration_module, "_fsync_directory", side_effect=fail_once
        ), self.assertRaisesRegex(OSError, "injected migration fsync failure"):
            migration_module._replace_with_recovery(temp, target)

        self.assertEqual('{"version":1}\n', target.read_text(encoding="utf-8"))
        self.assertFalse(temp.exists())

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
            migration_module, "_fsync_directory", side_effect=fail_once
        ), self.assertRaisesRegex(OSError, "injected migration fsync failure"):
            migration_module._replace_with_recovery(temp, target)

        self.assertFalse(target.exists())
        self.assertFalse(temp.exists())


if __name__ == "__main__":
    unittest.main()
