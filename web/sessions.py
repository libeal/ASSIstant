"""Durable Web workspace and per-Job session state.

Conversation history and protocol turns serve different purposes: history is
the compact model context, while turns are immutable UI/business-state
snapshots.  Background Jobs receive private copies and are merged back under a
single workspace lock in completion order.
"""

import fcntl
import hashlib
import json
import os
import re
import shutil
import threading
import time
import uuid
from dataclasses import dataclass
from pathlib import Path


SAFE_SESSION_ID = re.compile(r"^[A-Za-z0-9._-]+$")
COMPLETE_JOB_JOURNAL_VERSION = 1
AUDIT_OUTBOX_EVENT_ID = re.compile(r"^[A-Za-z0-9:._-]+$")


class SessionDataError(ValueError):
    """Raised when persisted session state is malformed."""


def now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _secure_mode(path, mode=0o600):
    try:
        os.chmod(path, mode)
    except OSError:
        pass


def _fsync_directory(path):
    try:
        fd = os.open(str(path), os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(fd)
    except OSError:
        pass
    finally:
        os.close(fd)


def _fsync_directory_required(path):
    """Fsync a directory and surface failures for transactional writes."""

    fd = os.open(str(path), os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _remove_file_durable(path):
    path = Path(path)
    try:
        path.unlink()
    except FileNotFoundError:
        return
    _fsync_directory_required(path.parent)


def _write_all(fd, payload):
    view = memoryview(payload)
    while view:
        written = os.write(fd, view)
        if written <= 0:
            raise OSError("short write while persisting session state")
        view = view[written:]


def secure_truncate(path):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.fchmod(fd, 0o600)
        os.fsync(fd)
    finally:
        os.close(fd)
    _fsync_directory(path.parent)


def _read_json_array_optional(path):
    path = Path(path)
    try:
        with path.open("r", encoding="utf-8") as handle:
            value = json.load(handle)
    except FileNotFoundError:
        return None
    except (OSError, json.JSONDecodeError) as exc:
        raise SessionDataError(f"invalid session history {path}: {exc}") from exc
    if not isinstance(value, list):
        raise SessionDataError(f"session history must be a JSON array: {path}")
    return value


def read_json_array(path):
    value = _read_json_array_optional(path)
    return [] if value is None else value


def write_json_atomic(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    suffix = f".{os.getpid()}.{threading.get_ident()}.tmp"
    tmp_path = path.with_name(path.name + suffix)
    try:
        fd = os.open(str(tmp_path), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            payload = json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n"
            _write_all(fd, payload.encode("utf-8"))
            os.fsync(fd)
        finally:
            os.close(fd)
        os.replace(tmp_path, path)
    except BaseException:
        try:
            tmp_path.unlink()
        except FileNotFoundError:
            pass
        raise
    _secure_mode(path)
    _fsync_directory(path.parent)


def read_turns(path):
    path = Path(path)
    turns = []
    try:
        handle = path.open("r", encoding="utf-8")
    except FileNotFoundError:
        return []
    except OSError as exc:
        raise SessionDataError(f"cannot read persisted turns {path}: {exc}") from exc
    with handle:
        for line_number, line in enumerate(handle, start=1):
            if not line.strip():
                continue
            try:
                turn = json.loads(line)
            except json.JSONDecodeError as exc:
                raise SessionDataError(
                    f"invalid persisted turn {path}:{line_number}: {exc}"
                ) from exc
            if not isinstance(turn, dict):
                raise SessionDataError(
                    f"persisted turn must be an object: {path}:{line_number}"
                )
            turns.append(turn)
    return turns


def read_last_turn(path):
    """Read only the final non-empty JSONL turn, regardless of line length."""

    path = Path(path)
    try:
        fd = os.open(str(path), os.O_RDONLY)
    except FileNotFoundError:
        return None
    except OSError as exc:
        raise SessionDataError(f"cannot read persisted turns {path}: {exc}") from exc

    try:
        position = os.fstat(fd).st_size
        pending = b""
        while position > 0:
            count = min(65536, position)
            position -= count
            pending = os.pread(fd, count, position) + pending
            parts = pending.split(b"\n")
            candidates = parts if position == 0 else parts[1:]
            for candidate in reversed(candidates):
                candidate = candidate.rstrip(b"\r")
                if not candidate.strip():
                    continue
                try:
                    turn = json.loads(candidate.decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                    raise SessionDataError(
                        f"invalid final persisted turn {path}: {exc}"
                    ) from exc
                if not isinstance(turn, dict):
                    raise SessionDataError(
                        f"final persisted turn must be an object: {path}"
                    )
                return turn
            pending = parts[0]
        return None
    finally:
        os.close(fd)


def write_turns_atomic(path, turns):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    suffix = f".{os.getpid()}.{threading.get_ident()}.tmp"
    tmp_path = path.with_name(path.name + suffix)
    try:
        fd = os.open(str(tmp_path), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            for turn in turns:
                if not isinstance(turn, dict):
                    raise SessionDataError("persisted turns must contain JSON objects")
                raw = json.dumps(turn, ensure_ascii=False, separators=(",", ":")) + "\n"
                _write_all(fd, raw.encode("utf-8"))
            os.fsync(fd)
        finally:
            os.close(fd)
        os.replace(tmp_path, path)
    except BaseException:
        try:
            tmp_path.unlink()
        except FileNotFoundError:
            pass
        raise
    _secure_mode(path)
    _fsync_directory(path.parent)


def append_turn(path, turn):
    if not isinstance(turn, dict):
        raise SessionDataError("persisted turn must be a JSON object")
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(str(path), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        os.fchmod(fd, 0o600)
        raw = json.dumps(turn, ensure_ascii=False, separators=(",", ":")) + "\n"
        _write_all(fd, raw.encode("utf-8"))
        os.fsync(fd)
    finally:
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        finally:
            os.close(fd)


def count_jsonl_events(path):
    try:
        with Path(path).open("r", encoding="utf-8") as handle:
            return sum(1 for line in handle if line.strip())
    except OSError:
        return 0


def compact_history_text(value, limit=1200):
    text = " ".join(str(value or "").split())
    return text[:limit] + "[TRUNCATED]" if len(text) > limit else text


def _history_digest(history):
    try:
        canonical = json.dumps(
            history,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
            allow_nan=False,
        )
    except (TypeError, ValueError) as exc:
        raise SessionDataError(f"session history is not canonical JSON: {exc}") from exc
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def _validate_history_entries(history, description="session history"):
    """Reject malformed model-context entries before they cross sessions."""

    if not isinstance(history, list):
        raise SessionDataError(f"{description} must be a JSON array")
    for index, entry in enumerate(history):
        location = f"{description}[{index}]"
        if not isinstance(entry, dict):
            raise SessionDataError(f"{location} must be a JSON object")
        if not isinstance(entry.get("type"), str) or not entry.get("type"):
            raise SessionDataError(f"{location}.type must be a non-empty string")
        request = entry.get("request")
        response = entry.get("response")
        if not isinstance(request, dict) or not isinstance(response, dict):
            raise SessionDataError(f"{location} request/response must be objects")
        if not isinstance(request.get("content"), str):
            raise SessionDataError(f"{location}.request.content must be a string")
        if not isinstance(response.get("content"), str):
            raise SessionDataError(f"{location}.response.content must be a string")
        if not isinstance(entry.get("status"), str):
            raise SessionDataError(f"{location}.status must be a string")
        if "status" in response and not isinstance(response.get("status"), str):
            raise SessionDataError(f"{location}.response.status must be a string")
        for key in ("mode", "started_at", "completed_at"):
            if key in entry and not isinstance(entry.get(key), str):
                raise SessionDataError(f"{location}.{key} must be a string")
        if "metadata" in entry and not isinstance(entry.get("metadata"), dict):
            raise SessionDataError(f"{location}.metadata must be an object")
    return history


def history_from_turns(turns):
    """Build model context from authoritative turn results, never audit events."""

    history = []
    for turn in turns:
        if not isinstance(turn, dict):
            continue
        if turn.get("context_eligible") is not True:
            continue
        result = turn.get("result") if isinstance(turn.get("result"), dict) else {}
        response = result.get("response") if isinstance(result.get("response"), dict) else {}
        status = str(turn.get("status") or result.get("status") or "completed")
        response_text = str(response.get("answer") or "")
        if not response_text:
            for block in result.get("output_blocks") if isinstance(result.get("output_blocks"), list) else []:
                if isinstance(block, dict) and block.get("kind") == "markdown" and block.get("text"):
                    response_text = str(block.get("text"))
                    break
        if not response_text:
            execution_count = sum(
                1
                for item in result.get("timeline")
                if isinstance(item, dict) and item.get("kind") == "execution"
            ) if isinstance(result.get("timeline"), list) else 0
            response_text = json.dumps(
                {"status": status, "results": execution_count},
                ensure_ascii=False,
                separators=(",", ":"),
            )
        history.append(
            {
                "type": "request",
                "mode": str(turn.get("mode") or "work"),
                "request": {"content": compact_history_text(turn.get("input"))},
                "response": {
                    "content": compact_history_text(response_text),
                    "status": status,
                },
                "status": status,
                "started_at": str(turn.get("created_at") or now_iso()),
                "completed_at": str(turn.get("updated_at") or now_iso()),
                "metadata": {"source": "persisted_turn"},
            }
        )
    return history


@dataclass(frozen=True)
class SessionPaths:
    session_id: str
    audit_log: Path
    history_file: Path
    turns_file: Path


@dataclass(frozen=True)
class JobSessionContext:
    job_id: str
    request_id: str
    created_at: str
    workspace: SessionPaths
    private: SessionPaths
    private_tmp_dir: Path
    snapshot_len: int
    snapshot_sha256: str


class SessionStore:
    def __init__(self, root, run_id, config_reader, audit_writer, lock=None):
        self.root = Path(root)
        self.run_id = str(run_id)
        self._config_reader = config_reader
        self._audit_writer = audit_writer
        self._lock = lock or threading.RLock()
        self._session_id = f"session_web_{self.run_id[:16]}"
        self._restored_from = ""

    @property
    def journal_dir(self):
        return self.root / "tmp" / "web" / "session-journal"

    def _journal_path(self, job_id):
        job_id = str(job_id)
        if not re.fullmatch(r"[0-9a-f]+", job_id):
            raise ValueError("job_id must be lowercase hexadecimal")
        return self.journal_dir / f"complete-{job_id}.json"

    def _completion_path(self, job_id):
        job_id = str(job_id)
        if not re.fullmatch(r"[0-9a-f]+", job_id):
            raise ValueError("job_id must be lowercase hexadecimal")
        return self.root / "tmp" / "web" / "jobs" / f"{job_id}.completion.json"

    def _target_path(self, relative_path):
        if not isinstance(relative_path, str) or not relative_path:
            raise SessionDataError("session transaction target path is required")
        relative = Path(relative_path)
        if relative.is_absolute() or ".." in relative.parts:
            raise SessionDataError("session transaction target path is unsafe")
        target = self.root / relative
        try:
            target.resolve(strict=False).relative_to(self.root.resolve(strict=False))
        except ValueError as exc:
            raise SessionDataError("session transaction target escapes project root") from exc
        return target

    def _validate_journal(self, journal, journal_path):
        if not isinstance(journal, dict):
            raise SessionDataError(f"session transaction journal must be an object: {journal_path}")
        if journal.get("version") != COMPLETE_JOB_JOURNAL_VERSION:
            raise SessionDataError(f"unsupported session transaction journal: {journal_path}")
        if journal.get("operation") != "complete_job":
            raise SessionDataError(f"invalid session transaction operation: {journal_path}")
        job_id = journal.get("job_id")
        if not isinstance(job_id, str) or not re.fullmatch(r"[0-9a-f]+", job_id):
            raise SessionDataError(f"invalid session transaction job_id: {journal_path}")
        if Path(journal_path).name != f"complete-{job_id}.json":
            raise SessionDataError(f"session transaction journal name mismatch: {journal_path}")
        state = journal.get("state")
        if state not in {"prepared", "committed"}:
            raise SessionDataError(f"invalid session transaction state: {journal_path}")
        completion = journal.get("completion")
        if not isinstance(completion, dict):
            raise SessionDataError(f"session transaction completion is invalid: {journal_path}")

        audit_outbox = journal.get("audit_outbox", [])
        if not isinstance(audit_outbox, list):
            raise SessionDataError(
                f"session transaction audit_outbox must be an array: {journal_path}"
            )
        audit_state = journal.get(
            "audit_state",
            "complete" if not audit_outbox else "pending",
        )
        if audit_state not in {"pending", "complete"}:
            raise SessionDataError(
                f"invalid session transaction audit state: {journal_path}"
            )
        seen_event_ids = set()
        for event in audit_outbox:
            if not isinstance(event, dict):
                raise SessionDataError(
                    f"session transaction audit event is invalid: {journal_path}"
                )
            event_id = event.get("event_id")
            if (
                not isinstance(event_id, str)
                or not AUDIT_OUTBOX_EVENT_ID.fullmatch(event_id)
                or event_id in seen_event_ids
            ):
                raise SessionDataError(
                    f"session transaction audit event_id is invalid: {journal_path}"
                )
            seen_event_ids.add(event_id)
            self._target_path(event.get("path"))
            if (
                not isinstance(event.get("session_id"), str)
                or not SAFE_SESSION_ID.fullmatch(event["session_id"])
                or not isinstance(event.get("stage"), str)
                or not event["stage"]
                or not isinstance(event.get("payload"), dict)
                or event["payload"].get("outbox_event_id") != event_id
            ):
                raise SessionDataError(
                    f"session transaction audit event payload is invalid: {journal_path}"
                )

        targets = journal.get("targets", [])
        if not isinstance(targets, list):
            raise SessionDataError(f"session transaction targets must be an array: {journal_path}")
        if state == "prepared" and "targets" not in journal:
            raise SessionDataError(f"prepared session transaction has no targets: {journal_path}")
        seen_paths = set()
        for target in targets:
            if not isinstance(target, dict):
                raise SessionDataError(f"session transaction target is invalid: {journal_path}")
            path = target.get("path")
            self._target_path(path)
            if path in seen_paths:
                raise SessionDataError(f"duplicate session transaction target: {path}")
            seen_paths.add(path)
            target_format = target.get("format")
            if target_format not in {"json_array", "json_object", "turns", "turns_append"}:
                raise SessionDataError(f"invalid session transaction target format: {path}")
            if not isinstance(target.get("before_exists"), bool):
                raise SessionDataError(f"invalid session transaction preimage: {path}")
            if target_format == "turns_append":
                before_size = target.get("before_size")
                if not isinstance(before_size, int) or isinstance(before_size, bool) or before_size < 0:
                    raise SessionDataError(
                        f"session transaction append target has an invalid preimage size: {path}"
                    )
                after = target.get("after")
                if not isinstance(after, list) or any(
                    not isinstance(turn, dict) for turn in after
                ):
                    raise SessionDataError(
                        f"session transaction append turns must contain objects: {path}"
                    )
                continue
            for value_name in ("before", "after"):
                value = target.get(value_name)
                expected_type = dict if target_format == "json_object" else list
                if not isinstance(value, expected_type):
                    raise SessionDataError(
                        f"session transaction {value_name} value has the wrong type: {path}"
                    )
                if target_format == "turns" and any(
                    not isinstance(turn, dict) for turn in value
                ):
                    raise SessionDataError(
                        f"session transaction turns must contain objects: {path}"
                    )
        return journal

    def _read_journal_locked(self, journal_path):
        journal_path = Path(journal_path)
        try:
            with journal_path.open("r", encoding="utf-8") as handle:
                journal = json.load(handle)
        except FileNotFoundError:
            return None
        except (OSError, json.JSONDecodeError) as exc:
            raise SessionDataError(
                f"invalid session transaction journal {journal_path}: {exc}"
            ) from exc
        return self._validate_journal(journal, journal_path)

    def _write_journal_locked(self, journal_path, journal):
        journal_path = Path(journal_path)
        journal_path.parent.mkdir(parents=True, exist_ok=True)
        _secure_mode(journal_path.parent, 0o700)
        self._validate_journal(journal, journal_path)
        write_json_atomic(journal_path, journal)
        _fsync_directory_required(journal_path.parent)

    def _transaction_target(self, path, target_format, before, after):
        path = Path(path)
        try:
            relative_path = path.relative_to(self.root)
        except ValueError as exc:
            raise SessionDataError(
                f"session transaction target is outside project root: {path}"
            ) from exc
        return {
            "path": str(relative_path),
            "format": target_format,
            "before_exists": path.exists(),
            "before": before,
            "after": after,
        }

    def _write_transaction_target_locked(self, target, value_name):
        path = self._target_path(target["path"])
        if value_name == "before" and not target["before_exists"]:
            _remove_file_durable(path)
            return
        if target["format"] == "turns_append":
            # An append-only turns target keeps both the journal and the commit
            # O(1): commit appends just the new turn lines; rollback truncates
            # back to the pre-append byte length instead of rewriting the file.
            if value_name == "before":
                self._truncate_turns_to_size_locked(path, target["before_size"])
            else:
                self._append_turns_locked(path, target["after"])
            return
        value = target[value_name]
        if target["format"] in {"json_array", "json_object"}:
            write_json_atomic(path, value)
        else:
            write_turns_atomic(path, value)
        _fsync_directory_required(path.parent)

    def _append_turns_locked(self, path, turns):
        """Durably append turn objects as JSONL lines (O(1) in existing size)."""
        path.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(str(path), os.O_RDWR | os.O_APPEND | os.O_CREAT, 0o600)
        try:
            os.fchmod(fd, 0o600)
            original_size = os.fstat(fd).st_size
            if original_size > 0 and os.pread(fd, 1, original_size - 1) != b"\n":
                # A valid final JSON object does not require a trailing newline.
                # Add its separator as part of this append; rollback truncates
                # both the separator and new turns back to before_size.
                _write_all(fd, b"\n")
            for turn in turns:
                if not isinstance(turn, dict):
                    raise SessionDataError("appended turn must be a JSON object")
                raw = json.dumps(turn, ensure_ascii=False, separators=(",", ":")) + "\n"
                _write_all(fd, raw.encode("utf-8"))
            os.fsync(fd)
        finally:
            os.close(fd)
        _fsync_directory_required(path.parent)

    def _truncate_turns_to_size_locked(self, path, before_size):
        """Roll an append target back to its pre-append byte length."""
        fd = os.open(str(path), os.O_WRONLY)
        try:
            os.ftruncate(fd, before_size)
            os.fsync(fd)
        finally:
            os.close(fd)
        _fsync_directory_required(path.parent)

    def _transaction_append_target(self, path, new_turns):
        """Build an O(1) append-only turns target.

        Records only the newly appended turns and the file's pre-append byte
        size, so the crash journal never grows with the whole session's history
        and completion never rewrites the entire turns file (was O(N^2) over a
        session). ``before_size`` is what rollback truncates back to.
        """
        path = Path(path)
        try:
            relative_path = path.relative_to(self.root)
        except ValueError as exc:
            raise SessionDataError(
                f"session transaction target is outside project root: {path}"
            ) from exc
        try:
            before_size = path.stat().st_size
            before_exists = True
        except FileNotFoundError:
            before_size = 0
            before_exists = False
        return {
            "path": str(relative_path),
            "format": "turns_append",
            "before_exists": before_exists,
            "before_size": before_size,
            "after": new_turns,
        }

    def _rollback_journal_locked(self, journal, journal_path):
        failures = []
        for target in reversed(journal.get("targets", [])):
            try:
                self._write_transaction_target_locked(target, "before")
            except Exception as exc:  # noqa: BLE001 - retain journal for later recovery.
                failures.append(f"{target.get('path')}: {exc}")
        if failures:
            raise SessionDataError(
                "session transaction rollback failed; prepared journal retained: "
                + "; ".join(failures)
            )
        _remove_file_durable(journal_path)

    def _audit_segments_locked(self, relative_path):
        live_path = self._target_path(relative_path)
        archives = []
        pattern = re.compile(rf"^{re.escape(live_path.name)}\.([1-9][0-9]*)$")
        try:
            entries = list(live_path.parent.iterdir())
        except FileNotFoundError:
            entries = []
        except OSError as exc:
            raise SessionDataError(
                f"cannot inspect audit outbox target {live_path.parent}: {exc}"
            ) from exc
        for entry in entries:
            match = pattern.fullmatch(entry.name)
            if match is not None and entry.is_file() and not entry.is_symlink():
                archives.append((int(match.group(1)), entry))
        ordered = [entry for _index, entry in sorted(archives)]
        if live_path.is_file() and not live_path.is_symlink():
            ordered.append(live_path)
        return ordered

    def _audit_outbox_event_exists_locked(self, outbox_event):
        event_id = outbox_event["event_id"]
        expected_session = outbox_event["session_id"]
        expected_stage = outbox_event["stage"]
        for path in self._audit_segments_locked(outbox_event["path"]):
            try:
                handle = path.open("r", encoding="utf-8")
            except OSError as exc:
                raise SessionDataError(f"cannot inspect audit outbox file {path}: {exc}") from exc
            with handle:
                for line_number, line in enumerate(handle, start=1):
                    if not line.strip():
                        continue
                    try:
                        event = json.loads(line)
                    except json.JSONDecodeError as exc:
                        raise SessionDataError(
                            f"invalid audit outbox file {path}:{line_number}: {exc}"
                        ) from exc
                    if not isinstance(event, dict):
                        raise SessionDataError(
                            f"audit outbox event must be an object: {path}:{line_number}"
                        )
                    payload = event.get("payload")
                    payload_event_id = (
                        payload.get("outbox_event_id")
                        if isinstance(payload, dict)
                        else None
                    )
                    envelope_event_id = event.get("outbox_event_id")
                    if event_id not in {payload_event_id, envelope_event_id}:
                        continue
                    if (
                        payload_event_id not in {None, event_id}
                        or envelope_event_id not in {None, event_id}
                        or event.get("session_id") != expected_session
                        or event.get("stage") != expected_stage
                    ):
                        raise SessionDataError(
                            f"audit outbox event identity mismatch for {event_id}: {path}:{line_number}"
                        )
                    return True
        return False

    def _deliver_committed_audit_locked(self, journal, journal_path):
        if journal.get("state") != "committed":
            raise SessionDataError(
                f"cannot deliver audit for an uncommitted session transaction: {journal_path}"
            )
        outbox = journal.get("audit_outbox", [])
        audit_state = journal.get(
            "audit_state",
            "complete" if not outbox else "pending",
        )
        if audit_state == "complete":
            return journal

        for event in outbox:
            if self._audit_outbox_event_exists_locked(event):
                continue
            self._audit_writer(
                self._target_path(event["path"]),
                event["session_id"],
                event["stage"],
                event["payload"],
            )

        delivered = dict(journal)
        delivered["audit_state"] = "complete"
        delivered["audit_completed_at"] = now_iso()
        self._write_journal_locked(journal_path, delivered)
        return delivered

    @staticmethod
    def _completion_with_audit_state(journal, error=None):
        completion = dict(journal["completion"])
        completion["audit_state"] = str(journal.get("audit_state") or "pending")
        if error is not None:
            completion["audit_error"] = str(error)[:400]
        return completion

    def _complete_committed_audit_locked(self, journal, journal_path):
        try:
            delivered = self._deliver_committed_audit_locked(journal, journal_path)
        except Exception as exc:  # The business-state commit is already durable.
            return self._completion_with_audit_state(journal, exc)
        return self._completion_with_audit_state(delivered)

    def _recover_journals_locked(self):
        if not self.journal_dir.is_dir():
            return []
        recovered = []
        for journal_path in sorted(self.journal_dir.glob("complete-*.json")):
            journal = self._read_journal_locked(journal_path)
            if journal["state"] == "prepared":
                self._rollback_journal_locked(journal, journal_path)
            else:
                self._deliver_committed_audit_locked(journal, journal_path)
            recovered.append(journal["job_id"])
        return recovered

    def _read_job_completion_file_locked(self, job_id):
        completion_path = self._completion_path(job_id)
        try:
            with completion_path.open("r", encoding="utf-8") as handle:
                completion = json.load(handle)
        except FileNotFoundError:
            return None
        except (OSError, json.JSONDecodeError) as exc:
            raise SessionDataError(
                f"invalid Job completion record {completion_path}: {exc}"
            ) from exc
        if not isinstance(completion, dict):
            raise SessionDataError(
                f"Job completion record must be an object: {completion_path}"
            )
        if completion.get("version") != 1 or completion.get("job_id") != str(job_id):
            raise SessionDataError(
                f"Job completion record identity mismatch: {completion_path}"
            )
        if not isinstance(completion.get("result"), dict) or not isinstance(
            completion.get("merge"), dict
        ):
            raise SessionDataError(
                f"Job completion record payload is invalid: {completion_path}"
            )
        merge = completion["merge"]
        if (
            not isinstance(completion.get("resource"), str)
            or not isinstance(merge.get("requested"), bool)
            or not isinstance(merge.get("history_merged_count"), int)
            or merge["history_merged_count"] < 0
            or not isinstance(merge.get("turn_persisted"), bool)
            or not isinstance(merge.get("workspace_session_id"), str)
            or not isinstance(merge.get("private_session_id"), str)
        ):
            raise SessionDataError(
                f"Job completion record merge summary is invalid: {completion_path}"
            )
        return completion

    def read_job_completion(self, job_id):
        """Return a committed Job completion record, or None when not durable."""

        with self._lock:
            journal_path = self._journal_path(job_id)
            journal = self._read_journal_locked(journal_path)
            if journal is None or journal["state"] != "committed":
                return None
            journal = self._deliver_committed_audit_locked(journal, journal_path)
            completion = self._read_job_completion_file_locked(job_id)
            if completion is None:
                raise SessionDataError(
                    f"committed session transaction has no Job completion record: {job_id}"
                )
            return completion

    @staticmethod
    def _next_turn_number(last_turn, path):
        if last_turn is None:
            return 1
        number = last_turn.get("number")
        if not isinstance(number, int) or isinstance(number, bool) or number < 1:
            raise SessionDataError(f"final persisted turn has an invalid number: {path}")
        return number + 1

    @staticmethod
    def _turn_payload(turn):
        payload_keys = (
            "mode",
            "input",
            "status",
            "created_at",
            "updated_at",
            "source",
            "result",
            "job_id",
            "context_eligible",
            "history_merged_count",
        )
        return {
            key: turn.get(key)
            for key in payload_keys
        }

    @classmethod
    def _assert_turns_consistent(cls, private_turn, workspace_turn, job_id):
        if cls._turn_payload(private_turn) != cls._turn_payload(workspace_turn):
            raise SessionDataError(f"private and workspace turns disagree for job {job_id}")

    @staticmethod
    def _copy_turn_for_paths(turn, paths, number):
        copied = dict(turn)
        copied["id"] = f"{paths.session_id}-turn-{number}"
        copied["number"] = number
        return copied

    @property
    def lock(self):
        return self._lock

    def paths_for(self, session_id):
        session_id = str(session_id)
        return SessionPaths(
            session_id=session_id,
            audit_log=self.root / "logs" / f"{session_id}.jsonl",
            history_file=self.root / "tmp" / "web" / "sessions" / f"{session_id}.history.json",
            turns_file=self.root / "tmp" / "web" / "sessions" / f"{session_id}.turns.jsonl",
        )

    def current_paths(self):
        with self._lock:
            return self.paths_for(self._session_id)

    def read_persisted_turns(self, session_id):
        session_id = str(session_id or "")
        if not SAFE_SESSION_ID.fullmatch(session_id):
            raise ValueError("session_id is required and must be a safe file name.")
        return read_turns(self.paths_for(session_id).turns_file)

    def context_turn_limit(self):
        try:
            value = int(self._config_reader().get("context_turns", 6))
        except (AttributeError, TypeError, ValueError):
            value = 6
        return max(0, value)

    def _record(self, paths, stage, payload=None):
        return self._audit_writer(
            paths.audit_log,
            paths.session_id,
            stage,
            payload if isinstance(payload, dict) else {},
        )

    def record_current(self, stage, payload=None):
        with self._lock:
            return self._record(self.paths_for(self._session_id), stage, payload)

    def _state_locked(self):
        paths = self.paths_for(self._session_id)
        history = read_json_array(paths.history_file)
        turns = read_turns(paths.turns_file)
        limit = self.context_turn_limit()
        window = history[-limit:] if limit else []
        return {
            "ok": True,
            "status": "active",
            "session_id": paths.session_id,
            "audit_log": str(paths.audit_log),
            "history_file": str(paths.history_file),
            "turns_file": str(paths.turns_file),
            "history_count": len(history),
            "context_turns": limit,
            "context_window_count": len(window),
            "turn_count": len(turns),
            "turns": turns,
            "restored_from": self._restored_from,
        }

    def state(self):
        with self._lock:
            return self._state_locked()

    def _finish_locked(self, status):
        if not self._session_id:
            return
        self._record(
            self.paths_for(self._session_id),
            "session_finished",
            {"status": str(status), "run_id": self.run_id},
        )

    def finish(self, status):
        with self._lock:
            self._finish_locked(status)

    def _start_locked(
        self,
        history=None,
        turns=None,
        restored_from="",
        start_reason="started",
        session_id=None,
    ):
        self._session_id = session_id or f"session_web_{uuid.uuid4().hex[:16]}"
        self._restored_from = str(restored_from or "")
        paths = self.paths_for(self._session_id)
        secure_truncate(paths.audit_log)
        write_json_atomic(paths.history_file, history if isinstance(history, list) else [])
        write_turns_atomic(paths.turns_file, turns if isinstance(turns, list) else [])
        self._record(
            paths,
            "session_started",
            {
                "request": "agent-web",
                "entrypoint": "web",
                "run_id": self.run_id,
                "started_at": now_iso(),
                "audit_mode": self._config_reader().get("audit_mode", "safe_summary"),
                "restored_from": self._restored_from,
                "start_reason": str(start_reason),
                "history_count": len(history) if isinstance(history, list) else 0,
                "turn_count": len(turns) if isinstance(turns, list) else 0,
            },
        )
        return self._state_locked()

    def initialize(self):
        with self._lock:
            self._recover_journals_locked()
            return self._start_locked(
                history=[],
                turns=[],
                start_reason="server_started",
                session_id=f"session_web_{self.run_id[:16]}",
            )

    def rotate(self, reason="rotated", history=None, turns=None, restored_from=""):
        with self._lock:
            self._finish_locked(reason)
            return self._start_locked(
                history=history if isinstance(history, list) else [],
                turns=turns if isinstance(turns, list) else [],
                restored_from=restored_from,
                start_reason=reason,
            )

    def restore(self, session_id):
        session_id = str(session_id or "")
        if not SAFE_SESSION_ID.fullmatch(session_id):
            return {
                "ok": False,
                "status": "invalid_session_id",
                "error": "session_id is required and must be a safe file name.",
            }
        source = self.paths_for(session_id)
        if not source.audit_log.is_file():
            return {"ok": False, "status": "not_found", "error": "Audit session not found."}
        try:
            turns = read_turns(source.turns_file)
        except SessionDataError as exc:
            return {"ok": False, "status": "persisted_turns_invalid", "error": str(exc)}
        if not turns:
            return {
                "ok": False,
                "status": "legacy_session_no_persisted_turns",
                "error": "该旧审计会话没有持久化权威 timeline，只能查看原始事件。",
            }
        try:
            history = _read_json_array_optional(source.history_file)
            if history is None:
                history = history_from_turns(turns)
            _validate_history_entries(history, "persisted session history")
        except SessionDataError as exc:
            return {
                "ok": False,
                "status": "persisted_session_invalid",
                "error": str(exc),
            }
        session = self.rotate(
            reason="restored_from_persisted_turns",
            history=history,
            turns=turns,
            restored_from=session_id,
        )
        return {
            "ok": True,
            "status": "restored",
            "session": session,
            "history_count": len(history),
            "turns": turns,
        }

    def leave(self):
        with self._lock:
            restored = self._restored_from
            reason = "left_restored" if restored else "rotated"
            self._finish_locked(reason)
            session = self._start_locked(
                history=[],
                turns=[],
                restored_from="",
                start_reason=reason,
            )
        return {
            "ok": True,
            "status": reason,
            "left_restored_from": restored,
            "session": session,
        }

    def discard_job_artifacts(self, job_id):
        """Remove all private durable and temporary files owned by one Job."""
        job_id = str(job_id)
        if not re.fullmatch(r"[0-9a-f]+", job_id):
            raise ValueError("job_id must be lowercase hexadecimal")
        private_session_id = f"job_{job_id}"
        audit_log = self.root / "logs" / f"{private_session_id}.jsonl"
        files = (
            audit_log,
            Path(f"{audit_log}.lock"),
            self.root / "tmp" / "web" / "jobs" / f"{job_id}.history.json",
            self._completion_path(job_id),
            self._journal_path(job_id),
            self.root / "tmp" / "web" / "sessions" / f"{private_session_id}.turns.jsonl",
        )
        with self._lock:
            for path in files:
                try:
                    path.unlink()
                except FileNotFoundError:
                    pass
            for archive in audit_log.parent.glob(f"{audit_log.name}.*"):
                suffix = archive.name.removeprefix(f"{audit_log.name}.")
                if re.fullmatch(r"[1-9][0-9]*", suffix):
                    archive.unlink()
            private_tmp_dir = self.root / "tmp" / private_session_id
            if private_tmp_dir.is_symlink():
                private_tmp_dir.unlink()
            elif private_tmp_dir.is_dir():
                shutil.rmtree(private_tmp_dir)
            else:
                try:
                    private_tmp_dir.unlink()
                except FileNotFoundError:
                    pass

    def create_job_context(self, job_id, request_id):
        job_id = str(job_id)
        if not re.fullmatch(r"[0-9a-f]+", job_id):
            raise ValueError("job_id must be lowercase hexadecimal")
        with self._lock:
            workspace = self.paths_for(self._session_id)
            history = read_json_array(workspace.history_file)
            limit = self.context_turn_limit()
            snapshot = history[-limit:] if limit else []
            _validate_history_entries(snapshot, "workspace history snapshot")
            snapshot_sha256 = _history_digest(snapshot)
            private_session_id = f"job_{job_id}"
            private = SessionPaths(
                session_id=private_session_id,
                audit_log=self.root / "logs" / f"{private_session_id}.jsonl",
                history_file=self.root / "tmp" / "web" / "jobs" / f"{job_id}.history.json",
                turns_file=self.root
                / "tmp"
                / "web"
                / "sessions"
                / f"{private_session_id}.turns.jsonl",
            )
            private_tmp_dir = self.root / "tmp" / private_session_id
            private_tmp_dir.mkdir(parents=True, exist_ok=True)
            _secure_mode(private_tmp_dir, 0o700)
            secure_truncate(private.audit_log)
            write_json_atomic(private.history_file, snapshot)
            write_turns_atomic(private.turns_file, [])
            context = JobSessionContext(
                job_id=job_id,
                request_id=str(request_id),
                created_at=now_iso(),
                workspace=workspace,
                private=private,
                private_tmp_dir=private_tmp_dir,
                snapshot_len=len(snapshot),
                snapshot_sha256=snapshot_sha256,
            )
            self._record(
                private,
                "session_started",
                {
                    "request": "agent-web-job",
                    "entrypoint": "web",
                    "run_id": self.run_id,
                    "job_id": job_id,
                    "request_id": str(request_id),
                    "workspace_session_id": workspace.session_id,
                    "history_snapshot_count": len(snapshot),
                    "history_snapshot_sha256": snapshot_sha256,
                },
            )
            return context

    @staticmethod
    def _turn(
        paths,
        number,
        mode,
        input_text,
        result,
        created_at,
        job_id="",
        updated_at=None,
        context_eligible=False,
        history_merged_count=0,
    ):
        timestamp = str(updated_at or now_iso())
        turn = {
            "id": f"{paths.session_id}-turn-{number}",
            "number": number,
            "mode": str(mode or "work"),
            "input": str(input_text or ""),
            "status": str(result.get("status") or "completed"),
            "created_at": str(created_at or timestamp),
            "updated_at": timestamp,
            "source": "persisted",
            "result": result,
            "context_eligible": bool(context_eligible),
            "history_merged_count": max(0, int(history_merged_count)),
        }
        if job_id:
            turn["job_id"] = job_id
        return turn

    def _audit_outbox_event(self, event_id, paths, stage, payload):
        try:
            relative_path = paths.audit_log.relative_to(self.root)
        except ValueError as exc:
            raise SessionDataError(
                f"audit outbox path is outside project root: {paths.audit_log}"
            ) from exc
        event_payload = dict(payload)
        event_payload["outbox_event_id"] = event_id
        return {
            "event_id": event_id,
            "path": str(relative_path),
            "session_id": paths.session_id,
            "stage": str(stage),
            "payload": event_payload,
        }

    def complete_job(self, context, resource, input_text, result, merge_history=False):
        """Finalize a private Job and serially merge its durable state."""

        if not isinstance(context, JobSessionContext):
            raise TypeError("context must be JobSessionContext")
        if not isinstance(result, dict):
            raise TypeError("result must be a JSON object")
        with self._lock:
            journal_path = self._journal_path(context.job_id)
            existing_journal = self._read_journal_locked(journal_path)
            if existing_journal is not None:
                if (
                    existing_journal.get("workspace_session_id")
                    != context.workspace.session_id
                    or existing_journal.get("private_session_id")
                    != context.private.session_id
                ):
                    raise SessionDataError(
                        f"job {context.job_id} already belongs to a different session transaction"
                    )
                if existing_journal["state"] == "committed":
                    if self._read_job_completion_file_locked(context.job_id) is None:
                        raise SessionDataError(
                            "committed session transaction has no Job completion record: "
                            f"{context.job_id}"
                        )
                    return self._complete_committed_audit_locked(
                        existing_journal,
                        journal_path,
                    )
                self._rollback_journal_locked(existing_journal, journal_path)

            existing_completion = self._read_job_completion_file_locked(context.job_id)
            if existing_completion is not None:
                merge = existing_completion["merge"]
                return {
                    "history_merged_count": int(merge.get("history_merged_count", 0)),
                    "turn_persisted": bool(merge.get("turn_persisted")),
                    "job_event_count": count_jsonl_events(context.private.audit_log),
                    "audit_state": "complete",
                }

            # Job completion is serialized and idempotence is owned by the
            # journal/completion record checks above. Only the JSONL tail is
            # needed to reconcile an interrupted append and allocate the next
            # turn number; scanning every historical turn made N completions
            # perform O(N^2) parsing even after writes became append-only.
            private_tail = read_last_turn(context.private.turns_file)
            workspace_tail = read_last_turn(context.workspace.turns_file)
            if private_tail is not None and private_tail.get("job_id") != context.job_id:
                raise SessionDataError(
                    f"private turn belongs to a different job: {context.job_id}"
                )
            private_job_turn = private_tail
            workspace_job_turn = (
                workspace_tail
                if workspace_tail is not None
                and workspace_tail.get("job_id") == context.job_id
                else None
            )
            private_next_number = self._next_turn_number(
                private_tail,
                context.private.turns_file,
            )
            workspace_next_number = self._next_turn_number(
                workspace_tail,
                context.workspace.turns_file,
            )
            job_was_already_persisted = bool(private_job_turn or workspace_job_turn)

            merged_history_count = 0
            transaction_targets = []
            if merge_history and not job_was_already_persisted:
                private_history = read_json_array(context.private.history_file)
                _validate_history_entries(private_history, "private Job history")
                if len(private_history) < context.snapshot_len:
                    raise SessionDataError(
                        f"private Job history truncated its snapshot for job {context.job_id}"
                    )
                snapshot_prefix = private_history[: context.snapshot_len]
                expected_snapshot_sha256 = str(context.snapshot_sha256 or "")
                if not re.fullmatch(r"[0-9a-f]{64}", expected_snapshot_sha256):
                    raise SessionDataError(
                        f"invalid history snapshot digest for job {context.job_id}"
                    )
                actual_snapshot_sha256 = _history_digest(snapshot_prefix)
                if actual_snapshot_sha256 != expected_snapshot_sha256:
                    raise SessionDataError(
                        f"private Job history modified its snapshot for job {context.job_id}"
                    )
                new_history = private_history[context.snapshot_len :]
                if new_history:
                    workspace_history = read_json_array(context.workspace.history_file)
                    _validate_history_entries(
                        workspace_history,
                        "workspace history before Job merge",
                    )
                    merged_history = [*workspace_history, *new_history]
                    transaction_targets.append(
                        self._transaction_target(
                            context.workspace.history_file,
                            "json_array",
                            workspace_history,
                            merged_history,
                        )
                    )
                    merged_history_count = len(new_history)

            turn_persisted = False
            if resource == "work":
                turn_persisted = True
                if private_job_turn and workspace_job_turn:
                    self._assert_turns_consistent(
                        private_job_turn,
                        workspace_job_turn,
                        context.job_id,
                    )
                elif private_job_turn:
                    workspace_job_turn = self._copy_turn_for_paths(
                        private_job_turn,
                        context.workspace,
                        workspace_next_number,
                    )
                    transaction_targets.append(
                        self._transaction_append_target(
                            context.workspace.turns_file,
                            [workspace_job_turn],
                        )
                    )
                elif workspace_job_turn:
                    private_job_turn = self._copy_turn_for_paths(
                        workspace_job_turn,
                        context.private,
                        private_next_number,
                    )
                    transaction_targets.append(
                        self._transaction_append_target(
                            context.private.turns_file,
                            [private_job_turn],
                        )
                    )
                else:
                    updated_at = now_iso()
                    private_job_turn = self._turn(
                        context.private,
                        private_next_number,
                        resource,
                        input_text,
                        result,
                        context.created_at,
                        job_id=context.job_id,
                        updated_at=updated_at,
                        context_eligible=bool(merge_history),
                        history_merged_count=merged_history_count,
                    )
                    workspace_job_turn = self._turn(
                        context.workspace,
                        workspace_next_number,
                        resource,
                        input_text,
                        result,
                        context.created_at,
                        job_id=context.job_id,
                        updated_at=updated_at,
                        context_eligible=bool(merge_history),
                        history_merged_count=merged_history_count,
                    )
                    transaction_targets.extend(
                        [
                            self._transaction_append_target(
                                context.private.turns_file,
                                [private_job_turn],
                            ),
                            self._transaction_append_target(
                                context.workspace.turns_file,
                                [workspace_job_turn],
                            ),
                        ]
                    )

            completion = {
                "history_merged_count": merged_history_count,
                "turn_persisted": turn_persisted,
                "context_eligible": bool(merge_history),
                # session_finished is the first outbox event and therefore part
                # of the final private-session event count even before delivery.
                "job_event_count": count_jsonl_events(context.private.audit_log) + 1,
            }
            completion_record = {
                "version": 1,
                "job_id": context.job_id,
                "request_id": context.request_id,
                "resource": str(resource),
                "status": str(result.get("status") or "failed"),
                "result": result,
                "merge": {
                    "requested": bool(merge_history),
                    "context_eligible": bool(merge_history),
                    "history_merged_count": merged_history_count,
                    "turn_persisted": turn_persisted,
                    "workspace_session_id": context.workspace.session_id,
                    "private_session_id": context.private.session_id,
                },
                "completed_at": now_iso(),
            }
            transaction_targets.append(
                self._transaction_target(
                    self._completion_path(context.job_id),
                    "json_object",
                    {},
                    completion_record,
                )
            )
            transaction_id = f"job-completion:{context.job_id}"
            audit_outbox = [
                self._audit_outbox_event(
                    f"{transaction_id}:private-finished",
                    context.private,
                    "session_finished",
                    {
                        "status": str(result.get("status") or "failed"),
                        "job_id": context.job_id,
                        "request_id": context.request_id,
                        "history_merged_count": merged_history_count,
                        "context_eligible": bool(merge_history),
                        "turn_persisted": turn_persisted,
                    },
                ),
                self._audit_outbox_event(
                    f"{transaction_id}:workspace-merged",
                    context.workspace,
                    "job_session_merged",
                    {
                        "job_id": context.job_id,
                        "request_id": context.request_id,
                        "job_session_id": context.private.session_id,
                        "job_audit_log": str(context.private.audit_log),
                        "job_event_count": completion["job_event_count"],
                        "status": str(result.get("status") or "failed"),
                        "history_merged_count": merged_history_count,
                        "context_eligible": bool(merge_history),
                        "turn_persisted": turn_persisted,
                    },
                ),
            ]
            prepared_journal = {
                "version": COMPLETE_JOB_JOURNAL_VERSION,
                "operation": "complete_job",
                "state": "prepared",
                "job_id": context.job_id,
                "workspace_session_id": context.workspace.session_id,
                "private_session_id": context.private.session_id,
                "prepared_at": now_iso(),
                "completion": completion,
                "targets": transaction_targets,
                "audit_state": "pending",
                "audit_outbox": audit_outbox,
            }
            self._write_journal_locked(journal_path, prepared_journal)

            try:
                for target in transaction_targets:
                    self._write_transaction_target_locked(target, "after")
                committed_journal = {
                    "version": COMPLETE_JOB_JOURNAL_VERSION,
                    "operation": "complete_job",
                    "state": "committed",
                    "job_id": context.job_id,
                    "workspace_session_id": context.workspace.session_id,
                    "private_session_id": context.private.session_id,
                    "committed_at": now_iso(),
                    "completion": completion,
                    "audit_state": "pending",
                    "audit_outbox": audit_outbox,
                }
                self._write_journal_locked(journal_path, committed_journal)
            except Exception as exc:
                try:
                    self._rollback_journal_locked(prepared_journal, journal_path)
                except Exception as rollback_exc:
                    raise SessionDataError(
                        f"session transaction failed and could not be rolled back: {rollback_exc}"
                    ) from exc
                raise

            # The durable commit is the point of no return. Audit delivery is an
            # idempotent outbox operation; a pending delivery is surfaced without
            # changing the already-persisted business result.
            return self._complete_committed_audit_locked(
                committed_journal,
                journal_path,
            )
