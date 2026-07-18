#!/usr/bin/env python3
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))

from subprocess_env import apply_manifest_env, build_subprocess_env  # noqa: E402


class SubprocessEnvTests(unittest.TestCase):
    def test_strips_ambient_credentials(self):
        parent = {
            "PATH": "/usr/bin",
            "HOME": "/home/agent",
            "AWS_SECRET_ACCESS_KEY": "aws-secret",
            "GITHUB_TOKEN": "gh-secret",
            "LINUX_AGENT_API_KEY": "ai-secret",
            "LINUX_AGENT_CONFIG_JSON": '{"api_key":"config-secret"}',
            "LINUX_AGENT_ROOT": "/opt/linux-agent",
            "LINUX_AGENT_REMOTE_MANIFEST": "/opt/linux-agent/remote/release-manifest.json",
            "LINUX_AGENT_REMOTE_RELEASE_BASE": "https://releases.example/v1",
            "LINUX_AGENT_REMOTE_PREFLIGHT": '{"ok":true}',
            "LINUX_AGENT_OBSERVER_HELPER_SOCKET": "/run/linux-agent/custom.sock",
            "LINUX_AGENT_AUDIT_WRITER_KEY": "writer-secret",
            "OPENAI_API_KEY": "openai-secret",
            "SSH_AUTH_SOCK": "/tmp/agent.sock",
            "DBUS_SESSION_BUS_ADDRESS": "unix:path=/tmp/bus",
            "MY_CUSTOM": "keep-out",
        }
        env = build_subprocess_env(parent, include_api_key=False)
        self.assertEqual(env["PATH"], "/usr/bin")
        self.assertEqual(env["LINUX_AGENT_ROOT"], "/opt/linux-agent")
        self.assertEqual(
            env["LINUX_AGENT_REMOTE_MANIFEST"],
            "/opt/linux-agent/remote/release-manifest.json",
        )
        self.assertEqual(
            env["LINUX_AGENT_REMOTE_RELEASE_BASE"],
            "https://releases.example/v1",
        )
        self.assertEqual(
            env["LINUX_AGENT_OBSERVER_HELPER_SOCKET"],
            "/run/linux-agent/custom.sock",
        )
        self.assertNotIn("AWS_SECRET_ACCESS_KEY", env)
        self.assertNotIn("GITHUB_TOKEN", env)
        self.assertNotIn("LINUX_AGENT_API_KEY", env)
        self.assertNotIn("LINUX_AGENT_CONFIG_JSON", env)
        self.assertNotIn("LINUX_AGENT_AUDIT_WRITER_KEY", env)
        self.assertNotIn("OPENAI_API_KEY", env)
        self.assertNotIn("SSH_AUTH_SOCK", env)
        self.assertNotIn("DBUS_SESSION_BUS_ADDRESS", env)
        self.assertNotIn("MY_CUSTOM", env)

    def test_optional_api_key_injection(self):
        parent = {"PATH": "/bin", "LINUX_AGENT_API_KEY": "ai-secret"}
        env = build_subprocess_env(parent, include_api_key=True)
        self.assertEqual(env["LINUX_AGENT_API_KEY"], "ai-secret")

    def test_manifest_env_is_explicit_but_cannot_replace_agent_secrets(self):
        env = {"PATH": "/bin"}
        apply_manifest_env(
            env,
            {
                "MCP_ACCESS_TOKEN": "mcp-owned-secret",
                "LINUX_AGENT_API_KEY": "must-not-pass",
                "LINUX_AGENT_CONFIG_JSON": "must-not-pass",
                "BAD=NAME": "must-not-pass",
                "BAD NAME": "must-not-pass",
            },
        )
        self.assertEqual(env["MCP_ACCESS_TOKEN"], "mcp-owned-secret")
        self.assertNotIn("LINUX_AGENT_API_KEY", env)
        self.assertNotIn("LINUX_AGENT_CONFIG_JSON", env)
        self.assertNotIn("BAD=NAME", env)
        self.assertNotIn("BAD NAME", env)


if __name__ == "__main__":
    unittest.main()
