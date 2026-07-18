"""Concurrent, durable configuration storage for the Web adapter."""

import fcntl
import json
import os
import re
import stat
import tempfile
import threading
from contextlib import contextmanager
from pathlib import Path


CONFIG_WRITABLE_FIELDS = {
    "provider": {"type": "str", "min": 1},
    "api_url": {"type": "str", "min": 1},
    "model": {"type": "str", "min": 1},
    "request_timeout_sec": {"type": "int", "min": 1, "max": 600},
    "provider_resilience.enabled": {"type": "bool"},
    "provider_resilience.max_attempts": {"type": "int", "min": 1, "max": 5},
    "provider_resilience.backoff_initial_ms": {"type": "int", "min": 0, "max": 60000},
    "provider_resilience.backoff_max_ms": {"type": "int", "min": 0, "max": 60000},
    "provider_resilience.circuit_failure_threshold": {"type": "int", "min": 1, "max": 100},
    "provider_resilience.circuit_open_sec": {"type": "int", "min": 1, "max": 86400},
    "context_turns": {"type": "int", "min": 1, "max": 50},
    "agent_loop.enabled_for_work": {"type": "bool"},
    "agent_loop.observation_text_limit": {"type": "int", "min": 200, "max": 200000},
    "agent_loop.thinking_trace_enabled": {"type": "bool"},
    "agent_loop.max_iterations": {"type": "int", "min": 1, "max": 100},
    "agent_loop.checkpoint_turns": {"type": "int", "min": 0, "max": 100},
    "approvals.auto.skill_readonly": {"type": "bool"},
    "approvals.auto.shell_readonly": {"type": "bool"},
    "approvals.auto.file_match": {"type": "bool"},
    "approvals.auto.file_patch": {"type": "bool"},
    "approvals.auto.file_download": {"type": "bool"},
    "approvals.auto.local_analyze": {"type": "bool"},
    "approvals.auto.remote_script": {"type": "bool"},
    "audit_mode": {"type": "enum", "values": {"safe_summary", "redacted_verbose"}},
    "audit_text_limit": {"type": "int", "min": 40, "max": 200000},
    "observer.enabled": {"type": "enum", "values": {"auto", "auditd", "disabled"}},
    "observer.privilege": {"type": "enum", "values": {"sudo_interactive", "passwordless", "none"}},
    "observer.max_events": {"type": "int", "min": 1, "max": 100000},
    "observer.require": {"type": "bool"},
    "execution.min_privilege_proxy": {"type": "bool"},
    "execution.timeout_sec": {"type": "int", "min": 1, "max": 3600},
    "execution.max_output_bytes": {"type": "int", "min": 4096, "max": 104857600},
    "execution.least_privilege_user": {"type": "str", "min": 1},
    "skills_dir": {"type": "str", "min": 0},
    "remote_script_policy": {"type": "enum", "values": {"download_review", "disabled"}},
    "providers_security.require_https": {"type": "bool"},
    "providers_security.block_internal_addresses": {"type": "bool"},
    "providers_security.allowed_hosts": {"type": "host_list", "max_items": 64},
    "remote.allow_api_key_transmission": {"type": "bool"},
    "web.max_active_jobs": {"type": "int", "min": 1, "max": 64},
    "web.job_timeout_sec": {"type": "int", "min": 1, "max": 86400},
    "web.max_job_attempts": {"type": "int", "min": 1, "max": 10},
    "web.cancel_grace_sec": {"type": "int", "min": 0, "max": 30},
    "web.metrics_enabled": {"type": "bool"},
}
CONFIG_SECRET_FIELDS = {"api_key"}
FAILOVER_API_KEY_ENV_PATTERN = re.compile(r"^[A-Z_][A-Z0-9_]*_API_KEY$")


def normalize_config_value(key, value):
    spec = CONFIG_WRITABLE_FIELDS.get(key)
    if not spec:
        return None, f"Unsupported writable config key: {key}"
    value_type = spec["type"]
    if value_type == "bool":
        if not isinstance(value, bool):
            return None, f"{key} must be boolean."
        return value, ""
    if value_type == "int":
        if isinstance(value, bool):
            return None, f"{key} must be integer."
        try:
            normalized = int(value)
        except (TypeError, ValueError):
            return None, f"{key} must be integer."
        if normalized < spec.get("min", normalized) or normalized > spec.get("max", normalized):
            return None, f"{key} is outside allowed range."
        return normalized, ""
    if value_type == "enum":
        normalized = str(value)
        if normalized not in spec["values"]:
            return None, f"{key} must be one of: {', '.join(sorted(spec['values']))}."
        return normalized, ""
    if value_type == "host_list":
        if not isinstance(value, list):
            return None, f"{key} must be a list of hostnames."
        max_items = spec.get("max_items", 64)
        if len(value) > max_items:
            return None, f"{key} allows at most {max_items} entries."
        normalized_list = []
        for item in value:
            host = str(item).strip().lower()
            if not host or len(host) > 255 or any(ch.isspace() for ch in host):
                return None, f"{key} contains an invalid hostname."
            normalized_list.append(host)
        return normalized_list, ""
    normalized = str(value)
    if len(normalized) < spec.get("min", 0):
        return None, f"{key} must not be empty."
    return normalized, ""


