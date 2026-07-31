"""Policy-file and command-guard service for the Web adapter."""

import json
import os
import stat
import tempfile
import uuid
from pathlib import Path


class SensitiveEditsDisabled(RuntimeError):
    pass


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
    descriptor = os.open(str(path), os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _assert_no_symlink_components(path):
    """Reject existing symbolic-link components before a Web-originated write."""

    path = Path(os.path.abspath(os.fspath(path)))
    current = Path(path.root)
    for component in path.parts[1:]:
        current /= component
        try:
            metadata = current.lstat()
        except FileNotFoundError:
            break
        if stat.S_ISLNK(metadata.st_mode):
            raise ValueError(f"policy path component must not be a symlink: {current}")
        if current != path and not stat.S_ISDIR(metadata.st_mode):
            raise ValueError(f"policy path component is not a directory: {current}")


def _copy_snapshot(source, directory):
    source = Path(source)
    directory = Path(directory)
    source_descriptor = os.open(
        str(source), os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    )
    snapshot_descriptor = -1
    snapshot = None
    try:
        metadata = os.fstat(source_descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise OSError("policy target must be a regular file")
        snapshot_descriptor, raw_path = tempfile.mkstemp(
            prefix=f".{source.name}.previous.", suffix=".tmp", dir=str(directory)
        )
        snapshot = Path(raw_path)
        os.fchmod(snapshot_descriptor, stat.S_IMODE(metadata.st_mode))
        while True:
            chunk = os.read(source_descriptor, 65536)
            if not chunk:
                break
            _write_all(snapshot_descriptor, chunk)
        os.fsync(snapshot_descriptor)
        os.close(snapshot_descriptor)
        snapshot_descriptor = -1
        current = os.stat(source, follow_symlinks=False)
        identity = (metadata.st_dev, metadata.st_ino, metadata.st_size, metadata.st_mtime_ns)
        current_identity = (
            current.st_dev,
            current.st_ino,
            current.st_size,
            current.st_mtime_ns,
        )
        if identity != current_identity:
            raise OSError("policy target changed while preparing replacement")
        return snapshot
    except Exception:
        if snapshot_descriptor >= 0:
            os.close(snapshot_descriptor)
        if snapshot is not None:
            snapshot.unlink(missing_ok=True)
        raise
    finally:
        os.close(source_descriptor)


def _restore_snapshot(snapshot, target, directory):
    snapshot = Path(snapshot)
    target = Path(target)
    directory = Path(directory)
    source_descriptor = os.open(
        str(snapshot), os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    )
    rollback_descriptor = -1
    rollback = None
    try:
        metadata = os.fstat(source_descriptor)
        rollback_descriptor, raw_path = tempfile.mkstemp(
            prefix=f".{target.name}.rollback.", suffix=".tmp", dir=str(directory)
        )
        rollback = Path(raw_path)
        os.fchmod(rollback_descriptor, stat.S_IMODE(metadata.st_mode))
        while True:
            chunk = os.read(source_descriptor, 65536)
            if not chunk:
                break
            _write_all(rollback_descriptor, chunk)
        os.fsync(rollback_descriptor)
        os.close(rollback_descriptor)
        rollback_descriptor = -1
        os.replace(rollback, target)
        rollback = None
        os.chmod(target, stat.S_IMODE(metadata.st_mode))
        _fsync_file(target)
        _fsync_directory(directory)
    finally:
        if rollback_descriptor >= 0:
            os.close(rollback_descriptor)
        if rollback is not None:
            rollback.unlink(missing_ok=True)
        os.close(source_descriptor)


class PolicyService:
    """Own policy browsing, validation, privileged writes, and guard config."""

    def __init__(
        self,
        root,
        *,
        overlay_root=None,
        config_reader,
        config_writer,
        agent_api,
        audit,
        config_public_state,
        config_updater=None,
        effective_uid=os.geteuid,
        privileged_writer=None,
        privileged_writer_probe=None,
        managed_execution=None,
        config_path=None,
        deployment_mode=None,
        # Kept as accepted compatibility parameters for third-party adapters;
        # policy editing no longer invokes sudo or a password-bearing runner.
        process_runner=None,
        env_builder=None,
    ):
        dependencies = {
            "config_reader": config_reader,
            "config_writer": config_writer,
            "agent_api": agent_api,
            "audit": audit,
            "config_public_state": config_public_state,
        }
        for name, dependency in dependencies.items():
            if not callable(dependency):
                raise TypeError(f"{name} must be callable")
        if config_updater is not None and not callable(config_updater):
            raise TypeError("config_updater must be callable")
        if not callable(effective_uid) and not isinstance(effective_uid, int):
            raise TypeError("effective_uid must be an integer or callable")
        if privileged_writer is not None and not callable(privileged_writer):
            raise TypeError("privileged_writer must be callable")
        if privileged_writer_probe is not None and not callable(privileged_writer_probe):
            raise TypeError("privileged_writer_probe must be callable")
        if managed_execution is not None and not isinstance(managed_execution, bool):
            raise TypeError("managed_execution must be a boolean or None")
        if deployment_mode is not None and deployment_mode not in {
            "source",
            "remote",
            "no_systemd",
            "managed",
        }:
            raise ValueError("deployment_mode is invalid")

        self.root = Path(root).resolve()
        self.policies_root = self.root / "policies"
        # Adapters that do not provide an explicit overlay retain the historic
        # in-tree behavior; the production Web adapter always injects the
        # managed ``data/policies`` root explicitly.
        self.overlay_root = (
            Path(os.path.abspath(os.fspath(overlay_root)))
            if overlay_root is not None
            else self.policies_root
        )
        self.managed = (
            self.root.parent.name == "releases"
            if managed_execution is None
            else managed_execution
        )
        self.deployment_mode = deployment_mode or (
            "managed"
            if self.managed
            else ("no_systemd" if self.root.parent.name == "releases" else "source")
        )
        self._config_reader = config_reader
        self._config_writer = config_writer
        self._config_updater = config_updater
        self._config_path = (
            Path(os.path.abspath(os.fspath(config_path)))
            if config_path is not None
            else None
        )
        self._agent_api = agent_api
        self._audit = audit
        self._config_public_state = config_public_state
        self._effective_uid = effective_uid
        self._privileged_writer = privileged_writer
        self._privileged_writer_probe = privileged_writer_probe

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

    @staticmethod
    def _has_writable_ancestor(path):
        """Return whether a missing target can be created by this process."""

        current = Path(path).parent
        while not current.exists():
            parent = current.parent
            if parent == current:
                return False
            current = parent
        return current.is_dir() and os.access(current, os.W_OK | os.X_OK)

    @staticmethod
    def _config_allows_mutation(config):
        if not isinstance(config, dict):
            return False
        if "web" not in config:
            return True
        web = config.get("web")
        if not isinstance(web, dict):
            return False
        if "sensitive_edits_enabled" not in web:
            return True
        value = web.get("sensitive_edits_enabled")
        return value if isinstance(value, bool) else False

    def _mutation_allowed(self):
        return self._config_allows_mutation(self._config_reader())

    def _mutation_blocked_result(self):
        return {
            "ok": False,
            "status": "sensitive_edits_disabled",
            "code": "sensitive_edits_disabled",
            "error": "Sensitive Web edits are disabled by server configuration.",
        }

    def _require_mutation_allowed(self):
        if not self._mutation_allowed():
            raise SensitiveEditsDisabled

    @staticmethod
    def _capability(*, available, allowed, method, code="", reason=""):
        return {
            "available": bool(available),
            "allowed": bool(allowed),
            "method": str(method or "unavailable"),
            "code": str(code or ""),
            "reason": str(reason or "")[:400],
        }

    def _direct_policy_available(self, target=None):
        try:
            self._assert_overlay_root()
        except (OSError, ValueError):
            return False
        candidate = Path(target) if target is not None else self.overlay_root / ".write-check"
        return self._has_writable_ancestor(candidate)

    def _direct_config_available(self):
        if self._config_path is None:
            return True
        try:
            _assert_no_symlink_components(self._config_path.parent)
        except (OSError, ValueError):
            return False
        return self._has_writable_ancestor(self._config_path)

    def mutation_capabilities(self):
        """Report effective Web mutation channels for the current deployment."""

        mutation_enabled = self._mutation_allowed()
        if self.managed:
            helper_result = None
            if self._privileged_writer_probe is not None:
                try:
                    helper_result = self._privileged_writer_probe()
                except (OSError, ValueError) as exc:
                    helper_result = {
                        "ok": False,
                        "status": "helper_unavailable",
                        "error": str(exc),
                    }
            helper_available = bool(
                isinstance(helper_result, dict)
                and helper_result.get("ok") is True
                and helper_result.get("status") in {"ready", "ok"}
            )
            helper_code = "" if helper_available else str(
                (helper_result or {}).get("code")
                or (helper_result or {}).get("status")
                or "helper_unavailable"
            )
            helper_reason = "" if helper_available else str(
                (helper_result or {}).get("error")
                or "Policy writer helper is unavailable."
            )
            policy_available = helper_available
            guard_available = helper_available
            policy_method = guard_method = "policy_helper"
            policy_code = guard_code = helper_code
            policy_reason = guard_reason = helper_reason
        else:
            policy_available = self._direct_policy_available()
            guard_available = self._direct_config_available()
            policy_method = guard_method = "root" if self._euid() == 0 else "direct"
            policy_code = "" if policy_available else "policy_write_failed"
            guard_code = "" if guard_available else "config_write_failed"
            policy_reason = (
                ""
                if policy_available
                else "The policy overlay directory is not writable by the Web process."
            )
            guard_reason = (
                ""
                if guard_available
                else "The configuration directory is not writable by the Web process."
            )

        if not mutation_enabled:
            policy_code = guard_code = "sensitive_edits_disabled"
            policy_reason = guard_reason = (
                "Sensitive Web edits are disabled by server configuration."
            )

        return {
            "deployment_mode": self.deployment_mode,
            "sensitive_edits_enabled": mutation_enabled,
            "policy_sudo_password_supported": False,
            "policy_write": self._capability(
                available=policy_available,
                allowed=mutation_enabled and policy_available,
                method=policy_method,
                code=policy_code,
                reason=policy_reason,
            ),
            "command_guard_write": self._capability(
                available=guard_available,
                allowed=mutation_enabled and guard_available,
                method=guard_method,
                code=guard_code,
                reason=guard_reason,
            ),
        }

    def _assert_policies_root(self):
        if self.policies_root.is_symlink():
            raise ValueError("policies root must not be a symbolic link")
        resolved = self.policies_root.resolve()
        try:
            resolved.relative_to(self.root)
        except ValueError as exc:
            raise ValueError("policies root must stay below the project root") from exc

    def _assert_overlay_root(self):
        _assert_no_symlink_components(self.overlay_root)
        if self.overlay_root.is_symlink():
            raise ValueError("policy overlay root must not be a symbolic link")
        if self.overlay_root.exists() and not self.overlay_root.is_dir():
            raise ValueError("policy overlay root must be a directory")

    @staticmethod
    def _validate_relative_path(relative_path):
        if not isinstance(relative_path, str) or not relative_path or "\x00" in relative_path:
            raise ValueError("policy path is required")
        candidate = Path(relative_path)
        if candidate.is_absolute() or ".." in candidate.parts:
            raise ValueError("policy path must be relative to policies/")
        if len(candidate.parts) != 1 or candidate.name.startswith("."):
            raise ValueError("only registered top-level policy files are editable")
        if candidate.suffix != ".json":
            raise ValueError("only JSON policy files are editable from the web console")
        return candidate

    def _registered_default(self, relative_path):
        self._assert_policies_root()
        candidate = self._validate_relative_path(relative_path)
        target = self.policies_root / candidate
        if target.is_symlink() or not target.is_file():
            raise ValueError("policy is not registered by the current release")
        return target

    def _overlay_target(self, relative_path):
        self._registered_default(relative_path)
        self._assert_overlay_root()
        candidate = self._validate_relative_path(relative_path)
        target = self.overlay_root / candidate
        if target.is_symlink():
            raise ValueError("symbolic links are not editable from the web console")
        return target

    def safe_path(self, relative_path):
        default = self._registered_default(relative_path)
        overlay = self._overlay_target(relative_path)
        if overlay.exists():
            if not overlay.is_file():
                raise ValueError("policy overlay must be a regular file")
            return overlay
        return default

    def list_files(self):
        self._assert_policies_root()
        self._assert_overlay_root()
        paths = sorted(self.policies_root.iterdir(), key=lambda item: item.name)
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
            overlay = self.overlay_root / path.name
            effective = overlay if overlay.exists() else path
            if overlay.is_symlink() or (overlay.exists() and not overlay.is_file()):
                raise ValueError(f"policy overlay is invalid: {path.name}")
            metadata = effective.stat()
            files.append(
                {
                    "path": path.name,
                    "size_bytes": metadata.st_size,
                    "mtime": int(metadata.st_mtime),
                    "source": "overlay" if effective == overlay else "default",
                }
            )
        return files

    def orphaned_files(self):
        self._assert_overlay_root()
        if not self.overlay_root.exists():
            return []
        orphans = []
        for path in sorted(self.overlay_root.iterdir(), key=lambda item: item.name):
            if path.name.startswith(".") or path.is_symlink() or not path.is_file():
                continue
            if path.suffix == ".json" and not (self.policies_root / path.name).is_file():
                orphans.append(path.name)
        return orphans

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
            "path": Path(relative_path).as_posix(),
            "source": "overlay" if target.parent == self.overlay_root else "default",
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

    def sudo_check(self, _password=None):
        """Compatibility endpoint: Bearer authentication is the authorization."""

        return {
            "ok": True,
            "status": "authorization_not_required",
            "method": "web_bearer",
            "deprecated": True,
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
        directory = Path(target).parent
        _assert_no_symlink_components(directory)
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        if directory.is_symlink() or not directory.is_dir():
            raise OSError("policy overlay directory is invalid")
        descriptor, raw_path = tempfile.mkstemp(
            prefix=f"{target.name}.",
            suffix=".tmp",
            dir=directory,
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

    def _root_replace(self, temp_path, target, pre_replace=None):
        _assert_no_symlink_components(target.parent)
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.parent.is_symlink() or target.is_symlink():
            raise OSError("policy target must not be a symbolic link")
        target_mode = 0o644 if self.overlay_root == self.policies_root else 0o600
        os.chmod(temp_path, target_mode)
        _fsync_file(temp_path)
        snapshot = None
        replaced = False
        retain_snapshot = False
        target_existed = target.exists()
        if target_existed:
            snapshot = _copy_snapshot(target, target.parent)
            _fsync_directory(target.parent)
        elif target.is_symlink():
            raise OSError("policy target appeared as a symbolic link")
        if pre_replace is not None:
            try:
                pre_replace()
            except Exception:
                if snapshot is not None:
                    snapshot.unlink(missing_ok=True)
                raise
        try:
            os.replace(temp_path, target)
            replaced = True
            _fsync_file(target)
            _fsync_directory(target.parent)
        except Exception as exc:
            if replaced:
                try:
                    if snapshot is not None:
                        _restore_snapshot(snapshot, target, target.parent)
                    else:
                        target.unlink(missing_ok=True)
                        _fsync_directory(target.parent)
                except Exception as rollback_exc:
                    retain_snapshot = snapshot is not None
                    recovery = f"; recovery backup: {snapshot}" if snapshot else ""
                    raise OSError(
                        f"policy replacement failed and rollback failed{recovery}: {rollback_exc}"
                    ) from exc
            raise
        finally:
            if snapshot is not None and not retain_snapshot:
                try:
                    snapshot.unlink(missing_ok=True)
                except OSError:
                    pass

    def write_file(self, relative_path, content, _password=""):
        target = self._overlay_target(relative_path)
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

        if not self._mutation_allowed():
            return self._mutation_blocked_result()

        direct_write = not self.managed and self._direct_policy_available(target)
        method = (
            ("root" if self._euid() == 0 else "direct")
            if not self.managed
            else "policy_helper"
        )
        if not self.managed and not direct_write:
            return {
                "ok": False,
                "status": "policy_write_failed",
                "code": "policy_write_failed",
                "error": (
                    "The policy overlay directory is not writable by the Web process."
                ),
            }
        if self.managed and self._privileged_writer is None:
            return {
                "ok": False,
                "status": "helper_unavailable",
                "code": "helper_unavailable",
                "error": "Policy writer helper is required for this installation.",
            }

        relative = Path(relative_path).name
        audit_payload = self._begin_audited_mutation(
            "policy_update",
            {"path": relative, "method": method},
        )
        helper_warning = None
        if direct_write:
            temp_path = None
            try:
                temp_path = self._create_temp_file(target, normalized_content)
                try:
                    self._root_replace(
                        temp_path,
                        target,
                        pre_replace=self._require_mutation_allowed,
                    )
                except SensitiveEditsDisabled:
                    return self._mutation_blocked_result()
            except (OSError, ValueError) as exc:
                return {
                    "ok": False,
                    "status": "policy_write_failed",
                    "code": "policy_write_failed",
                    "error": f"Could not save policy: {exc}",
                }
            finally:
                if temp_path is not None:
                    try:
                        temp_path.unlink()
                    except FileNotFoundError:
                        pass
        else:
            if not self._mutation_allowed():
                return self._mutation_blocked_result()
            helper_result = self._privileged_writer(
                "policy.write",
                {"path": relative, "content": normalized_content},
            )
            if not isinstance(helper_result, dict) or not helper_result.get("ok"):
                return helper_result if isinstance(helper_result, dict) else {
                    "ok": False,
                    "status": "helper_failed",
                    "code": "helper_failed",
                    "error": "Policy writer helper returned an invalid response.",
                }
            helper_warning = helper_result.get("warning")

        audit_result = self._finish_audited_mutation("policy_updated", audit_payload)
        result = {
            "ok": True,
            "status": "saved",
            "path": relative,
            "method": method,
            **audit_result,
        }
        if isinstance(helper_warning, str) and helper_warning:
            result["warning"] = helper_warning
        return result

    def update_command_guard(self, enabled, _password=""):
        if not isinstance(enabled, bool):
            return {
                "ok": False,
                "status": "invalid_config_value",
                "error": "command_guard.enabled must be boolean.",
            }

        if not self._mutation_allowed():
            return self._mutation_blocked_result()

        direct_write = not self.managed and self._direct_config_available()
        method = (
            ("root" if self._euid() == 0 else "direct")
            if not self.managed
            else "policy_helper"
        )
        if not self.managed and not direct_write:
            return {
                "ok": False,
                "status": "config_write_failed",
                "code": "config_write_failed",
                "error": (
                    "The configuration directory is not writable by the Web process."
                ),
            }
        if self.managed and self._privileged_writer is None:
            return {
                "ok": False,
                "status": "helper_unavailable",
                "code": "helper_unavailable",
                "error": "Policy writer helper is required for this installation.",
            }

        audit_payload = self._begin_audited_mutation(
            "command_guard_update",
            {"enabled": enabled, "method": method},
        )
        command_guard = {"enabled": enabled}
        helper_warning = None

        def mutate_config(config):
            if not self._config_allows_mutation(config):
                raise SensitiveEditsDisabled
            existing_guard = config.get("command_guard")
            updated_guard = dict(existing_guard) if isinstance(existing_guard, dict) else {}
            updated_guard["enabled"] = enabled
            config["command_guard"] = updated_guard

        try:
            if not self._mutation_allowed():
                return self._mutation_blocked_result()
            if not direct_write:
                helper_result = self._privileged_writer(
                    "command_guard.set",
                    {"enabled": enabled},
                )
                if not isinstance(helper_result, dict) or not helper_result.get("ok"):
                    return helper_result if isinstance(helper_result, dict) else {
                        "ok": False,
                        "status": "helper_failed",
                        "code": "helper_failed",
                        "error": "Policy writer helper returned an invalid response.",
                    }
                helper_warning = helper_result.get("warning")
            elif self._config_updater is not None:
                self._config_updater(mutate_config)
            else:
                current = self._config_reader()
                config = dict(current) if isinstance(current, dict) else {}
                mutate_config(config)
                self._config_writer(config)
        except SensitiveEditsDisabled:
            return self._mutation_blocked_result()
        except (OSError, ValueError) as exc:
            return {
                "ok": False,
                "status": "config_write_failed",
                "code": "config_write_failed",
                "error": f"Could not save command guard setting: {exc}",
            }

        result = self._config_public_state()
        result = dict(result) if isinstance(result, dict) else {"ok": True}
        public_config = result.get("config") if isinstance(result.get("config"), dict) else {}
        result["status"] = "updated"
        result["method"] = method
        result["command_guard"] = public_config.get("command_guard", command_guard)
        if isinstance(helper_warning, str) and helper_warning:
            result["warning"] = helper_warning
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
