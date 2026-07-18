#!/usr/bin/env python3
"""Drain one process stream while retaining a bounded byte prefix."""

import argparse
import json
import os
import selectors
import sys
import time
from pathlib import Path


DEFAULT_PRODUCER_DRAIN_GRACE_SEC = 0.5


def producer_is_alive(pid):
    """Return whether the direct producer still has a live /proc entry."""

    if pid is None:
        return True
    try:
        # ``/proc/<pid>/stat`` keeps a zombie visible until its parent reaps it.
        # Treat zombies as dead so a reaped producer is not required for the
        # limiter to release a FIFO held open by an orphaned descendant.
        stat_line = Path(f"/proc/{int(pid)}/stat").read_text(encoding="ascii")
        _, _, fields = stat_line.rpartition(")")
        state = fields.strip().split(maxsplit=1)[0]
        return state not in {"Z", "X"}
    except (FileNotFoundError, ProcessLookupError, OSError, ValueError, IndexError):
        try:
            os.kill(int(pid), 0)
        except (ProcessLookupError, PermissionError, OSError, ValueError):
            return False
        return True


def atomic_marker(path, payload):
    marker = Path(path)
    marker.parent.mkdir(parents=True, exist_ok=True)
    temporary = marker.with_name(f".{marker.name}.{os.getpid()}.tmp")
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
    descriptor = os.open(temporary, flags, 0o600)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, ensure_ascii=True, separators=(",", ":"))
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, marker)
        os.chmod(marker, 0o600)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def drain(
    output_path,
    marker_path,
    max_bytes,
    producer_pid=None,
    producer_drain_grace_sec=DEFAULT_PRODUCER_DRAIN_GRACE_SEC,
):
    output = Path(output_path)
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
    descriptor = os.open(output, flags, 0o600)
    total = 0
    retained = 0
    marked = False
    producer_detached = False
    producer_deadline = None
    input_fd = 0
    selector = selectors.DefaultSelector()
    selector.register(input_fd, selectors.EVENT_READ)
    try:
        with os.fdopen(descriptor, "wb", buffering=0) as handle:
            while True:
                if producer_pid is not None and not producer_is_alive(producer_pid):
                    if producer_deadline is None:
                        producer_deadline = (
                            time.monotonic() + producer_drain_grace_sec
                        )
                    if time.monotonic() >= producer_deadline:
                        producer_detached = True
                        break
                poll_timeout = 0.1
                if producer_deadline is not None:
                    poll_timeout = min(
                        poll_timeout,
                        max(0.0, producer_deadline - time.monotonic()),
                    )
                events = selector.select(poll_timeout)
                if not events:
                    continue
                try:
                    chunk = os.read(input_fd, 65536)
                except BlockingIOError:
                    continue
                if not chunk:
                    break
                total += len(chunk)
                remaining = max(0, max_bytes - retained)
                if remaining:
                    piece = chunk[:remaining]
                    handle.write(piece)
                    retained += len(piece)
                if len(chunk) > remaining and not marked:
                    atomic_marker(
                        marker_path,
                        {"truncated": True, "retained_bytes": retained},
                    )
                    marked = True
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(output, 0o600)
        if marked:
            atomic_marker(
                marker_path,
                {
                    "truncated": True,
                    "total_bytes": total,
                    "retained_bytes": retained,
                    "truncated_bytes": max(0, total - retained),
                },
            )
        if producer_detached:
            atomic_marker(
                marker_path,
                {
                    "producer_detached": True,
                    "truncated": marked,
                    "total_bytes": total,
                    "retained_bytes": retained,
                    "truncated_bytes": max(0, total - retained),
                },
            )
    finally:
        selector.close()
        try:
            os.chmod(output, 0o600)
        except FileNotFoundError:
            pass
    return producer_detached


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    parser.add_argument("--marker", required=True)
    parser.add_argument("--max-bytes", required=True, type=int)
    parser.add_argument("--producer-pid", type=int)
    parser.add_argument(
        "--producer-drain-grace-ms",
        type=int,
        default=int(DEFAULT_PRODUCER_DRAIN_GRACE_SEC * 1000),
    )
    args = parser.parse_args()
    if args.max_bytes <= 0:
        parser.error("--max-bytes must be positive")
    if args.producer_pid is not None and args.producer_pid <= 1:
        parser.error("--producer-pid must be greater than one")
    if args.producer_drain_grace_ms < 0 or args.producer_drain_grace_ms > 5000:
        parser.error("--producer-drain-grace-ms must be between 0 and 5000")
    detached = drain(
        args.output,
        args.marker,
        args.max_bytes,
        producer_pid=args.producer_pid,
        producer_drain_grace_sec=args.producer_drain_grace_ms / 1000,
    )
    if detached:
        print(
            "output producer exited while a descendant still held the stream",
            file=sys.stderr,
        )
        return 125
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
