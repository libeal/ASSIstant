"""Skill file browsing service for the Web adapter.

The service exposes only Markdown documentation and shell adapters below the
configured ``skills`` directory.  Hidden entries and symbolic links are not
enumerated, and every direct read is resolved and checked against the service
root before the file is opened.
"""

from pathlib import Path


READABLE_SUFFIXES = frozenset({".md", ".sh"})


class SkillService:
    """List and read the Web-visible portion of a Skill directory."""

    def __init__(self, skills_root):
        self.root = Path(skills_root).resolve()

    @staticmethod
    def _kind(path):
        return "markdown" if path.suffix == ".md" else "script"

    def safe_path(self, relative_path):
        """Resolve a readable Skill path without allowing root escape."""

        if not isinstance(relative_path, str) or not relative_path or "\x00" in relative_path:
            raise ValueError("skill path is required")
        candidate = Path(relative_path)
        if candidate.is_absolute() or ".." in candidate.parts:
            raise ValueError("skill path must be relative to skills/")
        if any(part.startswith(".") for part in candidate.parts):
            raise ValueError("hidden skill paths are not readable from the web console")
        if candidate.suffix not in READABLE_SUFFIXES:
            raise ValueError(
                "only Markdown and shell skill files are readable from the web console"
            )

        # Reject symlink components even when their current target happens to be
        # inside the root.  This keeps enumeration and direct reads on the same
        # policy and avoids following a link that can be retargeted later.
        current = self.root
        for part in candidate.parts:
            current = current / part
            if current.is_symlink():
                raise ValueError("symbolic links are not readable from the web console")

        target = (self.root / candidate).resolve()
        try:
            target.relative_to(self.root)
        except ValueError as exc:
            raise ValueError("skill path must be relative to skills/") from exc
        return target

    def _visible_entries(self, directory):
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

    def build_tree(self, directory=None):
        """Return a deterministic tree containing visible Skill files only."""

        directory = self.root if directory is None else Path(directory)
        try:
            directory.resolve().relative_to(self.root)
        except ValueError as exc:
            raise ValueError("skill tree path must stay below skills/") from exc

        children = []
        for child in self._visible_entries(directory):
            try:
                relative = child.relative_to(self.root).as_posix()
                if child.is_dir():
                    children.append(
                        {
                            "type": "dir",
                            "name": child.name,
                            "path": relative,
                            "children": self.build_tree(child),
                        }
                    )
                elif child.is_file() and child.suffix in READABLE_SUFFIXES:
                    metadata = child.stat()
                    children.append(
                        {
                            "type": "file",
                            "name": child.name,
                            "path": relative,
                            "kind": self._kind(child),
                            "size_bytes": metadata.st_size,
                            "mtime": int(metadata.st_mtime),
                        }
                    )
            except FileNotFoundError:
                # An entry removed during a listing simply is not part of this
                # snapshot; other IO failures remain visible to the caller.
                continue
        return children

    @staticmethod
    def _tree_file_paths(nodes):
        for node in nodes:
            if node.get("type") == "file":
                yield node
            elif node.get("type") == "dir":
                yield from SkillService._tree_file_paths(node.get("children") or [])

    def list_files(self):
        tree = self.build_tree()
        markdown = []
        scripts = []
        for node in self._tree_file_paths(tree):
            if node.get("kind") == "markdown":
                markdown.append(node["path"])
            elif node.get("kind") == "script":
                scripts.append(node["path"])
        return {
            "ok": True,
            "status": "listed",
            "root": "skills",
            "tree": tree,
            "markdown_files": sorted(markdown),
            "script_files": sorted(scripts),
        }

    def read_file(self, relative_path):
        target = self.safe_path(relative_path)
        if not target.is_file():
            return {"ok": False, "status": "not_found", "error": "Skill file not found."}
        return {
            "ok": True,
            "status": "read",
            "path": target.relative_to(self.root).as_posix(),
            "kind": self._kind(target),
            "content": target.read_text(encoding="utf-8"),
        }

    # Names matching the existing server functions make the eventual adapter
    # wiring mechanical while keeping all behavior owned by this service.
    safe_skills_path = safe_path
    list_skill_files = list_files
    read_skill_file = read_file


__all__ = ["READABLE_SUFFIXES", "SkillService"]
