#!/usr/bin/env python3
"""Durable JSONL audit-chain writer and verifier shared by Bash and Web.

Each chained event contains three writer-owned fields:

``seq``
    A strictly increasing sequence number, starting at one.
``prev_hash``
    The previous event's ``hash`` (64 zeroes for the chain root).
``hash``
    ``sha256(prev_hash + canonical_json(event_without_hash))``.

The canonical JSON form uses UTF-8, sorted keys, and compact separators.  A
stable ``<log>.lock`` file serializes every writer across opening, rotation,
and append, so a rename never changes the object on which writers coordinate.
"""

import fcntl
import hashlib
import json
import os
import re
import shutil
import stat
import sys


GENESIS_HASH = "0" * 64
HASH_PATTERN = re.compile(r"^[0-9a-f]{64}$")
READ_BLOCK_SIZE = 65536


class AuditWriteBlocked(RuntimeError):
    """Raised when the configured disk-space policy refuses an audit write."""


class AuditIntegrityError(RuntimeError):
    """Raised when appending cannot trust the existing chain tail."""


def _reject_json_constant(value):
    raise ValueError(f"non-finite JSON number is not allowed: {value}")


def _reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key is not allowed: {key}")
        result[key] = value
    return result


def _loads_json(text):
    return json.loads(
        text,
        parse_constant=_reject_json_constant,
        object_pairs_hook=_reject_duplicate_keys,
    )


def _canonical_event(event):
    body = dict(event)
    body.pop("hash", None)
    return json.dumps(
        body,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=False,
    )


def event_hash(event):
    """Return the integrity hash for an event containing ``prev_hash``."""
    prev_hash = event.get("prev_hash")
    if not isinstance(prev_hash, str):
        raise ValueError("audit event prev_hash must be a string")
    material = prev_hash + _canonical_event(event)
    return hashlib.sha256(material.encode("utf-8")).hexdigest()


def _open_flags(base_flags):
    flags = base_flags
    flags |= getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    return flags


def _open_lock(lock_path):
    fd = os.open(lock_path, _open_flags(os.O_RDWR | os.O_CREAT), 0o600)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise OSError("audit lock path is not a regular file")
        os.fchmod(fd, 0o600)
    except Exception:
        os.close(fd)
        raise
    return fd


def _open_log(path):
    fd = os.open(path, _open_flags(os.O_RDWR | os.O_APPEND | os.O_CREAT), 0o600)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise OSError("audit log path is not a regular file")
        # os.open's mode only applies to a newly-created file.  Tighten an
        # existing file too, and refuse the write if that cannot be guaranteed.
        os.fchmod(fd, 0o600)
    except Exception:
        os.close(fd)
        raise
    return fd


def _fsync_directory(directory):
    flags = _open_flags(os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    directory_fd = os.open(directory, flags)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)


def _write_all(fd, data):
    view = memoryview(data)
    written = 0
    while written < len(view):
        count = os.write(fd, view[written:])
        if count <= 0:
            raise OSError("audit append made no forward progress")
        written += count


def _last_nonempty_line(fd):
    """Read the complete final non-empty line, regardless of its length."""
    size = os.fstat(fd).st_size
    position = size
    pending = b""

    while position > 0:
        count = min(READ_BLOCK_SIZE, position)
        position -= count
        pending = os.pread(fd, count, position) + pending
        parts = pending.split(b"\n")

        # When more bytes precede this block, parts[0] may be a partial line.
        # Every later part is complete and can be inspected from newest first.
        candidates = parts if position == 0 else parts[1:]
        for candidate in reversed(candidates):
            candidate = candidate.rstrip(b"\r")
            if candidate.strip():
                return candidate
        pending = parts[0]

    candidate = pending.rstrip(b"\r")
    return candidate if candidate.strip() else b""


def _free_bytes(path):
    try:
        statvfs = os.statvfs(os.path.dirname(os.path.abspath(path)) or ".")
        return statvfs.f_bavail * statvfs.f_frsize
    except OSError:
        return None


def _next_rotation_path(path):
    directory = os.path.dirname(path) or "."
    basename = os.path.basename(path)
    pattern = re.compile(rf"^{re.escape(basename)}\.([1-9][0-9]*)$")
    highest = 0
    with os.scandir(directory) as entries:
        for entry in entries:
            match = pattern.fullmatch(entry.name)
            if match is not None:
                highest = max(highest, int(match.group(1)))
    return f"{path}.{highest + 1}"


