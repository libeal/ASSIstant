#!/usr/bin/env python3

import sys
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "web"))

import authentication  # noqa: E402
from authentication import BootstrapCredential  # noqa: E402


class BootstrapTokenTests(unittest.TestCase):
    def test_bootstrap_is_single_use_and_constant_time_checked(self):
        bootstrap = BootstrapCredential(clock=lambda: 100.0)
        with mock.patch.object(authentication.secrets, "token_urlsafe", return_value="bootstrap-secret"):
            self.assertEqual("bootstrap-secret", bootstrap.issue(ttl_seconds=10))
        with mock.patch.object(
            authentication.secrets,
            "compare_digest",
            wraps=authentication.secrets.compare_digest,
        ) as compare_digest:
            self.assertEqual("", bootstrap.consume("wrong", "api-token"))
            self.assertEqual("api-token", bootstrap.consume("bootstrap-secret", "api-token"))
            self.assertEqual("", bootstrap.consume("bootstrap-secret", "api-token"))
        self.assertEqual(2, compare_digest.call_count)

    def test_bootstrap_expires_before_consumption(self):
        now = [100.0]
        bootstrap = BootstrapCredential(clock=lambda: now[0])
        bootstrap.issue(ttl_seconds=10)
        now[0] = 111.0
        self.assertEqual("", bootstrap.consume("expired", "api-token"))

    def test_bootstrap_rejects_non_positive_lifetime(self):
        bootstrap = BootstrapCredential()
        with self.assertRaisesRegex(ValueError, "lifetime must be positive"):
            bootstrap.issue(ttl_seconds=0)


if __name__ == "__main__":
    unittest.main()
