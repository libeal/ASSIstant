#!/usr/bin/env python3
"""Explicit environment construction for untrusted child processes.

Agent, Skill, Terminal, and MCP children must not inherit ambient cloud
credentials or secrets from the parent process.  Only a small, documented
allowlist is forwarded; AI secrets stay out unless a caller opts in.
"""

from __future__ import annotations

import os
import re
from typing import Mapping, MutableMapping, Optional


# Runtime essentials that Skill / shell / MCP scripts commonly need.
_BASE_ENV_KEYS = (
    "PATH",
    "HOME",
    "USER",
    "LOGNAME",
    "SHELL",
    "PWD",
    "TMPDIR",
    "TMP",
    "TEMP",
    "TERM",
    "LANG",
    "LANGUAGE",
    "TZ",
    "XDG_CONFIG_HOME",
    "XDG_CACHE_HOME",
    "XDG_DATA_HOME",
    "XDG_STATE_HOME",
)

_SAFE_AGENT_ENV_KEYS = (
    "LINUX_AGENT_ROOT",
    "LINUX_AGENT_REMOTE_MODE",
    "LINUX_AGENT_REMOTE_RELEASE_BASE",
    "LINUX_AGENT_REMOTE_MANIFEST",
    "LINUX_AGENT_REMOTE_RELEASE_VERSION",
    "LINUX_AGENT_REMOTE_STORAGE_BACKEND",
    "LINUX_AGENT_REMOTE_PREFLIGHT",
    "LINUX_AGENT_ALLOW_INSECURE_TEST_URL",
    "LINUX_AGENT_OBSERVER_HELPER_SOCKET",
)

_PROTECTED_AGENT_ENV_KEYS = {
    "LINUX_AGENT_API_KEY",
    "LINUX_AGENT_API_KEY_SOURCE",
    "LINUX_AGENT_LAST_AI_PAYLOAD",
    "LINUX_AGENT_CONFIG_JSON",
}


def is_allowed_env_name(name: str) -> bool:
    """Return whether a non-secret name may be forwarded to children."""

    if not isinstance(name, str) or not name:
        return False
    if name in _BASE_ENV_KEYS:
        return True
    if name in _SAFE_AGENT_ENV_KEYS:
        return True
    return name.startswith("LC_")


def build_subprocess_env(
    parent: Optional[Mapping[str, str]] = None,
    *,
    include_api_key: bool = False,
    extra: Optional[Mapping[str, str]] = None,
) -> dict[str, str]:
    """Build a minimal child environment from an explicit allowlist.

    ``include_api_key`` is reserved for the AI-calling path only. Manifest-owned
    credentials may be supplied explicitly by that manifest, but ambient parent
    credentials are never copied into the child.
    """

    source: Mapping[str, str] = os.environ if parent is None else parent
    env: dict[str, str] = {}
    for key, value in source.items():
        if not isinstance(key, str) or not isinstance(value, str):
            continue
        if is_allowed_env_name(key):
            env[key] = value

    if include_api_key:
        api_key = source.get("LINUX_AGENT_API_KEY")
        if isinstance(api_key, str) and api_key and api_key != "please-set-your-api-key":
            env["LINUX_AGENT_API_KEY"] = api_key

    if extra:
        for key, value in extra.items():
            if not isinstance(key, str) or not isinstance(value, str):
                continue
            if not is_allowed_env_name(key):
                continue
            env[key] = value

    # Ensure children always have a usable PATH even if the parent was sparse.
    env.setdefault("PATH", "/usr/bin:/bin")
    return env


def apply_manifest_env(
    env: MutableMapping[str, str],
    manifest_env: object,
) -> MutableMapping[str, str]:
    """Merge MCP/skill manifest env entries without reintroducing secrets."""

    if not isinstance(manifest_env, dict):
        return env
    for key, value in manifest_env.items():
        if not isinstance(key, str) or not isinstance(value, str):
            continue
        if (
            re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key) is None
            or key in _PROTECTED_AGENT_ENV_KEYS
        ):
            continue
        env[key] = value
    return env


__all__ = [
    "apply_manifest_env",
    "build_subprocess_env",
    "is_allowed_env_name",
]
