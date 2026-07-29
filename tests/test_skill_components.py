from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, os.fspath(ROOT / "lib"))

from skill_component_ledger import LedgerError, load, mark_uninstalled, upsert  # noqa: E402
from skill_component_runtime import install_components, uninstall_components  # noqa: E402


class SkillComponentLedgerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.ledger = self.root / "data" / "skill-components.json"
        self.ledger.parent.mkdir()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _record(self, owned_path: Path) -> dict[str, object]:
        return {
            "installed": True,
            "contract_digest": "a" * 64,
            "units": [],
            "unit_files": [],
            "host_policy_files": [],
            "owned_paths": [
                {
                    "kind": "directory",
                    "path": os.fspath(owned_path),
                    "default": "/etc/linux-agent/database-profiles.d",
                }
            ],
        }

    def test_purge_removes_only_the_exact_owned_directory(self) -> None:
        owned = self.root / "managed" / "database-profiles.d"
        owned.mkdir(parents=True)
        (owned / "profile.json").write_text("{}\n", encoding="utf-8")
        sibling = owned.parent / "preserved"
        sibling.write_text("keep\n", encoding="utf-8")
        upsert(self.ledger, "sample", json.dumps(self._record(owned)))

        record, purged, cleanup_pending = mark_uninstalled(
            self.ledger, "sample", purge=True
        )

        self.assertEqual([os.fspath(owned)], purged)
        self.assertEqual([], cleanup_pending)
        self.assertFalse(owned.exists())
        self.assertEqual("keep\n", sibling.read_text(encoding="utf-8"))
        self.assertFalse(record["installed"])
        self.assertEqual([], record["owned_paths"])

    def test_purge_rejects_a_symlinked_path_component(self) -> None:
        outside = self.root / "outside" / "database-profiles.d"
        outside.mkdir(parents=True)
        parent = self.root / "managed"
        parent.mkdir()
        (parent / "link").symlink_to(outside.parent, target_is_directory=True)
        target = parent / "link" / "database-profiles.d"
        upsert(self.ledger, "sample", json.dumps(self._record(target)))

        with self.assertRaisesRegex(LedgerError, "symbolic link"):
            mark_uninstalled(self.ledger, "sample", purge=True)

        self.assertTrue(outside.is_dir())
        self.assertTrue(load(self.ledger)["skills"]["sample"]["installed"])

    def test_purge_ledger_failure_restores_owned_directory(self) -> None:
        owned = self.root / "managed" / "database-profiles.d"
        owned.mkdir(parents=True)
        (owned / "profile.json").write_text("{}\n", encoding="utf-8")
        upsert(self.ledger, "sample", json.dumps(self._record(owned)))
        previous_ledger = self.ledger.read_bytes()

        with mock.patch(
            "skill_component_ledger._write",
            side_effect=LedgerError("injected ledger failure"),
        ):
            with self.assertRaisesRegex(LedgerError, "injected ledger failure"):
                mark_uninstalled(self.ledger, "sample", purge=True)

        self.assertEqual("{}\n", (owned / "profile.json").read_text(encoding="utf-8"))
        self.assertEqual(previous_ledger, self.ledger.read_bytes())
        self.assertEqual([], list(owned.parent.glob(".*.purge-*")))

    def test_purge_cleanup_failure_is_reported_after_commit(self) -> None:
        owned = self.root / "managed" / "database-profiles.d"
        owned.mkdir(parents=True)
        (owned / "profile.json").write_text("{}\n", encoding="utf-8")
        upsert(self.ledger, "sample", json.dumps(self._record(owned)))

        with mock.patch(
            "skill_component_ledger.shutil.rmtree",
            side_effect=OSError("injected cleanup failure"),
        ):
            record, purged, cleanup_pending = mark_uninstalled(
                self.ledger, "sample", purge=True
            )

        self.assertFalse(owned.exists())
        self.assertFalse(record["installed"])
        self.assertEqual([os.fspath(owned)], purged)
        self.assertEqual(1, len(cleanup_pending))
        pending = Path(cleanup_pending[0])
        self.assertTrue((pending / "profile.json").is_file())
        self.assertEqual([], load(self.ledger)["skills"]["sample"]["owned_paths"])


class SkillComponentRuntimeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.package = self.root / "sample-component"
        (self.package / "scripts").mkdir(parents=True)
        (self.package / "assets" / "systemd").mkdir(parents=True)
        (self.package / "SKILL.md").write_text(
            "---\nname: sample-component\ndescription: sample component\n---\n",
            encoding="utf-8",
        )
        (self.package / "scripts" / "client.py").write_text("pass\n", encoding="utf-8")
        service = "assets/systemd/linux-agent-sample-helper.service"
        socket = "assets/systemd/linux-agent-sample-helper.socket"
        (self.package / service).write_text(
            "[Service]\nUser=linux-agent-credential\nGroup=linux-agent-credential\n"
            "Environment=LINUX_AGENT_SERVICE_USER=linux-agent\n"
            "ExecStart=/usr/bin/python3 /opt/linux-agent/skills/sample-component/scripts/client.py\n",
            encoding="utf-8",
        )
        (self.package / socket).write_text(
            "[Socket]\nSocketUser=root\nSocketGroup=linux-agent\nSocketMode=0660\n",
            encoding="utf-8",
        )
        extension = {
            "schema_version": 1,
            "package_version": "1.0.0",
            "core_api": 1,
            "category": "sample",
            "tools": [],
            "components": {
                "credential_helper": {
                    "name": "sample-helper",
                    "client": "scripts/client.py",
                    "socket_env": "LINUX_AGENT_SAMPLE_SOCKET",
                    "default_socket": "/run/linux-agent/sample-helper.sock",
                    "service_asset": service,
                    "socket_asset": socket,
                    "owned_paths": [],
                }
            },
        }
        (self.package / "linux-agent.json").write_text(
            json.dumps(extension), encoding="utf-8"
        )
        self.prefix = self.root / "prefix"
        self.prefix.mkdir()
        self.unit_dir = self.root / "systemd"
        self.ledger = self.root / "data" / "skill-components.json"
        self.ledger.parent.mkdir()
        self.arguments = argparse.Namespace(
            package=os.fspath(self.package),
            name="sample-component",
            ledger=os.fspath(self.ledger),
            prefix=os.fspath(self.prefix),
            unit_dir=os.fspath(self.unit_dir),
            host_policy=os.fspath(self.root / "etc" / "host-policy.json"),
            web_user="web-user",
            web_group="web-group",
            credential_user="credential-user",
            credential_group="credential-group",
            systemd=True,
            purge=False,
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_install_and_uninstall_render_and_remove_declared_units(self) -> None:
        with mock.patch("skill_component_runtime._systemctl", return_value=False), mock.patch(
            "skill_component_runtime.shutil.which", return_value=None
        ):
            installed = install_components(self.arguments)

        service = self.unit_dir / "linux-agent-sample-helper.service"
        socket = self.unit_dir / "linux-agent-sample-helper.socket"
        self.assertTrue(installed["record"]["installed"])
        self.assertIn("User=credential-user\n", service.read_text(encoding="utf-8"))
        self.assertIn("SocketGroup=web-group\n", socket.read_text(encoding="utf-8"))

        with mock.patch("skill_component_runtime._systemctl", return_value=False):
            removed = uninstall_components(self.arguments)

        self.assertFalse(service.exists())
        self.assertFalse(socket.exists())
        self.assertFalse(removed["record"]["installed"])

    def test_uninstall_defers_web_restart_until_package_removal(self) -> None:
        with mock.patch("skill_component_runtime._systemctl", return_value=False), mock.patch(
            "skill_component_runtime.shutil.which", return_value=None
        ):
            install_components(self.arguments)

        calls: list[tuple[str, ...]] = []

        def fake_systemctl(*arguments: str, required: bool = True) -> bool:
            del required
            calls.append(arguments)
            return arguments == (
                "is-active",
                "--quiet",
                "linux-agent-web.service",
            )

        with mock.patch("skill_component_runtime._systemctl", side_effect=fake_systemctl):
            removed = uninstall_components(self.arguments)

        self.assertTrue(removed["web_restart_required"])
        self.assertNotIn(("try-restart", "linux-agent-web.service"), calls)

    def test_failed_initial_install_removes_files_and_ledger(self) -> None:
        with mock.patch("skill_component_runtime._systemctl", return_value=False), mock.patch(
            "skill_component_runtime.shutil.which", return_value=None
        ), mock.patch(
            "skill_component_runtime.upsert",
            side_effect=LedgerError("injected ledger failure"),
        ):
            with self.assertRaisesRegex(LedgerError, "injected ledger failure"):
                install_components(self.arguments)

        self.assertFalse(
            (self.unit_dir / "linux-agent-sample-helper.service").exists()
        )
        self.assertFalse(
            (self.unit_dir / "linux-agent-sample-helper.socket").exists()
        )
        self.assertFalse(self.ledger.exists())

    def test_failed_upgrade_restores_previous_files_and_ledger(self) -> None:
        with mock.patch("skill_component_runtime._systemctl", return_value=False), mock.patch(
            "skill_component_runtime.shutil.which", return_value=None
        ):
            install_components(self.arguments)

        service = self.unit_dir / "linux-agent-sample-helper.service"
        socket = self.unit_dir / "linux-agent-sample-helper.socket"
        previous_service = service.read_bytes()
        previous_socket = socket.read_bytes()
        previous_ledger = self.ledger.read_bytes()
        source_service = self.package / "assets/systemd/linux-agent-sample-helper.service"
        source_service.write_text(
            source_service.read_text(encoding="utf-8") + "Environment=CHANGED=yes\n",
            encoding="utf-8",
        )

        with mock.patch("skill_component_runtime._systemctl", return_value=False), mock.patch(
            "skill_component_runtime.shutil.which", return_value=None
        ), mock.patch(
            "skill_component_runtime.upsert",
            side_effect=LedgerError("injected ledger failure"),
        ):
            with self.assertRaisesRegex(LedgerError, "injected ledger failure"):
                install_components(self.arguments)

        self.assertEqual(previous_service, service.read_bytes())
        self.assertEqual(previous_socket, socket.read_bytes())
        self.assertEqual(previous_ledger, self.ledger.read_bytes())

    def test_failed_uninstall_restores_files_and_ledger(self) -> None:
        with mock.patch("skill_component_runtime._systemctl", return_value=False), mock.patch(
            "skill_component_runtime.shutil.which", return_value=None
        ):
            install_components(self.arguments)

        service = self.unit_dir / "linux-agent-sample-helper.service"
        socket = self.unit_dir / "linux-agent-sample-helper.socket"
        previous_service = service.read_bytes()
        previous_socket = socket.read_bytes()
        previous_ledger = self.ledger.read_bytes()

        with mock.patch("skill_component_runtime._systemctl", return_value=False), mock.patch(
            "skill_component_runtime.mark_uninstalled",
            side_effect=LedgerError("injected ledger failure"),
        ):
            with self.assertRaisesRegex(LedgerError, "injected ledger failure"):
                uninstall_components(self.arguments)

        self.assertEqual(previous_service, service.read_bytes())
        self.assertEqual(previous_socket, socket.read_bytes())
        self.assertEqual(previous_ledger, self.ledger.read_bytes())


if __name__ == "__main__":
    unittest.main()
