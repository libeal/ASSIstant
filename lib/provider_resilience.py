#!/usr/bin/env python3
"""Persistent circuit-breaker state for AI Provider calls."""

import argparse
import fcntl
import json
import os
import stat
import tempfile
import time
from contextlib import contextmanager
from pathlib import Path


MAX_STATE_BYTES = 1024 * 1024
MAX_ENTRIES = 256


def _write_all(descriptor, data):
    view = memoryview(data)
    offset = 0
    while offset < len(view):
        written = os.write(descriptor, view[offset:])
        if written <= 0:
            raise OSError("circuit state write made no forward progress")
        offset += written


class CircuitStore:
    def __init__(self, path, clock=time.time):
        self.path = Path(path)
        self.lock_path = self.path.with_name(f".{self.path.name}.lock")
        self.clock = clock

    @contextmanager
    def _locked(self):
        if self.path.parent.is_symlink():
            raise OSError("circuit state directory must not be a symbolic link")
        try:
            self.path.parent.mkdir(parents=True, exist_ok=False, mode=0o700)
        except FileExistsError:
            pass
        parent_metadata = self.path.parent.lstat()
        if not stat.S_ISDIR(parent_metadata.st_mode):
            raise OSError("circuit state parent is not a directory")
        if parent_metadata.st_uid != os.geteuid() or stat.S_IMODE(parent_metadata.st_mode) & 0o077:
            raise OSError("circuit state directory must be owned by the service user and have mode 0700")
        flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(str(self.lock_path), flags, 0o600)
        try:
            metadata = os.fstat(descriptor)
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.geteuid():
                raise OSError("circuit lock is not a regular file")
            os.fchmod(descriptor, 0o600)
            fcntl.flock(descriptor, fcntl.LOCK_EX)
            yield
        finally:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_UN)
            finally:
                os.close(descriptor)

    def _read(self):
        if self.path.is_symlink():
            raise OSError("circuit state must not be a symbolic link")
        try:
            metadata = self.path.lstat()
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.geteuid():
                raise OSError("circuit state must be owned by the service user and be a regular file")
            if stat.S_IMODE(metadata.st_mode) & 0o077:
                raise OSError("circuit state permissions are too broad")
            if metadata.st_size > MAX_STATE_BYTES:
                raise OSError("circuit state exceeds size limit")
            with self.path.open("r", encoding="utf-8") as handle:
                state = json.load(handle)
        except FileNotFoundError:
            return {"version": 1, "circuits": {}}
        if not isinstance(state, dict) or not isinstance(state.get("circuits"), dict):
            raise ValueError("circuit state is invalid")
        return state

    def _write(self, state):
        if self.path.is_symlink():
            raise OSError("circuit state must not be a symbolic link")
        payload = (json.dumps(state, separators=(",", ":"), sort_keys=True) + "\n").encode("utf-8")
        descriptor, raw_path = tempfile.mkstemp(prefix=f".{self.path.name}.", suffix=".tmp", dir=self.path.parent)
        temp_path = Path(raw_path)
        try:
            os.fchmod(descriptor, 0o600)
            _write_all(descriptor, payload)
            os.fsync(descriptor)
            os.close(descriptor)
            descriptor = -1
            os.replace(temp_path, self.path)
            directory = os.open(str(self.path.parent), os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        except Exception:
            if descriptor >= 0:
                os.close(descriptor)
            try:
                temp_path.unlink()
            except FileNotFoundError:
                pass
            raise

    @staticmethod
    def _prune(state):
        circuits = state["circuits"]
        if len(circuits) <= MAX_ENTRIES:
            return
        keep = sorted(circuits.items(), key=lambda item: float(item[1].get("updated_at", 0)), reverse=True)[:MAX_ENTRIES]
        state["circuits"] = dict(keep)

    def allow(self, key, threshold, open_seconds):
        now = float(self.clock())
        probe_lease = max(1.0, min(float(open_seconds), 10.0))
        with self._locked():
            state = self._read()
            circuit = state["circuits"].get(key, {})
            opened_until = float(circuit.get("opened_until", 0) or 0)
            probe_until = float(circuit.get("probe_until", 0) or 0)
            if opened_until > now:
                return {"allowed": False, "state": "open", "retry_after_sec": max(1, int(opened_until - now + 0.999))}
            if opened_until > 0 or int(circuit.get("failures", 0) or 0) >= threshold:
                if probe_until > now:
                    return {"allowed": False, "state": "half_open_busy", "retry_after_sec": max(1, int(probe_until - now + 0.999))}
                circuit.update({"failures": threshold, "opened_until": 0, "probe_until": now + probe_lease, "updated_at": now})
                state["circuits"][key] = circuit
                self._prune(state)
                self._write(state)
                return {"allowed": True, "state": "half_open", "retry_after_sec": 0}
            return {"allowed": True, "state": "closed", "retry_after_sec": 0}

    def record_failure(self, key, threshold, open_seconds):
        now = float(self.clock())
        with self._locked():
            state = self._read()
            circuit = state["circuits"].get(key, {})
            failures = int(circuit.get("failures", 0) or 0) + 1
            was_probe = float(circuit.get("probe_until", 0) or 0) > 0
            opened_until = 0.0
            if failures >= threshold or was_probe:
                failures = max(failures, threshold)
                opened_until = now + open_seconds
            circuit.update({"failures": failures, "opened_until": opened_until, "probe_until": 0, "updated_at": now})
            state["circuits"][key] = circuit
            self._prune(state)
            self._write(state)
            return {"state": "open" if opened_until else "closed", "failures": failures, "opened_until": opened_until}

    def record_success(self, key):
        with self._locked():
            state = self._read()
            if key in state["circuits"]:
                state["circuits"].pop(key)
                self._write(state)
        return {"state": "closed", "failures": 0}


def positive_int(value, name, minimum, maximum):
    parsed = int(value)
    if parsed < minimum or parsed > maximum:
        raise ValueError(f"{name} must be between {minimum} and {maximum}")
    return parsed


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("allow", "failure", "success"))
    parser.add_argument("state_path")
    parser.add_argument("key")
    parser.add_argument("threshold", nargs="?", default="5")
    parser.add_argument("open_seconds", nargs="?", default="60")
    args = parser.parse_args()

    threshold = positive_int(args.threshold, "threshold", 1, 100)
    open_seconds = positive_int(args.open_seconds, "open_seconds", 1, 86400)
    store = CircuitStore(args.state_path)
    if args.action == "allow":
        result = store.allow(args.key, threshold, open_seconds)
    elif args.action == "failure":
        result = store.record_failure(args.key, threshold, open_seconds)
    else:
        result = store.record_success(args.key)
    print(json.dumps(result, separators=(",", ":"), sort_keys=True))


if __name__ == "__main__":
    main()
