#!/usr/bin/env python3

import hashlib
import json
import os
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))

import runtime_archive  # noqa: E402


class RuntimeArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def _make_tree(self):
        tree = self.root / "tree"
        for directory in (
            tree / "config",
            tree / "logs",
            tree / "policies",
            tree / "skills" / "custom",
            tree / "reports",
        ):
            directory.mkdir(parents=True, exist_ok=True)
        files = {
            "config/config.redacted.json": '{"web":{"host":"127.0.0.1"}}\n',
            "logs/session.jsonl": '{"seq":1}\n',
            "logs/session.jsonl.1": '{"seq":0}\n',
            "policies/risk-rules.json": '{"blocked_patterns":[]}\n',
            "skills/INDEX.md": "# User Skill Index\n",
            "skills/materialized.json": '{"schema_version":1,"materialized":[]}\n',
            "skills/custom/SKILL.md": "---\nname: custom\ndescription: test\n---\n",
            "reports/session.verify.json": '{"ok":true}\n',
        }
        for relative, content in files.items():
            target = tree / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(content, encoding="utf-8")
        records = []
        for path in sorted(tree.rglob("*")):
            if path.is_file():
                relative = path.relative_to(tree).as_posix()
                records.append(
                    {
                        "path": relative,
                        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                        "size_bytes": path.stat().st_size,
                    }
                )
        manifest = {
            "schema_version": 2,
            "redacted": True,
            "contents": {
                "user_skills": True,
                "effective_policies": True,
                "audit_chain_with_rotations": True,
            },
            "files": records,
        }
        (tree / "manifest.json").write_text(
            json.dumps(manifest, sort_keys=True), encoding="utf-8"
        )
        return tree

    @staticmethod
    def _pack(tree, archive_path):
        with tarfile.open(archive_path, "w:gz") as archive:
            for path in sorted(tree.rglob("*")):
                archive.add(path, arcname=path.relative_to(tree).as_posix(), recursive=False)

    def test_extract_checks_manifest_inventory_and_layout(self):
        tree = self._make_tree()
        archive = self.root / "runtime.tar.gz"
        self._pack(tree, archive)
        destination = self.root / "extract"
        destination.mkdir()

        manifest = runtime_archive.extract_verified(archive, destination)

        self.assertEqual(manifest["schema_version"], 2)
        self.assertEqual(
            (destination / "config" / "config.redacted.json").read_text(encoding="utf-8"),
            '{"web":{"host":"127.0.0.1"}}\n',
        )

    def test_extract_rejects_hash_tampering_and_missing_live_rotation(self):
        tree = self._make_tree()
        (tree / "config" / "config.redacted.json").write_text(
            '{"web":{"host":"tampered"}}\n', encoding="utf-8"
        )
        archive = self.root / "tampered.tar.gz"
        self._pack(tree, archive)
        destination = self.root / "tampered-extract"
        destination.mkdir()
        with self.assertRaises(runtime_archive.ArchiveError):
            runtime_archive.extract_verified(archive, destination)

        tree = self._make_tree()
        (tree / "logs" / "session.jsonl").unlink()
        records = []
        for path in sorted(tree.rglob("*")):
            if path.is_file() and path.name != "manifest.json":
                records.append(
                    {
                        "path": path.relative_to(tree).as_posix(),
                        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                        "size_bytes": path.stat().st_size,
                    }
                )
        manifest = json.loads((tree / "manifest.json").read_text(encoding="utf-8"))
        manifest["files"] = records
        (tree / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
        archive = self.root / "missing-live.tar.gz"
        self._pack(tree, archive)
        destination = self.root / "missing-live-extract"
        destination.mkdir()
        with self.assertRaisesRegex(runtime_archive.ArchiveError, "no live audit"):
            runtime_archive.extract_verified(archive, destination)

    def test_extract_rejects_symbolic_link_members(self):
        archive = self.root / "symlink.tar.gz"
        with tarfile.open(archive, "w:gz") as handle:
            member = tarfile.TarInfo("skills/escape")
            member.type = tarfile.SYMTYPE
            member.linkname = "/etc/passwd"
            handle.addfile(member)
        destination = self.root / "symlink-extract"
        destination.mkdir()
        with self.assertRaisesRegex(runtime_archive.ArchiveError, "unsupported archive member"):
            runtime_archive.extract_verified(archive, destination)

    def test_extract_requires_an_empty_destination(self):
        tree = self._make_tree()
        archive = self.root / "nonempty.tar.gz"
        self._pack(tree, archive)

        destination = self.root / "preloaded-file"
        destination.mkdir()
        (destination / "sentinel").write_text("keep\n", encoding="utf-8")
        with self.assertRaisesRegex(runtime_archive.ArchiveError, "must be empty"):
            runtime_archive.extract_verified(archive, destination)
        self.assertEqual("keep\n", (destination / "sentinel").read_text(encoding="utf-8"))

        external = self.root / "external"
        external.mkdir()
        linked_destination = self.root / "preloaded-link"
        linked_destination.mkdir()
        os.symlink(external, linked_destination / "skills")
        with self.assertRaisesRegex(runtime_archive.ArchiveError, "must be empty"):
            runtime_archive.extract_verified(archive, linked_destination)
        self.assertEqual([], list(external.iterdir()))

    def test_archive_and_config_json_reject_ambiguous_or_non_finite_values(self):
        tree = self._make_tree()
        manifest_path = tree / "manifest.json"
        manifest = manifest_path.read_text(encoding="utf-8")
        manifest_path.write_text(
            manifest[:-1] + ',"schema_version":2}',
            encoding="utf-8",
        )
        archive = self.root / "ambiguous-manifest.tar.gz"
        self._pack(tree, archive)
        destination = self.root / "ambiguous-manifest"
        destination.mkdir()
        with self.assertRaisesRegex(runtime_archive.ArchiveError, "manifest is invalid"):
            runtime_archive.extract_verified(archive, destination)

        for index, (current_payload, restored_payload) in enumerate(
            (
                ('{"value":1,"value":2}', '{"value":3}'),
                ('{"value":1}', '{"value":NaN}'),
            )
        ):
            with self.subTest(index=index):
                current = self.root / f"strict-current-{index}.json"
                restored = self.root / f"strict-restored-{index}.json"
                output = self.root / f"strict-output-{index}.json"
                current.write_text(current_payload, encoding="utf-8")
                restored.write_text(restored_payload, encoding="utf-8")
                with self.assertRaisesRegex(runtime_archive.ArchiveError, "JSON is invalid"):
                    runtime_archive.merge_config(current, restored, output)
                self.assertFalse(output.exists())

    def test_merge_config_preserves_only_sensitive_values(self):
        current = self.root / "current.json"
        restored = self.root / "restored.json"
        output = self.root / "merged.json"
        current.write_text(
            json.dumps(
                {
                    "api_key": "current-api-key",
                    "web": {"token": "current-token", "host": "old"},
                    "nested": {"keep": "old"},
                }
            ),
            encoding="utf-8",
        )
        restored.write_text(
            json.dumps(
                {
                    "api_key": "[REDACTED]",
                    "web": {
                        "token": "[REDACTED]",
                        "host": "new",
                        "new_secret": "[REDACTED]",
                    },
                    "nested": {"keep": "new", "visible": "yes"},
                }
            ),
            encoding="utf-8",
        )

        runtime_archive.merge_config(current, restored, output)
        merged = json.loads(output.read_text(encoding="utf-8"))
        self.assertEqual(merged["api_key"], "current-api-key")
        self.assertEqual(merged["web"], {"token": "current-token", "host": "new"})
        self.assertEqual(merged["nested"], {"keep": "new", "visible": "yes"})

    def test_build_manifest_is_sorted_deterministic_and_single_pass(self):
        stage = self.root / "manifest-stage"
        for relative, content in (
            ("skills/z/SKILL.md", "z\n"),
            ("config/config.redacted.json", "{}\n"),
            ("logs/a.jsonl", "event\n"),
            ("policies/risk-rules.json", "{}\n"),
        ):
            target = stage / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(content, encoding="utf-8")

        output = stage / "manifest.json"
        count = runtime_archive.build_manifest(
            stage,
            output,
            "2026-01-01T00:00:00Z",
            "v2",
            "local",
            False,
        )
        manifest = json.loads(output.read_text(encoding="utf-8"))
        paths = [record["path"] for record in manifest["files"]]

        self.assertEqual(count, 4)
        self.assertEqual(paths, sorted(paths))
        for record in manifest["files"]:
            path = stage / record["path"]
            self.assertEqual(record["size_bytes"], path.stat().st_size)
            self.assertEqual(record["sha256"], hashlib.sha256(path.read_bytes()).hexdigest())
        self.assertNotIn("manifest.json", paths)

    def test_build_manifest_rejects_unsafe_or_excessive_inventory(self):
        stage = self.root / "unsafe-manifest-stage"
        stage.mkdir()
        outside = self.root / "outside"
        outside.write_text("outside\n", encoding="utf-8")
        os.symlink(outside, stage / "linked")
        with self.assertRaisesRegex(runtime_archive.ArchiveError, "unsafe file"):
            runtime_archive.build_manifest(
                stage, stage / "manifest.json", "now", "v1", "local", False
            )
        (stage / "linked").unlink()
        outside_directory = self.root / "outside-directory"
        outside_directory.mkdir()
        os.symlink(outside_directory, stage / "linked-directory")
        with self.assertRaisesRegex(runtime_archive.ArchiveError, "unsafe file"):
            runtime_archive.build_manifest(
                stage, stage / "manifest.json", "now", "v1", "local", False
            )
        (stage / "linked-directory").unlink()
        (stage / "a").write_text("a", encoding="utf-8")
        with mock.patch.object(runtime_archive, "MAX_MEMBERS", 0), self.assertRaisesRegex(
            runtime_archive.ArchiveError, "member limit"
        ):
            runtime_archive.build_manifest(
                stage, stage / "manifest.json", "now", "v1", "local", False
            )

    def test_build_manifest_handles_one_hundred_thousand_records_without_argv(self):
        stage = self.root / "large-manifest-stage"
        stage.mkdir()
        output = stage / "manifest.json"

        class FakeRecord:
            __slots__ = ("index",)

            def __init__(self, index):
                self.index = index

            def relative_to(self, _root):
                return Path(f"records/{self.index:06d}")

            def is_symlink(self):
                return False

            def is_dir(self):
                return False

            def is_file(self):
                return True

            def stat(self):
                return mock.Mock(st_size=1)

        records = (FakeRecord(index) for index in range(100_000))
        with mock.patch.object(Path, "rglob", return_value=records), mock.patch.object(
            runtime_archive, "_sha256", return_value="a" * 64
        ):
            count = runtime_archive.build_manifest(
                stage, output, "now", "v1", "local", False
            )

        self.assertEqual(count, 100_000)
        self.assertGreater(output.stat().st_size, 100_000)

    def test_user_skill_index_contains_only_archived_runner_manifests(self):
        skills = self.root / "portable-skills"
        package = skills / "custom" / "scripts"
        package.mkdir(parents=True)
        (skills / "custom" / "SKILL.md").write_text(
            "---\nname: custom\ndescription: test\n---\n\n- `custom/run`: test\n",
            encoding="utf-8",
        )
        (package / "run.sh").write_text("#!/bin/sh\n", encoding="utf-8")
        manifest = {
            "schema_version": 1,
            "name": "custom",
            "description": "portable user Skill",
            "scripts": [
                {
                    "name": "run.sh",
                    "risk": "low",
                    "execution_class": "runner",
                    "capability": "",
                }
            ],
        }
        (skills / "custom" / "manifest.json").write_text(
            json.dumps(manifest), encoding="utf-8"
        )
        output = skills / "INDEX.md"

        count = runtime_archive.build_user_skill_index(skills, output)

        self.assertEqual(count, 1)
        self.assertIn("`custom/run`", output.read_text(encoding="utf-8"))
        manifest["scripts"][0]["execution_class"] = "host_helper"
        manifest["scripts"][0]["capability"] = "firewall.apply"
        (skills / "custom" / "manifest.json").write_text(
            json.dumps(manifest), encoding="utf-8"
        )
        output.unlink()
        with self.assertRaisesRegex(runtime_archive.ArchiveError, "script contract"):
            runtime_archive.build_user_skill_index(skills, output)

    def test_runtime_fingerprint_separates_release_and_mutable_domains(self):
        release = self.root / "release"
        (release / "lib").mkdir(parents=True)
        (release / "config").mkdir()
        (release / "tmp").mkdir()
        (release / "data").mkdir()
        (release / "lib" / "runtime.py").write_text("v1\n", encoding="utf-8")
        (release / "config" / "config.example.json").write_text("{}\n", encoding="utf-8")
        current_config = release / "config" / "config.json"
        current_config.write_text('{"port":1}\n', encoding="utf-8")
        (release / "tmp" / "restore-stage").write_text("one\n", encoding="utf-8")
        missing_skills = release / "data" / "skills"
        missing_policies = release / "data" / "policies"

        before = runtime_archive.runtime_fingerprint(
            release, current_config, missing_skills, missing_policies
        )
        (release / "tmp" / "restore-stage").write_text("two\n", encoding="utf-8")
        after_runtime_noise = runtime_archive.runtime_fingerprint(
            release, current_config, missing_skills, missing_policies
        )
        self.assertEqual(before, after_runtime_noise)

        (release / "lib" / "runtime.py").write_text("v2\n", encoding="utf-8")
        after_release_change = runtime_archive.runtime_fingerprint(
            release, current_config, missing_skills, missing_policies
        )
        self.assertNotEqual(before, after_release_change)

        persistent_config = self.root / "persistent-config"
        persistent_config.mkdir()
        managed_config = persistent_config / "config.json"
        managed_config.write_text('{"port":2}\n', encoding="utf-8")
        for path in (release / "config").iterdir():
            path.unlink()
        (release / "config").rmdir()
        os.symlink(persistent_config, release / "config")
        current_release = self.root / "current"
        os.symlink(release, current_release)
        managed = runtime_archive.runtime_fingerprint(
            current_release, managed_config, missing_skills, missing_policies
        )
        self.assertRegex(managed, r"^[0-9a-f]{64}$")

    def test_root_lock_creation_inherits_owner_without_chowning_existing_lock(self):
        existing = self.root / "existing.lock"
        existing.write_text("", encoding="utf-8")
        created = self.root / "created.lock"
        with mock.patch.object(os, "geteuid", return_value=0), mock.patch.object(
            os, "fchown"
        ) as fchown:
            with runtime_archive._exclusive_file_lock(
                existing, new_owner=(123, 456)
            ):
                pass
            fchown.assert_not_called()
            with runtime_archive._exclusive_file_lock(
                created, new_owner=(123, 456)
            ):
                pass
            fchown.assert_called_once_with(mock.ANY, 123, 456)

    def _commit_fixture(self, prefix):
        base = self.root / prefix
        candidate_skills = base / "candidate-skills"
        candidate_policies = base / "candidate-policies"
        archived_logs = base / "archived-logs"
        target_skills = base / "target-skills"
        target_policies = base / "target-policies"
        target_logs = base / "target-logs"
        for path in (
            candidate_skills / "custom",
            candidate_policies,
            archived_logs,
            target_skills,
            target_policies,
            target_logs,
        ):
            path.mkdir(parents=True, exist_ok=True)
        (candidate_skills / "INDEX.md").write_text("# index\n", encoding="utf-8")
        (candidate_skills / "custom" / "SKILL.md").write_text("new\n", encoding="utf-8")
        (candidate_policies / "risk-rules.json").write_text("new-policy\n", encoding="utf-8")
        (archived_logs / "session.jsonl").write_text("archive\n", encoding="utf-8")
        (target_skills / "old").write_text("old-skill\n", encoding="utf-8")
        (target_policies / "old.json").write_text("old-policy\n", encoding="utf-8")
        (target_logs / "existing.jsonl").write_text("existing\n", encoding="utf-8")
        target_config = base / "config.json"
        target_config.write_text('{"current":true}\n', encoding="utf-8")
        merged_config = base / "merged.json"
        merged_config.write_text('{"restored":true}\n', encoding="utf-8")
        return (
            candidate_skills,
            candidate_policies,
            archived_logs,
            target_skills,
            target_policies,
            target_logs,
            merged_config,
            target_config,
        )

    def test_commit_restore_replaces_overlay_and_preserves_audit_conflicts(self):
        paths = self._commit_fixture("commit")
        runtime_archive.commit_restore(*paths, managed=False)
        target_skills, target_policies = paths[3], paths[4]
        self.assertTrue((target_skills / "custom" / "SKILL.md").is_file())
        self.assertFalse((target_skills / "old").exists())
        self.assertEqual((target_policies / "risk-rules.json").read_text(encoding="utf-8"), "new-policy\n")

    def test_commit_restore_rolls_back_when_policy_rename_fails(self):
        paths = self._commit_fixture("rollback")
        target_skills, target_policies = paths[3], paths[4]
        original_skill = (target_skills / "old").read_text(encoding="utf-8")
        original_policy = (target_policies / "old.json").read_text(encoding="utf-8")
        original_replace = os.replace

        def fail_policy_install(source, destination):
            if Path(source).name.startswith(".target-policies.restore."):
                raise OSError("injected policy rename failure")
            return original_replace(source, destination)

        with mock.patch.object(runtime_archive.os, "replace", side_effect=fail_policy_install):
            with self.assertRaises(OSError):
                runtime_archive.commit_restore(*paths, managed=False)
        self.assertEqual((target_skills / "old").read_text(encoding="utf-8"), original_skill)
        self.assertEqual((target_policies / "old.json").read_text(encoding="utf-8"), original_policy)
        self.assertFalse((target_skills / "custom").exists())

    def test_commit_restore_fsync_failure_rolls_back_and_persists_recovery(self):
        paths = self._commit_fixture("fsync-rollback")
        real_fsync_directory = runtime_archive._fsync_directory
        calls = 0

        def fail_once(path):
            nonlocal calls
            calls += 1
            if calls == 1:
                raise OSError("injected restore fsync failure")
            return real_fsync_directory(path)

        with mock.patch.object(
            runtime_archive,
            "_fsync_directory",
            side_effect=fail_once,
        ), self.assertRaisesRegex(OSError, "injected restore fsync failure"):
            runtime_archive.commit_restore(*paths, managed=False)

        self.assertGreaterEqual(calls, 5)
        self.assertTrue((paths[3] / "old").is_file())
        self.assertTrue((paths[4] / "old.json").is_file())
        self.assertEqual('{"current":true}\n', paths[7].read_text(encoding="utf-8"))
        self.assertFalse((paths[5] / "session.jsonl").exists())

    def test_commit_restore_reports_cleanup_warning_after_durable_commit(self):
        paths = self._commit_fixture("cleanup-warning")
        original_rmtree = runtime_archive.shutil.rmtree

        def fail_backup_cleanup(path, *args, **kwargs):
            if ".restore-backup." in str(path):
                raise OSError("injected backup cleanup failure")
            return original_rmtree(path, *args, **kwargs)

        with mock.patch.object(
            runtime_archive.shutil,
            "rmtree",
            side_effect=fail_backup_cleanup,
        ):
            warning = runtime_archive.commit_restore(*paths, managed=False)

        self.assertEqual(warning, "restore_cleanup_pending")
        self.assertTrue((paths[3] / "custom" / "SKILL.md").is_file())
        self.assertEqual((paths[4] / "risk-rules.json").read_text(), "new-policy\n")

    def test_commit_restore_rejects_conflicting_audit_before_mutation(self):
        paths = self._commit_fixture("audit-conflict")
        archived_logs = paths[2]
        (archived_logs / "existing.jsonl").write_text("archived\n", encoding="utf-8")
        target_config = paths[7]

        with self.assertRaisesRegex(runtime_archive.ArchiveError, "different content"):
            runtime_archive.commit_restore(*paths, managed=False)

        self.assertTrue((paths[3] / "old").is_file())
        self.assertTrue((paths[4] / "old.json").is_file())
        self.assertEqual(target_config.read_text(encoding="utf-8"), '{"current":true}\n')

    def test_commit_restore_does_not_replace_concurrently_created_audit(self):
        paths = self._commit_fixture("audit-create-race")
        destination = paths[5] / "session.jsonl"
        real_link = os.link

        def create_before_link(source, target, *args, **kwargs):
            Path(target).write_text("concurrent\n", encoding="utf-8")
            return real_link(source, target, *args, **kwargs)

        with mock.patch.object(runtime_archive.os, "link", side_effect=create_before_link):
            with self.assertRaises(FileExistsError):
                runtime_archive.commit_restore(*paths, managed=False)

        self.assertEqual("concurrent\n", destination.read_text(encoding="utf-8"))
        self.assertTrue((paths[3] / "old").is_file())
        self.assertTrue((paths[4] / "old.json").is_file())
        self.assertEqual('{"current":true}\n', paths[7].read_text(encoding="utf-8"))

    def test_managed_commit_requires_precreated_overlay_directories(self):
        paths = self._commit_fixture("managed-missing")
        for target in (paths[3], paths[4]):
            for child in target.iterdir():
                child.unlink()
            target.rmdir()

        with self.assertRaisesRegex(runtime_archive.ArchiveError, "overlay directories"):
            runtime_archive.commit_restore(*paths, managed=True)


if __name__ == "__main__":
    unittest.main()
