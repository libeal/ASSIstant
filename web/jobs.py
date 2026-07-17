"""SQLite(WAL)-backed job persistence for the Web console.

The public API intentionally deals in dictionaries so the HTTP layer does not
need to know about the storage schema.  The complete dictionary is retained in
``record`` for forward-compatible fields, while fields used by lifecycle and
history queries are mirrored into explicit columns in the same transaction.
"""

import hashlib
import json
import os
import re
import sqlite3
import stat
import threading
import time
from contextlib import contextmanager
from pathlib import Path

JOB_ACTIVE_STATUSES = ("queued", "running")
DEFAULT_JOB_STATUSES = frozenset({"queued", "running", "succeeded", "failed", "cancelled"})
LEGACY_JOB_FILE = re.compile(r"^(?P<job_id>[0-9a-f]+)\.json$")
LEGACY_JOB_MAX_BYTES = 16 * 1024 * 1024

_SELECT_COLUMNS = """
    job_id, status, resource, action, version, created_at, started_at,
    finished_at, updated_at, idempotency_key, request_fingerprint, request_id,
    session_id, retry_of, root_job_id, attempt, max_attempts,
    cancel_requested_at, payload, result, partial_output, result_ok,
    result_status, record
"""

_COLUMN_DEFINITIONS = {
    "job_id": "TEXT PRIMARY KEY",
    "status": "TEXT NOT NULL DEFAULT ''",
    "resource": "TEXT NOT NULL DEFAULT ''",
    "action": "TEXT NOT NULL DEFAULT ''",
    "version": "INTEGER NOT NULL DEFAULT 0",
    "created_at": "TEXT NOT NULL DEFAULT ''",
    "started_at": "TEXT",
    "finished_at": "TEXT",
    "updated_at": "TEXT NOT NULL DEFAULT ''",
    "idempotency_key": "TEXT",
    "request_fingerprint": "TEXT",
    "request_id": "TEXT",
    "session_id": "TEXT",
    "retry_of": "TEXT",
    "root_job_id": "TEXT",
    "attempt": "INTEGER NOT NULL DEFAULT 1",
    "max_attempts": "INTEGER NOT NULL DEFAULT 1",
    "cancel_requested_at": "TEXT",
    "payload": "JSON",
    "result": "JSON",
    "partial_output": "JSON",
    "result_ok": "INTEGER",
    "result_status": "TEXT",
    # Kept for fields added by the HTTP API without a database migration.
    "record": "TEXT NOT NULL DEFAULT '{}'",
}


class IdempotencyConflict(ValueError):
    """Raised when one idempotency key is reused for a different request."""

    def __init__(self, idempotency_key, existing_job_id, existing_fingerprint, request_fingerprint):
        self.idempotency_key = str(idempotency_key)
        self.existing_job_id = str(existing_job_id)
        self.existing_fingerprint = str(existing_fingerprint)
        self.request_fingerprint = str(request_fingerprint)
        super().__init__(
            f"idempotency key {self.idempotency_key!r} is already bound to "
            f"job {self.existing_job_id} with a different request"
        )


class JobCapacityExceeded(RuntimeError):
    """Raised when admitting another active Job would exceed the limit."""

    def __init__(self, active, max_active):
        self.active = int(active)
        self.max_active = int(max_active)
        super().__init__(
            f"active job limit reached: {self.active} active, maximum {self.max_active}"
        )


class JobVersionConflict(RuntimeError):
    """Raised when a caller updates a stale Job representation."""

    def __init__(self, job_id, expected_version, actual_version):
        self.job_id = str(job_id)
        self.expected_version = int(expected_version)
        self.actual_version = int(actual_version)
        super().__init__(
            f"job {self.job_id} version conflict: expected {self.expected_version}, "
            f"actual {self.actual_version}"
        )


class LegacyJobMigrationError(RuntimeError):
    """Raised when the former file-per-Job store cannot be migrated safely."""