def _latest_rotation_path(path):
    directory = os.path.dirname(path) or "."
    basename = os.path.basename(path)
    pattern = re.compile(rf"^{re.escape(basename)}\.([1-9][0-9]*)$")
    latest = None
    latest_index = 0
    try:
        entries = os.scandir(directory)
    except OSError:
        return None
    with entries:
        for entry in entries:
            match = pattern.fullmatch(entry.name)
            if match is None or entry.is_symlink():
                continue
            index = int(match.group(1))
            if index > latest_index and entry.is_file(follow_symlinks=False):
                latest = os.path.join(directory, entry.name)
                latest_index = index
    return latest


def _valid_hash(value):
    return isinstance(value, str) and HASH_PATTERN.fullmatch(value) is not None


def _valid_seq(value):
    return isinstance(value, int) and not isinstance(value, bool) and value > 0


def _tail_chain_state(fd, path):
    """Return a self-consistent final event without scanning earlier lines."""
    raw = _last_nonempty_line(fd)
    location = os.path.basename(os.fspath(path))
    if not raw:
        raise AuditIntegrityError(f"existing audit chain tail is empty: {location}")
    try:
        text = raw.decode("utf-8")
        event = _loads_json(text)
    except (UnicodeDecodeError, json.JSONDecodeError, RecursionError, ValueError) as exc:
        raise AuditIntegrityError(f"existing audit chain tail is invalid at {location}: {exc}") from exc
    if not isinstance(event, dict):
        raise AuditIntegrityError(f"existing audit chain tail is not an object: {location}")

    missing = [field for field in ("seq", "prev_hash", "hash") if field not in event]
    if missing:
        raise AuditIntegrityError(
            f"existing audit chain tail is missing {','.join(missing)}: {location}"
        )
    seq = event.get("seq")
    previous_hash = event.get("prev_hash")
    stored_hash = event.get("hash")
    if not _valid_seq(seq):
        raise AuditIntegrityError(f"existing audit chain tail has invalid seq: {location}")
    if not _valid_hash(previous_hash):
        raise AuditIntegrityError(f"existing audit chain tail has invalid prev_hash: {location}")
    if not _valid_hash(stored_hash):
        raise AuditIntegrityError(f"existing audit chain tail has invalid hash: {location}")
    try:
        calculated_hash = event_hash(event)
    except (RecursionError, TypeError, ValueError) as exc:
        raise AuditIntegrityError(
            f"existing audit chain tail is not canonicalizable: {location}: {exc}"
        ) from exc
    if stored_hash != calculated_hash:
        raise AuditIntegrityError(f"existing audit chain tail hash mismatch: {location}")
    return seq, stored_hash


