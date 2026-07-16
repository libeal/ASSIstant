"""Policy-file and command-guard service for the Web adapter."""

import json
import os
import subprocess
import tempfile
import uuid
from pathlib import Path


def _reject_json_constant(value):
    raise ValueError(f"non-finite JSON number is not allowed: {value}")


def _reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key is not allowed: {key}")
        result[key] = value
    return result


def _write_all(file_descriptor, data):
    view = memoryview(data)
    written = 0
    while written < len(view):
        count = os.write(file_descriptor, view[written:])
        if count <= 0:
            raise OSError("policy temporary write made no forward progress")
        written += count


def _fsync_directory(path):
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
    descriptor = os.open(str(path), flags)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _fsync_file(path):
    descriptor = os.open(str(path), os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


class PolicyService:
    """Own policy browsing, validation, privileged writes, and guard config."""

    def __init__(
        self,
        root,
        *,
        config_reader,
        config_writer,
        agent_api,
        audit,
        config_public_state,
        effective_uid=os.geteuid,
        process_runner=subprocess.run,
    ):
        dependencies = {
            "config_reader": config_reader,
            "config_writer": config_writer,
            "agent_api": agent_api,
            "audit": audit,
            "config_public_state": config_public_state,
            "process_runner": process_runner,
        }
        for name, dependency in dependencies.items():
            if not callable(dependency):
                raise TypeError(f"{name} must be callable")
        if not callable(effective_uid) and not isinstance(effective_uid, int):
            raise TypeError("effective_uid must be an integer or callable")

        self.root = Path(root).resolve()
        self.policies_root = self.root / "policies"
        self.temp_root = self.root / "tmp" / "web" / "policy-edits"
        self._config_reader = config_reader
        self._config_writer = config_writer
        self._agent_api = agent_api
        self._audit = audit
        self._config_public_state = config_public_state
        self._effective_uid = effective_uid
        self._process_runner = process_runner

    def _begin_audited_mutation(self, stage, payload):
        audit_payload = dict(payload)
        audit_payload["operation_id"] = uuid.uuid4().hex
        self._audit(f"{stage}_requested", audit_payload)
        return audit_payload

    def _finish_audited_mutation(self, stage, payload):
        try:
            self._audit(stage, payload)
        except Exception as exc:  # The durable intent still records the mutation.
            return {
                "audit_status": "requested_only",
                "audit_error": str(exc)[:400],
            }
        return {}

    def _euid(self):
        value = self._effective_uid() if callable(self._effective_uid) else self._effective_uid
        return int(value)

    def _assert_policies_root(self):
        if self.policies_root.is_symlink():
            raise ValueError("policies root must not be a symbolic link")
        resolved = self.policies_root.resolve()
        try:
            resolved.relative_to(self.root)
        except ValueError as exc:
            raise ValueError("policies root must stay below the project root") from exc

    def safe_path(self, relative_path):
        self._assert_policies_root()
        if not isinstance(relative_path, str) or not relative_path or "\x00" in relative_path:
            raise ValueError("policy path is required")
        candidate = Path(relative_path)
        if candidate.is_absolute() or ".." in candidate.parts:
            raise ValueError("policy path must be relative to policies/")
        if any(part.startswith(".") for part in candidate.parts):
            raise ValueError("hidden policy paths are not editable from the web console")
        if candidate.suffix != ".json":
            raise ValueError("only JSON policy files are editable from the web console")

        current = self.policies_root
        for part in candidate.parts:
            current = current / part
            if current.is_symlink():
                raise ValueError("symbolic links are not editable from the web console")
        target = (self.policies_root / candidate).resolve()
        try:
            target.relative_to(self.policies_root)
        except ValueError as exc:
            raise ValueError("policy path must be relative to policies/") from exc
        return target

    def list_files(self):
        self._assert_policies_root()
        try:
            paths = sorted(self.policies_root.iterdir(), key=lambda item: item.name)
        except FileNotFoundError:
            return []
        files = []
        for path in paths:
            if path.name.startswith(".") or path.is_symlink():
                continue
            try:
                if not path.is_file() or path.suffix != ".json":
                    continue
                metadata = path.stat()
            except FileNotFoundError:
                continue
            files.append(
                {
                    "path": path.relative_to(self.policies_root).as_posix(),
                    "size_bytes": metadata.st_size,
                    "mtime": int(metadata.st_mtime),
                }
            )
        return files

    def read_file(self, relative_path):
        target = self.safe_path(relative_path)
        if not target.is_file():
            return {"ok": False, "status": "not_found", "error": "Policy file not found."}
        content = target.read_text(encoding="utf-8")
        try:
            parsed = json.loads(
                content,
                parse_constant=_reject_json_constant,
                object_pairs_hook=_reject_duplicate_keys,
            )
        except (json.JSONDecodeError, ValueError):
            parsed = None
        return {
            "ok": True,
            "status": "read",
            "path": target.relative_to(self.policies_root).as_posix(),
            "content": content,
            "json": parsed,
        }

    def validate(self, relative_path, content):
        try:
            self.safe_path(relative_path)
        except ValueError as exc:
            return {"ok": False, "status": "invalid_path", "error": str(exc)}
        return self._agent_api(
            "policy",
            "validate",
            {"path": relative_path, "content": content},
            timeout=60,
        )

    def sudo_check(self, password):
        if self._euid() == 0:
            return {"ok": True, "status": "sudo_ok", "method": "root"}
        if not password:
            return {
                "ok": False,
                "status": "sudo_required",
                "error": "sudo password is required.",
            }
        try:
            process = self._process_runner(
                ["sudo", "-S", "-p", "", "-v"],
                input=f"{password}\n",
                text=True,
                capture_output=True,
                timeout=10,
                check=False,
            )
        except FileNotFoundError:
            return {
                "ok": False,
                "status": "sudo_not_found",
                "error": "sudo is not installed.",
            }
        except subprocess.TimeoutExpired:
            return {
                "ok": False,
                "status": "sudo_timeout",
                "error": "sudo validation timed out.",
            }
        if process.returncode == 0:
            return {"ok": True, "status": "sudo_ok", "method": "sudo"}
        return {
            "ok": False,
            "status": "sudo_denied",
            "error": (process.stderr or "sudo validation failed").strip()[:400],
        }

    @staticmethod
    def _parse_content(content):
        if not isinstance(content, str) or not content.strip():
            return None, {
                "ok": False,
                "status": "empty_content",
                "error": "Policy content is empty.",
            }
        try:
            parsed = json.loads(
                content,
                parse_constant=_reject_json_constant,
                object_pairs_hook=_reject_duplicate_keys,
            )
            normalized = json.dumps(
                parsed,
                ensure_ascii=False,
                indent=2,
                allow_nan=False,
            ) + "\n"
        except (json.JSONDecodeError, TypeError, ValueError) as exc:
            return None, {"ok": False, "status": "invalid_json", "error": str(exc)}
        return normalized, None

    def _create_temp_file(self, target, normalized_content):
        current = self.root
        for part in self.temp_root.relative_to(self.root).parts:
            current = current / part
            if current.is_symlink():
                raise OSError("policy temporary directory must not contain symbolic links")
            current.mkdir(exist_ok=True, mode=0o700)
        try:
            self.temp_root.resolve().relative_to(self.root)
        except ValueError as exc:
            raise OSError("policy temporary directory escaped the project root") from exc
        os.chmod(self.temp_root, 0o700)
        descriptor, raw_path = tempfile.mkstemp(
            prefix=f"{target.name}.",
            suffix=".tmp",
            dir=self.temp_root,
        )
        temp_path = Path(raw_path)
        try:
            os.fchmod(descriptor, 0o600)
            _write_all(descriptor, normalized_content.encode("utf-8"))
            os.fsync(descriptor)
        except Exception:
            os.close(descriptor)
            try:
                temp_path.unlink()
            except FileNotFoundError:
                pass
            raise
        os.close(descriptor)
        return temp_path

    def _root_replace(self, temp_path, target):
        target.parent.mkdir(parents=True, exist_ok=True)
        os.chmod(temp_path, 0o644)
        _fsync_file(temp_path)
        os.replace(temp_path, target)
        _fsync_file(target)
        _fsync_directory(target.parent)
        if self.temp_root != target.parent:
            _fsync_directory(self.temp_root)

    def _sudo_install(self, temp_path, target, password):
        try:
            return self._process_runner(
                [
                    "sudo",
                    "-S",
                    "-p",
                    "",
                    "install",
                    "-m",
                    "0644",
                    "--",
                    str(temp_path),
                    str(target),
                ],
                input=f"{password}\n",
                text=True,
                capture_output=True,
                timeout=10,
                check=False,
            )
        except subprocess.TimeoutExpired:
            return None

    def write_file(self, relative_path, content, password=""):
        target = self.safe_path(relative_path)
        normalized_content, parse_error = self._parse_content(content)
        if parse_error:
            return parse_error

        validation = self.validate(relative_path, normalized_content)
        if not isinstance(validation, dict) or not validation.get("ok"):
            return {
                "ok": False,
                "status": "validation_failed",
                "error": "Policy validation failed.",
                "validation": validation.get("validation", validation)
                if isinstance(validation, dict)
                else {"ok": False, "status": "invalid_validation_response"},
            }

        method = "root"
        if self._euid() != 0:
            check = self.sudo_check(password)
            if not check.get("ok"):
                return check
            method = str(check.get("method") or "sudo")

        relative = target.relative_to(self.policies_root).as_posix()
        audit_payload = self._begin_audited_mutation(
            "policy_update",
            {"path": relative, "method": method},
        )
        temp_path = self._create_temp_file(target, normalized_content)
        try:
            if method == "root":
                self._root_replace(temp_path, target)
            else:
                process = self._sudo_install(temp_path, target, password)
                if process is None:
                    return {
                        "ok": False,
                        "status": "sudo_timeout",
                        "error": "sudo install timed out.",
                    }
                if process.returncode != 0:
                    return {
                        "ok": False,
                        "status": "sudo_write_failed",
                        "error": (process.stderr or "sudo install failed").strip()[:400],
                    }
                _fsync_file(target)
                _fsync_directory(target.parent)
        finally:
            try:
                temp_path.unlink()
            except FileNotFoundError:
                pass

        audit_result = self._finish_audited_mutation("policy_updated", audit_payload)
        return {
            "ok": True,
            "status": "saved",
            "path": relative,
            "method": method,
            **audit_result,
        }

    def update_command_guard(self, enabled, password=""):
        if not isinstance(enabled, bool):
            return {
                "ok": False,
                "status": "invalid_config_value",
                "error": "command_guard.enabled must be boolean.",
            }

        if self._euid() == 0:
            method = "root"
        else:
            check = self.sudo_check(password)
            if not check.get("ok"):
                return check
            method = str(check.get("method") or "sudo")

        audit_payload = self._begin_audited_mutation(
            "command_guard_update",
            {"enabled": enabled, "method": method},
        )
        current = self._config_reader()
        config = dict(current) if isinstance(current, dict) else {}
        existing_guard = config.get("command_guard")
        command_guard = dict(existing_guard) if isinstance(existing_guard, dict) else {}
        command_guard["enabled"] = enabled
        config["command_guard"] = command_guard
        try:
            self._config_writer(config)
        except OSError as exc:
            return {
                "ok": False,
                "status": "config_write_failed",
                "error": f"Could not save command guard setting: {exc}",
            }

        result = self._config_public_state()
        result = dict(result) if isinstance(result, dict) else {"ok": True}
        public_config = result.get("config") if isinstance(result.get("config"), dict) else {}
        result["status"] = "updated"
        result["method"] = method
        result["command_guard"] = public_config.get("command_guard", command_guard)
        result.update(
            self._finish_audited_mutation(
                "command_guard_updated",
                audit_payload,
            )
        )
        return result

    # Compatibility names for a later server adapter-only patch.
    safe_policy_path = safe_path
    list_policy_files = list_files
    read_policy_file = read_file
    validate_policy_content = validate
    write_policy_file = write_file


__all__ = ["PolicyService"]