def canonical_request_fingerprint(resource, action, payload):
    """Hash the canonical JSON representation of a Job's request identity."""

    canonical = json.dumps(
        {
            "action": str(action or ""),
            "payload": payload,
            "resource": str(resource or ""),
        },
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=False,
    )
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _json_dump(value):
    if value is None:
        return None
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def _json_load(value):
    if value is None:
        return None
    try:
        return json.loads(value)
    except (TypeError, json.JSONDecodeError):
        return None


class JobStore:
    def __init__(
        self,
        db_path,
        allowed_statuses=None,
        schema_version=1,
        legacy_jobs_dir=None,
    ):
        self._db_path = Path(db_path)
        self._legacy_jobs_dir = Path(
            legacy_jobs_dir
            if legacy_jobs_dir is not None
            else self._db_path.parent / "jobs"
        )
        self._allowed_statuses = frozenset(allowed_statuses or DEFAULT_JOB_STATUSES)
        if not self._allowed_statuses:
            raise ValueError("allowed_statuses must not be empty")
        self._schema_version = max(1, int(schema_version))
        self._locks = {}
        self._locks_guard = threading.Lock()
        self._db_path.parent.mkdir(parents=True, exist_ok=True)
        self._create_database_file()
        self._initialize_schema()
        self._migrate_legacy_json_jobs()

    def _create_database_file(self):
        """Create the database without relying on the caller's umask."""
        fd = os.open(str(self._db_path), os.O_CREAT | os.O_RDWR, 0o600)
        os.close(fd)
        os.chmod(self._db_path, 0o600)

    def _secure_database_files(self):
        # SQLite creates WAL/SHM lazily.  Tighten any sidecars present after an
        # operation as well as the main database file.
        for path in (
            self._db_path,
            Path(f"{self._db_path}-wal"),
            Path(f"{self._db_path}-shm"),
        ):
            try:
                os.chmod(path, 0o600)
            except FileNotFoundError:
                pass

    def _connect(self):
        conn = sqlite3.connect(str(self._db_path), timeout=10)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA busy_timeout=5000")
        conn.execute("PRAGMA synchronous=NORMAL")
        self._secure_database_files()
        return conn

    @contextmanager
    def _connection(self):
        conn = self._connect()
        try:
            yield conn
        finally:
            conn.close()
            self._secure_database_files()

    @contextmanager
    def _immediate_transaction(self):
        with self._connection() as conn:
            try:
                conn.execute("BEGIN IMMEDIATE")
                yield conn
                conn.commit()
            except Exception:
                conn.rollback()
                raise

    def _initialize_schema(self):
        with self._connection() as conn:
            self._enable_wal(conn)
            conn.execute("BEGIN IMMEDIATE")
            try:
                conn.execute(
                    """
                    CREATE TABLE IF NOT EXISTS jobs (
                        job_id TEXT PRIMARY KEY,
                        status TEXT NOT NULL DEFAULT '',
                        resource TEXT NOT NULL DEFAULT '',
                        action TEXT NOT NULL DEFAULT '',
                        version INTEGER NOT NULL DEFAULT 0,
                        created_at TEXT NOT NULL DEFAULT '',
                        started_at TEXT,
                        finished_at TEXT,
                        updated_at TEXT NOT NULL DEFAULT '',
                        idempotency_key TEXT,
                        request_fingerprint TEXT,
                        request_id TEXT,
                        session_id TEXT,
                        retry_of TEXT,
                        root_job_id TEXT,
                        attempt INTEGER NOT NULL DEFAULT 1,
                        max_attempts INTEGER NOT NULL DEFAULT 1,
                        cancel_requested_at TEXT,
                        payload JSON,
                        result JSON,
                        partial_output JSON,
                        result_ok INTEGER,
                        result_status TEXT,
                        record TEXT NOT NULL DEFAULT '{}'
                    )
                    """
                )
                added_columns = self._add_missing_columns(conn)
                if added_columns:
                    self._backfill_explicit_columns(conn, added_columns)
                self._normalize_existing_records(conn)
                conn.execute("CREATE INDEX IF NOT EXISTS idx_jobs_status ON jobs(status)")
                conn.execute("CREATE INDEX IF NOT EXISTS idx_jobs_updated_at ON jobs(updated_at)")
                conn.execute(
                    "CREATE UNIQUE INDEX IF NOT EXISTS idx_jobs_idempotency_key"
                    " ON jobs(idempotency_key) WHERE idempotency_key IS NOT NULL"
                )
                conn.commit()
            except Exception:
                conn.rollback()
                raise

    @staticmethod
    def _enable_wal(conn):
        row = conn.execute("PRAGMA journal_mode=WAL").fetchone()
        mode = str(row[0] if row else "").strip().lower()
        if mode != "wal":
            raise sqlite3.DatabaseError(
                f"SQLite WAL mode is required for Job storage; database returned {mode!r}"
            )

    @staticmethod
    def _fsync_directory(path):
        fd = os.open(str(path), os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(fd)
        finally:
            os.close(fd)

    def _legacy_job_files(self):
        try:
            entries = list(self._legacy_jobs_dir.iterdir())
        except FileNotFoundError:
            return []
        except OSError as exc:
            raise LegacyJobMigrationError(
                f"cannot inspect legacy Job directory {self._legacy_jobs_dir}: {exc}"
            ) from exc
        return sorted(
            (
                entry
                for entry in entries
                if LEGACY_JOB_FILE.fullmatch(entry.name) is not None
            ),
            key=lambda entry: entry.name,
        )

    def _read_legacy_job(self, path):
        match = LEGACY_JOB_FILE.fullmatch(path.name)
        if match is None:
            raise LegacyJobMigrationError(f"invalid legacy Job file name: {path}")
        try:
            file_stat = path.stat(follow_symlinks=False)
        except OSError as exc:
            raise LegacyJobMigrationError(f"cannot stat legacy Job file {path}: {exc}") from exc
        if not stat.S_ISREG(file_stat.st_mode) or path.is_symlink():
            raise LegacyJobMigrationError(
                f"legacy Job path must be a regular non-symlink file: {path}"
            )
        if file_stat.st_size > LEGACY_JOB_MAX_BYTES:
            raise LegacyJobMigrationError(
                f"legacy Job file exceeds {LEGACY_JOB_MAX_BYTES} bytes: {path}"
            )
        try:
            raw = path.read_bytes()
            legacy = json.loads(raw.decode("utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise LegacyJobMigrationError(f"invalid legacy Job file {path}: {exc}") from exc
        if not isinstance(legacy, dict):
            raise LegacyJobMigrationError(f"legacy Job must be a JSON object: {path}")

        job_id = match.group("job_id")
        embedded_job_id = str(legacy.get("job_id") or "")
        if embedded_job_id and embedded_job_id != job_id:
            raise LegacyJobMigrationError(
                f"legacy Job identity mismatch for {path}: found {embedded_job_id!r}"
            )
        digest = hashlib.sha256(raw).hexdigest()
        record = dict(legacy)
        record.update(
            {
                "schema_version": self._schema_version,
                "job_id": job_id,
                "request_id": str(record.get("request_id") or f"legacy-{job_id}"),
                "session_id": str(record.get("session_id") or f"legacy_job_{job_id}"),
                "payload": record.get("payload")
                if isinstance(record.get("payload"), dict)
                else {},
                "legacy_source_file": path.name,
                "legacy_record_sha256": digest,
            }
        )
        if not record.get("phase"):
            record["phase"] = (
                str(record.get("status") or "")
                if record.get("status") in JOB_ACTIVE_STATUSES
                else "terminal"
            )
        try:
            normalized, key = self._normalize_new_record(
                record,
                idempotency_key=record.get("idempotency_key"),
            )
        except (TypeError, ValueError) as exc:
            raise LegacyJobMigrationError(f"invalid legacy Job record {path}: {exc}") from exc
        return path, normalized, key, digest

    def _archive_migrated_legacy_file(self, path, digest):
        archive = path.with_name(f"{path.name}.migrated")
        if archive.exists() or archive.is_symlink():
            try:
                archived_digest = hashlib.sha256(archive.read_bytes()).hexdigest()
            except OSError as exc:
                raise LegacyJobMigrationError(
                    f"cannot verify migrated legacy Job archive {archive}: {exc}"
                ) from exc
            if archived_digest != digest:
                raise LegacyJobMigrationError(
                    f"legacy Job archive conflicts with source file: {archive}"
                )
            try:
                path.unlink()
            except OSError as exc:
                raise LegacyJobMigrationError(
                    f"cannot remove duplicate migrated legacy Job file {path}: {exc}"
                ) from exc
        else:
            try:
                path.rename(archive)
            except OSError as exc:
                raise LegacyJobMigrationError(
                    f"cannot archive migrated legacy Job file {path}: {exc}"
                ) from exc
        self._fsync_directory(path.parent)

    def _migrate_legacy_json_jobs(self):
        paths = self._legacy_job_files()
        if not paths:
            return []
        candidates = [self._read_legacy_job(path) for path in paths]

        migrated = []
        with self._immediate_transaction() as conn:
            for path, record, _key, digest in candidates:
                existing = self._select_one(conn, "job_id = ?", (record["job_id"],))
                if existing is not None:
                    if existing.get("legacy_record_sha256") != digest:
                        raise LegacyJobMigrationError(
                            f"legacy Job {record['job_id']} conflicts with an existing SQLite record"
                        )
                else:
                    try:
                        self._insert_row(conn, record)
                    except sqlite3.IntegrityError as exc:
                        raise LegacyJobMigrationError(
                            f"legacy Job {record['job_id']} conflicts during migration: {exc}"
                        ) from exc
                migrated.append((path, record["job_id"], digest))

        for path, _job_id, digest in migrated:
            self._archive_migrated_legacy_file(path, digest)
        return [job_id for _path, job_id, _digest in migrated]

    def _add_missing_columns(self, conn):
        existing = {row["name"] for row in conn.execute("PRAGMA table_info(jobs)")}
        if "job_id" not in existing:
            raise sqlite3.DatabaseError("jobs table is missing its job_id primary key")
        added = []
        for name, definition in _COLUMN_DEFINITIONS.items():
            if name not in existing:
                conn.execute(f"ALTER TABLE jobs ADD COLUMN {name} {definition}")
                added.append(name)
        return added

    def _backfill_explicit_columns(self, conn, added_columns):
        """Populate newly added columns from a legacy full-record table."""
        rows = conn.execute(f"SELECT {_SELECT_COLUMNS} FROM jobs").fetchall()
        for row in rows:
            legacy_record = _json_load(row["record"])
            if not isinstance(legacy_record, dict):
                legacy_record = {}
            record = self._row_to_record(row)
            # SQLite fills newly added NOT NULL columns with their declared
            # defaults.  Those defaults must not overwrite richer values that
            # already existed in the forward-compatible record blob.
            for name in added_columns:
                if name in legacy_record:
                    record[name] = legacy_record[name]
            record, _ = self._normalize_new_record(
                record,
                idempotency_key=record.get("idempotency_key"),
            )
            self._update_row(conn, record)

    def _normalize_existing_records(self, conn):
        """Upgrade every record blob to the active schema, even without DDL."""

        rows = conn.execute(f"SELECT {_SELECT_COLUMNS} FROM jobs").fetchall()
        for row in rows:
            record, _ = self._normalize_new_record(
                self._row_to_record(row),
                idempotency_key=row["idempotency_key"],
            )
            self._update_row(conn, record)

    def _lock(self, job_id):
        with self._locks_guard:
            lock = self._locks.get(job_id)
            if lock is None:
                lock = threading.Lock()
                self._locks[job_id] = lock
            return lock

    def discard_lock(self, job_id):
        with self._locks_guard:
            self._locks.pop(str(job_id), None)

    @staticmethod
    def _row_to_record(row):
        if row is None:
            return None
        record = _json_load(row["record"])
        if not isinstance(record, dict):
            record = {}

        # Explicit columns are authoritative when populated.  When migrating an
        # old record-only table, newly added nullable columns are initially NULL
        # and the value already present in ``record`` is preserved for backfill.
        for name in ("job_id", "status", "resource", "action", "created_at", "updated_at"):
            value = row[name]
            if value is not None and (value != "" or name not in record):
                record[name] = value

        record["version"] = int(row["version"] or 0)

        for name in (
            "started_at",
            "finished_at",
            "idempotency_key",
            "request_fingerprint",
            "request_id",
            "session_id",
            "retry_of",
            "root_job_id",
            "cancel_requested_at",
            "result_status",
        ):
            if row[name] is not None:
                record[name] = row[name]

        for name in ("attempt", "max_attempts"):
            record[name] = int(row[name] or 1)

        for name in ("payload", "result", "partial_output"):
            if row[name] is not None:
                parsed = _json_load(row[name])
                if parsed is not None:
                    record[name] = parsed

        if row["result_ok"] is not None:
            record["result_ok"] = bool(row["result_ok"])
        return record

    def _normalize_new_record(self, record, idempotency_key=None):
        if not isinstance(record, dict):
            raise TypeError("job record must be a dictionary")
        normalized = dict(record)
        job_id = str(normalized.get("job_id") or "")
        if not job_id:
            raise ValueError("job_id is required")
        normalized["job_id"] = job_id
        normalized["status"] = str(normalized.get("status") or "")
        if normalized["status"] not in self._allowed_statuses:
            raise ValueError(f"unsupported Job status: {normalized['status']!r}")
        try:
            record_schema_version = int(normalized.get("schema_version", self._schema_version))
        except (TypeError, ValueError) as exc:
            raise ValueError("job schema_version must be an integer") from exc
        if record_schema_version != self._schema_version:
            raise ValueError(
                f"unsupported Job schema_version {record_schema_version}; "
                f"expected {self._schema_version}"
            )
        normalized["schema_version"] = record_schema_version
        normalized["resource"] = str(normalized.get("resource") or "")
        normalized["action"] = str(normalized.get("action") or "")
        normalized["request_id"] = str(normalized.get("request_id") or "")
        normalized["session_id"] = str(normalized.get("session_id") or "")
        if not normalized["request_id"] or not normalized["session_id"]:
            raise ValueError("request_id and session_id are required")
        if not isinstance(normalized.get("payload"), dict):
            raise ValueError("job payload must be a JSON object")
        try:
            normalized["version"] = int(normalized.get("version", 0))
        except (TypeError, ValueError):
            normalized["version"] = 0
        timestamp = now_iso()
        normalized["created_at"] = str(normalized.get("created_at") or timestamp)
        normalized["updated_at"] = str(normalized.get("updated_at") or normalized["created_at"])

        retry_of = str(normalized.get("retry_of") or "") or None
        root_job_id = str(normalized.get("root_job_id") or retry_of or job_id)
        if retry_of is None:
            normalized.pop("retry_of", None)
        else:
            normalized["retry_of"] = retry_of
        normalized["root_job_id"] = root_job_id

        try:
            attempt = int(normalized.get("attempt", 1))
        except (TypeError, ValueError):
            attempt = 1
        try:
            max_attempts = int(normalized.get("max_attempts", 1))
        except (TypeError, ValueError):
            max_attempts = 1
        normalized["attempt"] = max(1, attempt)
        normalized["max_attempts"] = max(normalized["attempt"], max_attempts, 1)

        cancel_requested_at = str(normalized.get("cancel_requested_at") or "") or None
        if cancel_requested_at is None:
            normalized.pop("cancel_requested_at", None)
        else:
            normalized["cancel_requested_at"] = cancel_requested_at

        normalized["request_fingerprint"] = canonical_request_fingerprint(
            normalized["resource"],
            normalized["action"],
            normalized.get("payload"),
        )

        key = idempotency_key if idempotency_key is not None else normalized.get("idempotency_key")
        key = str(key) if key else None
        if key is not None:
            normalized["idempotency_key"] = key
        else:
            normalized.pop("idempotency_key", None)
        return normalized, key

    @staticmethod
    def _column_values(record):
        result_ok = record.get("result_ok")
        if result_ok is not None:
            result_ok = 1 if bool(result_ok) else 0
        return (
            str(record.get("status") or ""),
            str(record.get("resource") or ""),
            str(record.get("action") or ""),
            int(record.get("version", 0)),
            str(record.get("created_at") or ""),
            record.get("started_at") or None,
            record.get("finished_at") or None,
            str(record.get("updated_at") or ""),
            record.get("idempotency_key") or None,
            record.get("request_fingerprint") or None,
            record.get("request_id") or None,
            record.get("session_id") or None,
            record.get("retry_of") or None,
            record.get("root_job_id") or None,
            int(record.get("attempt", 1)),
            int(record.get("max_attempts", 1)),
            record.get("cancel_requested_at") or None,
            _json_dump(record.get("payload")),
            _json_dump(record.get("result")),
            _json_dump(record.get("partial_output")),
            result_ok,
            record.get("result_status") or None,
            json.dumps(record, ensure_ascii=False, separators=(",", ":")),
        )

    def _insert_row(self, conn, record):
        conn.execute(
            """
            INSERT INTO jobs (
                status, resource, action, version, created_at, started_at,
                finished_at, updated_at, idempotency_key, request_fingerprint,
                request_id, session_id, retry_of, root_job_id, attempt,
                max_attempts, cancel_requested_at, payload, result,
                partial_output, result_ok, result_status, record, job_id
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (*self._column_values(record), record["job_id"]),
        )

    def _update_row(self, conn, record):
        conn.execute(
            """
            UPDATE jobs SET
                status=?, resource=?, action=?, version=?, created_at=?,
                started_at=?, finished_at=?, updated_at=?, idempotency_key=?,
                request_fingerprint=?, request_id=?, session_id=?, retry_of=?,
                root_job_id=?, attempt=?, max_attempts=?, cancel_requested_at=?,
                payload=?, result=?, partial_output=?, result_ok=?,
                result_status=?, record=?
            WHERE job_id=?
            """,
            (*self._column_values(record), str(record["job_id"])),
        )

    def _select_one(self, conn, clause, parameters):
        row = conn.execute(
            f"SELECT {_SELECT_COLUMNS} FROM jobs WHERE {clause}",
            parameters,
        ).fetchone()
        return self._row_to_record(row)

    def _existing_idempotent_request(self, conn, normalized, key):
        if key is None:
            return None
        existing = self._select_one(conn, "idempotency_key = ?", (key,))
        if existing is None:
            return None
        existing_fingerprint = existing.get("request_fingerprint")
        if not existing_fingerprint:
            existing_fingerprint = canonical_request_fingerprint(
                existing.get("resource"),
                existing.get("action"),
                existing.get("payload"),
            )
            existing["request_fingerprint"] = existing_fingerprint
            self._update_row(conn, existing)
        if existing_fingerprint != normalized["request_fingerprint"]:
            raise IdempotencyConflict(
                key,
                existing.get("job_id"),
                existing_fingerprint,
                normalized["request_fingerprint"],
            )
        return existing

    @staticmethod
    def _count_active_in_connection(conn):
        placeholders = ",".join("?" for _ in JOB_ACTIVE_STATUSES)
        row = conn.execute(
            f"SELECT COUNT(*) FROM jobs WHERE status IN ({placeholders})",
            JOB_ACTIVE_STATUSES,
        ).fetchone()
        return int(row[0]) if row else 0

    def _create_in_transaction(self, conn, normalized, key, max_active=None):
        existing = self._existing_idempotent_request(conn, normalized, key)
        if existing is not None:
            return existing, True

        if max_active is not None and normalized.get("status") in JOB_ACTIVE_STATUSES:
            active = self._count_active_in_connection(conn)
            if active >= max_active:
                raise JobCapacityExceeded(active, max_active)

        self._insert_row(conn, normalized)
        return normalized, False

    def create(self, record, idempotency_key=None):
        """Create a Job, atomically deduplicating a supplied idempotency key."""
        normalized, key = self._normalize_new_record(record, idempotency_key)
        with self._immediate_transaction() as conn:
            return self._create_in_transaction(conn, normalized, key)

    def admit(self, record, idempotency_key, max_active):
        """Deduplicate, enforce active capacity, and insert in one transaction."""
        if isinstance(max_active, bool) or not isinstance(max_active, (int, str)):
            raise ValueError("max_active must be a non-negative integer")
        if isinstance(max_active, str):
            max_active = max_active.strip()
            if not max_active.isdecimal():
                raise ValueError("max_active must be a non-negative integer")
        max_active = int(max_active)
        if max_active < 0:
            raise ValueError("max_active must be a non-negative integer")

        normalized, key = self._normalize_new_record(record, idempotency_key)
        with self._immediate_transaction() as conn:
            return self._create_in_transaction(
                conn,
                normalized,
                key,
                max_active=max_active,
            )

    def read(self, job_id):
        with self._connection() as conn:
            return self._select_one(conn, "job_id = ?", (str(job_id),))

    def read_by_idempotency_key(self, idempotency_key):
        if not idempotency_key:
            return None
        with self._connection() as conn:
            return self._select_one(
                conn,
                "idempotency_key = ?",
                (str(idempotency_key),),
            )

    def update(self, job_id, mutator, expected_version=None):
        """Run one serialized, transactional read-modify-write operation."""
        job_id = str(job_id)
        if expected_version is not None:
            if isinstance(expected_version, bool):
                raise ValueError("expected_version must be a non-negative integer")
            try:
                expected_version = int(expected_version)
            except (TypeError, ValueError) as exc:
                raise ValueError("expected_version must be a non-negative integer") from exc
            if expected_version < 0:
                raise ValueError("expected_version must be a non-negative integer")
        with self._lock(job_id):
            with self._immediate_transaction() as conn:
                record = self._select_one(conn, "job_id = ?", (job_id,))
                if record is None:
                    return None
                if (
                    expected_version is not None
                    and int(record.get("version", 0)) != expected_version
                ):
                    raise JobVersionConflict(
                        job_id,
                        expected_version,
                        int(record.get("version", 0)),
                    )
                if mutator(record) is False:
                    return record
                status = str(record.get("status") or "")
                if status not in self._allowed_statuses:
                    raise ValueError(f"unsupported Job status: {status!r}")
                record["schema_version"] = self._schema_version
                record["version"] = int(record.get("version", 0)) + 1
                record["updated_at"] = now_iso()
                self._update_row(conn, record)
                return record

    def list_active(self):
        placeholders = ",".join("?" for _ in JOB_ACTIVE_STATUSES)
        with self._connection() as conn:
            rows = conn.execute(
                f"SELECT {_SELECT_COLUMNS} FROM jobs"
                f" WHERE status IN ({placeholders}) ORDER BY created_at, job_id",
                JOB_ACTIVE_STATUSES,
            ).fetchall()
        return [self._row_to_record(row) for row in rows]

    @staticmethod
    def _recovered_terminal_status(result):
        if result.get("status") == "cancelled":
            return "cancelled"
        if result.get("ok") or result.get("status") == "approval_required":
            return "succeeded"
        return "failed"

    def recover_interrupted(self, completion_reader):
        """Atomically finalize Jobs left active by an earlier server process."""

        if not callable(completion_reader):
            raise TypeError("completion_reader must be callable")

        # Session completion files are independently durable.  Read them before
        # opening the SQLite write transaction so filesystem/audit recovery does
        # not hold the database lock for an unbounded period.
        candidates = self.list_active()
        completions = {
            str(candidate["job_id"]): completion_reader(str(candidate["job_id"]))
            for candidate in candidates
        }
        recovered = []
        timestamp = now_iso()
        with self._immediate_transaction() as conn:
            for candidate in candidates:
                job_id = str(candidate["job_id"])
                record = self._select_one(conn, "job_id = ?", (job_id,))
                if record is None or record.get("status") not in JOB_ACTIVE_STATUSES:
                    continue
                completion = completions[job_id]
                if completion is not None:
                    if not isinstance(completion, dict) or not isinstance(
                        completion.get("result"), dict
                    ):
                        raise ValueError(
                            f"durable completion for Job {job_id} must contain a result object"
                        )
                    recovered_result = completion["result"]
                    record["status"] = self._recovered_terminal_status(recovered_result)
                    record["result"] = recovered_result
                    record["result_ok"] = bool(recovered_result.get("ok"))
                    record["result_status"] = str(
                        recovered_result.get("status") or record["status"]
                    )
                    record["recovery_source"] = "durable_session_completion"
                    record["finished_at"] = str(
                        completion.get("completed_at") or timestamp
                    )
                else:
                    record["status"] = "failed"
                    record["result"] = {
                        "ok": False,
                        "status": "server_restarted",
                        "error": "The Web server restarted before this job completed.",
                    }
                    record["result_ok"] = False
                    record["result_status"] = "server_restarted"
                    record["recovery_source"] = "interrupted_without_completion"
                    record["finished_at"] = timestamp
                record["phase"] = "terminal"
                record["schema_version"] = self._schema_version
                record["version"] = int(record.get("version", 0)) + 1
                record["updated_at"] = timestamp
                self._update_row(conn, record)
                recovered.append(record)
        return recovered

    def list_audit_pending(self):
        placeholders = ",".join("?" for _ in JOB_ACTIVE_STATUSES)
        with self._connection() as conn:
            rows = conn.execute(
                f"SELECT {_SELECT_COLUMNS} FROM jobs"
                f" WHERE status NOT IN ({placeholders}) ORDER BY created_at, job_id",
                JOB_ACTIVE_STATUSES,
            ).fetchall()
        return [
            record
            for record in (self._row_to_record(row) for row in rows)
            if record.get("audit_state") == "pending"
        ]

    def count_active(self):
        with self._connection() as conn:
            return self._count_active_in_connection(conn)


    def status_counts(self):
        """Return {status: count} for all jobs currently retained in SQLite."""
        with self._connection() as conn:
            rows = conn.execute(
                "SELECT status, COUNT(*) FROM jobs GROUP BY status"
            ).fetchall()
        counts = {}
        for status, count in rows:
            key = str(status or "")
            counts[key] = int(count or 0)
        return counts

    def cleanup(self, retention_hours):
        cutoff = time.strftime(
            "%Y-%m-%dT%H:%M:%SZ",
            time.gmtime(time.time() - float(retention_hours) * 3600),
        )
        placeholders = ",".join("?" for _ in JOB_ACTIVE_STATUSES)
        with self._immediate_transaction() as conn:
            rows = conn.execute(
                f"SELECT {_SELECT_COLUMNS} FROM jobs WHERE updated_at < ?"
                f" AND status NOT IN ({placeholders})",
                (cutoff, *JOB_ACTIVE_STATUSES),
            ).fetchall()
            deleted = [
                str(record["job_id"])
                for record in (self._row_to_record(row) for row in rows)
                if record.get("audit_state") != "pending"
            ]
            if deleted:
                conn.executemany(
                    "DELETE FROM jobs WHERE job_id = ?",
                    [(job_id,) for job_id in deleted],
                )
        for job_id in deleted:
            self.discard_lock(job_id)
        return deleted
