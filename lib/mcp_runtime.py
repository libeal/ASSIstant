#!/usr/bin/env python3
"""Provision and inspect the isolated offline runtime used by the MCP adapter."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import venv
from pathlib import Path
from typing import Any


SUPPORTED_ARCHITECTURES = {
    "x86_64": "manylinux-x86_64",
    "amd64": "manylinux-x86_64",
    "aarch64": "manylinux-aarch64",
    "arm64": "manylinux-aarch64",
}
SUPPORTED_PYTHON = {(3, minor) for minor in range(10, 15)}
CHECKSUM_PATTERN = re.compile(r"([0-9a-f]{64})  ([A-Za-z0-9_./+-]+)")


class McpRuntimeError(RuntimeError):
    """The offline MCP SDK runtime is unavailable or invalid."""


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def project_root() -> Path:
    configured = os.environ.get("LINUX_AGENT_ROOT")
    return Path(configured).resolve() if configured else Path(__file__).resolve().parents[1]


def wheelhouse_root() -> Path:
    configured = os.environ.get("LINUX_AGENT_MCP_SDK_ROOT")
    return (
        Path(configured).resolve()
        if configured
        else project_root() / "third_party" / "mcp-python-sdk"
    )


def platform_details() -> tuple[str, str, str]:
    if sys.platform != "linux":
        raise McpRuntimeError("MCP SDK runtime supports glibc Linux only")
    libc_name, libc_version = platform.libc_ver()
    if libc_name.lower() != "glibc":
        raise McpRuntimeError("MCP SDK runtime requires glibc Linux")
    python_version = sys.version_info[:2]
    if python_version not in SUPPORTED_PYTHON:
        raise McpRuntimeError("MCP SDK runtime supports CPython 3.10 through 3.14")
    machine = platform.machine().lower()
    wheel_directory = SUPPORTED_ARCHITECTURES.get(machine)
    if wheel_directory is None:
        raise McpRuntimeError(f"MCP SDK runtime does not support architecture: {machine}")
    return machine, wheel_directory, libc_version


def validate_wheelhouse(root: Path) -> dict[str, Any]:
    if not root.is_dir() or root.is_symlink():
        raise McpRuntimeError(f"MCP SDK wheelhouse is unavailable: {root}")
    required_files = ("VERSION", "UPSTREAM.json", "requirements.lock", "SHA256SUMS")
    for name in required_files:
        path = root / name
        if not path.is_file() or path.is_symlink():
            raise McpRuntimeError(f"MCP SDK wheelhouse is missing {name}")
    expected: set[str] = set()
    for line in (root / "SHA256SUMS").read_text(encoding="utf-8").splitlines():
        match = CHECKSUM_PATTERN.fullmatch(line)
        if match is None:
            raise McpRuntimeError("MCP SDK SHA256SUMS contains an invalid line")
        digest, relative = match.groups()
        candidate = (root / relative).resolve()
        try:
            candidate.relative_to(root.resolve())
        except ValueError as exc:
            raise McpRuntimeError("MCP SDK checksum path escapes the wheelhouse") from exc
        if not candidate.is_file() or candidate.is_symlink():
            raise McpRuntimeError(f"MCP SDK checksum target is invalid: {relative}")
        if sha256_file(candidate) != digest:
            raise McpRuntimeError(f"MCP SDK checksum mismatch: {relative}")
        expected.add(relative)
    actual = {
        path.relative_to(root).as_posix()
        for path in root.rglob("*")
        if path.is_file() and path.name != "SHA256SUMS"
    }
    if actual != expected:
        raise McpRuntimeError("MCP SDK SHA256SUMS does not cover the complete wheelhouse")
    version = (root / "VERSION").read_text(encoding="utf-8").strip()
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise McpRuntimeError("MCP SDK VERSION is invalid")
    return {
        "version": version,
        "requirements_sha256": sha256_file(root / "requirements.lock"),
    }


def runtime_identity(wheelhouse: dict[str, Any], machine: str) -> str:
    digest = str(wheelhouse["requirements_sha256"])[:16]
    python_tag = f"cp{sys.version_info.major}{sys.version_info.minor}"
    return f"{wheelhouse['version']}-{python_tag}-{machine}-{digest}"


def runtime_root(identity: str) -> Path:
    configured = os.environ.get("LINUX_AGENT_MCP_VENV")
    if configured:
        return Path(configured).resolve()
    root = project_root()
    # Managed and Remote releases are immutable runtime units. Keeping the
    # venv inside that verified unit makes current upgrades and rollbacks
    # switch code, wheelhouse and Python dependencies atomically.
    if os.environ.get("LINUX_AGENT_REMOTE_MODE") == "1":
        return root / ".mcp-venv"
    releases_root = root.parent
    install_prefix = releases_root.parent
    if releases_root.name == "releases" and (install_prefix / "data").is_dir():
        return root / ".mcp-venv"
    # Source checkouts use one stable ignored cache. Never use the per-session
    # LINUX_AGENT_TMP_DIR: Web jobs rotate that directory after every request.
    temporary_root = os.environ.get("LINUX_AGENT_TMP_ROOT")
    base = Path(temporary_root).resolve() if temporary_root else root / "tmp"
    return base / ".shared" / "mcp-venvs" / identity


def marker_payload(identity: str, wheelhouse: dict[str, Any], machine: str) -> dict[str, Any]:
    return {
        "identity": identity,
        "sdk_version": wheelhouse["version"],
        "requirements_sha256": wheelhouse["requirements_sha256"],
        "python": f"{sys.version_info.major}.{sys.version_info.minor}",
        "architecture": machine,
    }


def read_marker(venv_root: Path) -> dict[str, Any] | None:
    marker = venv_root / ".mcp-runtime.json"
    if not marker.is_file() or marker.is_symlink():
        return None
    try:
        payload = json.loads(marker.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    return payload if isinstance(payload, dict) else None


def runtime_python(venv_root: Path) -> Path:
    return venv_root / "bin" / "python"


def runtime_is_ready(venv_root: Path, expected: dict[str, Any]) -> bool:
    python = runtime_python(venv_root)
    if not python.is_file() or python.is_symlink() or read_marker(venv_root) != expected:
        return False
    probe = subprocess.run(
        [
            os.fspath(python),
            "-c",
            (
                "from importlib.metadata import version;"
                "assert version('mcp') == '2.0.0';"
                "assert version('mcp-types') == '2.0.0'"
            ),
        ],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
        timeout=15,
    )
    return probe.returncode == 0


def install_runtime(
    venv_root: Path,
    wheelhouse_root_path: Path,
    wheel_directory: str,
    expected: dict[str, Any],
) -> None:
    parent = venv_root.parent
    parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(parent, 0o700)
    staging = Path(tempfile.mkdtemp(prefix=f".{venv_root.name}.", dir=parent))
    try:
        venv.EnvBuilder(with_pip=True, clear=True, symlinks=False).create(staging)
        python = runtime_python(staging)
        environment = {
            "PATH": os.environ.get("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"),
            "HOME": os.environ.get("HOME", "/nonexistent"),
            "LANG": os.environ.get("LANG", "C.UTF-8"),
            "LC_ALL": os.environ.get("LC_ALL", "C.UTF-8"),
            "PIP_DISABLE_PIP_VERSION_CHECK": "1",
            "PIP_NO_INDEX": "1",
            "PIP_REQUIRE_VIRTUALENV": "1",
        }
        command = [
            os.fspath(python),
            "-m",
            "pip",
            "install",
            "--no-index",
            "--require-hashes",
            "--find-links",
            os.fspath(wheelhouse_root_path / "wheels" / "common"),
            "--find-links",
            os.fspath(wheelhouse_root_path / "wheels" / wheel_directory),
            "--requirement",
            os.fspath(wheelhouse_root_path / "requirements.lock"),
        ]
        completed = subprocess.run(
            command,
            env=environment,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
            timeout=180,
        )
        if completed.returncode != 0:
            detail = completed.stdout[-2000:].strip()
            raise McpRuntimeError(f"offline MCP SDK installation failed: {detail}")
        marker = staging / ".mcp-runtime.json"
        marker.write_text(json.dumps(expected, sort_keys=True) + "\n", encoding="utf-8")
        # The marker contains only public build identity. Managed Runner users
        # must be able to verify a root-provisioned release venv.
        os.chmod(marker, 0o644)
        if not runtime_is_ready(staging, expected):
            raise McpRuntimeError("installed MCP SDK runtime failed its import probe")
        if venv_root.exists():
            shutil.rmtree(venv_root)
        staging.rename(venv_root)
    finally:
        if staging.exists():
            shutil.rmtree(staging, ignore_errors=True)


def runtime_status(ensure: bool = False) -> dict[str, Any]:
    machine, wheel_directory, libc_version = platform_details()
    wheelhouse_path = wheelhouse_root()
    wheelhouse = validate_wheelhouse(wheelhouse_path)
    identity = runtime_identity(wheelhouse, machine)
    venv_root = runtime_root(identity)
    expected = marker_payload(identity, wheelhouse, machine)
    if ensure and not runtime_is_ready(venv_root, expected):
        lock_path = venv_root.parent / f"{venv_root.name}.lock"
        lock_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        with lock_path.open("a+", encoding="utf-8") as lock:
            os.chmod(lock_path, 0o600)
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            if not runtime_is_ready(venv_root, expected):
                install_runtime(venv_root, wheelhouse_path, wheel_directory, expected)
    ready = runtime_is_ready(venv_root, expected)
    return {
        "ok": ready,
        "available": True,
        "runtime_ready": ready,
        "status": "ready" if ready else "not_installed",
        "sdk_version": wheelhouse["version"],
        "protocol_version": "2026-07-28",
        "python": f"{sys.version_info.major}.{sys.version_info.minor}",
        "architecture": machine,
        "wheel_directory": wheel_directory,
        "libc": f"glibc {libc_version}",
        "wheelhouse": os.fspath(wheelhouse_path),
        "venv": os.fspath(venv_root),
        "python_path": os.fspath(runtime_python(venv_root)) if ready else "",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("status", "ensure", "python"))
    args = parser.parse_args()
    try:
        result = runtime_status(ensure=args.command in {"ensure", "python"})
    except (McpRuntimeError, OSError, subprocess.SubprocessError) as exc:
        result = {
            "ok": False,
            "available": False,
            "runtime_ready": False,
            "status": "unavailable",
            "error": str(exc),
        }
    if args.command == "python" and result.get("ok"):
        print(result["python_path"])
    else:
        print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))
    return 0 if result.get("ok") else 1


if __name__ == "__main__":
    raise SystemExit(main())
