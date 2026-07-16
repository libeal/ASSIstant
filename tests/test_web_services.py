#!/usr/bin/env python3

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "web"))

from provider import (  # noqa: E402
    ProviderSecurityHelpers,
    ProviderService,
    extract_model_ids,
)
import policy as policy_module  # noqa: E402
from policy import PolicyService  # noqa: E402
from skills import SkillService  # noqa: E402


DOMAIN_SCHEMA = {
    "provider_normalization": {
        "prefix_rules": [
            {"prefix": "openai_compatible", "canonical": "openai_compatible"}
        ],
        "aliases": {
            "": "openai_compatible",
            "zhipu": "zhipu_ai",
            "zhipuai": "zhipu_ai",
            "zhipu_ai": "zhipu_ai",
        },
    }
}


class SkillServiceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name) / "skills"
        (self.root / "nested").mkdir(parents=True)
        (self.root / ".hidden").mkdir()
        (self.root / "README.md").write_text("root docs\n", encoding="utf-8")
        (self.root / "run.sh").write_text("#!/usr/bin/env bash\n", encoding="utf-8")
        (self.root / "nested" / "guide.md").write_text("nested docs\n", encoding="utf-8")
        (self.root / "ignored.txt").write_text("ignore\n", encoding="utf-8")
        (self.root / ".hidden" / "secret.md").write_text("hidden\n", encoding="utf-8")
        self.service = SkillService(self.root)

    def tearDown(self):
        self.temp.cleanup()

    def test_list_and_read_visible_skill_files(self):
        listing = self.service.list_files()

        self.assertTrue(listing["ok"])
        self.assertEqual(listing["markdown_files"], ["README.md", "nested/guide.md"])
        self.assertEqual(listing["script_files"], ["run.sh"])
        self.assertEqual([item["type"] for item in listing["tree"]], ["dir", "file", "file"])
        read = self.service.read_file("nested/guide.md")
        self.assertEqual(read["status"], "read")
        self.assertEqual(read["kind"], "markdown")
        self.assertEqual(read["content"], "nested docs\n")

    def test_safe_path_rejects_escape_absolute_suffix_and_symlink(self):
        outside = Path(self.temp.name) / "outside.md"
        outside.write_text("outside\n", encoding="utf-8")
        os.symlink(outside, self.root / "linked.md")

        for path in (
            "../outside.md",
            str(outside),
            "ignored.txt",
            ".hidden/secret.md",
            "linked.md",
        ):
            with self.subTest(path=path), self.assertRaises(ValueError):
                self.service.safe_path(path)


class ProviderServiceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.registry = Path(self.temp.name) / "providers.json"
        self.registry.write_text(
            json.dumps(
                {
                    "providers": [
                        {
                            "id": "openai_compatible",
                            "label": "Custom",
                            "api_url": "https://api.example/v1/chat/completions",
                            "auth": "bearer",
                            "models": {
                                "supported": True,
                                "derive_from_api_url": True,
                                "parser": "openai_data_id",
                            },
                        },
                        {
                            "id": "manual",
                            "label": "Manual only",
                            "models": {"supported": False, "reason": "enter manually"},
                        },
                    ]
                }
            ),
            encoding="utf-8",
        )
        self.config = {
            "provider": "openai_compatible",
            "api_url": "https://api.example/v1/chat/completions",
            "api_key": "configured-secret",
            "request_timeout_sec": 90,
            "providers_security": {"require_https": True},
        }
        self.inspected = []
        self.fetches = []

        def inspect_url(url, security):
            self.inspected.append((url, dict(security)))
            return url, "", ["203.0.113.10"]

        self.security = ProviderSecurityHelpers(
            policy_from_config=lambda config: config.get("providers_security", {}),
            validate_url=lambda url, _security: (url, ""),
            inspect_url=inspect_url,
            error_message=lambda status: f"blocked: {status}",
        )

    def tearDown(self):
        self.temp.cleanup()

    def service(self, **overrides):
        def fetch(url, headers, timeout, secret, addresses):
            self.fetches.append((url, headers, timeout, secret, tuple(addresses)))
            return {"data": [{"id": "model-z"}, {"id": "model-a"}, {"id": "model-a"}]}, None

        options = {
            "config_reader": lambda: dict(self.config),
            "key_resolver": lambda config, override: (
                (str(override), "request") if override else (str(config.get("api_key") or ""), "config")
            ),
            "remote_mode": False,
            "security_helpers": self.security,
            "fetch_json": fetch,
        }
        options.update(overrides)
        return ProviderService(self.registry, DOMAIN_SCHEMA, **options)

    def test_schema_driven_normalization(self):
        service = self.service()
        expected = {
            "": "openai_compatible",
            "OpenAI-Compatible / local": "openai_compatible",
            "ZhipuAI": "zhipu_ai",
            "new/provider name": "new_provider_name",
        }
        for raw, normalized in expected.items():
            with self.subTest(raw=raw):
                self.assertEqual(service.normalize_id(raw), normalized)

    def test_model_parsers_filter_and_deduplicate(self):
        self.assertEqual(
            extract_model_ids(
                {"data": [{"id": " z "}, {"id": "a"}, {"id": "a"}, {"id": ""}]},
                "openai_data_id",
            ),
            ["a", "z"],
        )
        self.assertEqual(
            extract_model_ids(
                {
                    "models": [
                        {"name": "models/gemini-b", "supportedGenerationMethods": ["generateContent"]},
                        {"name": "models/embed", "supportedGenerationMethods": ["embedContent"]},
                        {"name": "models/gemini-a"},
                    ]
                },
                "google_models",
            ),
            ["gemini-a", "gemini-b"],
        )

    def test_supported_model_request_is_inspected_pinned_and_parsed(self):
        result = self.service().list_models({"provider": "openai_compatible"})

        self.assertTrue(result["ok"])
        self.assertEqual(result["models"], [{"id": "model-a"}, {"id": "model-z"}])
        self.assertEqual(self.inspected[0][0], "https://api.example/v1/models")
        self.assertEqual(self.fetches[0][4], ("203.0.113.10",))
        self.assertEqual(self.fetches[0][2], 60)

    def test_ssrf_rejection_stops_before_fetch(self):
        blocked_helpers = ProviderSecurityHelpers(
            policy_from_config=lambda _config: {"require_https": True},
            validate_url=lambda url, _security: (url, ""),
            inspect_url=lambda _url, _security: ("", "blocked_internal_address", []),
            error_message=lambda _status: "internal address blocked",
        )
        result = self.service(security_helpers=blocked_helpers).list_models(
            {"provider": "openai_compatible"}
        )

        self.assertFalse(result["ok"])
        self.assertEqual(result["status"], "blocked_internal_address")
        self.assertEqual(self.fetches, [])

    def test_unknown_and_model_list_unsupported_providers_are_explicit(self):
        service = self.service()

        unknown = service.list_models({"provider": "missing-provider"})
        self.assertEqual(unknown["status"], "unsupported_provider")
        self.assertEqual(unknown["provider"], "missing_provider")
        unavailable = service.list_models({"provider": "manual"})
        self.assertEqual(unavailable["status"], "model_list_unavailable")
        self.assertEqual(unavailable["error"], "enter manually")
        self.assertEqual(self.fetches, [])


class PolicyServiceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name) / "project"
        self.policies = self.root / "policies"
        self.policies.mkdir(parents=True)
        self.policy_path = self.policies / "example.json"
        self.policy_path.write_text('{"enabled":false}\n', encoding="utf-8")
        self.config = {"command_guard": {"enabled": False}}
        self.validation_result = {
            "ok": True,
            "status": "valid",
            "validation": {"ok": True},
        }
        self.audit_events = []
        self.config_writes = []

    def tearDown(self):
        self.temp.cleanup()

    def service(self, audit=None):
        def write_config(config):
            self.config = dict(config)
            self.config_writes.append(dict(config))

        def agent_api(resource, action, payload, timeout=None):
            self.assertEqual((resource, action), ("policy", "validate"))
            self.assertEqual(timeout, 60)
            self.assertEqual(payload["path"], "example.json")
            return dict(self.validation_result)

        audit_writer = audit or (
            lambda stage, payload: self.audit_events.append((stage, payload))
        )
        return PolicyService(
            self.root,
            config_reader=lambda: self.config,
            config_writer=write_config,
            agent_api=agent_api,
            audit=audit_writer,
            config_public_state=lambda: {"ok": True, "config": self.config},
            effective_uid=lambda: 0,
            process_runner=lambda *_args, **_kwargs: self.fail("root tests must not run sudo"),
        )

    def test_policy_paths_reject_escape_hidden_suffix_and_symlink(self):
        outside = Path(self.temp.name) / "outside.json"
        outside.write_text("{}\n", encoding="utf-8")
        os.symlink(outside, self.policies / "linked.json")
        service = self.service()

        for path in (
            "../outside.json",
            str(outside),
            ".hidden.json",
            "not-json.txt",
            "linked.json",
        ):
            with self.subTest(path=path), self.assertRaises(ValueError):
                service.safe_path(path)
        self.assertEqual([item["path"] for item in service.list_files()], ["example.json"])

    def test_policy_root_symlink_is_not_enumerated(self):
        alternate_root = Path(self.temp.name) / "alternate-project"
        alternate_root.mkdir()
        os.symlink(self.policies, alternate_root / "policies")
        service = PolicyService(
            alternate_root,
            config_reader=lambda: {},
            config_writer=lambda _config: None,
            agent_api=lambda *_args, **_kwargs: {"ok": True},
            audit=lambda *_args: None,
            config_public_state=lambda: {},
            effective_uid=0,
        )

        with self.assertRaises(ValueError):
            service.list_files()
        with self.assertRaises(ValueError):
            service.safe_path("example.json")

    def test_read_policy_returns_content_and_json(self):
        result = self.service().read_file("example.json")

        self.assertTrue(result["ok"])
        self.assertEqual(result["json"], {"enabled": False})
        self.assertEqual(result["content"], '{"enabled":false}\n')

    def test_validation_failure_does_not_write_or_create_temp_file(self):
        self.validation_result = {
            "ok": False,
            "status": "invalid_policy",
            "validation": {"ok": False, "findings": [{"code": "bad"}]},
        }
        before = self.policy_path.read_bytes()

        result = self.service().write_file("example.json", '{"enabled":true}', "")

        self.assertEqual(result["status"], "validation_failed")
        self.assertEqual(self.policy_path.read_bytes(), before)
        self.assertFalse((self.root / "tmp").exists())
        self.assertEqual(self.audit_events, [])

    def test_root_write_uses_atomic_replace_and_cleans_temp(self):
        service = self.service()
        with mock.patch.object(policy_module.os, "replace", wraps=os.replace) as replace:
            result = service.write_file("example.json", '{"enabled":true}', "")

        self.assertEqual(result, {
            "ok": True,
            "status": "saved",
            "path": "example.json",
            "method": "root",
        })
        replace.assert_called_once()
        self.assertEqual(json.loads(self.policy_path.read_text(encoding="utf-8")), {"enabled": True})
        self.assertEqual(self.policy_path.stat().st_mode & 0o777, 0o644)
        self.assertEqual(list((self.root / "tmp" / "web" / "policy-edits").glob("*.tmp")), [])
        self.assertEqual(
            [stage for stage, _payload in self.audit_events],
            ["policy_update_requested", "policy_updated"],
        )
        operation_ids = {
            payload["operation_id"] for _stage, payload in self.audit_events
        }
        self.assertEqual(1, len(operation_ids))
        self.assertEqual(self.audit_events[-1][1]["path"], "example.json")

    def test_audit_intent_failure_prevents_policy_write(self):
        before = self.policy_path.read_bytes()

        def fail_audit(_stage, _payload):
            raise RuntimeError("audit blocked")

        with self.assertRaisesRegex(RuntimeError, "audit blocked"):
            self.service(audit=fail_audit).write_file(
                "example.json",
                '{"enabled":true}',
            )

        self.assertEqual(before, self.policy_path.read_bytes())
        self.assertFalse((self.root / "tmp").exists())

    def test_completed_audit_failure_keeps_success_and_reports_intent_only(self):
        events = []

        def fail_completed(stage, payload):
            events.append((stage, payload))
            if stage == "policy_updated":
                raise RuntimeError("completion audit blocked")

        result = self.service(audit=fail_completed).write_file(
            "example.json",
            '{"enabled":true}',
        )

        self.assertTrue(result["ok"])
        self.assertEqual("requested_only", result["audit_status"])
        self.assertIn("completion audit blocked", result["audit_error"])
        self.assertEqual({"enabled": True}, json.loads(self.policy_path.read_text()))
        self.assertEqual(
            [stage for stage, _payload in events],
            ["policy_update_requested", "policy_updated"],
        )

    def test_temporary_policy_is_owner_only_while_staged(self):
        service = self.service()
        temp_path = service._create_temp_file(self.policy_path, "{}\n")
        try:
            self.assertEqual(temp_path.stat().st_mode & 0o777, 0o600)
        finally:
            temp_path.unlink()

    def test_root_command_guard_update_uses_injected_config_boundary(self):
        result = self.service().update_command_guard(True)

        self.assertEqual(result["status"], "updated")
        self.assertEqual(result["method"], "root")
        self.assertTrue(result["command_guard"]["enabled"])
        self.assertTrue(self.config_writes[-1]["command_guard"]["enabled"])
        self.assertEqual(
            [stage for stage, _payload in self.audit_events[-2:]],
            ["command_guard_update_requested", "command_guard_updated"],
        )
        self.assertEqual(
            self.audit_events[-2][1]["operation_id"],
            self.audit_events[-1][1]["operation_id"],
        )

    def test_audit_intent_failure_prevents_command_guard_update(self):
        def fail_audit(_stage, _payload):
            raise RuntimeError("audit blocked")

        with self.assertRaisesRegex(RuntimeError, "audit blocked"):
            self.service(audit=fail_audit).update_command_guard(True)

        self.assertFalse(self.config["command_guard"]["enabled"])
        self.assertEqual([], self.config_writes)

if __name__ == "__main__":
    unittest.main()
