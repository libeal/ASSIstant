#!/usr/bin/env python3

import json
import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "skills" / "controlled-tools" / "scripts" / "file-download.sh"


FAKE_PINNED_HTTP = r'''
import os


class PinnedHTTPPolicyError(ValueError):
    def __init__(self, code, message, *, url="", address=""):
        super().__init__(message)
        self.code = code
        self.url = url
        self.address = address


class Response:
    def __init__(self, payload):
        self.payload = payload
        self.offset = 0
        self.headers = {"Content-Length": str(len(payload))}

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

    def read(self, size=-1):
        if size < 0:
            size = len(self.payload) - self.offset
        chunk = self.payload[self.offset:self.offset + size]
        self.offset += len(chunk)
        return chunk


_fault = os.environ.get("LINUX_AGENT_DOWNLOAD_FAULT", "")
_original_fsync = os.fsync
_original_replace = os.replace
_fsync_calls = 0
_replace_calls = 0


def _faulting_fsync(descriptor):
    global _fsync_calls
    _fsync_calls += 1
    failure_call = {
        "existing_fsync": 3,
        "new_fsync": 2,
        "rollback_replace": 3,
        "cleanup_fsync": 4,
    }.get(_fault)
    if failure_call == _fsync_calls:
        raise OSError(f"injected fsync failure {_fsync_calls}")
    return _original_fsync(descriptor)


def _faulting_replace(source, target):
    global _replace_calls
    _replace_calls += 1
    if _fault == "rollback_replace" and _replace_calls == 2:
        raise OSError("injected rollback replace failure")
    return _original_replace(source, target)


os.fsync = _faulting_fsync
os.replace = _faulting_replace


def open_public_https(url, **_kwargs):
    payload = os.environ.get("LINUX_AGENT_DOWNLOAD_PAYLOAD", "new-content").encode()
    return Response(payload), url, ("203.0.113.10",), (url,)
'''


class FileDownloadTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        library = self.root / "runtime" / "lib"
        library.mkdir(parents=True)
        (library / "pinned_http.py").write_text(
            textwrap.dedent(FAKE_PINNED_HTTP), encoding="utf-8"
        )
        self.runtime_root = library.parent
        self.target = self.root / "download.bin"

    def tearDown(self):
        self.temp.cleanup()

    def run_download(self, fault="", output_path=None, create_parent=False):
        environment = os.environ.copy()
        environment.update(
            {
                "LINUX_AGENT_ROOT": str(self.runtime_root),
                "LINUX_AGENT_DOWNLOAD_PAYLOAD": "new-content",
                "LINUX_AGENT_DOWNLOAD_FAULT": fault,
            }
        )
        completed = subprocess.run(
            [
                "bash",
                str(SCRIPT),
                json.dumps(
                    {
                        "url": "https://download.example/file",
                        "output_path": str(output_path or self.target),
                        "overwrite": True,
                        "create_parent": create_parent,
                    }
                ),
            ],
            capture_output=True,
            text=True,
            env=environment,
            check=False,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        return json.loads(completed.stdout)

    def test_existing_target_is_restored_when_directory_fsync_fails(self):
        self.target.write_text("old-content", encoding="utf-8")

        result = self.run_download("existing_fsync")

        self.assertFalse(result["ok"])
        self.assertEqual(result["status"], "write_error")
        self.assertEqual(result["persistence"], "rolled_back")
        self.assertEqual(self.target.read_text(), "old-content")
        recovery = Path(result["recovery_path"])
        self.assertTrue(recovery.is_file())
        self.assertEqual(recovery.read_text(), "old-content")

    def test_new_target_is_removed_when_directory_fsync_fails(self):
        result = self.run_download("new_fsync")

        self.assertFalse(result["ok"])
        self.assertEqual(result["persistence"], "rolled_back")
        self.assertFalse(self.target.exists())
        self.assertNotIn("recovery_path", result)

    def test_failed_rollback_retains_a_recovery_copy(self):
        self.target.write_text("old-content", encoding="utf-8")

        result = self.run_download("rollback_replace")

        self.assertFalse(result["ok"])
        self.assertEqual(result["persistence"], "unknown")
        self.assertIn("rollback_error", result)
        recovery = Path(result["recovery_path"])
        self.assertEqual(recovery.read_text(), "old-content")
        self.assertEqual(self.target.read_text(), "new-content")

    def test_success_does_not_report_a_deleted_backup_as_recovery(self):
        self.target.write_text("old-content", encoding="utf-8")

        result = self.run_download("cleanup_fsync")

        self.assertTrue(result["ok"], result)
        self.assertTrue(result["backup_cleanup_pending"])
        self.assertNotIn("recovery_path", result)
        self.assertEqual(self.target.read_text(), "new-content")

    def test_broken_output_symlink_is_rejected(self):
        self.target.symlink_to(self.root / "missing-target")

        result = self.run_download()

        self.assertFalse(result["ok"])
        self.assertEqual(result["status"], "unsupported_path")
        self.assertTrue(self.target.is_symlink())

    def test_parent_symlink_is_rejected(self):
        real_parent = self.root / "real-parent"
        real_parent.mkdir()
        linked_parent = self.root / "linked-parent"
        linked_parent.symlink_to(real_parent, target_is_directory=True)

        result = self.run_download(output_path=linked_parent / "download.bin")

        self.assertFalse(result["ok"])
        self.assertEqual(result["status"], "unsupported_path")
        self.assertFalse((real_parent / "download.bin").exists())

    def test_create_parent_rejects_symlink_component(self):
        real_parent = self.root / "real-parent"
        real_parent.mkdir()
        linked_parent = self.root / "linked-parent"
        linked_parent.symlink_to(real_parent, target_is_directory=True)

        result = self.run_download(
            output_path=linked_parent / "nested" / "download.bin",
            create_parent=True,
        )

        self.assertFalse(result["ok"])
        self.assertEqual(result["status"], "unsupported_path")
        self.assertFalse((real_parent / "nested" / "download.bin").exists())

    def test_parent_file_is_rejected(self):
        parent_file = self.root / "parent-file"
        parent_file.write_text("not a directory", encoding="utf-8")

        result = self.run_download(output_path=parent_file / "download.bin")

        self.assertFalse(result["ok"])
        self.assertEqual(result["status"], "unsupported_path")


if __name__ == "__main__":
    unittest.main()
