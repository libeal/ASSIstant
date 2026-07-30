#!/usr/bin/env python3
"""Validate MCP manifests against the repository JSON Schema contract."""

from __future__ import annotations

import argparse
import json
import re
import urllib.parse
from dataclasses import dataclass
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SCHEMA = ROOT / "schema" / "mcp-manifest.json"
MAX_MANIFEST_BYTES = 262_144
FORBIDDEN_HEADERS = {
    "accept",
    "content-length",
    "content-type",
    "host",
    "traceparent",
    "tracestate",
    "baggage",
}
FORBIDDEN_CREDENTIAL_HEADERS = FORBIDDEN_HEADERS
SECRET_HEADER_PATTERN = re.compile(
    r"(?i)(authorization|cookie|token|secret|password|passwd|api[_-]?key|credential|private[_-]?key)"
)


@dataclass(frozen=True)
class ValidationIssue:
    path: str
    message: str
    keyword: str


def type_matches(value: Any, expected: str) -> bool:
    return {
        "object": isinstance(value, dict),
        "array": isinstance(value, list),
        "string": isinstance(value, str),
        "boolean": isinstance(value, bool),
        "integer": isinstance(value, int) and not isinstance(value, bool),
        "number": isinstance(value, (int, float)) and not isinstance(value, bool),
        "null": value is None,
    }.get(expected, False)


def pointer(parent: str, key: object) -> str:
    escaped = str(key).replace("~", "~0").replace("/", "~1")
    return f"{parent}/{escaped}" if parent else f"/{escaped}"


def format_matches(value: str, format_name: str) -> bool:
    if format_name == "mcp-http-url":
        try:
            parsed = urllib.parse.urlsplit(value)
            port = parsed.port
        except ValueError:
            return False
        return bool(
            parsed.scheme.lower() in {"http", "https"}
            and parsed.hostname
            and parsed.username is None
            and parsed.password is None
            and (port is None or 1 <= port <= 65535)
            and not any(character.isspace() for character in value)
        )
    if format_name == "mcp-header-name":
        lower = value.lower()
        return bool(
            re.fullmatch(r"[!#$%&'*+.^_`|~0-9A-Za-z-]+", value)
            and lower not in FORBIDDEN_HEADERS
            and not lower.startswith("mcp-")
        )
    if format_name == "mcp-credential-header-name":
        lower = value.lower()
        return bool(
            re.fullmatch(r"[!#$%&'*+.^_`|~0-9A-Za-z-]+", value)
            and lower not in FORBIDDEN_CREDENTIAL_HEADERS
            and not lower.startswith("mcp-")
        )
    if format_name in {
        "mcp-https-document-url",
        "mcp-oauth-issuer-url",
        "mcp-oauth-redirect-url",
    }:
        try:
            parsed = urllib.parse.urlsplit(value)
            port = parsed.port
        except ValueError:
            return False
        scheme_allowed = parsed.scheme.lower() == "https"
        if format_name == "mcp-oauth-redirect-url":
            scheme_allowed = scheme_allowed or (
                parsed.scheme.lower() == "http" and parsed.hostname in {"127.0.0.1", "::1", "localhost"}
            )
        if format_name == "mcp-oauth-issuer-url":
            scheme_allowed = scheme_allowed or (
                parsed.scheme.lower() == "http" and parsed.hostname in {"127.0.0.1", "::1", "localhost"}
            )
        return bool(
            scheme_allowed
            and parsed.hostname
            and parsed.username is None
            and parsed.password is None
            and (port is None or 1 <= port <= 65535)
            and (format_name != "mcp-https-document-url" or parsed.path not in {"", "/"})
            and (format_name not in {"mcp-https-document-url", "mcp-oauth-issuer-url"} or not parsed.query)
            and not parsed.fragment
            and not any(character.isspace() for character in value)
        )
    return True


