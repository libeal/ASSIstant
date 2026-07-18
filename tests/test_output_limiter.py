#!/usr/bin/env python3

import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class OutputLimiterTests(unittest.TestCase):
    def test_retains_exact_prefix_and_records_dropped_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "stdout"
            marker = root / "overflow.json"
            payload = ("界" * 2000).encode("utf-8")
            process = subprocess.run(
                [
                    sys.executable,
                    str(ROOT / "lib" / "output_limiter.py"),
                    "--output",
                    str(output),
                    "--marker",
                    str(marker),
                    "--max-bytes",
                    "4096",
                ],
                input=payload,
                check=True,
            )
            self.assertEqual(process.returncode, 0)
            self.assertEqual(output.read_bytes(), payload[:4096])
            metadata = json.loads(marker.read_text(encoding="utf-8"))
            self.assertEqual(metadata["total_bytes"], len(payload))
            self.assertEqual(metadata["retained_bytes"], 4096)
            self.assertEqual(metadata["truncated_bytes"], len(payload) - 4096)
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)
            self.assertEqual(marker.stat().st_mode & 0o777, 0o600)

    def test_detached_fifo_writer_does_not_block_limiter_forever(self):
        """A producer that exits while a detached child holds the FIFO is fail-closed."""

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fifo = root / "output.pipe"
            output = root / "stdout"
            marker = root / "overflow.json"
            child_pid_file = root / "child.pid"
            os.mkfifo(fifo, 0o600)
            producer = subprocess.Popen(
                [
                    sys.executable,
                    "-c",
                    (
                        "import os, pathlib, time\n"
                        "child = os.fork()\n"
                        "if child == 0:\n"
                        "    os.setsid()\n"
                        "    pathlib.Path(os.environ['CHILD_PID']).write_text(str(os.getpid()))\n"
                        "    fd = os.open(os.environ['FIFO'], os.O_WRONLY)\n"
                        "    os.write(fd, b'prefix')\n"
                        "    time.sleep(2)\n"
                        "    os.close(fd)\n"
                        "    os._exit(0)\n"
                        "os._exit(0)\n"
                    ),
                ],
                env={
                    "FIFO": str(fifo),
                    "CHILD_PID": str(child_pid_file),
                    "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
                },
            )
            reader_fd = os.open(fifo, os.O_RDONLY | os.O_NONBLOCK)
            reader = os.fdopen(reader_fd, "rb", buffering=0)
            try:
                deadline = time.monotonic() + 2
                while not child_pid_file.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                limiter = subprocess.run(
                    [
                        sys.executable,
                        str(ROOT / "lib" / "output_limiter.py"),
                        "--output",
                        str(output),
                        "--marker",
                        str(marker),
                        "--max-bytes",
                        "4096",
                        "--producer-pid",
                        str(producer.pid),
                    ],
                    stdin=reader,
                    capture_output=True,
                    timeout=2,
                    check=False,
                )
                producer.wait(timeout=2)
                self.assertEqual(limiter.returncode, 125)
                self.assertIn(b"producer exited", limiter.stderr)
                metadata = json.loads(marker.read_text(encoding="utf-8"))
                self.assertTrue(metadata["producer_detached"])
                self.assertEqual(output.read_bytes(), b"prefix")
            finally:
                reader.close()
                if child_pid_file.exists():
                    child_pid = int(child_pid_file.read_text(encoding="ascii"))
                    try:
                        os.kill(child_pid, 9)
                    except ProcessLookupError:
                        pass


if __name__ == "__main__":
    unittest.main()