def _normalize_nonnegative(value, name):
    if isinstance(value, bool):
        raise ValueError(f"{name} must be a non-negative integer")
    try:
        normalized = int(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{name} must be a non-negative integer") from exc
    if normalized < 0:
        raise ValueError(f"{name} must be a non-negative integer")
    return normalized


def append_event(path, event, fsync=True, max_bytes=0, min_free_bytes=0, on_full="degrade"):
    """Append one event atomically and return its write/rotation status.

    ``AuditWriteBlocked`` is raised before the data file is changed when free
    space is below the configured block threshold. ``AuditIntegrityError`` is
    raised when the final non-empty event is not self-consistent. Full-chain
    validation, including rotated archives, is the explicit ``verify``
    operation so append remains O(1) in the number of existing events.
    """
    if not isinstance(event, dict):
        raise ValueError("audit event must be a JSON object")
    max_bytes = _normalize_nonnegative(max_bytes, "max_bytes")
    min_free_bytes = _normalize_nonnegative(min_free_bytes, "min_free_bytes")
    on_full = str(on_full).strip().lower()
    if on_full not in {"degrade", "block"}:
        raise ValueError("on_full must be degrade or block")

    path = os.path.abspath(os.fspath(path))
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, exist_ok=True)
    lock_path = f"{path}.lock"
    lock_fd = _open_lock(lock_path)
    log_fd = None
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX)

        rotation_target = None
        recovered_archive = None
        try:
            status = "ok"
            free = _free_bytes(path) if min_free_bytes else None
            space_check_failed = min_free_bytes > 0 and free is None
            space_low = free is not None and free < min_free_bytes
            if space_check_failed or space_low:
                if on_full == "block":
                    if space_check_failed:
                        raise AuditWriteBlocked("audit write blocked: free disk space could not be determined")
                    raise AuditWriteBlocked(
                        f"audit write blocked: free disk {free} bytes below minimum {min_free_bytes}"
                    )
                # Drop the potentially large/sensitive payload, but retain the
                # audit identity envelope.  Degradation is when request/job and
                # execution-user correlation matters most; replacing the whole
                # event would violate the shared AuditEvent contract.
                event = dict(event)
                event["payload"] = {
                    "audit_degraded": True,
                    "reason": "disk_space_check_failed" if space_check_failed else "disk_space_low",
                    "free_bytes": free,
                }
                status = "degraded"
            else:
                event = dict(event)

            # Integrity and rotation metadata are owned by the writer.
            for field in ("seq", "prev_hash", "hash", "rotated_from"):
                event.pop(field, None)

            # A crash can occur after the old live file was durably renamed and
            # either before replacement creation or while that replacement is
            # still empty. Resume from the newest valid archive rather than
            # silently starting a second genesis chain.
            if not os.path.lexists(path):
                recovered_archive = _latest_rotation_path(path)
            else:
                live_stat = os.stat(path, follow_symlinks=False)
                if stat.S_ISREG(live_stat.st_mode) and live_stat.st_size == 0:
                    recovered_archive = _latest_rotation_path(path)
            if recovered_archive is not None:
                archive_fd = _open_log(recovered_archive)
                try:
                    previous_seq, previous_hash = _tail_chain_state(
                        archive_fd,
                        recovered_archive,
                    )
                finally:
                    os.close(archive_fd)
                rotated_from = os.path.basename(recovered_archive)
                log_fd = _open_log(path)
                original_size = 0
                if status == "ok":
                    status = "recovered"
            else:
                log_fd = _open_log(path)
                original_size = os.fstat(log_fd).st_size
                if original_size > 0:
                    previous_seq, previous_hash = _tail_chain_state(log_fd, path)
                else:
                    previous_seq, previous_hash = 0, GENESIS_HASH
                rotated_from = ""

            if max_bytes and original_size >= max_bytes and original_size > 0:
                if fsync:
                    os.fsync(log_fd)
                target = _next_rotation_path(path)
                os.rename(path, target)
                rotation_target = target
                rotated_from = os.path.basename(target)
                if fsync:
                    _fsync_directory(directory)
                os.close(log_fd)
                log_fd = None
                log_fd = _open_log(path)
                original_size = 0
                if status == "ok":
                    status = "rotated"

            if rotated_from:
                event["rotated_from"] = rotated_from
            event["seq"] = previous_seq + 1
            event["prev_hash"] = previous_hash
            event["hash"] = event_hash(event)

            raw = json.dumps(event, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode("utf-8")
            needs_separator = original_size > 0 and os.pread(log_fd, 1, original_size - 1) != b"\n"
            data = (b"\n" if needs_separator else b"") + raw + b"\n"
            try:
                _write_all(log_fd, data)
                if fsync:
                    os.fsync(log_fd)
                    # Persist creation of the lock/live file and both directory
                    # changes made by rotation.
                    _fsync_directory(directory)
            except Exception:
                try:
                    os.ftruncate(log_fd, original_size)
                    if fsync:
                        os.fsync(log_fd)
                except OSError:
                    pass
                raise
            return status
        except Exception as exc:
            # If rotation/recovery created a replacement live file but the
            # append did not commit, restore the last complete durable state.
            rollback_required = rotation_target is not None or recovered_archive is not None
            if rollback_required:
                rollback_error = None
                try:
                    if log_fd is not None:
                        os.close(log_fd)
                        log_fd = None
                    if os.path.lexists(path):
                        os.unlink(path)
                    if rotation_target is not None and os.path.exists(rotation_target):
                        os.rename(rotation_target, path)
                    if fsync:
                        _fsync_directory(directory)
                except OSError as rollback_exc:
                    rollback_error = rollback_exc
                if rollback_error is not None:
                    raise AuditIntegrityError(
                        f"audit rotation failed and rollback was incomplete: {rollback_error}"
                    ) from exc
            raise
    finally:
        if log_fd is not None:
            try:
                os.close(log_fd)
            except OSError:
                pass
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_UN)
        except OSError:
            pass
        os.close(lock_fd)


