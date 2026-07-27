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
        env_builder,
        lib_root,
        server_started_at,
        process_runner=subprocess.run,
        effective_uid=os.geteuid,
        which=shutil.which,
        managed_execution=False,
        allow_sudo_password=True,
        helper_socket_checker=None,
        now_iso=None,
    ):
        for name, callback in (
            ("config_reader", config_reader),
            ("audit", audit),
            ("env_builder", env_builder),
            ("process_runner", process_runner),
            ("effective_uid", effective_uid),
            ("which", which),
        ):
            if not callable(callback):
                raise TypeError(f"{name} must be callable")
        if not isinstance(managed_execution, bool):
            raise TypeError("managed_execution must be a boolean")
        if not isinstance(allow_sudo_password, bool):
            raise TypeError("allow_sudo_password must be a boolean")
        self.config_reader = config_reader
        self.audit = audit
        self.env_builder = env_builder
        self.lib_root = Path(lib_root)
        self.server_started_at = str(server_started_at)
        self.process_runner = process_runner
        self.effective_uid = effective_uid
        self.which = which
        self.managed_execution = bool(managed_execution)
        self.allow_sudo_password = bool(allow_sudo_password)
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

    def password_allowed(self, observer=None):
        observer = observer or self.runtime_config()
        return (
            not self.managed_execution
            and self.allow_sudo_password
            and not self.helper_available()
            and self.effective_uid() != 0
            and observer.get("enabled") != "disabled"
            and observer.get("privilege") == "sudo_interactive"
        )

    def authorization_mode(self, observer=None):
        observer = observer or self.runtime_config()
        if observer.get("enabled") == "disabled":
            return "disabled"
        if observer.get("privilege") == "none":
            return "disabled"
        if self.helper_available() or self.managed_execution:
            return "helper"
        if self.effective_uid() == 0:
            return "root"
        if observer.get("privilege") == "passwordless":
            return "sudo_noninteractive"
        if self.password_allowed(observer):
            return "sudo_interactive"
        return "unavailable"

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
            "managed_execution": self.managed_execution,
            "authorization_mode": self.authorization_mode(observer),
            "password_allowed": self.password_allowed(observer),
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

    def _run(self, command, *, timeout, env=None, input_text=None):
        if env is None:
            env = self.env_builder(include_api_key=False)
        options = {
            "env": env,
            "text": True,
            "capture_output": True,
            "timeout": timeout,
            "check": False,
        }
        if input_text is not None:
            options["input"] = input_text
        return self.process_runner(command, **options)

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
        except (OSError, subprocess.TimeoutExpired):
            return False
        return process.returncode == 0

    def validate_sudo(self, password):
        if (
            not isinstance(password, str)
            or not password
            or len(password) > 4096
            or any(character in password for character in ("\x00", "\n", "\r"))
        ):
            return {"ok": False, "status": "invalid_password"}
        try:
            process = self._run(
                ["sudo", "-S", "-p", "", "-v"],
                timeout=15,
                input_text=f"{password}\n",
            )
        except FileNotFoundError:
            return {"ok": False, "status": "sudo_not_found"}
        except subprocess.TimeoutExpired:
            return {"ok": False, "status": "sudo_timeout"}
        if process.returncode == 0:
            return {"ok": True, "status": "sudo_validated"}
        return {"ok": False, "status": "sudo_denied"}

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
        if helper is None and self.managed_execution:
            return self._failed(
                "observer_helper_unavailable",
                "helper",
                "The privileged observer helper is unavailable.",
                "Install or repair linux-agent-observer-helper.socket locally; managed Web never accepts sudo credentials.",
            )
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

        effective_uid = self.effective_uid()
        if effective_uid != 0:
            if not self.which("sudo"):
                return self._failed(
                    "sudo_not_found",
                    "sudo",
                    "sudo is not installed.",
                    "Install sudo, run Web as root, or use a managed installation with the observer helper.",
                )
            if not self.sudo_cached():
                if observer.get("privilege") != "sudo_interactive":
                    return self._failed(
                        "sudo_required",
                        "sudo",
                        "Passwordless sudo is not available.",
                        "observer.privilege=passwordless only uses an existing sudo -n authorization.",
                    )
                if not self.allow_sudo_password:
                    return self._failed(
                        "sudo_transport_disabled",
                        "sudo",
                        "Interactive sudo is restricted to a loopback Web listener.",
                        "Bind Web to 127.0.0.1/localhost or use the managed observer helper; the password was not used.",
                    )
                if not password:
                    return self._failed(
                        "sudo_required",
                        "sudo",
                        "sudo password is required.",
                        "The local Web adapter validates the password once through sudo stdin and does not store or log it.",
                    )
                check = self.validate_sudo(password)
                password = ""
                if not check.get("ok"):
                    status = str(check.get("status") or "sudo_denied")
                    return self._failed(
                        status,
                        "sudo",
                        "sudo credential validation failed.",
                        "The credential was not stored or logged; auditd observer was not enabled for Web Jobs.",
                    )

        if effective_uid == 0:
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
