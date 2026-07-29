"""Read-only Web view of builtin and user Agent Skills packages."""

from __future__ import annotations

import os
from pathlib import Path

from skill_package import (
    SkillPackageError,
    SkillPackageIncompatibleError,
    load_index,
    load_package,
)


READABLE_SUFFIXES = frozenset({".json", ".md", ".py", ".sh", ".txt"})
MAX_READ_BYTES = 256 * 1024


class SkillService:
    """Expose Skill files while delegating package validation to the resolver."""

    def __init__(self, skills_root, *, user_skills_root=None):
        self.root = Path(os.path.abspath(os.fspath(skills_root)))
        self.user_root = (
            Path(os.path.abspath(os.fspath(user_skills_root)))
            if user_skills_root is not None
            else None
        )
        self._assert_no_symlink_components(self.root)
        if self.user_root is not None:
            self._assert_no_symlink_components(self.user_root)
        if self.user_root == self.root:
            self.user_root = None

    @staticmethod
    def _assert_no_symlink_components(path):
        if not path.is_absolute():
            raise ValueError("Skill root must be an absolute path")
        current = Path(path.anchor)
        for component in path.parts[1:]:
            current /= component
            if current.is_symlink():
                raise ValueError("Skill root must not contain symbolic links")

    @staticmethod
    def _kind(path):
        if path.name == "linux-agent.json":
            return "extension"
        if path.suffix == ".md":
            return "markdown"
        if path.suffix in {".py", ".sh"}:
            return "script"
        return "reference"

    @staticmethod
    def _is_readable_file(path):
        return path.suffix in READABLE_SUFFIXES

    @staticmethod
    def _visible_entries(directory):
        try:
            entries = list(directory.iterdir())
        except (FileNotFoundError, NotADirectoryError, PermissionError):
            return []
        return sorted(
            (
                entry
                for entry in entries
                if not entry.name.startswith(".") and not entry.is_symlink()
            ),
            key=lambda entry: (not entry.is_dir(), entry.name.lower(), entry.name),
        )

    def _reserved_builtin_names(self):
        index_path = self.root / "INDEX.md"
        try:
            return frozenset(load_index(index_path))
        except SkillPackageError:
            return frozenset()

    def _scan_packages(self):
        packages = {}
        findings = []
        reserved = self._reserved_builtin_names()
        for entry in self._visible_entries(self.root):
            if entry.is_dir() and (entry / "SKILL.md").is_file():
                packages[entry.name] = (entry, "builtin")
        if self.user_root is None:
            return packages, findings
        self._assert_no_symlink_components(self.user_root)
        for entry in self._visible_entries(self.user_root):
            if not entry.is_dir() or not (entry / "SKILL.md").is_file():
                continue
            if entry.name in reserved or entry.name in packages:
                findings.append(
                    {
                        "severity": "warning",
                        "code": "SKILL_NAME_RESERVED",
                        "skill": entry.name,
                        "message": "User Skill conflicts with a reserved builtin name.",
                    }
                )
                continue
            packages[entry.name] = (entry, "user")
        return packages, findings

    def _root_for_path(self, candidate):
        if len(candidate.parts) == 1:
            return self.root, "builtin"
        packages, _findings = self._scan_packages()
        package = packages.get(candidate.parts[0])
        if package is None:
            return self.root, "builtin"
        return package[0].parent, package[1]

    def safe_path(self, relative_path):
        """Resolve a readable Skill path without following symbolic links."""

        if not isinstance(relative_path, str) or not relative_path or "\x00" in relative_path:
            raise ValueError("skill path is required")
        candidate = Path(relative_path)
        if candidate.is_absolute() or ".." in candidate.parts:
            raise ValueError("skill path must be relative to skills/")
        if any(part.startswith(".") for part in candidate.parts):
            raise ValueError("hidden skill paths are not readable from the web console")
        if not self._is_readable_file(candidate):
            raise ValueError("only UTF-8 Skill metadata, scripts, and references are readable")

        root, _origin = self._root_for_path(candidate)
        current = root
        for part in candidate.parts:
            current /= part
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
            except (FileNotFoundError, PermissionError):
                continue
        return children

    def build_tree(self, directory=None):
        if directory is not None and Path(directory).resolve() != self.root.resolve():
            resolved = Path(directory).resolve()
            roots = [(self.root, "builtin")]
            if self.user_root is not None:
                roots.append((self.user_root, "user"))
            for root, origin in roots:
                try:
                    resolved.relative_to(root)
                except ValueError:
                    continue
                return self._build_directory_tree(resolved, root, origin)
            raise ValueError("skill tree path must stay below a Skill root")

        packages, _findings = self._scan_packages()
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
    def _public_package(directory, origin):
        try:
            package = load_package(directory, origin)
        except SkillPackageIncompatibleError as exc:
            return {
                "name": directory.name,
                "origin": origin,
                "state": "incompatible",
                "error": str(exc),
            }
        except SkillPackageError as exc:
            return {
                "name": directory.name,
                "origin": origin,
                "state": "invalid",
                "error": str(exc),
            }
        return {
            key: value
            for key, value in {
                **package,
                "origin": origin,
                "state": "installed",
            }.items()
            if key not in {"body", "extension"}
        }

    def list_packages(self):
        packages, _findings = self._scan_packages()
        return [
            self._public_package(directory, origin)
            for _name, (directory, origin) in sorted(packages.items())
        ]

    def builtin_components(self, component_type):
        """Return valid installed builtin components without exposing user code."""

        packages, findings = self._scan_packages()
        components = []
        for name, (directory, origin) in sorted(packages.items()):
            if origin != "builtin":
                continue
            try:
                package = load_package(directory, origin)
            except SkillPackageIncompatibleError as exc:
                findings.append(
                    {
                        "severity": "warning",
                        "code": "SKILL_COMPONENT_INCOMPATIBLE",
                        "skill": name,
                        "message": str(exc),
                    }
                )
                continue
            except SkillPackageError as exc:
                findings.append(
                    {
                        "severity": "warning",
                        "code": "SKILL_COMPONENT_INVALID",
                        "skill": name,
                        "message": str(exc),
                    }
                )
                continue
            component = package.get("components", {}).get(component_type)
            if isinstance(component, dict):
                components.append(
                    {
                        "name": name,
                        "directory": directory,
                        "component": component,
                        "package": package,
                    }
                )
        return components, findings

    def builtin_package_names(self):
        """Return every installed builtin directory, including invalid packages."""

        packages, _findings = self._scan_packages()
        return frozenset(
            name for name, (_directory, origin) in packages.items() if origin == "builtin"
        )

    def list_files(self):
        tree = self.build_tree()
        markdown = []
        scripts = []
        extensions = []
        references = []
        for node in self._tree_file_paths(tree):
            kind = node.get("kind")
            if kind == "markdown":
                markdown.append(node["path"])
            elif kind == "script":
                scripts.append(node["path"])
            elif kind == "extension":
                extensions.append(node["path"])
            else:
                references.append(node["path"])
        _packages, findings = self._scan_packages()
        return {
            "ok": True,
            "status": "listed",
            "root": "skills",
            "tree": tree,
            "markdown_files": sorted(markdown),
            "script_files": sorted(scripts),
            "extension_files": sorted(extensions),
            "reference_files": sorted(references),
            "packages": self.list_packages(),
            "findings": findings,
        }

    def read_file(self, relative_path):
        target = self.safe_path(relative_path)
        if not target.is_file():
            return {"ok": False, "status": "not_found", "error": "Skill file not found."}
        if target.stat().st_size > MAX_READ_BYTES:
            raise ValueError("Skill file exceeds the Web read limit")
        root, origin = self._root_for_path(Path(relative_path))
        try:
            content = target.read_text(encoding="utf-8")
        except UnicodeDecodeError as exc:
            raise ValueError("Skill file must be UTF-8") from exc
        return {
            "ok": True,
            "status": "read",
            "path": target.relative_to(root).as_posix(),
            "origin": origin,
            "kind": self._kind(target),
            "content": content,
        }

    safe_skills_path = safe_path
    list_skill_files = list_files
    read_skill_file = read_file


__all__ = ["READABLE_SUFFIXES", "SkillService"]
