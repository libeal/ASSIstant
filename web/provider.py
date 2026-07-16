"""Provider registry and model-list service for the Web adapter.

Provider identity rules come from ``schema/domain.json``.  Runtime configuration,
secret lookup, remote-mode policy, and URL-security helpers are injected by the
adapter so this module has no dependency on ``web.server`` or process globals.
"""

import http.client
import json
import re
import socket
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlencode, urlparse, urlunparse


DEFAULT_MODEL_RESPONSE_LIMIT = 1024 * 1024


@dataclass(frozen=True)
class ProviderSecurityHelpers:
    """Injected SSRF policy operations used by :class:`ProviderService`."""

    policy_from_config: object
    validate_url: object
    inspect_url: object
    error_message: object

    def __post_init__(self):
        for name in ("policy_from_config", "validate_url", "inspect_url", "error_message"):
            if not callable(getattr(self, name)):
                raise TypeError(f"security helper {name} must be callable")


def derive_models_url(api_url):
    parsed = urlparse(str(api_url or ""))
    path = parsed.path.rstrip("/")
    if path.endswith("/chat/completions"):
        path = path[: -len("/chat/completions")] + "/models"
    elif path.endswith("/messages"):
        path = path[: -len("/messages")] + "/models"
    else:
        path += "/models"
    return urlunparse((parsed.scheme, parsed.netloc, path, "", "", ""))


def provider_auth_headers(auth, api_key):
    if auth == "anthropic":
        return {"x-api-key": api_key, "anthropic-version": "2023-06-01"}
    if auth == "api_subscription_key":
        return {"api-subscription-key": api_key}
    if auth in {"google_key_query", "none"}:
        return {}
    return {"Authorization": f"Bearer {api_key}"}


def model_list_request_url(provider, api_url, api_key):
    models = provider.get("models") if isinstance(provider.get("models"), dict) else {}
    if models.get("derive_from_api_url"):
        url = derive_models_url(api_url)
    else:
        url = str(models.get("url") or "")
    auth = str(models.get("auth") or provider.get("auth") or "bearer")
    if auth == "google_key_query":
        separator = "&" if urlparse(url).query else "?"
        url = f"{url}{separator}{urlencode({'key': api_key})}"
    return url, auth


def extract_model_ids(payload, parser):
    """Extract, de-duplicate, bound, and sort IDs from supported payloads."""

    ids = []
    if parser == "google_models":
        items = payload.get("models") if isinstance(payload, dict) else []
        if not isinstance(items, list):
            return []
        for item in items:
            if not isinstance(item, dict):
                continue
            methods = item.get("supportedGenerationMethods")
            if isinstance(methods, list) and "generateContent" not in methods:
                continue
            name = str(item.get("name") or item.get("id") or "")
            if name.startswith("models/"):
                name = name[len("models/") :]
            ids.append(name)
    elif parser == "models_name_or_id":
        items = payload.get("models") if isinstance(payload, dict) else []
        if not isinstance(items, list):
            return []
        for item in items:
            if isinstance(item, dict):
                ids.append(str(item.get("name") or item.get("id") or ""))
            else:
                ids.append(str(item or ""))
    else:
        items = payload.get("data") if isinstance(payload, dict) else []
        if not isinstance(items, list):
            return []
        for item in items:
            if isinstance(item, dict):
                ids.append(str(item.get("id") or ""))
            else:
                ids.append(str(item or ""))

    clean = []
    seen = set()
    for model_id in ids:
        model_id = " ".join(str(model_id or "").split())
        if not model_id or len(model_id) > 200 or model_id in seen:
            continue
        seen.add(model_id)
        clean.append(model_id)
    return sorted(clean)


def _pinned_socket(addresses, port, timeout):
    last_error = None
    for address in addresses:
        try:
            return socket.create_connection((address, port), timeout=timeout)
        except OSError as exc:
            last_error = exc
    if last_error is not None:
        raise last_error
    raise OSError("Provider hostname did not resolve to a usable address.")


