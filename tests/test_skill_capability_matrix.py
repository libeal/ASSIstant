#!/usr/bin/env python3
"""Close the pre-major-version Skill capability baseline against v2 packages."""

from __future__ import annotations

import hashlib
import json
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))

from skill_package import load_index, load_package  # noqa: E402


INTENTIONAL_ADDITIONS = {
    "container-inspect/container-inspect",
    "container-inspect/container-list",
    "container-inspect/image-inventory",
    "container-inspect/resource-snapshot",
    "container-inspect/runtime-summary",
    "database-inspect/instance-discovery",
    "database-inspect/instance-health",
    "database-inspect/instance-metrics",
    "ops-change/account-audit",
    "ops-change/package-query",
    "ops-change/package-upgrade-plan",
    "ops-change/schedule-audit",
    "ops-change/schedule-edit-plan",
    "ops-change/service-restart",
    "ops-change/systemd-dropin",
}
INTENTIONAL_DESCRIPTION_ADJUSTMENTS = {
    "controlled-tools",
    "network-ops-tools",
    "ops-basic",
    "os-deep-inspect",
    "session-history",
}
INTENTIONAL_CLI_ADDITIONS = {
    "skills list",
    "skills read",
    "skills install",
    "skills uninstall",
    "credentials",
}
INTENTIONAL_API_ADDITIONS = {
    "skills:list",
    "skills:read",
    "skills:install",
    "skills:uninstall",
}
INTENTIONAL_WEB_ADDITIONS = {"/api/skill-components"}
INTENTIONAL_ERROR_CODE_ADDITIONS = {
    "credential_expired",
    "credential_unavailable",
    "host_operation_not_allowed",
    "invalid_install_state",
    "invalid_skill_package",
    "legacy_format_unsupported",
    "runtime_busy",
    "skill_component_install_failed",
    "skill_component_uninstall_failed",
    "skill_digest_mismatch",
    "skill_download_failed",
    "skill_not_loaded",
    "skill_operation_failed",
    "skill_package_incompatible",
    "skill_package_invalid",
    "skill_package_unavailable",
    "target_changed",
    "unsupported",
}
INTENTIONAL_ERROR_CODE_REMOVALS = {"invalid_skill_manifest"}
CLI_COMMAND_MARKERS = {"skills validate": "agent skills list|validate"}


class SkillCapabilityMatrixTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.baseline = json.loads(
            (ROOT / "tests/fixtures/skill-capability-baseline.json").read_text(
                encoding="utf-8"
            )
        )
        cls.packages = {
            path.name: load_package(path, "builtin")
            for path in sorted((ROOT / "skills").iterdir())
            if path.is_dir() and not path.is_symlink()
        }
        cls.current = {
            f"{name}/{tool['name']}": tool
            for name, package in cls.packages.items()
            for tool in package["tools"]
        }

    def test_every_baseline_tool_is_preserved_without_contract_regression(self) -> None:
        baseline_refs = set()
        changed_descriptions = set()
        for skill, package in self.baseline["skills"].items():
            self.assertIn(skill, self.packages)
            self.assertTrue(self.packages[skill]["description"])
            if package["description"] != self.packages[skill]["description"]:
                changed_descriptions.add(skill)
            for tool_name, expected in package["tools"].items():
                ref = f"{skill}/{tool_name}"
                baseline_refs.add(ref)
                self.assertIn(ref, self.current)
                actual = self.current[ref]
                self.assertEqual("single_json_object", expected["parameters"])
                self.assertEqual(expected["risk"], actual["risk"])
                self.assertEqual(expected["approval_scope"], actual["approval_scope"])
                self.assertEqual(
                    expected["execution_class"], actual["execution"]["class"]
                )
                self.assertEqual(
                    expected["capability"], actual["execution"]["capability"]
                )
        self.assertEqual(43, len(baseline_refs))
        self.assertEqual(INTENTIONAL_DESCRIPTION_ADJUSTMENTS, changed_descriptions)

    def test_all_nonbaseline_tools_are_reviewed_intentional_additions(self) -> None:
        baseline_refs = {
            f"{skill}/{tool}"
            for skill, package in self.baseline["skills"].items()
            for tool in package["tools"]
        }
        self.assertEqual(INTENTIONAL_ADDITIONS, set(self.current) - baseline_refs)
        self.assertEqual(58, len(self.current))

    def test_index_and_package_tool_catalog_are_exact(self) -> None:
        sections = load_index(ROOT / "skills/INDEX.md")
        index_refs = {
            tool["ref"] for section in sections.values() for tool in section["tools"]
        }
        self.assertEqual(set(self.current), index_refs)
        self.assertEqual(set(self.packages), set(sections))

    def test_every_tool_has_a_complete_generic_dispatch_contract(self) -> None:
        for ref, tool in self.current.items():
            with self.subTest(ref=ref):
                self.assertTrue(tool["description"])
                self.assertRegex(tool["approval_scope"], r"^[a-z][a-z0-9_]{0,63}$")
                self.assertIn(
                    tool["execution"]["class"],
                    {"runner", "host_helper", "credential_helper"},
                )
                self.assertIn(tool["execution"]["dispatch"], {"always", "apply_only"})
                self.assertIsInstance(tool["runtime_inputs"], list)
                self.assertIsInstance(tool["guards"], list)

    def test_cli_and_api_baselines_are_retained_with_reviewed_additions(self) -> None:
        surface = self.baseline["runtime_surface"]
        cli = (ROOT / "bin/agent").read_text(encoding="utf-8")
        for command in surface["cli_commands"]:
            with self.subTest(cli=command):
                self.assertIn(CLI_COMMAND_MARKERS.get(command, f"agent {command}"), cli)
        for command in INTENTIONAL_CLI_ADDITIONS:
            with self.subTest(cli_addition=command):
                self.assertIn(f"agent {command}", cli)

        api = (ROOT / "lib/api.sh").read_text(encoding="utf-8")
        for action in surface["api_actions"]:
            with self.subTest(api=action):
                self.assertIn(action, api)
        for action in INTENTIONAL_API_ADDITIONS:
            with self.subTest(api_addition=action):
                self.assertIn(action, api)

    def test_web_and_remote_surfaces_are_retained_with_reviewed_additions(self) -> None:
        surface = self.baseline["runtime_surface"]
        server = (ROOT / "web/server.py").read_text(encoding="utf-8")
        for route in surface["web_routes"]:
            with self.subTest(web=route):
                self.assertIn(f'"{route}"', server)
        for route in INTENTIONAL_WEB_ADDITIONS:
            with self.subTest(web_addition=route):
                self.assertIn(f'"{route}"', server)

        remote = surface["remote_behavior"]
        self.assertEqual(
            {
                "core_contains_builtin_index": True,
                "core_contains_builtin_packages": False,
                "skills_are_separate_assets": True,
            },
            remote,
        )
        release_builder = (ROOT / "scripts/build-remote-release.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn(
            'cp -a "${ROOT_DIR}/skills/INDEX.md" "${core_stage}/skills/INDEX.md"',
            release_builder,
        )
        self.assertIn('skill_stage="${tmp_root}/skill-${skill_name}"', release_builder)
        self.assertIn(
            "core_contents:{builtin_skill_index:true,builtin_skill_packages:false}",
            release_builder,
        )

    def test_helper_routes_and_error_code_differences_are_fully_classified(self) -> None:
        surface = self.baseline["runtime_surface"]
        helper_routes = {
            tool["execution"]["capability"]: tool["execution"]["class"]
            for tool in self.current.values()
            if tool["execution"]["capability"]
            and tool["execution"]["capability"] in surface["helper_routes"]
        }
        self.assertEqual(surface["helper_routes"], helper_routes)

        schema = json.loads((ROOT / "schema/domain.json").read_text(encoding="utf-8"))
        current_codes = set(schema["error_codes"])
        self.assertTrue(INTENTIONAL_ERROR_CODE_ADDITIONS <= current_codes)
        self.assertTrue(INTENTIONAL_ERROR_CODE_REMOVALS.isdisjoint(current_codes))
        reconstructed_baseline = (
            current_codes - INTENTIONAL_ERROR_CODE_ADDITIONS
        ) | INTENTIONAL_ERROR_CODE_REMOVALS
        expected = surface["error_codes"]
        self.assertEqual(expected["count"], len(reconstructed_baseline))
        encoded = "".join(f"{name}\n" for name in sorted(reconstructed_baseline)).encode()
        self.assertEqual(expected["sorted_names_sha256"], hashlib.sha256(encoded).hexdigest())


if __name__ == "__main__":
    unittest.main()
