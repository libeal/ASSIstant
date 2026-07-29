#!/usr/bin/env python3

import io
import json
import os
import shutil
import sys
import tempfile
import urllib.error
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))
sys.path.insert(0, str(ROOT / "web"))

from provider import (  # noqa: E402
    ProviderSecurityHelpers,
    ProviderService,
    extract_model_ids,
)
from provider_security import (  # noqa: E402
    host_is_trusted,
    provider_url_host,
    trusted_provider_hosts,
)
import policy as policy_module  # noqa: E402
import provider as provider_module  # noqa: E402
import pinned_http  # noqa: E402
from policy import PolicyService  # noqa: E402
from skills import SkillService  # noqa: E402
from skill_components import SkillWebComponentError, SkillWebRegistry  # noqa: E402


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
        (self.root / "notes.txt").write_text("reference\n", encoding="utf-8")
        (self.root / "ignored.bin").write_bytes(b"ignore")
        (self.root / ".hidden" / "secret.md").write_text("hidden\n", encoding="utf-8")
        self.service = SkillService(self.root)

    def tearDown(self):
        self.temp.cleanup()

    @staticmethod
    def _write_package(root, name, *, execution_class="runner", capability=""):
        package = root / name
        scripts = package / "scripts"
        scripts.mkdir(parents=True)
        (package / "SKILL.md").write_text(
            f"---\nname: {name}\ndescription: Test package\n---\n\n# Test\n",
            encoding="utf-8",
        )
        (scripts / "inspect.sh").write_text("#!/usr/bin/env bash\n", encoding="utf-8")
        execution = {
            "class": execution_class,
            "capability": capability,
            "dispatch": "always",
        }
        if execution_class != "runner":
            (scripts / "adapter.py").write_text(
                "print('{\"ok\":false}')\n",
                encoding="utf-8",
            )
            execution["adapter"] = "scripts/adapter.py"
        (package / "linux-agent.json").write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "package_version": "1.0.0",
                    "core_api": 1,
                    "category": "custom",
                    "tools": [
                        {
                            "name": "inspect",
                            "description": "Inspect fixture.",
                            "entrypoint": "scripts/inspect.sh",
                            "risk": "low",
                            "approval_scope": "skill_readonly",
                            "execution": execution,
                            "runtime_inputs": [],
                            "guards": [],
                        }
                    ],
                    "components": {},
                }
            ),
            encoding="utf-8",
        )
        return package

    def test_list_and_read_visible_skill_files(self):
        listing = self.service.list_files()

        self.assertTrue(listing["ok"])
        self.assertEqual(listing["markdown_files"], ["README.md", "nested/guide.md"])
        self.assertEqual(listing["script_files"], ["run.sh"])
        self.assertEqual(listing["reference_files"], ["notes.txt"])
        self.assertEqual(
            [item["type"] for item in listing["tree"]],
            ["dir", "file", "file", "file"],
        )
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
            "ignored.bin",
            ".hidden/secret.md",
            "linked.md",
        ):
            with self.subTest(path=path), self.assertRaises(ValueError):
                self.service.safe_path(path)

    def test_standard_instruction_only_package_is_listed(self):
        package = self.root / "instruction-only"
        package.mkdir()
        (package / "SKILL.md").write_text(
            "---\nname: instruction-only\ndescription: Instructions only\n---\n\n# Guide\n",
            encoding="utf-8",
        )

        listing = self.service.list_files()

        self.assertEqual(listing["packages"][0]["name"], "instruction-only")
        self.assertEqual(listing["packages"][0]["state"], "installed")
        self.assertEqual(listing["packages"][0]["tools"], [])

    def test_invalid_and_legacy_packages_are_isolated(self):
        package = self.root / "broken"
        package.mkdir()
        (package / "SKILL.md").write_text(
            "---\nname: another-skill\ndescription: Broken\n---\n",
            encoding="utf-8",
        )
        legacy = self.root / "legacy"
        legacy.mkdir()
        (legacy / "SKILL.md").write_text(
            "---\nname: legacy\ndescription: Legacy\n---\n",
            encoding="utf-8",
        )
        (legacy / "manifest.json").write_text("{}", encoding="utf-8")
        incompatible = self.root / "future-core"
        incompatible.mkdir()
        (incompatible / "SKILL.md").write_text(
            "---\nname: future-core\ndescription: Future core\n---\n",
            encoding="utf-8",
        )
        (incompatible / "linux-agent.json").write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "package_version": "1.0.0",
                    "core_api": 2,
                    "category": "custom",
                    "tools": [],
                    "components": {},
                }
            ),
            encoding="utf-8",
        )

        packages = {item["name"]: item for item in self.service.list_files()["packages"]}

        self.assertEqual(packages["broken"]["state"], "invalid")
        self.assertIn("match", packages["broken"]["error"])
        self.assertEqual(packages["legacy"]["state"], "invalid")
        self.assertIn("legacy_format_unsupported", packages["legacy"]["error"])
        self.assertEqual(packages["future-core"]["state"], "incompatible")

    def test_user_overlay_reserved_name_is_disabled_without_breaking_listing(self):
        user_root = Path(self.temp.name) / "user-skills"
        self._write_package(user_root, "reserved")
        (self.root / "INDEX.md").write_text(
            "# Skill Index\n\n## reserved\n\n> Reserved\n",
            encoding="utf-8",
        )
        service = SkillService(self.root, user_skills_root=user_root)

        listing = service.list_files()

        self.assertTrue(listing["ok"])
        self.assertNotIn("reserved", {item["name"] for item in listing["packages"]})
        self.assertEqual(listing["findings"][0]["code"], "SKILL_NAME_RESERVED")

    def test_user_overlay_cannot_declare_privileged_execution(self):
        user_root = Path(self.temp.name) / "user-skills"
        self._write_package(
            user_root,
            "custom-network",
            execution_class="host_helper",
            capability="network.apply",
        )
        service = SkillService(self.root, user_skills_root=user_root)

        package = service.list_files()["packages"][0]

        self.assertEqual(package["state"], "invalid")
        self.assertIn("user Skill tools", package["error"])

    def test_user_overlay_root_symlink_is_rejected_before_enumeration(self):
        outside = Path(self.temp.name) / "outside-skills"
        outside.mkdir()
        linked_root = Path(self.temp.name) / "linked-skills"
        os.symlink(outside, linked_root)

        with self.assertRaisesRegex(ValueError, "Skill root"):
            SkillService(self.root, user_skills_root=linked_root)