class _PinnedHTTPConnection(http.client.HTTPConnection):
    def __init__(self, host, *args, resolved_addresses=None, **kwargs):
        super().__init__(host, *args, **kwargs)
        self.resolved_addresses = tuple(resolved_addresses or ())

    def connect(self):
        self.sock = _pinned_socket(self.resolved_addresses, self.port, self.timeout)
        if self._tunnel_host:
            self._tunnel()


class _PinnedHTTPSConnection(http.client.HTTPSConnection):
    def __init__(self, host, *args, resolved_addresses=None, **kwargs):
        super().__init__(host, *args, **kwargs)
        self.resolved_addresses = tuple(resolved_addresses or ())

    def connect(self):
        self.sock = _pinned_socket(self.resolved_addresses, self.port, self.timeout)
        if self._tunnel_host:
            self._tunnel()
        server_hostname = self._tunnel_host or self.host
        self.sock = self._context.wrap_socket(self.sock, server_hostname=server_hostname)


class _PinnedHTTPHandler(urllib.request.HTTPHandler):
    def __init__(self, resolved_addresses):
        super().__init__()
        self.resolved_addresses = tuple(resolved_addresses)

    def http_open(self, request):
        addresses = self.resolved_addresses

        class Connection(_PinnedHTTPConnection):
            def __init__(self, host, *args, **kwargs):
                super().__init__(host, *args, resolved_addresses=addresses, **kwargs)

        return self.do_open(Connection, request)


class _PinnedHTTPSHandler(urllib.request.HTTPSHandler):
    def __init__(self, resolved_addresses):
        super().__init__()
        self.resolved_addresses = tuple(resolved_addresses)

    def https_open(self, request):
        addresses = self.resolved_addresses

        class Connection(_PinnedHTTPSConnection):
            def __init__(self, host, *args, **kwargs):
                super().__init__(host, *args, resolved_addresses=addresses, **kwargs)

        return self.do_open(
            Connection,
            request,
            context=self._context,
            check_hostname=self._check_hostname,
        )


class _NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, file_pointer, code, message, headers, new_url):
        return None


def _redacted_text(value, secret=""):
    text = str(value or "")
    if secret:
        text = text.replace(secret, "[REDACTED]")
        text = text.replace(urlencode({"key": secret})[len("key=") :], "[REDACTED]")
    return text[:600]


