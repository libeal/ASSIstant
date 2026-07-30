#!/usr/bin/env python3
"""Build and verify the repository's offline MCP Python SDK wheelhouse."""

from __future__ import annotations

import argparse
import email.parser
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request
import zipfile
from collections import defaultdict
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
WHEELHOUSE = ROOT / "third_party" / "mcp-python-sdk"
PYTHON_TARGETS = ("310", "311", "312", "313", "314")
PLATFORMS = {
    "manylinux-x86_64": "manylinux2014_x86_64",
    "manylinux-aarch64": "manylinux2014_aarch64",
}
PINNED_RPDS = {
    "310": "0.30.0",
    "311": "0.30.0",
    "312": "0.30.0",
    "313": "0.30.0",
    "314": "2026.6.3",
}
PACKAGE_NAME_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
VERSION_PATTERN = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:[A-Za-z0-9.-]*)?$")


class WheelhouseError(RuntimeError):
    pass


def canonical_name(value: str) -> str:
    return re.sub(r"[-_.]+", "-", value).lower()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def fetch_json(url: str) -> dict[str, Any]:
    request = urllib.request.Request(
        url,
        headers={"Accept": "application/json", "User-Agent": "linux-agent-wheelhouse/1"},
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        if response.status != 200:
            raise WheelhouseError(f"metadata request failed with HTTP {response.status}: {url}")
        payload = json.load(response)
    if not isinstance(payload, dict):
        raise WheelhouseError(f"metadata response is not an object: {url}")
    return payload


def wheel_metadata(path: Path) -> tuple[str, str, email.message.Message]:
    with zipfile.ZipFile(path) as archive:
        names = [name for name in archive.namelist() if name.endswith(".dist-info/METADATA")]
        if len(names) != 1:
            raise WheelhouseError(f"wheel must contain exactly one METADATA file: {path.name}")
        raw = archive.read(names[0]).decode("utf-8")
    metadata = email.parser.Parser().parsestr(raw)
    name = metadata.get("Name", "")
    version = metadata.get("Version", "")
    if not PACKAGE_NAME_PATTERN.fullmatch(name) or not version:
        raise WheelhouseError(f"wheel has invalid package metadata: {path.name}")
    return name, version, metadata


def pypi_release(name: str, version: str, cache: dict[tuple[str, str], dict[str, Any]]) -> dict[str, Any]:
    key = (canonical_name(name), version)
    if key not in cache:
        encoded_name = urllib.parse.quote(name, safe="")
        encoded_version = urllib.parse.quote(version, safe="")
        cache[key] = fetch_json(f"https://pypi.org/pypi/{encoded_name}/{encoded_version}/json")
    return cache[key]


def verify_pypi_digest(
    path: Path,
    name: str,
    version: str,
    cache: dict[tuple[str, str], dict[str, Any]],
) -> str:
    release = pypi_release(name, version, cache)
    candidates = release.get("urls")
    if not isinstance(candidates, list):
        raise WheelhouseError(f"PyPI release has no files: {name}=={version}")
    expected = None
    for candidate in candidates:
        if isinstance(candidate, dict) and candidate.get("filename") == path.name:
            digests = candidate.get("digests")
            if isinstance(digests, dict):
                expected = digests.get("sha256")
            break
    if not isinstance(expected, str) or not re.fullmatch(r"[0-9a-f]{64}", expected):
        raise WheelhouseError(f"wheel is not present in PyPI release metadata: {path.name}")
    actual = sha256_file(path)
    if actual != expected:
        raise WheelhouseError(f"PyPI SHA-256 mismatch for {path.name}")
    return actual


def run_pip_download(destination: Path, version: str, platform: str, python_target: str) -> None:
    command = [
        sys.executable,
        "-m",
        "pip",
        "download",
        "--disable-pip-version-check",
        "--only-binary=:all:",
        "--platform",
        platform,
        "--implementation",
        "cp",
        "--python-version",
        python_target,
        "--abi",
        f"cp{python_target}",
        "--dest",
        os.fspath(destination),
        f"mcp=={version}",
        f"mcp-types=={version}",
        f"rpds-py=={PINNED_RPDS[python_target]}",
    ]
    subprocess.run(command, check=True)


def copy_verified_wheels(stage: Path, downloads: Path, version: str) -> dict[str, dict[str, set[str]]]:
    package_wheels: dict[str, dict[str, set[str]]] = defaultdict(lambda: defaultdict(set))
    metadata_cache: dict[tuple[str, str], dict[str, Any]] = {}
    seen_files: dict[str, str] = {}

    for destination_name, platform in PLATFORMS.items():
        for python_target in PYTHON_TARGETS:
            target = downloads / destination_name / python_target
            target.mkdir(parents=True)
            run_pip_download(target, version, platform, python_target)
            for wheel in sorted(target.glob("*.whl")):
                name, wheel_version, _ = wheel_metadata(wheel)
                digest = verify_pypi_digest(wheel, name, wheel_version, metadata_cache)
                prior_digest = seen_files.get(wheel.name)
                if prior_digest is not None and prior_digest != digest:
                    raise WheelhouseError(f"same wheel filename has different content: {wheel.name}")
                seen_files[wheel.name] = digest
                output_dir = stage / "wheels" / (
                    "common" if wheel.name.endswith("-py3-none-any.whl") else destination_name
                )
                output_dir.mkdir(parents=True, exist_ok=True)
                output = output_dir / wheel.name
                if not output.exists():
                    shutil.copyfile(wheel, output)
                package_wheels[canonical_name(name)][wheel_version].add(digest)

    for required in ("mcp", "mcp-types"):
        versions = package_wheels.get(required, {})
        if set(versions) != {version}:
            raise WheelhouseError(f"wheelhouse did not resolve {required}=={version}")
    conflicts = {
        name: sorted(versions)
        for name, versions in package_wheels.items()
        if len(versions) != 1 and name != "rpds-py"
    }
    if conflicts:
        raise WheelhouseError(f"dependency versions differ across targets: {conflicts}")
    return package_wheels


def write_requirements_lock(stage: Path, packages: dict[str, dict[str, set[str]]]) -> None:
    lines = [
        "# Generated by scripts/update-mcp-wheelhouse.py; do not edit.",
        "# Install with --no-index --require-hashes and the selected wheel directories.",
    ]
    for name in sorted(packages):
        versions = packages[name]
        for version in sorted(versions):
            marker = ""
            if name == "rpds-py":
                marker = (
                    '; python_version < "3.14"'
                    if version == "0.30.0"
                    else '; python_version >= "3.14"'
                )
            hashes = sorted(versions[version])
            lines.append(f"{name}=={version}{marker} \\")
            for index, digest in enumerate(hashes):
                suffix = " \\" if index < len(hashes) - 1 else ""
                lines.append(f"    --hash=sha256:{digest}{suffix}")
    (stage / "requirements.lock").write_text("\n".join(lines) + "\n", encoding="utf-8")


def extract_licenses(stage: Path) -> None:
    licenses_root = stage / "LICENSES"
    licenses_root.mkdir()
    index: list[dict[str, Any]] = []
    seen: set[tuple[str, str]] = set()
    for wheel in sorted((stage / "wheels").glob("*/*.whl")):
        name, version, metadata = wheel_metadata(wheel)
        key = (canonical_name(name), version)
        if key in seen:
            continue
        seen.add(key)
        package_dir = licenses_root / f"{key[0]}-{version}"
        package_dir.mkdir()
        extracted: list[str] = []
        with zipfile.ZipFile(wheel) as archive:
            for member in sorted(archive.namelist()):
                parts = Path(member).parts
                if ".dist-info" not in member or not any(
                    part.lower().startswith(("license", "copying", "notice")) for part in parts
                ):
                    continue
                if member.endswith("/"):
                    continue
                target_name = Path(member).name
                if not target_name or target_name in extracted:
                    continue
                data = archive.read(member)
                (package_dir / target_name).write_bytes(data)
                extracted.append(target_name)
        summary = {
            "name": name,
            "version": version,
            "license_expression": metadata.get("License-Expression") or metadata.get("License") or "NOASSERTION",
            "license_files": extracted,
            "source_wheel": wheel.name,
        }
        (package_dir / "METADATA.json").write_text(
            json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        index.append(summary)
    (licenses_root / "INDEX.json").write_text(
        json.dumps(index, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def write_upstream(stage: Path, version: str) -> None:
    tag = fetch_json(
        f"https://api.github.com/repos/modelcontextprotocol/python-sdk/git/ref/tags/v{urllib.parse.quote(version)}"
    )
    tag_object = tag.get("object")
    commit = tag_object.get("sha") if isinstance(tag_object, dict) else None
    if not isinstance(commit, str) or not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise WheelhouseError("upstream tag did not resolve to a commit")
    package_files: dict[str, Any] = {}
    for package in ("mcp", "mcp-types"):
        release = fetch_json(f"https://pypi.org/pypi/{package}/{version}/json")
        files = []
        for item in release.get("urls", []):
            if not isinstance(item, dict) or item.get("packagetype") != "bdist_wheel":
                continue
            digest = item.get("digests", {}).get("sha256")
            if isinstance(digest, str):
                files.append({"filename": item.get("filename"), "sha256": digest})
        package_files[package] = {"version": version, "wheels": files}
    payload = {
        "repository": "https://github.com/modelcontextprotocol/python-sdk",
        "tag": f"v{version}",
        "commit": commit,
        "protocol_version": "2026-07-28",
        "python": {"minimum": "3.10", "maximum_tested": "3.14"},
        "platforms": sorted(PLATFORMS),
        "packages": package_files,
    }
    (stage / "UPSTREAM.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def write_checksums(stage: Path) -> None:
    lines = []
    for path in sorted(stage.rglob("*")):
        if not path.is_file() or path.name == "SHA256SUMS":
            continue
        lines.append(f"{sha256_file(path)}  {path.relative_to(stage).as_posix()}")
    (stage / "SHA256SUMS").write_text("\n".join(lines) + "\n", encoding="utf-8")


def check_wheelhouse(root: Path = WHEELHOUSE) -> dict[str, Any]:
    required = ["VERSION", "UPSTREAM.json", "requirements.lock", "SHA256SUMS", "LICENSES", "wheels"]
    missing = [name for name in required if not (root / name).exists()]
    if missing:
        raise WheelhouseError(f"wheelhouse is incomplete: {missing}")
    version = (root / "VERSION").read_text(encoding="utf-8").strip()
    if not VERSION_PATTERN.fullmatch(version):
        raise WheelhouseError("wheelhouse VERSION is invalid")
    expected_paths: set[str] = set()
    for line in (root / "SHA256SUMS").read_text(encoding="utf-8").splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  (.+)", line)
        if match is None:
            raise WheelhouseError("SHA256SUMS contains an invalid line")
        digest, relative = match.groups()
        path = root / relative
        if not path.is_file() or path.is_symlink() or sha256_file(path) != digest:
            raise WheelhouseError(f"wheelhouse checksum failed: {relative}")
        expected_paths.add(relative)
    actual_paths = {
        path.relative_to(root).as_posix()
        for path in root.rglob("*")
        if path.is_file() and path.name != "SHA256SUMS"
    }
    if actual_paths != expected_paths:
        raise WheelhouseError("SHA256SUMS does not cover the complete wheelhouse")
    wheels = sorted((root / "wheels").glob("*/*.whl"))
    if not wheels:
        raise WheelhouseError("wheelhouse contains no wheels")
    packages = {canonical_name(wheel_metadata(path)[0]) for path in wheels}
    if not {"mcp", "mcp-types"}.issubset(packages):
        raise WheelhouseError("wheelhouse is missing the MCP SDK packages")
    return {"ok": True, "version": version, "wheel_count": len(wheels), "package_count": len(packages)}


def replace_wheelhouse(stage: Path) -> None:
    WHEELHOUSE.parent.mkdir(parents=True, exist_ok=True)
    backup = WHEELHOUSE.with_name(WHEELHOUSE.name + ".previous")
    if backup.exists():
        shutil.rmtree(backup)
    if WHEELHOUSE.exists():
        WHEELHOUSE.rename(backup)
    try:
        stage.rename(WHEELHOUSE)
    except Exception:
        if backup.exists() and not WHEELHOUSE.exists():
            backup.rename(WHEELHOUSE)
        raise
    if backup.exists():
        shutil.rmtree(backup)


def update(version: str) -> dict[str, Any]:
    if not VERSION_PATTERN.fullmatch(version):
        raise WheelhouseError("version must be an exact release version")
    work_root = Path(tempfile.mkdtemp(prefix="mcp-wheelhouse-", dir=WHEELHOUSE.parent))
    stage = work_root / WHEELHOUSE.name
    downloads = work_root / "downloads"
    stage.mkdir()
    try:
        packages = copy_verified_wheels(stage, downloads, version)
        (stage / "VERSION").write_text(version + "\n", encoding="utf-8")
        write_requirements_lock(stage, packages)
        write_upstream(stage, version)
        extract_licenses(stage)
        write_checksums(stage)
        result = check_wheelhouse(stage)
        replace_wheelhouse(stage)
        return result
    finally:
        shutil.rmtree(work_root, ignore_errors=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    update_parser = subparsers.add_parser("update")
    update_parser.add_argument("version")
    subparsers.add_parser("check")
    args = parser.parse_args()
    try:
        result = update(args.version) if args.command == "update" else check_wheelhouse()
    except (OSError, subprocess.CalledProcessError, WheelhouseError, zipfile.BadZipFile) as exc:
        print(json.dumps({"ok": False, "error": str(exc)}, separators=(",", ":")))
        return 1
    print(json.dumps(result, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
