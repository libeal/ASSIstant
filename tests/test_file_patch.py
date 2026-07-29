import hashlib
import sys
import tempfile
import threading
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "skills" / "controlled-tools" / "scripts"))

import file_patch  # noqa: E402


class FilePatchTests(unittest.TestCase):
    def test_argument_json_rejects_duplicates_and_non_finite_numbers(self):
        for raw in ('{"action":"patch","action":"create"}', '{"expected_count":NaN}'):
            with self.subTest(raw=raw), self.assertRaises(file_patch.FilePatchError):
                file_patch._strict_object(raw)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.target = self.root / "app.conf"
        self.target.write_text("one=1\ntwo=2\n", encoding="utf-8")

    def tearDown(self):
        self.temp.cleanup()

    def digest(self):
        return hashlib.sha256(self.target.read_bytes()).hexdigest()

    def test_multi_operation_patch_is_atomic_and_cas_bound(self):
        before = self.digest()
        result = file_patch.execute(
            {
                "action": "patch",
                "path": str(self.target),
                "expected_sha256": before,
                "apply": True,
                "operations": [
                    {"find": "one=1", "replacement": "one=10", "expected_count": 1},
                    {"find": "two=2", "replacement": "two=20", "expected_count": 1},
                ],
            }
        )
        self.assertEqual(result["status"], "patched")
        self.assertEqual(self.target.read_text(encoding="utf-8"), "one=10\ntwo=20\n")
        self.assertTrue(Path(result["backup_path"]).is_file())

        with self.assertRaisesRegex(file_patch.FilePatchError, "target changed"):
            file_patch.execute(
                {
                    "action": "patch",
                    "path": str(self.target),
                    "expected_sha256": before,
                    "operations": [
                        {"find": "one=10", "replacement": "bad", "expected_count": 1}
                    ],
                }
            )

    def test_failed_later_operation_writes_nothing(self):
        before = self.target.read_bytes()
        with self.assertRaisesRegex(file_patch.FilePatchError, r"operations\[1\]"):
            file_patch.execute(
                {
                    "action": "patch",
                    "path": str(self.target),
                    "expected_sha256": hashlib.sha256(before).hexdigest(),
                    "apply": True,
                    "operations": [
                        {"find": "one=1", "replacement": "one=10", "expected_count": 1},
                        {"find": "missing", "replacement": "bad", "expected_count": 1},
                    ],
                }
            )
        self.assertEqual(self.target.read_bytes(), before)
        self.assertEqual(list(self.root.glob("app.conf.bak.*")), [])

    def test_append_block_is_idempotent_and_conflicts_on_content_change(self):
        arguments = {
            "action": "append_block",
            "path": str(self.target),
            "marker_id": "limits",
            "comment_prefix": "#",
            "content": "limit=4",
            "expected_sha256": self.digest(),
            "apply": True,
        }
        result = file_patch.execute(arguments)
        self.assertEqual(result["status"], "patched")
        arguments["expected_sha256"] = self.digest()
        unchanged = file_patch.execute(arguments)
        self.assertEqual(unchanged["status"], "unchanged")
        arguments["content"] = "limit=8"
        with self.assertRaisesRegex(file_patch.FilePatchError, "different content"):
            file_patch.execute(arguments)

    def test_create_uses_exclusive_target_and_returns_deletion_credential(self):
        created = self.root / "created.conf"
        result = file_patch.execute(
            {
                "action": "create",
                "path": str(created),
                "content": "secret=false\n",
                "mode": "0600",
                "apply": True,
            }
        )
        credential = result["deletion_credential"]
        self.assertEqual(credential["path"], str(created))
        self.assertEqual(credential["sha256"], hashlib.sha256(created.read_bytes()).hexdigest())
        self.assertTrue(credential["inode"].isdigit())
        self.assertTrue(credential["device"].isdigit())
        with self.assertRaisesRegex(file_patch.FilePatchError, "already exists"):
            file_patch.execute(
                {
                    "action": "create",
                    "path": str(created),
                    "content": "overwrite\n",
                    "apply": True,
                }
            )

    def test_legacy_single_replacement_remains_supported(self):
        result = file_patch.execute(
            {
                "path": str(self.target),
                "find": "one=1",
                "replacement": "one=3",
                "expected_count": 1,
                "apply": False,
            }
        )
        self.assertEqual(result["status"], "previewed")
        self.assertEqual(result["expected_count"], 1)
        self.assertEqual(result["actual_count"], 1)
        self.assertEqual(self.target.read_text(encoding="utf-8"), "one=1\ntwo=2\n")

    def test_symbolic_link_component_is_rejected(self):
        outside = self.root / "outside"
        outside.mkdir()
        linked = self.root / "linked"
        linked.symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(file_patch.FilePatchError, "symbolic"):
            file_patch.execute(
                {
                    "action": "create",
                    "path": str(linked / "new.conf"),
                    "content": "x",
                    "apply": True,
                }
            )

    def patch_arguments(self):
        return {
            "action": "patch",
            "path": str(self.target),
            "expected_sha256": self.digest(),
            "apply": True,
            "operations": [
                {"find": "one=1", "replacement": "one=10", "expected_count": 1}
            ],
        }

    def test_replace_failure_preserves_original_and_removes_backup(self):
        original = self.target.read_bytes()
        with mock.patch.object(file_patch.os, "replace", side_effect=OSError("replace failed")):
            with self.assertRaisesRegex(OSError, "replace failed"):
                file_patch.execute(self.patch_arguments())
        self.assertEqual(original, self.target.read_bytes())
        self.assertEqual([], list(self.root.glob("app.conf.bak.*")))

    def test_directory_fsync_failure_restores_original_and_keeps_backup(self):
        original = self.target.read_bytes()
        real_fsync_directory = file_patch._fsync_directory
        calls = 0

        def fail_after_replace(directory):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise OSError("directory fsync failed")
            return real_fsync_directory(directory)

        with mock.patch.object(file_patch, "_fsync_directory", side_effect=fail_after_replace):
            with self.assertRaisesRegex(file_patch.FilePatchError, "original content restored"):
                file_patch.execute(self.patch_arguments())
        self.assertEqual(original, self.target.read_bytes())
        self.assertEqual(1, len(list(self.root.glob("app.conf.bak.*"))))

    def test_create_directory_fsync_failure_removes_target(self):
        target = self.root / "new.conf"
        real_fsync_directory = file_patch._fsync_directory
        calls = 0

        def fail_first(directory):
            nonlocal calls
            calls += 1
            if calls == 1:
                raise OSError("directory fsync failed")
            return real_fsync_directory(directory)

        with mock.patch.object(file_patch, "_fsync_directory", side_effect=fail_first):
            with self.assertRaisesRegex(file_patch.FilePatchError, "target was removed"):
                file_patch.execute(
                    {
                        "action": "create",
                        "path": str(target),
                        "content": "secret=false\n",
                        "apply": True,
                    }
                )
        self.assertFalse(target.exists())

    def test_concurrent_patch_with_same_cas_commits_once(self):
        arguments = self.patch_arguments()
        barrier = threading.Barrier(2)
        original_read = file_patch._read_existing
        initial_reads = 0
        initial_lock = threading.Lock()

        def synchronized_read(path, maximum):
            nonlocal initial_reads
            result = original_read(path, maximum)
            with initial_lock:
                initial_reads += 1
                should_wait = initial_reads <= 2
            if should_wait:
                barrier.wait(timeout=2)
            return result

        def apply_patch():
            try:
                return file_patch.execute(dict(arguments))["status"]
            except file_patch.FilePatchError as exc:
                return exc.status

        # Synchronize the pre-lock reads. The per-target lock then permits one
        # commit and forces the other writer to fail its in-lock CAS check.
        with mock.patch.object(file_patch, "_read_existing", side_effect=synchronized_read):
            with ThreadPoolExecutor(max_workers=2) as executor:
                statuses = list(executor.map(lambda _index: apply_patch(), range(2)))
        self.assertEqual(["patched", "target_changed"], sorted(statuses))
        self.assertEqual("one=10\ntwo=2\n", self.target.read_text(encoding="utf-8"))
        self.assertEqual(1, len(list(self.root.glob("app.conf.bak.*"))))


if __name__ == "__main__":
    unittest.main()
