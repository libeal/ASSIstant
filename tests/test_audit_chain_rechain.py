#!/usr/bin/env python3

import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))

import audit_chain  # noqa: E402


class AuditRechainTests(unittest.TestCase):
    def test_root_only_inherits_log_directory_owner_for_new_audit_inodes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            log = root / "session.jsonl"
            owner = root.stat()
            with mock.patch.object(audit_chain.os, "geteuid", return_value=0), mock.patch.object(
                audit_chain.os, "fchown"
            ) as fchown:
                descriptor = audit_chain._open_log(log)
                try:
                    fchown.assert_called_once_with(
                        descriptor, owner.st_uid, owner.st_gid
                    )
                finally:
                    audit_chain.os.close(descriptor)

            with mock.patch.object(audit_chain.os, "geteuid", return_value=0), mock.patch.object(
                audit_chain.os, "fchown"
            ) as fchown:
                descriptor = audit_chain._open_log(log)
                try:
                    fchown.assert_not_called()
                finally:
                    audit_chain.os.close(descriptor)

    def test_redacted_rotated_snapshot_can_be_rechained_and_verified(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            live = root / "session.jsonl"
            for index in range(1, 5):
                audit_chain.append_event(
                    live,
                    {
                        "stage": "event",
                        "payload": {"index": index, "secret": f"secret-{index}"},
                    },
                    max_bytes=160,
                )
            self.assertTrue(audit_chain.verify_chain(live)["ok"])

            snapshot_dir = root / "snapshot"
            snapshot_dir.mkdir()
            snapshot_live = Path(audit_chain.snapshot_chain(live, snapshot_dir))
            rotations = sorted(
                (
                    path
                    for path in snapshot_dir.glob(f"{snapshot_live.name}.*")
                    if path.name.rsplit(".", 1)[-1].isdigit()
                ),
                key=lambda path: int(path.name.rsplit(".", 1)[-1]),
            )
            segments = rotations + [snapshot_live]
            for segment in segments:
                redacted = []
                for line in segment.read_text(encoding="utf-8").splitlines():
                    event = json.loads(line)
                    event["payload"]["secret"] = "[REDACTED]"
                    redacted.append(json.dumps(event, ensure_ascii=False) + "\n")
                segment.write_text("".join(redacted), encoding="utf-8")

            self.assertFalse(audit_chain.verify_chain(snapshot_live)["ok"])
            result = audit_chain.rechain_snapshot(snapshot_live)
            self.assertEqual(result["status"], "rechained")
            self.assertTrue(audit_chain.verify_chain(snapshot_live)["ok"])
            self.assertGreaterEqual(result["segments"], 3)
            for segment in segments:
                self.assertNotIn("secret-", segment.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
