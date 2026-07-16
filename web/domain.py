"""Runtime validation for the cross-language domain contract."""

import json
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
            self._require_fields("approval", result["approval_card"])
        if not isinstance(result.get("output_blocks"), list):
            raise DomainValidationError("execution_result output_blocks must be an array")
        if result.get("timeline_semantics") != "step_projection":
            raise DomainValidationError("unsupported timeline semantics")
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
