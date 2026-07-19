"""Runtime validation for the cross-language domain contract."""

import json
import re
from pathlib import Path


class DomainValidationError(ValueError):
    """Raised when a value crosses a domain boundary with an invalid shape."""


class DomainContract:
    def __init__(self, schema):
        if isinstance(schema, (str, Path)):
            with Path(schema).open("r", encoding="utf-8") as handle:
                schema = json.load(handle)
        if not isinstance(schema, dict):
            raise TypeError("domain schema must be an object")
        self.schema = schema
        self.schema_version = int(schema.get("schema_version", 1))
        self.protocol_version = str(schema.get("protocol_version") or "1.0.0")
        self.job_statuses = frozenset(schema.get("job_status") or ())
        self.step_statuses = frozenset(schema.get("step_status") or ())
        self.work_statuses = frozenset(schema.get("work_status") or ())
        contracts = schema.get("contracts") if isinstance(schema.get("contracts"), dict) else {}
        execution_contract = (
            contracts.get("execution_result")
            if isinstance(contracts.get("execution_result"), dict)
            else {}
        )
        result_status_enum = str(execution_contract.get("status_enum") or "result_status")
        self.result_statuses = frozenset(
            schema.get(result_status_enum)
            or schema.get("result_status")
            or schema.get("work_status")
            or ()
        )
        self.risk_levels = frozenset(schema.get("risk_level") or ())
        self.executor_types = frozenset(schema.get("executor_type") or ())
        self.approval_types = frozenset(schema.get("approval_type") or ())
        self.approval_actions = frozenset(schema.get("approval_action") or ())
        error_codes = schema.get("error_codes")
        self.error_codes = frozenset(error_codes if isinstance(error_codes, dict) else ())
        self.compatibility_statuses = frozenset().union(
            self.job_statuses,
            self.step_statuses,
            self.work_statuses,
            self.result_statuses,
        )

    def _required(self, contract_name):
        contracts = self.schema.get("contracts")
        contract = contracts.get(contract_name) if isinstance(contracts, dict) else None
        required = contract.get("required") if isinstance(contract, dict) else None
        return tuple(required) if isinstance(required, list) else ()

    def _require_fields(self, contract_name, value):
        if not isinstance(value, dict):
            raise DomainValidationError(f"{contract_name} must be an object")
        missing = [name for name in self._required(contract_name) if name not in value]
        if missing:
            raise DomainValidationError(
                f"{contract_name} is missing required fields: {', '.join(missing)}"
            )

    def protocol_metadata(self):
        return {
            "schema_version": self.schema_version,
            "protocol_version": self.protocol_version,
        }

    def enrich_execution_result(self, result):
        if not isinstance(result, dict):
            raise DomainValidationError("execution_result must be an object")
        enriched = dict(result)
        enriched.setdefault("schema_version", self.schema_version)
        enriched.setdefault("protocol_version", self.protocol_version)
        enriched.setdefault("timeline", [])
        enriched.setdefault("approval_card", None)
        enriched.setdefault("output_blocks", [])
        enriched.setdefault("timeline_semantics", "step_projection")
        self.validate_execution_result(enriched)
        return enriched

    def validate_execution_result(self, result):
        self._require_fields("execution_result", result)
        if not isinstance(result.get("ok"), bool):
            raise DomainValidationError("execution_result ok must be a boolean")
        if result.get("schema_version") != self.schema_version:
            raise DomainValidationError("execution_result schema_version is unsupported")
        if str(result.get("protocol_version") or "") != self.protocol_version:
            raise DomainValidationError("execution_result protocol_version is unsupported")
        status = str(result.get("status") or "")
        if self.result_statuses and status not in self.result_statuses:
            raise DomainValidationError(f"unsupported execution_result status: {status}")
        timeline = result.get("timeline")
        if not isinstance(timeline, list):
            raise DomainValidationError("execution_result timeline must be an array")
        seen_step_ids = set()
        for index, item in enumerate(timeline):
            if not isinstance(item, dict):
                raise DomainValidationError(f"timeline item {index} must be an object")
            item_status = str(item.get("status") or "")
            if self.step_statuses and item_status not in self.step_statuses:
                raise DomainValidationError(
                    f"timeline item {index} has unsupported status: {item_status}"
                )
            step_id = str(item.get("step_id") or item.get("id") or "")
            if step_id and step_id in seen_step_ids:
                raise DomainValidationError(
                    f"timeline step projection contains duplicate key: {step_id}"
                )
            if step_id:
                seen_step_ids.add(step_id)
        if result.get("approval_card") is not None:
            self.validate_approval(result["approval_card"])
        response = result.get("response")
        if isinstance(response, dict) and response.get("response_type") == "work_plan":
            self.validate_plan(response)
        if not isinstance(result.get("output_blocks"), list):
            raise DomainValidationError("execution_result output_blocks must be an array")
        if result.get("timeline_semantics") != "step_projection":
            raise DomainValidationError("unsupported timeline semantics")
        return result

    def validate_api_result(
        self,
        result,
        *,
        execution_result=False,
        required_fields=None,
    ):
        """Validate a versioned CLI API envelope before Web returns it."""

        if execution_result:
            self.validate_execution_result(result)
        else:
            if not isinstance(result, dict):
                raise DomainValidationError("api_result must be an object")
            if not isinstance(result.get("ok"), bool):
                raise DomainValidationError("api_result ok must be a boolean")
            if result.get("schema_version") != self.schema_version:
                raise DomainValidationError("api_result schema_version is unsupported")
            if str(result.get("protocol_version") or "") != self.protocol_version:
                raise DomainValidationError("api_result protocol_version is unsupported")
            status = result.get("status")
            if not isinstance(status, str) or not status:
                raise DomainValidationError(
                    "api_result status must be a non-empty string"
                )
            supported = self.compatibility_statuses.union(self.error_codes)
            if supported and status not in supported:
                raise DomainValidationError(
                    f"unsupported api_result status: {status}"
                )
            if result["ok"] is False:
                self._require_fields("error", result)
                code = result.get("code")
                if not isinstance(code, str) or not code:
                    raise DomainValidationError(
                        "api_result error code must be a non-empty string"
                    )
                if code != status:
                    raise DomainValidationError(
                        "api_result error status must match its code"
                    )
                if supported and code not in supported:
                    raise DomainValidationError(
                        f"unsupported api_result error code: {code}"
                    )
                if not isinstance(result.get("message"), str):
                    raise DomainValidationError(
                        "api_result error message must be a string"
                    )
                if not isinstance(result.get("retryable"), bool):
                    raise DomainValidationError(
                        "api_result error retryable must be a boolean"
                    )
                if not isinstance(result.get("request_id"), str):
                    raise DomainValidationError(
                        "api_result error request_id must be a string"
                    )
                if not isinstance(result.get("details"), dict):
                    raise DomainValidationError(
                        "api_result error details must be an object"
                    )

        if result.get("ok") is True:
            for name, expected_type in (required_fields or {}).items():
                value = result.get(name)
                if not isinstance(value, expected_type):
                    raise DomainValidationError(
                        f"api_result {name} has an invalid type"
                    )
                if expected_type is str and not value.strip():
                    raise DomainValidationError(
                        f"api_result {name} must be a non-empty string"
                    )
        return result

    def validate_job(self, job):
        self._require_fields("job", job)
        if job.get("schema_version") != self.schema_version:
            raise DomainValidationError("Job schema_version is unsupported")
        if str(job.get("status") or "") not in self.job_statuses:
            raise DomainValidationError("Job status is unsupported")
        for name in ("version", "attempt", "max_attempts"):
            value = job.get(name)
            if isinstance(value, bool) or not isinstance(value, int) or value < 0:
                raise DomainValidationError(f"Job {name} must be a non-negative integer")
        if job["attempt"] < 1 or job["max_attempts"] < job["attempt"]:
            raise DomainValidationError("Job retry counters are inconsistent")
        if not isinstance(job.get("payload"), dict):
            raise DomainValidationError("Job payload must be an object")
        return job

    def validate_plan(self, plan):
        self._require_fields("plan", plan)
        contracts = self.schema.get("contracts")
        contract = contracts.get("plan") if isinstance(contracts, dict) else {}
        expected_type = str(contract.get("response_type") or "work_plan")
        if plan.get("response_type") != expected_type:
            raise DomainValidationError("plan response_type is unsupported")
        if not isinstance(plan.get("summary"), str) or not plan["summary"].strip():
            raise DomainValidationError("plan summary must be a non-empty string")
        continue_decision = plan.get("continue_decision")
        if not isinstance(continue_decision, dict):
            raise DomainValidationError("plan continue_decision must be an object")
        if not isinstance(continue_decision.get("should_continue"), bool):
            raise DomainValidationError(
                "plan continue_decision.should_continue must be a boolean"
            )
        if not isinstance(continue_decision.get("reason"), str):
            raise DomainValidationError(
                "plan continue_decision.reason must be a string"
            )
        steps = plan.get("steps")
        if not isinstance(steps, list) or not steps or not all(isinstance(step, dict) for step in steps):
            raise DomainValidationError("plan steps must be a non-empty array of objects")
        step_ids = []
        for index, step in enumerate(steps):
            step_id = step.get("id")
            if not isinstance(step_id, str) or not step_id.strip():
                raise DomainValidationError(f"plan step {index} id must be a non-empty string")
            step_ids.append(step_id)
            for name in ("title", "reason", "expected_effect", "rollback_hint"):
                if not isinstance(step.get(name), str):
                    raise DomainValidationError(
                        f"plan step {index} {name} must be a string"
                    )
            if not step["title"].strip():
                raise DomainValidationError(
                    f"plan step {index} title must be non-empty"
                )
            executor_type = str(step.get("executor_type") or "")
            if self.executor_types and executor_type not in self.executor_types:
                raise DomainValidationError(
                    f"plan step {index} executor_type is unsupported"
                )
            if not isinstance(step.get("arguments"), dict):
                raise DomainValidationError(
                    f"plan step {index} arguments must be an object"
                )
            if self.risk_levels and str(step.get("risk_level") or "") not in self.risk_levels:
                raise DomainValidationError(
                    f"plan step {index} risk_level is unsupported"
                )
            executor_fields = {
                "skill_script": ("skill_script",),
                "shell": ("command",),
                "remote_script": ("url", "command"),
                "mcp_tool": ("mcp_server", "mcp_tool"),
            }
            required_any = executor_fields.get(executor_type, ())
            present = [
                name
                for name in required_any
                if isinstance(step.get(name), str) and step[name].strip()
            ]
            if executor_type == "mcp_tool" and len(present) != 2:
                raise DomainValidationError(
                    f"plan step {index} MCP target is incomplete"
                )
            if executor_type != "mcp_tool" and required_any and not present:
                raise DomainValidationError(
                    f"plan step {index} executor target is missing"
                )
        if len(step_ids) != len(set(step_ids)):
            raise DomainValidationError("plan step ids must be unique")
        return plan

    def validate_approval(self, approval):
        self._require_fields("approval", approval)
        for name in ("id", "type", "subject"):
            if not isinstance(approval.get(name), str) or not approval[name].strip():
                raise DomainValidationError(f"approval {name} must be a non-empty string")
        if self.approval_types and approval["type"] not in self.approval_types:
            raise DomainValidationError("approval type is unsupported")
        risk_level = str(approval.get("risk_level") or "")
        if self.risk_levels and risk_level not in self.risk_levels:
            raise DomainValidationError("approval risk_level is unsupported")
        actions = approval.get("actions")
        if not isinstance(actions, list) or not actions:
            raise DomainValidationError("approval actions must be a non-empty array")
        if not all(isinstance(action, str) and action for action in actions):
            raise DomainValidationError("approval actions must contain non-empty strings")
        if self.approval_actions and any(
            action not in self.approval_actions for action in actions
        ):
            raise DomainValidationError("approval action is unsupported")
        if len(actions) != len(set(actions)):
            raise DomainValidationError("approval actions must be unique")
        return approval

    def validate_audit_event(self, event, *, chained=True):
        if chained:
            self._require_fields("audit_event", event)
        else:
            if not isinstance(event, dict):
                raise DomainValidationError("audit_event must be an object")
            required = set(self._required("audit_event")) - {"seq", "prev_hash", "hash"}
            missing = [name for name in sorted(required) if name not in event]
            if missing:
                raise DomainValidationError(
                    f"audit_event is missing required fields: {', '.join(missing)}"
                )
        if event.get("schema_version") != self.schema_version:
            raise DomainValidationError("audit_event schema_version is unsupported")
        for name in (
            "timestamp",
            "session_id",
            "stage",
            "request_id",
            "job_id",
            "system_user",
            "execution_user",
        ):
            if not isinstance(event.get(name), str):
                raise DomainValidationError(f"audit_event {name} must be a string")
        if not event["timestamp"] or not event["session_id"] or not event["stage"]:
            raise DomainValidationError("audit_event identity fields must be non-empty")
        if not event["system_user"] or not event["execution_user"]:
            raise DomainValidationError("audit_event user fields must be non-empty")
        if not isinstance(event.get("payload"), dict):
            raise DomainValidationError("audit_event payload must be an object")
        if chained:
            seq = event.get("seq")
            if isinstance(seq, bool) or not isinstance(seq, int) or seq < 1:
                raise DomainValidationError("audit_event seq must be a positive integer")
            for name in ("prev_hash", "hash"):
                value = event.get(name)
                if not isinstance(value, str) or re.fullmatch(r"[0-9a-f]{64}", value) is None:
                    raise DomainValidationError(f"audit_event {name} must be a SHA-256 hex string")
        return event

    def validate_skill_manifest(self, manifest):
        self._require_fields("skill_manifest", manifest)
        if re.fullmatch(r"[a-z0-9][a-z0-9-]*", str(manifest.get("name") or "")) is None:
            raise DomainValidationError("skill_manifest name is unsupported")
        for name in ("name", "description"):
            if not isinstance(manifest.get(name), str) or not manifest[name].strip():
                raise DomainValidationError(f"skill_manifest {name} must be a non-empty string")
        scripts = manifest.get("scripts")
        if (
            not isinstance(scripts, list)
            or not scripts
            or not all(isinstance(script, dict) for script in scripts)
        ):
            raise DomainValidationError(
                "skill_manifest scripts must be a non-empty array of objects"
            )
        script_names = []
        for index, script in enumerate(scripts):
            script_name = script.get("name")
            if not isinstance(script_name, str) or re.fullmatch(
                r"[a-z0-9][a-z0-9-]*\.sh",
                script_name,
            ) is None:
                raise DomainValidationError(
                    f"skill_manifest script {index} name is unsupported"
                )
            script_names.append(script_name)
        if len(script_names) != len(set(script_names)):
            raise DomainValidationError("skill_manifest script names must be unique")
        return manifest

    def validate_turn(self, turn):
        self._require_fields("persisted_turn", turn)
        turn_id = turn.get("id")
        if not isinstance(turn_id, str) or not turn_id.strip():
            raise DomainValidationError("persisted turn id must be a non-empty string")
        number = turn.get("number")
        if isinstance(number, bool) or not isinstance(number, int) or number < 1:
            raise DomainValidationError("persisted turn number must be a positive integer")
        status = turn.get("status")
        if not isinstance(status, str) or not status:
            raise DomainValidationError("persisted turn status must be a non-empty string")
        if self.result_statuses and status not in self.result_statuses:
            raise DomainValidationError(f"unsupported persisted turn status: {status}")
        if not isinstance(turn.get("context_eligible"), bool):
            raise DomainValidationError("persisted turn context_eligible must be a boolean")
        result = turn.get("result")
        self.validate_execution_result(result)
        if status != result.get("status"):
            raise DomainValidationError(
                "persisted turn status must match execution_result status"
            )
        return turn

    def normalize_error(self, payload, request_id=""):
        normalized = dict(payload) if isinstance(payload, dict) else {}
        code = str(normalized.get("code") or normalized.get("status") or "internal_error")
        raw_message = normalized.get("message") or normalized.get("error") or code
        if isinstance(raw_message, dict):
            raw_message = raw_message.get("message") or raw_message.get("code") or code
        codes = self.schema.get("error_codes")
        original_code = code
        if (
            isinstance(codes, dict)
            and code not in codes
            and code not in self.compatibility_statuses
        ):
            code = "internal_error"
        spec = codes.get(code) if isinstance(codes, dict) else None
        details = normalized.get("details")
        if not isinstance(details, dict):
            details = {}
        if original_code != code:
            details = {**details, "original_code": original_code}
        normalized.update(
            {
                "ok": False,
                "status": code,
                "error": str(raw_message),
                "code": code,
                "message": str(raw_message),
                "retryable": bool(normalized.get("retryable"))
                if "retryable" in normalized
                else bool(spec.get("retryable", False))
                if isinstance(spec, dict)
                else False,
                "request_id": str(normalized.get("request_id") or request_id or ""),
                "details": details,
            }
        )
        self._require_fields("error", normalized)
        return normalized


__all__ = ["DomainContract", "DomainValidationError"]
