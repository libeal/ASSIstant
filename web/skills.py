"""Read-only Web view of built-in Skills and the persistent user overlay."""

import json
import os
from pathlib import Path


READABLE_SUFFIXES = frozenset({".md", ".sh", ".json"})
HOST_HELPER_CAPABILITIES = {
    "network-ops-tools/firewall": "firewall.apply",
    "network-ops-tools/hosts-file-editor": "hosts.apply",
}


def _reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key is not allowed: {key}")
        result[key] = value
    return result


class SkillService:
    """Merge immutable release Skills with a non-overriding user overlay."""

    def __init__(
        self,
        skills_root,
        manifest_validator=None,
        *,
        user_skills_root=None,
        require_manifest_file=False,
    ):
        self.root = Path(skills_root).resolve()
        self.user_root = (
            Path(os.path.abspath(os.fspath(user_skills_root)))
            if user_skills_root is not None
            else None
        )
        if self.user_root is not None:
            self._assert_no_symlink_components(self.user_root)
        if self.user_root == self.root:
            self.user_root = None
        if manifest_validator is not None and not callable(manifest_validator):
            raise TypeError("manifest_validator must be callable")
        self.manifest_validator = manifest_validator
        self.require_manifest_file = bool(require_manifest_file)

    @staticmethod
    def _assert_no_symlink_components(path):
        """Reject an overlay root before any lexical path can escape it."""

        if not path.is_absolute():
            raise ValueError("Skill root must be an absolute path")
        current = Path(path.anchor)
        for component in path.parts[1:]:
            current /= component
            if current.is_symlink():
                raise ValueError("Skill root must not contain symbolic links")

    @staticmethod
    def _kind(path):
        if path.name == "manifest.json":
            return "manifest"
        return "markdown" if path.suffix == ".md" else "script"

    @staticmethod
    def _is_readable_file(path):
        return path.suffix in {".md", ".sh"} or path.name == "manifest.json"

    @staticmethod
    def _visible_entries(directory):
        try:
            entries = list(directory.iterdir())
        except (FileNotFoundError, NotADirectoryError):
            return []
        return sorted(
            (
                entry
                for entry in entries
                if not entry.name.startswith(".") and not entry.is_symlink()
            ),
            key=lambda entry: (not entry.is_dir(), entry.name.lower(), entry.name),
        )

    def _roots(self):
        roots = [(self.root, "builtin")]
        if self.user_root is not None:
            roots.append((self.user_root, "user"))
        return roots

    def _package_roots(self):
        packages = {}
        for root, origin in self._roots():
            if origin == "user":
                self._assert_no_symlink_components(root)
            if root.is_symlink():
                raise ValueError(f"{origin} skills root must not be a symbolic link")
            for entry in self._visible_entries(root):
                if not entry.is_dir():
                    continue
                if not (entry / "SKILL.md").exists() and not (entry / "scripts").exists():
                    continue
                previous = packages.get(entry.name)
                if previous is not None:
                    raise ValueError(
                        f"User Skill conflicts with built-in Skill: {entry.name}"
                    )
                packages[entry.name] = (entry, origin)
        return packages

    def _root_for_path(self, candidate):
        if len(candidate.parts) == 1:
            return self.root, "builtin"
        packages = self._package_roots()
        package = packages.get(candidate.parts[0])
        if package is None:
            return self.root, "builtin"
        return package[0].parent, package[1]

    def safe_path(self, relative_path):
        """Resolve a readable Skill path without following overlay symlinks."""

        if not isinstance(relative_path, str) or not relative_path or "\x00" in relative_path:
            raise ValueError("skill path is required")
        candidate = Path(relative_path)
        if candidate.is_absolute() or ".." in candidate.parts:
            raise ValueError("skill path must be relative to skills/")
        if any(part.startswith(".") for part in candidate.parts):
            raise ValueError("hidden skill paths are not readable from the web console")
        if not self._is_readable_file(candidate):
            raise ValueError(
                "only Markdown, shell, and manifest.json Skill files are readable"
            )

        root, _origin = self._root_for_path(candidate)
        current = root
        for part in candidate.parts:
            current = current / part
            if current.is_symlink():
                raise ValueError("symbolic links are not readable from the web console")
        target = (root / candidate).resolve()
        try:
            target.relative_to(root)
        except ValueError as exc:
            raise ValueError("skill path must stay below its Skill root") from exc
        return target

    def _build_directory_tree(self, directory, root, origin):
        children = []
        for child in self._visible_entries(directory):
            try:
                relative = child.relative_to(root).as_posix()
                if child.is_dir():
                    children.append(
                        {
                            "type": "dir",
                            "name": child.name,
                            "path": relative,
                            "origin": origin,
                            "children": self._build_directory_tree(child, root, origin),
                        }
                    )
                elif child.is_file() and self._is_readable_file(child):
                    metadata = child.stat()
                    children.append(
                        {
                            "type": "file",
                            "name": child.name,
                            "path": relative,
                            "origin": origin,
                            "kind": self._kind(child),
                            "size_bytes": metadata.st_size,
                            "mtime": int(metadata.st_mtime),
                        }
                    )
            except FileNotFoundError:
                continue
        return children

    def build_tree(self, directory=None):
        """Return one deterministic tree for both non-conflicting roots."""

        if directory is not None and Path(directory).resolve() != self.root:
            resolved = Path(directory).resolve()
            for root, origin in self._roots():
                try:
                    resolved.relative_to(root)
                except ValueError:
                    continue
                return self._build_directory_tree(resolved, root, origin)
            raise ValueError("skill tree path must stay below a Skill root")

        packages = self._package_roots()
        children = []
        for child in self._visible_entries(self.root):
            if child.is_dir():
                package, origin = packages.get(child.name, (child, "builtin"))
                children.append(
                    {
                        "type": "dir",
                        "name": child.name,
                        "path": child.name,
                        "origin": origin,
                        "children": self._build_directory_tree(package, package.parent, origin),
                    }
                )
            elif child.is_file() and self._is_readable_file(child):
                metadata = child.stat()
                children.append(
                    {
                        "type": "file",
                        "name": child.name,
                        "path": child.name,
                        "origin": "builtin",
                        "kind": self._kind(child),
                        "size_bytes": metadata.st_size,
                        "mtime": int(metadata.st_mtime),
                    }
                )
        for name, (package, origin) in packages.items():
            if origin != "user":
                continue
            children.append(
                {
                    "type": "dir",
                    "name": name,
                    "path": name,
                    "origin": origin,
                    "children": self._build_directory_tree(package, package.parent, origin),
                }
            )
        return sorted(
            children,
            key=lambda item: (item["type"] != "dir", item["name"].lower(), item["name"]),
        )

    @staticmethod
    def _tree_file_paths(nodes):
        for node in nodes:
            if node.get("type") == "file":
                yield node
            elif node.get("type") == "dir":
                yield from SkillService._tree_file_paths(node.get("children") or [])

    @staticmethod
    def _legacy_manifest(directory, scripts):
        skill_md = directory / "SKILL.md"
        lines = skill_md.read_text(encoding="utf-8").splitlines()
        metadata = {}
        for line in lines[1:] if lines and lines[0].strip() == "---" else ():
            if line.strip() == "---":
                break
            key, separator, value = line.partition(":")
            if separator and key in {"name", "description"}:
                metadata[key] = value.strip()
        if not metadata.get("name") or not metadata.get("description"):
            raise ValueError(f"Skill metadata is incomplete: {directory.name}")
        return {
            "name": metadata["name"],
            "description": metadata["description"],
            "scripts": [{"name": script.name} for script in scripts],
        }

    def _load_manifest(self, directory, origin):
        skill_md = directory / "SKILL.md"
        scripts_dir = directory / "scripts"
        manifest_path = directory / "manifest.json"
        if (
            skill_md.is_symlink()
            or not skill_md.is_file()
            or scripts_dir.is_symlink()
            or not scripts_dir.is_dir()
        ):
            raise ValueError(f"Skill package is incomplete: {directory.name}")
        scripts = [
            script
            for script in self._visible_entries(scripts_dir)
            if script.is_file() and script.suffix == ".sh"
        ]
        if not scripts:
            raise ValueError(f"Skill package has no scripts: {directory.name}")
        if manifest_path.is_symlink():
            raise ValueError(f"Skill manifest must not be a symlink: {directory.name}")
        manifest_is_file = manifest_path.is_file()
        if manifest_is_file:
            try:
                manifest = json.loads(
                    manifest_path.read_text(encoding="utf-8"),
                    parse_constant=lambda value: (_ for _ in ()).throw(
                        ValueError(f"invalid JSON constant: {value}")
                    ),
                    object_pairs_hook=_reject_duplicate_keys,
                )
            except (OSError, json.JSONDecodeError, ValueError) as exc:
                raise ValueError(f"Skill manifest is invalid: {directory.name}: {exc}") from exc
        elif self.require_manifest_file:
            raise ValueError(f"Skill manifest.json is missing: {directory.name}")
        else:
            manifest = self._legacy_manifest(directory, scripts)

        if not isinstance(manifest, dict) or manifest.get("name") != directory.name:
            raise ValueError(
                f"Skill manifest name does not match its directory: {directory.name}"
            )
        if self.manifest_validator is not None:
            self.manifest_validator(manifest)
        declared = {item.get("name") for item in manifest.get("scripts", [])}
        actual = {script.name for script in scripts}
        if declared != actual:
            raise ValueError(f"Skill manifest script set does not match files: {directory.name}")
        if origin == "user" and any(
            item.get("execution_class") != "runner" or item.get("capability") != ""
            for item in manifest["scripts"]
        ):
            raise ValueError(f"User Skill may only use runner execution: {directory.name}")
        if origin == "builtin":
            for item in manifest["scripts"]:
                ref = f"{directory.name}/{Path(item['name']).stem}"
                expected = HOST_HELPER_CAPABILITIES.get(ref)
                if "execution_class" not in item:
                    continue
                if item["execution_class"] == "host_helper" and (
                    expected is None or item["capability"] != expected
                ):
                    raise ValueError(
                        f"Built-in host_helper declaration is not allowlisted: {ref}"
                    )
                if expected is not None and (
                    item["execution_class"] != "host_helper"
                    or item["capability"] != expected
                ):
                    raise ValueError(
                        f"Privileged built-in Skill must use host_helper: {ref}"
                    )
        return {**manifest, **({"origin": origin} if manifest_is_file else {})}

    def list_manifests(self):
        manifests = []
        for _name, (directory, origin) in sorted(self._package_roots().items()):
            manifests.append(self._load_manifest(directory, origin))
        return manifests

    def list_files(self):
        tree = self.build_tree()
        markdown = []
        scripts = []
        manifests = []
        for node in self._tree_file_paths(tree):
            if node.get("kind") == "markdown":
                markdown.append(node["path"])
            elif node.get("kind") == "script":
                scripts.append(node["path"])
            elif node.get("kind") == "manifest":
                manifests.append(node["path"])
        return {
            "ok": True,
            "status": "listed",
            "root": "skills",
            "tree": tree,
            "markdown_files": sorted(markdown),
            "script_files": sorted(scripts),
            "manifest_files": sorted(manifests),
            "manifests": self.list_manifests(),
        }

    def read_file(self, relative_path):
        target = self.safe_path(relative_path)
        if not target.is_file():
            return {"ok": False, "status": "not_found", "error": "Skill file not found."}
        root, origin = self._root_for_path(Path(relative_path))
        return {
            "ok": True,
            "status": "read",
            "path": target.relative_to(root).as_posix(),
            "origin": origin,
            "kind": self._kind(target),
            "content": target.read_text(encoding="utf-8"),
        }

    safe_skills_path = safe_path
    list_skill_files = list_files
    read_skill_file = read_file


__all__ = ["READABLE_SUFFIXES", "SkillService"]
