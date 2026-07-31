from __future__ import annotations

import io
import json
import os
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SPEC_FIXTURES = ROOT / "tests" / "fixtures" / "agent-skills-spec"
sys.path.insert(0, os.fspath(ROOT / "lib"))

from skill_lifecycle import LifecycleError, install, uninstall  # noqa: E402
from skill_package import (  # noqa: E402
    SkillPackageError,
    SkillPackageIncompatibleError,
    catalog,
    discover_catalog,
    load_index,
    load_package,
    validate_builtin_root,
)


def write_skill(root: Path, name: str, frontmatter: str | None = None) -> Path:
    package = root / name
    package.mkdir(parents=True)
    metadata = frontmatter or f"name: {name}\ndescription: {name} instructions"
    (package / "SKILL.md").write_text(
        f"---\n{metadata}\n---\n\n# Instructions\n",
        encoding="utf-8",
    )
    return package


class SkillPackageTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_standard_frontmatter_and_instruction_only_package(self) -> None:
        instruction_only = load_package(SPEC_FIXTURES / "instruction-only", "user")
        self.assertEqual("instruction-only", instruction_only["name"])
        self.assertIsNone(instruction_only["extension"])
        self.assertEqual([], instruction_only["tools"])

        loaded = load_package(SPEC_FIXTURES / "with-resources", "user")
        self.assertEqual("with-resources", loaded["name"])
        self.assertEqual("Bounded sample instructions", loaded["description"])
        self.assertEqual({"author": "example", "version": "1.0"}, loaded["frontmatter"]["metadata"])
        self.assertEqual("Bash Read", loaded["frontmatter"]["allowed-tools"])
        self.assertIsNone(loaded["extension"])
        self.assertEqual([], loaded["tools"])
        self.assertTrue((SPEC_FIXTURES / "with-resources" / "references" / "guide.md").is_file())
        self.assertTrue((SPEC_FIXTURES / "with-resources" / "assets" / "template.txt").is_file())

    def test_duplicate_unknown_and_invalid_frontmatter_are_rejected(self) -> None:
        fixture_cases = ("duplicate-key", "invalid-name")
        for directory in fixture_cases:
            with self.subTest(directory=directory):
                with self.assertRaises(SkillPackageError):
                    load_package(SPEC_FIXTURES / directory, "user")

        cases = {"unknown": "name: unknown\ndescription: unknown\ncustom: value"}
        for directory, frontmatter in cases.items():
            with self.subTest(directory=directory):
                package = write_skill(self.root, directory, frontmatter)
                with self.assertRaises(SkillPackageError):
                    load_package(package, "user")

    def test_directory_mismatch_legacy_format_and_links_are_rejected(self) -> None:
        mismatch = write_skill(
            self.root, "directory-name", "name: another-name\ndescription: mismatch"
        )
        with self.assertRaisesRegex(SkillPackageError, "match"):
            load_package(mismatch, "user")

        legacy = write_skill(self.root, "legacy")
        (legacy / "manifest.json").write_text("{}\n", encoding="utf-8")
        with self.assertRaisesRegex(SkillPackageError, "legacy_format_unsupported"):
            load_package(legacy, "user")

        linked = write_skill(self.root, "linked")
        (linked / "references").mkdir()
        (linked / "references" / "escape").symlink_to(self.root / "outside")
        with self.assertRaisesRegex(SkillPackageError, "symbolic links"):
            load_package(linked, "user")

    def test_user_package_cannot_declare_components_or_privileged_tools(self) -> None:
        package = write_skill(self.root, "privileged")
        (package / "scripts").mkdir()
        (package / "scripts" / "tool.sh").write_text("#!/bin/sh\n", encoding="utf-8")
        (package / "scripts" / "adapter.py").write_text("pass\n", encoding="utf-8")
        (package / "scripts" / "handler.py").write_text("pass\n", encoding="utf-8")
        extension = {
            "schema_version": 1,
            "package_version": "1.0.0",
            "core_api": 1,
            "category": "custom",
            "tools": [
                {
                    "name": "tool",
                    "description": "tool",
                    "entrypoint": "scripts/tool.sh",
                    "risk": "high",
                    "approval_scope": "skill_readonly",
                    "execution": {
                        "class": "host_helper",
                        "capability": "sample.apply",
                        "dispatch": "apply_only",
                        "adapter": "scripts/adapter.py",
                    },
                    "runtime_inputs": [],
                    "guards": [],
                }
            ],
            "components": {"host_helper": {"handler": "scripts/handler.py"}},
        }
        (package / "linux-agent.json").write_text(json.dumps(extension), encoding="utf-8")
        with self.assertRaisesRegex(SkillPackageError, "user Skills cannot declare components"):
            load_package(package, "user")

    def test_empty_builtin_catalog_is_valid_and_missing_catalog_is_a_warning(self) -> None:
        empty = self.root / "empty"
        empty.mkdir()
        (empty / "INDEX.md").write_text("# Skill catalog\n", encoding="utf-8")
        self.assertEqual({}, load_index(empty / "INDEX.md"))
        self.assertEqual(
            {"ok": True, "status": "validated", "root": os.fspath(empty), "skills": [], "findings": []},
            validate_builtin_root(empty),
        )

        missing = self.root / "missing"
        missing.mkdir()
        result = validate_builtin_root(missing)
        self.assertTrue(result["ok"])
        self.assertEqual("unavailable", result["status"])
        self.assertEqual("warning", result["findings"][0]["severity"])

        strict = validate_builtin_root(missing, strict=True)
        self.assertFalse(strict["ok"])
        self.assertEqual("critical", strict["findings"][0]["severity"])

    def test_strict_rejects_missing_and_invalid_index_packages(self) -> None:
        missing_root = self.root / "missing-package"
        missing_root.mkdir()
        (missing_root / "INDEX.md").write_text(
            "## declared-only\n\n> declared-only instructions\n",
            encoding="utf-8",
        )

        runtime = validate_builtin_root(missing_root)
        self.assertTrue(runtime["ok"])
        self.assertEqual("unavailable", runtime["skills"][0]["state"])
        self.assertEqual("warning", runtime["findings"][0]["severity"])
        strict = validate_builtin_root(missing_root, strict=True)
        self.assertFalse(strict["ok"])
        self.assertEqual("critical", strict["findings"][0]["severity"])

        invalid_root = self.root / "invalid-package"
        invalid_root.mkdir()
        package = write_skill(invalid_root, "broken")
        (package / "manifest.json").write_text("{}\n", encoding="utf-8")
        (invalid_root / "INDEX.md").write_text(
            "## broken\n\n> broken instructions\n",
            encoding="utf-8",
        )

        runtime = validate_builtin_root(invalid_root)
        self.assertTrue(runtime["ok"])
        self.assertEqual("invalid", runtime["skills"][0]["state"])
        self.assertEqual("warning", runtime["findings"][0]["severity"])
        strict = validate_builtin_root(invalid_root, strict=True)
        self.assertFalse(strict["ok"])
        self.assertEqual("critical", strict["findings"][0]["severity"])

    def test_user_catalog_ignores_internal_transaction_directories(self) -> None:
        builtin = self.root / "builtin"
        builtin.mkdir()
        (builtin / "INDEX.md").write_text("# Empty\n", encoding="utf-8")
        user = self.root / "user"
        user.mkdir()
        (user / ".locks").mkdir()
        (user / ".install.interrupted").mkdir()
        write_skill(user, "visible-user")

        result = catalog(builtin, user)

        self.assertEqual(["visible-user"], [skill["name"] for skill in result["skills"]])
        self.assertEqual([], result["findings"])

    def test_runtime_disables_index_mismatch_but_strict_build_rejects_it(self) -> None:
        write_skill(self.root, "mismatched")
        (self.root / "INDEX.md").write_text(
            "## mismatched\n\n> different catalog description\n",
            encoding="utf-8",
        )

        runtime = validate_builtin_root(self.root)
        self.assertTrue(runtime["ok"])
        self.assertEqual("invalid", runtime["skills"][0]["state"])
        self.assertEqual("warning", runtime["findings"][0]["severity"])

        strict = validate_builtin_root(self.root, strict=True)
        self.assertFalse(strict["ok"])
        self.assertEqual("invalid", strict["skills"][0]["state"])
        self.assertEqual("critical", strict["findings"][0]["severity"])

    def test_incompatible_extension_is_distinct_from_an_invalid_package(self) -> None:
        builtin = self.root / "builtin"
        package = write_skill(builtin, "future-core")
        (package / "linux-agent.json").write_text(
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
        (builtin / "INDEX.md").write_text(
            "## future-core\n\n> future-core instructions\n",
            encoding="utf-8",
        )

        with self.assertRaises(SkillPackageIncompatibleError):
            load_package(package, "builtin")
        runtime = validate_builtin_root(builtin)
        self.assertTrue(runtime["ok"])
        self.assertEqual("incompatible", runtime["skills"][0]["state"])
        self.assertEqual("SKILL_PACKAGE_INCOMPATIBLE", runtime["findings"][0]["code"])
        strict = validate_builtin_root(builtin, strict=True)
        self.assertFalse(strict["ok"])
        self.assertEqual("incompatible", strict["skills"][0]["state"])
        self.assertEqual("critical", strict["findings"][0]["severity"])

        empty_builtin = self.root / "empty-builtin"
        empty_builtin.mkdir()
        (empty_builtin / "INDEX.md").write_text("# Empty\n", encoding="utf-8")
        user_catalog = catalog(empty_builtin, builtin)
        self.assertTrue(user_catalog["ok"])
        self.assertEqual("incompatible", user_catalog["skills"][0]["state"])
        discovered = discover_catalog(user_catalog, "future-core")
        self.assertEqual(
            [{"name": "future-core", "state": "incompatible", "score": 100}],
            discovered["candidates"],
        )


class SkillLifecycleTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.sources = self.root / "sources"
        self.sources.mkdir()
        self.target = self.root / "installed"

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_install_replace_and_uninstall_are_atomic(self) -> None:
        source = write_skill(self.sources, "local-skill")
        result = install(source, self.target, "user", None)
        self.assertEqual("installed", result["status"])
        self.assertEqual(0o640, (self.target / "local-skill" / "SKILL.md").stat().st_mode & 0o777)

        replacement_root = self.root / "replacement"
        replacement = write_skill(
            replacement_root,
            "local-skill",
            "name: local-skill\ndescription: replacement instructions",
        )
        with self.assertRaisesRegex(LifecycleError, "already installed"):
            install(replacement, self.target, "user", None)
        replaced = install(replacement, self.target, "user", None, replace=True)
        self.assertEqual("replaced", replaced["status"])
        self.assertIn(
            "replacement instructions",
            (self.target / "local-skill" / "SKILL.md").read_text(encoding="utf-8"),
        )

        removed = uninstall("local-skill", self.target, "user", True)
        self.assertTrue(removed["purged"])
        self.assertFalse((self.target / "local-skill").exists())

    def test_reserved_name_and_unsafe_archive_are_rejected(self) -> None:
        builtin = self.root / "builtin"
        builtin.mkdir()
        (builtin / "INDEX.md").write_text("## reserved\n\n> reserved\n", encoding="utf-8")
        source = write_skill(self.sources, "reserved")
        with self.assertRaisesRegex(LifecycleError, "reserved"):
            install(source, self.target, "user", builtin / "INDEX.md")

        archive = self.root / "unsafe.tar.gz"
        with tarfile.open(archive, "w:gz") as output:
            member = tarfile.TarInfo("../escape")
            payload = b"escape"
            member.size = len(payload)
            output.addfile(member, io.BytesIO(payload))
        with self.assertRaisesRegex(LifecycleError, "unsafe path"):
            install(archive, self.target, "user", None)
        self.assertFalse((self.root / "escape").exists())

    def test_failed_uninstall_does_not_create_the_target_root(self) -> None:
        missing = self.root / "never-created"
        with self.assertRaisesRegex(LifecycleError, "unavailable"):
            uninstall("missing", missing, "user", False)
        self.assertFalse(missing.exists())

    def _fail_first_target_root_fsync(self):
        from skill_lifecycle import _fsync_directory

        triggered = False

        def fail_once(path: Path) -> None:
            nonlocal triggered
            if path == self.target and not triggered:
                triggered = True
                raise OSError("injected directory fsync failure")
            _fsync_directory(path)

        return fail_once

    def test_initial_install_fsync_failure_removes_new_target(self) -> None:
        source = write_skill(self.sources, "local-skill")
        with mock.patch(
            "skill_lifecycle._fsync_directory",
            side_effect=self._fail_first_target_root_fsync(),
        ):
            with self.assertRaisesRegex(OSError, "injected directory fsync failure"):
                install(source, self.target, "user", None)

        self.assertFalse((self.target / "local-skill").exists())
        self.assertEqual([], list(self.target.glob(".replaced.*")))

    def test_replacement_fsync_failure_restores_previous_package(self) -> None:
        original = write_skill(self.sources, "local-skill")
        install(original, self.target, "user", None)
        previous = (self.target / "local-skill" / "SKILL.md").read_bytes()
        replacement = write_skill(
            self.root / "replacement-failure",
            "local-skill",
            "name: local-skill\ndescription: replacement instructions",
        )

        with mock.patch(
            "skill_lifecycle._fsync_directory",
            side_effect=self._fail_first_target_root_fsync(),
        ):
            with self.assertRaisesRegex(OSError, "injected directory fsync failure"):
                install(replacement, self.target, "user", None, replace=True)

        self.assertEqual(
            previous, (self.target / "local-skill" / "SKILL.md").read_bytes()
        )
        self.assertEqual([], list(self.target.glob(".replaced.*")))

    def test_uninstall_fsync_failure_restores_package(self) -> None:
        source = write_skill(self.sources, "local-skill")
        install(source, self.target, "user", None)

        with mock.patch(
            "skill_lifecycle._fsync_directory",
            side_effect=self._fail_first_target_root_fsync(),
        ):
            with self.assertRaisesRegex(OSError, "injected directory fsync failure"):
                uninstall("local-skill", self.target, "user", False)

        self.assertTrue((self.target / "local-skill" / "SKILL.md").is_file())
        self.assertEqual([], list(self.target.glob(".removed.*")))

    def test_uninstall_cleanup_failure_reports_committed_removal(self) -> None:
        source = write_skill(self.sources, "local-skill")
        install(source, self.target, "user", None)

        with mock.patch(
            "skill_lifecycle.shutil.rmtree",
            side_effect=OSError("injected cleanup failure"),
        ):
            result = uninstall("local-skill", self.target, "user", False)

        self.assertEqual("uninstalled", result["status"])
        self.assertEqual("uninstall_cleanup_pending", result["warning"])
        self.assertEqual(1, len(result["cleanup_pending"]))
        self.assertFalse((self.target / "local-skill").exists())
        self.assertTrue(Path(result["cleanup_pending"][0]).is_dir())


class InputSchemaSubsetTest(unittest.TestCase):
    """`input_schema` is a closed JSON Schema subset, enforced at load time.

    A parameter form is a convenience over the JSON textbox. Anything outside
    the subset must be rejected here rather than reaching the signed Remote
    contract chain or the console, which would then render it half-supported.
    """

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _load(self, schema: object) -> dict:
        package = write_skill(self.root, "probe")
        (package / "scripts").mkdir()
        (package / "scripts" / "probe.sh").write_text("#!/bin/sh\n", encoding="utf-8")
        extension = {
            "schema_version": 1,
            "package_version": "1.0.0",
            "core_api": 1,
            "category": "custom",
            "tools": [
                {
                    "name": "probe",
                    "description": "probe",
                    "entrypoint": "scripts/probe.sh",
                    "risk": "low",
                    "approval_scope": "skill_readonly",
                    "execution": {"class": "runner", "capability": "", "dispatch": "always"},
                    "runtime_inputs": [],
                    "guards": [],
                    "input_schema": schema,
                }
            ],
            "components": {},
        }
        (package / "linux-agent.json").write_text(json.dumps(extension), encoding="utf-8")
        try:
            return load_package(package, "user")
        finally:
            for path in sorted(package.rglob("*"), reverse=True):
                path.unlink() if path.is_file() else path.rmdir()
            package.rmdir()

    def test_supported_subset_is_normalized(self) -> None:
        loaded = self._load(
            {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "title": "路径", "default": "/var"},
                    "top_n": {"type": "integer", "default": 10},
                    "ratio": {"type": "number"},
                    "verbose": {"type": "boolean", "default": False},
                    "tags": {"type": "array", "items": {"type": "string"}},
                    "mode": {"type": "string", "enum": ["fast", "full"], "default": "full"},
                },
                "required": ["path"],
            }
        )
        schema = loaded["tools"][0]["input_schema"]
        self.assertEqual("object", schema["type"])
        self.assertEqual(["path"], schema["required"])
        # additionalProperties defaults to closed rather than being dropped.
        self.assertFalse(schema["additionalProperties"])
        self.assertEqual({"type": "string"}, schema["properties"]["tags"]["items"])
        self.assertEqual(["fast", "full"], schema["properties"]["mode"]["enum"])
        self.assertEqual(10, schema["properties"]["top_n"]["default"])

    def test_tool_without_schema_stays_absent(self) -> None:
        package = write_skill(self.root, "plain")
        (package / "scripts").mkdir()
        (package / "scripts" / "probe.sh").write_text("#!/bin/sh\n", encoding="utf-8")
        extension = {
            "schema_version": 1,
            "package_version": "1.0.0",
            "core_api": 1,
            "category": "custom",
            "tools": [
                {
                    "name": "probe",
                    "description": "probe",
                    "entrypoint": "scripts/probe.sh",
                    "risk": "low",
                    "approval_scope": "skill_readonly",
                    "execution": {"class": "runner", "capability": "", "dispatch": "always"},
                    "runtime_inputs": [],
                    "guards": [],
                }
            ],
            "components": {},
        }
        (package / "linux-agent.json").write_text(json.dumps(extension), encoding="utf-8")
        loaded = load_package(package, "user")
        self.assertNotIn("input_schema", loaded["tools"][0])

    def test_out_of_subset_schemas_are_rejected(self) -> None:
        cases = {
            "root must be object": {"type": "array", "items": {"type": "string"}},
            "nested object": {"type": "object", "properties": {"a": {"type": "object"}}},
            "non-string array items": {
                "type": "object",
                "properties": {"a": {"type": "array", "items": {"type": "integer"}}},
            },
            "unknown property keyword": {
                "type": "object",
                "properties": {"a": {"type": "string", "pattern": "^x$"}},
            },
            "unknown root keyword": {
                "type": "object",
                "properties": {"a": {"type": "string"}},
                "$schema": "https://json-schema.org/draft/2020-12/schema",
            },
            "ref": {"type": "object", "properties": {"a": {"$ref": "#/definitions/x"}}},
            "enum type mismatch": {
                "type": "object",
                "properties": {"a": {"type": "string", "enum": [1, 2]}},
            },
            "enum on array": {
                "type": "object",
                "properties": {"a": {"type": "array", "items": {"type": "string"}, "enum": ["x"]}},
            },
            "default type mismatch": {
                "type": "object",
                "properties": {"a": {"type": "integer", "default": "3"}},
            },
            "default outside enum": {
                "type": "object",
                "properties": {"a": {"type": "string", "enum": ["x"], "default": "y"}},
            },
            "required names an undeclared property": {
                "type": "object",
                "properties": {"a": {"type": "string"}},
                "required": ["b"],
            },
            "empty properties": {"type": "object", "properties": {}},
            "invalid property name": {"type": "object", "properties": {"Bad-Name": {"type": "string"}}},
            "too many properties": {
                "type": "object",
                "properties": {f"p{index}": {"type": "string"} for index in range(25)},
            },
            "oversized": {
                "type": "object",
                "properties": {"a": {"type": "string", "description": "x" * 9000}},
            },
            "not an object": ["nope"],
        }
        for label, schema in cases.items():
            with self.subTest(label):
                with self.assertRaises(SkillPackageError):
                    self._load(schema)

    def test_boolean_is_not_accepted_as_an_integer_default(self) -> None:
        with self.assertRaises(SkillPackageError):
            self._load({"type": "object", "properties": {"a": {"type": "integer", "default": True}}})


if __name__ == "__main__":
    unittest.main()