def write_nested_config_value(config, key, value):
    parts = key.split(".")
    target = config
    for part in parts[:-1]:
        child = target.get(part)
        if not isinstance(child, dict):
            child = {}
            target[part] = child
        target = child
    target[parts[-1]] = value


def validate_config_relationships(config):
    resilience = config.get("provider_resilience")
    if not isinstance(resilience, dict):
        return ""
    initial = resilience.get("backoff_initial_ms")
    maximum = resilience.get("backoff_max_ms")
    if isinstance(initial, int) and isinstance(maximum, int) and maximum < initial:
        return "provider_resilience.backoff_max_ms must be greater than or equal to backoff_initial_ms."
    return ""


def provider_failover_api_key_envs(config):
    resilience = config.get("provider_resilience")
    if not isinstance(resilience, dict):
        return []
    failover = resilience.get("failover")
    if not isinstance(failover, list):
        return []
    names = []
    for entry in failover[:8]:
        if not isinstance(entry, dict) or entry.get("reuse_primary_api_key") is True:
            continue
        name = entry.get("api_key_env")
        if (
            isinstance(name, str)
            and name != "LINUX_AGENT_API_KEY"
            and FAILOVER_API_KEY_ENV_PATTERN.fullmatch(name)
            and name not in names
        ):
            names.append(name)
    return names


def _write_all(descriptor, data):
    view = memoryview(data)
    offset = 0
    while offset < len(view):
        written = os.write(descriptor, view[offset:])
        if written <= 0:
            raise OSError("configuration write made no forward progress")
        offset += written


def _fsync_directory(path):
    descriptor = os.open(str(path), os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


class ConfigStore:
    """Serialize read-modify-write transactions across threads and processes."""

    def __init__(self, path):
        self.path = Path(path)
        self.lock_path = self.path.with_name(f".{self.path.name}.lock")
        self._thread_lock = threading.RLock()

    @contextmanager
    def _locked(self, *, exclusive):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
        with self._thread_lock:
            descriptor = os.open(str(self.lock_path), flags, 0o600)
            try:
                metadata = os.fstat(descriptor)
                if not stat.S_ISREG(metadata.st_mode):
                    raise OSError("configuration lock is not a regular file")
                os.fchmod(descriptor, 0o600)
                fcntl.flock(descriptor, fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH)
                yield
            finally:
                try:
                    fcntl.flock(descriptor, fcntl.LOCK_UN)
                finally:
                    os.close(descriptor)

    def _read_unlocked(self):
        try:
            with self.path.open("r", encoding="utf-8") as handle:
                data = json.load(handle)
        except FileNotFoundError:
            return {}
        if not isinstance(data, dict):
            raise ValueError("configuration root must be a JSON object")
        return data

    def read(self):
        with self._locked(exclusive=False):
            return self._read_unlocked()

    def _write_unlocked(self, config):
        if not isinstance(config, dict):
            raise TypeError("configuration root must be a mapping")
        if self.path.is_symlink():
            raise OSError("configuration file must not be a symbolic link")
        payload = (json.dumps(config, ensure_ascii=False, indent=2, allow_nan=False) + "\n").encode("utf-8")
        descriptor, raw_path = tempfile.mkstemp(
            prefix=f".{self.path.name}.",
            suffix=".tmp",
            dir=self.path.parent,
        )
        temp_path = Path(raw_path)
        try:
            os.fchmod(descriptor, 0o600)
            _write_all(descriptor, payload)
            os.fsync(descriptor)
            os.close(descriptor)
            descriptor = -1
            os.replace(temp_path, self.path)
            os.chmod(self.path, 0o600)
            _fsync_directory(self.path.parent)
        except Exception:
            if descriptor >= 0:
                os.close(descriptor)
            try:
                temp_path.unlink()
            except FileNotFoundError:
                pass
            raise

    def write(self, config):
        with self._locked(exclusive=True):
            self._write_unlocked(config)

    def update(self, mutator):
        if not callable(mutator):
            raise TypeError("configuration mutator must be callable")
        with self._locked(exclusive=True):
            config = self._read_unlocked()
            replacement = mutator(config)
            if replacement is not None:
                if not isinstance(replacement, dict):
                    raise TypeError("configuration mutator must return a mapping or None")
                config = replacement
            self._write_unlocked(config)
            return config


__all__ = [
    "CONFIG_SECRET_FIELDS",
    "CONFIG_WRITABLE_FIELDS",
    "ConfigStore",
    "normalize_config_value",
    "provider_failover_api_key_envs",
    "validate_config_relationships",
    "write_nested_config_value",
]
