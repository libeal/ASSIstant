#!/usr/bin/env python3
"""Unit tests for transactional Web session persistence."""

import copy
import json
import sys
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
WEB_ROOT = ROOT / "web"
if str(WEB_ROOT) not in sys.path:
    sys.path.insert(0, str(WEB_ROOT))

import sessions as sessions_module  # noqa: E402
from sessions import (  # noqa: E402
    COMPLETE_JOB_JOURNAL_VERSION,
    SessionDataError,
    SessionStore,
    append_turn,
    count_jsonl_events,
    read_json_array,
    read_last_turn,
    read_turns,
    write_turns_atomic,
    write_json_atomic,
)


def audit_writer(path, session_id, stage, payload):
    append_turn(
        path,
        {
            "timestamp": sessions_module.now_iso(),
            "session_id": session_id,
            "stage": stage,
            "payload": payload,
        },
    )


def turn_payload(turn):
    return {
        key: value
        for key, value in turn.items()
        if key not in {"id", "number"}
    }


def history_entry(label, status="executed"):
    return {
        "type": "request",
        "mode": "work",
        "request": {"content": f"input-{label}"},
        "response": {"content": f"output-{label}", "status": status},
        "status": status,
        "started_at": "2026-07-01T00:00:00Z",
        "completed_at": "2026-07-01T00:00:01Z",
        "metadata": {},
    }


