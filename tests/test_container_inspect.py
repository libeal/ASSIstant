import json
import sys
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "skills" / "container-inspect" / "scripts"))

import container_inspect  # noqa: E402


class ContainerInspectTests(unittest.TestCase):
    def test_multiple_runtimes_require_explicit_selection(self):
        with mock.patch.object(
            container_inspect,
            "_runtime_tools",
            return_value={"docker": "/usr/bin/docker", "podman": "/usr/bin/podman"},
        ):
            with self.assertRaisesRegex(container_inspect.ContainerInspectError, "select runtime"):
                container_inspect.container_list({})

    def test_inspect_uses_fixed_argv_and_redacts_sensitive_fields(self):
        payload = [
            {
                "Id": "abc",
                "Name": "/demo",
                "Config": {
                    "Image": "example:latest",
                    "Env": ["PUBLIC=yes", "PASSWORD=hidden"],
                    "Labels": {
                        "owner": "ops",
                        "api_token": "hidden",
                        "description": "password=hidden",
                    },
                },
                "State": {"Status": "running", "Pid": 42, "Error": "hidden"},
                "Mounts": [
                    {
                        "Type": "bind",
                        "Source": "/host/secret",
                        "Destination": "/run/secrets/database",
                        "RW": False,
                    }
                ],
            }
        ]
        with mock.patch.object(
            container_inspect, "_runtime_tools", return_value={"docker": "/usr/bin/docker"}
        ), mock.patch.object(
            container_inspect, "_run", return_value=json.dumps(payload)
        ) as run:
            result = container_inspect.container_inspect({"runtime": "docker", "id": "abc"})
        run.assert_called_once_with(["/usr/bin/docker", "inspect", "abc"])
        inspected = result["container"]
        self.assertEqual(inspected["environment_keys"], ["PUBLIC", "PASSWORD"])
        self.assertEqual(inspected["labels"]["api_token"], "[REDACTED]")
        self.assertEqual(inspected["labels"]["description"], "[REDACTED]")
        self.assertNotIn("Source", inspected["mounts"][0])
        self.assertEqual("[REDACTED]", inspected["mounts"][0]["destination"])
        self.assertNotIn("Error", inspected["state"])

    def test_stats_is_single_sample_and_bounded(self):
        rows = "\n".join(json.dumps({"ID": str(index)}) for index in range(3))
        with mock.patch.object(
            container_inspect, "_runtime_tools", return_value={"docker": "/usr/bin/docker"}
        ), mock.patch.object(container_inspect, "_run", return_value=rows) as run:
            result = container_inspect.resource_snapshot({"runtime": "docker", "limit": 2})
        run.assert_called_once_with(
            ["/usr/bin/docker", "stats", "--no-stream", "--format", "{{json .}}"]
        )
        self.assertEqual(result["sample_mode"], "single")
        self.assertEqual(result["count"], 2)
        self.assertTrue(result["truncated"])

    def test_container_list_redacts_docker_and_podman_command_lines(self):
        cases = (
            (
                "docker",
                json.dumps(
                    {
                        "ID": "abc",
                        "Image": "app:latest",
                        "Command": "run --token docker-secret",
                        "Names": "demo",
                    }
                ),
                "Command",
                "docker-secret",
            ),
            (
                "podman",
                json.dumps(
                    [
                        {
                            "Id": "def",
                            "Image": "app:latest",
                            "Args": ["run", "--password", "podman-secret"],
                        }
                    ]
                ),
                "Args",
                "podman-secret",
            ),
        )
        for runtime, output, field, secret in cases:
            with self.subTest(runtime=runtime), mock.patch.object(
                container_inspect,
                "_runtime_tools",
                return_value={runtime: f"/usr/bin/{runtime}"},
            ), mock.patch.object(container_inspect, "_run", return_value=output):
                result = container_inspect.container_list({"runtime": runtime})
            serialized = json.dumps(result, sort_keys=True)
            self.assertEqual("[REDACTED]", result["containers"][0][field])
            self.assertNotIn(secret, serialized)
            self.assertIn("app:latest", serialized)

    def test_custom_endpoint_and_unknown_fields_are_rejected(self):
        with self.assertRaisesRegex(container_inspect.ContainerInspectError, "unsupported fields"):
            container_inspect.container_list(
                {"runtime": "docker", "endpoint": "unix:///tmp/docker.sock"}
            )

    def test_json_parser_rejects_duplicates_and_non_finite_values(self):
        with self.assertRaisesRegex(container_inspect.ContainerInspectError, "duplicate"):
            container_inspect._object('{"runtime":"docker","runtime":"podman"}')
        with self.assertRaisesRegex(container_inspect.ContainerInspectError, "constant"):
            container_inspect._object('{"limit":NaN}')
        with self.assertRaises(container_inspect.ContainerInspectError) as context:
            container_inspect._json('{"value":Infinity}')
        self.assertEqual("invalid_output", context.exception.code)

    def test_runtime_discovery_rejects_group_writable_client(self):
        candidate = mock.Mock()
        candidate.stat.return_value = mock.Mock(
            st_mode=0o100775,
        )
        with mock.patch.object(
            container_inspect,
            "RUNTIME_PATHS",
            {"docker": ("/tmp/docker",)},
        ), mock.patch.object(container_inspect, "Path", return_value=candidate), mock.patch.object(
            container_inspect.os,
            "access",
            return_value=True,
        ):
            self.assertEqual({}, container_inspect._runtime_tools())


if __name__ == "__main__":
    unittest.main()
