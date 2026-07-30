"""Generic loader and dispatcher for signed builtin Skill Web components."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import re
import stat
import sys
from pathlib import Path


ERROR_CODE_PATTERN = re.compile(r"^[a-z][a-z0-9_]{0,63}$")
PACKAGE_NAME_PATTERN = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$")
RESOURCE_PATTERN = PACKAGE_NAME_PATTERN
ROUTE_PATTERN = re.compile(r"^/api/[a-z0-9][a-z0-9_./-]{0,190}$")
MAX_REMOTE_MANIFEST_BYTES = 1024 * 1024


class SkillWebComponentError(ValueError):
    def __init__(self, message, code="skill_component_unavailable"):
        super().__init__(message)
        self.code = code


class SkillWebRegistry:
    """Load package-local Web backends and expose only their fixed contract."""

    def __init__(
        self,
        skill_service,
        *,
        remote_mode,
        managed_execution,
        remote_manifest=None,
        materialize=None,
    ):
        self.skill_service = skill_service
        self.remote_mode = bool(remote_mode)
        self.managed_execution = bool(managed_execution)
        self.remote_manifest = Path(remote_manifest) if remote_manifest else None
        self.materialize = materialize
        self.components = {}
        self.routes = {}
        self.pending_components = {}
        self.pending_routes = {}
        self.findings = []
        self.reload()

    @staticmethod
    def _strict_json(path):
        def reject_duplicates(pairs):
            result = {}
            for key, value in pairs:
                if key in result:
                    raise ValueError(f"duplicate JSON key: {key}")
                result[key] = value
            return result

        metadata = path.lstat()
        if (
            not stat.S_ISREG(metadata.st_mode)
            or path.is_symlink()
            or metadata.st_size > MAX_REMOTE_MANIFEST_BYTES
        ):
            raise ValueError("remote manifest is unavailable or too large")
        with path.open("r", encoding="utf-8") as handle:
            return json.load(handle, object_pairs_hook=reject_duplicates)

    @staticmethod
    def _pending_web_contract(value):
        required = {
            "resource",
            "backend",
            "frontend",
            "fragment",
            "navigation",
            "routes",
            "job_actions",
        }
        if (
            not isinstance(value, dict)
            or not required.issubset(value)
            or set(value) - required - {"error_codes"}
        ):
            raise ValueError("pending Web component contract is invalid")
        resource = value.get("resource")
        navigation = value.get("navigation")
        routes = value.get("routes")
        job_actions = value.get("job_actions")
        if (
            not isinstance(resource, str)
            or RESOURCE_PATTERN.fullmatch(resource) is None
            or not isinstance(navigation, dict)
            or set(navigation) != {"screen", "label", "icon", "key", "order"}
            or not isinstance(routes, list)
            or not routes
            or not isinstance(job_actions, list)
            or not job_actions
        ):
            raise ValueError("pending Web component contract is invalid")
        normalized_routes = []
        route_keys = set()
        for route in routes:
            if not isinstance(route, dict) or set(route) != {"method", "path", "action"}:
                raise ValueError("pending Web component route is invalid")
            method = route.get("method")
            path = route.get("path")
            action = route.get("action")
            key = (method, path)
            if (
                method not in {"GET", "POST"}
                or not isinstance(path, str)
                or ROUTE_PATTERN.fullmatch(path) is None
                or not isinstance(action, str)
                or ERROR_CODE_PATTERN.fullmatch(action.replace(".", "_")) is None
                or key in route_keys
            ):
                raise ValueError("pending Web component route is invalid")
            route_keys.add(key)
            normalized_routes.append(dict(route))
        if (
            not all(
                isinstance(action, str)
                and RESOURCE_PATTERN.fullmatch(action) is not None
                for action in job_actions
            )
            or len(job_actions) != len(set(job_actions))
        ):
            raise ValueError("pending Web component jobs are invalid")
        error_codes = value.get("error_codes", {})
        if (
            not isinstance(error_codes, dict)
            or len(error_codes) > 64
            or any(
                not isinstance(code, str)
                or ERROR_CODE_PATTERN.fullmatch(code) is None
                or not isinstance(spec, dict)
                or set(spec) != {"retryable", "http"}
                or not isinstance(spec.get("retryable"), bool)
                or isinstance(spec.get("http"), bool)
                or not isinstance(spec.get("http"), int)
                or not 400 <= spec["http"] <= 599
                for code, spec in error_codes.items()
            )
        ):
            raise ValueError("pending Web component error codes are invalid")
        return {
            **value,
            "routes": normalized_routes,
            "job_actions": list(job_actions),
            "error_codes": {code: dict(spec) for code, spec in error_codes.items()},
        }

    def _load_pending(self, installed_names):
        if (
            not self.remote_mode
            or self.remote_manifest is None
            or not callable(self.materialize)
        ):
            return {}, {}, []
        findings = []
        pending = {}
        routes = {}
        try:
            manifest = self._strict_json(self.remote_manifest)
            if not isinstance(manifest, dict) or manifest.get("schema_version") != 2:
                raise ValueError("remote manifest schema is invalid")
            skills = manifest.get("skills")
            if not isinstance(skills, dict):
                raise ValueError("remote manifest Skill catalog is invalid")
            for name, entry in sorted(skills.items()):
                if name in installed_names:
                    continue
                if (
                    not isinstance(name, str)
                    or PACKAGE_NAME_PATTERN.fullmatch(name) is None
                    or not isinstance(entry, dict)
                ):
                    raise ValueError("remote manifest Skill entry is invalid")
                components = entry.get("components", {})
                if not isinstance(components, dict):
                    raise ValueError("remote manifest components are invalid")
                raw_web = components.get("web")
                if raw_web is None:
                    continue
                contract = self._pending_web_contract(raw_web)
                resource = contract["resource"]
                if resource in pending:
                    raise ValueError(f"duplicate pending Web resource: {resource}")
                pending[resource] = {
                    "name": name,
                    "contract": contract,
                    "components": components,
                }
                for route in contract["routes"]:
                    key = (route["method"], route["path"])
                    if key in routes:
                        raise ValueError(f"duplicate pending Web route: {route['path']}")
                    routes[key] = (resource, route["action"])
        except (OSError, UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
            findings.append(
                {
                    "severity": "warning",
                    "code": "SKILL_PENDING_COMPONENT_INVALID",
                    "message": str(exc),
                }
            )
            return {}, {}, findings
        return pending, routes, findings

    @staticmethod
    def _load_backend(path, package_name):
        module_name = (
            "linux_agent_web_component_"
            + package_name.replace("-", "_")
            + "_"
            + hashlib.sha256(os.fspath(path).encode("utf-8")).hexdigest()[:12]
        )
        spec = importlib.util.spec_from_file_location(module_name, path)
        if spec is None or spec.loader is None:
            raise SkillWebComponentError("Skill Web backend loader is unavailable")
        module = importlib.util.module_from_spec(spec)
        backend_root = os.fspath(path.parent)
        sys.path.insert(0, backend_root)
        try:
            spec.loader.exec_module(module)
        except Exception as exc:
            raise SkillWebComponentError(
                "Skill Web backend could not be loaded"
            ) from exc
        finally:
            try:
                sys.path.remove(backend_root)
            except ValueError:
                pass
        factory = getattr(module, "create_component", None)
        if not callable(factory):
            raise SkillWebComponentError(
                "Skill Web backend has no create_component factory"
            )
        return factory

    def reload(self):
        entries, findings = self.skill_service.builtin_components("web")
        components = {}
        routes = {}
        for entry in entries:
            name = entry["name"]
            directory = entry["directory"]
            contract = entry["component"]
            resource = contract["resource"]
            try:
                if resource in components:
                    raise SkillWebComponentError(
                        f"duplicate Skill Web resource: {resource}"
                    )
                credential = entry["package"].get("components", {}).get(
                    "credential_helper", {}
                )
                socket_env = credential.get("socket_env", "")
                default_socket = credential.get("default_socket", "")
                helper_socket = (
                    os.environ.get(socket_env, default_socket)
                    if socket_env
                    else default_socket
                )
                context = {
                    "remote_mode": self.remote_mode,
                    "managed_execution": self.managed_execution,
                    "helper_socket": helper_socket,
                }
                previous = self.components.get(resource)
                unchanged = (
                    previous is not None
                    and previous["name"] == name
                    and previous["directory"] == directory
                    and previous["contract"] == contract
                    and previous["package"] == entry["package"]
                    and previous.get("context") == context
                )
                if unchanged:
                    instance = previous["instance"]
                else:
                    factory = self._load_backend(
                        directory / contract["backend"], name
                    )
                    instance = factory(context)
                for method in (
                    "web_action",
                    "sanitize_job_payload",
                    "run_job",
                    "cancel_job",
                    "clear_secrets",
                ):
                    if not callable(getattr(instance, method, None)):
                        raise SkillWebComponentError(
                            f"Skill Web backend is missing {method}"
                        )
                components[resource] = {
                    "name": name,
                    "directory": directory,
                    "contract": contract,
                    "package": entry["package"],
                    "context": context,
                    "instance": instance,
                }
                for route in contract["routes"]:
                    key = (route["method"], route["path"])
                    if key in routes:
                        raise SkillWebComponentError(
                            f"duplicate Skill Web route: {route['path']}"
                        )
                    routes[key] = (resource, route["action"])
            except SkillWebComponentError as exc:
                findings.append(
                    {
                        "severity": "warning",
                        "code": "SKILL_WEB_COMPONENT_INVALID",
                        "skill": name,
                        "message": str(exc),
                    }
                )
                components.pop(resource, None)
                routes = {
                    key: value
                    for key, value in routes.items()
                    if value[0] != resource
                }
        pending, pending_routes, pending_findings = self._load_pending(
            self.skill_service.builtin_package_names()
        )
        self.components = components
        self.routes = routes
        self.pending_components = pending
        self.pending_routes = pending_routes
        self.findings = findings + pending_findings

    def _ensure_resource(self, resource):
        if resource in self.components:
            return self.components[resource]
        pending = self.pending_components.get(resource)
        if pending is None:
            raise SkillWebComponentError("Skill Web component is unavailable")
        try:
            result = self.materialize(pending["name"])
        except Exception as exc:
            raise SkillWebComponentError(
                "Skill Web component could not be materialized"
            ) from exc
        if not isinstance(result, dict) or result.get("ok") is not True:
            message = (
                result.get("error")
                if isinstance(result, dict) and isinstance(result.get("error"), str)
                else "Skill Web component could not be materialized"
            )
            raise SkillWebComponentError(message)
        self.reload()
        item = self.components.get(resource)
        if item is None or item["name"] != pending["name"]:
            raise SkillWebComponentError(
                "Materialized Skill does not provide the declared Web component"
            )
        if item["package"].get("components", {}) != pending["components"]:
            raise SkillWebComponentError(
                "Materialized Skill components do not match the signed manifest"
            )
        return item

    def public_components(self):
        result = []
        for resource, item in sorted(
            self.components.items(),
            key=lambda entry: entry[1]["contract"]["navigation"]["order"],
        ):
            contract = item["contract"]
            prefix = f"/skill-assets/{item['name']}/"
            result.append(
                {
                    "name": item["name"],
                    "resource": resource,
                    "navigation": dict(contract["navigation"]),
                    "frontend_url": prefix + contract["frontend"],
                    "fragment_url": prefix + contract["fragment"],
                    "job_actions": list(contract["job_actions"]),
                }
            )
        return result

    def error_spec(self, code):
        if not isinstance(code, str) or ERROR_CODE_PATTERN.fullmatch(code) is None:
            return None
        matches = []
        for item in (*self.components.values(), *self.pending_components.values()):
            contract = item.get("contract")
            if not isinstance(contract, dict):
                continue
            spec = contract.get("error_codes", {}).get(code)
            if isinstance(spec, dict):
                matches.append(spec)
        if not matches or any(spec != matches[0] for spec in matches[1:]):
            return None
        return dict(matches[0])

    def asset_path(self, package_name, relative_path):
        if not isinstance(relative_path, str) or not relative_path:
            raise SkillWebComponentError("Skill Web asset path is required")
        candidate = Path(relative_path)
        if candidate.is_absolute() or ".." in candidate.parts:
            raise SkillWebComponentError("Skill Web asset path is invalid")
        item = next(
            (
                value
                for value in self.components.values()
                if value["name"] == package_name
            ),
            None,
        )
        if item is None:
            raise SkillWebComponentError("Skill Web component is unavailable")
        allowed = {
            item["contract"]["frontend"],
            item["contract"]["fragment"],
        }
        normalized = candidate.as_posix()
        if normalized not in allowed:
            raise SkillWebComponentError("Skill Web asset is not declared")
        target = item["directory"] / candidate
        if target.is_symlink() or not target.is_file():
            raise SkillWebComponentError("Skill Web asset is unavailable")
        return target

    def handles_job(self, resource, action):
        item = self.components.get(resource)
        if item:
            return action in item["contract"]["job_actions"]
        pending = self.pending_components.get(resource)
        return bool(pending and action in pending["contract"]["job_actions"])

    def job_refs(self):
        installed = {
            (resource, action)
            for resource, item in self.components.items()
            for action in item["contract"]["job_actions"]
        }
        pending = {
            (resource, action)
            for resource, item in self.pending_components.items()
            for action in item["contract"]["job_actions"]
        }
        return installed | pending

    @staticmethod
    def _raise_component_error(exc):
        code = getattr(exc, "code", "")
        if not isinstance(code, str) or ERROR_CODE_PATTERN.fullmatch(code) is None:
            code = "skill_component_failed"
        raise SkillWebComponentError(str(exc), code) from exc

    def handle_web_action(self, method, path, body=None):
        route = self.routes.get((method, path))
        if route is None:
            pending = self.pending_routes.get((method, path))
            if pending is not None:
                self._ensure_resource(pending[0])
                route = self.routes.get((method, path))
        if route is None:
            return None
        resource, action = route
        try:
            return self.components[resource]["instance"].web_action(
                action, body if isinstance(body, dict) else {}
            )
        except Exception as exc:
            self._raise_component_error(exc)

    def sanitize_job_payload(self, resource, action, payload):
        try:
            item = self._ensure_resource(resource)
            return item["instance"].sanitize_job_payload(
                action, payload
            )
        except Exception as exc:
            self._raise_component_error(exc)

    def run_job(self, resource, action, payload, query_id):
        try:
            item = self._ensure_resource(resource)
            return item["instance"].run_job(
                action, payload, query_id=query_id
            )
        except Exception as exc:
            self._raise_component_error(exc)

    def cancel_job(self, resource, query_id):
        try:
            item = self._ensure_resource(resource)
            return item["instance"].cancel_job(query_id)
        except Exception as exc:
            self._raise_component_error(exc)

    def clear_secrets(self):
        cleared = 0
        for item in self.components.values():
            try:
                cleared += int(item["instance"].clear_secrets() or 0)
            except Exception:
                continue
        return cleared
