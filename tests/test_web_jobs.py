#!/usr/bin/env python3
"""Unit tests for the durable Web Job store."""

import json
import sqlite3
import stat
import sys
import tempfile
import threading
import unittest
from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WEB_ROOT = ROOT / "web"
if str(WEB_ROOT) not in sys.path:
    sys.path.insert(0, str(WEB_ROOT))

from jobs import (  # noqa: E402
    IdempotencyConflict,
    JobCapacityExceeded,
    JobStore,
    JobVersionConflict,
    LegacyJobMigrationError,
    canonical_request_fingerprint,
)


def job_record(job_id, payload=None, **overrides):
    record = {
        "ok": True,
        "job_id": job_id,
        "resource": "work",
        "action": "run",
        "status": "queued",
        "version": 0,
        "created_at": "2026-07-15T00:00:00Z",
        "updated_at": "2026-07-15T00:00:00Z",
        "request_id": f"request-{job_id}",
        "session_id": f"job_{job_id}",
        "payload": {"input": "inspect", "options": {"b": 2, "a": 1}}
        if payload is None
        else payload,
        "result": None,
        "result_ok": None,
        "result_status": None,
    }
    record.update(overrides)
    return record


class JobStoreTest(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.db_path = Path(self.temp_dir.name) / "jobs.db"
        self.store = JobStore(self.db_path)

    def test_schema_uses_wal_and_persists_lifecycle_columns(self):
        required = {
            "job_id",
            "status",
            "version",
            "idempotency_key",
            "request_fingerprint",
            "retry_of",
            "root_job_id",
            "attempt",
            "max_attempts",
            "cancel_requested_at",
            "record",
        }
        with closing(sqlite3.connect(self.db_path)) as connection:
            journal_mode = connection.execute("PRAGMA journal_mode").fetchone()[0]
            columns = {row[1] for row in connection.execute("PRAGMA table_info(jobs)")}
        self.assertEqual("wal", journal_mode.lower())
        self.assertTrue(required <= columns, required - columns)
        self.assertEqual(0o600, stat.S_IMODE(self.db_path.stat().st_mode))

    def test_wal_mode_is_required_not_best_effort(self):
        class Cursor:
            @staticmethod
            def fetchone():
                return ("delete",)

        class Connection:
            @staticmethod
            def execute(_statement):
                return Cursor()

        with self.assertRaisesRegex(sqlite3.DatabaseError, "WAL mode is required"):
            JobStore._enable_wal(Connection())

    def test_same_canonical_request_is_deduplicated(self):
        first, deduplicated = self.store.create(
            job_record("a1"),
            idempotency_key="same-request",
        )
        self.assertFalse(deduplicated)

        reordered_payload = {"options": {"a": 1, "b": 2}, "input": "inspect"}
        second, deduplicated = self.store.create(
            job_record("a2", payload=reordered_payload),
            idempotency_key="same-request",
        )
        self.assertTrue(deduplicated)
        self.assertEqual(first["job_id"], second["job_id"])
        self.assertEqual(
            canonical_request_fingerprint("work", "run", reordered_payload),
            second["request_fingerprint"],
        )

    def test_different_request_with_same_key_conflicts(self):
        first, _ = self.store.create(
            job_record("b1"),
            idempotency_key="conflicting-request",
        )
        with self.assertRaises(IdempotencyConflict) as raised:
            self.store.create(
                job_record("b2", payload={"input": "different"}),
                idempotency_key="conflicting-request",
            )
        self.assertEqual("b1", raised.exception.existing_job_id)
        self.assertEqual("conflicting-request", raised.exception.idempotency_key)
        self.assertEqual(first["request_fingerprint"], raised.exception.existing_fingerprint)

    def test_admit_deduplicates_before_enforcing_capacity(self):
        first, deduplicated = self.store.admit(
            job_record("capacity-a1"),
            idempotency_key="capacity-replay",
            max_active=1,
        )
        self.assertFalse(deduplicated)

        replay, deduplicated = self.store.admit(
            job_record("capacity-a2"),
            idempotency_key="capacity-replay",
            max_active=1,
        )
        self.assertTrue(deduplicated)
        self.assertEqual(first["job_id"], replay["job_id"])

        with self.assertRaises(JobCapacityExceeded) as raised:
            self.store.admit(
                job_record("capacity-a3"),
                idempotency_key="capacity-new",
                max_active=1,
            )
        self.assertEqual(1, raised.exception.active)
        self.assertEqual(1, raised.exception.max_active)

    def test_admit_is_atomic_across_store_instances(self):
        other_store = JobStore(self.db_path)
        barrier = threading.Barrier(2)

        def admit(store, job_id):
            barrier.wait(timeout=5)
            try:
                admitted, deduplicated = store.admit(
                    job_record(job_id),
                    idempotency_key=f"key-{job_id}",
                    max_active=1,
                )
                return "admitted", admitted["job_id"], deduplicated
            except JobCapacityExceeded as exc:
                return "capacity", exc.active, exc.max_active

        with ThreadPoolExecutor(max_workers=2) as executor:
            results = list(
                executor.map(
                    lambda arguments: admit(*arguments),
                    ((self.store, "capacity-b1"), (other_store, "capacity-b2")),
                )
            )

        self.assertEqual(1, sum(result[0] == "admitted" for result in results))
        self.assertEqual(1, sum(result[0] == "capacity" for result in results))
        capacity_result = next(result for result in results if result[0] == "capacity")
        self.assertEqual(("capacity", 1, 1), capacity_result)
        self.assertEqual(1, self.store.count_active())

    def test_update_increments_version_only_when_mutated(self):
        created, _ = self.store.create(job_record("c1"))
        self.assertEqual(0, created["version"])

        updated = self.store.update("c1", lambda record: record.update(status="running"))
        self.assertEqual("running", updated["status"])
        self.assertEqual(1, updated["version"])

        unchanged = self.store.update("c1", lambda _record: False)
        self.assertEqual(1, unchanged["version"])
        self.assertEqual(1, self.store.read("c1")["version"])

        with self.assertRaises(JobVersionConflict) as raised:
            self.store.update(
                "c1",
                lambda record: record.update(status="failed"),
                expected_version=0,
            )
        self.assertEqual(0, raised.exception.expected_version)
        self.assertEqual(1, raised.exception.actual_version)
        self.assertEqual("running", self.store.read("c1")["status"])

    def test_recover_interrupted_uses_durable_completion_or_restart_failure(self):
        self.store.create(job_record("c4", status="running", version=3))
        self.store.create(job_record("c5", status="queued", version=1))
        self.store.create(job_record("c6", status="succeeded", version=2))
        completed_result = {"ok": True, "status": "executed", "answer": "done"}

        recovered = self.store.recover_interrupted(
            lambda job_id: (
                {
                    "result": completed_result,
                    "completed_at": "2026-07-15T00:02:00Z",
                }
                if job_id == "c4"
                else None
            )
        )

        self.assertEqual({"c4", "c5"}, {job["job_id"] for job in recovered})
        completed = self.store.read("c4")
        self.assertEqual("succeeded", completed["status"])
        self.assertEqual(completed_result, completed["result"])
        self.assertEqual("durable_session_completion", completed["recovery_source"])
        self.assertEqual("2026-07-15T00:02:00Z", completed["finished_at"])
        self.assertEqual(4, completed["version"])
        interrupted = self.store.read("c5")
        self.assertEqual("failed", interrupted["status"])
        self.assertEqual("server_restarted", interrupted["result_status"])
        self.assertEqual(
            "interrupted_without_completion",
            interrupted["recovery_source"],
        )
        self.assertEqual(2, interrupted["version"])
        self.assertEqual("succeeded", self.store.read("c6")["status"])

    def test_recover_interrupted_rolls_back_all_jobs_for_invalid_completion(self):
        self.store.create(job_record("c7", status="running"))
        self.store.create(job_record("c8", status="queued"))

        with self.assertRaisesRegex(ValueError, "must contain a result object"):
            self.store.recover_interrupted(
                lambda job_id: {"result": "invalid"} if job_id == "c8" else None
            )

        self.assertEqual("running", self.store.read("c7")["status"])
        self.assertEqual("queued", self.store.read("c8")["status"])

    def test_cleanup_retains_terminal_jobs_with_pending_audit_delivery(self):
        self.store.create(
            job_record(
                "c2",
                status="succeeded",
                audit_state="pending",
                audit_error="audit temporarily unavailable",
            )
        )
        self.store.create(job_record("c3", status="succeeded", audit_state="complete"))

        self.assertEqual(["c3"], self.store.cleanup(0))
        pending = self.store.list_audit_pending()
        self.assertEqual(["c2"], [record["job_id"] for record in pending])
        self.assertEqual("pending", self.store.read("c2")["audit_state"])
        self.assertIsNone(self.store.read("c3"))

    def test_legacy_record_only_table_is_migrated_without_losing_values(self):
        legacy_db_path = Path(self.temp_dir.name) / "legacy.db"
        legacy = job_record(
            "d2",
            version=7,
            status="failed",
            idempotency_key="legacy-key",
            retry_of="d1",
            root_job_id="d0",
            attempt=2,
            max_attempts=4,
            cancel_requested_at="2026-07-15T00:01:00Z",
        )
        with closing(sqlite3.connect(legacy_db_path)) as connection, connection:
            connection.execute(
                "CREATE TABLE jobs (job_id TEXT PRIMARY KEY, record TEXT NOT NULL)"
            )
            connection.execute(
                "INSERT INTO jobs(job_id, record) VALUES (?, ?)",
                (legacy["job_id"], json.dumps(legacy, separators=(",", ":"))),
            )

        migrated_store = JobStore(legacy_db_path)
        migrated = migrated_store.read("d2")
        self.assertEqual(7, migrated["version"])
        self.assertEqual("legacy-key", migrated["idempotency_key"])
        self.assertEqual("d1", migrated["retry_of"])
        self.assertEqual("d0", migrated["root_job_id"])
        self.assertEqual(2, migrated["attempt"])
        self.assertEqual(4, migrated["max_attempts"])
        self.assertEqual("2026-07-15T00:01:00Z", migrated["cancel_requested_at"])
        self.assertEqual(
            canonical_request_fingerprint("work", "run", legacy["payload"]),
            migrated["request_fingerprint"],
        )

    def test_real_file_per_job_records_are_migrated_and_archived(self):
        legacy_dir = Path(self.temp_dir.name) / "legacy-jobs"
        legacy_dir.mkdir()
        legacy_path = legacy_dir / "deadbeef.json"
        legacy_path.write_text(
            json.dumps(
                {
                    "ok": True,
                    "job_id": "deadbeef",
                    "resource": "terminal",
                    "action": "run",
                    "status": "running",
                    "version": 4,
                    "created_at": "2026-07-15T00:00:00Z",
                    "updated_at": "2026-07-15T00:01:00Z",
                    "result": None,
                    "result_ok": None,
                    "result_status": None,
                },
                separators=(",", ":"),
            ),
            encoding="utf-8",
        )
        db_path = Path(self.temp_dir.name) / "migrated.db"

        migrated_store = JobStore(db_path, legacy_jobs_dir=legacy_dir)
        migrated = migrated_store.read("deadbeef")

        self.assertEqual("running", migrated["status"])
        self.assertEqual(4, migrated["version"])
        self.assertEqual({}, migrated["payload"])
        self.assertEqual("legacy-deadbeef", migrated["request_id"])
        self.assertEqual("legacy_job_deadbeef", migrated["session_id"])
        self.assertEqual("deadbeef.json", migrated["legacy_source_file"])
        self.assertFalse(legacy_path.exists())
        self.assertTrue((legacy_dir / "deadbeef.json.migrated").is_file())
        self.assertEqual(["deadbeef"], [job["job_id"] for job in migrated_store.list_active()])

        reopened = JobStore(db_path, legacy_jobs_dir=legacy_dir)
        self.assertEqual("running", reopened.read("deadbeef")["status"])

    def test_corrupt_legacy_file_aborts_the_whole_migration(self):
        legacy_dir = Path(self.temp_dir.name) / "corrupt-legacy"
        legacy_dir.mkdir()
        (legacy_dir / "a1.json").write_text(
            json.dumps(job_record("a1"), separators=(",", ":")),
            encoding="utf-8",
        )
        (legacy_dir / "b2.json").write_text("{broken", encoding="utf-8")
        db_path = Path(self.temp_dir.name) / "corrupt.db"

        with self.assertRaisesRegex(LegacyJobMigrationError, "invalid legacy Job file"):
            JobStore(db_path, legacy_jobs_dir=legacy_dir)

        with closing(sqlite3.connect(db_path)) as connection:
            self.assertEqual(0, connection.execute("SELECT COUNT(*) FROM jobs").fetchone()[0])
        self.assertTrue((legacy_dir / "a1.json").is_file())
        self.assertFalse((legacy_dir / "a1.json.migrated").exists())

    def test_legacy_file_conflict_is_explicit_and_preserves_source(self):
        legacy_dir = Path(self.temp_dir.name) / "conflicting-legacy"
        legacy_dir.mkdir()
        db_path = Path(self.temp_dir.name) / "conflicting.db"
        store = JobStore(db_path, legacy_jobs_dir=legacy_dir)
        store.create(job_record("cafe", status="failed"))
        source = legacy_dir / "cafe.json"
        source.write_text(
            json.dumps(
                {
                    "job_id": "cafe",
                    "resource": "work",
                    "action": "run",
                    "status": "succeeded",
                    "version": 1,
                    "created_at": "2026-07-15T00:00:00Z",
                    "updated_at": "2026-07-15T00:02:00Z",
                },
                separators=(",", ":"),
            ),
            encoding="utf-8",
        )

        with self.assertRaisesRegex(LegacyJobMigrationError, "conflicts"):
            JobStore(db_path, legacy_jobs_dir=legacy_dir)
        self.assertTrue(source.is_file())
        self.assertEqual("failed", store.read("cafe")["status"])


if __name__ == "__main__":
    unittest.main()