class SkillWebRegistryTests(unittest.TestCase):
    def test_builtin_component_registers_routes_jobs_and_declared_assets(self):
        registry = SkillWebRegistry(
            SkillService(ROOT / "skills"),
            remote_mode=True,
            managed_execution=False,
        )

        public = registry.public_components()
        database = next(item for item in public if item["resource"] == "database")
        self.assertEqual("database-inspect", database["name"])
        self.assertTrue(registry.handles_job("database", "health"))
        self.assertEqual(
            {"retryable": True, "http": 503},
            registry.error_spec("database_unreachable"),
        )
        profiles = registry.handle_web_action("GET", "/api/database/profiles", {})
        self.assertEqual("remote", profiles["mode"])
        frontend = registry.asset_path(
            "database-inspect", "assets/web/view-database.js"
        )
        self.assertTrue(frontend.is_file())
        with self.assertRaises(SkillWebComponentError):
            registry.asset_path(
                "database-inspect", "assets/web/database.py"
            )

    def test_credential_helper_web_component_is_hidden_without_execution_channel(self):
        registry = SkillWebRegistry(
            SkillService(ROOT / "skills"),
            remote_mode=False,
            managed_execution=False,
        )

        self.assertNotIn(
            "database",
            {component["resource"] for component in registry.public_components()},
        )
        self.assertFalse(registry.handles_job("database", "health"))
        self.assertIsNone(
            registry.handle_web_action("GET", "/api/database/profiles", {})
        )
        self.assertTrue(
            any(
                item.get("code") == "SKILL_WEB_COMPONENT_UNAVAILABLE"
                and item.get("skill") == "database-inspect"
                for item in registry.findings
            )
        )

    def test_reload_preserves_unchanged_component_instance_and_credentials(self):
        registry = SkillWebRegistry(
            SkillService(ROOT / "skills"),
            remote_mode=True,
            managed_execution=False,
        )
        instance = registry.components["database"]["instance"]
        reference = instance.secret_store.put(
            "database-user",
            "database-password",
            {"mode": "remote"},
        )
        self.addCleanup(instance.secret_store.clear)

        registry.reload()

        self.assertIs(instance, registry.components["database"]["instance"])
        self.assertEqual({"mode": "remote"}, instance.secret_store.metadata(reference))

    def test_zero_and_invalid_skill_sets_leave_the_web_registry_usable(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "skills"
            root.mkdir()
            empty = SkillWebRegistry(
                SkillService(root), remote_mode=False, managed_execution=False
            )
            self.assertEqual([], empty.public_components())
            self.assertEqual(set(), empty.job_refs())
            self.assertIsNone(empty.handle_web_action("GET", "/api/unknown", {}))

            package = root / "broken"
            package.mkdir()
            (package / "SKILL.md").write_text(
                "---\nname: broken\ndescription: Broken package\n---\n",
                encoding="utf-8",
            )
            (package / "linux-agent.json").write_text("{}", encoding="utf-8")
            invalid = SkillWebRegistry(
                SkillService(root), remote_mode=False, managed_execution=False
            )
            self.assertEqual([], invalid.public_components())
            self.assertTrue(
                any(
                    item.get("code") == "SKILL_COMPONENT_INVALID"
                    for item in invalid.findings
                )
            )

    def test_remote_route_materializes_only_its_pending_signed_component(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "skills"
            root.mkdir()
            source = ROOT / "skills" / "database-inspect"
            contract = json.loads(
                (source / "linux-agent.json").read_text(encoding="utf-8")
            )
            manifest = Path(temporary) / "release-manifest.json"
            manifest.write_text(
                json.dumps(
                    {
                        "schema_version": 2,
                        "skills": {
                            "database-inspect": {
                                "components": contract["components"]
                            },
                            "instruction-only": {"components": {}},
                        },
                    }
                ),
                encoding="utf-8",
            )
            materialized = []

            def materialize(name):
                materialized.append(name)
                shutil.copytree(source, root / name)
                return {"ok": True, "status": "skill_materialized", "skill": name}

            registry = SkillWebRegistry(
                SkillService(root),
                remote_mode=True,
                managed_execution=False,
                remote_manifest=manifest,
                materialize=materialize,
            )

            self.assertEqual([], registry.public_components())
            self.assertTrue(registry.handles_job("database", "health"))
            self.assertEqual([], materialized)
            with self.assertRaises(SkillWebComponentError):
                registry.asset_path(
                    "database-inspect", "assets/web/view-database.js"
                )
            self.assertEqual([], materialized)
            profiles = registry.handle_web_action(
                "GET", "/api/database/profiles", {}
            )
            self.assertEqual("remote", profiles["mode"])
            self.assertEqual(["database-inspect"], materialized)
            self.assertEqual("database-inspect", registry.public_components()[0]["name"])


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
            url_host=provider_url_host,
            trusted_hosts=trusted_provider_hosts,
            host_is_trusted=host_is_trusted,
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
        self.assertEqual(self.fetches[0][1]["User-Agent"], "LinuxAgentWeb/1.0")

    def test_default_fetcher_revalidates_each_redirect_hop(self):
        requests = []

        class Response:
            def __enter__(self):
                return self

            def __exit__(self, *_args):
                return False

            def read(self, _limit=-1):
                return b'{"data":[{"id":"redirected-model"}]}'

        class Opener:
            def __init__(self, redirect):
                self.redirect = redirect

            def open(self, request, timeout):
                requests.append((request.full_url, dict(request.header_items()), timeout))
                if self.redirect:
                    raise urllib.error.HTTPError(
                        request.full_url,
                        302,
                        "redirect",
                        {"Location": "https://api.example/v1/redirected-models"},
                        io.BytesIO(),
                    )
                return Response()

        with mock.patch.object(
            pinned_http,
            "build_pinned_opener",
            side_effect=[Opener(True), Opener(False)],
        ) as build_opener:
            result = self.service(fetch_json=None).list_models(
                {"provider": "openai_compatible"}
            )

        self.assertTrue(result["ok"], result)
        self.assertEqual(result["models"], [{"id": "redirected-model"}])
        self.assertEqual(build_opener.call_count, 2)
        self.assertEqual(len(self.inspected), 3)
        self.assertEqual(
            [item[0] for item in self.inspected],
            [
                "https://api.example/v1/models",
                "https://api.example/v1/models",
                "https://api.example/v1/redirected-models",
            ],
        )
        self.assertEqual(len(requests), 2)
        self.assertEqual(requests[1][0], "https://api.example/v1/redirected-models")
        self.assertEqual(requests[1][1]["Authorization"], "Bearer configured-secret")

    def test_credentialed_redirect_to_untrusted_host_is_rejected_before_second_connection(self):
        requests = []

        class Opener:
            def open(self, request, timeout):
                requests.append((request.full_url, dict(request.header_items()), timeout))
                raise urllib.error.HTTPError(
                    request.full_url,
                    302,
                    "redirect",
                    {"Location": "https://attacker.example/collect"},
                    io.BytesIO(),
                )

        with mock.patch.object(
            pinned_http,
            "build_pinned_opener",
            return_value=Opener(),
        ) as build_opener:
            result = self.service(fetch_json=None).list_models(
                {"provider": "openai_compatible"}
            )

        self.assertFalse(result["ok"])
        self.assertEqual(result["status"], "provider_host_not_allowed")
        self.assertEqual(build_opener.call_count, 1)
        self.assertEqual(len(requests), 1)
        self.assertIn("attacker.example", self.inspected[-1][0])
        self.assertNotIn("configured-secret", json.dumps(result))

    def test_pinned_https_handler_uses_context_without_legacy_hostname_argument(self):
        handler = provider_module._PinnedHTTPSHandler(["203.0.113.10"])
        response = mock.sentinel.response

        with mock.patch.object(handler, "do_open", return_value=response) as do_open:
            result = handler.https_open(mock.sentinel.request)

        self.assertIs(result, response)
        connection_type, request = do_open.call_args.args
        self.assertIs(request, mock.sentinel.request)
        self.assertEqual(do_open.call_args.kwargs, {"context": handler._context})
        connection = connection_type("api.example", context=handler._context)
        self.assertEqual(connection.resolved_addresses, ("203.0.113.10",))

    def test_credentialed_body_api_url_override_is_blocked(self):
        """Body api_url to an untrusted public host must not receive the API key."""

        result = self.service().list_models(
            {
                "provider": "openai_compatible",
                "api_url": "https://attacker.example/v1/chat/completions",
                "api_key": "request-secret",
            }
        )
        self.assertFalse(result["ok"])
        self.assertIn(
            result["status"],
            {"provider_url_override_blocked", "provider_host_not_allowed"},
        )
        self.assertEqual(self.fetches, [])

    def test_allowlisted_body_api_url_override_is_permitted(self):
        self.config["providers_security"] = {
            "require_https": True,
            "allowed_hosts": ["models.example"],
        }
        result = self.service().list_models(
            {
                "provider": "openai_compatible",
                "api_url": "https://models.example/v1/chat/completions",
                "api_key": "request-secret",
            }
        )
        self.assertTrue(result["ok"], result)
        self.assertTrue(self.fetches)
        self.assertIn("models.example", self.fetches[0][0])

    def test_ssrf_rejection_stops_before_fetch(self):
        blocked_helpers = ProviderSecurityHelpers(
            policy_from_config=lambda _config: {"require_https": True},
            validate_url=lambda url, _security: (url, ""),
            inspect_url=lambda _url, _security: ("", "blocked_internal_address", []),
            error_message=lambda _status: "internal address blocked",
            url_host=provider_url_host,
            trusted_hosts=trusted_provider_hosts,
            host_is_trusted=host_is_trusted,
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

    def service(
        self,
        audit=None,
        config_updater=None,
        overlay_root=None,
        effective_uid=0,
        root=None,
        privileged_writer=None,
        managed_execution=None,
    ):
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
        options = {
            "config_reader": lambda: self.config,
            "config_writer": write_config,
            "agent_api": agent_api,
            "audit": audit_writer,
            "config_public_state": lambda: {"ok": True, "config": self.config},
            "config_updater": config_updater,
            "effective_uid": lambda: effective_uid,
            "process_runner": lambda *_args, **_kwargs: self.fail(
                "root tests must not run sudo"
            ),
            "privileged_writer": privileged_writer,
        }
        if managed_execution is not None:
            options["managed_execution"] = managed_execution
        if overlay_root is not None:
            options["overlay_root"] = overlay_root
        return PolicyService(
            self.root if root is None else root,
            **options,
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

    def test_policy_write_rechecks_gate_immediately_before_replace(self):
        before = self.policy_path.read_bytes()
        original_fsync = policy_module._fsync_file

        def disable_after_staged_file_is_synced(path):
            original_fsync(path)
            self.config["web"] = {"sensitive_edits_enabled": False}

        with mock.patch.object(
            policy_module,
            "_fsync_file",
            side_effect=disable_after_staged_file_is_synced,
        ), mock.patch.object(policy_module.os, "replace", wraps=os.replace) as replace:
            result = self.service().write_file("example.json", '{"enabled":true}')

        self.assertFalse(result["ok"])
        self.assertEqual(result["status"], "sensitive_edits_disabled")
        self.assertEqual(before, self.policy_path.read_bytes())
        replace.assert_not_called()
        self.assertEqual(
            list((self.root / "tmp" / "web" / "policy-edits").glob("*.tmp")),
            [],
        )

    def test_source_write_creates_missing_policy_overlay(self):
        overlay = self.root / "data" / "policies"

        result = self.service(overlay_root=overlay, effective_uid=1000).write_file(
            "example.json", '{"enabled":true}'
        )

        self.assertTrue(result["ok"], result)
        self.assertEqual(result["method"], "direct")
        self.assertEqual(
            json.loads((overlay / "example.json").read_text(encoding="utf-8")),
            {"enabled": True},
        )
        self.assertEqual(
            json.loads(self.policy_path.read_text(encoding="utf-8")),
            {"enabled": False},
        )

    def test_managed_policy_and_guard_propagate_helper_cleanup_warning(self):
        managed_root = Path(self.temp.name) / "releases" / "current"
        (managed_root / "policies").mkdir(parents=True)
        (managed_root / "policies" / "example.json").write_text(
            '{"enabled":false}\n', encoding="utf-8"
        )
        overlay = Path(self.temp.name) / "data" / "policies"

        def privileged_writer(operation, params):
            if operation == "policy.write":
                return {
                    "ok": True,
                    "status": "saved",
                    "warning": "policy_cleanup_pending",
                }
            self.config["command_guard"] = {"enabled": params["enabled"]}
            return {
                "ok": True,
                "status": "updated",
                "warning": "policy_cleanup_pending",
            }

        service = self.service(
            root=managed_root,
            overlay_root=overlay,
            privileged_writer=privileged_writer,
        )
        policy_result = service.write_file("example.json", '{"enabled":true}')
        guard_result = service.update_command_guard(True)

        self.assertEqual(policy_result["warning"], "policy_cleanup_pending")
        self.assertEqual(guard_result["warning"], "policy_cleanup_pending")

    def test_no_systemd_release_layout_writes_policy_without_helper(self):
        release_root = Path(self.temp.name) / "releases" / "v1"
        (release_root / "policies").mkdir(parents=True)
        (release_root / "policies" / "example.json").write_text(
            '{"enabled":false}\n', encoding="utf-8"
        )
        overlay = Path(self.temp.name) / "data" / "policies"
        service = self.service(
            root=release_root,
            overlay_root=overlay,
            effective_uid=1000,
            managed_execution=False,
            privileged_writer=lambda *_args: self.fail(
                "no-systemd policy write must not call the helper"
            ),
        )

        result = service.write_file("example.json", '{"enabled":true}')

        self.assertTrue(result["ok"], result)
        self.assertEqual(result["method"], "direct")
        self.assertEqual(
            json.loads((overlay / "example.json").read_text(encoding="utf-8")),
            {"enabled": True},
        )

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

    def test_sensitive_edit_switch_blocks_only_mutations(self):
        self.config["web"] = {"sensitive_edits_enabled": False}
        before = self.policy_path.read_bytes()

        read = self.service().read_file("example.json")
        validation = self.service().validate("example.json", '{"enabled":true}')
        write = self.service().write_file("example.json", '{"enabled":true}')
        guard = self.service().update_command_guard(True)

        self.assertTrue(read["ok"])
        self.assertTrue(validation["ok"])
        self.assertEqual(write["status"], "sensitive_edits_disabled")
        self.assertEqual(guard["status"], "sensitive_edits_disabled")
        self.assertEqual(before, self.policy_path.read_bytes())
        self.assertFalse(self.config["command_guard"]["enabled"])
        self.assertEqual([], self.audit_events)

    def test_command_guard_rechecks_gate_inside_config_transaction(self):
        def update_after_admin_disables(mutator):
            self.config["web"] = {"sensitive_edits_enabled": False}
            mutator(self.config)
            self.config_writes.append(dict(self.config))

        result = self.service(
            config_updater=update_after_admin_disables
        ).update_command_guard(True)

        self.assertFalse(result["ok"])
        self.assertEqual(result["status"], "sensitive_edits_disabled")
        self.assertFalse(self.config["command_guard"]["enabled"])
        self.assertEqual(self.config_writes, [])

    def test_legacy_sudo_endpoint_never_invokes_process_runner(self):
        result = self.service().sudo_check("must-not-be-used")

        self.assertTrue(result["ok"])
        self.assertEqual(result["status"], "authorization_not_required")
        self.assertEqual(result["method"], "web_bearer")

    def test_audit_intent_failure_prevents_command_guard_update(self):
        def fail_audit(_stage, _payload):
            raise RuntimeError("audit blocked")

        with self.assertRaisesRegex(RuntimeError, "audit blocked"):
            self.service(audit=fail_audit).update_command_guard(True)

        self.assertFalse(self.config["command_guard"]["enabled"])
        self.assertEqual([], self.config_writes)

if __name__ == "__main__":
    unittest.main()


class MetricsRegistryTests(unittest.TestCase):
    def test_counter_and_prometheus_render(self):
        from metrics import create_default_registry, normalize_route

        registry = create_default_registry(process_start_time=1_700_000_000.0)
        registry.inc(
            "linux_agent_http_requests_total",
            labels={"method": "GET", "route": "health", "status": "200"},
        )
        registry.inc(
            "linux_agent_http_requests_total",
            labels={"method": "GET", "route": "health", "status": "200"},
        )
        registry.inc(
            "linux_agent_jobs_completed_total",
            labels={"result": "succeeded"},
        )
        text = registry.render_prometheus_text(
            extra_gauges=[
                ("linux_agent_build_info", {"version": "v0.0.0-test"}, 1),
                ("linux_agent_jobs", {"status": "running"}, 2),
                ("linux_agent_jobs_active", {}, 2),
            ]
        )
        self.assertIn("linux_agent_http_requests_total{method=\"GET\",route=\"health\",status=\"200\"} 2", text)
        self.assertIn("linux_agent_build_info{version=\"v0.0.0-test\"} 1", text)
        self.assertIn("linux_agent_jobs{status=\"running\"} 2", text)
        self.assertIn("# TYPE linux_agent_jobs_completed_total counter", text)
        self.assertEqual(normalize_route("/api/jobs/abc123"), "jobs_detail")
        self.assertEqual(normalize_route("/api/jobs/abc123/cancel"), "jobs_cancel")
        self.assertEqual(normalize_route("/api/config/web"), "config_web")

    def test_registry_is_thread_safe_enough_for_concurrent_increments(self):
        from concurrent.futures import ThreadPoolExecutor
        from metrics import MetricsRegistry

        registry = MetricsRegistry()
        registry.register_counter("test_counter", "test")

        def bump(_):
            registry.inc("test_counter", labels={"k": "v"})

        with ThreadPoolExecutor(max_workers=8) as pool:
            list(pool.map(bump, range(200)))
        self.assertEqual(registry.get_counter("test_counter", labels={"k": "v"}), 200.0)