def _add_break(report, path, line, reason, **detail):
    item = {"path": path, "line": line, "reason": reason}
    item.update(detail)
    report["breaks"].append(item)


class _ChainVerifier:
    def __init__(self, root_path, report):
        self.root_path = os.path.abspath(root_path)
        self.root_directory = os.path.realpath(os.path.dirname(self.root_path) or ".")
        self.root_name = os.path.basename(self.root_path)
        self.live_path = os.path.join(self.root_directory, self.root_name)
        self.rotation_pattern = re.compile(rf"^{re.escape(self.root_name)}\.([1-9][0-9]*)$")
        self.report = report
        self.visited = set()
        self.active = set()

    def _segment_index(self, path):
        match = self.rotation_pattern.fullmatch(os.path.basename(path))
        return int(match.group(1)) if match else None

    def _rotation_target(self, segment_path, line_number, rotated_from):
        if not isinstance(rotated_from, str) or not rotated_from:
            _add_break(
                self.report,
                segment_path,
                line_number,
                "invalid_rotated_from",
                found=rotated_from,
            )
            return None
        if os.path.basename(rotated_from) != rotated_from or self.rotation_pattern.fullmatch(rotated_from) is None:
            _add_break(
                self.report,
                segment_path,
                line_number,
                "rotation_path_escape",
                found=rotated_from,
            )
            return None

        current_index = self._segment_index(segment_path)
        target_index = int(self.rotation_pattern.fullmatch(rotated_from).group(1))
        if current_index is not None and target_index >= current_index:
            _add_break(
                self.report,
                segment_path,
                line_number,
                "invalid_rotation_order",
                current_index=current_index,
                target_index=target_index,
            )
            return None
        if current_index is None:
            latest = _latest_rotation_path(self.live_path)
            if latest is not None and os.path.basename(latest) != rotated_from:
                _add_break(
                    self.report,
                    segment_path,
                    line_number,
                    "rotation_not_latest",
                    expected=os.path.basename(latest),
                    found=rotated_from,
                )

        candidate = os.path.abspath(os.path.join(self.root_directory, rotated_from))
        real_candidate = os.path.realpath(candidate)
        if (
            os.path.dirname(candidate) != self.root_directory
            or real_candidate != candidate
            or os.path.islink(candidate)
        ):
            _add_break(
                self.report,
                segment_path,
                line_number,
                "rotation_path_escape",
                found=rotated_from,
            )
            return None
        try:
            mode = os.stat(candidate, follow_symlinks=False).st_mode
        except OSError as exc:
            _add_break(
                self.report,
                segment_path,
                line_number,
                "rotation_missing",
                rotated_from=rotated_from,
                error=str(exc),
            )
            return None
        if not stat.S_ISREG(mode):
            _add_break(
                self.report,
                segment_path,
                line_number,
                "rotation_not_regular",
                rotated_from=rotated_from,
            )
            return None
        return candidate

    def _parse_event(self, segment_path, line_number, raw):
        self.report["events"] += 1
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError as exc:
            _add_break(
                self.report,
                segment_path,
                line_number,
                "invalid_utf8",
                error=str(exc),
            )
            return None
        try:
            event = _loads_json(text)
        except (json.JSONDecodeError, RecursionError, ValueError) as exc:
            _add_break(
                self.report,
                segment_path,
                line_number,
                "invalid_json",
                error=str(exc),
            )
            return None
        if not isinstance(event, dict):
            _add_break(
                self.report,
                segment_path,
                line_number,
                "non_object",
                found_type=type(event).__name__,
            )
            return None
        return event

    def _verify_event(self, segment_path, line_number, event, expected_seq, expected_prev):
        missing = [field for field in ("seq", "prev_hash", "hash") if field not in event]
        if missing:
            _add_break(
                self.report,
                segment_path,
                line_number,
                "missing_chain_fields",
                fields=missing,
            )

        seq = event.get("seq")
        prev_hash = event.get("prev_hash")
        stored_hash = event.get("hash")
        valid_seq = _valid_seq(seq)
        valid_prev = _valid_hash(prev_hash)
        valid_stored = _valid_hash(stored_hash)

        if "seq" in event and not valid_seq:
            _add_break(self.report, segment_path, line_number, "invalid_seq", found=seq)
        elif valid_seq and expected_seq is not None and seq != expected_seq:
            _add_break(
                self.report,
                segment_path,
                line_number,
                "seq_mismatch",
                expected=expected_seq,
                found=seq,
            )

        if "prev_hash" in event and not valid_prev:
            _add_break(self.report, segment_path, line_number, "invalid_prev_hash", found=prev_hash)
        elif valid_prev and expected_prev is not None and prev_hash != expected_prev:
            _add_break(
                self.report,
                segment_path,
                line_number,
                "chain_mismatch",
                expected=expected_prev,
                found=prev_hash,
            )

        if "hash" in event and not valid_stored:
            _add_break(self.report, segment_path, line_number, "invalid_hash", found=stored_hash)
        elif valid_prev and valid_stored:
            try:
                calculated = event_hash(event)
            except (RecursionError, TypeError, ValueError) as exc:
                _add_break(
                    self.report,
                    segment_path,
                    line_number,
                    "invalid_canonical_json",
                    error=str(exc),
                )
            else:
                if stored_hash != calculated:
                    _add_break(
                        self.report,
                        segment_path,
                        line_number,
                        "hash_mismatch",
                        expected=calculated,
                        found=stored_hash,
                    )

        if valid_seq and valid_prev and valid_stored:
            self.report["chained_events"] += 1
            return seq, stored_hash
        return None, None

    def verify_segment(self, segment_path, is_root=False):
        segment_path = os.path.abspath(segment_path)
        identity = os.path.realpath(segment_path)
        if identity in self.active or identity in self.visited:
            _add_break(self.report, segment_path, 0, "rotation_cycle")
            return None, None
        self.active.add(identity)
        self.visited.add(identity)
        self.report["segments"] += 1
        self.report["files"].append(segment_path)

        last_seq = None
        last_hash = None
        saw_event = False
        try:
            fd = os.open(segment_path, _open_flags(os.O_RDONLY))
        except OSError as exc:
            _add_break(self.report, segment_path, 0, "read_error", error=str(exc))
            self.active.discard(identity)
            return None, None

        mode = stat.S_IMODE(os.fstat(fd).st_mode)
        if mode != 0o600:
            _add_break(
                self.report,
                segment_path,
                0,
                "insecure_permissions",
                expected="0600",
                found=f"{mode:04o}",
            )

        try:
            with os.fdopen(fd, "rb", closefd=True) as handle:
                for line_number, raw in enumerate(handle, start=1):
                    raw = raw.rstrip(b"\r\n")
                    if not raw.strip():
                        continue
                    event = self._parse_event(segment_path, line_number, raw)
                    if event is None:
                        saw_event = True
                        last_seq = None
                        last_hash = None
                        continue

                    if not saw_event:
                        saw_event = True
                        rotated_present = "rotated_from" in event
                        if rotated_present:
                            rotated_from = event.get("rotated_from")
                            if is_root and isinstance(rotated_from, str):
                                self.report["rotated_from"] = rotated_from
                            target = self._rotation_target(segment_path, line_number, rotated_from)
                            if target is not None:
                                archive_seq, archive_hash = self.verify_segment(target)
                                expected_seq = archive_seq + 1 if archive_seq is not None else None
                                expected_prev = archive_hash
                            else:
                                expected_seq = None
                                expected_prev = None
                        else:
                            segment_index = self._segment_index(segment_path)
                            if segment_index is not None and segment_index > 1:
                                _add_break(
                                    self.report,
                                    segment_path,
                                    line_number,
                                    "missing_rotated_from",
                                )
                            if is_root and segment_index is None:
                                latest = _latest_rotation_path(self.live_path)
                                if latest is not None:
                                    _add_break(
                                        self.report,
                                        segment_path,
                                        line_number,
                                        "orphaned_archives",
                                        latest=os.path.basename(latest),
                                    )
                            expected_seq = 1
                            expected_prev = GENESIS_HASH
                    else:
                        if "rotated_from" in event:
                            _add_break(
                                self.report,
                                segment_path,
                                line_number,
                                "unexpected_rotated_from",
                            )
                        expected_seq = last_seq + 1 if last_seq is not None else None
                        expected_prev = last_hash

                    last_seq, last_hash = self._verify_event(
                        segment_path,
                        line_number,
                        event,
                        expected_seq,
                        expected_prev,
                    )
        finally:
            self.active.discard(identity)

        if not saw_event:
            _add_break(self.report, segment_path, 0, "empty_log")
        return last_seq, last_hash