class SessionStoreTransactionTest(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.root = Path(self.temp_dir.name)
        self.store = SessionStore(
            self.root,
            "primary-run",
            lambda: {"context_turns": 6, "audit_mode": "safe_summary"},
            audit_writer,
        )
        self.store.initialize()

    @staticmethod
    def result():
        return {
            "ok": True,
            "status": "executed",
            "response": {"answer": "completed"},
            "timeline": [],
        }

    def context_with_history(self, job_id):
        context = self.store.create_job_context(job_id, f"request-{job_id}")
        private_history = read_json_array(context.private.history_file)
        private_history.append(history_entry(job_id))
        write_json_atomic(context.private.history_file, private_history)
        return context

    def test_complete_job_is_idempotent_by_job_id(self):
        context = self.context_with_history("a1b2")

        first = self.store.complete_job(
            context,
            "work",
            "inspect",
            self.result(),
            merge_history=True,
        )
        private_audit_count = count_jsonl_events(context.private.audit_log)
        workspace_audit_count = count_jsonl_events(context.workspace.audit_log)
        second = self.store.complete_job(
            context,
            "work",
            "inspect",
            self.result(),
            merge_history=True,
        )

        self.assertEqual(first, second)
        self.assertEqual(1, len(read_json_array(context.workspace.history_file)))
        private_turns = read_turns(context.private.turns_file)
        workspace_turns = read_turns(context.workspace.turns_file)
        self.assertEqual(1, len(private_turns))
        self.assertEqual(1, len(workspace_turns))
        self.assertEqual(turn_payload(private_turns[0]), turn_payload(workspace_turns[0]))
        self.assertTrue(private_turns[0]["context_eligible"])
        self.assertEqual(1, private_turns[0]["history_merged_count"])
        self.assertEqual(private_audit_count, count_jsonl_events(context.private.audit_log))
        self.assertEqual(workspace_audit_count, count_jsonl_events(context.workspace.audit_log))

        durable_completion = self.store.read_job_completion(context.job_id)
        self.assertEqual("work", durable_completion["resource"])
        self.assertEqual(self.result(), durable_completion["result"])
        self.assertEqual(1, durable_completion["merge"]["history_merged_count"])
        self.assertTrue(durable_completion["merge"]["turn_persisted"])

        journal = self.store._read_journal_locked(
            self.store._journal_path(context.job_id)
        )
        self.assertEqual("committed", journal["state"])
        self.assertEqual("complete", journal["audit_state"])
        self.assertNotIn("targets", journal)

    def test_cancelled_work_persists_a_non_context_turn(self):
        context = self.context_with_history("b2c3")
        result = {
            "ok": False,
            "status": "cancelled",
            "timeline": [],
            "approval_card": None,
            "output_blocks": [],
        }

        completion = self.store.complete_job(
            context,
            "work",
            "cancel this",
            result,
            merge_history=False,
        )

        self.assertEqual([], read_json_array(context.workspace.history_file))
        private_turn = read_turns(context.private.turns_file)[0]
        workspace_turn = read_turns(context.workspace.turns_file)[0]
        self.assertEqual("cancelled", private_turn["status"])
        self.assertFalse(private_turn["context_eligible"])
        self.assertEqual(0, private_turn["history_merged_count"])
        self.assertEqual(turn_payload(private_turn), turn_payload(workspace_turn))
        self.assertTrue(completion["turn_persisted"])
        self.assertFalse(completion["context_eligible"])

    def test_restore_preserves_an_existing_valid_empty_history(self):
        source = self.store.paths_for("session_empty_history_restore")
        append_turn(
            source.audit_log,
            {
                "timestamp": sessions_module.now_iso(),
                "session_id": source.session_id,
                "stage": "session_started",
                "payload": {},
            },
        )
        write_json_atomic(source.history_file, [])
        write_turns_atomic(
            source.turns_file,
            [
                {
                    "id": "eligible-turn",
                    "number": 1,
                    "mode": "work",
                    "input": "must not be rebuilt",
                    "status": "executed",
                    "created_at": "2026-07-01T00:00:00Z",
                    "updated_at": "2026-07-01T00:00:01Z",
                    "result": {
                        "ok": True,
                        "status": "executed",
                        "response": {"answer": "must not be rebuilt"},
                    },
                    "context_eligible": True,
                }
            ],
        )

        restored = self.store.restore(source.session_id)

        self.assertTrue(restored["ok"])
        self.assertEqual(0, restored["history_count"])
        self.assertEqual(
            [],
            read_json_array(Path(restored["session"]["history_file"])),
        )

    def test_restore_rebuilds_only_eligible_turns_when_history_is_missing(self):
        source = self.store.paths_for("session_missing_history_restore")
        append_turn(
            source.audit_log,
            {
                "timestamp": sessions_module.now_iso(),
                "session_id": source.session_id,
                "stage": "session_started",
                "payload": {},
            },
        )
        write_turns_atomic(
            source.turns_file,
            [
                {
                    "id": "eligible-turn",
                    "number": 1,
                    "mode": "work",
                    "input": "restore me",
                    "status": "executed",
                    "created_at": "2026-07-01T00:00:00Z",
                    "updated_at": "2026-07-01T00:00:01Z",
                    "result": {
                        "ok": True,
                        "status": "executed",
                        "response": {"answer": "restored answer"},
                    },
                    "context_eligible": True,
                },
                {
                    "id": "cancelled-turn",
                    "number": 2,
                    "mode": "work",
                    "input": "do not restore me",
                    "status": "cancelled",
                    "created_at": "2026-07-01T00:00:02Z",
                    "updated_at": "2026-07-01T00:00:03Z",
                    "result": {"ok": False, "status": "cancelled"},
                    "context_eligible": False,
                },
            ],
        )
        self.assertFalse(source.history_file.exists())

        restored = self.store.restore(source.session_id)

        self.assertTrue(restored["ok"])
        self.assertEqual(1, restored["history_count"])
        history = read_json_array(Path(restored["session"]["history_file"]))
        self.assertEqual(1, len(history))
        self.assertEqual("restore me", history[0]["request"]["content"])
        self.assertEqual("restored answer", history[0]["response"]["content"])

    def test_restore_rejects_a_corrupt_existing_history(self):
        source = self.store.paths_for("session_corrupt_history_restore")
        append_turn(
            source.audit_log,
            {
                "timestamp": sessions_module.now_iso(),
                "session_id": source.session_id,
                "stage": "session_started",
                "payload": {},
            },
        )
        write_turns_atomic(
            source.turns_file,
            [
                {
                    "id": "eligible-turn",
                    "number": 1,
                    "mode": "work",
                    "input": "must not restore",
                    "status": "executed",
                    "result": {"ok": True, "status": "executed"},
                    "context_eligible": True,
                }
            ],
        )
        source.history_file.parent.mkdir(parents=True, exist_ok=True)
        source.history_file.write_text("{broken", encoding="utf-8")
        active_before = self.store.current_paths().session_id

        restored = self.store.restore(source.session_id)

        self.assertFalse(restored["ok"])
        self.assertEqual("persisted_session_invalid", restored["status"])
        self.assertIn("invalid session history", restored["error"])
        self.assertEqual(active_before, self.store.current_paths().session_id)

    def test_history_merge_rejects_a_modified_snapshot_prefix(self):
        workspace = self.store.current_paths()
        baseline = [history_entry("baseline")]
        write_json_atomic(workspace.history_file, baseline)
        context = self.context_with_history("b2d4")
        private_history = read_json_array(context.private.history_file)
        private_history[0]["request"]["content"] = "forged snapshot"
        write_json_atomic(context.private.history_file, private_history)

        with self.assertRaisesRegex(SessionDataError, "modified its snapshot"):
            self.store.complete_job(
                context,
                "work",
                "inspect",
                self.result(),
                merge_history=True,
            )

        self.assertEqual(baseline, read_json_array(workspace.history_file))
        self.assertEqual([], read_turns(workspace.turns_file))
        self.assertIsNone(self.store.read_job_completion(context.job_id))

    def test_history_merge_rejects_truncated_snapshot_and_malformed_tail(self):
        workspace = self.store.current_paths()
        baseline = [history_entry("first"), history_entry("second")]
        write_json_atomic(workspace.history_file, baseline)

        truncated = self.store.create_job_context("b2d5", "request-b2d5")
        write_json_atomic(
            truncated.private.history_file,
            [history_entry("forged-tail")],
        )
        with self.assertRaisesRegex(SessionDataError, "truncated its snapshot"):
            self.store.complete_job(
                truncated,
                "work",
                "inspect",
                self.result(),
                merge_history=True,
            )

        malformed = self.store.create_job_context("b2d6", "request-b2d6")
        private_history = read_json_array(malformed.private.history_file)
        private_history.append({"type": "request", "status": "executed"})
        write_json_atomic(malformed.private.history_file, private_history)
        with self.assertRaisesRegex(SessionDataError, "request/response must be objects"):
            self.store.complete_job(
                malformed,
                "work",
                "inspect",
                self.result(),
                merge_history=True,
            )

        self.assertEqual(baseline, read_json_array(workspace.history_file))
        self.assertEqual([], read_turns(workspace.turns_file))

    def test_history_merge_rejects_a_missing_snapshot_digest(self):
        workspace = self.store.current_paths()
        baseline = [history_entry("legacy-baseline")]
        write_json_atomic(workspace.history_file, baseline)
        context = self.store.create_job_context("b2d7", "request-b2d7")
        legacy_context = replace(context, snapshot_sha256="")
        private_history = read_json_array(context.private.history_file)
        private_history.append(history_entry("legacy-new"))
        write_json_atomic(context.private.history_file, private_history)

        with self.assertRaisesRegex(SessionDataError, "invalid history snapshot digest"):
            self.store.complete_job(
                legacy_context,
                "work",
                "inspect",
                self.result(),
                merge_history=True,
            )

        self.assertEqual(baseline, read_json_array(workspace.history_file))
        self.assertEqual([], read_turns(workspace.turns_file))
        self.assertIsNone(self.store.read_job_completion(context.job_id))

    def test_history_merge_rejects_a_malformed_current_workspace_history(self):
        context = self.context_with_history("b2d8")
        write_json_atomic(
            context.workspace.history_file,
            [{"type": "request", "status": "executed"}],
        )

        with self.assertRaisesRegex(SessionDataError, "request/response must be objects"):
            self.store.complete_job(
                context,
                "work",
                "inspect",
                self.result(),
                merge_history=True,
            )

        self.assertEqual([], read_turns(context.workspace.turns_file))
        self.assertIsNone(self.store.read_job_completion(context.job_id))

    def test_discard_job_artifacts_removes_every_private_job_file(self):
        context = self.context_with_history("b3c4")
        self.store.complete_job(
            context,
            "work",
            "inspect",
            self.result(),
            merge_history=True,
        )
        audit_lock = Path(f"{context.private.audit_log}.lock")
        audit_lock.touch()
        audit_archives = (
            Path(f"{context.private.audit_log}.1"),
            Path(f"{context.private.audit_log}.2"),
        )
        for archive in audit_archives:
            archive.touch()
        unrelated_audit_file = Path(f"{context.private.audit_log}.backup")
        unrelated_audit_file.touch()
        private_tmp_file = context.private_tmp_dir / "artifact"
        private_tmp_file.write_text("temporary", encoding="utf-8")
        private_files = (
            context.private.audit_log,
            audit_lock,
            context.private.history_file,
            context.private.turns_file,
            self.store._completion_path(context.job_id),
            self.store._journal_path(context.job_id),
            *audit_archives,
        )
        self.assertTrue(all(path.exists() for path in private_files))

        self.store.discard_job_artifacts(context.job_id)

        self.assertTrue(all(not path.exists() for path in private_files))
        self.assertFalse(context.private_tmp_dir.exists())
        self.assertTrue(unrelated_audit_file.is_file())
        self.assertTrue(context.workspace.history_file.is_file())
        self.assertTrue(context.workspace.turns_file.is_file())
        self.store.discard_job_artifacts(context.job_id)

    def test_mid_transaction_write_failure_rolls_back_every_target(self):
        context = self.context_with_history("c3d4")
        original_append = SessionStore._append_turns_locked
        injected = False

        def fail_workspace_turn_once(store_self, path, turns):
            nonlocal injected
            is_new_workspace_turn = Path(path) == context.workspace.turns_file and any(
                turn.get("job_id") == context.job_id for turn in turns
            )
            if is_new_workspace_turn and not injected:
                injected = True
                raise OSError("injected workspace turn failure")
            return original_append(store_self, path, turns)

        with mock.patch.object(
            SessionStore,
            "_append_turns_locked",
            autospec=True,
            side_effect=fail_workspace_turn_once,
        ):
            with self.assertRaisesRegex(OSError, "injected workspace turn failure"):
                self.store.complete_job(
                    context,
                    "work",
                    "inspect",
                    self.result(),
                    merge_history=True,
                )

        self.assertTrue(injected)
        self.assertEqual([], read_json_array(context.workspace.history_file))
        self.assertEqual([], read_turns(context.private.turns_file))
        self.assertEqual([], read_turns(context.workspace.turns_file))
        self.assertIsNone(self.store.read_job_completion(context.job_id))
        self.assertFalse(self.store._journal_path(context.job_id).exists())

        self.store.complete_job(
            context,
            "work",
            "inspect",
            self.result(),
            merge_history=True,
        )
        self.assertEqual(1, len(read_json_array(context.workspace.history_file)))
        self.assertEqual(1, len(read_turns(context.private.turns_file)))
        self.assertEqual(1, len(read_turns(context.workspace.turns_file)))
        self.assertIsNotNone(self.store.read_job_completion(context.job_id))

    def test_completion_record_failure_rolls_back_session_state(self):
        context = self.context_with_history("d4e5")
        completion_path = self.store._completion_path(context.job_id)
        original_write_json = sessions_module.write_json_atomic
        injected = False

        def fail_completion_once(path, value):
            nonlocal injected
            if Path(path) == completion_path and not injected:
                injected = True
                raise OSError("injected completion record failure")
            return original_write_json(path, value)

        with mock.patch.object(
            sessions_module,
            "write_json_atomic",
            side_effect=fail_completion_once,
        ):
            with self.assertRaisesRegex(OSError, "injected completion record failure"):
                self.store.complete_job(
                    context,
                    "work",
                    "inspect",
                    self.result(),
                    merge_history=True,
                )

        self.assertTrue(injected)
        self.assertEqual([], read_json_array(context.workspace.history_file))
        self.assertEqual([], read_turns(context.private.turns_file))
        self.assertEqual([], read_turns(context.workspace.turns_file))
        self.assertIsNone(self.store.read_job_completion(context.job_id))
        self.assertFalse(self.store._journal_path(context.job_id).exists())

    def test_committed_journal_failure_rolls_back_without_false_audit(self):
        context = self.context_with_history("d5e6")
        original_write_journal = self.store._write_journal_locked

        def fail_committed(journal_path, journal):
            if journal.get("state") == "committed":
                raise OSError("injected committed journal failure")
            return original_write_journal(journal_path, journal)

        with mock.patch.object(
            self.store,
            "_write_journal_locked",
            side_effect=fail_committed,
        ):
            with self.assertRaisesRegex(OSError, "injected committed journal failure"):
                self.store.complete_job(
                    context,
                    "work",
                    "inspect",
                    self.result(),
                    merge_history=True,
                )

        self.assertEqual([], read_json_array(context.workspace.history_file))
        self.assertEqual([], read_turns(context.private.turns_file))
        self.assertEqual([], read_turns(context.workspace.turns_file))
        self.assertIsNone(self.store.read_job_completion(context.job_id))
        self.assertFalse(self.store._journal_path(context.job_id).exists())
        private_stages = [event["stage"] for event in read_turns(context.private.audit_log)]
        workspace_stages = [event["stage"] for event in read_turns(context.workspace.audit_log)]
        self.assertNotIn("session_finished", private_stages)
        self.assertNotIn("job_session_merged", workspace_stages)

    def test_committed_pending_audit_is_recovered_without_duplicates(self):
        context = self.context_with_history("d6e7")
        original_audit_writer = self.store._audit_writer
        failed = False

        def fail_workspace_audit_once(path, session_id, stage, payload):
            nonlocal failed
            if stage == "job_session_merged" and not failed:
                failed = True
                raise OSError("injected workspace audit failure")
            return original_audit_writer(path, session_id, stage, payload)

        self.store._audit_writer = fail_workspace_audit_once
        completion = self.store.complete_job(
            context,
            "work",
            "inspect",
            self.result(),
            merge_history=True,
        )
        self.assertEqual("pending", completion["audit_state"])
        self.assertIn("injected workspace audit failure", completion["audit_error"])

        journal_path = self.store._journal_path(context.job_id)
        pending = self.store._read_journal_locked(journal_path)
        self.assertEqual("committed", pending["state"])
        self.assertEqual("pending", pending["audit_state"])
        self.assertEqual(1, len(read_json_array(context.workspace.history_file)))
        self.assertEqual(1, len(read_turns(context.workspace.turns_file)))
        self.assertEqual(
            1,
            sum(
                event["stage"] == "session_finished"
                for event in read_turns(context.private.audit_log)
            ),
        )
        self.assertEqual(
            0,
            sum(
                event["stage"] == "job_session_merged"
                for event in read_turns(context.workspace.audit_log)
            ),
        )

        recovered_store = SessionStore(
            self.root,
            "outbox-recovery-run",
            lambda: {"context_turns": 6, "audit_mode": "safe_summary"},
            audit_writer,
        )
        recovered_store.initialize()

        delivered = recovered_store._read_journal_locked(journal_path)
        self.assertEqual("complete", delivered["audit_state"])
        self.assertEqual(
            1,
            sum(
                event["stage"] == "session_finished"
                for event in read_turns(context.private.audit_log)
            ),
        )
        self.assertEqual(
            1,
            sum(
                event["stage"] == "job_session_merged"
                for event in read_turns(context.workspace.audit_log)
            ),
        )
        self.assertIsNotNone(recovered_store.read_job_completion(context.job_id))

    def test_degraded_audit_envelope_keeps_outbox_delivery_idempotent(self):
        context = self.context_with_history("d6e8")
        workspace_delivery_failed = False

        def degrade_private_then_fail_workspace(path, session_id, stage, payload):
            nonlocal workspace_delivery_failed
            if stage == "session_finished":
                append_turn(
                    path,
                    {
                        "timestamp": sessions_module.now_iso(),
                        "session_id": session_id,
                        "stage": stage,
                        "outbox_event_id": payload["outbox_event_id"],
                        "payload": {"audit_degraded": True},
                    },
                )
                return
            if stage == "job_session_merged" and not workspace_delivery_failed:
                workspace_delivery_failed = True
                raise OSError("injected workspace audit failure")
            return audit_writer(path, session_id, stage, payload)

        self.store._audit_writer = degrade_private_then_fail_workspace
        completion = self.store.complete_job(
            context,
            "work",
            "inspect",
            self.result(),
            merge_history=True,
        )
        self.assertEqual("pending", completion["audit_state"])
        self.assertIn("injected workspace audit failure", completion["audit_error"])

        recovered_store = SessionStore(
            self.root,
            "degraded-outbox-recovery-run",
            lambda: {"context_turns": 6, "audit_mode": "safe_summary"},
            audit_writer,
        )
        recovered_store.initialize()

        private_finished = [
            event
            for event in read_turns(context.private.audit_log)
            if event.get("stage") == "session_finished"
        ]
        workspace_merged = [
            event
            for event in read_turns(context.workspace.audit_log)
            if event.get("stage") == "job_session_merged"
        ]
        self.assertEqual(1, len(private_finished))
        self.assertTrue(private_finished[0]["payload"]["audit_degraded"])
        self.assertEqual(1, len(workspace_merged))
        self.assertEqual(
            "complete",
            recovered_store._read_journal_locked(
                recovered_store._journal_path(context.job_id)
            )["audit_state"],
        )

    def test_initialize_rolls_back_prepared_journal(self):
        baseline_history = [history_entry("baseline")]
        workspace = self.store.current_paths()
        write_json_atomic(workspace.history_file, baseline_history)
        context = self.store.create_job_context("e5f6", "request-e5f6")
        new_history = [*baseline_history, history_entry("new")]
        updated_at = sessions_module.now_iso()
        private_turn = self.store._turn(
            context.private,
            1,
            "work",
            "inspect",
            self.result(),
            context.created_at,
            context.job_id,
            updated_at,
        )
        workspace_turn = self.store._turn(
            context.workspace,
            1,
            "work",
            "inspect",
            self.result(),
            context.created_at,
            context.job_id,
            updated_at,
        )
        completion_record = {
            "version": 1,
            "job_id": context.job_id,
            "request_id": context.request_id,
            "resource": "work",
            "status": "executed",
            "result": self.result(),
            "merge": {
                "requested": True,
                "history_merged_count": 1,
                "turn_persisted": True,
                "workspace_session_id": context.workspace.session_id,
                "private_session_id": context.private.session_id,
            },
            "completed_at": sessions_module.now_iso(),
        }
        targets = [
            self.store._transaction_target(
                context.workspace.history_file,
                "json_array",
                baseline_history,
                new_history,
            ),
            self.store._transaction_target(
                context.private.turns_file,
                "turns",
                [],
                [private_turn],
            ),
            self.store._transaction_target(
                context.workspace.turns_file,
                "turns",
                [],
                [workspace_turn],
            ),
            self.store._transaction_target(
                self.store._completion_path(context.job_id),
                "json_object",
                {},
                completion_record,
            ),
        ]
        journal_path = self.store._journal_path(context.job_id)
        journal = {
            "version": COMPLETE_JOB_JOURNAL_VERSION,
            "operation": "complete_job",
            "state": "prepared",
            "job_id": context.job_id,
            "workspace_session_id": context.workspace.session_id,
            "private_session_id": context.private.session_id,
            "prepared_at": sessions_module.now_iso(),
            "completion": {
                "history_merged_count": 1,
                "turn_persisted": True,
                "job_event_count": 0,
            },
            "targets": targets,
        }
        self.store._write_journal_locked(journal_path, journal)
        for target in targets:
            self.store._write_transaction_target_locked(target, "after")

        self.assertEqual(new_history, read_json_array(context.workspace.history_file))
        self.assertEqual([private_turn], read_turns(context.private.turns_file))
        self.assertEqual([workspace_turn], read_turns(context.workspace.turns_file))
        self.assertTrue(self.store._completion_path(context.job_id).is_file())
        self.assertIsNone(self.store.read_job_completion(context.job_id))

        recovered_store = SessionStore(
            self.root,
            "recovery-run",
            lambda: {"context_turns": 6, "audit_mode": "safe_summary"},
            audit_writer,
        )
        recovered_store.initialize()

        self.assertEqual(baseline_history, read_json_array(context.workspace.history_file))
        self.assertEqual([], read_turns(context.private.turns_file))
        self.assertEqual([], read_turns(context.workspace.turns_file))
        self.assertIsNone(recovered_store.read_job_completion(context.job_id))
        self.assertFalse(journal_path.exists())


class AppendOnlyTurnsTest(SessionStoreTransactionTest):
    """The append-only turns target keeps completion O(1), not O(N^2)."""

    def test_sequential_jobs_append_turns_without_rewriting(self):
        # Completing many work jobs into one workspace must not rewrite the whole
        # turns file each time; each completion appends exactly one line and the
        # workspace accumulates every turn in order.
        workspace_turns_file = None
        for index in range(5):
            context = self.context_with_history(f"{index:04x}")
            self.store.complete_job(
                context, "work", f"input-{index}", self.result(), merge_history=True
            )
            workspace_turns_file = context.workspace.turns_file
            self.assertEqual(index + 1, len(read_turns(workspace_turns_file)))

        workspace_turns = read_turns(workspace_turns_file)
        self.assertEqual([1, 2, 3, 4, 5], [turn["number"] for turn in workspace_turns])
        # A committed journal drops its targets; the turns file is the durable state.
        self.assertEqual(5, len(read_turns(workspace_turns_file)))

    def test_complete_job_reads_only_tail_and_keeps_turn_journal_bounded(self):
        workspace = self.store.current_paths()
        for number in range(1, 101):
            append_turn(
                workspace.turns_file,
                {
                    "id": f"seed-turn-{number}",
                    "number": number,
                    "mode": "work",
                    "input": f"historical-marker-{number}",
                    "status": "executed",
                    "result": self.result(),
                    "job_id": f"seed-job-{number}",
                },
            )
        before = workspace.turns_file.read_bytes().rstrip(b"\n")
        workspace.turns_file.write_bytes(before)
        context = self.context_with_history("f00d")
        journals = []
        original_write_journal = self.store._write_journal_locked

        def capture_journal(path, journal):
            journals.append(copy.deepcopy(journal))
            return original_write_journal(path, journal)

        with (
            mock.patch.object(
                sessions_module,
                "read_turns",
                side_effect=AssertionError("complete_job scanned all turns"),
            ),
            mock.patch.object(
                sessions_module,
                "write_turns_atomic",
                side_effect=AssertionError("complete_job rewrote all turns"),
            ),
            mock.patch.object(
                self.store,
                "_write_journal_locked",
                side_effect=capture_journal,
            ),
        ):
            self.store.complete_job(
                context,
                "work",
                "new input",
                self.result(),
                merge_history=False,
            )

        after = workspace.turns_file.read_bytes()
        self.assertTrue(after.startswith(before + b"\n"))
        self.assertEqual(101, len(read_turns(workspace.turns_file)))
        self.assertEqual(101, read_last_turn(workspace.turns_file)["number"])
        prepared = next(journal for journal in journals if journal["state"] == "prepared")
        turn_targets = [
            target for target in prepared["targets"]
            if target["format"] == "turns_append"
        ]
        self.assertEqual(2, len(turn_targets))
        self.assertTrue(all("before" not in target for target in turn_targets))
        self.assertTrue(all(len(target["after"]) == 1 for target in turn_targets))
        prepared_json = json.dumps(prepared, sort_keys=True)
        self.assertNotIn("historical-marker-1", prepared_json)
        self.assertNotIn("seed-job-100", prepared_json)

    def test_prepared_append_target_rolls_back_by_truncation(self):
        # Pre-seed the workspace turns file with one committed turn, then simulate
        # a crash mid-append: a prepared journal with a turns_append target must
        # truncate the appended line back off, not corrupt the existing turn.
        first_context = self.context_with_history("aa01")
        self.store.complete_job(
            first_context, "work", "first", self.result(), merge_history=True
        )
        turns_file = first_context.workspace.turns_file
        before = read_turns(turns_file)
        self.assertEqual(1, len(before))
        before_size = turns_file.stat().st_size

        appended_turn = {
            "id": "x-turn-2",
            "number": 2,
            "mode": "work",
            "input": "second",
            "status": "executed",
            "result": self.result(),
        }
        target = self.store._transaction_append_target(turns_file, [appended_turn])
        self.assertEqual("turns_append", target["format"])
        self.assertEqual(before_size, target["before_size"])

        # Commit the append, then roll it back — the file returns to its preimage.
        self.store._write_transaction_target_locked(target, "after")
        self.assertEqual(2, len(read_turns(turns_file)))
        self.store._write_transaction_target_locked(target, "before")
        self.assertEqual(before, read_turns(turns_file))
        self.assertEqual(before_size, turns_file.stat().st_size)

    def test_append_rollback_preserves_an_existing_empty_turns_file(self):
        context = self.context_with_history("aa02")
        turns_file = context.private.turns_file
        self.assertTrue(turns_file.is_file())
        self.assertEqual(0, turns_file.stat().st_size)
        target = self.store._transaction_append_target(
            turns_file,
            [{"id": "temporary", "number": 1, "job_id": context.job_id}],
        )

        self.store._write_transaction_target_locked(target, "after")
        self.store._write_transaction_target_locked(target, "before")

        self.assertTrue(turns_file.is_file())
        self.assertEqual(0, turns_file.stat().st_size)


if __name__ == "__main__":
    unittest.main()
