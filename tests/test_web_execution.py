#!/usr/bin/env python3
"""Unit tests for the Web process execution adapter."""

import json
import os
import signal
import subprocess
import sys
import tempfile
import textwrap
import threading
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
WEB_ROOT = ROOT / "web"
if str(WEB_ROOT) not in sys.path:
    sys.path.insert(0, str(WEB_ROOT))

import execution as execution_module  # noqa: E402
from execution import ExecutionService, RequestContext  # noqa: E402


FIXTURE_SOURCE = r"""
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

payload = json.loads(sys.argv[-1])
mode = payload.get("fixture", "json")

if mode == "silent":
    time.sleep(60)
elif mode == "ignore_term":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    Path(payload["pid_file"]).write_text(str(os.getpid()), encoding="utf-8")
    while True:
        time.sleep(1)
elif mode == "grandchild_side_effect":
    grandchild_source = r'''
import os
import sys
import time
from pathlib import Path

time.sleep(float(sys.argv[2]))
Path(sys.argv[1]).write_text(f"side-effect-from-{os.getpid()}", encoding="utf-8")
'''
    grandchild = subprocess.Popen([
        sys.executable,
        "-c",
        grandchild_source,
        payload["marker_file"],
        str(payload.get("delay", 1.0)),
    ])
    Path(payload["ready_file"]).write_text(
        json.dumps({
            "worker_pid": os.getpid(),
            "grandchild_pid": grandchild.pid,
            "process_group": os.getpgrp(),
        }),
        encoding="utf-8",
    )
    while True:
        time.sleep(1)
elif mode == "worker_exits_with_grandchild":
    grandchild_source = r'''
import os
import sys
import time
from pathlib import Path

time.sleep(float(sys.argv[2]))
Path(sys.argv[1]).write_text(f"side-effect-from-{os.getpid()}", encoding="utf-8")
'''
    grandchild = subprocess.Popen(
        [
            sys.executable,
            "-c",
            grandchild_source,
            payload["marker_file"],
            str(payload.get("delay", 0.5)),
        ],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    Path(payload["ready_file"]).write_text(str(grandchild.pid), encoding="utf-8")
    print(json.dumps({"ok": True, "status": "executed"}), flush=True)
elif mode == "partial":
    print("flow-one", file=sys.stderr, flush=True)
    time.sleep(0.3)
    print("flow-two", file=sys.stderr, flush=True)
    print(json.dumps({"ok": True, "status": "executed"}), flush=True)
else:
    print(json.dumps({
        "ok": True,
        "status": "executed",
        "payload": payload,
        "api_key": os.environ.get("LINUX_AGENT_API_KEY", ""),
        "request_id": os.environ.get("LINUX_AGENT_REQUEST_ID", ""),
    }), flush=True)
"""


class FakeSessionStore:
    def __init__(self, root):
        self.paths = SimpleNamespace(
            session_id="session_test",
            audit_log=root / "audit.jsonl",
            history_file=root / "history.json",
        )

    def current_paths(self):
        return self.paths