def verify_chain(path):
    """Recursively verify a live log and every ``rotated_from`` archive."""
    requested_path = os.fspath(path)
    absolute_path = os.path.abspath(requested_path)
    report = {
        "ok": False,
        "status": "integrity_broken",
        "path": requested_path,
        "events": 0,
        "chained_events": 0,
        "segments": 0,
        "files": [],
        "breaks": [],
        "rotated_from": "",
    }
    if not os.path.isfile(absolute_path) or os.path.islink(absolute_path):
        try:
            os.stat(absolute_path, follow_symlinks=False)
            error = "audit path is not a regular non-symlink file"
        except OSError as exc:
            error = str(exc)
        report["status"] = "not_found"
        report["error"] = error
        return report

    root_name = os.path.basename(absolute_path)
    lock_path = os.path.join(os.path.dirname(absolute_path), f"{root_name}.lock")
    lock_fd = None
    try:
        lock_fd = _open_lock(lock_path)
        fcntl.flock(lock_fd, fcntl.LOCK_SH)
        verifier = _ChainVerifier(absolute_path, report)
        verifier.verify_segment(absolute_path, is_root=True)
    except RecursionError as exc:
        _add_break(report, absolute_path, 0, "rotation_depth_exceeded", error=str(exc))
    except OSError as exc:
        _add_break(report, absolute_path, 0, "lock_error", error=str(exc))
    finally:
        if lock_fd is not None:
            try:
                fcntl.flock(lock_fd, fcntl.LOCK_UN)
            except OSError:
                pass
            os.close(lock_fd)

    report["ok"] = not report["breaks"] and report["events"] > 0
    report["status"] = "verified" if report["ok"] else "integrity_broken"
    return report