def validate(value: Any, schema: dict[str, Any], path: str = "") -> list[ValidationIssue]:
    issues: list[ValidationIssue] = []
    expected_type = schema.get("type")
    if isinstance(expected_type, str) and not type_matches(value, expected_type):
        return [ValidationIssue(path or "/", f"must be {expected_type}", "type")]
    if isinstance(expected_type, list) and not any(type_matches(value, item) for item in expected_type):
        return [ValidationIssue(path or "/", "has an invalid type", "type")]
    if "const" in schema and value != schema["const"]:
        issues.append(ValidationIssue(path or "/", f"must equal {schema['const']!r}", "const"))
    enum = schema.get("enum")
    if isinstance(enum, list) and value not in enum:
        issues.append(ValidationIssue(path or "/", "must be one of the allowed values", "enum"))
    if isinstance(value, str):
        minimum = schema.get("minLength")
        maximum = schema.get("maxLength")
        pattern = schema.get("pattern")
        if isinstance(minimum, int) and len(value) < minimum:
            issues.append(ValidationIssue(path or "/", "is too short", "minLength"))
        if isinstance(maximum, int) and len(value) > maximum:
            issues.append(ValidationIssue(path or "/", "is too long", "maxLength"))
        if isinstance(pattern, str) and re.search(pattern, value) is None:
            issues.append(ValidationIssue(path or "/", "does not match the required pattern", "pattern"))
        format_name = schema.get("format")
        if isinstance(format_name, str) and not format_matches(value, format_name):
            issues.append(ValidationIssue(path or "/", f"does not match format {format_name}", "format"))
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        minimum = schema.get("minimum")
        maximum = schema.get("maximum")
        if isinstance(minimum, (int, float)) and value < minimum:
            issues.append(ValidationIssue(path or "/", f"must be at least {minimum}", "minimum"))
        if isinstance(maximum, (int, float)) and value > maximum:
            issues.append(ValidationIssue(path or "/", f"must be at most {maximum}", "maximum"))
    if isinstance(value, list):
        maximum = schema.get("maxItems")
        if isinstance(maximum, int) and len(value) > maximum:
            issues.append(ValidationIssue(path or "/", "contains too many items", "maxItems"))
        item_schema = schema.get("items")
        if isinstance(item_schema, dict):
            for index, item in enumerate(value):
                issues.extend(validate(item, item_schema, pointer(path, index)))
    if isinstance(value, dict):
        required = schema.get("required", [])
        if isinstance(required, list):
            for key in required:
                if isinstance(key, str) and key not in value:
                    issues.append(ValidationIssue(pointer(path, key), "is required", "required"))
        maximum = schema.get("maxProperties")
        if isinstance(maximum, int) and len(value) > maximum:
            issues.append(ValidationIssue(path or "/", "contains too many properties", "maxProperties"))
        property_names = schema.get("propertyNames")
        if isinstance(property_names, dict):
            for key in value:
                issues.extend(validate(key, property_names, pointer(path, key)))
        properties = schema.get("properties", {})
        additional = schema.get("additionalProperties", True)
        if isinstance(properties, dict):
            for key, item in value.items():
                child_schema = properties.get(key)
                if isinstance(child_schema, dict):
                    issues.extend(validate(item, child_schema, pointer(path, key)))
                elif additional is False:
                    issues.append(ValidationIssue(pointer(path, key), "is not an allowed property", "additionalProperties"))
                elif isinstance(additional, dict):
                    issues.extend(validate(item, additional, pointer(path, key)))
    all_of = schema.get("allOf")
    if isinstance(all_of, list):
        for child in all_of:
            if isinstance(child, dict):
                issues.extend(validate(value, child, path))
    condition = schema.get("if")
    if isinstance(condition, dict):
        branch = schema.get("then") if not validate(value, condition, path) else schema.get("else")
        if isinstance(branch, dict):
            issues.extend(validate(value, branch, path))
    one_of = schema.get("oneOf")
    if isinstance(one_of, list):
        matches = [child for child in one_of if isinstance(child, dict) and not validate(value, child, path)]
        if len(matches) != 1:
            issues.append(ValidationIssue(path or "/", "must match exactly one allowed shape", "oneOf"))
    return issues


def finding_code(issue: ValidationIssue) -> str:
    if issue.path == "/" and issue.keyword == "type":
        return "MCP_MANIFEST_NOT_OBJECT"
    if issue.path.startswith("/id"):
        return "MCP_ID_INVALID"
    if issue.path.startswith("/transport"):
        return "MCP_TRANSPORT_INVALID"
    if issue.path == "/command" and issue.keyword == "required":
        return "MCP_STDIO_COMMAND_MISSING"
    if issue.path.startswith("/args"):
        return "MCP_STDIO_ARGS_INVALID"
    if issue.path.startswith("/env"):
        return "MCP_STDIO_ENV_INVALID"
    if issue.path.startswith("/headers"):
        return "MCP_HTTP_HEADERS_INVALID"
    if issue.path.startswith("/url"):
        return "MCP_HTTP_URL_INVALID"
    if issue.path.startswith("/message_url"):
        return "MCP_SSE_MESSAGE_URL_INVALID"
    if issue.path.startswith("/protocol"):
        return "MCP_PROTOCOL_CONFIG_INVALID"
    if issue.path.startswith("/compatibility"):
        return "MCP_COMPATIBILITY_INVALID"
    if issue.path.startswith("/credential_profile"):
        return "MCP_CREDENTIAL_PROFILE_INVALID"
    return "MCP_MANIFEST_SCHEMA_INVALID"


def validate_path(path: Path, schema_path: Path = DEFAULT_SCHEMA) -> dict[str, Any]:
    relative = path.as_posix()
    try:
        if path.stat().st_size > MAX_MANIFEST_BYTES:
            raise ValueError("mcp.json exceeds 256 KiB")
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
        return {
            "ok": False,
            "path": relative,
            "id": "",
            "transport": "",
            "findings": [{
                "severity": "critical",
                "code": "MCP_MANIFEST_INVALID_JSON",
                "path": relative,
                "message": str(exc),
            }],
        }
    schema = json.loads(schema_path.read_text(encoding="utf-8"))
    issues = validate(payload, schema)
    findings = [
        {
            "severity": "critical",
            "code": finding_code(issue),
            "path": relative,
            "json_pointer": issue.path,
            "message": issue.message,
        }
        for issue in issues
    ]
    if isinstance(payload, dict) and payload.get("transport") == "sse":
        findings.append({
            "severity": "low",
            "code": "MCP_SSE_DEPRECATED",
            "path": relative,
            "message": "legacy HTTP+SSE transport is deprecated",
        })
    if isinstance(payload, dict) and isinstance(payload.get("headers"), dict):
        secret_headers = [
            key for key in payload["headers"] if isinstance(key, str) and SECRET_HEADER_PATTERN.search(key)
        ]
        if secret_headers:
            findings.append({
                "severity": "low",
                "code": "MCP_INLINE_SECRET_DEPRECATED",
                "path": relative,
                "message": "secret-like inline headers should migrate to a credential profile",
            })
    critical = [finding for finding in findings if finding["severity"] == "critical"]
    return {
        "ok": not critical,
        "path": relative,
        "id": payload.get("id", "") if isinstance(payload, dict) else "",
        "transport": payload.get("transport", "") if isinstance(payload, dict) else "",
        "manifest_version": payload.get("manifest_version", 1) if isinstance(payload, dict) else 1,
        "findings": findings,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest")
    parser.add_argument("--schema", default=str(DEFAULT_SCHEMA))
    args = parser.parse_args()
    result = validate_path(Path(args.manifest), Path(args.schema))
    print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