class ProviderService:
    """Own provider lookup, public views, and protected model discovery."""

    def __init__(
        self,
        registry_path,
        domain_schema,
        *,
        config_reader,
        key_resolver,
        remote_mode,
        security_helpers,
        fetch_json=None,
        response_limit=DEFAULT_MODEL_RESPONSE_LIMIT,
    ):
        if not callable(config_reader):
            raise TypeError("config_reader must be callable")
        if not callable(key_resolver):
            raise TypeError("key_resolver must be callable")
        if not isinstance(security_helpers, ProviderSecurityHelpers):
            raise TypeError("security_helpers must be ProviderSecurityHelpers")
        self.registry_path = Path(registry_path)
        self._domain_schema = domain_schema
        self._config_reader = config_reader
        self._key_resolver = key_resolver
        self._remote_mode = bool(remote_mode)
        self._security = security_helpers
        self._fetcher = fetch_json or self._fetch_json_url
        self._response_limit = max(1, int(response_limit))

    def _schema(self):
        source = self._domain_schema() if callable(self._domain_schema) else self._domain_schema
        if isinstance(source, (str, Path)):
            try:
                with Path(source).open("r", encoding="utf-8") as handle:
                    source = json.load(handle)
            except (OSError, json.JSONDecodeError):
                return {}
        return source if isinstance(source, dict) else {}

    def read_registry(self):
        try:
            with self.registry_path.open("r", encoding="utf-8") as handle:
                payload = json.load(handle)
        except (OSError, json.JSONDecodeError):
            return []
        providers = payload.get("providers") if isinstance(payload, dict) else None
        return [provider for provider in providers if isinstance(provider, dict)] if isinstance(providers, list) else []

    def normalize_id(self, value):
        normalized = re.sub(r"[-\s/]+", "_", str(value or "").strip().lower())
        rules = self._schema().get("provider_normalization")
        if not isinstance(rules, dict):
            return normalized
        for rule in rules.get("prefix_rules") or []:
            if not isinstance(rule, dict):
                continue
            prefix = str(rule.get("prefix") or "")
            if prefix and normalized.startswith(prefix):
                return str(rule.get("canonical") or prefix)
        aliases = rules.get("aliases") if isinstance(rules.get("aliases"), dict) else {}
        if normalized in aliases:
            return str(aliases[normalized])
        return normalized

    def get_provider(self, provider_id):
        normalized = self.normalize_id(provider_id)
        for provider in self.read_registry():
            if self.normalize_id(provider.get("id")) == normalized:
                return dict(provider)
        return None

    def configured_provider_id(self, config=None):
        config = self._read_config() if config is None else config
        configured = self.normalize_id(config.get("provider", ""))
        if self.get_provider(configured) is not None:
            return configured
        default_id = self.normalize_id("")
        return default_id if default_id and self.get_provider(default_id) is not None else configured

    def public_provider(self, provider):
        models = provider.get("models") if isinstance(provider.get("models"), dict) else {}
        return {
            "id": str(provider.get("id") or ""),
            "label": str(provider.get("label") or provider.get("id") or ""),
            "api_url": str(provider.get("api_url") or ""),
            "default_model": str(provider.get("default_model") or ""),
            "custom_url": bool(provider.get("custom_url", False)),
            "model_fetch_supported": bool(models.get("supported", False)),
            "model_fetch_reason": str(models.get("reason") or ""),
            "request_format": str(provider.get("request_format") or "openai_chat"),
        }

    def public_state(self):
        providers = [
            self.public_provider(provider)
            for provider in self.read_registry()
            if provider.get("id")
        ]
        return {"ok": True, "status": "listed", "providers": providers}

    def _read_config(self):
        config = self._config_reader()
        return config if isinstance(config, dict) else {}

    @staticmethod
    def _safe_int(value, default):
        try:
            return int(value)
        except (TypeError, ValueError):
            return int(default)

    def _resolve_key(self, config, override):
        resolved = self._key_resolver(config, override)
        if not isinstance(resolved, tuple) or len(resolved) != 2:
            raise TypeError("key_resolver must return (api_key, source)")
        return str(resolved[0] or ""), str(resolved[1] or "missing")

    def _fetch_json_url(self, url, headers, timeout, secret, resolved_addresses):
        request = urllib.request.Request(url, headers=headers, method="GET")
        opener = urllib.request.build_opener(
            _NoRedirectHandler(),
            urllib.request.ProxyHandler({}),
            _PinnedHTTPHandler(resolved_addresses),
            _PinnedHTTPSHandler(resolved_addresses),
        )
        try:
            with opener.open(request, timeout=timeout) as response:
                body = response.read(self._response_limit + 1)
                if len(body) > self._response_limit:
                    return None, {
                        "ok": False,
                        "status": "provider_response_too_large",
                        "error": "Model list response is too large.",
                    }
        except urllib.error.HTTPError as exc:
            try:
                detail = exc.read(400).decode("utf-8", errors="replace")
            except OSError:
                detail = str(exc)
            return None, {
                "ok": False,
                "status": "provider_request_failed",
                "error": f"Provider returned HTTP {exc.code}.",
                "detail": _redacted_text(detail, secret),
            }
        except urllib.error.URLError as exc:
            return None, {
                "ok": False,
                "status": "provider_request_failed",
                "error": "Provider model list request failed.",
                "detail": _redacted_text(exc.reason, secret),
            }
        except TimeoutError:
            return None, {
                "ok": False,
                "status": "provider_request_timeout",
                "error": "Provider model list request timed out.",
            }
        try:
            return json.loads(body.decode("utf-8")), None
        except (UnicodeDecodeError, json.JSONDecodeError):
            return None, {
                "ok": False,
                "status": "provider_invalid_response",
                "error": "Provider model list response is not valid JSON.",
            }

    @staticmethod
    def _model_error(status, provider_id, message):
        return {
            "ok": False,
            "status": status,
            "provider": provider_id,
            "models": [],
            "error": message,
        }

    def list_models(self, body):
        body = body if isinstance(body, dict) else {}
        config = self._read_config()
        remote = config.get("remote") if isinstance(config.get("remote"), dict) else {}
        if self._remote_mode and remote.get("allow_api_key_transmission") is not True:
            return self._model_error(
                "secret_transmission_disabled",
                self.normalize_id(body.get("provider") or config.get("provider") or ""),
                "Remote runtime has not allowed API key transmission.",
            )

        explicit_provider = body.get("provider")
        provider_id = (
            self.normalize_id(explicit_provider)
            if explicit_provider
            else self.configured_provider_id(config)
        )
        provider = self.get_provider(provider_id)
        if provider is None:
            return self._model_error(
                "unsupported_provider",
                provider_id,
                "Provider is not configured in the registry.",
            )
        provider_id = self.normalize_id(provider.get("id"))
        models = provider.get("models") if isinstance(provider.get("models"), dict) else {}
        if models.get("supported") is not True:
            return self._model_error(
                "model_list_unavailable",
                provider_id,
                str(models.get("reason") or "This provider does not expose a configured model list endpoint."),
            )

        api_url = str(body.get("api_url") or config.get("api_url") or provider.get("api_url") or "")
        security = dict(self._security.policy_from_config(config))
        if self._remote_mode:
            security["require_https"] = True
        if models.get("derive_from_api_url") or not models.get("url"):
            api_url, url_error = self._security.validate_url(api_url, security)
            if url_error:
                return self._model_error(
                    url_error,
                    provider_id,
                    self._security.error_message(url_error),
                )

        api_key, key_source = self._resolve_key(config, body.get("api_key"))
        url, auth = model_list_request_url(provider, api_url, api_key)
        url, url_error, resolved_addresses = self._security.inspect_url(url, security)
        if url_error:
            return self._model_error(
                url_error,
                provider_id,
                self._security.error_message(url_error),
            )
        if auth != "none" and not api_key:
            return self._model_error(
                "api_key_missing",
                provider_id,
                "API key is required to list models.",
            )

        timeout = min(max(self._safe_int(config.get("request_timeout_sec", 30) or 30, 30), 1), 60)
        headers = {"Accept": "application/json"}
        headers.update(provider_auth_headers(auth, api_key))
        payload, error = self._fetcher(url, headers, timeout, api_key, resolved_addresses)
        if error:
            result = dict(error)
            result["provider"] = provider_id
            result["models"] = []
            return result
        parser = str(models.get("parser") or "openai_data_id")
        model_ids = extract_model_ids(payload, parser)
        return {
            "ok": True,
            "status": "listed",
            "provider": provider_id,
            "key_source": key_source,
            "models": [{"id": model_id} for model_id in model_ids],
            "model_count": len(model_ids),
        }

    # Compatibility-oriented names for the later server adapter patch.
    read_provider_registry = read_registry
    normalize_provider_id = normalize_id
    provider_by_id = get_provider
    config_provider_id = configured_provider_id
    providers_public_state = public_state
    list_provider_models = list_models
    extract_model_ids = staticmethod(extract_model_ids)


__all__ = [
    "DEFAULT_MODEL_RESPONSE_LIMIT",
    "ProviderSecurityHelpers",
    "ProviderService",
    "derive_models_url",
    "extract_model_ids",
    "model_list_request_url",
    "provider_auth_headers",
]