def snapshot_chain(path, destination_directory):
    """Copy one rotation-consistent audit chain into a private directory.

    Writers coordinate on ``<live>.lock`` across rotation and append. Holding a
    shared lock while discovering and copying every numeric segment guarantees
    that render, verify, and event parsing can subsequently consume one stable
    point-in-time view instead of observing three different chain tails.

    The live basename and archive suffixes are preserved because
    ``rotated_from`` stores basenames and verification intentionally validates
    those links.
    """
    source_path = os.path.abspath(os.fspath(path))
    destination_directory = os.path.abspath(os.fspath(destination_directory))
    source_directory = os.path.dirname(source_path) or "."
    source_name = os.path.basename(source_path)

    destination_stat = os.stat(destination_directory, follow_symlinks=False)
    if not stat.S_ISDIR(destination_stat.st_mode) or os.path.islink(destination_directory):
        raise OSError("audit snapshot destination is not a regular directory")

    lock_path = os.path.join(source_directory, f"{source_name}.lock")
    lock_fd = _open_lock(lock_path)
    created_paths = []
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_SH)

        if not os.path.lexists(source_path):
            raise FileNotFoundError("audit path does not exist")
        if not os.path.isfile(source_path) or os.path.islink(source_path):
            raise OSError("audit path is not a regular non-symlink file")

        rotation_pattern = re.compile(rf"^{re.escape(source_name)}\.([1-9][0-9]*)$")
        archives = []
        with os.scandir(source_directory) as entries:
            for entry in entries:
                match = rotation_pattern.fullmatch(entry.name)
                if match is None or entry.is_symlink():
                    continue
                if entry.is_file(follow_symlinks=False):
                    archives.append((int(match.group(1)), entry.path))

        ordered_sources = [candidate for _, candidate in sorted(archives)] + [source_path]
        for source in ordered_sources:
            destination = os.path.join(destination_directory, os.path.basename(source))
            source_fd = os.open(source, _open_flags(os.O_RDONLY))
            destination_fd = None
            try:
                if not stat.S_ISREG(os.fstat(source_fd).st_mode):
                    raise OSError("audit snapshot source is not a regular file")
                destination_fd = os.open(
                    destination,
                    _open_flags(os.O_WRONLY | os.O_CREAT | os.O_EXCL),
                    0o600,
                )
                with os.fdopen(source_fd, "rb", closefd=True) as source_handle:
                    source_fd = None
                    with os.fdopen(destination_fd, "wb", closefd=True) as destination_handle:
                        destination_fd = None
                        shutil.copyfileobj(source_handle, destination_handle, READ_BLOCK_SIZE)
                os.chmod(destination, 0o600, follow_symlinks=False)
                created_paths.append(destination)
            finally:
                if source_fd is not None:
                    os.close(source_fd)
                if destination_fd is not None:
                    os.close(destination_fd)

        return os.path.join(destination_directory, source_name)
    except Exception:
        for created_path in reversed(created_paths):
            try:
                os.unlink(created_path)
            except OSError:
                pass
        raise
    finally:
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_UN)
        except OSError:
            pass
        os.close(lock_fd)


