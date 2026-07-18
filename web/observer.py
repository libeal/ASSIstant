"""Observer bootstrap application service for the Web adapter."""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import time
from pathlib import Path


class ObserverService:
    """Own observer configuration, helper discovery, and bootstrap state."""

    def __init__(
        self,
        *,
        config_reader,
        audit,
        sudo_check,
        env_builder,
        lib_root,
        server_started_at,
        process_runner=subprocess.run,
        effective_uid=os.geteuid,
        which=shutil.which,
        helper_socket_checker=None,
        now_iso=None,
    ):
        for name, callback in (
            ("config_reader", config_reader),
            ("audit", audit),
            ("sudo_check", sudo_check),
            ("env_builder", env_builder),
            ("process_runner", process_runner),
            ("effective_uid", effective_uid),
            ("which", which),
        ):
            if not callable(callback):
                raise TypeError(f"{name} must be callable")
        self.config_reader = config_reader
        self.audit = audit
        self.sudo_check = sudo_check
        self.env_builder = env_builder
        self.lib_root = Path(lib_root)
        self.server_started_at = str(server_started_at)
        self.process_runner = process_runner
        self.effective_uid = effective_uid
        self.which = which
        self.helper_socket_checker = helper_socket_checker or (lambda path: path.is_socket())
        self.now_iso = now_iso or (
            lambda: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        )
        self.state = {
            "status": "pending",
            "ok": True,
            "method": "",
            "error": "",
            "diagnostic": "",
            "updated_at": self.server_started_at,
        }

    @staticmethod
    def _safe_int(value, default):
        try:
            return int(value)
        except (TypeError, ValueError):
            return default

    @staticmethod
    def public_log_payload(result):
        return {
            "status": result.get("status", ""),
            "method": result.get("method", ""),
            "error": result.get("error", ""),
            "diagnostic": result.get("diagnostic", ""),
            "observer": result.get("observer", {}),
        }

    def runtime_config(self):
        config = self.config_reader()
        observer = config.get("observer") if isinstance(config.get("observer"), dict) else {}
        enabled = str(observer.get("enabled") or "auto")
        if enabled not in {"auto", "auditd", "disabled"}:
            enabled = "auto"
        privilege = str(observer.get("privilege") or "sudo_interactive")
        if privilege not in {"sudo_interactive", "passwordless", "none"}:
            privilege = "sudo_interactive"
        max_events = self._safe_int(observer.get("max_events", 200) or 200, 200)
        if max_events <= 0:
            max_events = 200
        return {
            "enabled": enabled,
            "privilege": privilege,
            "max_events": max_events,
            "require": observer.get("require", False) is True,
        }

    @staticmethod
    def helper_socket_path():
        return Path(
            os.environ.get(
                "LINUX_AGENT_OBSERVER_HELPER_SOCKET",
                "/run/linux-agent/observer.sock",
            )
        )

    def helper_available(self):
        return bool(self.helper_socket_checker(self.helper_socket_path()))

    def requires_permission(self, observer):
        return (
            observer.get("enabled") != "disabled"
            and observer.get("privilege") != "none"
            and not self.helper_available()
        )

    def public_state(self, force_ok=None, extra=None):
        observer = self.runtime_config()
        state = dict(self.state)
        if observer.get("enabled") == "disabled":
            state.update(
                {
                    "status": "disabled",
                    "ok": True,
                    "method": "config",
                    "diagnostic": "observer.enabled is disabled in config.",
                }
            )
        state.update(extra or {})
        ok = bool(state.get("ok", True)) if force_ok is None else bool(force_ok)
        return {
            "ok": ok,
            "status": state.get("status", "pending"),
            "method": state.get("method", ""),
            "error": state.get("error", ""),
            "diagnostic": state.get("diagnostic", ""),
            "updated_at": state.get("updated_at", self.server_started_at),
            "requires_permission": self.requires_permission(observer),
            "observer": observer,
        }

    def update_state(self, status, ok, method="", error="", diagnostic=""):
        self.state.update(
            {
                "status": status,
                "ok": bool(ok),
                "method": method,
                "error": str(error or "")[:400],
                "diagnostic": str(diagnostic or "")[:600],
                "updated_at": self.now_iso(),
            }
        )
        return self.public_state(force_ok=ok)

    def _record(self, stage, result):
        self.audit(stage, self.public_log_payload(result))
        return result

    def skip(self):
        result = self.update_state(
            "skipped",
            True,
            method="user",
            diagnostic="User skipped Web observer bootstrap; later Jobs will record observer_unavailable if privileged access is unavailable.",
        )
        self._record("observer_bootstrap_skipped", result)
        result["logged"] = True
        return result

    def _run(self, command, *, timeout, env=None):
        if env is None:
            env = self.env_builder(include_api_key=False)
        return self.process_runner(
            command,
            env=env,
            text=True,
            capture_output=True,
            timeout=timeout,
            check=False,
        )

    def helper_preflight(self):
        if not self.helper_available():
            return None
        command = [
            sys.executable,
            str(self.lib_root / "observer_helper.py"),
            "request",
            "--socket",
            str(self.helper_socket_path()),
            "status",
        ]
        try:
            return self._run(
                command,
                env=self.env_builder(include_api_key=False),
                timeout=20,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            return exc

    def sudo_cached(self):
        if not self.which("sudo"):
            return False
        try:
            process = self._run(["sudo", "-n", "true"], timeout=5)
        except (FileNotFoundError, subprocess.TimeoutExpired):
            return False
        return process.returncode == 0

    def _failed(self, status, method, error, diagnostic):
        return self._record(
            "observer_bootstrap_failed",
            self.update_state(
                status,
                False,
                method=method,
                error=error,
                diagnostic=diagnostic,
            ),
        )

    def enable(self, password=""):
        observer = self.runtime_config()
        if observer.get("enabled") == "disabled":
            return self._failed(
                "observer_disabled",
                "config",
                "observer.enabled is disabled.",
                "Enable observer.enabled before starting auditd observer bootstrap.",
            )
        if observer.get("privilege") == "none":
            return self._failed(
                "sudo_required",
                "none",
                "observer.privilege is set to none.",
                "Set observer.privilege to sudo_interactive or passwordless to enable the helper or auditd from Web.",
            )

        helper = self.helper_preflight()
        if helper is not None:
            if hasattr(helper, "returncode") and helper.returncode == 0:
                return self._record(
                    "observer_bootstrap_enabled",
                    self.update_state(
                        "enabled",
                        True,
                        method="helper",
                        diagnostic="The privileged observer helper is available; Web Jobs will use its fixed auditd protocol without sudo credentials.",
                    ),
                )
            if hasattr(helper, "returncode"):
                detail = (helper.stderr or helper.stdout or "observer helper failed").strip()
            else:
                detail = str(helper)
            return self._failed(
                "observer_helper_failed",
                "helper",
                detail,
                "The helper socket exists but its auditd preflight failed; Web will not fall back to sudo.",
            )

        if not self.which("auditctl"):
            return self._failed(
                "auditctl_not_found",
                "auditd",
                "auditctl is not installed.",
                "Install auditd/auditctl or disable observer.",
            )
        if not self.which("ausearch"):
            return self._failed(
                "ausearch_not_found",
                "auditd",
                "ausearch is not installed.",
                "Install auditd/ausearch or disable observer.",
            )

        if self.effective_uid() != 0 and not self.sudo_cached():
            if not password:
                return self._failed(
                    "sudo_required",
                    "sudo",
                    "sudo password is required.",
                    "Web has no TTY, so sudo credentials must be validated from the browser once per sudo timeout window.",
                )
            check = self.sudo_check(password)
            if not check.get("ok"):
                return self._failed(
                    str(check.get("status") or "sudo_denied"),
                    str(check.get("method") or "sudo"),
                    str(check.get("error") or check.get("status") or "sudo validation failed"),
                    "sudo credential validation failed; auditd observer was not enabled for Web Jobs.",
                )

        if self.effective_uid() == 0:
            command, method = ["auditctl", "-s"], "root"
        else:
            command, method = ["sudo", "-n", "auditctl", "-s"], "sudo"
        try:
            process = self._run(command, timeout=10)
        except subprocess.TimeoutExpired:
            return self._failed(
                "auditctl_timeout",
                method,
                "auditctl validation timed out.",
                "auditctl -s did not return within 10 seconds.",
            )
        except FileNotFoundError:
            return self._failed(
                "auditctl_not_found",
                method,
                "auditctl is not installed.",
                "Install auditd/auditctl or disable observer.",
            )
        if process.returncode == 0:
            return self._record(
                "observer_bootstrap_enabled",
                self.update_state(
                    "enabled",
                    True,
                    method=method,
                    diagnostic="auditctl preflight succeeded; subsequent Web Jobs can start auditd observer while privileged access remains valid.",
                ),
            )

        stderr = (process.stderr or process.stdout or "auditctl validation failed").strip()[:400]
        status = "auditctl_failed"
        diagnostic = "auditctl -s failed; auditd may be unavailable or the kernel audit interface may be restricted."
        if "operation not permitted" in stderr.lower():
            status = "auditctl_permission_denied"
            diagnostic = "auditctl was rejected by the kernel audit interface; this commonly happens in containers, WSL, or hosts without CAP_AUDIT_CONTROL/auditd support."
        return self._failed(status, method, stderr, diagnostic)


__all__ = ["ObserverService"]