class ExecutionServiceTest(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.root = Path(self.temp_dir.name)
        self.fixture = self.root / "fixture.py"
        self.fixture.write_text(textwrap.dedent(FIXTURE_SOURCE), encoding="utf-8")
        self.agent = self.root / "agent"
        self.agent.write_text(
            '#!/usr/bin/env bash\nexec python3 "$EXECUTION_FIXTURE" "$@"\n',
            encoding="utf-8",
        )
        self.agent.chmod(0o700)
        self.tmp_dir = self.root / "job-tmp"
        self.tmp_dir.mkdir()
        self.registry = {}
        self.registry_lock = threading.Lock()
        self.partial_updates = []
        self.env_requests = []

        def env_builder(include_api_key=False):
            self.env_requests.append(include_api_key)
            env = os.environ.copy()
            env.pop("LINUX_AGENT_API_KEY", None)
            env["EXECUTION_FIXTURE"] = str(self.fixture)
            if include_api_key:
                env["LINUX_AGENT_API_KEY"] = "builder-controlled-secret"
            return env

        self.service = ExecutionService(
            root=self.root,
            agent=self.agent,
            env_builder=env_builder,
            session_store=FakeSessionStore(self.root),
            job_reader=lambda _job_id: {
                "status": "running",
                "cancel_requested_at": None,
            },
            partial_writer=lambda job_id, resource, text: self.partial_updates.append(
                (job_id, resource, text)
            ),
            workspace_lock=threading.RLock(),
            process_registry=self.registry,
            process_registry_lock=self.registry_lock,
            cancel_grace=0.1,
            default_job_timeout=0.15,
        )
        self.addCleanup(self.service.terminate_all)

    def job_context(self, job_id):
        return RequestContext(
            request_id=f"request-{job_id}",
            job_id=job_id,
            session_id=f"job_{job_id}",
            audit_log=self.root / f"{job_id}.jsonl",
            history_file=self.root / f"{job_id}.history.json",
            tmp_dir=self.tmp_dir,
        )

    def wait_for(self, predicate, timeout=3):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            value = predicate()
            if value:
                return value
            time.sleep(0.01)
        self.fail("condition was not satisfied before timeout")

    @staticmethod
    def process_can_run(pid):
        try:
            fields = Path(f"/proc/{int(pid)}/stat").read_text(encoding="utf-8").split()
        except (FileNotFoundError, ProcessLookupError):
            return False
        # A zombie can still answer kill(pid, 0), but cannot produce effects.
        return len(fields) > 2 and fields[2] not in {"Z", "X"}

    def test_synchronous_json_result_uses_compatible_envelope(self):
        result = self.service.run_sync(
            "terminal",
            "run",
            {"fixture": "json", "value": 7},
            timeout=2,
            request_id="sync-request",
        )
        self.assertTrue(result["ok"])
        self.assertEqual("executed", result["status"])
        self.assertEqual(7, result["payload"]["value"])
        self.assertEqual("sync-request", result["request_id"])
        self.assertFalse(result["timed_out"])
        self.assertFalse(result["cancelled"])
        runtime = next(
            block for block in result["output_blocks"] if block["title"] == "Agent runtime"
        )
        self.assertEqual(0, runtime["json"]["exit_code"])

    def test_external_command_uses_bounded_process_lifecycle(self):
        outcome = self.service.run_external_sync(
            [sys.executable, "-c", 'print("external-ok")'],
            {"PATH": os.environ.get("PATH", "/usr/bin:/bin")},
            timeout=2,
            resource="backup",
        )

        self.assertEqual(outcome.returncode, 0)
        self.assertEqual(outcome.stdout, "external-ok")
        self.assertFalse(outcome.output_limit_exceeded)

    def test_silent_job_times_out_and_is_reaped(self):
        started = time.monotonic()
        result = self.service.run_job(
            "work",
            "run",
            {"fixture": "silent"},
            context=self.job_context("timeout"),
        )
        self.assertLess(time.monotonic() - started, 3)
        self.assertFalse(result["ok"])
        self.assertEqual("timed_out", result["status"])
        self.assertTrue(result["timed_out"])
        self.assertFalse(result["cancelled"])
        self.assertNotIn("timeout", self.registry)

    def test_ignore_term_job_is_killed_and_reaped(self):
        pid_file = self.root / "ignore-term.pid"
        context = self.job_context("ignoreterm")
        with ThreadPoolExecutor(max_workers=1) as executor:
            future = executor.submit(
                self.service.run_job,
                "work",
                "run",
                {"fixture": "ignore_term", "pid_file": str(pid_file)},
                context,
                10,
            )
            self.wait_for(pid_file.exists)
            process = self.wait_for(lambda: self.registry.get("ignoreterm"))
            pid = int(pid_file.read_text(encoding="utf-8"))
            termination = self.service.terminate("ignoreterm")
            result = future.result(timeout=3)

        self.assertTrue(termination["ok"])
        # The registry tracks the supervisor, which exits on SIGTERM. The
        # execution thread may concurrently SIGKILL the remaining process group
        # before terminate() checks it, so sigkill_sent is not authoritative and
        # the supervisor return code can remain -SIGTERM. The worker PID check
        # below is the actual assertion that the SIGTERM-ignoring child died.
        self.assertIn(termination["returncode"], {-signal.SIGTERM, -signal.SIGKILL})
        self.assertTrue(termination["reaped"])
        self.assertIsNotNone(process.poll())
        self.assertEqual("cancelled", result["status"])
        self.assertTrue(result["cancelled"])
        self.assertFalse(result["timed_out"])
        self.assertNotIn("ignoreterm", self.registry)
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)

    def test_partial_stderr_callback_receives_running_output(self):
        with ThreadPoolExecutor(max_workers=1) as executor:
            future = executor.submit(
                self.service.run_job,
                "work",
                "run",
                {"fixture": "partial"},
                self.job_context("partial"),
                2,
            )
            self.wait_for(lambda: self.partial_updates)
            self.assertFalse(future.done(), "partial output arrived only after process exit")
            result = future.result(timeout=3)
        self.assertTrue(result["ok"])
        self.assertTrue(self.partial_updates)
        self.assertEqual("partial", self.partial_updates[-1][0])
        self.assertIn("flow-one", self.partial_updates[-1][2])
        self.assertIn("flow-two", self.partial_updates[-1][2])

    def test_terminate_all_reaps_every_registered_job(self):
        job_ids = ("allone", "alltwo")
        with ThreadPoolExecutor(max_workers=2) as executor:
            futures = []
            for job_id in job_ids:
                pid_file = self.root / f"{job_id}.pid"
                futures.append(
                    executor.submit(
                        self.service.run_job,
                        "work",
                        "run",
                        {"fixture": "ignore_term", "pid_file": str(pid_file)},
                        self.job_context(job_id),
                        10,
                    )
                )
            self.wait_for(lambda: all(job_id in self.registry for job_id in job_ids))
            termination = self.service.terminate_all()
            results = [future.result(timeout=3) for future in futures]

        self.assertEqual("terminated_all", termination["status"])
        self.assertEqual(set(job_ids), {item["job_id"] for item in termination["results"]})
        self.assertTrue(all(item["reaped"] for item in termination["results"]))
        self.assertTrue(all(result["status"] == "cancelled" for result in results))
        self.assertFalse(self.registry)

    @unittest.skipUnless(os.name == "posix", "POSIX process groups are required")
    def test_normal_worker_exit_reaps_remaining_process_group(self):
        ready_file = self.root / "remaining-grandchild.pid"
        marker_file = self.root / "remaining-grandchild-side-effect"

        result = self.service.run_sync(
            "terminal",
            "run",
            {
                "fixture": "worker_exits_with_grandchild",
                "ready_file": str(ready_file),
                "marker_file": str(marker_file),
                "delay": 0.4,
            },
            timeout=2,
        )

        self.assertTrue(result["ok"])
        grandchild_pid = int(ready_file.read_text(encoding="utf-8"))
        self.wait_for(lambda: not self.process_can_run(grandchild_pid))
        time.sleep(0.5)
        self.assertFalse(marker_file.exists())

    @unittest.skipUnless(
        sys.platform.startswith("linux"),
        "/proc file-descriptor accounting is required",
    )
    def test_repeated_execution_does_not_leak_liveness_or_output_fds(self):
        self.service.run_sync("terminal", "run", {"fixture": "json"}, timeout=2)
        before = set(os.listdir("/proc/self/fd"))

        for _ in range(10):
            result = self.service.run_sync(
                "terminal",
                "run",
                {"fixture": "json"},
                timeout=2,
            )
            self.assertTrue(result["ok"])

        self.assertEqual(before, set(os.listdir("/proc/self/fd")))

    @unittest.skipUnless(
        sys.platform.startswith("linux"),
        "/proc file-descriptor accounting is required",
    )
    def test_spawn_failure_closes_both_liveness_pipe_ends(self):
        before = set(os.listdir("/proc/self/fd"))

        with mock.patch.object(
            execution_module.subprocess,
            "Popen",
            side_effect=OSError("injected spawn failure"),
        ):
            with self.assertRaisesRegex(OSError, "injected spawn failure"):
                self.service._spawn(
                    ["bash", str(self.agent)],
                    os.environ.copy(),
                )

        self.assertEqual(before, set(os.listdir("/proc/self/fd")))

    def test_reader_thread_start_failure_reaps_process_and_closes_pipes(self):
        class FailingThread:
            @staticmethod
            def start():
                raise RuntimeError("injected reader start failure")

            @staticmethod
            def is_alive():
                return False

        spawned = []
        original_spawn = self.service._spawn

        def capture_spawn(command, env):
            process = original_spawn(command, env)
            spawned.append(process)
            return process

        with (
            mock.patch.object(self.service, "_spawn", side_effect=capture_spawn),
            mock.patch.object(
                execution_module.threading,
                "Thread",
                side_effect=lambda **_kwargs: FailingThread(),
            ),
        ):
            with self.assertRaisesRegex(RuntimeError, "injected reader start failure"):
                self.service.run_sync(
                    "terminal",
                    "run",
                    {"fixture": "silent"},
                    timeout=2,
                )

        self.assertEqual(1, len(spawned))
        process = spawned[0]
        self.assertIsNotNone(process.poll())
        self.assertIsNone(getattr(process, "_linux_agent_liveness_fd", None))
        self.assertTrue(process.stdout.closed)
        self.assertTrue(process.stderr.closed)

    def test_non_posix_termination_falls_back_to_direct_process_methods(self):
        class IgnoringProcess:
            pid = 12345

            def __init__(self):
                self.returncode = None
                self.terminate_called = False
                self.kill_called = False

            def poll(self):
                return self.returncode

            def terminate(self):
                self.terminate_called = True

            def kill(self):
                self.kill_called = True
                self.returncode = -9

            def wait(self, timeout=None):
                if self.returncode is None and timeout is not None:
                    raise subprocess.TimeoutExpired("fixture", timeout)
                return self.returncode

        process = IgnoringProcess()
        with mock.patch.object(execution_module, "POSIX_PROCESS_GROUPS", False):
            termination = self.service._terminate_process(process)

        self.assertTrue(process.terminate_called)
        self.assertTrue(process.kill_called)
        self.assertTrue(termination["reaped"])

    @unittest.skipUnless(
        sys.platform.startswith("linux"),
        "Linux PDEATHSIG and /proc are required",
    )
    def test_web_parent_sigkill_terminates_worker_process_group(self):
        ready_file = self.root / "parent-death-ready.json"
        marker_file = self.root / "orphan-side-effect"
        controller = self.root / "execution-controller.py"
        controller.write_text(
            textwrap.dedent(
                r'''
                import os
                import sys
                import threading
                from pathlib import Path
                from types import SimpleNamespace

                sys.path.insert(0, sys.argv[1])
                from execution import ExecutionService, RequestContext

                root = Path(sys.argv[2])
                agent = Path(sys.argv[3])
                fixture = sys.argv[4]
                ready_file = sys.argv[5]
                marker_file = sys.argv[6]

                class SessionStore:
                    def current_paths(self):
                        return SimpleNamespace(
                            session_id="controller",
                            audit_log=root / "controller.jsonl",
                            history_file=root / "controller.history.json",
                        )

                def env_builder(include_api_key=False):
                    del include_api_key
                    env = os.environ.copy()
                    env["EXECUTION_FIXTURE"] = fixture
                    return env

                service = ExecutionService(
                    root=root,
                    agent=agent,
                    env_builder=env_builder,
                    session_store=SessionStore(),
                    job_reader=lambda _job_id: {
                        "status": "running",
                        "cancel_requested_at": None,
                    },
                    partial_writer=None,
                    workspace_lock=threading.RLock(),
                    process_registry={},
                    process_registry_lock=threading.Lock(),
                    cancel_grace=0.1,
                    default_job_timeout=30,
                )
                context = RequestContext(
                    request_id="parent-death-request",
                    job_id="parentdeath",
                    session_id="job_parentdeath",
                    audit_log=root / "parentdeath.jsonl",
                    history_file=root / "parentdeath.history.json",
                    tmp_dir=root / "job-tmp",
                )
                service.run_job(
                    "work",
                    "run",
                    {
                        "fixture": "grandchild_side_effect",
                        "ready_file": ready_file,
                        "marker_file": marker_file,
                        "delay": 1.0,
                    },
                    context=context,
                    timeout=30,
                )
                '''
            ),
            encoding="utf-8",
        )
        controller_process = subprocess.Popen(
            [
                sys.executable,
                str(controller),
                str(WEB_ROOT),
                str(self.root),
                str(self.agent),
                str(self.fixture),
                str(ready_file),
                str(marker_file),
            ],
            start_new_session=True,
        )
        process_group = None

        def cleanup_controller():
            if controller_process.poll() is None:
                os.kill(controller_process.pid, signal.SIGKILL)
                controller_process.wait(timeout=3)
            if process_group is not None:
                try:
                    os.killpg(process_group, signal.SIGKILL)
                except ProcessLookupError:
                    pass

        self.addCleanup(cleanup_controller)
        self.wait_for(ready_file.exists)
        process_info = json.loads(ready_file.read_text(encoding="utf-8"))
        process_group = int(process_info["process_group"])
        worker_pid = int(process_info["worker_pid"])
        grandchild_pid = int(process_info["grandchild_pid"])
        self.assertTrue(self.process_can_run(worker_pid))
        self.assertTrue(self.process_can_run(grandchild_pid))

        os.kill(controller_process.pid, signal.SIGKILL)
        controller_process.wait(timeout=3)
        self.wait_for(
            lambda: not self.process_can_run(worker_pid)
            and not self.process_can_run(grandchild_pid),
            timeout=3,
        )
        time.sleep(1.2)

        self.assertFalse(marker_file.exists())


    def test_oversized_stdout_is_hard_capped(self):
        """Producer output must not be retained beyond max_output_bytes."""

        service = ExecutionService(
            root=self.root,
            agent=self.agent,
            env_builder=lambda include_api_key=False: os.environ.copy(),
            session_store=FakeSessionStore(self.root),
            job_reader=None,
            partial_writer=None,
            workspace_lock=threading.RLock(),
            process_registry={},
            process_registry_lock=threading.Lock(),
            max_output_bytes=4096,
        )
        context = service.workspace_context(request_id="output-cap")
        # Emit ~50 KiB so the hard cap is the only bound (not wall-clock timeout).
        command = [
            sys.executable,
            "-c",
            "import sys; sys.stdout.write(\"x\" * 50000); sys.stdout.flush()",
        ]
        outcome = service._execute(command, os.environ.copy(), context, "tools", timeout=10)
        self.assertLessEqual(len(outcome.stdout.encode("utf-8")), 4096)
        self.assertTrue(outcome.output_limit_exceeded)
        self.assertGreater(outcome.stdout_truncated_bytes, 0)
        self.assertIn("output capped", outcome.stderr)
        result = service._result_envelope(outcome, "tools", 10)
        self.assertEqual(result["status"], "output_limit_exceeded")
        self.assertTrue(result["output_blocks"][-1]["json"]["output_limit_exceeded"])

    def test_api_key_presence_is_controlled_only_by_env_builder(self):
        terminal = self.service.run_sync(
            "terminal",
            "run",
            {"fixture": "json"},
            timeout=2,
        )
        work = self.service.run_sync(
            "work",
            "run",
            {"fixture": "json"},
            timeout=2,
        )
        self.assertEqual("", terminal["api_key"])
        self.assertEqual("builder-controlled-secret", work["api_key"])
        self.assertEqual([False, True], self.env_requests[-2:])


if __name__ == "__main__":
    unittest.main()