def _parse_append_options(argv):
    if not argv:
        raise ValueError("audit log path is required")
    path = argv[0]
    fsync = True
    max_bytes = 0
    min_free_bytes = 0
    on_full = "degrade"
    index = 1
    while index < len(argv):
        arg = argv[index]
        if arg == "--no-fsync":
            fsync = False
            index += 1
            continue
        if arg not in {"--max-bytes", "--min-free-bytes", "--on-full"}:
            raise ValueError(f"unknown option: {arg}")
        if index + 1 >= len(argv):
            raise ValueError(f"missing value for {arg}")
        value = argv[index + 1]
        if arg == "--max-bytes":
            max_bytes = int(value or 0)
        elif arg == "--min-free-bytes":
            min_free_bytes = int(value or 0)
        else:
            on_full = value or "degrade"
        index += 2
    return path, {
        "fsync": fsync,
        "max_bytes": max_bytes,
        "min_free_bytes": min_free_bytes,
        "on_full": on_full,
    }


def _event_from_json(raw):
    event = _loads_json(raw)
    if not isinstance(event, dict):
        raise ValueError("event must be a JSON object")
    return event


def _append_once(path, event, options):
    try:
        append_event(path, event, **options)
    except AuditWriteBlocked as exc:
        return 3, f"audit_chain: {exc}"
    except AuditIntegrityError as exc:
        return 4, f"audit_chain: integrity error: {exc}"
    except (OSError, TypeError, ValueError) as exc:
        return 4, f"audit_chain: write failed: {exc}"
    return 0, ""


def _cli_append(argv):
    try:
        path, options = _parse_append_options(argv)
    except ValueError as exc:
        print(f"audit_chain: invalid option: {exc}", file=sys.stderr)
        return 2

    raw = sys.stdin.read()
    try:
        event = _event_from_json(raw)
    except (json.JSONDecodeError, RecursionError, ValueError) as exc:
        print(f"audit_chain: invalid event JSON: {exc}", file=sys.stderr)
        return 2
    code, message = _append_once(path, event, options)
    if message:
        print(message, file=sys.stderr)
    return code


def _cli_serve(argv):
    """Append newline-delimited events for one log using one interpreter."""
    try:
        path, options = _parse_append_options(argv)
    except ValueError as exc:
        print(f"audit_chain: invalid option: {exc}", file=sys.stderr)
        return 2

    try:
        for raw in sys.stdin:
            try:
                event = _event_from_json(raw)
            except (json.JSONDecodeError, RecursionError, ValueError) as exc:
                code, message = 2, f"audit_chain: invalid event JSON: {exc}"
            else:
                code, message = _append_once(path, event, options)
            message = " ".join(message.splitlines())
            print(f"{code}\t{message}", flush=True)
    except KeyboardInterrupt:
        return 130
    return 0


def _cli_verify(argv):
    report = verify_chain(argv[0])
    print(json.dumps(report, ensure_ascii=False, separators=(",", ":")))
    return 0 if report.get("ok") else 1


def _cli_snapshot(argv):
    if len(argv) != 2:
        print("audit_chain: snapshot requires <file> <destination-directory>", file=sys.stderr)
        return 2
    try:
        snapshot_path = snapshot_chain(argv[0], argv[1])
    except FileNotFoundError as exc:
        print(f"audit_chain: snapshot failed: {exc}", file=sys.stderr)
        return 5
    except OSError as exc:
        print(f"audit_chain: snapshot failed: {exc}", file=sys.stderr)
        return 4
    print(snapshot_path)
    return 0


def main(argv):
    if len(argv) >= 2 and argv[0] == "append":
        return _cli_append(argv[1:])
    if len(argv) >= 2 and argv[0] == "serve":
        return _cli_serve(argv[1:])
    if len(argv) >= 2 and argv[0] == "verify":
        return _cli_verify(argv[1:])
    if len(argv) >= 2 and argv[0] == "snapshot":
        return _cli_snapshot(argv[1:])
    print(
        "usage: audit_chain.py append|serve <file> [options] | verify <file> | "
        "snapshot <file> <destination-directory>",
        file=sys.stderr,
    )
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
