import hashlib
import json
import os
import stat
import tempfile
import unittest
from pathlib import Path

from lib.provider_resilience import CircuitStore


class CircuitStoreTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.path = Path(self.temp_dir.name) / "shared" / "provider-circuits.json"
        self.now = [100.0]
        self.store = CircuitStore(self.path, clock=lambda: self.now[0])
        self.endpoint = "https://provider.example/v1/chat/completions"
        self.key = hashlib.sha256(f"openai\0{self.endpoint}".encode()).hexdigest()

    def test_opens_half_opens_and_closes(self):
        self.assertEqual(self.store.allow(self.key, 2, 30)["state"], "closed")
        self.assertEqual(self.store.record_failure(self.key, 2, 30)["state"], "closed")
        self.assertEqual(self.store.record_failure(self.key, 2, 30)["state"], "open")

        blocked = self.store.allow(self.key, 2, 30)
        self.assertFalse(blocked["allowed"])
        self.assertEqual(blocked["state"], "open")

        self.now[0] += 31
        probe = self.store.allow(self.key, 2, 30)
        self.assertTrue(probe["allowed"])
        self.assertEqual(probe["state"], "half_open")
        self.assertEqual(self.store.allow(self.key, 2, 30)["state"], "half_open_busy")

        self.assertEqual(self.store.record_success(self.key)["state"], "closed")
        self.assertEqual(self.store.allow(self.key, 2, 30)["state"], "closed")

    def test_half_open_failure_reopens_the_circuit(self):
        self.store.record_failure(self.key, 1, 10)
        self.now[0] += 11
        self.assertEqual(self.store.allow(self.key, 1, 10)["state"], "half_open")
        self.assertEqual(self.store.record_failure(self.key, 1, 10)["state"], "open")
        self.assertFalse(self.store.allow(self.key, 1, 10)["allowed"])

    def test_state_is_private_and_contains_only_hashed_endpoint_identity(self):
        self.store.record_failure(self.key, 1, 30)
        mode = stat.S_IMODE(os.stat(self.path).st_mode)
        self.assertEqual(mode, 0o600)
        payload = self.path.read_text(encoding="utf-8")
        self.assertNotIn(self.endpoint, payload)
        self.assertIn(self.key, json.loads(payload)["circuits"])

    def test_symbolic_link_state_directory_is_rejected(self):
        outside = Path(self.temp_dir.name) / "outside"
        outside.mkdir()
        self.path.parent.parent.mkdir(parents=True, exist_ok=True)
        self.path.parent.symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(OSError, "symbolic link"):
            self.store.record_failure(self.key, 1, 30)
        self.assertEqual([], list(outside.iterdir()))

    def test_existing_permissive_state_directory_is_rejected_without_chmod(self):
        self.path.parent.mkdir(parents=True)
        self.path.parent.chmod(0o755)
        with self.assertRaisesRegex(OSError, "mode 0700"):
            self.store.record_failure(self.key, 1, 30)
        self.assertEqual(0o755, stat.S_IMODE(self.path.parent.stat().st_mode))


if __name__ == "__main__":
    unittest.main()
