#!/usr/bin/env python3

import json
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "web"))

from domain import DomainContract, DomainValidationError  # noqa: E402
from timeline import TimelineDataError, timeline_from_turns  # noqa: E402


class DomainContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with (ROOT / "schema" / "domain.json").open(encoding="utf-8") as handle:
            cls.contract = DomainContract(json.load(handle))

    def result(self, **overrides):
        result = {
            "ok": True,
            "status": "executed",
            "timeline": [
                {
                    "id": "execution-one",
                    "step_id": "one",
                    "kind": "execution",
                    "status": "succeeded",
                }
            ],
            "approval_card": None,
            "output_blocks": [],
        }
        result.update(overrides)
        return self.contract.enrich_execution_result(result)

    def test_execution_result_is_versioned_and_validated(self):
        result = self.result()
        self.assertEqual(self.contract.schema_version, result["schema_version"])
        self.assertEqual(self.contract.protocol_version, result["protocol_version"])
        self.assertEqual("step_projection", result["timeline_semantics"])

    def test_api_result_validates_version_status_and_route_fields(self):
        result = {
            "ok": True,
            "status": "checked",
            "schema_version": self.contract.schema_version,
            "protocol_version": self.contract.protocol_version,
            "doctor": {},
        }
        self.assertIs(
            result,
            self.contract.validate_api_result(
                result,
                required_fields={"doctor": dict},
            ),
        )
        for field, value in (
            ("status", "invented"),
            ("protocol_version", "9.9.9"),
            ("doctor", []),
        ):
            with self.subTest(field=field), self.assertRaises(
                DomainValidationError
            ):
                self.contract.validate_api_result(
                    {**result, field: value},
                    required_fields={"doctor": dict},
                )

    def test_api_result_accepts_known_errors_and_materialized_skill(self):
        error = {
            "ok": False,
            "status": "validation_failed",
            "code": "validation_failed",
            "message": "invalid input",
            "retryable": False,
            "request_id": "request-one",
            "details": {},
            "schema_version": self.contract.schema_version,
            "protocol_version": self.contract.protocol_version,
        }
        self.assertIs(error, self.contract.validate_api_result(error))

        materialized = {
            "ok": True,
            "status": "skill_materialized",
            "skill": "ops-basic",
            "files": [],
            "schema_version": self.contract.schema_version,
            "protocol_version": self.contract.protocol_version,
        }
        self.assertIs(
            materialized,
            self.contract.validate_api_result(
                materialized,
                required_fields={"skill": str, "files": list},
            ),
        )

    def test_api_result_uses_full_execution_contract_when_requested(self):
        result = self.result()
        self.assertIs(
            result,
            self.contract.validate_api_result(result, execution_result=True),
        )
        with self.assertRaisesRegex(DomainValidationError, "output_blocks"):
            self.contract.validate_api_result(
                {key: value for key, value in result.items() if key != "output_blocks"},
                execution_result=True,
            )

    def test_duplicate_projection_and_unknown_status_are_rejected(self):
        duplicate = self.result()["timeline"] * 2
        with self.assertRaises(DomainValidationError):
            self.result(timeline=duplicate)
        with self.assertRaises(DomainValidationError):
            self.result(status="invented")

    def test_execution_status_does_not_accept_error_codes_as_lifecycle_states(self):
        self.assertIn("observer_required_unavailable", self.contract.error_codes)
        self.assertNotIn(
            "observer_required_unavailable", self.contract.result_statuses
        )
        with self.assertRaisesRegex(
            DomainValidationError, "unsupported execution_result status"
        ):
            self.result(status="observer_required_unavailable")

    def test_ai_failure_keeps_error_code_out_of_lifecycle_status(self):
        result = self.result(
            ok=False,
            status="ai_failed",
            code="ai_request_failed",
            error_code="ai_request_failed",
            error="provider unavailable",
            timeline=[],
        )
        self.assertEqual("ai_failed", result["status"])
        self.assertEqual("ai_request_failed", result["code"])
        self.assertEqual("ai_request_failed", result["error_code"])

    def test_error_contract_keeps_compatibility_aliases(self):
        error = self.contract.normalize_error(
            {"ok": False, "status": "too_many_jobs", "error": "busy"},
            "request-one",
        )
        self.assertEqual("too_many_jobs", error["code"])
        self.assertEqual("busy", error["message"])
        self.assertEqual("busy", error["error"])
        self.assertTrue(error["retryable"])
        self.assertEqual("request-one", error["request_id"])
        self.assertEqual({}, error["details"])

    def test_known_business_and_service_errors_keep_their_status(self):
        for status in (
            "blocked",
            "validated",
            "unsupported_provider",
            "model_list_unavailable",
            "api_key_missing",
        ):
            with self.subTest(status=status):
                error = self.contract.normalize_error(
                    {"ok": False, "status": status, "error": status},
                    "request-known",
                )
                self.assertEqual(status, error["code"])
                self.assertEqual(status, error["status"])
                self.assertNotIn("original_code", error["details"])

    def test_unknown_error_code_is_normalized_to_schema_defined_internal_error(self):
        error = self.contract.normalize_error(
            {"ok": False, "status": "invented_error", "error": "broken"},
            "request-two",
        )
        self.assertEqual("internal_error", error["code"])
        self.assertEqual("internal_error", error["status"])
        self.assertEqual("invented_error", error["details"]["original_code"])
        self.assertTrue(error["retryable"])

    def test_timeline_accepts_valid_turn_and_rejects_invalid_turn(self):
        turn = {
            "id": "turn-one",
            "number": 1,
            "mode": "work",
            "input": "inspect",
            "status": "executed",
            "context_eligible": True,
            "result": self.result(),
        }
        timeline = timeline_from_turns("session-one", [turn], self.contract)
        self.assertEqual("session-one", timeline["session_id"])
        self.assertEqual(self.contract.protocol_version, timeline["protocol_version"])
        broken = dict(turn)
        broken["result"] = {"ok": True, "status": "executed"}
        with self.assertRaises(TimelineDataError):
            timeline_from_turns("session-one", [broken], self.contract)

    def test_persisted_turn_validates_outer_contract_and_result_consistency(self):
        valid = {
            "id": "turn-one",
            "number": 1,
            "status": "executed",
            "context_eligible": False,
            "result": self.result(),
        }
        self.assertIs(valid, self.contract.validate_turn(valid))

        invalid_values = (
            ("id", ""),
            ("number", 0),
            ("number", True),
            ("status", "invented"),
            ("context_eligible", "false"),
        )
        for field, value in invalid_values:
            with self.subTest(field=field, value=value):
                broken = dict(valid)
                broken[field] = value
                with self.assertRaises(DomainValidationError):
                    self.contract.validate_turn(broken)

        mismatched = dict(valid)
        mismatched["status"] = "failed"
        with self.assertRaisesRegex(DomainValidationError, "must match"):
            self.contract.validate_turn(mismatched)

        for missing in ("id", "number", "status", "context_eligible"):
            with self.subTest(missing=missing):
                broken = dict(valid)
                del broken[missing]
                with self.assertRaisesRegex(DomainValidationError, "missing required"):
                    self.contract.validate_turn(broken)

    def test_plan_approval_audit_and_skill_contracts_are_runtime_validated(self):
        plan = {
            "response_type": "work_plan",
            "summary": "inspect host",
            "continue_decision": {"should_continue": False, "reason": "done"},
            "steps": [
                {
                    "id": "one",
                    "title": "inspect",
                    "executor_type": "shell",
                    "command": "id",
                    "arguments": {},
                    "reason": "inspect",
                    "expected_effect": "identity",
                    "risk_level": "low",
                    "rollback_hint": "none",
                }
            ],
        }
        self.assertIs(plan, self.contract.validate_plan(plan))
        with self.assertRaises(DomainValidationError):
            self.contract.validate_plan({**plan, "response_type": "invented"})

        approval = {
            "id": "approval-one",
            "type": "terminal",
            "subject": "restart service",
            "risk_level": "high",
            "actions": ["approve", "reject"],
        }
        self.assertIs(approval, self.contract.validate_approval(approval))
        with self.assertRaises(DomainValidationError):
            self.contract.validate_approval({**approval, "risk_level": "invented"})

        audit_event = {
            "schema_version": self.contract.schema_version,
            "timestamp": "2026-07-18T00:00:00Z",
            "session_id": "session-one",
            "stage": "tested",
            "payload": {},
            "seq": 1,
            "prev_hash": "0" * 64,
            "hash": "a" * 64,
            "request_id": "request-one",
            "job_id": "",
            "system_user": "operator",
            "execution_user": "linux-agent",
        }
        self.assertIs(audit_event, self.contract.validate_audit_event(audit_event))
        with self.assertRaises(DomainValidationError):
            self.contract.validate_audit_event({**audit_event, "hash": "not-a-hash"})

        manifest = {
            "name": "ops-basic",
            "description": "operations",
            "scripts": [{"name": "resource-inspect.sh"}],
        }
        self.assertIs(manifest, self.contract.validate_skill_manifest(manifest))
        with self.assertRaises(DomainValidationError):
            self.contract.validate_skill_manifest({**manifest, "scripts": ["bad"]})

    def test_execution_result_validates_embedded_work_plan(self):
        result = self.result()
        result["response"] = {
            "response_type": "work_plan",
            "summary": "inspect host",
            "continue_decision": {"should_continue": False, "reason": "done"},
            "steps": [
                {
                    "id": "one",
                    "title": "inspect",
                    "executor_type": "shell",
                    "command": "id",
                    "arguments": {},
                    "reason": "inspect",
                    "expected_effect": "identity",
                    "risk_level": "low",
                    "rollback_hint": "none",
                }
            ],
        }
        self.contract.validate_execution_result(result)
        result["response"]["summary"] = ""
        with self.assertRaisesRegex(DomainValidationError, "summary"):
            self.contract.validate_execution_result(result)


if __name__ == "__main__":
    unittest.main()
